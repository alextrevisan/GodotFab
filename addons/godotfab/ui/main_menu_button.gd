@tool
extends Button
## Fab menu at the end of the gallery's search row: the logo with a status
## dot (green logged in, gray out, red after an error), then the editor's
## "more" dots. It opens the account, library refresh, settings and links.

const Icons = preload("res://addons/godotfab/ui/icons.gd")
const SettingsDialog = preload("res://addons/godotfab/ui/settings_dialog.gd")
const LoginDialog = preload("res://addons/godotfab/ui/login_dialog.gd")
const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Settings = preload("res://addons/godotfab/settings.gd")

enum Item { ACCOUNT, LOGIN, LOGOUT, REFRESH, SETTINGS, CHECK, WEBSITE, FOLDER, VERSION }

const LOGO_SIZE := 16
const DOT_RADIUS := 3.5

var gallery: Node
var plugin: EditorPlugin

var _content: HBoxContainer
var _logo: TextureRect
var _dot: Control
var _dots: TextureRect
var _menu: PopupMenu
var _settings: AcceptDialog
var _login: ConfirmationDialog
var _logo_key := ""


func setup(new_gallery: Node) -> void:
	gallery = new_gallery
	plugin = gallery.plugin
	text = ""
	_content = HBoxContainer.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_content)
	_logo = TextureRect.new()
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_logo)
	_dot = Control.new()
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dot.draw.connect(_draw_dot)
	_logo.add_child(_dot)
	_dots = TextureRect.new()
	_dots.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(_dots)

	_menu = PopupMenu.new()
	add_child(_menu)
	_menu.id_pressed.connect(_on_id_pressed)
	_menu.popup_hide.connect(func(): set_pressed_no_signal(false))
	_settings = SettingsDialog.new()
	add_child(_settings)
	_settings.setup(plugin)
	_login = LoginDialog.new()
	add_child(_login)
	_login.setup(plugin.auth)
	toggle_mode = true
	toggled.connect(_on_toggled)
	plugin.auth.changed.connect(refresh)
	refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _content:
		refresh()


func refresh() -> void:
	if _content == null:
		return
	var edscale := EditorInterface.get_editor_scale()
	var logo_size := Vector2.ONE * LOGO_SIZE * edscale
	_logo.custom_minimum_size = logo_size
	var key := str(edscale)
	if key != _logo_key:
		_logo_key = key
		_logo.texture = Icons.render_logo(LOGO_SIZE * edscale)
	var dot_size := Vector2.ONE * (DOT_RADIUS + 1.5) * 2 * edscale
	_dot.position = logo_size - dot_size * 0.6
	_dot.size = dot_size
	_dot.queue_redraw()
	_dots.texture = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	_content.add_theme_constant_override("separation", int(4 * edscale))
	custom_minimum_size.x = _content.get_combined_minimum_size().x + get_theme_stylebox("normal").get_minimum_size().x
	var auth = plugin.auth
	if auth.is_logged_in():
		tooltip_text = "Fab: logged in as %s" % (auth.display_name if auth.display_name else auth.account_id)
	else:
		tooltip_text = "Fab: not logged in"
	if _menu.visible:
		_fill_menu()


func _draw_dot() -> void:
	var edscale := EditorInterface.get_editor_scale()
	var center := _dot.size / 2
	var auth = plugin.auth
	var color: Color
	if not auth.last_error.is_empty():
		color = get_theme_color("error_color", "Editor")
	elif auth.is_logged_in():
		color = get_theme_color("success_color", "Editor")
	else:
		color = get_theme_color("disabled_font_color", "Editor")
	_dot.draw_circle(center, (DOT_RADIUS + 1.5) * edscale, get_theme_color("base_color", "Editor"))
	_dot.draw_circle(center, DOT_RADIUS * edscale, color)


func _on_toggled(pressed: bool) -> void:
	if not pressed:
		_menu.hide()
		return
	_fill_menu()
	_menu.reset_size()
	var pos := get_screen_position() + Vector2(size.x - _menu.size.x, size.y)
	_menu.popup(Rect2i(Vector2i(pos), Vector2i.ZERO))


func open_login() -> void:
	_login.open()


func open_settings() -> void:
	_settings.open()


func _fill_menu() -> void:
	_menu.clear()
	var auth = plugin.auth
	if auth.is_logged_in():
		_menu.add_icon_item(get_theme_icon("Godot", "EditorIcons") if not has_theme_icon("User", "EditorIcons") else get_theme_icon("User", "EditorIcons"), auth.display_name if auth.display_name else auth.account_id, Item.ACCOUNT)
		_menu.set_item_disabled(_menu.get_item_index(Item.ACCOUNT), true)
		_menu.add_item("Log Out", Item.LOGOUT)
	else:
		_menu.add_item("Log In to Epic Games…", Item.LOGIN)
	if not auth.last_error.is_empty():
		_menu.add_item("Last login error: %s" % auth.last_error.left(60), Item.ACCOUNT)
		_menu.set_item_disabled(_menu.item_count - 1, true)
	_menu.add_separator()
	_menu.add_icon_item(get_theme_icon("Reload", "EditorIcons"), "Refresh My Library", Item.REFRESH)
	_menu.set_item_disabled(_menu.get_item_index(Item.REFRESH), not auth.is_logged_in())
	_menu.add_icon_item(get_theme_icon("Tools", "EditorIcons"), "Settings…", Item.SETTINGS)
	_menu.add_item("Check Unreal Setup…", Item.CHECK)
	_menu.add_separator()
	_menu.add_icon_item(get_theme_icon("ExternalLink", "EditorIcons"), "Open fab.com", Item.WEBSITE)
	_menu.add_icon_item(get_theme_icon("Folder", "EditorIcons"), "Show Download Folder", Item.FOLDER)
	_menu.add_separator()
	_menu.add_item("GodotFab %s" % plugin.get_addon_version(), Item.VERSION)
	_menu.set_item_disabled(_menu.item_count - 1, true)


func _on_id_pressed(id: int) -> void:
	match id:
		Item.LOGIN:
			open_login()
		Item.LOGOUT:
			plugin.auth.logout()
			plugin.api.clear_library()
		Item.REFRESH:
			gallery.refresh_library()
		Item.SETTINGS:
			open_settings()
		Item.CHECK:
			_settings.open()
			_settings.call_deferred("_check_setup")
		Item.WEBSITE:
			OS.shell_open(FabApi.HOST)
		Item.FOLDER:
			var dir := Settings.download_dir_abs()
			DirAccess.make_dir_recursive_absolute(dir)
			OS.shell_show_in_file_manager(dir)
