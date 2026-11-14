@tool
extends RefCounted
## Fixes the materials of an imported FBX whose textures Godot's FBX importer
## could not load, using the references read from the FBX itself (FbxRefs):
## - UDIM textures (`Body_BaseColor.<UDIM>.png`, one file per UV tile, which
##   Godot doesn't support) become a shader that picks the tile from the UV;
## - a texture missing at the path the FBX names (an author's absolute path,
##   a file renamed in the pack) is looked up in the pack: same file name
##   anywhere, else a texture whose name matches the material and the slot;
## - an opacity texture (TransparencyFactor), which StandardMaterial3D has no
##   slot for, makes the material a shader that cuts the surface with it.
## - subsurface and specular maps, which the FBX format can't reference, are
##   taken from files named like the base color (Body_BaseColor -> Body_SSS,
##   Body_Specular) in its folder; they make the material a shader too.
## Headless-safe and static; FbxPostImport calls it from the import.

const FbxRefs = preload("res://addons/godotfab/fbx_refs.gd")
const Log = preload("res://addons/godotfab/log.gd")

const MANIFEST_FILE := ".godotfab.json"
const TEXTURE_EXTENSIONS := ["png", "jpg", "jpeg", "tga", "exr", "webp", "tif", "tiff", "bmp", "hdr"]
const UDIM_TOKEN := "<UDIM>"
## Name keywords of each slot, for the fallback search (lowercase).
const SLOT_KEYWORDS := {
	"albedo": ["basecolor", "base_color", "albedo", "diffuse"],
	"normal": ["normal"],
	"orm": ["occlusionroughnessmetallic", "orm"],
	"opacity": ["opacity", "alpha"],
}
## Slots Godot's FBX importer drops even when the file is found: ORM maps
## come as ShininessExponent / ReflectionFactor, opacity as TransparencyFactor.
const GODOT_IGNORED_SLOTS := ["orm", "opacity"]
## Slots the FBX format has no property for, looked up next to the base
## color by name (see sibling_entry), with the words that name them.
const SIBLING_WORDS := {
	"sss": ["SSS", "Subsurface", "SubsurfaceScattering", "Scattering"],
	"specular": ["Specular"],
}
## Name parts that say nothing about which material a texture belongs to.
## Slot words are left out too: every base color texture shares "base" and "color".
const GENERIC_TOKENS := ["tex", "texture", "textures", "map", "light", "dark", "png", "jpg", "low", "high", "final",
	"base", "color", "colour", "basecolor", "albedo", "diffuse", "normal", "opacity", "alpha", "orm", "occlusion", "roughness", "metallic"]


# MARK: plan

## What to fix, per FBX material name: {material: {slot: entry}}, where an
## entry is {"udim": {tile_index: abs_path}} or {"file": abs_path}. Slots
## Godot resolves on its own are left out (ORM and opacity never are), except in a material with an
## opacity texture: it becomes a shader, which needs every texture. A
## material with nothing to fix is absent. `fbx_path` is absolute.
## `scene_materials` names the materials of the imported scene: those the FBX
## gives no texture get the textures named like the mesh or the material.
static func plan(fbx_path: String, scene_materials: Array = []) -> Dictionary:
	var refs := FbxRefs.parse(fbx_path)
	if not refs.ok:
		return {}
	return plan_from_refs(fbx_path, refs.materials, scene_materials)


