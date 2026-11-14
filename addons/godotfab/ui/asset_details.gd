@tool
extends AcceptDialog
## Asset details with a preview, description, key parameters and tags, and
## under them the format and scene choosers with the action button. The
## action downloads, cancels, adds to the library, logs in, retries or
## opens the imported scene depending on the job and the account. It isn't
## modal: clicking the editor outside closes it.

signal download_requested(listing: Dictionary, format: String, scene_pref: String, engine_version: String)
signal cancel_requested(uid: String)
signal add_to_library_requested(uid: String)

const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Jobs = preload("res://addons/godotfab/jobs.gd")
const Settings = preload("res://addons/godotfab/settings.gd")
const Badges = preload("res://addons/godotfab/ui/badges.gd")
const UnrealBridge = preload("res://addons/godotfab/unreal_bridge.gd")
const GodotImport = preload("res://addons/godotfab/godot_import.gd")
const Dialogs = preload("res://addons/godotfab/ui/dialogs.gd")

const PREVIEW_SIZE := 320
const STRIP_SIZE := 56
const MAX_STRIP := 6
## Dialog size at editor scale 1, clamped to SCREEN_FRACTION of the screen.
const DIALOG_SIZE := Vector2(980, 640)

var gallery: Node
var listing: Dictionary = {}
var detail: Dictionary = {}

var _preview: TextureRect
var _price: Label
var _strip: HBoxContainer
var _title: Label
var _params: GridContainer
var _description: RichTextLabel
var _tags: Label
var _format: OptionButton
var _scene: OptionButton
var _scene_label: Label
var _engine: OptionButton
var _engine_label: Label
## Unreal builds of the listing from the format endpoint, per uid.
var _unreal_versions: Dictionary = {}
## uid -> whether the account's library has the listing (when known).
var _in_library: Dictionary = {}
var _adding := false
var _action: Button
var _secondary: Button
var _convert_again: Button
var _delete_downloads: Button
var _archive_box: VBoxContainer
var _archive_label: Label
var _archive_folder: LinkButton
var _delete_confirm: ConfirmationDialog
var _status: Label
var _error_box: VBoxContainer
var _error_label: Label
var _log: RichTextLabel
var _open_unreal: Button
var _import_folder: Button
var _web: Button
var _import_dialog: EditorFileDialog
var _detail_uid := ""
var _preview_cache: Dictionary = {}


