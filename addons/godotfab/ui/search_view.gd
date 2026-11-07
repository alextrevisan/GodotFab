@tool
extends VBoxContainer
## The Fab search of the gallery: filters, results and their thumbnails.
## Results load more as they scroll, like fab.com.

const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Log = preload("res://addons/godotfab/log.gd")
const GalleryItem = preload("res://addons/godotfab/ui/gallery_item.gd")

const MORE_SCREENS := 1.0

var gallery: Node
var filter_row: HFlowContainer
var grid: GridContainer
var sort_option: OptionButton
var type_option: OptionButton
var free_check: CheckBox
var downloaded_check: CheckBox
var format_option: OptionButton

var results: Array = []
## uid -> GalleryItem
var items: Dictionary = {}

var _message_box: VBoxContainer
var _message_label: Label
var _message_button: Button
var _message_action: Callable
var _more_box: VBoxContainer
var _more_label: Label
var _more_button: Button
var _started := false
var _search_url := ""
var _search_text := ""
var _next_url := ""
var _loading_more := false
var _more_error := ""
var _generation := 0


func setup(new_gallery: Node) -> void:
	gallery = new_gallery
	var edscale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(20 * edscale))

	filter_row = HFlowContainer.new()
	filter_row.add_theme_constant_override("h_separation", int(12 * edscale))
	filter_row.add_theme_constant_override("v_separation", int(6 * edscale))
	sort_option = _labeled_option("Sort:", FabApi.SORTS)
	type_option = _labeled_option("Type:", FabApi.LISTING_TYPES)
	format_option = _labeled_option("Format:", [["", "Any"], ["gltf", "glTF"], ["fbx", "FBX"], ["unreal-engine", "Unreal Engine"]])
	format_option.tooltip_text = "Only listings that offer this format. glTF and FBX import directly; Unreal Engine packs are converted with UnrealToGodot."
	var checks := HBoxContainer.new()
	filter_row.add_child(checks)
	free_check = CheckBox.new()
	free_check.text = "Free only"
	checks.add_child(free_check)
	downloaded_check = CheckBox.new()
	downloaded_check.text = "In project"
	downloaded_check.tooltip_text = "Show only the results already imported into this project."
	checks.add_child(downloaded_check)

	_message_box = VBoxContainer.new()
	_message_box.visible = false
	_message_box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_message_box)
	_message_label = Label.new()
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_box.add_child(_message_label)
	_message_button = Button.new()
	_message_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_message_button.pressed.connect(func():
		if _message_action.is_valid():
			_message_action.call())
	_message_box.add_child(_message_button)
	grid = GridContainer.new()
	grid.add_theme_constant_override("h_separation", int(GalleryItem.GAP * edscale))
	grid.add_theme_constant_override("v_separation", int(GalleryItem.GAP * edscale))
	add_child(grid)
	_more_box = VBoxContainer.new()
	_more_box.visible = false
	_more_box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_more_box)
	_more_label = Label.new()
	_more_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_more_box.add_child(_more_label)
	_more_button = Button.new()
	_more_button.text = "Retry"
	_more_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_more_button.pressed.connect(func():
		_more_error = ""
		load_more())
	_more_box.add_child(_more_button)

	sort_option.item_selected.connect(func(_i): request_search())
	type_option.item_selected.connect(func(_i): request_search())
	format_option.item_selected.connect(func(_i): request_search())
	free_check.toggled.connect(func(_on): request_search())
	downloaded_check.toggled.connect(func(_on): _apply_downloaded_filter())
	var scroll_bar: VScrollBar = gallery.scroll.get_v_scroll_bar()
	scroll_bar.value_changed.connect(func(_v): on_scrolled())
	scroll_bar.changed.connect(on_scrolled)
	grid.resized.connect(on_scrolled)


func _labeled_option(label_text: String, options: Array) -> OptionButton:
	var box := HBoxContainer.new()
	filter_row.add_child(box)
	var label := Label.new()
	label.text = label_text
	box.add_child(label)
	var option := OptionButton.new()
	for entry in options:
		option.add_item(entry[1])
		option.set_item_metadata(option.item_count - 1, entry[0])
	box.add_child(option)
	return option


func on_shown() -> void:
	if not _started:
		_started = true
		request_search()
	else:
		on_scrolled()


# MARK: search