static func plan_from_refs(fbx_path: String, materials: Dictionary, scene_materials: Array = []) -> Dictionary:
	var fbx_dir := fbx_path.get_base_dir()
	var pack_root := pack_root_of(fbx_dir)
	var pack_textures: Array[String] = []
	_collect_textures(pack_root, pack_textures)
	var out := {}
	var cleared := {}
	for material in materials:
		var slots := []
		for ref in materials[material]:
			slots.append(slot_of(str(ref.property), str(ref.relative) + " " + str(ref.file)))
		var every := slots.has("opacity")
		var fixes := {}
		for i in materials[material].size():
			var ref: Dictionary = materials[material][i]
			var slot: String = slots[i]
			if slot.is_empty() or fixes.has(slot):
				continue
			var entry := _resolve(fbx_dir, ref, material, slot, pack_textures, every)
			if not entry.is_empty():
				fixes[slot] = entry
		for slot in fixes:
			if fixes[slot].has("clear"):
				cleared[fixes[slot].clear] = int(cleared.get(fixes[slot].clear, 0)) + 1
		_add_siblings(fbx_dir, materials[material], slots, fixes)
		_complete_slots(fbx_dir, materials[material], slots, fixes)
		if not fixes.is_empty():
			out[material] = fixes
	for material in scene_materials:
		if not _plan_key(out, str(material)).is_empty() or not _plan_key(materials, str(material)).is_empty():
			continue
		var fixes := _textures_named_like(fbx_path, str(material), pack_textures)
		if not fixes.is_empty():
			out[str(material)] = fixes
	for name in cleared:
		Log.warning("FBX import: %s references \"%s\", which is not an image, for %d texture(s); those slots are left empty (the FBX doesn't carry its textures)" % [fbx_path.get_file(), name, cleared[name]])
	return out


## Maps the FBX can't reference (subsurface, specular) found next to the
## material's base color: same name with only the slot word swapped
## (`Body_BaseColor.<UDIM>.png` -> `Body_SSS.<UDIM>.png`), same folder.
static func _add_siblings(fbx_dir: String, refs: Array, slots: Array, fixes: Dictionary) -> void:
	var albedo := slots.find("albedo")
	if albedo < 0:
		return
	var location := _albedo_location(fbx_dir, refs[albedo], fixes.get("albedo", {}))
	if location.is_empty():
		return
	for slot in SIBLING_WORDS:
		if fixes.has(slot):
			continue
		var entry := sibling_entry(location.dir, location.name, SIBLING_WORDS[slot])
		if not entry.is_empty():
			fixes[slot] = entry


## {dir, name} of the base color file ("name" may hold <UDIM>); {} if unknown.
static func _albedo_location(fbx_dir: String, ref: Dictionary, fix: Dictionary) -> Dictionary:
	var relative := str(ref.relative)
	var name := (relative if not relative.is_empty() else str(ref.file)).get_file()
	if fix.has("udim"):
		for tile in fix.udim:
			return {"dir": str(fix.udim[tile]).get_base_dir(), "name": name}
		return {}
	if fix.has("file"):
		return {"dir": str(fix.file).get_base_dir(), "name": str(fix.file).get_file()}
	if not relative.is_empty() and FileAccess.file_exists(fbx_dir.path_join(relative)):
		var path := fbx_dir.path_join(relative).simplify_path()
		return {"dir": path.get_base_dir(), "name": path.get_file()}
	if FileAccess.file_exists(fbx_dir.path_join(name)):
		return {"dir": fbx_dir, "name": name}
	return {}


## Slots completed from the names of the textures, for the maps an FBX often
## leaves out (only the normal map referenced, say): base color, normal, ORM.
const NAMED_SLOTS := ["albedo", "normal", "orm"]
## Last name part(s) of a texture -> its slot ("T_Rock_01_A", "Crate_Base_Color").
const SLOT_SUFFIXES := {
	"a": "albedo", "bc": "albedo", "basecolor": "albedo", "basecolour": "albedo", "albedo": "albedo",
	"diffuse": "albedo", "diff": "albedo", "d": "albedo", "col": "albedo", "color": "albedo", "colour": "albedo",
	"n": "normal", "nrm": "normal", "nor": "normal", "norm": "normal", "normal": "normal", "normalgl": "normal", "normaldx": "normal",
	"orm": "orm", "arm": "orm", "occlusionroughnessmetallic": "orm",
}
## Name prefixes that say what an asset is, not which one (T_, SM_, M_...).
const ASSET_PREFIXES := ["t", "tx", "tex", "sm", "sk", "s", "m", "mi", "mat"]


