@tool
extends RefCounted
## Repairs applied to an UnrealToGodot export so it loads in Godot 4.8:
##
## 1. A texture parameter node used in both the vertex and the fragment
##    graph of a VisualShader keeps the same uniform name in both. Godot
##    4.7 merged the two declarations; 4.8 reports "Redefinition of
##    'Name'" and the material fails. The vertex-side node is renamed
##    "<Name>_VS" (the converter's own convention for scalar parameters)
##    and every ShaderMaterial using the shader gets a matching
##    "shader_parameter/<Name>_VS" value.
## 2. Resource UIDs of the copied files are registered before the editor's
##    scan, so loading a material before its texture is imported doesn't
##    warn "invalid UID".
## 3. UnrealToGodot writes the world transform of the source instance into
##    the prefab's mesh CollisionShape3D (the one named after the prefab),
##    so collisions end up offset twice in the scene. The mesh collider is
##    in the mesh's own space, like the Mesh node, so its transform is
##    reset to identity. Primitive shapes (Box0, Sphere0, Capsule0…) keep
##    their local transform.
## 4. Nodes two or more levels deep get their parent path reversed
##    ("StaticMesh/Actor" instead of "Actor/StaticMesh"), and prefab
##    instances name only their direct parent, so Godot drops them
##    ("Parent path ... has vanished"). Those paths are rewritten.
## 5. Point, spot and rect lights get 1000× the Unreal lumens and
##    light_energy = 16, so interiors burn out (worse with SDFGI, which
##    bounces it). Their light_energy is scaled to LIGHT_ENERGY.

const Log = preload("res://addons/godotfab/log.gd")

const TEXTURE_PARAMETER_TYPES := ["VisualShaderNodeTexture2DParameter", "VisualShaderNodeTexture2DArrayParameter",
	"VisualShaderNodeTexture3DParameter", "VisualShaderNodeCubemapParameter", "VisualShaderNodeTextureParameterTriplanar"]
const VS_SUFFIX := "_VS"
## light_energy the converter writes for non-directional lights, and the
## value that matches Unreal's look (tested against the pack's screenshots).
const CONVERTER_LIGHT_ENERGY := "16.000000"
const LIGHT_ENERGY := "0.160000"


## Fixes every VisualShader and ShaderMaterial .tres under [param root]
## (absolute path). Returns {shaders_fixed: int, materials_fixed: int}.
static func fix_export_tree(root: String) -> Dictionary:
	var files: Array[String] = []
	_collect(root, files)
	var renamed_by_shader := {}
	var shaders_fixed := 0
	for path in files:
		if not path.ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if not text.begins_with("[gd_resource type=\"VisualShader\""):
			continue
		var result := fix_visual_shader_text(text)
		if result.renamed.is_empty() and result.merged == 0:
			continue
		_write(path, result.text)
		if not result.renamed.is_empty():
			renamed_by_shader[path.get_file()] = result.renamed
		shaders_fixed += 1
	var prefabs_fixed := 0
	for path in files:
		if not path.ends_with(".tscn") or path.get_base_dir().get_file() != "Prefabs":
			continue
		var text := FileAccess.get_file_as_string(path)
		var fixed_prefab := fix_prefab_collision_text(text)
		if fixed_prefab != text:
			_write(path, fixed_prefab)
			prefabs_fixed += 1
	var scenes_fixed := 0
	for path in files:
		if not path.ends_with(".tscn"):
			continue
		var text := FileAccess.get_file_as_string(path)
		var fixed_scene := fix_light_energy_text(fix_scene_parent_paths(text))
		if fixed_scene != text:
			_write(path, fixed_scene)
			scenes_fixed += 1
	var materials_fixed := 0
	if not renamed_by_shader.is_empty():
		for path in files:
			if not path.ends_with(".tres"):
				continue
			var text := FileAccess.get_file_as_string(path)
			if not text.contains("ShaderMaterial"):
				continue
			var shader_file := material_shader_file(text)
			if shader_file.is_empty() or not renamed_by_shader.has(shader_file):
				continue
			var fixed := fix_material_text(text, renamed_by_shader[shader_file])
			if fixed != text:
				_write(path, fixed)
				materials_fixed += 1
	# UnrealToGodot swaps a material that fails to compile in Unreal for a
	# white "shader didn't compile" placeholder named "<MI>_Didnt_Compile_<n>".
	var failed := {}
	var failed_re := RegEx.create_from_string("\\(?([A-Za-z0-9_]+)_Didnt_Compile_\\d+")
	for path in files:
		var m := failed_re.search(path.get_file())
		if m:
			failed[m.get_string(1)] = true
	if not failed.is_empty():
		Log.warning("These materials failed to compile in Unreal and were replaced by a white placeholder (see the Unreal log for the error): %s" % ", ".join(failed.keys()))
	if shaders_fixed > 0 or prefabs_fixed > 0 or scenes_fixed > 0:
		Log.info("Fixed %d visual shaders, %d materials, %d prefab collisions and %d scenes (parent paths, light energy)" % [shaders_fixed, materials_fixed, prefabs_fixed, scenes_fixed])
	return {"shaders_fixed": shaders_fixed, "materials_fixed": materials_fixed, "prefabs_fixed": prefabs_fixed, "scenes_fixed": scenes_fixed}


