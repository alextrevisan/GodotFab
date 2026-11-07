@tool
extends Button
## A card of the results grid: thumbnail, title, price and format badges, a
## job progress bar and a downloaded/error icon, in the editor's button
## colors with rounded corners; a border shows on hover and focus.

signal selected(listing: Dictionary)

const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Jobs = preload("res://addons/godotfab/jobs.gd")
const Badges = preload("res://addons/godotfab/ui/badges.gd")

const MIN_WIDTH := 200
const GAP := 16
const CORNER_RADIUS := 8
const TITLE_PADDING := Vector2(10, 6)
const FRAME_WIDTH := 2
const PROGRESS_HEIGHT := 4
const STATES := ["normal", "hover", "pressed", "hover_pressed"]
const TYPE_ICONS := {"3d-model": "MeshInstance3D", "environment": "WorldEnvironment", "material": "StandardMaterial3D", "animation": "AnimationPlayer", "audio": "AudioStreamPlayer", "hdri": "WorldEnvironment", "vfx": "GPUParticles3D"}

var listing: Dictionary = {}

var _thumb_clip: Panel
var _thumb: TextureRect
var _status_icon: TextureRect
var _progress_track: ColorRect
var _progress_bar: ColorRect
var _price: Label
var _formats: Label
var _state_label: Label
var _title: Label
var _frame: Panel
var _width := 0.0
var _hovered := false
var _downloaded := false
var _job: Dictionary = {}
var _texture: Texture2D
var _thumbnail_failed := false
var _updating_theme := false
static var _styles: Dictionary = {}


func _init() -> void:
	toggle_mode = false
	focus_mode = Control.FOCUS_ALL
	_thumb_clip = Panel.new()
	_thumb_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_thumb_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_thumb_clip)
	_thumb = TextureRect.new()
	_thumb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_thumb_clip.add_child(_thumb)
	_status_icon = TextureRect.new()
	_status_icon.visible = false
	_status_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_status_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_thumb.add_child(_status_icon)
	_progress_track = ColorRect.new()
	_progress_track.visible = false
	_progress_track.color = Color(0, 0, 0, 0.5)
	_progress_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb.add_child(_progress_track)
	_progress_bar = ColorRect.new()
	_progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_track.add_child(_progress_bar)
	_state_label = Label.new()
	_state_label.visible = false
	_thumb.add_child(_state_label)
	_price = Label.new()
	_thumb.add_child(_price)
	_formats = Label.new()
	_thumb.add_child(_formats)
	_title = Label.new()
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_title)
	_frame = Panel.new()
	_frame.visible = false
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)


func _ready() -> void:
	var edscale := EditorInterface.get_editor_scale()
	if _width == 0.0:
		_width = MIN_WIDTH * edscale
	pressed.connect(func(): selected.emit(listing))
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	focus_entered.connect(_update_frame)
	focus_exited.connect(_update_frame)
	_thumb.resized.connect(_place_badges)
	_apply_theme()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	match what:
		NOTIFICATION_THEME_CHANGED:
			if not _updating_theme:
				_apply_theme()
		NOTIFICATION_RESIZED:
			_layout()


func setup(new_listing: Dictionary) -> void:
	listing = new_listing
	if is_node_ready():
		_update()


func set_width(width: float) -> void:
	_width = width
	if is_node_ready():
		_update_size()


func set_thumbnail(texture: Texture2D) -> void:
	_texture = texture
	_thumbnail_failed = texture == null
	if is_node_ready():
		_update_thumbnail()


func set_downloaded(downloaded: bool) -> void:
	_downloaded = downloaded
	if is_node_ready():
		_update_job()


func set_job(job: Dictionary) -> void:
	_job = job
	if is_node_ready():
		_update_job()


func _update() -> void:
	var title := str(listing.get("title", ""))
	_title.text = title
	var seller := FabApi.seller_name(listing)
	tooltip_text = "%s\nby %s" % [title, seller] if seller else title
	var kind := str(listing.get("distributionMethod", ""))
	if not kind.is_empty():
		tooltip_text += "\n" + kind.capitalize().replace("_", " ")
	var price := FabApi.price_label(listing)
	Badges.style_badge(_price, "free" if price == "Free" else "paid", price)
	var tags := PackedStringArray()
	for code in FabApi.formats_of(listing):
		if code in FabApi.ALL_FORMATS:
			tags.append(FabApi.FORMAT_LABELS.get(code, code))
	Badges.style_badge(_formats, "format", " · ".join(tags))
	_place_badges()
	_update_size()
	_update_job()
	_update_thumbnail()


func _place_badges() -> void:
	Badges.place_badge(_price, Control.PRESET_BOTTOM_RIGHT)
	Badges.place_badge(_formats, Control.PRESET_BOTTOM_LEFT)


