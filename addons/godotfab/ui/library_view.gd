@tool
extends VBoxContainer
## The account's Fab library (Unreal Engine format), shown by the gallery's
## library toggle, with the same cards as the search.

const FabApi = preload("res://addons/godotfab/fab_api.gd")
const GalleryItem = preload("res://addons/godotfab/ui/gallery_item.gd")

const SORTS := [["title", "Title A–Z"], ["-title", "Title Z–A"], ["seller", "Seller"]]
const KINDS := [["", "All kinds"], ["ASSET_PACK", "Asset packs"], ["COMPLETE_PROJECT", "Complete projects"], ["CODE_PLUGIN", "Code plugins"]]
const KIND_LABELS := {"ASSET_PACK": "Asset pack", "COMPLETE_PROJECT": "Complete project", "CODE_PLUGIN": "Code plugin"}

var gallery: Node
## Shown by the gallery above the results in library mode: the same kind of
## filters as the search, except Free only (everything here is owned).
var filter_row: HFlowContainer
var grid: GridContainer
var items: Dictionary = {}
var sort_option: OptionButton
var type_option: OptionButton
var kind_option: OptionButton
var engine_option: OptionButton
var downloaded_check: CheckBox

var _message: Label
var _button: Button
var _loaded := false
var _loading := false


func setup(new_gallery: Node) -> void:
	gallery = new_gallery
	var edscale := EditorInterface.get_editor_scale()
	add_theme_constant_override("separation", int(20 * edscale))
	filter_row = HFlowContainer.new()
	filter_row.visible = false
	filter_row.add_theme_constant_override("h_separation", int(12 * edscale))
	filter_row.add_theme_constant_override("v_separation", int(6 * edscale))
	sort_option = _labeled_option("Sort:", SORTS)
	type_option = _labeled_option("Type:", [["", "All types"]])
	kind_option = _labeled_option("Kind:", KINDS)
	engine_option = _labeled_option("Engine:", [["", "Any engine"]])
	engine_option.tooltip_text = "Only assets with a build for this Unreal Engine version."
	downloaded_check = CheckBox.new()
	downloaded_check.text = "In project"
	downloaded_check.tooltip_text = "Show only the assets already imported into this project."
	filter_row.add_child(downloaded_check)
	sort_option.item_selected.connect(func(_i): _filter())
	type_option.item_selected.connect(func(_i): _filter())
	kind_option.item_selected.connect(func(_i): _filter())
	engine_option.item_selected.connect(func(_i): _filter())
	downloaded_check.toggled.connect(func(_on): _filter())
	_message = Label.new()
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_message)
	_button = Button.new()
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.visible = false
	add_child(_button)
	grid = GridContainer.new()
	grid.add_theme_constant_override("h_separation", int(GalleryItem.GAP * edscale))
	grid.add_theme_constant_override("v_separation", int(GalleryItem.GAP * edscale))
	add_child(grid)
	gallery.auth.account_changed.connect(func():
		_loaded = false
		if is_visible_in_tree():
			refresh())


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


static func _selected_value(option: OptionButton) -> String:
	return str(option.get_item_metadata(maxi(0, option.selected))) if option.item_count > 0 else ""


## Rebuilds an option list with "All" plus [param values], keeping the
## selection when it still exists.
static func _refill_option(option: OptionButton, all_label: String, values: Array, labels := {}) -> void:
	var selected := _selected_value(option)
	option.clear()
	option.add_item(all_label)
	option.set_item_metadata(0, "")
	for value in values:
		option.add_item(str(labels.get(value, value)))
		option.set_item_metadata(option.item_count - 1, str(value))
		if str(value) == selected:
			option.select(option.item_count - 1)


func on_shown() -> void:
	if not _loaded:
		refresh()
	else:
		_filter()


