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
## 6. Unreal parameter names with spaces or dashes ("Level 1 Wind") are
##    written verbatim into the uniform declaration. They are made valid
##    identifiers ("Level_1_Wind") in the shader and its materials.
## 7. Custom expressions get COMPILER_HLSL replaced by a float
##    ("#if 0.0"), which Godot's preprocessor rejects (the whole shader
##    fails). The condition becomes an integer.
## 8. World-space nodes (WorldPosition, PixelNormalWS…) are written as
##    "INV_VIEW_MATRIX * vec4(VERTEX, 1.0)" in every graph. That is right in
##    the fragment graph (VERTEX in view space) but in the vertex graph
##    VERTEX is in model space, so the "world" position depends on the
##    camera: wind/bending (world position offset) stretches the mesh as the
##    camera moves. In vertex-graph expressions it becomes MODEL_MATRIX.
## 10. The rest of the vertex graph works in Unreal space but local-to-world
##    transforms are missing or done in Godot space, and the world position
##    offset is added unconverted; see fix_vertex_unreal_transforms.
## 9. Float textures are exported as EXR (Pivot Painter positions/vectors,
##    flow maps: data, not color). The converter's .import asks for VRAM
##    compression, which is BC6H for HDR (lossy, alpha dropped: Pivot
##    Painter keeps the parent index there) and mipmaps (neighbouring
##    pivots blend). They are imported lossless without mipmaps.
## 11. Textures the vertex graph samples are data too (Pivot Painter axis and
##    extent per branch, read texel by texel through UV2). The editor detects
##    their use in 3D and recompresses them to VRAM (S3TC 4x4 blocks mix the
##    texels of neighbouring branches, which then turn and shrink wrongly:
##    trees look half empty). Their .import is made lossless with 3D
##    detection off; mipmaps are left as they are (the vertex stage reads
##    level 0).
## 12. Unreal's Power node is PositiveClampedPow (the base is clamped to 0
##    and up); the converter writes a plain vector pow, which is NaN for a
##    negative base in GLSL. A NaN in the wind offset of Pivot Painter
##    foliage removes the whole mesh. Each pow node becomes an expression
##    node computing pow(max(base, 0.0), exponent).
## 13. The world normal node (PixelNormalWS) is left in Godot axes while the
##    rest of the graph is in Unreal axes (Z up). Snow masks then cover one
##    vertical half of each trunk. Its output is swapped with .xzy.
## 14. Unreal Clamp nodes in "Clamp Min" mode are written as clamp(x, min, 1).
##    Pivot Painter 2's extent (Clamp Min 8) then is always 1 cm and the wind
##    falloff saturates: lower branches swing hard, the top barely moves.
##    They become max(x, min); see fix_clamp_min.
## 15. Texture parameters are always written with linear filtering. Pivot
##    Painter textures are Nearest in Unreal (one value per branch, parent index
##    in the alpha bits); blended texels send branches flying. Parameters that
##    get a texture the commandlet lists as Nearest are set to nearest; see
##    fix_nearest_textures.
## 16. Alpha tested foliage loses its leaves at a distance: mipmaps average the
##    opacity below the clip value. Textures the commandlet lists as feeding
##    Opacity Mask are imported with alpha test coverage preserved; when the
##    opacity is in R, G or B, that channel is swapped with alpha on import and
##    back in the shader; see fix_opacity_textures.
## 17. Alpha tested materials get render_mode alpha_to_coverage: with MSAA 3D
##    on, sub-pixel leaves cover part of a pixel instead of a hard dot, so
##    distant foliage stays full; see fix_alpha_to_coverage.
## 18. Alpha tested foliage thins out with distance (small mipmaps keep the
##    opacity below the clip value; Unreal hides it with TAA). The alpha
##    scissor threshold is lowered with distance; see fix_alpha_test_distance.
## 19. Automatic mesh LOD collapses leaf cards (half the crown gone at 90 m,
##    popping at each LOD step). Meshes with alpha tested materials get
##    lod_bias = 4; see fix_foliage_lod_bias.

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
	var sanitized_by_shader := {}
	var shaders_fixed := 0
	for path in files:
		if not path.ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if not text.begins_with("[gd_resource type=\"VisualShader\""):
			continue
		var result := fix_visual_shader_text(text)
		if result.text == text:
			continue
		_write(path, result.text)
		if not result.renamed.is_empty():
			renamed_by_shader[path.get_file()] = result.renamed
		if not result.sanitized.is_empty():
			sanitized_by_shader[path.get_file()] = result.sanitized
		shaders_fixed += 1
	var prefabs_fixed := 0
	for path in files:
		if not path.ends_with(".tscn") or path.get_base_dir().get_file() != "Prefabs":
			continue
		var text := FileAccess.get_file_as_string(path)
		var fixed_prefab := fix_missing_shape_subresources(fix_prefab_collision_text(text))
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
	var float_textures_fixed := 0
	for path in files:
		if not path.to_lower().ends_with(".exr.import"):
			continue
		var text := FileAccess.get_file_as_string(path)
		var fixed_import := fix_float_texture_import_text(text)
		if fixed_import != text:
			_write(path, fixed_import)
			float_textures_fixed += 1
	if float_textures_fixed > 0:
		Log.info("Float textures imported lossless without mipmaps: %d" % float_textures_fixed)
	var materials_fixed := 0
	if not renamed_by_shader.is_empty() or not sanitized_by_shader.is_empty():
		for path in files:
			if not path.ends_with(".tres"):
				continue
			var text := FileAccess.get_file_as_string(path)
			if not text.contains("ShaderMaterial"):
				continue
			var shader_file := material_shader_file(text)
			if shader_file.is_empty():
				continue
			var fixed := rename_material_parameters(text, sanitized_by_shader.get(shader_file, {}))
			fixed = fix_material_text(fixed, renamed_by_shader.get(shader_file, []))
			if fixed != text:
				_write(path, fixed)
				materials_fixed += 1
	var vertex_textures_fixed := fix_vertex_texture_imports(root, files)
	if vertex_textures_fixed > 0:
		Log.info("Textures sampled by vertex shaders imported lossless: %d" % vertex_textures_fixed)
	var nearest_fixed := fix_nearest_textures(root, files)
	if nearest_fixed > 0:
		Log.info("Texture parameters sampled with nearest filtering (as in Unreal): %d" % nearest_fixed)
	var opacity_fixed := fix_opacity_textures(root, files)
	if opacity_fixed > 0:
		Log.info("Opacity mask textures imported with alpha test coverage preserved: %d" % opacity_fixed)
	var lod_fixed := fix_foliage_lod_bias(files)
	if lod_fixed > 0:
		Log.info("Alpha tested meshes with mesh LOD pushed away (lod_bias %s): %d" % [FOLIAGE_LOD_BIAS, lod_fixed])
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