func request_search(force := false) -> void:
	var text: String = gallery.query()
	var formats := PackedStringArray(FabApi.ALL_FORMATS)
	var format := str(format_option.get_item_metadata(maxi(0, format_option.selected)))
	if not format.is_empty():
		formats = PackedStringArray([format])
	var url := FabApi.build_search_url(text, str(type_option.get_item_metadata(maxi(0, type_option.selected))),
		free_check.button_pressed, str(sort_option.get_item_metadata(maxi(0, sort_option.selected))), formats)
	if url == _search_url and not force:
		return
	_search_url = url
	_search_text = text.strip_edges()
	_message_box.hide()
	_loading_more = false
	_more_error = ""
	_update_more()
	gallery.set_busy(true)
	_generation += 1
	_start_search(url, false, _generation)


func load_more() -> void:
	if _next_url.is_empty() or not _more_error.is_empty() or _loading_more or gallery.is_busy():
		return
	_loading_more = true
	_update_more()
	_start_search(_next_url, true, _generation)


func _start_search(url: String, more: bool, generation: int) -> void:
	var result: Dictionary = await gallery.api.search(url)
	if generation != _generation or not is_inside_tree():
		return
	if not result.ok:
		_search_failed(result.error, more)
		return
	if more:
		_loading_more = false
		_update_more()
	else:
		gallery.set_busy(false)
		_clear_results()
	_next_url = result.next
	_show_results(result.results)
	if not more:
		gallery.scroll.scroll_vertical = 0
	on_scrolled.call_deferred()


func _search_failed(message: String, more: bool) -> void:
	var error := message if message else "unknown error"
	Log.warning("Search failed: %s" % error)
	if more:
		_loading_more = false
		_more_error = error
		_update_more()
		return
	gallery.set_busy(false)
	_clear_results()
	_show_message("Search failed: %s" % error, "Retry", request_search.bind(true))


func _clear_results() -> void:
	items.clear()
	results = []
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	_next_url = ""


func _show_results(page: Array) -> void:
	var added: Array = []
	for listing in page:
		if listing is Dictionary and listing.has("uid") and not items.has(listing.uid):
			added.append(listing)
	results.append_array(added)
	if results.is_empty():
		_show_message("No results for \"%s\"." % _search_text if _search_text else "No assets match the selected filters.")
	else:
		_message_box.hide()
	for listing in added:
		var uid: String = listing.uid
		var item := GalleryItem.new()
		grid.add_child(item)
		item.setup(listing)
		item.selected.connect(gallery.open_details)
		item.set_downloaded(gallery.is_downloaded(uid))
		item.set_job(gallery.jobs.get_job(uid))
		items[uid] = item
		gallery.thumbnails.request(listing, func(texture):
			if is_instance_valid(item):
				item.set_thumbnail(texture))
	_apply_downloaded_filter()
	gallery.update_columns()


func _apply_downloaded_filter() -> void:
	var only_downloaded := downloaded_check.button_pressed
	for uid in items:
		items[uid].visible = not only_downloaded or gallery.is_downloaded(uid)


func on_job_changed(uid: String) -> void:
	if items.has(uid):
		items[uid].set_job(gallery.jobs.get_job(uid))
		items[uid].set_downloaded(gallery.is_downloaded(uid))


func refresh_downloaded() -> void:
	for uid in items:
		items[uid].set_downloaded(gallery.is_downloaded(uid))
	_apply_downloaded_filter()


# MARK: scrolling

func on_scrolled() -> void:
	if not is_visible_in_tree() or items.is_empty():
		return
	var scroll: ScrollContainer = gallery.scroll
	var margin := scroll.size.y * MORE_SCREENS
	var top: float = scroll.scroll_vertical - (grid.global_position.y - gallery.border.global_position.y)
	var bottom: float = top + scroll.size.y
	if grid.size.y < bottom + margin:
		load_more()


func _update_more() -> void:
	_more_box.visible = _loading_more or not _more_error.is_empty()
	_more_label.text = "Loading more…" if _more_error.is_empty() else "Loading more failed: %s" % _more_error
	_more_button.visible = not _more_error.is_empty()


func _show_message(text: String, button_text := "", action := Callable()) -> void:
	_message_label.text = text
	_message_button.text = button_text
	_message_button.visible = not button_text.is_empty()
	_message_action = action
	_message_box.show()
