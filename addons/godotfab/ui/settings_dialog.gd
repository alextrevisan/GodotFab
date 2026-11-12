@tool
extends AcceptDialog
## Settings opened from the Fab menu. Changes apply right away. They are
## also in Godot's Project Settings and Editor Settings under Godotfab.

const Settings = preload("res://addons/godotfab/settings.gd")
const Log = preload("res://addons/godotfab/log.gd")
const UnrealBridge = preload("res://addons/godotfab/unreal_bridge.gd")
const Dialogs = preload("res://addons/godotfab/ui/dialogs.gd")

const DIALOG_SIZE := Vector2(700, 640)

var plugin: EditorPlugin

var _grid: GridContainer
var _download_dir: LineEdit
var _format: OptionButton
var _project: LineEdit
var _engine: LineEdit
var _version: LineEdit
var _skinned: OptionButton
var _nanite: OptionButton
var _textures: CheckBox
var _physics: CheckBox
var _scene: OptionButton
var _parallel: SpinBox
var _log_level: OptionButton
var _check_label: Label
var _dir_dialog: EditorFileDialog
var _file_dialog: EditorFileDialog
var _engine_dialog: EditorFileDialog


func setup(new_plugin: EditorPlugin) -> void:
	plugin = new_plugin
	title = "Fab Settings"
	ok_button_text = "Close"
	var edscale := EditorInterface.get_editor_scale()
	min_size = Dialogs.min_size_for(self, Vector2(420, 300))
	var box := Dialogs.scrolling_content(self)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", int(12 * edscale))
	_grid.add_theme_constant_override("v_separation", int(6 * edscale))
	box.add_child(_grid)

	_section("Project", "Saved in project.godot and shared with everyone working on this project.\nAlso in Project Settings → Godotfab.")
	_download_dir = LineEdit.new()
	_download_dir.text_submitted.connect(func(_t): _apply_download_dir())
	_download_dir.focus_exited.connect(_apply_download_dir)
	_dir_dialog = EditorFileDialog.new()
	_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_dir_dialog.dir_selected.connect(func(dir: String):
		_download_dir.text = dir
		_apply_download_dir())
	add_child(_dir_dialog)
	_row("Download to", _browse_row(_download_dir, _dir_dialog), "Folder of the project the assets are imported into.")
	_format = _options(Settings.FORMATS.map(func(f): return f[1]))
	_format.item_selected.connect(func(i): Settings.set_project(Settings.PREFERRED_FORMAT, Settings.FORMATS[i][0]))
	_row("Preferred format", _format, "Which of the listing's formats to download by default. glTF and FBX are imported by Godot directly; Unreal Engine packs are converted with UnrealToGodot.")

	_section("Unreal Engine", "Needed only for assets that exist in Unreal Engine format.")
	_project = LineEdit.new()
	_project.text_submitted.connect(func(_t): _apply_paths())
	_project.focus_exited.connect(_apply_paths)
	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_file_dialog.add_filter("*.uproject", "Unreal project")
	_file_dialog.file_selected.connect(func(path: String):
		_project.text = path
		_apply_paths())
	add_child(_file_dialog)
	_row("Unreal project", _browse_row(_project, _file_dialog), "The .uproject the packs are added to. It must contain the UnrealToGodot plugin with the GodotFab commandlet (see Check setup).")
	_engine = LineEdit.new()
	_engine.text_submitted.connect(func(_t): _apply_paths())
	_engine.focus_exited.connect(_apply_paths)
	_engine_dialog = EditorFileDialog.new()
	_engine_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_engine_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_engine_dialog.dir_selected.connect(func(dir: String):
		_engine.text = dir
		_apply_paths())
	add_child(_engine_dialog)
	_row("Unreal Engine", _browse_row(_engine, _engine_dialog), "Root folder of the engine (the one containing Engine/Binaries).")
	_version = LineEdit.new()
	_version.text_submitted.connect(func(_t): _apply_paths())
	_version.focus_exited.connect(_apply_paths)
	_row("Engine version", _version, "Fab build to download, like UE_5.8. Falls back to the newest build the asset has.")
	_skinned = _options(Settings.SKINNED.map(func(f): return f[1]))
	_skinned.item_selected.connect(func(i): Settings.set_project(Settings.EXPORT_SKINNED, Settings.SKINNED[i][0]))
	_row("Skinned meshes", _skinned, "Export skeletal meshes as skinned (with animations) or as static meshes.")
	_nanite = _options(Settings.NANITE.map(func(f): return f[1]))
	_nanite.item_selected.connect(func(i): Settings.set_project(Settings.EXPORT_NANITE, Settings.NANITE[i][0]))
	_row("Nanite", _nanite, "Coarse mesh exports fast; original mesh keeps every triangle.")
	_textures = CheckBox.new()
	_textures.text = "Export textures"
	_textures.toggled.connect(func(on): Settings.set_project(Settings.EXPORT_TEXTURES, on))
	_row("Textures", _textures, "")
	_physics = CheckBox.new()
	_physics.text = "Export physics"
	_physics.toggled.connect(func(on): Settings.set_project(Settings.EXPORT_PHYSICS, on))
	_row("Physics", _physics, "")
	_scene = _options(Settings.SCENES.map(func(f): return f[1]))
	_scene.item_selected.connect(func(i): Settings.set_project(Settings.EXPORT_SCENE, Settings.SCENES[i][0]))
	_row("Scene to export", _scene, "UnrealToGodot exports one level: the pack's Overview/Demo map plus, beside it, the pack's meshes the map doesn't place (characters and weapons spawned by Blueprints), or a generated level with every mesh.")
	var check := Button.new()
	check.text = "Check Unreal setup"
	check.pressed.connect(_check_setup)
	_row("", check, "")
	_check_label = Label.new()
	_check_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_check_label.custom_minimum_size.x = 420 * edscale
	_check_label.visible = false
	_row("", _check_label, "")

	_section("Editor", "Saved in your editor settings and applies to all your projects.\nAlso in Editor Settings → Godotfab.")
	_parallel = SpinBox.new()
	_parallel.min_value = 1
	_parallel.max_value = 8
	_parallel.value_changed.connect(func(v): Settings.set_editor(Settings.PARALLEL_CHUNKS, int(v)))
	_row("Parallel downloads", _parallel, "Chunks downloaded at the same time.")
	_log_level = _options(Log.Level.keys())
	_log_level.item_selected.connect(func(i): Settings.set_editor(Settings.LOG_LEVEL, i))
	_row("Log level", _log_level, "How much the addon prints to the Output panel.")
	about_to_popup.connect(_load)
	confirmed.connect(_apply_all)