## Rewrites the .import of every texture under [param root] that a vertex
## graph samples, set on its texture node or through a ShaderMaterial's
## parameter (fix 11). Returns the number of .import files changed.
static func fix_vertex_texture_imports(root: String, files: Array[String]) -> int:
	var params_by_shader := {}
	var res_paths := {}
	for path in files:
		if not path.ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if not text.begins_with("[gd_resource type=\"VisualShader\""):
			continue
		var found := vertex_textures(text)
		if not found.params.is_empty():
			params_by_shader[path.get_file()] = found.params
		for res_path in found.paths:
			res_paths[res_path] = true
	if not params_by_shader.is_empty():
		for path in files:
			if not path.ends_with(".tres"):
				continue
			var text := FileAccess.get_file_as_string(path)
			if not text.contains("ShaderMaterial"):
				continue
			var params: Array = params_by_shader.get(material_shader_file(text), [])
			for res_path in material_textures(text, params):
				res_paths[res_path] = true
	if res_paths.is_empty():
		return 0
	var fixed := 0
	for path in files:
		if not path.ends_with(".import"):
			continue
		var relative := path.substr(root.length()).trim_suffix(".import")
		if not relative.begins_with("/"):
			relative = "/" + relative
		var sampled := false
		for res_path in res_paths:
			if str(res_path).ends_with(relative):
				sampled = true
				break
		if not sampled:
			continue
		var text := FileAccess.get_file_as_string(path)
		var fixed_import := fix_vertex_texture_import_text(text)
		if fixed_import != text:
			_write(path, fixed_import)
			fixed += 1
	return fixed


## File the commandlet writes next to the export: one texture per line, the
## Unreal package path without its mount point ("/Game/A/T" -> "A/T", "/Engine/
## B/T" -> "Engine/B/T"), for every texture whose Unreal filter is Nearest.
const NEAREST_TEXTURES_FILE := "godotfab_nearest_textures.txt"
const TEXTURE_FILTER_NEAREST := 1


## Fix 15: the converter writes every texture parameter with linear filtering
## and mipmaps. Unreal samples Pivot Painter textures with Nearest filtering:
## they hold one value per branch, and the parent index sits in the bits of the
## alpha channel. Branches whose UV2 is a hair off the texel center (Spruce
## Forest's low trees) then read a blend of two texels, decode a random parent
## and the wind turns them about another branch, far from the trunk. Texture
## parameters a ShaderMaterial fills with a texture listed in
## NEAREST_TEXTURES_FILE get texture_filter = nearest. Other textures (wind
## noise, also sampled by the vertex graph) keep their filtering. Returns the
## number of texture parameter nodes changed.
static func fix_nearest_textures(root: String, files: Array[String]) -> int:
	var list := root.path_join(NEAREST_TEXTURES_FILE)
	if not FileAccess.file_exists(list):
		return 0
	var nearest := {}
	for line in FileAccess.get_file_as_string(list).split("\n", false):
		var rel := line.strip_edges().trim_prefix("/")
		if not rel.is_empty():
			nearest[rel] = true
	if nearest.is_empty():
		return 0
	var params_by_shader := {}
	for path in files:
		if not path.ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if not text.contains("ShaderMaterial"):
			continue
		var shader_file := material_shader_file(text)
		if shader_file.is_empty():
			continue
		for param in nearest_material_parameters(text, nearest):
			if not params_by_shader.has(shader_file):
				params_by_shader[shader_file] = []
			if not param in params_by_shader[shader_file]:
				params_by_shader[shader_file].append(param)
	var fixed := 0
	for path in files:
		if not path.ends_with(".tres") or not params_by_shader.has(path.get_file()):
			continue
		var text := FileAccess.get_file_as_string(path)
		if not text.begins_with("[gd_resource type=\"VisualShader\""):
			continue
		var result := set_texture_filter_text(text, params_by_shader[path.get_file()], TEXTURE_FILTER_NEAREST)
		if result.count > 0:
			_write(path, result.text)
			fixed += result.count
	return fixed


## File the commandlet writes next to the export: "<texture>\t<channel>\t<clip>"
## per line (texture as in NEAREST_TEXTURES_FILE, channel R, G, B, A or RGB),
## for every texture channel that feeds the Opacity Mask of a masked material.
const OPACITY_TEXTURES_FILE := "godotfab_opacity_textures.txt"
## Expanded output port of VisualShaderNodeTexture for each channel.
const CHANNEL_PORTS := {"R": 1, "G": 2, "B": 3, "A": 4}
## Godot's process/channel_remap value (and key) for each channel.
const CHANNEL_REMAP := {"R": 0, "G": 1, "B": 2, "A": 3}
const CHANNEL_REMAP_KEYS := {"R": "red", "G": "green", "B": "blue", "A": "alpha"}
## Marks a texture node whose R/G/B port was already swapped with alpha.
const OPACITY_SWAP_META := "metadata/godotfab_opacity_swap"
const TEXTURE_SOURCE_PORT := 5