func setup(new_gallery: Node) -> void:
	gallery = new_gallery
	title = "Asset"
	ok_button_text = "Close"
	exclusive = false
	var edscale := EditorInterface.get_editor_scale()
	min_size = Dialogs.min_size_for(self, Vector2(520, 360))
	# Everything scrolls, so the dialog never has to grow past the screen.
	var content := Dialogs.scrolling_content(self)
	content.add_theme_constant_override("separation", int(12 * edscale))
	var panes := HBoxContainer.new()
	panes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panes.add_theme_constant_override("separation", int(16 * edscale))
	content.add_child(panes)

	var left := VBoxContainer.new()
	left.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	panes.add_child(left)
	var frame := PanelContainer.new()
	frame.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	left.add_child(frame)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE * 0.75) * edscale
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.add_child(_preview)
	_price = Label.new()
	_preview.add_child(_price)
	_preview.resized.connect(func(): Badges.place_badge(_price))
	_strip = HBoxContainer.new()
	_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_child(_strip)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", int(8 * edscale))
	panes.add_child(right)
	_title = Label.new()
	_title.add_theme_font_override("font", get_theme_font("title", "EditorFonts"))
	_title.add_theme_font_size_override("font_size", get_theme_font_size("title_size", "EditorFonts"))
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_title)
	_params = GridContainer.new()
	_params.columns = 2
	_params.add_theme_constant_override("h_separation", int(16 * edscale))
	right.add_child(_params)
	_description = RichTextLabel.new()
	_description.bbcode_enabled = true
	_description.fit_content = true
	_description.scroll_active = false
	_description.selection_enabled = true
	_description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_description.custom_minimum_size.x = 200 * edscale
	right.add_child(_description)
	_tags = Label.new()
	_tags.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tags.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	right.add_child(_tags)

	# Archives the download couldn't extract (.rar, .7z): what to do, and a
	# link that opens the folder they were kept in.
	_archive_box = VBoxContainer.new()
	_archive_box.visible = false
	content.add_child(_archive_box)
	_archive_label = Label.new()
	_archive_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_archive_label.add_theme_color_override("font_color", get_theme_color("warning_color", "Editor"))
	_archive_box.add_child(_archive_label)
	_archive_folder = LinkButton.new()
	_archive_folder.underline = LinkButton.UNDERLINE_MODE_ALWAYS
	_archive_folder.tooltip_text = "Opens the folder in the file manager"
	_archive_folder.pressed.connect(func(): OS.shell_open(_archive_folder.get_meta("folder", "")))
	_archive_box.add_child(_archive_folder)

	_error_box = VBoxContainer.new()
	_error_box.visible = false
	content.add_child(_error_box)
	_error_label = Label.new()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.add_theme_color_override("font_color", get_theme_color("error_color", "Editor"))
	_error_box.add_child(_error_label)
	_log = RichTextLabel.new()
	_log.custom_minimum_size.y = 90 * edscale
	_log.selection_enabled = true
	_log.add_theme_font_override("normal_font", get_theme_font("source", "EditorFonts"))
	_log.add_theme_font_size_override("normal_font_size", int(11 * edscale))
	_error_box.add_child(_log)
	var error_buttons := HBoxContainer.new()
	_error_box.add_child(error_buttons)
	_open_unreal = Button.new()
	_open_unreal.text = "Open in Unreal Editor"
	_open_unreal.tooltip_text = "Opens the pack's map in the Unreal Editor so you can run UnrealToGodot → Export To Godot by hand. Set its output folder, then use Import export folder…"
	_open_unreal.pressed.connect(_open_in_unreal)
	error_buttons.add_child(_open_unreal)
	_import_folder = Button.new()
	_import_folder.text = "Import export folder…"
	_import_folder.pressed.connect(func(): _import_dialog.popup_file_dialog())
	error_buttons.add_child(_import_folder)
	_import_dialog = EditorFileDialog.new()
	_import_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_import_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_import_dialog.dir_selected.connect(_import_export_folder)
	add_child(_import_dialog)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status)
	# Wraps on narrow screens instead of widening the dialog.
	var footer := HFlowContainer.new()
	footer.add_theme_constant_override("h_separation", int(8 * edscale))
	footer.add_theme_constant_override("v_separation", int(6 * edscale))
	footer.alignment = FlowContainer.ALIGNMENT_END
	content.add_child(footer)
	var format_label := Label.new()
	format_label.text = "Format:"
	footer.add_child(format_label)
	_format = OptionButton.new()
	_format.item_selected.connect(func(_i): _update_action())
	footer.add_child(_format)
	_engine_label = Label.new()
	_engine_label.text = "Engine:"
	footer.add_child(_engine_label)
	_engine = OptionButton.new()
	_engine.tooltip_text = "Unreal Engine version of the build to download. Only that build is downloaded."
	footer.add_child(_engine)
	_scene_label = Label.new()
	_scene_label.text = "Scene:"
	footer.add_child(_scene_label)
	_scene = OptionButton.new()
	_scene.tooltip_text = "Level UnrealToGodot exports. Maps show up once the pack is installed in the Unreal project."
	footer.add_child(_scene)
	_delete_downloads = Button.new()
	_delete_downloads.visible = false
	_delete_downloads.icon = get_theme_icon("Remove", "EditorIcons")
	_delete_downloads.tooltip_text = "Deletes the files GodotFab keeps from the download of this asset. Downloading it again then fetches everything from Fab. The asset stays in this project and in the Unreal project."
	_delete_downloads.pressed.connect(_ask_delete_downloads)
	footer.add_child(_delete_downloads)
	_delete_confirm = ConfirmationDialog.new()
	_delete_confirm.title = "Delete downloaded files"
	_delete_confirm.ok_button_text = "Delete"
	_delete_confirm.confirmed.connect(_delete_downloads_now)
	add_child(_delete_confirm)
	_convert_again = Button.new()
	_convert_again.visible = false
	_convert_again.text = "Convert again"
	_convert_again.tooltip_text = "Runs the Unreal conversion again on the pack already installed in the Unreal project and imports the result, without downloading anything."
	_convert_again.pressed.connect(_convert_again_now)
	footer.add_child(_convert_again)
	_secondary = Button.new()
	_secondary.visible = false
	footer.add_child(_secondary)
	_action = Button.new()
	_action.text = "Download"
	_action.pressed.connect(_on_action)
	footer.add_child(_action)
	_web = Button.new()
	_web.text = "View on fab.com"
	_web.icon = get_theme_icon("ExternalLink", "EditorIcons")
	_web.pressed.connect(func(): OS.shell_open(FabApi.listing_page_url(str(listing.get("uid", "")))))
	footer.add_child(_web)
	get_viewport().gui_focus_changed.connect(_on_focus_changed) if is_inside_tree() else null
	focus_exited.connect(_close_if_outside)