## Scales the converter's light_energy of point/spot/rect lights (the line
## that follows light_intensity_lumens and light_color).
static func fix_light_energy_text(text: String) -> String:
	var re := RegEx.create_from_string("(?m)^(light_intensity_lumens = [^\\n]*\\nlight_color = [^\\n]*\\n)light_energy = %s$" % CONVERTER_LIGHT_ENERGY.replace(".", "\\."))
	return re.sub(text, "$1light_energy = " + LIGHT_ENERGY, true)


## Rewrites parent paths that point at no node declared earlier in the
## scene: the reversed path when that one exists, or, for a one-name path,
## the only declared node with that name. Paths into instanced scenes are
## left alone (neither form matches a declared node).
static func fix_scene_parent_paths(text: String) -> String:
	var node_re := RegEx.create_from_string("(?m)^\\[node name=\"([^\"]+)\"[^\\]\\n]*?parent=\"([^\"]*)\"")
	var known := {}
	var by_name := {}  # last name -> [paths]
	var out := text
	var offset := 0
	for m in node_re.search_all(text):
		var name := m.get_string(1)
		var parent := m.get_string(2)
		if parent != "." and not known.has(parent):
			var parts := parent.split("/")
			parts.reverse()
			var reversed := "/".join(parts)
			var fixed := ""
			if known.has(reversed):
				fixed = reversed
			elif parts.size() == 1 and by_name.get(parent, []).size() == 1:
				fixed = by_name[parent][0]
			if fixed != "":
				var start := m.get_start(2) + offset
				out = out.substr(0, start) + fixed + out.substr(start + parent.length())
				offset += fixed.length() - parent.length()
				parent = fixed
		var path := name if parent == "." else parent + "/" + name
		known[path] = true
		if not by_name.has(name):
			by_name[name] = []
		by_name[name].append(path)
	return out


## Removes the transform of the prefab's own mesh collision shape: a
## CollisionShape3D under StaticBody whose name is not a primitive
## (Box/Sphere/Capsule/Cylinder + index) and whose shape is a polygon shape.
static func fix_prefab_collision_text(text: String) -> String:
	var node_re := RegEx.create_from_string("(?m)^\\[node name=\"([^\"]+)\" type=\"CollisionShape3D\" parent=\"StaticBody\" *\\]\\n")
	var primitive_re := RegEx.create_from_string("^(Box|Sphere|Capsule|Cylinder)\\d+$")
	var out := text
	var offset := 0
	for m in node_re.search_all(text):
		if primitive_re.search(m.get_string(1)) != null:
			continue
		# The node's block: up to the next node header or the end.
		var block_start := m.get_end()
		var block_end := text.find("\n[node", block_start)
		if block_end < 0:
			block_end = text.length()
		var block := text.substr(block_start, block_end - block_start)
		if not block.contains("shape = SubResource(") or block.contains("BoxShape3D") or block.contains("SphereShape3D"):
			pass
		var transform_re := RegEx.create_from_string("(?m)^transform = Transform3D\\([^)]*\\)\\n")
		var t := transform_re.search(block)
		if t == null:
			continue
		# Only polygon (mesh) shapes live in the mesh's own space.
		var shape_re := RegEx.create_from_string("shape = SubResource\\(\"([^\"]+)\"\\)")
		var sm := shape_re.search(block)
		if sm == null:
			continue
		var sub_header := "[sub_resource type=\"%s\" id=\"%s\"]"
		var is_polygon := text.contains(sub_header % ["ConcavePolygonShape3D", sm.get_string(1)]) or text.contains(sub_header % ["ConvexPolygonShape3D", sm.get_string(1)])
		if not is_polygon:
			continue
		var abs_start := block_start + t.get_start() + offset
		var abs_end := block_start + t.get_end() + offset
		out = out.substr(0, abs_start) + out.substr(abs_end)
		offset -= t.get_end() - t.get_start()
	return out