## Opens at a size that fits the screen.
func open() -> void:
	popup_centered(Dialogs.fit_to_screen(self, DIALOG_SIZE))


func _load() -> void:
	_download_dir.text = Settings.download_dir()
	_format.select(Settings.option_index(Settings.FORMATS, Settings.preferred_format()))
	_project.text = Settings.unreal_project()
	_engine.text = Settings.unreal_engine()
	_version.text = Settings.engine_version()
	_skinned.select(Settings.option_index(Settings.SKINNED, Settings.get_project(Settings.EXPORT_SKINNED)))
	_nanite.select(Settings.option_index(Settings.NANITE, Settings.get_project(Settings.EXPORT_NANITE)))
	_textures.set_pressed_no_signal(bool(Settings.get_project(Settings.EXPORT_TEXTURES)))
	_physics.set_pressed_no_signal(bool(Settings.get_project(Settings.EXPORT_PHYSICS)))
	_scene.select(Settings.option_index(Settings.SCENES, Settings.get_project(Settings.EXPORT_SCENE)))
	_parallel.set_value_no_signal(int(Settings.get_editor(Settings.PARALLEL_CHUNKS)))
	_log_level.select(int(Settings.get_editor(Settings.LOG_LEVEL)))
	_check_label.visible = false


func _apply_all() -> void:
	_apply_download_dir()
	_apply_paths()


func _apply_download_dir() -> void:
	var dir := _download_dir.text.strip_edges()
	if dir.is_empty():
		return
	if dir != Settings.download_dir():
		Settings.set_project(Settings.DOWNLOAD_DIR, dir)
		plugin.on_settings_changed()


func _apply_paths() -> void:
	var changed := false
	# The Unreal paths belong to this computer (editor settings); the version is shared.
	for pair in [[Settings.UNREAL_PROJECT, _project], [Settings.UNREAL_ENGINE, _engine]]:
		var value: String = pair[1].text.strip_edges()
		if value != str(Settings.get_editor(pair[0])):
			Settings.set_editor(pair[0], value)
			changed = true
	var version := _version.text.strip_edges()
	if version != Settings.engine_version():
		Settings.set_project(Settings.ENGINE_VERSION, version)
		changed = true
	if changed:
		plugin.on_settings_changed()


func _check_setup() -> void:
	_apply_paths()
	var result: Dictionary = UnrealBridge.check_setup(Settings.unreal_engine(), Settings.unreal_project())
	_check_label.text = "\n".join(result.messages)
	_check_label.add_theme_color_override("font_color", get_theme_color("success_color" if result.ok else "warning_color", "Editor"))
	_check_label.visible = true


func _browse_row(edit: LineEdit, dialog: EditorFileDialog) -> HBoxContainer:
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var browse := Button.new()
	browse.icon = get_theme_icon("FolderBrowse", "EditorIcons")
	browse.theme_type_variation = "EditorInspectorButton"
	browse.pressed.connect(func():
		if dialog.file_mode == EditorFileDialog.FILE_MODE_OPEN_FILE:
			dialog.current_path = edit.text.strip_edges()
		else:
			dialog.current_dir = edit.text.strip_edges()
		dialog.popup_file_dialog())
	var row := HBoxContainer.new()
	row.add_child(edit)
	row.add_child(browse)
	return row


func _section(text: String, tooltip: String) -> void:
	var edscale := EditorInterface.get_editor_scale()
	for i in 2:
		var label := Label.new()
		if i == 0:
			label.text = text
			label.tooltip_text = tooltip
			label.mouse_filter = Control.MOUSE_FILTER_PASS
			label.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
		if _grid.get_child_count() > 0:
			label.custom_minimum_size.y = 24 * edscale
			label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_grid.add_child(label)


func _row(text: String, control: Control, tooltip: String) -> void:
	var label := Label.new()
	label.text = text
	label.tooltip_text = tooltip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	control.tooltip_text = tooltip
	control.custom_minimum_size.x = 260 * EditorInterface.get_editor_scale()
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(label)
	_grid.add_child(control)


func _options(items: Array) -> OptionButton:
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	return option