func show_listing(new_listing: Dictionary) -> void:
	listing = new_listing
	title = str(listing.get("title", "Asset"))
	_title.text = title
	Badges.style_badge(_price, "free" if FabApi.is_free(listing) else "paid", FabApi.price_label(listing))
	_fill_formats()
	_fill_scenes()
	_fill_engines()
	_fill_params({})
	_description.text = ""
	_tags.text = ""
	_preview.texture = null
	for child in _strip.get_children():
		child.queue_free()
	_update_action()
	popup_centered(dialog_size())
	_detail_uid = str(listing.get("uid", ""))
	_load_preview(FabApi.thumbnail_url(listing, 640), _preview)
	_fetch_detail()
	_fetch_unreal_versions()
	_fetch_library_state()


## The dialog size: DIALOG_SIZE at the editor scale, clamped to the screen.
func dialog_size() -> Vector2i:
	return Dialogs.fit_to_screen(self, DIALOG_SIZE)


## Refreshes the action and status after a job or login change.
func refresh() -> void:
	if visible and not listing.is_empty():
		_update_action()


func _fetch_detail() -> void:
	var uid := str(listing.get("uid", ""))
	_detail_uid = uid
	var result: Dictionary = await gallery.api.listing(uid)
	if _detail_uid != uid or not visible:
		return
	if not result.ok:
		_description.text = "[i]Could not load the details: %s[/i]" % result.error
		return
	detail = result.data
	_description.text = html_to_bbcode(str(detail.get("description", "")))
	_fill_params(detail)
	_fill_tags(detail)
	_fill_strip(detail)
	if FabApi.formats_of(detail).size() > FabApi.formats_of(listing).size():
		listing.assetFormats = detail.get("assetFormats", [])
		_fill_formats()
		_update_action()


func _fill_params(data: Dictionary) -> void:
	for child in _params.get_children():
		child.queue_free()
	var source: Dictionary = data if not data.is_empty() else listing
	var rows := [
		["Seller", FabApi.seller_name(source)],
		["Price", FabApi.price_label(source)],
		["Type", str(source.get("listingType", ""))],
		["Formats", ", ".join(FabApi.formats_of(source).map(func(c): return FabApi.FORMAT_LABELS.get(c, c)))],
	]
	var ratings = source.get("ratings")
	if ratings is Dictionary and int(ratings.get("total", 0)) > 0:
		rows.append(["Rating", "%.1f ★ (%d)" % [float(ratings.get("averageRating", 0)), int(ratings.total)]])
	var published := str(source.get("publishedAt", ""))
	if published:
		rows.append(["Published", published.substr(0, 10)])
	var category = source.get("category")
	if category is Dictionary:
		rows.append(["Category", str(category.get("name", ""))])
	for row in rows:
		if str(row[1]).is_empty():
			continue
		var key := Label.new()
		key.text = row[0]
		key.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
		_params.add_child(key)
		var value := Label.new()
		value.text = str(row[1])
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_params.add_child(value)


func _fill_tags(data: Dictionary) -> void:
	var names := PackedStringArray()
	for tag in data.get("tags", []):
		if tag is Dictionary:
			names.append(str(tag.get("name", "")))
	_tags.text = "Tags: " + ", ".join(names) if names.size() > 0 else ""