## Merges parameter nodes that declare the same uniform inside one graph
## (Godot 4.8 emits one declaration per node → "Redefinition"). The node
## with the lowest index is kept; connections from the others are moved to
## it and their node entries are removed. Returns {text, merged: int}.
static func merge_duplicate_parameters(text: String) -> Dictionary:
	var header := RegEx.create_from_string("\\[sub_resource type=\"(VisualShaderNode\\w*Parameter(?:Triplanar)?)\" id=\"([^\"]+)\"\\]")
	var name_re := RegEx.create_from_string("(?m)^parameter_name = \"([^\"]*)\"")
	var names_by_id := {}
	for m in header.search_all(text):
		var block_start := m.get_end()
		var block_end := text.find("\n[", block_start)
		var block := text.substr(block_start, (block_end if block_end >= 0 else text.length()) - block_start)
		var n := name_re.search(block)
		if n:
			# Same uniform only when the node type matches too.
			names_by_id[m.get_string(2)] = m.get_string(1) + ":" + n.get_string(1)
	var node_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/(\\d+)/node = SubResource\\(\"([^\"]+)\"\\)")
	# stage -> name -> sorted node indices
	var by_stage := {}
	for m in node_re.search_all(text):
		var id := m.get_string(3)
		if not names_by_id.has(id):
			continue
		var stage := m.get_string(1)
		if not by_stage.has(stage):
			by_stage[stage] = {}
		var names: Dictionary = by_stage[stage]
		var key: String = names_by_id[id]
		if not names.has(key):
			names[key] = []
		names[key].append(m.get_string(2).to_int())
	var out := text
	var merged := 0
	for stage in by_stage:
		var replace := {}  # duplicate index -> kept index
		for key in by_stage[stage]:
			var idx: Array = by_stage[stage][key]
			if idx.size() < 2:
				continue
			idx.sort()
			for i in range(1, idx.size()):
				replace[idx[i]] = idx[0]
		if replace.is_empty():
			continue
		merged += replace.size()
		for dup in replace:
			var line_re := RegEx.create_from_string("(?m)^nodes/%s/%d/[^\\n]*\\n" % [stage, dup])
			out = line_re.sub(out, "", true)
		var conn_re := RegEx.create_from_string("(?m)^(nodes/%s/connections = PackedInt32Array\\()([^)]*)\\)" % stage)
		var cm := conn_re.search(out)
		if cm == null:
			continue
		var nums := cm.get_string(2).split(",", false)
		var kept := PackedStringArray()
		var seen := {}
		for q in range(0, nums.size() - 3, 4):
			var a := nums[q].strip_edges().to_int()
			var b := nums[q + 1].strip_edges().to_int()
			var c := nums[q + 2].strip_edges().to_int()
			var d := nums[q + 3].strip_edges().to_int()
			a = replace.get(a, a)
			c = replace.get(c, c)
			var k := "%d, %d, %d, %d" % [a, b, c, d]
			if seen.has(k):
				continue
			seen[k] = true
			kept.append(k)
		out = out.substr(0, cm.get_start()) + cm.get_string(1) + ", ".join(kept) + ")" + out.substr(cm.get_end())
	return {"text": out, "merged": merged}


## Merges same-graph duplicates, then renames texture parameters shared by
## the vertex and fragment graphs.
## Returns {text: String, renamed: Array[String], merged: int}.
static func fix_visual_shader_text(text: String) -> Dictionary:
	var merge := merge_duplicate_parameters(text)
	var renamed_result := _rename_vertex_textures(merge.text)
	renamed_result.merged = merge.merged
	return renamed_result