## Fix 16: alpha tested foliage loses its leaves at a distance, the mipmaps
## average the opacity below the clip value. Godot can keep the alpha test
## coverage of each mipmap (mipmaps/preserve_alpha_test_coverage), but only for
## the alpha channel. A texture listed in OPACITY_TEXTURES_FILE with channel A
## just gets that option. One with R, G or B gets that channel swapped with
## alpha on import (the remap runs before the mipmaps), and every texture node
## that samples it through a shader parameter gets its two output ports
## swapped back. A texture is left alone when that is not safe: read as a whole
## color, listed with two channels, set directly on a shader node, or bound to a
## parameter that also receives textures that are not swapped the same way.
## Returns the number of .import files changed.
static func fix_opacity_textures(root: String, files: Array[String]) -> int:
	var list := root.path_join(OPACITY_TEXTURES_FILE)
	if not FileAccess.file_exists(list):
		return 0
	var listed := parse_opacity_list(FileAccess.get_file_as_string(list))
	if listed.is_empty():
		return 0
	# .import files of mipmapped textures, by path relative to the root without extension.
	var imports := {}
	for path in files:
		if not path.ends_with(".import"):
			continue
		var rel := path.substr(root.length()).trim_prefix("/").trim_suffix(".import").get_basename()
		if listed.has(_listed_key(rel, listed)) and FileAccess.get_file_as_string(path).contains("mipmaps/generate=true"):
			imports[_listed_key(rel, listed)] = path
	# Texture bindings: shader file -> parameter -> [listed key or "" for others].
	var bindings := {}
	var direct := {}
	var shaders := {}
	var bound := {}
	for path in files:
		if not path.ends_with(".tres") and not path.ends_with(".tscn"):
			continue
		var text := FileAccess.get_file_as_string(path)
		var is_shader := text.begins_with("[gd_resource type=\"VisualShader\"")
		if is_shader:
			shaders[path.get_file()] = path
		var shader_file := "" if is_shader or not path.ends_with(".tres") or not text.contains("ShaderMaterial") else material_shader_file(text)
		if shader_file.is_empty():
			# Set on a shader node, or used outside a ShaderMaterial: no port to swap back.
			for res_path in _ext_resource_paths(text).values():
				direct[_listed_key(str(res_path).trim_prefix("res://").get_basename(), listed)] = true
			continue
		var ext_paths := _ext_resource_paths(text)
		var param_re := RegEx.create_from_string("(?m)^shader_parameter/(\\w+) = ExtResource\\(\"([^\"]+)\"\\)")
		for m in param_re.search_all(text):
			if not ext_paths.has(m.get_string(2)):
				continue
			var key := _listed_key(str(ext_paths[m.get_string(2)]).trim_prefix("res://").get_basename(), listed)
			if not bindings.has(shader_file):
				bindings[shader_file] = {}
			if not bindings[shader_file].has(m.get_string(1)):
				bindings[shader_file][m.get_string(1)] = []
			if not key in bindings[shader_file][m.get_string(1)]:
				bindings[shader_file][m.get_string(1)].append(key)
			bound[key] = true
	# Textures that can be fixed; R/G/B ones need every parameter they reach swappable.
	var valid := {}
	for key in listed:
		var channel: String = listed[key].channel
		if not channel in CHANNEL_PORTS or not imports.has(key):
			continue
		if channel != "A" and (direct.has(key) or not bound.has(key)):
			continue
		valid[key] = channel
	var swappable_cache := {}
	var changed := true
	while changed:
		changed = false
		for shader_file in bindings:
			for param in bindings[shader_file]:
				var keys: Array = bindings[shader_file][param]
				var channels := {}
				var ok := true
				for key in keys:
					if valid.has(key):
						channels[valid[key]] = true
					elif key != "":
						ok = false
				if channels.is_empty() or channels.has("A") and channels.size() == 1:
					# Alpha needs no port swap: other textures on the parameter don't matter.
					continue
				var channel: String = channels.keys()[0]
				if ok and not keys.has("") and channels.size() == 1:
					var cache_key: String = shader_file + "\t" + param
					if not swappable_cache.has(cache_key):
						swappable_cache[cache_key] = shaders.has(shader_file) and opacity_swap_text(FileAccess.get_file_as_string(shaders[shader_file]), param, channel).ok
					ok = swappable_cache[cache_key]
				else:
					ok = false
				if not ok:
					for key in keys:
						if valid.has(key):
							valid.erase(key)
							changed = true
	# Shader ports first, then the imports.
	for shader_file in bindings:
		if not shaders.has(shader_file):
			continue
		var text := FileAccess.get_file_as_string(shaders[shader_file])
		var fixed_text := text
		for param in bindings[shader_file]:
			var key: String = bindings[shader_file][param][0]
			if not valid.has(key) or valid[key] == "A":
				continue
			fixed_text = opacity_swap_text(fixed_text, param, valid[key]).text
		if fixed_text != text:
			_write(shaders[shader_file], fixed_text)
	var fixed := 0
	for key in valid:
		var text := FileAccess.get_file_as_string(imports[key])
		var fixed_import := opacity_import_text(text, valid[key], listed[key].clip)
		if fixed_import != text:
			_write(imports[key], fixed_import)
			fixed += 1
	return fixed


## {texture key: {channel: String, clip: float}} from an OPACITY_TEXTURES_FILE
## text. A texture listed with two channels gets channel "" (left alone); with
## two clip values, the lowest one.
static func parse_opacity_list(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var parts := line.strip_edges().split("\t")
		if parts.size() < 3 or parts[0].is_empty():
			continue
		var key := parts[0].trim_prefix("/")
		var clip := parts[2].to_float()
		if not out.has(key):
			out[key] = {"channel": parts[1], "clip": clip}
			continue
		if out[key].channel != parts[1]:
			out[key].channel = ""
		out[key].clip = minf(out[key].clip, clip)
	return out


## The key of [param listed] a texture path (res:// relative, no extension)
## matches, or "" when none does.
static func _listed_key(bare: String, listed: Dictionary) -> String:
	if listed.has(bare):
		return bare
	for key in listed:
		if bare.ends_with("/" + str(key)):
			return key
	return ""


## Swaps output port CHANNEL_PORTS[channel] with the alpha port of every
## texture node that samples parameter [param param] of a VisualShader text.
## Returns {text, ok: bool}; ok is false (text unchanged) when the parameter
## also feeds anything else, or a node reads the whole color.
static func opacity_swap_text(text: String, param: String, channel: String) -> Dictionary:
	var fail := {"text": text, "ok": false}
	var header := RegEx.create_from_string("\\[sub_resource type=\"([^\"]+)\" id=\"([^\"]+)\"\\]\n")
	var types := {}
	var blocks := {}
	var param_ids := {}
	for m in header.search_all(text):
		var end := text.find("\n[", m.get_end())
		end = end if end >= 0 else text.length()
		var block := text.substr(m.get_end(), end - m.get_end())
		types[m.get_string(2)] = m.get_string(1)
		blocks[m.get_string(2)] = [m.get_end(), end]
		if m.get_string(1) in TEXTURE_PARAMETER_TYPES and ("\n" + block + "\n").contains("\nparameter_name = \"%s\"\n" % param):
			param_ids[m.get_string(2)] = true
	if param_ids.is_empty():
		return fail
	var node_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/(\\d+)/node = SubResource\\(\"([^\"]+)\"\\)")
	var node_ids := {}
	for m in node_re.search_all(text):
		node_ids[m.get_string(1) + "/" + m.get_string(2)] = m.get_string(3)
	var conn_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/connections = PackedInt32Array\\(([^)]*)\\)")
	var port := int(CHANNEL_PORTS[channel])
	var swaps := {}
	var stages := {}
	for m in conn_re.search_all(text):
		var stage := m.get_string(1)
		var values := m.get_string(2).split(",", false)
		var ints: Array[int] = []
		for v in values:
			ints.append(int(v))
		stages[stage] = [m, ints]
		for i in range(0, ints.size() - 3, 4):
			var from_id: String = node_ids.get(stage + "/" + str(ints[i]), "")
			if not param_ids.has(from_id):
				continue
			var to_key := stage + "/" + str(ints[i + 2])
			var to_id: String = node_ids.get(to_key, "")
			if types.get(to_id, "") != "VisualShaderNodeTexture" or ints[i + 3] != 2:
				return fail
			var tex_block := text.substr(blocks[to_id][0], blocks[to_id][1] - blocks[to_id][0])
			if not tex_block.contains("source = %d" % TEXTURE_SOURCE_PORT):
				return fail
			swaps[to_key] = to_id
	if swaps.is_empty():
		return fail
	var out := text
	var done := {}
	for stage in stages:
		var m: RegExMatch = stages[stage][0]
		var ints: Array[int] = stages[stage][1]
		for i in range(0, ints.size() - 3, 4):
			var key: String = stage + "/" + str(ints[i])
			if not swaps.has(key):
				continue
			if ints[i + 1] == 0:
				return fail
			if text.substr(blocks[swaps[key]][0], blocks[swaps[key]][1] - blocks[swaps[key]][0]).contains(OPACITY_SWAP_META):
				continue
			if ints[i + 1] == port:
				ints[i + 1] = 4
			elif ints[i + 1] == 4:
				ints[i + 1] = port
			done[swaps[key]] = true
		var joined := PackedStringArray()
		for v in ints:
			joined.append(str(v))
		out = out.replace(m.get_string(0), "nodes/%s/connections = PackedInt32Array(%s)" % [stage, ", ".join(joined)])
	for id in done:
		out = out.replace("[sub_resource type=\"VisualShaderNodeTexture\" id=\"%s\"]\n" % id,
			"[sub_resource type=\"VisualShaderNodeTexture\" id=\"%s\"]\n%s = \"%s\"\n" % [id, OPACITY_SWAP_META, channel])
	return {"text": out, "ok": true}