func _fill_strip(data: Dictionary) -> void:
	for child in _strip.get_children():
		child.queue_free()
	var medias: Array = data.get("medias", []) if data.get("medias") is Array else []
	var count := 0
	for media in medias:
		if not media is Dictionary or str(media.get("type", "")) != "image":
			continue
		var small := _image_url(media, 144)
		var large := _image_url(media, 960)
		if small.is_empty():
			continue
		var button := Button.new()
		button.custom_minimum_size = Vector2.ONE * STRIP_SIZE * EditorInterface.get_editor_scale()
		button.expand_icon = true
		button.pressed.connect(func(): _load_preview(large, _preview))
		_strip.add_child(button)
		_load_preview(small, button)
		count += 1
		if count >= MAX_STRIP:
			break


static func _image_url(media: Dictionary, min_width: int) -> String:
	return FabApi.thumbnail_url({"thumbnails": [media]}, min_width)


func _load_preview(url: String, target: Control) -> void:
	if url.is_empty():
		return
	var texture: Texture2D = _preview_cache.get(url)
	var uid := _detail_uid
	if texture == null:
		var response: Dictionary = await gallery.api.fetch_bytes(url)
		if not response.ok or not is_instance_valid(target):
			return
		if target == _preview and _detail_uid != uid:
			return # another listing was opened meanwhile
		var image := Image.new()
		var ext := url.get_extension().split("?")[0].to_lower()
		var err := image.load_webp_from_buffer(response.body) if ext == "webp" else (image.load_png_from_buffer(response.body) if ext == "png" else image.load_jpg_from_buffer(response.body))
		if err != OK:
			return
		texture = ImageTexture.create_from_image(image)
		_preview_cache[url] = texture
	if target is TextureRect:
		target.texture = texture
	elif target is Button:
		target.icon = texture


# MARK: formats, scenes and the action

func _fill_formats() -> void:
	_format.clear()
	var offered := FabApi.formats_of(listing)
	var chosen := FabApi.choose_format(listing, Settings.preferred_format())
	var index := 0
	for code in offered:
		_format.add_item(str(FabApi.FORMAT_LABELS.get(code, code)))
		var i := _format.item_count - 1
		_format.set_item_metadata(i, code)
		if not code in FabApi.ALL_FORMATS:
			_format.set_item_disabled(i, true)
		if code == chosen:
			index = i
	if _format.item_count > 0:
		_format.select(index)
	_format.disabled = _format.item_count == 0


func selected_format() -> String:
	if _format.selected < 0:
		return ""
	return str(_format.get_item_metadata(_format.selected))


func _fill_scenes() -> void:
	_scene.clear()
	_scene.add_item("Auto")
	_scene.set_item_metadata(0, "auto")
	var job: Dictionary = gallery.jobs.get_job(str(listing.get("uid", "")))
	for map in job.get("maps", []):
		_scene.add_item(str(map).get_file())
		_scene.set_item_metadata(_scene.item_count - 1, str(map))
	_scene.add_item("All meshes")
	_scene.set_item_metadata(_scene.item_count - 1, "meshes")
	var current := str(job.get("scene_pref", "auto"))
	for i in _scene.item_count:
		if _scene.get_item_metadata(i) == current:
			_scene.select(i)


## Whether the listing is in the account's library (cached library).
func _fetch_library_state() -> void:
	var uid := str(listing.get("uid", ""))
	if not gallery.auth.is_logged_in():
		return
	var result: Dictionary = await gallery.api.library()
	if not result.ok or str(listing.get("uid", "")) != uid:
		return
	_in_library[uid] = not FabApi.library_item_for(result.items, uid).is_empty()
	_update_action()


func _add_to_library_now() -> void:
	var uid := str(listing.get("uid", ""))
	if _adding:
		return
	_adding = true
	_status.text = "Adding to your library…"
	_secondary.disabled = true
	var result: Dictionary = await gallery.api.add_to_library(uid)
	_adding = false
	_secondary.disabled = false
	if str(listing.get("uid", "")) != uid:
		return
	if result.ok:
		_in_library[uid] = true
		gallery.api.clear_library()
		await gallery.api.library(true)
		_update_action()
		_status.text = "Added to your library."
	else:
		# Fab wants the website for this: open the listing there.
		OS.shell_open(FabApi.listing_page_url(uid))
		_update_action()
		_status.text = FabApi.NEEDS_WEB_MESSAGE
		_secondary.visible = true
		_secondary.text = "Refresh library"
		for connection in _secondary.pressed.get_connections():
			_secondary.pressed.disconnect(connection.callable)
		_secondary.pressed.connect(func(): gallery.refresh_library())