func refresh(force := false) -> void:
	if _loading:
		return
	if not gallery.auth.is_logged_in():
		_clear()
		_show_message("Log in to see the Unreal Engine assets in your Fab library.", "Log In…", gallery.menu_button.open_login)
		return
	_loading = true
	_show_message("Loading your library…")
	gallery.set_busy(true)
	var result: Dictionary = await gallery.api.library(force)
	_loading = false
	gallery.set_busy(false)
	if not is_inside_tree():
		return
	if not result.ok:
		_clear()
		_show_message("Could not load the library: %s" % result.error, "Retry", refresh.bind(true))
		return
	_loaded = true
	_clear()
	if result.items.is_empty():
		_show_message("Your Fab library has no Unreal Engine assets yet.", "Open fab.com", func(): OS.shell_open(FabApi.HOST))
		return
	_message.visible = false
	_button.visible = false
	var types := {}
	var engines := {}
	for item in result.items:
		if item is Dictionary:
			types[str(item.get("listingType", ""))] = true
			for version in FabApi.engine_versions_of(item.get("projectVersions", []) if item.get("projectVersions") is Array else []):
				engines[version] = true
	var type_values := types.keys()
	type_values.sort()
	_refill_option(type_option, "All types", type_values)
	var engine_values := FabApi.engine_versions_of([{"engineVersions": engines.keys()}])
	_refill_option(engine_option, "Any engine", engine_values)
	for item in result.items:
		var listing := library_item_to_listing(item)
		var uid: String = listing.uid
		if uid.is_empty() or items.has(uid):
			continue
		var card := GalleryItem.new()
		grid.add_child(card)
		card.setup(listing)
		card.selected.connect(gallery.open_details)
		card.set_downloaded(gallery.is_downloaded(uid))
		card.set_job(gallery.jobs.get_job(uid))
		items[uid] = card
		gallery.thumbnails.request(listing, func(texture):
			if is_instance_valid(card):
				card.set_thumbnail(texture))
	_filter()
	gallery.update_columns()


## A library item in the shape of a search listing, so the cards and the
## details dialog work the same.
static func library_item_to_listing(item: Dictionary) -> Dictionary:
	var images: Array = []
	var raw_images = item.get("images")
	for image in (raw_images if raw_images is Array else []):
		if image is Dictionary and image.has("url"):
			images.append({"url": image.url, "width": int(image.get("width", 0)), "height": int(image.get("height", 0))})
	return {
		"uid": FabApi.listing_uid_of(item),
		"title": str(item.get("title", "")),
		"thumbnails": [{"images": images, "mediaUrl": images[0].url if not images.is_empty() else ""}],
		"isFree": true,
		"user": {"sellerName": str(item.get("seller", ""))},
		"listingType": str(item.get("listingType", "")),
		"distributionMethod": str(item.get("distributionMethod", "")),
		"assetFormats": [{"assetFormatType": {"code": FabApi.UNREAL_FORMAT, "name": "Unreal Engine"}}],
		"description": str(item.get("description", "")),
		"_library_item": item,
	}


func _filter() -> void:
	var text: String = gallery.query().strip_edges().to_lower()
	var type := _selected_value(type_option)
	var kind := _selected_value(kind_option)
	var engine := _selected_value(engine_option)
	var only_downloaded := downloaded_check.button_pressed
	for uid in items:
		var card = items[uid]
		var listing: Dictionary = card.listing
		var item: Dictionary = listing.get("_library_item", {})
		var shown := text.is_empty() or str(listing.get("title", "")).to_lower().contains(text) or FabApi.seller_name(listing).to_lower().contains(text)
		shown = shown and (type.is_empty() or str(item.get("listingType", "")) == type)
		shown = shown and (kind.is_empty() or str(item.get("distributionMethod", "")) == kind)
		shown = shown and (engine.is_empty() or engine in FabApi.engine_versions_of(item.get("projectVersions", []) if item.get("projectVersions") is Array else []))
		shown = shown and (not only_downloaded or gallery.is_downloaded(uid))
		card.visible = shown
	_sort_cards()


## Reorders the grid's children by the selected sort.
func _sort_cards() -> void:
	var sort := _selected_value(sort_option)
	var cards := grid.get_children()
	cards.sort_custom(func(a, b): return _card_before(a, b, sort))
	for i in cards.size():
		grid.move_child(cards[i], i)


static func _card_before(a, b, sort: String) -> bool:
	var ta := str(a.listing.get("title", "")).to_lower()
	var tb := str(b.listing.get("title", "")).to_lower()
	if sort == "-title":
		return ta > tb
	if sort == "seller":
		var sa := FabApi.seller_name(a.listing).to_lower()
		var sb := FabApi.seller_name(b.listing).to_lower()
		return sa < sb if sa != sb else ta < tb
	return ta < tb


## Number of cards passing the filters.
func visible_count() -> int:
	var n := 0
	for uid in items:
		if items[uid].visible:
			n += 1
	return n


func filter() -> void:
	_filter()


func on_job_changed(uid: String) -> void:
	if items.has(uid):
		items[uid].set_job(gallery.jobs.get_job(uid))
		items[uid].set_downloaded(gallery.is_downloaded(uid))


func refresh_downloaded() -> void:
	for uid in items:
		items[uid].set_downloaded(gallery.is_downloaded(uid))


func _clear() -> void:
	items.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()


func _show_message(text: String, button_text := "", action := Callable()) -> void:
	_message.text = text
	_message.visible = true
	_button.text = button_text
	_button.visible = not button_text.is_empty()
	for connection in _button.pressed.get_connections():
		_button.pressed.disconnect(connection.callable)
	if action.is_valid():
		_button.pressed.connect(action)