## The .import of an opacity mask texture: alpha test coverage preserved in the
## mipmaps at [param clip]; for R, G or B, that channel swapped with alpha.
static func opacity_import_text(text: String, channel: String, clip: float) -> String:
	var values := {
		"mipmaps/preserve_alpha_test_coverage": "true",
		"mipmaps/alpha_test_threshold": str(snappedf(clip, 0.0001)),
	}
	for c in CHANNEL_REMAP_KEYS:
		values["process/channel_remap/" + CHANNEL_REMAP_KEYS[c]] = str(CHANNEL_REMAP[c])
	if channel != "A":
		values["process/channel_remap/" + CHANNEL_REMAP_KEYS[channel]] = str(CHANNEL_REMAP["A"])
		values["process/channel_remap/alpha"] = str(CHANNEL_REMAP[channel])
	var out := text
	for key in values:
		var re := RegEx.create_from_string("(?m)^" + key + "=.*$")
		var line: String = key + "=" + values[key]
		if re.search(out):
			out = re.sub(out, line)
		else:
			out = out.trim_suffix("\n") + "\n" + line + "\n"
	return out


## Shader parameter names a ShaderMaterial text fills with a texture from
## [param nearest] (keys: paths relative to the export root, no extension).
static func nearest_material_parameters(text: String, nearest: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var ext_paths := _ext_resource_paths(text)
	var param_re := RegEx.create_from_string("(?m)^shader_parameter/(\\w+) = ExtResource\\(\"([^\"]+)\"\\)")
	for m in param_re.search_all(text):
		if not ext_paths.has(m.get_string(2)):
			continue
		var res_path: String = ext_paths[m.get_string(2)]
		var bare := res_path.trim_prefix("res://").get_basename()
		for rel in nearest:
			if bare == rel or bare.ends_with("/" + str(rel)):
				if not m.get_string(1) in out:
					out.append(m.get_string(1))
				break
	return out


## Sets texture_filter on the texture parameter nodes of a VisualShader text
## named in [param params]. Returns {text, count: int} (nodes changed).
static func set_texture_filter_text(text: String, params: Array, filter: int) -> Dictionary:
	var header := RegEx.create_from_string("\\[sub_resource type=\"([^\"]+)\" id=\"[^\"]+\"\\]\n")
	var name_re := RegEx.create_from_string("(?m)^parameter_name = \"([^\"]*)\"$")
	var filter_re := RegEx.create_from_string("(?m)^texture_filter = \\d+$")
	var out := ""
	var last := 0
	var count := 0
	for m in header.search_all(text):
		if not m.get_string(1) in TEXTURE_PARAMETER_TYPES:
			continue
		var end := text.find("\n[", m.get_end())
		end = end if end >= 0 else text.length()
		var block := text.substr(m.get_end(), end - m.get_end())
		var n := name_re.search(block)
		if n == null or not n.get_string(1) in params:
			continue
		var line := "texture_filter = %d" % filter
		var fixed_block: String
		if filter_re.search(block):
			fixed_block = filter_re.sub(block, line)
		else:
			fixed_block = block.substr(0, n.get_end()) + "\n" + line + block.substr(n.get_end())
		if fixed_block == block:
			continue
		out += text.substr(last, m.get_end() - last) + fixed_block
		last = end
		count += 1
	out += text.substr(last)
	return {"text": out, "count": count}


## Textures sampled by the vertex graph of a VisualShader:
## {params: Array[String] (texture parameter names), paths: Array[String]
## (res:// paths set directly on texture nodes)}.
static func vertex_textures(text: String) -> Dictionary:
	var ext_paths := _ext_resource_paths(text)
	var vertex_re := RegEx.create_from_string("(?m)^nodes/vertex/\\d+/node = SubResource\\(\"([^\"]+)\"\\)")
	var vertex_ids := {}
	for m in vertex_re.search_all(text):
		vertex_ids[m.get_string(1)] = true
	var header := RegEx.create_from_string("\\[sub_resource type=\"([^\"]+)\" id=\"([^\"]+)\"\\]")
	var name_re := RegEx.create_from_string("(?m)^parameter_name = \"([^\"]*)\"")
	var texture_re := RegEx.create_from_string("(?m)^texture = ExtResource\\(\"([^\"]+)\"\\)")
	var params: Array[String] = []
	var paths: Array[String] = []
	for m in header.search_all(text):
		if not vertex_ids.has(m.get_string(2)):
			continue
		var block_end := text.find("\n[", m.get_end())
		var block := text.substr(m.get_end(), (block_end if block_end >= 0 else text.length()) - m.get_end())
		if m.get_string(1) in TEXTURE_PARAMETER_TYPES:
			var n := name_re.search(block)
			if n and not n.get_string(1) in params:
				params.append(n.get_string(1))
		var t := texture_re.search(block)
		if t and ext_paths.has(t.get_string(1)) and not ext_paths[t.get_string(1)] in paths:
			paths.append(ext_paths[t.get_string(1)])
	return {"params": params, "paths": paths}


## res:// paths of the textures a ShaderMaterial sets for [param params].
static func material_textures(text: String, params: Array) -> Array[String]:
	var out: Array[String] = []
	if params.is_empty():
		return out
	var ext_paths := _ext_resource_paths(text)
	var param_re := RegEx.create_from_string("(?m)^shader_parameter/(\\w+) = ExtResource\\(\"([^\"]+)\"\\)")
	for m in param_re.search_all(text):
		if m.get_string(1) in params and ext_paths.has(m.get_string(2)):
			var res_path: String = ext_paths[m.get_string(2)]
			if not res_path in out:
				out.append(res_path)
	return out


## {ext_resource id: path} of a .tres/.tscn text.
static func _ext_resource_paths(text: String) -> Dictionary:
	var out := {}
	var ext_re := RegEx.create_from_string("\\[ext_resource ([^\\]]*)\\]")
	var path_re := RegEx.create_from_string("\\bpath=\"([^\"]+)\"")
	var id_re := RegEx.create_from_string("\\bid=\"([^\"]+)\"")
	for m in ext_re.search_all(text):
		var p := path_re.search(m.get_string(1))
		var i := id_re.search(m.get_string(1))
		if p and i:
			out[i.get_string(1)] = p.get_string(1)
	return out


## The .import of a texture a vertex graph samples: lossless and never
## recompressed by the editor's 3D detection; other settings kept.
static func fix_vertex_texture_import_text(text: String) -> String:
	var out := RegEx.create_from_string("(?m)^compress/mode=\\d+$").sub(text, "compress/mode=0")
	out = RegEx.create_from_string("(?m)^detect_3d/compress_to=\\d+$").sub(out, "detect_3d/compress_to=0")
	return out


## The .import of an EXR texture exported from a float source: lossless
## (compress/mode=0) and no mipmaps, other settings kept.
static func fix_float_texture_import_text(text: String) -> String:
	var out := RegEx.create_from_string("(?m)^compress/mode=\\d+$").sub(text, "compress/mode=0")
	out = RegEx.create_from_string("(?m)^mipmaps/generate=\\w+$").sub(out, "mipmaps/generate=false")
	return out


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


## Removes CollisionShape3D nodes whose shape SubResource is never declared.
## The converter skips the ConcavePolygonShape3D when the mesh has no
## collision data but still writes the node; Godot then refuses the prefab
## ("Invalid parameter") and the editor can't open any scene using it.
static func fix_missing_shape_subresources(text: String) -> String:
	var declared := {}
	for m in RegEx.create_from_string("(?m)^\\[sub_resource [^\\]\\n]*id=\"([^\"]+)\"").search_all(text):
		declared[m.get_string(1)] = true
	var node_re := RegEx.create_from_string("(?m)^\\[node name=\"[^\"]+\" type=\"CollisionShape3D\"[^\\n]*\\]\\n")
	var shape_re := RegEx.create_from_string("(?m)^shape = SubResource\\(\"([^\"]+)\"\\)$")
	var out := text
	var removed := 0
	for m in node_re.search_all(text):
		var block_end := text.find("\n[", m.get_end())
		block_end = text.length() if block_end < 0 else block_end + 1
		var block := text.substr(m.get_end(), block_end - m.get_end())
		var sm := shape_re.search(block)
		if sm == null or declared.has(sm.get_string(1)):
			continue
		var start := m.get_start() - removed
		out = out.substr(0, start) + out.substr(start + block_end - m.get_start())
		removed += block_end - m.get_start()
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


## Merges same-graph duplicates, renames texture parameters shared by the
## vertex and fragment graphs, turns Unreal parameter names into valid
## identifiers, makes float preprocessor conditions integers and puts
## vertex-graph world-space nodes in model space.
## Returns {text: String, renamed: Array[String], merged: int,
## sanitized: {old: new}, conditions: int, world_space: int,
## unreal_transforms: int}.
static func fix_visual_shader_text(text: String) -> Dictionary:
	var merge := merge_duplicate_parameters(text)
	var sanitize := sanitize_parameter_names(merge.text)
	var conditions := fix_preprocessor_conditions(sanitize.text)
	var world := fix_vertex_world_space(conditions.text)
	var transforms := fix_vertex_unreal_transforms(world.text)
	var powers := fix_unreal_power(transforms.text)
	var normals := fix_world_normal_axes(powers.text)
	var clamps := fix_clamp_min(normals.text)
	var coverage := fix_alpha_to_coverage(clamps.text)
	var distance := fix_alpha_test_distance(coverage.text)
	var renamed_result := _rename_vertex_textures(distance.text)
	renamed_result.alpha_test_distance = distance.count
	renamed_result.alpha_to_coverage = coverage.count
	renamed_result.powers = powers.count
	renamed_result.clamp_mins = clamps.count
	renamed_result.world_normals = normals.count
	renamed_result.world_space = world.count
	renamed_result.unreal_transforms = transforms.count
	renamed_result.merged = merge.merged
	renamed_result.sanitized = sanitize.sanitized
	renamed_result.conditions = conditions.count
	return renamed_result


## Fragment output port of ALPHA_SCISSOR_THRESHOLD.
const ALPHA_SCISSOR_PORT := 19


## Fix 17: alpha tested materials (alpha scissor threshold connected) get
## render_mode alpha_to_coverage. With MSAA 3D on, leaves smaller than a pixel
## cover part of it instead of a hard on/off dot, so distant foliage stays full
## (Unreal hides that with TAA). Without MSAA it changes nothing.
## Returns {text, count: int} (1 when the flag was added).
static func fix_alpha_to_coverage(text: String) -> Dictionary:
	var unchanged := {"text": text, "count": 0}
	var conn := RegEx.create_from_string("(?m)^nodes/fragment/connections = PackedInt32Array\\(([^)]*)\\)").search(text)
	# Spatial shaders only (other modes number their output ports differently).
	if conn == null or text.contains("\nflags/alpha_to_coverage = true") or RegEx.create_from_string("(?m)^mode = [1-9]").search(text):
		return unchanged
	var ints := conn.get_string(1).split(",", false)
	var scissor := false
	for i in range(0, ints.size() - 3, 4):
		if int(ints[i + 2]) == 0 and int(ints[i + 3]) == ALPHA_SCISSOR_PORT:
			scissor = true
			break
	if not scissor or not text.contains("\n[resource]\n"):
		return unchanged
	return {"text": text.replace("\n[resource]\n", "\n[resource]\nflags/alpha_to_coverage = true\n"), "count": 1}


## lod_bias given to meshes with alpha tested materials.
const FOLIAGE_LOD_BIAS := 4.0


## Fix 19: Godot's automatic mesh LOD decimates foliage as any other mesh, and
## collapsing leaf cards removes the leaves: a European Beech keeps half of its
## crown area at 90 m and the crown pops at each LOD step. Mesh nodes of
## scenes that use an alpha tested material (a ShaderMaterial whose shader has
## the alpha scissor threshold connected) get lod_bias = FOLIAGE_LOD_BIAS,
## which keeps the full crown past 200 m. Returns the number of scenes changed.
static func fix_foliage_lod_bias(files: Array[String]) -> int:
	var masked_shaders := {}
	for path in files:
		if not path.ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.begins_with("[gd_resource type=\"VisualShader\"") and has_alpha_scissor(text):
			masked_shaders[path.get_file()] = true
	if masked_shaders.is_empty():
		return 0
	var masked_materials := {}
	for path in files:
		if not path.ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.contains("ShaderMaterial") and masked_shaders.has(material_shader_file(text)):
			masked_materials[path.get_file()] = true
	var fixed := 0
	for path in files:
		if not path.ends_with(".tscn"):
			continue
		var text := FileAccess.get_file_as_string(path)
		var fixed_text := foliage_lod_bias_text(text, masked_materials)
		if fixed_text != text:
			_write(path, fixed_text)
			fixed += 1
	return fixed


## True when the fragment graph of a spatial VisualShader text feeds the alpha
## scissor threshold.
static func has_alpha_scissor(text: String) -> bool:
	var conn := RegEx.create_from_string("(?m)^nodes/fragment/connections = PackedInt32Array\\(([^)]*)\\)").search(text)
	if conn == null or RegEx.create_from_string("(?m)^mode = [1-9]").search(text):
		return false
	var ints := conn.get_string(1).split(",", false)
	for i in range(0, ints.size() - 3, 4):
		if int(ints[i + 2]) == 0 and int(ints[i + 3]) == ALPHA_SCISSOR_PORT:
			return true
	return false


## Adds lod_bias to every node of a scene text that overrides a surface with a
## material whose file name is a key of [param masked_materials].
static func foliage_lod_bias_text(text: String, masked_materials: Dictionary) -> String:
	var ext_paths := _ext_resource_paths(text)
	var node_re := RegEx.create_from_string("(?m)^\\[node [^\\]]*\\]\n")
	var override_re := RegEx.create_from_string("(?m)^surface_material_override/\\d+ = ExtResource\\(\"([^\"]+)\"\\)")
	var out := ""
	var last := 0
	for m in node_re.search_all(text):
		var end := text.find("\n[", m.get_end())
		end = end if end >= 0 else text.length()
		var block := text.substr(m.get_end(), end - m.get_end())
		if ("\n" + block).contains("\nlod_bias = "):
			continue
		var masked := false
		for o in override_re.search_all(block):
			if masked_materials.has(str(ext_paths.get(o.get_string(1), "")).get_file()):
				masked = true
				break
		if not masked:
			continue
		out += text.substr(last, m.get_end() - last) + "lod_bias = %s\n" % FOLIAGE_LOD_BIAS
		last = m.get_end()
	return out + text.substr(last)


const ALPHA_DISTANCE_ID := "VisualShaderNodeExpression_godotfab_alpha_distance"
## The alpha scissor threshold is multiplied by ALPHA_FAR_SCALE from
## ALPHA_FAR_END meters on, blending in from ALPHA_FAR_BEGIN.
const ALPHA_FAR_SCALE := 0.65
const ALPHA_FAR_BEGIN := 10.0
const ALPHA_FAR_END := 45.0


## Fix 18: alpha tested foliage thins out with distance even with coverage
## preserving mipmaps: bilinear filtering of the small mipmaps keeps the
## opacity of a leaf below Unreal's clip value over most of its area (European
## Beech draws 72% of its true crown area at 40 m, 55% at 60 m, 38% at 90 m).
## Unreal hides that with TAA. An expression node between the threshold's
## source and the output lowers the threshold with the distance to the camera,
## which keeps the crown at 97-113% of its true area up to 90 m.
## Returns {text, count: int} (1 when the node was added).
static func fix_alpha_test_distance(text: String) -> Dictionary:
	var unchanged := {"text": text, "count": 0}
	var conn_re := RegEx.create_from_string("(?m)^nodes/fragment/connections = PackedInt32Array\\(([^)]*)\\)")
	var conn := conn_re.search(text)
	if conn == null or text.contains(ALPHA_DISTANCE_ID) or RegEx.create_from_string("(?m)^mode = [1-9]").search(text):
		return unchanged
	if not text.contains("\n[resource]\n"):
		return unchanged
	var ints: Array[int] = []
	for v in conn.get_string(1).split(",", false):
		ints.append(int(v))
	var at := -1
	for i in range(0, ints.size() - 3, 4):
		if ints[i + 2] == 0 and ints[i + 3] == ALPHA_SCISSOR_PORT:
			at = i
			break
	if at < 0:
		return unchanged
	var id := 2
	for m in RegEx.create_from_string("(?m)^nodes/\\w+/(\\d+)/node = ").search_all(text):
		id = maxi(id, int(m.get_string(1)) + 1)
	var expression := "// GodotFab: alpha test threshold lowered with distance\noutput0 = input0 * mix(1.0, %s, smoothstep(%s, %s, length(VERTEX)));" % [ALPHA_FAR_SCALE, ALPHA_FAR_BEGIN, ALPHA_FAR_END]
	var sub_resource := "[sub_resource type=\"VisualShaderNodeExpression\" id=\"%s\"]\nsize = Vector2(760, 200)\nexpression = \"%s\"\n\n" % [ALPHA_DISTANCE_ID, expression]
	var node := "nodes/fragment/%d/node = SubResource(\"%s\")\nnodes/fragment/%d/position = Vector2(-120, 200)\nnodes/fragment/%d/size = Vector2(760, 200)\nnodes/fragment/%d/input_ports = \"0,0,input0;\"\nnodes/fragment/%d/output_ports = \"0,0,output0;\"\nnodes/fragment/%d/expression = \"%s\"\n" % [id, ALPHA_DISTANCE_ID, id, id, id, id, id, expression]
	# source -> expression -> alpha scissor threshold
	ints[at + 2] = id
	ints[at + 3] = 0
	ints.append_array([id, 0, 0, ALPHA_SCISSOR_PORT])
	var joined := PackedStringArray()
	for v in ints:
		joined.append(str(v))
	var out := text.replace(conn.get_string(0), node + "nodes/fragment/connections = PackedInt32Array(%s)" % ", ".join(joined))
	out = out.replace("\n[resource]\n", "\n" + sub_resource + "[resource]\n")
	return {"text": out, "count": 1}


## The converter's PixelNormalWS/VertexNormalWS node returns the world normal
## in Godot axes (Y up), but the graph works in Unreal axes (its WorldPosition
## node ends with ".xzy"). Masks that read the normal's Z as "facing up" (snow
## on trunks and branches) then read a horizontal axis: one vertical half of
## each trunk gets snow. The node's output is swapped to Unreal axes too.
## Returns {text, count: int}.
static func fix_world_normal_axes(text: String) -> Dictionary:
	var re := RegEx.create_from_string("(//Vertex/PixelNormalWS:\\d+\\([^)\n]*\\)\noutput0 = \\( (?:INV_VIEW_MATRIX|MODEL_MATRIX) \\* vec4\\( NORMAL, 0\\.0\\)\\)\\.xyz;)(?=\n\")")
	var count := re.search_all(text).size()
	if count == 0:
		return {"text": text, "count": 0}
	return {"text": re.sub(text, "$1\noutput0 = output0.xzy;// GodotFab: Unreal axes, Z up", true), "count": count}


## Unreal's Clamp node has a mode; "Clamp Min" ignores Max (its default 1
## stays in the asset). The converter writes every Clamp as clamp(x, min,
## max), so Pivot Painter 2's extent decode (Clamp Min 8: extent = max(x, 8)
## cm) always returns 1 cm. Each wind level's falloff then saturates and
## every branch swings as a rigid piece: long lower branches sweep far while
## the top barely moves. A scalar Clamp whose default min is above its
## default max (with both pins unconnected) can only come from that mode, so
## it becomes max(x, min). Returns {text, count: int}.
static func fix_clamp_min(text: String) -> Dictionary:
	var header := RegEx.create_from_string("\\[sub_resource type=\"VisualShaderNodeClamp\" id=\"([^\"]+)\"\\]\n")
	var defaults_re := RegEx.create_from_string("(?m)^default_input_values = \\[\\s*0,\\s*([-0-9.e]+),\\s*1,\\s*([-0-9.e]+),\\s*2,\\s*([-0-9.e]+)\\s*\\]$")
	var node_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/(\\d+)/node = SubResource\\(\"([^\"]+)\"\\)$")
	var places := {}
	for m in node_re.search_all(text):
		places[m.get_string(3)] = [m.get_string(1), m.get_string(2)]
	var connected := {}
	var conn_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/connections = PackedInt32Array\\(([^)]*)\\)$")
	for m in conn_re.search_all(text):
		var numbers := m.get_string(2).split(",", false)
		for i in range(0, numbers.size() - 3, 4):
			connected["%s/%s/%s" % [m.get_string(1), numbers[i + 2].strip_edges(), numbers[i + 3].strip_edges()]] = true
	var out := text
	var count := 0
	for m in header.search_all(text):
		var id := m.get_string(1)
		var start := out.find(m.get_string(0))
		var end := out.find("\n[", start + m.get_string(0).length())
		end = end if end >= 0 else out.length()
		var block := out.substr(start, end - start)
		var op := RegEx.create_from_string("(?m)^op_type = (\\d+)$").search(block)
		if op and op.get_string(1) != "0":
			continue
		var d := defaults_re.search(block)
		if d == null or float(d.get_string(2)) <= float(d.get_string(3)) or not places.has(id):
			continue
		var stage: String = places[id][0]
		var number: String = places[id][1]
		if connected.has("%s/%s/1" % [stage, number]) or connected.has("%s/%s/2" % [stage, number]):
			continue
		var replacement := "[sub_resource type=\"VisualShaderNodeFloatOp\" id=\"%s\"]\noperator = 6\ndefault_input_values = [0, %s, 1, %s]\n" % [id, d.get_string(1), d.get_string(2)]
		out = out.substr(0, start) + replacement + out.substr(end)
		count += 1
	return {"text": out, "count": count}


