@tool
extends RefCounted
## Price and format badges on the cards and the details preview, in fixed
## colors like on fab.com.

const COLORS := {
	"free": [Color("6d7e31"), Color.WHITE],
	"paid": [Color("3c3c3c"), Color.WHITE],
	"format": [Color("1f1f23", 0.85), Color("dddddd")],
}
const BADGE_PADDING := Vector2(8, 3)
const BADGE_INSET := 6


## Shows [param text] on a rounded badge of [param kind], or hides the label
## when the text is empty.
static func style_badge(label: Label, kind: String, text: String) -> void:
	label.text = text
	label.visible = not text.is_empty()
	if text.is_empty():
		return
	var edscale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	var colors: Array = COLORS.get(kind, COLORS.paid)
	var box := StyleBoxFlat.new()
	box.bg_color = colors[0]
	box.set_corner_radius_all(int(4 * edscale))
	box.content_margin_left = BADGE_PADDING.x * edscale
	box.content_margin_right = BADGE_PADDING.x * edscale
	box.content_margin_top = BADGE_PADDING.y * edscale
	box.content_margin_bottom = BADGE_PADDING.y * edscale
	label.add_theme_stylebox_override("normal", box)
	label.add_theme_color_override("font_color", colors[1])
	label.add_theme_font_size_override("font_size", int(11 * edscale))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE


## Puts the badge in the bottom right corner of its parent.
static func place_badge(label: Label, corner := Control.PRESET_BOTTOM_RIGHT) -> void:
	var edscale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	var inset := BADGE_INSET * edscale
	label.set_anchors_and_offsets_preset(corner)
	var size := label.get_combined_minimum_size()
	match corner:
		Control.PRESET_BOTTOM_RIGHT:
			label.offset_left = -size.x - inset
			label.offset_right = -inset
			label.offset_top = -size.y - inset
			label.offset_bottom = -inset
		Control.PRESET_BOTTOM_LEFT:
			label.offset_left = inset
			label.offset_right = size.x + inset
			label.offset_top = -size.y - inset
			label.offset_bottom = -inset
		_:
			label.offset_left = inset
			label.offset_right = size.x + inset
			label.offset_top = inset
			label.offset_bottom = size.y + inset