## [stem, slot] of a texture name without extension: "T_Rock_01_A" ->
## ["T_Rock_01", "albedo"]; [] when its last part names no handled slot.
static func texture_slot_suffix(basename: String) -> Array:
	var parts := basename.replace("-", "_").replace(" ", "_").replace(".", "_").split("_", false)
	if parts.size() < 2:
		return []
	for count in [2, 1]:
		if parts.size() <= count:
			continue
		var suffix := "".join(parts.slice(parts.size() - count)).to_lower()
		if SLOT_SUFFIXES.has(suffix):
			var cut := basename.length()
			for i in count:
				cut = maxi(basename.rfind("_", cut - 1), maxi(basename.rfind("-", cut - 1), basename.rfind(" ", cut - 1)))
			return [basename.substr(0, cut), SLOT_SUFFIXES[suffix]] if cut > 0 else []
	return []


## A name reduced for comparison: no type prefix, no separators, lowercase
## ("SM_Rock_01" and "T_Rock_01" -> "rock01").
static func stem_key(name: String) -> String:
	var parts := name.replace("-", "_").replace(" ", "_").replace(".", "_").split("_", false)
	if parts.size() > 1 and parts[0].to_lower() in ASSET_PREFIXES:
		parts = parts.slice(1)
	return "".join(parts).to_lower()


## Base color, normal and ORM maps found next to a texture the material does
## reference: same name, other slot suffix (T_Pallet_Normal -> T_Pallet_BaseColor).
static func _complete_slots(fbx_dir: String, refs: Array, slots: Array, fixes: Dictionary) -> void:
	var known: Array[String] = []
	for i in refs.size():
		var fix: Dictionary = fixes.get(slots[i], {})
		if fix.has("file"):
			known.append(str(fix.file))
			continue
		var relative := str(refs[i].relative)
		var name := (relative if not relative.is_empty() else str(refs[i].file)).get_file()
		if not relative.is_empty() and FileAccess.file_exists(fbx_dir.path_join(relative)):
			known.append(fbx_dir.path_join(relative).simplify_path())
		elif not name.is_empty() and FileAccess.file_exists(fbx_dir.path_join(name)):
			known.append(fbx_dir.path_join(name))
	for path in known:
		var own := texture_slot_suffix(path.get_file().get_basename())
		if own.is_empty() and str(fixes.get("albedo", {}).get("file", "")) == path and _names_no_slot(path.get_file().get_basename()):
			own = [path.get_file().get_basename(), "albedo"]
		if own.is_empty():
			continue
		for file in DirAccess.get_files_at(path.get_base_dir()):
			if not file.get_extension().to_lower() in TEXTURE_EXTENSIONS:
				continue
			var other := texture_slot_suffix(file.get_basename())
			if other.is_empty() or str(other[0]).to_lower() != str(own[0]).to_lower():
				continue
			if other[1] in NAMED_SLOTS and not slots.has(other[1]) and not fixes.has(other[1]):
				fixes[other[1]] = {"file": path.get_base_dir().path_join(file)}


## For a material the FBX gives no texture: the pack's textures named like the
## FBX file or the material ("SM_Rock_01" -> T_Rock_01_A, _N, _ORM), the
## nearest to the FBX first. {} when none.
static func _textures_named_like(fbx_path: String, material: String, pack_textures: Array[String]) -> Dictionary:
	var keys := []
	for name in [fbx_path.get_file().get_basename(), material.get_slice(":", material.get_slice_count(":") - 1)]:
		var key := stem_key(name)
		if key.length() >= 3 and not key in keys:
			keys.append(key)
	var fixes := {}
	var best := {}
	for path in pack_textures:
		var named := texture_slot_suffix(path.get_file().get_basename())
		if named.is_empty() or not named[1] in NAMED_SLOTS or not stem_key(named[0]) in keys:
			continue
		var closeness := _shared_prefix(path, fbx_path)
		if closeness > int(best.get(named[1], -1)):
			best[named[1]] = closeness
			fixes[named[1]] = {"file": path}
	return fixes


static func _shared_prefix(a: String, b: String) -> int:
	var n := 0
	while n < mini(a.length(), b.length()) and a[n] == b[n]:
		n += 1
	return n


