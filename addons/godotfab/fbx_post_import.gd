@tool
extends EditorScenePostImportPlugin
## Runs FbxTextureFix on every FBX Godot imports: textures the FBX importer
## could not load (UDIM tiles, missing paths) are resolved from the FBX's own
## references and set on the imported materials. The import option
## "godotfab/fix_fbx_textures" turns it off per file.
##
## Each material of an imported scene (any format) also gets two options in
## the Advanced Import Settings: the strength of its normal map, and reading
## the normal map in DirectX convention (green down, Unreal's), which makes
## the material a shader.

const FbxTextureFix = preload("res://addons/godotfab/fbx_texture_fix.gd")
const Log = preload("res://addons/godotfab/log.gd")
const OPTION := "godotfab/fix_fbx_textures"
const NORMAL_STRENGTH := "godotfab/normal_strength"
const NORMAL_FLIP_Y := "godotfab/normal_flip_y"

## The file being imported: post-process hooks don't get its path, but the
## importer asks for its options right before importing it (scene imports
## run one at a time on the main thread).
var _source := ""


func _get_import_options(path: String) -> void:
	_source = path
	if path.get_extension().to_lower() == "fbx":
		add_import_option(OPTION, true)


## Shown per material in the Advanced Import Settings. They are read back from
## the .import file in _post_process: Godot runs the material hook only for
## some materials (not those of every mesh), so it can't be relied on.
func _get_internal_import_options(category: int) -> void:
	if category == INTERNAL_IMPORT_CATEGORY_MATERIAL:
		add_import_option_advanced(TYPE_FLOAT, NORMAL_STRENGTH, 1.0, PROPERTY_HINT_RANGE, "0,4,0.01")
		add_import_option(NORMAL_FLIP_Y, false)


func _post_process(scene: Node) -> void:
	var source := _source
	var is_fbx := source.get_extension().to_lower() == "fbx"
	var options := material_options(source)
	var prepared := FbxTextureFix.prepare_materials(scene, options, is_fbx)
	var fixes := {}
	if is_fbx and get_option_value(OPTION):
		var names := []
		for material in FbxTextureFix.materials_of(scene):
			names.append(material.resource_name)
		fixes = FbxTextureFix.plan(ProjectSettings.globalize_path(source), names)
	var changed := FbxTextureFix.apply(scene, fixes, options)
	if prepared + changed > 0:
		Log.info("Scene import: %s, %d material(s) adjusted" % [source.get_file(), max(prepared, changed)])


## {material name: {"normal_strength": float, "normal_flip_y": bool}} set in
## the import settings of `source` (only materials with a GodotFab option).
static func material_options(source: String) -> Dictionary:
	var config := ConfigFile.new()
	if source.is_empty() or config.load(source + ".import") != OK:
		return {}
	var subresources = config.get_value("params", "_subresources", {})
	var materials = subresources.get("materials", {}) if subresources is Dictionary else {}
	var out := {}
	for name in materials:
		var settings = materials[name]
		if not settings is Dictionary:
			continue
		var entry := {}
		if settings.has(NORMAL_STRENGTH):
			entry["normal_strength"] = float(settings[NORMAL_STRENGTH])
		if settings.has(NORMAL_FLIP_Y):
			entry["normal_flip_y"] = bool(settings[NORMAL_FLIP_Y])
		if not entry.is_empty():
			out[str(name)] = entry
	return out