## The Unreal builds come from the listing's format endpoint (no login).
func _fetch_unreal_versions() -> void:
	var uid := str(listing.get("uid", ""))
	if _unreal_versions.has(uid) or not FabApi.has_unreal_format(listing):
		return
	var result: Dictionary = await gallery.api.listing_format(uid, FabApi.UNREAL_FORMAT)
	if not result.ok or not visible or str(listing.get("uid", "")) != uid:
		return
	_unreal_versions[uid] = result.versions
	_fill_engines()


func _fill_engines() -> void:
	_engine.clear()
	var uid := str(listing.get("uid", ""))
	var builds: Array = _unreal_versions.get(uid, [])
	if builds.is_empty():
		var library_item: Dictionary = listing.get("_library_item", {})
		builds = library_item.get("projectVersions", []) if library_item.get("projectVersions") is Array else []
	var versions := FabApi.engine_versions_of(builds)
	var configured := Settings.engine_version()
	if versions.is_empty():
		_engine.add_item("Auto (%s)" % configured)
		_engine.set_item_metadata(0, "")
		_engine.disabled = true
		return
	_engine.disabled = false
	var selected := 0
	for version in versions:
		_engine.add_item(str(version))
		_engine.set_item_metadata(_engine.item_count - 1, str(version))
		if version == configured:
			selected = _engine.item_count - 1
	_engine.select(selected)


func selected_engine_version() -> String:
	if _engine.selected < 0:
		return ""
	return str(_engine.get_item_metadata(_engine.selected))


func selected_scene() -> String:
	if _scene.selected < 0:
		return "auto"
	return str(_scene.get_item_metadata(_scene.selected))


func _update_action() -> void:
	var uid := str(listing.get("uid", ""))
	var job: Dictionary = gallery.jobs.get_job(uid)
	var state: int = int(job.get("state", -1))
	var format := selected_format()
	var is_unreal := format == FabApi.UNREAL_FORMAT
	_scene.visible = is_unreal
	_scene_label.visible = is_unreal
	_engine.visible = is_unreal
	_engine_label.visible = is_unreal
	_secondary.visible = false
	_convert_again.visible = false
	_delete_downloads.visible = false
	_error_box.visible = false
	_action.disabled = false
	_action.icon = null
	_format.disabled = state in Jobs.ACTIVE
	var downloaded: Dictionary = gallery.downloaded_entry(uid)
	var logged_in: bool = gallery.auth.is_logged_in()
	for connection in _secondary.pressed.get_connections():
		_secondary.pressed.disconnect(connection.callable)
	if format.is_empty():
		_action.text = "Download"
		_action.disabled = true
		_status.text = "This listing offers no glTF, FBX or Unreal Engine format."
	elif state in Jobs.ACTIVE:
		_action.text = "Cancel"
		_status.text = Jobs.state_label(state) + (": " + str(job.message) if job.get("message", "") else "")
	elif state == Jobs.State.DONE or (not downloaded.is_empty() and state != Jobs.State.ERROR):
		var scene := str(job.get("scene", downloaded.get("scene", "")))
		_action.text = "Open Scene" if scene else "Show in FileSystem"
		_action.icon = get_theme_icon("StatusSuccess", "EditorIcons")
		_status.text = "In the project: %s" % str(job.get("target", "res://" + str(downloaded.get("folder", ""))))
		_secondary.visible = true
		_secondary.text = "Download again"
		_secondary.pressed.connect(_start_download)
		_convert_again.visible = UnrealBridge.pack_installed(Settings.unreal_project(), _pack_folders())
	elif state == Jobs.State.NEEDS_LOGIN or not logged_in:
		_action.text = "Log In…"
		_status.text = str(job.get("error", "")) if state == Jobs.State.NEEDS_LOGIN else "Log in to your Epic account to download from your Fab library."
	elif state == Jobs.State.NEEDS_LIBRARY:
		if FabApi.is_free(listing):
			_action.text = "Add on fab.com"
			_status.text = "This free asset isn't in your Fab library yet. " + FabApi.NEEDS_WEB_MESSAGE
		else:
			_action.text = "Buy on fab.com"
			_status.text = "This asset isn't in your Fab library. Buy it on fab.com, then click Refresh library."
		_secondary.visible = true
		_secondary.text = "Refresh library"
		_secondary.pressed.connect(func(): gallery.refresh_library())
	elif state == Jobs.State.ERROR:
		_action.text = "Retry"
		_status.text = ""
		_error_box.visible = true
		_error_label.text = str(job.get("error", ""))
		_log.text = str(job.get("log_tail", ""))
		_log.visible = not _log.text.is_empty()
		_open_unreal.visible = is_unreal
		_import_folder.visible = is_unreal
	else:
		_action.text = "Download"
		_status.text = "Converts with Unreal Engine (UnrealToGodot)." if is_unreal else "Imported directly by Godot."
		# Only Unreal builds need the library entry; glTF/FBX downloads ask Fab directly.
		if is_unreal and logged_in and FabApi.is_free(listing) and _in_library.get(uid, true) == false:
			_secondary.visible = true
			_secondary.text = "Add to My Library"
			_secondary.tooltip_text = "Adds this free asset to your Fab library. Fab needs its website for that, so the listing page opens in your browser; click Add to My Library there, then Refresh library here."
			_secondary.pressed.connect(_add_to_library_now)
			_status.text += " Not in your library yet."
		elif is_unreal and logged_in and _in_library.get(uid, false) == true:
			_status.text += " In your library."
	var archives: Array = gallery.jobs.unextracted_archives(uid) if not state in Jobs.ACTIVE else []
	_archive_box.visible = not archives.is_empty()
	if _archive_box.visible:
		var target := str(job.get("target", "res://" + str(downloaded.get("folder", ""))))
		_archive_label.text = Jobs.archive_warning(archives, target)
		var folder: String = gallery.jobs.archives_dir(uid)
		_archive_folder.text = "Downloaded to: %s" % folder
		_archive_folder.set_meta("folder", folder)
	if not state in Jobs.ACTIVE:
		var kept: int = gallery.jobs.downloads_size(uid)
		_delete_downloads.visible = kept > 0
		_delete_downloads.text = "Delete downloaded files (%s)" % String.humanize_size(kept)
	_fill_scenes() if is_unreal and _scene.item_count <= 2 else null


