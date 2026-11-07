@tool
extends PanelContainer
## Fab main-screen tab: search with filters, scrolling thumbnails and an
## asset details dialog with a Download button. Works like the Asset Store.
## The toggle next to the search switches to the account's Fab library.

const Icons = preload("res://addons/godotfab/ui/icons.gd")
const GalleryItem = preload("res://addons/godotfab/ui/gallery_item.gd")
const SearchView = preload("res://addons/godotfab/ui/search_view.gd")
const LibraryView = preload("res://addons/godotfab/ui/library_view.gd")
const AssetDetails = preload("res://addons/godotfab/ui/asset_details.gd")
const MainMenuButton = preload("res://addons/godotfab/ui/main_menu_button.gd")
const Thumbnails = preload("res://addons/godotfab/ui/thumbnails.gd")
const ProjectAssets = preload("res://addons/godotfab/project_assets.gd")
const Settings = preload("res://addons/godotfab/settings.gd")
const Jobs = preload("res://addons/godotfab/jobs.gd")

const SPINNER_SIZE := 64
const SPINNER_SPEED := 0.75

## Set by the plugin before the gallery enters the tree.
var plugin: EditorPlugin
var api
var auth
var jobs: Jobs
var thumbnails: Thumbnails

var main: VBoxContainer
var search_edit: LineEdit
var library_toggle: Button
var menu_button: Button
var scroll: ScrollContainer
var border: PanelContainer
var search: SearchView
var library: LibraryView
var spinner: TextureRect
var details: AssetDetails

var _busy := false
var _library_mode := false
var _other_text := ""
var _other_scroll := 0
var _updating_theme := false
var _downloaded: Dictionary = {}
var _jobs_badge: Label


func _ready() -> void:
	set_process(false)
	if plugin == null:
		return
	api = plugin.api
	auth = plugin.auth
	jobs = plugin.jobs
	thumbnails = Thumbnails.new(api, plugin.thumb_cache_dir())
	var edscale := EditorInterface.get_editor_scale()
	main = VBoxContainer.new()
	main.add_theme_constant_override("separation", int(10 * edscale))
	add_child(main)

	var search_row := HBoxContainer.new()
	main.add_child(search_row)
	search_edit = LineEdit.new()
	search_edit.placeholder_text = "Search Fab assets (ENTER to search)"
	search_edit.clear_button_enabled = true
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_row.add_child(search_edit)
	library_toggle = Button.new()
	library_toggle.toggle_mode = true
	library_toggle.theme_type_variation = "FlatButton"
	library_toggle.tooltip_text = "Show the Unreal Engine assets in your Fab library"
	search_row.add_child(library_toggle)
	search_row.add_child(VSeparator.new())
	menu_button = MainMenuButton.new()
	search_row.add_child(menu_button)

	search = SearchView.new()
	library = LibraryView.new()
	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	margin.add_child(scroll)
	border = PanelContainer.new()
	border.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	border.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(border)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	border.add_child(body)
	body.add_child(search)
	body.add_child(library)
	library.visible = false
	search.setup(self)
	library.setup(self)
	main.add_child(search.filter_row)
	main.add_child(library.filter_row)
	main.add_child(margin)
	# The container gives the spinner the whole area; the texture stays at
	# its own size in the middle and the control rotates around its center.
	spinner = TextureRect.new()
	spinner.visible = false
	spinner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spinner.texture = Icons.render_logo(SPINNER_SIZE * edscale)
	spinner.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	spinner.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	spinner.modulate = Color(1, 1, 1, 0.7)
	spinner.resized.connect(func(): spinner.pivot_offset = spinner.size / 2)
	margin.add_child(spinner)
	var border_style := StyleBoxEmpty.new()
	border_style.content_margin_left = 15 * edscale
	border_style.content_margin_top = 0
	border_style.content_margin_right = 35 * edscale
	border_style.content_margin_bottom = 15 * edscale
	border.add_theme_stylebox_override("panel", border_style)

	details = AssetDetails.new()
	add_child(details)
	details.setup(self)
	details.download_requested.connect(func(listing, format, scene_pref, engine_version): jobs.start(listing, format, scene_pref, engine_version))
	details.cancel_requested.connect(jobs.cancel)
	details.add_to_library_requested.connect(jobs.add_to_library)
	menu_button.setup(self)

	search_edit.text_changed.connect(_on_search_text_changed)
	search_edit.text_submitted.connect(func(_t): _on_search_submitted())
	library_toggle.toggled.connect(_on_library_toggled)
	_jobs_badge = Label.new()
	_jobs_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_jobs_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_jobs_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_jobs_badge.custom_minimum_size = Vector2.ONE * roundf(16 * edscale)
	library_toggle.add_child(_jobs_badge)
	_jobs_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_jobs_badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_jobs_badge.offset_left = 5 * edscale
	_jobs_badge.offset_right = 5 * edscale
	_jobs_badge.offset_top = -4 * edscale
	_jobs_badge.offset_bottom = -4 * edscale
	scroll.resized.connect(update_columns)
	jobs.job_changed.connect(_on_job_changed)
	jobs.job_finished.connect(func(_uid, _ok): refresh_project_index())
	auth.changed.connect(func(): details.refresh())
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(refresh_project_index)
	refresh_project_index()
	_updating_theme = true
	_update_theme()
	_updating_theme = false