## Every vec3 pow node (VisualShaderNodeVectorOp, operator 5, op_type 1:
## what the converter writes for Unreal's Power) becomes an expression node
## with the same ports computing pow(max(base, 0.0), exponent), Unreal's
## PositiveClampedPow. Unconnected inputs keep the node's default value.
## Returns {text, count: int}.
static func fix_unreal_power(text: String) -> Dictionary:
	var header := RegEx.create_from_string("\\[sub_resource type=\"VisualShaderNodeVectorOp\" id=\"([^\"]+)\"\\]\n")
	var node_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/(\\d+)/node = SubResource\\(\"([^\"]+)\"\\)$")
	var vec_re := RegEx.create_from_string("Vector3\\(\\s*([-0-9.e]+),\\s*([-0-9.e]+),\\s*([-0-9.e]+)\\s*\\)")
	var places := {}
	for m in node_re.search_all(text):
		places[m.get_string(3)] = [m.get_string(1), m.get_string(2)]
	var connected := {}
	var conn_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/connections = PackedInt32Array\\(([^)]*)\\)$")
	for m in conn_re.search_all(text):
		var numbers := m.get_string(2).split(",", false)
		for i in range(0, numbers.size() - 3, 4):
			connected["%s/%s/%s" % [m.get_string(1), numbers[i + 2].strip_edges(), numbers[i + 3].strip_edges()]] = true
	var out := text
	var count := 0
	for m in header.search_all(text):
		var id := m.get_string(1)
		var start := out.find(m.get_string(0))
		var end := out.find("\n[", start + m.get_string(0).length())
		end = end if end >= 0 else out.length()
		var block := out.substr(start, end - start)
		if not block.contains("\noperator = 5\n") or not block.contains("\nop_type = 1\n") or not places.has(id):
			continue
		var stage: String = places[id][0]
		var number: String = places[id][1]
		var defaults := vec_re.search_all(block)
		var inputs: Array[String] = []
		for port in 2:
			if connected.has("%s/%s/%d" % [stage, number, port]):
				inputs.append("input%d" % port)
			elif defaults.size() > port:
				var d: RegExMatch = defaults[port]
				inputs.append("vec3(%s, %s, %s)" % [d.get_string(1), d.get_string(2), d.get_string(3)])
			else:
				inputs.append("vec3(%s)" % ("1.0" if port == 0 else "2.0"))
		var expression := "output0 = pow(max(%s, vec3(0.0)), %s);// GodotFab: Unreal PositiveClampedPow" % inputs
		out = out.substr(0, start) + "[sub_resource type=\"VisualShaderNodeExpression\" id=\"%s\"]\nsize = Vector2(980, 300)\nexpression = \"%s\"\n" % [id, expression] + out.substr(end)
		var node_line := "nodes/%s/%s/node = SubResource(\"%s\")\n" % [stage, number, id]
		var at := out.find(node_line)
		if at < 0:
			continue
		at += node_line.length()
		var extra := "nodes/%s/%s/size = Vector2(980, 300)\nnodes/%s/%s/input_ports = \"0,4,input0;1,4,input1;\"\nnodes/%s/%s/output_ports = \"0,4,output0;\"\nnodes/%s/%s/expression = \"%s\"\n" % [stage, number, stage, number, stage, number, stage, number, expression]
		# After the node's other lines (position), before the next node.
		var next := out.find("\nnodes/", at - 1)
		while next >= 0 and out.substr(next + 1).begins_with("nodes/%s/%s/" % [stage, number]):
			next = out.find("\nnodes/", next + 1)
		var insert_at := (next + 1) if next >= 0 else out.length()
		out = out.substr(0, insert_at) + extra + out.substr(insert_at)
		count += 1
	return {"text": out, "count": count}