static func _rename_vertex_textures(text: String) -> Dictionary:
	# sub-resource id -> parameter name, for texture parameter nodes.
	var header := RegEx.create_from_string("\\[sub_resource type=\"(%s)\" id=\"([^\"]+)\"\\]" % "|".join(TEXTURE_PARAMETER_TYPES))
	var name_re := RegEx.create_from_string("(?m)^parameter_name = \"([^\"]*)\"")
	var names_by_id := {}
	for m in header.search_all(text):
		var block_start := m.get_end()
		var block_end := text.find("\n[", block_start)
		var block := text.substr(block_start, (block_end if block_end >= 0 else text.length()) - block_start)
		var n := name_re.search(block)
		if n:
			names_by_id[m.get_string(2)] = n.get_string(1)
	# The ids used by the vertex graph.
	var vertex_re := RegEx.create_from_string("(?m)^nodes/vertex/\\d+/node = SubResource\\(\"([^\"]+)\"\\)")
	var vertex_ids := {}
	for m in vertex_re.search_all(text):
		vertex_ids[m.get_string(1)] = true
	# Names declared by more than one node in use (several graphs).
	var used_re := RegEx.create_from_string("(?m)^nodes/\\w+/\\d+/node = SubResource\\(\"([^\"]+)\"\\)")
	var count := {}
	for m in used_re.search_all(text):
		var id := m.get_string(1)
		if names_by_id.has(id):
			count[names_by_id[id]] = count.get(names_by_id[id], 0) + 1
	var renamed: Array[String] = []
	var out := text
	for id in names_by_id:
		var name: String = names_by_id[id]
		if count.get(name, 0) < 2 or not vertex_ids.has(id) or name.ends_with(VS_SUFFIX):
			continue
		var old_block := "id=\"%s\"]\n" % id
		var pos := out.find(old_block)
		if pos < 0:
			continue
		var line_pos := out.find("parameter_name = \"%s\"" % name, pos)
		if line_pos < 0:
			continue
		out = out.substr(0, line_pos) + "parameter_name = \"%s%s\"" % [name, VS_SUFFIX] + out.substr(line_pos + ("parameter_name = \"%s\"" % name).length())
		if not name in renamed:
			renamed.append(name)
	return {"text": out, "renamed": renamed}


## The file name of the Shader ext_resource of a ShaderMaterial, "" if none.
static func material_shader_file(text: String) -> String:
	var re := RegEx.create_from_string("\\[ext_resource type=\"Shader\"[^\\]]*path=\"([^\"]+)\"")
	var m := re.search(text)
	return m.get_string(1).get_file() if m else ""


## Adds "shader_parameter/<name>_VS = <value>" after each renamed
## parameter's line, unless it is already there.
static func fix_material_text(text: String, renamed: Array) -> String:
	var lines := text.split("\n")
	var out := PackedStringArray()
	var existing := {}
	for line in lines:
		if line.begins_with("shader_parameter/"):
			existing[line.split(" ")[0]] = true
	for line in lines:
		out.append(line)
		for name in renamed:
			var key := "shader_parameter/%s" % name
			if line.begins_with(key + " ") and not existing.has(key + VS_SUFFIX):
				out.append(line.replace(key + " ", key + VS_SUFFIX + " ", ))
				existing[key + VS_SUFFIX] = true
	return "\n".join(out)


## Registers the uid of every .import, .tscn and .tres under [param root]
## (absolute) for its res:// path, so references resolve on the first scan.
static func register_uids(root: String, res_root: String) -> int:
	if not Engine.is_editor_hint():
		return 0
	var files: Array[String] = []
	_collect(root, files)
	var uid_re := RegEx.create_from_string("(?m)^uid=\"(uid://[a-z0-9]+)\"|\\[gd_(?:scene|resource)[^\\]]*uid=\"(uid://[a-z0-9]+)\"")
	var registered := 0
	for path in files:
		var ext := path.get_extension()
		if not ext in ["import", "tscn", "tres"]:
			continue
		var head := FileAccess.get_file_as_string(path).left(600)
		var m := uid_re.search(head)
		if m == null:
			continue
		var uid_text := m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)
		var id := ResourceUID.text_to_id(uid_text)
		if id == ResourceUID.INVALID_ID:
			continue
		var relative := path.substr(root.length()).trim_prefix("/")
		if ext == "import":
			relative = relative.trim_suffix(".import")
		var res_path := res_root.rstrip("/") + "/" + relative
		if ResourceUID.has_id(id):
			continue
		ResourceUID.add_id(id, res_path)
		registered += 1
	return registered