## The entry ({"udim": ...} / {"file": ...}) of the first existing file named
## like `albedo_name` with its base color word replaced by one of `words`.
static func sibling_entry(dir: String, albedo_name: String, words: Array) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("(?i)(base_?colou?r|albedo|diffuse)")
	var m := regex.search(albedo_name)
	if m == null:
		return {}
	var files := DirAccess.get_files_at(dir)
	for word in words:
		var name: String = albedo_name.substr(0, m.get_start()) + word + albedo_name.substr(m.get_end())
		if name.contains(UDIM_TOKEN):
			var tiles := udim_tiles(dir, name)
			if not tiles.is_empty():
				return {"udim": tiles}
			continue
		for file in files:
			if file.to_lower() == name.to_lower():
				return {"file": dir.path_join(file)}
	return {}


## The material slot an FBX texture property feeds; "" when unhandled.
static func slot_of(property: String, file_names: String) -> String:
	var p := property.to_lower()
	var names := file_names.to_lower()
	if p in ["diffusecolor", "maya|basecolor", "base_color", "maya|base_color", "diffusefactor"]:
		return "albedo"
	if p in ["normalmap", "bump", "maya|normalcamera", "normal_camera"]:
		return "normal"
	if p in ["transparencyfactor", "transparentcolor", "opacity", "maya|opacity"]:
		return "opacity"
	for keyword in SLOT_KEYWORDS.orm:
		if names.contains(keyword):
			return "orm"
	return ""


## {} when Godot finds the file itself (unless `every`: then that file);
## else {"udim": ...} or {"file": ...}, or {} too when nothing usable is in
## the pack.
static func _resolve(fbx_dir: String, ref: Dictionary, material: String, slot: String, pack_textures: Array[String], every := false) -> Dictionary:
	var relative := str(ref.relative)
	var file := str(ref.file)
	var name := (relative if not relative.is_empty() else file).get_file()
	if name.is_empty():
		return {}
	# A reference to something that isn't an image (an exporter's `.fbm`
	# media folder): Godot binds whatever embedded image shares that name,
	# so the slot is emptied rather than showing a wrong texture.
	if not name.contains(UDIM_TOKEN) and not name.get_extension().to_lower() in TEXTURE_EXTENSIONS:
		return {"clear": name}
	if name.contains(UDIM_TOKEN):
		var tiles := udim_tiles(fbx_dir.path_join(relative).get_base_dir() if not relative.is_empty() else fbx_dir, name)
		if tiles.is_empty():
			for path in pack_textures:
				if _udim_regex(name).search(path.get_file()):
					tiles = udim_tiles(path.get_base_dir(), name)
					break
		return {"udim": tiles} if not tiles.is_empty() else {}
	# Where Godot's FBX importer looks: the relative path, then the name next to the FBX.
	# It never applies ORM or opacity textures, even when it finds them.
	var keep := every or slot in GODOT_IGNORED_SLOTS
	if not relative.is_empty() and FileAccess.file_exists(fbx_dir.path_join(relative)):
		return {"file": fbx_dir.path_join(relative).simplify_path()} if keep else {}
	if FileAccess.file_exists(fbx_dir.path_join(name)):
		return {"file": fbx_dir.path_join(name)} if keep else {}
	for path in pack_textures:
		if path.get_file().to_lower() == name.to_lower():
			return {"file": path}
	var candidate := find_candidate(pack_textures, material, slot, name)
	return {"file": candidate} if not candidate.is_empty() else {}


## {tile index (0 for 1001): absolute path} of the files matching a UDIM name.
static func udim_tiles(dir: String, udim_name: String) -> Dictionary:
	var tiles := {}
	var regex := _udim_regex(udim_name)
	for file in DirAccess.get_files_at(dir):
		var m := regex.search(file)
		if m:
			var tile := int(m.get_string(1)) - 1001
			if tile >= 0 and tile < 100:
				tiles[tile] = dir.path_join(file)
	return tiles


static func _udim_regex(udim_name: String) -> RegEx:
	var parts := udim_name.split(UDIM_TOKEN)
	var pattern := "^"
	for i in parts.size():
		if i > 0:
			pattern += "(1\\d{3})"
		pattern += _escape(parts[i])
	var regex := RegEx.new()
	regex.compile("(?i)" + pattern + "$")
	return regex


