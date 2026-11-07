@tool
extends EditorPlugin
## The GodotFab plugin: settings, services (auth, Fab API, jobs) and the
## main screen tab (the gallery).

const Settings = preload("res://addons/godotfab/settings.gd")
const Log = preload("res://addons/godotfab/log.gd")
const Icons = preload("res://addons/godotfab/ui/icons.gd")
const Http = preload("res://addons/godotfab/http.gd")
const EpicAuth = preload("res://addons/godotfab/epic_auth.gd")
const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Jobs = preload("res://addons/godotfab/jobs.gd")
const Gallery = preload("res://addons/godotfab/ui/gallery.gd")

var http: Http
var auth: EpicAuth
var api: FabApi
var jobs: Jobs
var gallery: Control


func _enter_tree() -> void:
	Settings.register()
	Log.info("Plugin enabled")
	http = Http.new(self)
	auth = EpicAuth.new()
	auth.name = "EpicAuth"
	auth.fetch = http.fetch
	add_child(auth)
	api = FabApi.new()
	api.fetch = http.fetch
	api.auth = auth
	jobs = Jobs.new()
	jobs.name = "Jobs"
	jobs.api = api
	jobs.auth = auth
	jobs.configure_from_settings()
	add_child(jobs)
	_init_gallery()
	ProjectSettings.settings_changed.connect(on_settings_changed)
	EditorInterface.get_editor_settings().settings_changed.connect(on_settings_changed)
	Log.info("Download path: %s" % Settings.download_dir_abs())
	if OS.get_environment("GODOTFAB_SMOKE") == "1":
		var smoke = load("res://tests/smoke/editor_smoke.gd").new()
		smoke.plugin = self
		add_child(smoke)


func _exit_tree() -> void:
	ProjectSettings.settings_changed.disconnect(on_settings_changed)
	EditorInterface.get_editor_settings().settings_changed.disconnect(on_settings_changed)
	if gallery:
		gallery.queue_free()
		gallery = null
	Log.info("Plugin exited")


## Settings changed in Godot's dialogs or the addon's own.
func on_settings_changed() -> void:
	Log.level = int(Settings.get_editor(Settings.LOG_LEVEL))
	if jobs:
		jobs.configure_from_settings()
	if gallery and gallery.has_method("refresh_project_index"):
		gallery.refresh_project_index()


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if gallery:
		gallery.visible = visible


func _get_plugin_name() -> String:
	return "Fab"


func _get_plugin_icon() -> Texture2D:
	return Icons.render_svg(Icons.ICON_PATH, EditorInterface.get_editor_scale(), true)


func _init_gallery() -> void:
	gallery = Gallery.new()
	gallery.plugin = self
	gallery.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gallery.hide()
	EditorInterface.get_editor_main_screen().add_child(gallery)


func data_dir() -> String:
	return EditorInterface.get_editor_paths().get_data_dir().path_join("godotfab")


func thumb_cache_dir() -> String:
	return data_dir().path_join("thumbs")


func get_addon_version() -> String:
	var config := ConfigFile.new()
	if config.load("res://addons/godotfab/plugin.cfg") == OK:
		return str(config.get_value("plugin", "version", "unknown"))
	return "unknown"