## UnrealToGodot writes the same UIDs in every export (WorldEnvironment.tscn,
## CameraAttributes.tres, notify_player.gd, engine materials…), so a second
## pack in the project collides with the first ("UID duplicate detected",
## "invalid UID"). Every UID declared under [param root] (absolute) is replaced
## by one derived from [param salt] (the pack's res:// folder) and the old one,
## stable across reimports, and every reference to it inside the pack is
## rewritten. Already-remapped trees are left as they are (the mapping is
## recorded in .godotfab_uids). Returns the number of UIDs remapped.
static func remap_uids(root: String, salt: String) -> int:
	var marker := root.path_join(".godotfab_uids")
	if FileAccess.file_exists(marker):
		return 0
	var files: Array[String] = []
	_collect(root, files)
	var texts := {}
	for path in files:
		if path.get_extension() in ["tscn", "tres", "import", "uid"]:
			texts[path] = FileAccess.get_file_as_string(path)
	var declared_re := RegEx.create_from_string("(?m)^\\[gd_(?:scene|resource)[^\\]\\n]*uid=\"uid://([a-z0-9]+)\"|^uid=\"uid://([a-z0-9]+)\"")
	var mapping := {}
	for path in texts:
		var text: String = texts[path]
		if path.ends_with(".uid"):
			var old := text.strip_edges().trim_prefix("uid://")
			if not old.is_empty():
				mapping[old] = ""
			continue
		var m := declared_re.search(text.left(2000))
		if m:
			mapping[m.get_string(1) if m.get_string(1) != "" else m.get_string(2)] = ""
	for old in mapping:
		mapping[old] = derived_uid(salt, old)
	var ref_re := RegEx.create_from_string("uid://([a-z0-9]+)")
	for path in texts:
		var text: String = texts[path]
		var out := ""
		var last := 0
		for m in ref_re.search_all(text):
			var old := m.get_string(1)
			if mapping.has(old):
				out += text.substr(last, m.get_start() - last) + "uid://" + mapping[old]
				last = m.get_end()
		if last > 0:
			out += text.substr(last)
			_write(path, out)
	var lines := PackedStringArray()
	for old in mapping:
		lines.append("%s %s" % [old, mapping[old]])
	_write(marker, "\n".join(lines) + "\n")
	return mapping.size()


## ext_resource lines whose uid doesn't match the uid the target file declares
## (UnrealToGodot references notify_player.gd with a uid different from the
## one in its .gd.uid) get the declared uid, so Godot doesn't warn "invalid
## UID". Only targets inside the pack are checked. Returns the lines fixed.
static func fix_stale_uid_refs(root: String, res_root: String) -> int:
	var files: Array[String] = []
	_collect(root, files)
	var declared_re := RegEx.create_from_string("(?m)^\\[gd_(?:scene|resource)[^\\]\\n]*uid=\"(uid://[a-z0-9]+)\"|^uid=\"(uid://[a-z0-9]+)\"")
	var uid_of := {}  # res:// path -> declared uid
	var prefix := res_root.trim_suffix("/") + "/"
	for path in files:
		var rel := path.trim_prefix(root.trim_suffix("/") + "/")
		if path.ends_with(".uid"):
			uid_of[prefix + rel.trim_suffix(".uid")] = FileAccess.get_file_as_string(path).strip_edges()
		elif path.get_extension() in ["tscn", "tres", "import"]:
			var m := declared_re.search(FileAccess.get_file_as_string(path).left(2000))
			if m:
				var target := prefix + (rel.trim_suffix(".import") if path.ends_with(".import") else rel)
				uid_of[target] = m.get_string(1) if m.get_string(1) != "" else m.get_string(2)
	var ref_re := RegEx.create_from_string("(\\[ext_resource[^\\]\\n]*?uid=\")(uid://[a-z0-9]+)(\"[^\\]\\n]*?path=\")([^\"]+)(\")")
	var fixed := 0
	for path in files:
		if not path.get_extension() in ["tscn", "tres"]:
			continue
		var text := FileAccess.get_file_as_string(path)
		var out := ""
		var last := 0
		for m in ref_re.search_all(text):
			var want: String = uid_of.get(m.get_string(4), "")
			if want != "" and want != m.get_string(2):
				out += text.substr(last, m.get_start(2) - last) + want
				last = m.get_end(2)
				fixed += 1
		if last > 0:
			_write(path, out + text.substr(last))
	return fixed


## A valid UID text derived from [param salt] and [param old].
static func derived_uid(salt: String, old: String) -> String:
	var high := (salt + "|" + old).hash()
	var low := (old + "|" + salt).hash()
	var id := ((high << 31) ^ low) & 0x7FFFFFFFFFFFFFFF
	if id == 0:
		id = 1
	return ResourceUID.id_to_text(id).trim_prefix("uid://")


static func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
	for file in d.get_files():
		out.append(dir.path_join(file))


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