static func _escape(text: String) -> String:
	var out := ""
	for c in text:
		out += ("\\" + c) if c in ".^$|?*+()[]{}\\" else c
	return out


## The best texture of the pack for a material's slot: its name must carry a
## keyword of the slot and share a name part with the material (or with the
## missing file's name). "" when nothing qualifies.
static func find_candidate(pack_textures: Array[String], material: String, slot: String, missing_name: String) -> String:
	var material_tokens := _tokens(material.get_slice(":", material.get_slice_count(":") - 1))
	var name_tokens := _tokens(missing_name.get_basename())
	var best := ""
	var best_score := 0
	for path in pack_textures:
		var file := path.get_file().get_basename().to_lower()
		var has_keyword := false
		for keyword in SLOT_KEYWORDS.get(slot, []):
			if file.replace("-", "").contains(keyword):
				has_keyword = true
		# A texture whose name says no slot at all ("T_Mobile_Trees_Trunk") is
		# a base color, but only for a material all of whose words it carries.
		var unnamed := not has_keyword and slot == "albedo" and _names_no_slot(path.get_file().get_basename())
		if not has_keyword and not unnamed:
			continue
		var file_tokens := _tokens(path.get_file().get_basename())
		var dir_tokens := _tokens(path.get_base_dir().get_file())
		var score := 0
		var all_words := not material_tokens.is_empty()
		for t in material_tokens:
			if t in file_tokens:
				score += 10
			elif t in dir_tokens:
				score += 5
			if not t in file_tokens:
				all_words = false
		if unnamed and not all_words:
			continue
		for t in name_tokens:
			if t in file_tokens or t in dir_tokens:
				score += 1
		if score > best_score or (score == best_score and score > 0 and path.length() < best.length()):
			best_score = score
			best = path
	# A single shared word with the missing file's name is too weak a hint.
	return best if best_score >= 2 else ""


## True when a texture name carries no slot suffix or slot keyword.
static func _names_no_slot(basename: String) -> bool:
	if not texture_slot_suffix(basename).is_empty():
		return false
	var file := basename.to_lower().replace("-", "")
	for slot in SLOT_KEYWORDS:
		for keyword in SLOT_KEYWORDS[slot]:
			if file.contains(keyword):
				return false
	for word in SIBLING_WORDS.values():
		for w in word:
			if file.contains(str(w).to_lower()):
				return false
	return true