func _on_action() -> void:
	var uid := str(listing.get("uid", ""))
	var job: Dictionary = gallery.jobs.get_job(uid)
	var state: int = int(job.get("state", -1))
	match _action.text:
		"Cancel":
			cancel_requested.emit(uid)
		"Log In…":
			gallery.menu_button.open_login()
		"Add on fab.com", "Buy on fab.com":
			OS.shell_open(FabApi.listing_page_url(uid))
		"Retry":
			gallery.jobs.start(listing, selected_format(), selected_scene(), selected_engine_version())
		"Open Scene":
			var scene := str(job.get("scene", gallery.downloaded_entry(uid).get("scene", "")))
			if scene.ends_with(".tscn"):
				EditorInterface.open_scene_from_path(scene)
			else:
				EditorInterface.get_file_system_dock().navigate_to_path(scene)
			hide()
		"Show in FileSystem":
			var folder := str(job.get("target", "res://" + str(gallery.downloaded_entry(uid).get("folder", ""))))
			EditorInterface.get_file_system_dock().navigate_to_path(folder)
			hide()
		_:
			_start_download()
	_update_action()


## Content folders of the installed Unreal pack (this session's job, else the
## manifest written at import).
func _pack_folders() -> Array:
	var uid := str(listing.get("uid", ""))
	var folders: Array = gallery.jobs.get_job(uid).get("content_folders", [])
	if folders.is_empty():
		var downloaded: Dictionary = gallery.downloaded_entry(uid)
		if str(downloaded.get("format", "")) == FabApi.UNREAL_FORMAT:
			folders = downloaded.get("content_folders", [])
	return folders


func _convert_again_now() -> void:
	var uid := str(listing.get("uid", ""))
	var maps: Array = gallery.jobs.get_job(uid).get("maps", [])
	if maps.is_empty():
		maps = gallery.downloaded_entry(uid).get("maps", [])
	gallery.jobs.convert_again(listing, _pack_folders(), maps, selected_scene())
	_update_action()


