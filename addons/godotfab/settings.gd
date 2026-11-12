@tool
extends RefCounted
## Project and editor settings of the addon. Project settings live in
## project.godot and are shared with the team; editor settings stay on this
## computer. All of them show in Godot's settings dialogs under "Godotfab".

const Log = preload("res://addons/godotfab/log.gd")

const DOWNLOAD_DIR := "godotfab/downloads/directory"
const PREFERRED_FORMAT := "godotfab/downloads/preferred_format"
const UNREAL_PROJECT := "godotfab/unreal/project_path"
const UNREAL_ENGINE := "godotfab/unreal/engine_path"
const ENGINE_VERSION := "godotfab/unreal/engine_version"
const EXPORT_SKINNED := "godotfab/export/skinned_meshes"
const EXPORT_NANITE := "godotfab/export/nanite"
const EXPORT_TEXTURES := "godotfab/export/export_textures"
const EXPORT_PHYSICS := "godotfab/export/export_physics"
const EXPORT_SCENE := "godotfab/export/scene"
const PARALLEL_CHUNKS := "godotfab/downloads/parallel_chunks"
## Keeps the downloaded chunks after an import, so downloading the asset again
## (to convert it with other options, or after fixing the exporter) needs no network.
const KEEP_DOWNLOADS := "godotfab/downloads/keep_downloaded_files"
const LOG_LEVEL := "godotfab/client/log_level"

## [value, label] pairs for option buttons.
const FORMATS := [["gltf", "glTF (.glb) when available, else Unreal"], ["fbx", "FBX when available, else Unreal"], ["unreal-engine", "Unreal Engine (convert)"]]
const SKINNED := [["skinned", "Export as skinned mesh"], ["static", "Export as static mesh"]]
const NANITE := [["coarse", "Nanite: coarse mesh"], ["original", "Nanite: original mesh"]]
const SCENES := [["auto", "Auto (pack map + its unplaced meshes, else all meshes)"], ["meshes", "All meshes in a grid"]]

## key -> {default, hint, hint_string, editor: bool}
const KEYS := {
	DOWNLOAD_DIR: {"default": "res://fab_assets", "hint": PROPERTY_HINT_DIR},
	PREFERRED_FORMAT: {"default": "gltf", "hint": PROPERTY_HINT_ENUM, "hint_string": "gltf,fbx,unreal-engine"},
	UNREAL_PROJECT: {"default": "", "hint": PROPERTY_HINT_GLOBAL_FILE, "hint_string": "*.uproject", "editor": true},
	UNREAL_ENGINE: {"default": "", "hint": PROPERTY_HINT_GLOBAL_DIR, "editor": true},
	ENGINE_VERSION: {"default": "UE_5.8"},
	EXPORT_SKINNED: {"default": "skinned", "hint": PROPERTY_HINT_ENUM, "hint_string": "skinned,static"},
	EXPORT_NANITE: {"default": "coarse", "hint": PROPERTY_HINT_ENUM, "hint_string": "coarse,original"},
	EXPORT_TEXTURES: {"default": true},
	EXPORT_PHYSICS: {"default": true},
	EXPORT_SCENE: {"default": "auto", "hint": PROPERTY_HINT_ENUM, "hint_string": "auto,meshes"},
	PARALLEL_CHUNKS: {"default": 4, "hint": PROPERTY_HINT_RANGE, "hint_string": "1,8,1", "editor": true},
	KEEP_DOWNLOADS: {"default": true, "editor": true},
	LOG_LEVEL: {"default": Log.Level.INFO, "hint": PROPERTY_HINT_ENUM, "hint_string": "ERROR,WARNING,INFO,VERBOSE,DEBUG", "editor": true},
}


static func register() -> void:
	for key in KEYS:
		var info: Dictionary = KEYS[key]
		if info.get("editor", false):
			_add_editor_setting(key, info)
		else:
			_add_project_setting(key, info)
	Log.level = get_editor(LOG_LEVEL)


static func _add_project_setting(key: String, info: Dictionary) -> void:
	var default = info.default
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default)
	ProjectSettings.add_property_info({"name": key, "type": typeof(default),
		"hint": info.get("hint", PROPERTY_HINT_NONE), "hint_string": info.get("hint_string", "")})
	ProjectSettings.set_initial_value(key, default)
	ProjectSettings.set_as_basic(key, true)


static func _add_editor_setting(key: String, info: Dictionary) -> void:
	if not Engine.is_editor_hint():
		return
	var settings := EditorInterface.get_editor_settings()
	var default = info.default
	if not settings.has_setting(key):
		settings.set_setting(key, default)
	settings.add_property_info({"name": key, "type": typeof(default),
		"hint": info.get("hint", PROPERTY_HINT_NONE), "hint_string": info.get("hint_string", "")})
	settings.set_initial_value(key, default, false)


static func get_project(key: String) -> Variant:
	if ProjectSettings.has_setting(key):
		return ProjectSettings.get_setting(key)
	return KEYS[key].default


static func set_project(key: String, value: Variant) -> void:
	ProjectSettings.set_setting(key, value)
	ProjectSettings.save()


static func get_editor(key: String) -> Variant:
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if settings.has_setting(key):
			return settings.get_setting(key)
	return KEYS[key].default


static func set_editor(key: String, value: Variant) -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(key, value)
	if key == LOG_LEVEL:
		Log.level = int(value)


static func download_dir() -> String:
	return str(get_project(DOWNLOAD_DIR))


static func download_dir_abs() -> String:
	return ProjectSettings.globalize_path(download_dir())


static func preferred_format() -> String:
	return str(get_project(PREFERRED_FORMAT))


static func unreal_project() -> String:
	return str(get_editor(UNREAL_PROJECT))


static func unreal_engine() -> String:
	return str(get_editor(UNREAL_ENGINE))


static func engine_version() -> String:
	return str(get_project(ENGINE_VERSION))


static func export_options() -> Dictionary:
	return {
		"skinned_as_static": get_project(EXPORT_SKINNED) == "static",
		"nanite_original": get_project(EXPORT_NANITE) == "original",
		"export_textures": bool(get_project(EXPORT_TEXTURES)),
		"export_physics": bool(get_project(EXPORT_PHYSICS)),
		"scene": str(get_project(EXPORT_SCENE)),
	}


## Index of [param value] in a [value, label] list, 0 if missing.
static func option_index(options: Array, value: Variant) -> int:
	for i in options.size():
		if options[i][0] == value:
			return i
	return 0
