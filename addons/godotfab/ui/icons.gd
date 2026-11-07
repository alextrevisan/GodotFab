@tool
extends RefCounted
## GodotFab logo and icons rendered from SVG at the editor scale (same
## approach as the BlenderKit addon).

## Monochrome editor tab icon, drawn in #e0e0e0 like the built-in editor icons.
const ICON_PATH = "res://addons/godotfab/logo/godotfab-icon.svg"
const LOGO_PATH = "res://addons/godotfab/logo/godotfab-logo.svg"
const LOGO_SVG_SIZE = 64.0
const CACHE_SIZE := 32

static var _rendered: Dictionary = {}


## Renders the SVG at [param scale] times its size. Monochrome icons turn
## dark on light themes. The textures are shared, so they must not be changed.
static func render_svg(path: String, scale: float, monochrome := false) -> Texture2D:
	var dark := monochrome and not is_dark_icon_theme()
	var key := "%s %s %s" % [path, scale, dark]
	if _rendered.has(key):
		return _rendered[key]
	var svg := FileAccess.get_file_as_string(path)
	if dark:
		svg = svg.replace("#e0e0e0", "#5a5a5a")
	var image := Image.new()
	if svg.is_empty() or image.load_svg_from_string(svg, scale) != OK:
		return null
	if _rendered.size() >= CACHE_SIZE:
		_rendered.clear()
	_rendered[key] = ImageTexture.create_from_image(image)
	return _rendered[key]


## The colored logo, [param px] pixels wide.
static func render_logo(px: float) -> Texture2D:
	return render_svg(LOGO_PATH, px / LOGO_SVG_SIZE)


static func is_dark_icon_theme() -> bool:
	if not Engine.is_editor_hint():
		return true
	var settings := EditorInterface.get_editor_settings()
	match settings.get_setting("interface/theme/icon_and_font_color"):
		1: return false
		2: return true
	var base_color: Color = settings.get_setting("interface/theme/base_color")
	return base_color.get_luminance() < 0.5