## Unreal parameter names may contain spaces or dashes ("Level 1 Wind") or
## start with a digit; Godot writes them as-is into the uniform declaration,
## which doesn't compile. Every character outside [A-Za-z0-9_] becomes "_"
## and a name that doesn't start with a letter gets a "p_" prefix (Godot 4.8
## strips leading digits and underscores from parameter names, so a "_"
## prefix alone no longer matches the materials). Returns {text, sanitized:
## {old: new}}.
static func sanitize_parameter_names(text: String) -> Dictionary:
	var name_re := RegEx.create_from_string("(?m)^parameter_name = \"([^\"]*)\"$")
	var invalid_re := RegEx.create_from_string("[^A-Za-z0-9_]")
	var sanitized := {}
	var out := text
	var offset := 0
	for m in name_re.search_all(text):
		var old := m.get_string(1)
		var fixed := invalid_re.sub(old, "_", true)
		if fixed != "" and not ((fixed[0] >= "a" and fixed[0] <= "z") or (fixed[0] >= "A" and fixed[0] <= "Z")):
			fixed = "p_" + fixed
		if fixed == old or fixed == "":
			continue
		sanitized[old] = fixed
		var start := m.get_start(1) + offset
		out = out.substr(0, start) + fixed + out.substr(start + old.length())
		offset += fixed.length() - old.length()
	return {"text": out, "sanitized": sanitized}