func _ask_delete_downloads() -> void:
	var uid := str(listing.get("uid", ""))
	_delete_confirm.dialog_text = "Delete the downloaded files of \"%s\" (%s)?\n\nDownloading it again will fetch everything from Fab. The asset stays in this project and in the Unreal project." % [
		str(listing.get("title", uid)), String.humanize_size(gallery.jobs.downloads_size(uid))]
	_delete_confirm.popup_centered()


func _delete_downloads_now() -> void:
	var uid := str(listing.get("uid", ""))
	if not gallery.jobs.delete_downloads(uid):
		_status.text = "Could not delete the downloaded files (is the job still running?)"
	_update_action()


func _start_download() -> void:
	download_requested.emit(listing, selected_format(), selected_scene(), selected_engine_version())
	_update_action()


func _open_in_unreal() -> void:
	var job: Dictionary = gallery.jobs.get_job(str(listing.get("uid", "")))
	var maps: Array = job.get("maps", [])
	var map := UnrealBridge.pick_scene(maps, selected_scene())
	var editor := UnrealBridge.editor_cmd(Settings.unreal_engine()).trim_suffix("-Cmd").trim_suffix("-Cmd.exe")
	var pid := OS.create_process(editor, UnrealBridge.editor_open_args(Settings.unreal_project(), map), false)
	_status.text = "Unreal Editor started (pid %d). Run UnrealToGodot → Export To Godot, then Import export folder…" % pid if pid > 0 else "Could not start %s" % editor


func _import_export_folder(dir: String) -> void:
	var uid := str(listing.get("uid", ""))
	var job: Dictionary = gallery.jobs.get_job(uid)
	var target: String = Settings.download_dir().path_join(GodotImport.slug(str(listing.get("title", uid))))
	var meta := {"uid": uid, "title": str(listing.get("title", "")), "format": FabApi.UNREAL_FORMAT, "url": FabApi.listing_page_url(uid),
		"thumbnail": FabApi.thumbnail_url(listing, 320), "maps": job.get("maps", [])}
	var result: Dictionary = GodotImport.import_export(dir, target, meta)
	if result.ok:
		gallery.refresh_project_index()
		_status.text = "Imported into %s" % target
	else:
		_status.text = "Import failed: %s" % result.error
	_update_action()


# MARK: closing

func _on_focus_changed(_control: Control) -> void:
	pass


func _close_if_outside() -> void:
	pass


## HTML from Fab descriptions as BBCode: paragraphs, line breaks, lists,
## bold/italic and headings; everything else stripped.
static func html_to_bbcode(html: String) -> String:
	var text := html
	var regex := RegEx.new()
	regex.compile("(?i)<\\s*br\\s*/?>")
	text = regex.sub(text, "\n", true)
	regex.compile("(?i)</\\s*(p|div|h[1-6]|ul|ol|blockquote|tr)\\s*>")
	text = regex.sub(text, "\n\n", true)
	regex.compile("(?i)<\\s*li[^>]*>")
	text = regex.sub(text, "• ", true)
	regex.compile("(?i)</\\s*li\\s*>")
	text = regex.sub(text, "\n", true)
	regex.compile("(?i)<\\s*(b|strong|h[1-6])[^>]*>")
	text = regex.sub(text, "[b]", true)
	regex.compile("(?i)</\\s*(b|strong|h[1-6])\\s*>")
	text = regex.sub(text, "[/b]", true)
	regex.compile("(?i)<\\s*(i|em)[^>]*>")
	text = regex.sub(text, "[i]", true)
	regex.compile("(?i)</\\s*(i|em)\\s*>")
	text = regex.sub(text, "[/i]", true)
	regex.compile("<[^>]+>")
	text = regex.sub(text, "", true)
	for pair in [["&nbsp;", " "], ["&amp;", "&"], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", "\""], ["&#39;", "'"], ["&rsquo;", "’"], ["&lsquo;", "‘"], ["&ldquo;", "“"], ["&rdquo;", "”"], ["&hellip;", "…"], ["&ndash;", "–"], ["&mdash;", "—"]]:
		text = text.replace(pair[0], pair[1])
	regex.compile("\\n{3,}")
	text = regex.sub(text, "\n\n", true)
	return text.strip_edges()