func _process(delta: float) -> void:
	spinner.rotation = fmod(spinner.rotation + TAU * SPINNER_SPEED * delta, TAU)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED:
			if not plugin or not is_visible_in_tree():
				return
			search_edit.grab_focus()
			if _library_mode:
				library.on_shown()
			else:
				search.on_shown()
		NOTIFICATION_THEME_CHANGED:
			if is_node_ready() and plugin and not _updating_theme:
				_updating_theme = true
				_update_theme()
				_updating_theme = false


func _update_theme() -> void:
	add_theme_stylebox_override("panel", get_theme_stylebox("bg", "AssetLib"))
	scroll.add_theme_stylebox_override("panel", get_theme_stylebox("panel", "Tree"))
	search_edit.right_icon = get_theme_icon("Search", "EditorIcons")
	library_toggle.icon = get_theme_icon("AssetStore" if has_theme_icon("AssetStore", "EditorIcons") else "AssetLib", "EditorIcons")
	library_toggle.custom_minimum_size.x = library_toggle.icon.get_width() + get_theme_stylebox("normal", "Button").get_minimum_size().x
	var edscale := EditorInterface.get_editor_scale()
	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = get_theme_color("accent_color", "Editor")
	badge_style.set_corner_radius_all(int(8 * edscale))
	badge_style.set_border_width_all(maxi(1, int(2 * edscale)))
	badge_style.border_color = get_theme_color("base_color", "Editor")
	badge_style.content_margin_left = 3 * edscale
	badge_style.content_margin_right = 3 * edscale
	_jobs_badge.add_theme_stylebox_override("normal", badge_style)
	_jobs_badge.add_theme_color_override("font_color", get_theme_color("base_color", "Editor"))
	_jobs_badge.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	_jobs_badge.add_theme_font_size_override("font_size", int(10 * edscale))
	_update_jobs_badge()


# MARK: layout and state

func content_width() -> float:
	return scroll.size.x - border.get_theme_stylebox("panel").get_minimum_size().x


func update_columns() -> void:
	var min_width := GalleryItem.MIN_WIDTH * EditorInterface.get_editor_scale()
	var separation := search.grid.get_theme_constant("h_separation")
	var available := content_width() - scroll.get_v_scroll_bar().size.x
	var columns := maxi(1, int((available + separation) / (min_width + separation)))
	var width := maxf(min_width, floorf((available + separation) / columns - separation))
	for grid in [search.grid, library.grid]:
		grid.columns = columns
		for item in grid.get_children():
			item.set_width(width)


func set_busy(busy: bool) -> void:
	_busy = busy
	spinner.rotation = 0
	scroll.modulate = Color(1, 1, 1, 0.5) if busy else Color.WHITE
	spinner.visible = busy
	set_process(busy)


func is_busy() -> bool:
	return _busy


func query() -> String:
	return search_edit.text


func _on_search_text_changed(text: String) -> void:
	if _library_mode:
		library.filter()
	elif text.is_empty():
		search.request_search()


func _on_search_submitted() -> void:
	if _library_mode:
		library.filter()
	else:
		search.request_search()


func _on_library_toggled(pressed: bool) -> void:
	_library_mode = pressed
	var text := search_edit.text
	search_edit.text = _other_text
	_other_text = text
	var position := scroll.scroll_vertical
	search.visible = not pressed
	search.filter_row.visible = not pressed
	library.visible = pressed
	library.filter_row.visible = pressed
	search_edit.placeholder_text = "Filter your library" if pressed else "Search Fab assets (ENTER to search)"
	scroll.scroll_vertical = _other_scroll
	_other_scroll = position
	set_busy(false)
	if pressed:
		library.on_shown()
	else:
		search.on_shown()
	update_columns()


func refresh_library() -> void:
	api.clear_library()
	library.refresh(true)
	var result: Dictionary = await api.library()
	if result.ok:
		jobs.retry_waiting_for_library(result.items)
	details.refresh()


# MARK: details, jobs and project state

func open_details(listing: Dictionary) -> void:
	details.show_listing(listing)


func _on_job_changed(uid: String) -> void:
	search.on_job_changed(uid)
	library.on_job_changed(uid)
	if details.visible and str(details.listing.get("uid", "")) == uid:
		details.refresh()
	_update_jobs_badge()


func _update_jobs_badge() -> void:
	var count := jobs.count_active()
	_jobs_badge.visible = count > 0
	_jobs_badge.text = str(count)


func refresh_project_index() -> void:
	_downloaded.clear()
	for entry in ProjectAssets.scan(Settings.download_dir_abs()):
		_downloaded[str(entry.get("uid", ""))] = entry
	search.refresh_downloaded()
	library.refresh_downloaded()
	if details.visible:
		details.refresh()


func is_downloaded(uid: String) -> bool:
	return _downloaded.has(uid)


func downloaded_entry(uid: String) -> Dictionary:
	return _downloaded.get(uid, {})
