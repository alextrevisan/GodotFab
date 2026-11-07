@tool
extends ConfirmationDialog
## Epic login: the browser shows a JSON page with an authorizationCode after
## signing in; the user pastes it (or the whole page) here.

const EpicAuth = preload("res://addons/godotfab/epic_auth.gd")
const Dialogs = preload("res://addons/godotfab/ui/dialogs.gd")

const DIALOG_SIZE := Vector2(520, 340)

var auth: EpicAuth
var _code: TextEdit
var _error: Label
var _open_button: Button


func setup(new_auth: EpicAuth) -> void:
	auth = new_auth
	title = "Log in to Epic Games"
	ok_button_text = "Log In"
	min_size = Dialogs.min_size_for(self, Vector2(360, 240))
	var edscale := EditorInterface.get_editor_scale()
	var box := Dialogs.scrolling_content(self)
	box.add_theme_constant_override("separation", int(8 * edscale))
	var steps := Label.new()
	steps.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	steps.text = "1. Open the Epic login page in your browser and sign in.\n2. The page then shows a short JSON text with an \"authorizationCode\".\n3. Copy that code (or the whole text) and paste it below. The code expires in a few minutes."
	box.add_child(steps)
	_open_button = Button.new()
	_open_button.text = "Open login page in browser"
	_open_button.icon = get_theme_icon("ExternalLink", "EditorIcons")
	_open_button.pressed.connect(func(): OS.shell_open(EpicAuth.login_url()))
	box.add_child(_open_button)
	_code = TextEdit.new()
	_code.placeholder_text = "Paste the authorizationCode here"
	_code.custom_minimum_size.y = 80 * edscale
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(_code)
	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
	_error.visible = false
	box.add_child(_error)
	get_ok_button().pressed.connect(_on_ok)
	about_to_popup.connect(func():
		_error.visible = false
		_code.text = ""
		_code.grab_focus.call_deferred())


## Opens at a size that fits the screen.
func open() -> void:
	popup_centered(Dialogs.fit_to_screen(self, DIALOG_SIZE))


func _on_ok() -> void:
	var text := _code.text.strip_edges()
	if text.is_empty():
		return
	var result: Dictionary = await auth.sign_in(text)
	if not result.ok:
		_error.text = str(result.error)
		_error.visible = true
		open()