## UnrealToGodot replaces macros like COMPILER_HLSL in custom expressions
## with a float ("#if 0.0//COMPILER_HLSL"). Godot's shader preprocessor only
## evaluates integer conditions and rejects the whole shader otherwise
## ("Unknown character '#'" at the first directive). Float literals in
## #if/#elif become 0 or 1. Returns {text, count: int}.
static func fix_preprocessor_conditions(text: String) -> Dictionary:
	var re := RegEx.create_from_string("(#(?:el)?if[ \\t]+)(-?\\d+\\.\\d*)")
	var out := ""
	var last := 0
	var count := 0
	for m in re.search_all(text):
		out += text.substr(last, m.get_start() - last) + m.get_string(1) + ("0" if m.get_string(2).to_float() == 0.0 else "1")
		last = m.get_end()
		count += 1
	out += text.substr(last)
	return {"text": out, "count": count}


## In expressions of the vertex graph only, "INV_VIEW_MATRIX * vec4(<VERTEX,
## NORMAL, TANGENT or BINORMAL>, w)" becomes "MODEL_MATRIX * …": the input is
## in model space there, not view space. Covers the expression sub-resources
## the vertex graph uses and the "nodes/vertex/<n>/expression" copies.
## Returns {text, count: int} (replacements made).
static func fix_vertex_world_space(text: String) -> Dictionary:
	var space_re := RegEx.create_from_string("INV_VIEW_MATRIX(\\s*\\*\\s*vec4\\(\\s*(?:VERTEX|NORMAL|TANGENT|BINORMAL)\\s*,)")
	return _edit_vertex_expressions(text, func(part: String) -> Array:
		var found := space_re.search_all(part).size()
		return [space_re.sub(part, "MODEL_MATRIX$1", true) if found > 0 else part, found])


