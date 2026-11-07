@tool
extends RefCounted
## Sizing shared by the addon's dialogs: the wanted size at the editor
## scale, never more than a fraction of the screen the editor is on.

const SCREEN_FRACTION := 0.85


## [param wanted] is the size at editor scale 1; the result is clamped to
## SCREEN_FRACTION of the usable screen and never below the window's min_size.
static func fit_to_screen(window: Window, wanted: Vector2) -> Vector2i:
	var edscale := EditorInterface.get_editor_scale()
	var size := wanted * edscale
	var screen := Vector2.ZERO
	var parent_window := window.get_parent().get_window() if window.get_parent() else null
	if parent_window:
		screen = Vector2(DisplayServer.screen_get_usable_rect(parent_window.current_screen).size)
	if screen.x <= 0 or screen.y <= 0:
		screen = Vector2(DisplayServer.screen_get_usable_rect().size)
	if screen.x > 0 and screen.y > 0:
		size = size.min(screen * SCREEN_FRACTION)
	return Vector2i(size.max(Vector2(window.min_size)))


## The window's minimum: [param wanted] at the editor scale, but at most
## half the screen, so a large editor scale can't push the dialog off it.
static func min_size_for(window: Window, wanted: Vector2) -> Vector2i:
	var edscale := EditorInterface.get_editor_scale()
	var size := wanted * edscale
	var screen := Vector2(DisplayServer.screen_get_usable_rect().size)
	if screen.x > 0 and screen.y > 0:
		size = size.min(screen * 0.5)
	return Vector2i(size)


## Wraps the dialog's content in a vertical ScrollContainer and returns the
## container the content goes into.
static func scrolling_content(window: Window) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	window.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return content