func _apply_theme() -> void:
	_updating_theme = true
	var styles := _shared_styles()
	for state in STATES:
		add_theme_stylebox_override(state, styles[state])
	add_theme_stylebox_override("focus", styles.focus)
	_thumb_clip.add_theme_stylebox_override("panel", styles.mask)
	_title.add_theme_stylebox_override("normal", styles.title)
	_progress_bar.color = get_theme_color("accent_color", "Editor")
	var edscale := EditorInterface.get_editor_scale()
	_status_icon.custom_minimum_size = Vector2.ONE * 16 * edscale
	_status_icon.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_status_icon.offset_left = -22 * edscale
	_status_icon.offset_right = -6 * edscale
	_status_icon.offset_top = 6 * edscale
	_status_icon.offset_bottom = 22 * edscale
	_progress_track.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_progress_track.offset_top = -PROGRESS_HEIGHT * edscale
	_progress_bar.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_state_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_state_label.offset_left = 6 * edscale
	_state_label.offset_top = 6 * edscale
	_state_label.add_theme_font_size_override("font_size", int(11 * edscale))
	_state_label.add_theme_color_override("font_color", Color.WHITE)
	_state_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_state_label.add_theme_constant_override("shadow_offset_x", 1)
	_state_label.add_theme_constant_override("shadow_offset_y", 1)
	_update_frame()
	_update()
	_updating_theme = false


func _shared_styles() -> Dictionary:
	var edscale := EditorInterface.get_editor_scale()
	var bases: Array = STATES.map(func(state): return get_theme_stylebox(state, "PanelBackgroundButton"))
	var key := "%s %s" % [edscale, bases.map(func(base): return base.get_instance_id())]
	if _styles.get("key") == key:
		return _styles
	_styles = {"key": key, "focus": StyleBoxEmpty.new()}
	var radius := int(CORNER_RADIUS * edscale)
	for i in STATES.size():
		var box: StyleBoxFlat = bases[i].duplicate() if bases[i] is StyleBoxFlat else StyleBoxFlat.new()
		box.set_corner_radius_all(radius)
		box.set_content_margin_all(0)
		_styles[STATES[i]] = box
	var mask := StyleBoxFlat.new()
	mask.bg_color = Color.WHITE
	mask.corner_radius_top_left = radius
	mask.corner_radius_top_right = radius
	_styles.mask = mask
	var title_box := StyleBoxEmpty.new()
	title_box.content_margin_left = TITLE_PADDING.x * edscale
	title_box.content_margin_right = TITLE_PADDING.x * edscale
	title_box.content_margin_top = TITLE_PADDING.y * edscale
	title_box.content_margin_bottom = TITLE_PADDING.y * edscale
	_styles.title = title_box
	return _styles


func _update_size() -> void:
	custom_minimum_size = Vector2(_width, _width * 0.75 + _title.get_combined_minimum_size().y)
	_layout()


func _layout() -> void:
	var width := size.x
	var thumb_height := width * 0.75
	_thumb_clip.position = Vector2.ZERO
	_thumb_clip.size = Vector2(width, thumb_height)
	_title.position = Vector2(0, thumb_height)
	_title.size = Vector2(width, size.y - thumb_height)


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_update_frame()


func _update_frame() -> void:
	_frame.visible = has_focus() or _hovered
	if not _frame.visible:
		return
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_corner_radius_all(int(CORNER_RADIUS * EditorInterface.get_editor_scale()))
	box.set_border_width_all(maxi(1, int(FRAME_WIDTH * EditorInterface.get_editor_scale())))
	box.border_color = get_theme_color("accent_color", "Editor") if has_focus() else Color(get_theme_color("mono_color", "Editor"), 0.35)
	_frame.add_theme_stylebox_override("panel", box)


func _update_thumbnail() -> void:
	if _texture != null:
		_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_thumb.texture = _texture
	elif _thumbnail_failed:
		_thumb.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		_thumb.texture = get_theme_icon(TYPE_ICONS.get(str(listing.get("listingType", "")), "File"), "EditorIcons")
	else:
		_thumb.texture = null


func _update_job() -> void:
	var state: int = int(_job.get("state", -1))
	var active := state in Jobs.ACTIVE
	_progress_track.visible = active
	_progress_bar.anchor_right = clampf(float(_job.get("progress", 0.0)), 0.0, 1.0)
	_state_label.visible = active or state == Jobs.State.NEEDS_LIBRARY or state == Jobs.State.NEEDS_LOGIN
	if _state_label.visible:
		var message := str(_job.get("message", ""))
		_state_label.text = Jobs.state_label(state) + ("\n" + message if message else "")
	var failed := state == Jobs.State.ERROR
	_status_icon.visible = failed or (_downloaded and not active)
	if failed:
		_status_icon.texture = get_theme_icon("StatusError", "EditorIcons")
		_status_icon.tooltip_text = "Failed: %s" % _job.get("error", "")
	else:
		_status_icon.texture = get_theme_icon("StatusSuccess", "EditorIcons")
		_status_icon.tooltip_text = "In the project"