## Unreal-space transforms the converter leaves out of vertex-graph
## expressions. Its graph works in Unreal space (WorldPosition is turned into
## centimeters, Z up: Godot .xzy * 100), but:
## - "TransformPosition Local->World" multiplies the Unreal-space input by
##   MODEL_MATRIX as if it were Godot meters (ObjectPivotPoint);
## - Pivot Painter's DecodePosition/DecodeAxisVector and ObjectScale are
##   "//Unimplemented" pass-throughs (right only for an instance at the origin);
## - the world position offset is added to VERTEX (Godot, local, meters) as
##   Unreal world centimeters, axes not swapped back.
## Away from the origin, Pivot Painter foliage explodes (branches rotate
## around pivots metres away). Returns {text, count: int}.
static func fix_vertex_unreal_transforms(text: String) -> Dictionary:
	var to_world_point := "output0 = ((MODEL_MATRIX * vec4(input0.xzy / 100.0, 1.0)).xyz * 100.0).xzy;// GodotFab: Unreal local to world"
	var to_world_vector := "output0 = (MODEL_MATRIX * vec4(input0.xzy, 0.0)).xyz.xzy;// GodotFab: Unreal local to world"
	var rules := [
		[RegEx.create_from_string("(//TransformPosition:\\d+\\(ms_PivotPainter2_DecodePostion\\)\\n)//Unimplemented\\noutput0 =  input0;"), "$1" + to_world_point],
		[RegEx.create_from_string("(//Transform:\\d+\\((?:ms_PivotPainter2_DecodeAxisVector|ObjectScale)\\)\\n)//Unimplemented\\noutput0 =  input0;"), "$1" + to_world_vector],
		[RegEx.create_from_string("(//TransformPosition Local->World:\\d+\\([^)]*\\)\\nmat4 ModelMatrix = MODEL_MATRIX;\\n)output0 = \\(ModelMatrix \\* vec4\\(input0, 1\\.0\\)\\)\\.xyz;"), "$1" + to_world_point],
		[RegEx.create_from_string("(//Scale down to Godot Units, Unreal is in cm\\n)output0 = input0 \\+ input1 / 100\\.0;"), "$1output0 = input0 + (inverse(MODEL_MATRIX) * vec4(input1.xzy / 100.0, 0.0)).xyz;// GodotFab: Unreal world offset to local"],
	]
	return _edit_vertex_expressions(text, func(part: String) -> Array:
		var count := 0
		for rule in rules:
			var re: RegEx = rule[0]
			var found := re.search_all(part).size()
			if found > 0:
				part = re.sub(part, rule[1], true)
				count += found
		return [part, count])


## Applies [param edit] (part -> [new part, count]) to the vertex-graph
## expressions of a VisualShader: the expression sub-resources used by the
## vertex graph alone and the "nodes/vertex/<n>/expression" copies.
## Returns {text, count: int}.
static func _edit_vertex_expressions(text: String, edit: Callable) -> Dictionary:
	var node_re := RegEx.create_from_string("(?m)^nodes/(\\w+)/\\d+/node = SubResource\\(\"([^\"]+)\"\\)")
	var stages_by_id := {}
	for m in node_re.search_all(text):
		var stages: Dictionary = stages_by_id.get_or_add(m.get_string(2), {})
		stages[m.get_string(1)] = true
	var ranges: Array = []
	var header := RegEx.create_from_string("\\[sub_resource type=\"VisualShaderNodeExpression\" id=\"([^\"]+)\"\\]")
	for m in header.search_all(text):
		var stages: Dictionary = stages_by_id.get(m.get_string(1), {})
		if stages.size() != 1 or not stages.has("vertex"):
			continue
		var end := text.find("\n[", m.get_end())
		ranges.append([m.get_end(), end if end >= 0 else text.length()])
	var copy_re := RegEx.create_from_string("(?s)\nnodes/vertex/\\d+/expression = \"(?:[^\"\\\\]|\\\\.)*\"")
	for m in copy_re.search_all(text):
		ranges.append([m.get_start(), m.get_end()])
	ranges.sort_custom(func(a, b): return a[0] < b[0])
	var out := ""
	var last := 0
	var count := 0
	for r in ranges:
		if r[0] < last:
			continue
		var part := text.substr(r[0], r[1] - r[0])
		var edited: Array = edit.call(part)
		if edited[1] == 0:
			continue
		out += text.substr(last, r[0] - last) + str(edited[0])
		last = r[1]
		count += int(edited[1])
	out += text.substr(last)
	return {"text": out, "count": count}


## Renames "shader_parameter/<old> = …" lines of a ShaderMaterial after
## [method sanitize_parameter_names] renamed the shader's parameters.
static func rename_material_parameters(text: String, sanitized: Dictionary) -> String:
	var out := text
	for old in sanitized:
		out = out.replace("\nshader_parameter/%s = " % old, "\nshader_parameter/%s = " % sanitized[old])
	return out


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