## Lowercase name parts: split on separators and camel case, digits and
## generic words dropped.
static func _tokens(text: String) -> Array[String]:
	var spaced := ""
	for i in text.length():
		var c := text[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and text[i - 1] == text[i - 1].to_lower() and text[i - 1] != text[i - 1].to_upper():
			spaced += " "
		spaced += c
	var out: Array[String] = []
	for part in spaced.to_lower().replace("_", " ").replace("-", " ").replace(".", " ").replace(":", " ").split(" ", false):
		var word := part.rstrip("0123456789")
		if word.length() >= 2 and not word in GENERIC_TOKENS and not word.is_valid_int():
			out.append(word)
	return out


## The pack folder (the nearest parent holding the GodotFab manifest), else
## the FBX's own folder.
static func pack_root_of(dir: String) -> String:
	var current := dir
	while current != "" and current != current.get_base_dir():
		if FileAccess.file_exists(current.path_join(MANIFEST_FILE)):
			return current
		current = current.get_base_dir()
	return dir


static func _collect_textures(dir: String, out: Array[String]) -> void:
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() in TEXTURE_EXTENSIONS:
			out.append(dir.path_join(file))
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_collect_textures(dir.path_join(sub), out)


# MARK: apply

## Adjusts the imported materials before the fixes, returns how many changed:
## - (`is_fbx`) a normal map with a strength of 0 gets 1: Godot's FBX importer
##   reads a missing BumpFactor as 0, which turns every normal map off;
## - the "normal_strength" of `options` ({material name: {...}}) scales it.
static func prepare_materials(scene: Node, options: Dictionary, is_fbx: bool) -> int:
	var changed := 0
	for material in materials_of(scene):
		if not material is BaseMaterial3D:
			continue
		var m: BaseMaterial3D = material
		var before := m.normal_scale
		if is_fbx and m.normal_scale == 0.0:
			m.normal_scale = 1.0
		var strength: float = options.get(m.resource_name, {}).get("normal_strength", 1.0)
		m.normal_scale *= strength
		if m.normal_scale != before and (m.normal_texture != null or strength != 1.0):
			changed += 1
	return changed


## The distinct materials on the meshes of a scene.
static func materials_of(scene: Node) -> Array:
	var out := []
	for node in _all_nodes(scene):
		var mesh = node.mesh if node is MeshInstance3D or node is ImporterMeshInstance3D else null
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var material = mesh.surface_get_material(i) if mesh is Mesh else mesh.get_surface_material(i)
			if material and not out.has(material):
				out.append(material)
	return out


## Applies a plan to an imported scene; returns how many materials changed.
## `options` is {material name: {"normal_flip_y": bool}} from the import
## settings: a material whose normal map is flipped becomes a shader too.
static func apply(scene: Node, fixes: Dictionary, options: Dictionary = {}) -> int:
	if fixes.is_empty() and not _any_flip(options):
		return 0
	var done := {}
	var changed := 0
	for node in _all_nodes(scene):
		var mesh = null
		if node is MeshInstance3D:
			mesh = node.mesh
		elif node is ImporterMeshInstance3D:
			mesh = node.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var material: Material = mesh.surface_get_material(i) if mesh is Mesh else mesh.get_surface_material(i)
			if material == null:
				continue
			var key := _plan_key(fixes, material.resource_name)
			var flip: bool = options.get(material.resource_name, {}).get("normal_flip_y", false)
			if key.is_empty() and not flip:
				continue
			if not done.has(material):
				done[material] = fixed_material(material, fixes.get(key, {}), flip)
				if done[material] != material:
					changed += 1
			if mesh is Mesh:
				mesh.surface_set_material(i, done[material])
			else:
				mesh.set_surface_material(i, done[material])
	return changed


static func _any_flip(options: Dictionary) -> bool:
	for name in options:
		if options[name].get("normal_flip_y", false):
			return true
	return false


static func _plan_key(fixes: Dictionary, material_name: String) -> String:
	if fixes.has(material_name):
		return material_name
	var short := material_name.get_slice(":", material_name.get_slice_count(":") - 1)
	for key in fixes:
		if str(key).get_slice(":", str(key).get_slice_count(":") - 1) == short:
			return key
	return ""


## The material with its fixes: a shader when any slot is UDIM or there is
## an opacity texture or a normal map to flip (`flip_normal_y`: DirectX
## convention), else a copy of the StandardMaterial3D with the found
## textures. Slots that already have a texture keep it.
static func fixed_material(material: Material, fixes: Dictionary, flip_normal_y := false) -> Material:
	var needs_shader := fixes.has("opacity") or fixes.has("sss") or fixes.has("specular") or flip_normal_y
	for slot in fixes:
		if fixes[slot].has("udim"):
			needs_shader = true
	if needs_shader:
		return shader_material(material, fixes, flip_normal_y)
	if not material is BaseMaterial3D:
		return material
	var out: BaseMaterial3D = material.duplicate()
	var touched := false
	for slot in fixes:
		if fixes[slot].has("clear"):
			touched = _clear_slot(out, slot) or touched
			continue
		var texture := _load_texture(fixes[slot].get("file", ""))
		if texture == null:
			continue
		match slot:
			"albedo":
				if out.albedo_texture == null:
					out.albedo_texture = texture
					# Leaves and grass: the FBX lost the texture, so it also
					# never said the material is cut out.
					if out.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and _has_alpha(texture):
						out.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					touched = true
			"normal":
				if out.normal_texture == null:
					out.normal_enabled = true
					out.normal_texture = texture
					touched = true
			"orm":
				if out.roughness_texture == null and out.metallic_texture == null:
					_set_orm(out, texture)
					touched = true
	if not touched:
		return material
	if fixes.values().any(func(entry): return not entry.has("clear")):
		Log.info("FBX import: fixed textures of material %s" % material.resource_name)
	return out


## Empties a slot whose FBX reference is invalid; true when it had a texture.
static func _clear_slot(material: BaseMaterial3D, slot: String) -> bool:
	match slot:
		"albedo":
			if material.albedo_texture:
				material.albedo_texture = null
				return true
		"normal":
			if material.normal_texture or material.normal_enabled:
				material.normal_texture = null
				material.normal_enabled = false
				return true
		"orm":
			if material.roughness_texture or material.metallic_texture:
				material.roughness_texture = null
				material.metallic_texture = null
				material.ao_texture = null
				material.ao_enabled = false
				return true
	return false


static func _set_orm(material: BaseMaterial3D, texture: Texture2D) -> void:
	material.ao_enabled = true
	material.ao_texture = texture
	material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.roughness = 1.0
	material.roughness_texture = texture
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.metallic = 1.0
	material.metallic_texture = texture
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE


## A ShaderMaterial sampling each slot's UDIM tiles (or single texture).
## Slots without a fix keep the texture the material already has; the normal
## strength is the material's normal_scale. When a texture of the material
## can't be carried over (separate roughness/metallic maps), the material is
## returned as is.
static func shader_material(material: Material, fixes: Dictionary, flip_normal_y := false) -> Material:
	var existing = _existing_textures(material, fixes)
	if existing == null:
		Log.warning("FBX import: material %s left as is (its textures don't fit the generated shader)" % material.resource_name)
		return material
	var textures: Dictionary = existing
	for slot in ["albedo", "normal", "orm", "opacity", "sss", "specular"]:
		if not fixes.has(slot):
			continue
		var tiles := {}
		if fixes[slot].has("udim"):
			for tile in fixes[slot].udim:
				var texture := _load_texture(fixes[slot].udim[tile])
				if texture:
					tiles[int(tile)] = texture
		else:
			var texture := _load_texture(fixes[slot].get("file", ""))
			if texture:
				tiles[-1] = texture
		if not tiles.is_empty():
			textures[slot] = tiles
	var shader := Shader.new()
	shader.code = udim_shader_code(textures, flip_normal_y)
	var out := ShaderMaterial.new()
	out.resource_name = material.resource_name
	out.shader = shader
	for slot in textures:
		for tile in textures[slot]:
			out.set_shader_parameter(_uniform(slot, tile), textures[slot][tile])
	if material is BaseMaterial3D:
		out.set_shader_parameter("albedo_color", material.albedo_color)
		if textures.has("normal"):
			out.set_shader_parameter("normal_strength", material.normal_scale)
	Log.info("FBX import: material %s is now a shader (%s)" % [material.resource_name, ", ".join(PackedStringArray(textures.keys()))])
	return out


## {slot: {-1: Texture2D}} of the textures a BaseMaterial3D already has for
## the slots `fixes` doesn't cover; null when one can't be expressed by the
## shader (roughness or metallic maps that aren't one ORM texture).
static func _existing_textures(material: Material, fixes: Dictionary) -> Variant:
	var out := {}
	if not material is BaseMaterial3D:
		return out
	var m: BaseMaterial3D = material
	if m.albedo_texture and not fixes.has("albedo"):
		out["albedo"] = {-1: m.albedo_texture}
	if m.normal_enabled and m.normal_texture and not fixes.has("normal"):
		out["normal"] = {-1: m.normal_texture}
	if not fixes.has("orm") and (m.roughness_texture or m.metallic_texture):
		var orm := m.roughness_texture == m.metallic_texture \
			and m.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN \
			and m.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		if not orm:
			return null
		out["orm"] = {-1: m.roughness_texture}
	return out


static func _uniform(slot: String, tile: int) -> String:
	return "%s_tex" % slot if tile < 0 else "%s_%d" % [slot, 1001 + tile]


## Shader code for {slot: {tile: Texture2D}} (tile -1: one texture for all).
## UDIM tile = floor(u) + 10 * floor(v) with v up; Godot's UV.y is 1 - v.
## Opacity cuts the surface (alpha scissor: no sorting issues on hair cards)
## and shows both faces, as cards are usually single planes. `flip_normal_y`
## reads the normal map in DirectX convention (green down), as Unreal does.
static func udim_shader_code(textures: Dictionary, flip_normal_y := false) -> String:
	var hints := {"albedo": "source_color", "normal": "hint_normal", "orm": "hint_default_white", "opacity": "hint_default_white",
		"sss": "hint_default_white", "specular": "hint_default_white"}
	var lines := PackedStringArray(["// Generated by GodotFab for UDIM textures.", "shader_type spatial;", ""])
	if textures.has("opacity"):
		lines[1] = "shader_type spatial;\nrender_mode cull_disabled;"
	lines.append("uniform vec4 albedo_color : source_color = vec4(1.0);")
	if textures.has("normal"):
		lines.append("uniform float normal_strength : hint_range(0.0, 4.0) = 1.0;")
	if textures.has("opacity"):
		lines.append("uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;")
	if textures.has("sss"):
		lines.append("uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;")
	for slot in textures:
		var tiles: Array = textures[slot].keys()
		tiles.sort()
		for tile in tiles:
			lines.append("uniform sampler2D %s : %s, filter_linear_mipmap_anisotropic, repeat_enable;" % [_uniform(slot, tile), hints[slot]])
	lines.append("")
	lines.append("void fragment() {")
	lines.append("\tvec2 uv_dx = dFdx(UV);")
	lines.append("\tvec2 uv_dy = dFdy(UV);")
	lines.append("\tint tile = int(floor(UV.x)) + 10 * int(floor(1.0 - UV.y));")
	for slot in textures:
		lines.append("\tvec4 %s_s = vec4(1.0);" % slot)
		var tiles: Array = textures[slot].keys()
		tiles.sort()
		if tiles.has(-1):
			lines.append("\t%s_s = texture(%s, UV);" % [slot, _uniform(slot, -1)])
		else:
			var first := true
			for tile in tiles:
				lines.append("\t%sif (tile == %d) { %s_s = textureGrad(%s, UV, uv_dx, uv_dy); }" % ["" if first else "else ", tile, slot, _uniform(slot, tile)])
				first = false
	lines.append("\tALBEDO = albedo_color.rgb * %s;" % ("albedo_s.rgb" if textures.has("albedo") else "vec3(1.0)"))
	if textures.has("normal"):
		lines.append("\tNORMAL_MAP = vec3(normal_s.r, 1.0 - normal_s.g, normal_s.b);" if flip_normal_y else "\tNORMAL_MAP = normal_s.rgb;")
		lines.append("\tNORMAL_MAP_DEPTH = normal_strength;")
	if textures.has("orm"):
		lines.append("\tAO = orm_s.r;")
		lines.append("\tROUGHNESS = orm_s.g;")
		lines.append("\tMETALLIC = orm_s.b;")
	if textures.has("opacity"):
		lines.append("\tALPHA = opacity_s.r;")
		lines.append("\tALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;")
	if textures.has("sss"):
		lines.append("\tSSS_STRENGTH = sss_s.r * sss_strength;")
	if textures.has("specular"):
		lines.append("\tSPECULAR = specular_s.r;")
	lines.append("}")
	return "\n".join(lines) + "\n"


static func _load_texture(abs_path: String) -> Texture2D:
	if abs_path.is_empty():
		return null
	var res_path := ProjectSettings.localize_path(abs_path)
	if not res_path.begins_with("res://") or not ResourceLoader.exists(res_path):
		Log.warning("FBX import: texture %s is not imported" % abs_path)
		return null
	return load(res_path) as Texture2D


## True when the texture has transparent pixels.
static func _has_alpha(texture: Texture2D) -> bool:
	var image := texture.get_image()
	if image == null:
		return false
	if image.is_compressed():
		image = image.duplicate()
		if image.decompress() != OK:
			return false
	return image.detect_alpha() != Image.ALPHA_NONE


static func _all_nodes(node: Node) -> Array:
	var out := [node]
	for child in node.get_children():
		out.append_array(_all_nodes(child))
	return out
