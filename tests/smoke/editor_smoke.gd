@tool
extends Node
## Exercises the gallery inside a headless editor, against the real Fab
## search API (no login needed). Started by the plugin when the environment
## variable GODOTFAB_SMOKE is "1":
##   GODOTFAB_SMOKE=1 godot --headless --editor --path . --quit-after 2000
## Prints "SMOKE OK" or "SMOKE FAIL: …" and quits the editor.

const Jobs = preload("res://addons/godotfab/jobs.gd")

var plugin: EditorPlugin
var _failures: Array[String] = []


func _ready() -> void:
	_run()


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)
		print("SMOKE check failed: " + what)
	else:
		print("SMOKE ok: " + what)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	await _frames(5)
	var gallery = plugin.gallery
	_check(gallery != null and gallery.is_inside_tree(), "gallery in the editor main screen")
	gallery.visible = true
	await _frames(2)
	_check(gallery.search.visible and not gallery.library.visible, "search view shown first")
	_check(gallery.spinner.stretch_mode == TextureRect.STRETCH_KEEP_CENTERED and gallery.spinner.texture.get_width() <= 64 * EditorInterface.get_editor_scale(), "spinner drawn at its own size (%d px)" % gallery.spinner.texture.get_width())
	# Search the real API.
	gallery.search_edit.text = "chair"
	gallery.search.request_search(true)
	var waited := 0
	while gallery.is_busy() and waited < 600:
		await _frames(1)
		waited += 1
	_check(not gallery.is_busy(), "search finished")
	var count: int = gallery.search.items.size()
	_check(count > 0, "search returned cards (%d)" % count)
	if count > 0:
		# Thumbnails arrive.
		var first = gallery.search.grid.get_child(0)
		waited = 0
		while first._texture == null and not first._thumbnail_failed and waited < 900:
			await _frames(1)
			waited += 1
		_check(first._texture != null, "first thumbnail decoded")
		# More than one batch of thumbnails decodes (the loader pumps batches of 6).
		var decoded := 0
		waited = 0
		while decoded < 10 and waited < 1200:
			await _frames(1)
			waited += 1
			decoded = 0
			for c in gallery.search.grid.get_children():
				if c._texture != null:
					decoded += 1
		_check(decoded >= 10, "at least 10 thumbnails decoded (%d)" % decoded)
		# Details dialog with the real listing endpoint.
		gallery.open_details(first.listing)
		waited = 0
		while gallery.details.detail.is_empty() and waited < 600:
			await _frames(1)
			waited += 1
		_check(not gallery.details.detail.is_empty(), "details loaded")
		_check(gallery.details._format.item_count > 0, "format options filled")
		var dsize: Vector2i = gallery.details.dialog_size()
		_check(dsize.x >= 520 and dsize.y >= 360, "details dialog size computed %s" % dsize)
		var has_scroll := false
		for child in gallery.details.get_children():
			if child is ScrollContainer:
				has_scroll = true
		_check(has_scroll, "details content is inside a ScrollContainer")
		_check(gallery.details._action.text in ["Log In…", "Download"], "action is %s" % gallery.details._action.text)
		gallery.details.hide()
		# Load more by scrolling.
		var before := count
		gallery.search.load_more()
		waited = 0
		while gallery.search.items.size() == before and waited < 600:
			await _frames(1)
			waited += 1
		_check(gallery.search.items.size() > before, "load more added cards (%d)" % gallery.search.items.size())
	# Library view logged out.
	gallery.library_toggle.button_pressed = true
	await _frames(2)
	_check(gallery.library.visible, "library view shown")
	if plugin.auth.is_logged_in():
		waited = 0
		while gallery.is_busy() and waited < 900:
			await _frames(1)
			waited += 1
		_check(gallery.library.items.size() > 0 or gallery.library._message.visible, "library loaded for %s (%d items)" % [plugin.auth.display_name, gallery.library.items.size()])
		_check(gallery.library.filter_row.visible and not gallery.search.filter_row.visible, "library filters shown instead of the search filters")
		if gallery.library.items.size() > 0:
			var all_count: int = gallery.library.visible_count()
			var engine_opt: OptionButton = gallery.library.engine_option
			_check(engine_opt.item_count > 1, "engine filter lists versions (%d)" % (engine_opt.item_count - 1))
			engine_opt.select(engine_opt.item_count - 1)
			engine_opt.item_selected.emit(engine_opt.item_count - 1)
			var filtered: int = gallery.library.visible_count()
			_check(filtered <= all_count, "engine filter narrows %d -> %d" % [all_count, filtered])
			engine_opt.select(0)
			engine_opt.item_selected.emit(0)
			gallery.library.kind_option.select(3)
			gallery.library.kind_option.item_selected.emit(3)
			_check(gallery.library.visible_count() <= all_count, "kind filter applied (%d plugins)" % gallery.library.visible_count())
			gallery.library.kind_option.select(0)
			gallery.library.kind_option.item_selected.emit(0)
			gallery.library.sort_option.select(1)
			gallery.library.sort_option.item_selected.emit(1)
			var first_title: String = gallery.library.grid.get_child(0).listing.title
			var last_title: String = gallery.library.grid.get_child(gallery.library.grid.get_child_count() - 1).listing.title
			_check(first_title.to_lower() >= last_title.to_lower(), "Z–A sort: '%s' before '%s'" % [first_title, last_title])
			_check(gallery.library.visible_count() == all_count, "filters reset show everything again")
	else:
		_check(gallery.library._button.visible and gallery.library._button.text == "Log In…", "library asks to log in")
	gallery.library_toggle.button_pressed = false
	# Menu, settings and login dialogs build without errors.
	gallery.menu_button._fill_menu()
	gallery.menu_button._settings._load()
	gallery.menu_button._settings._check_setup()
	_check(gallery.menu_button._settings._check_label.visible, "unreal setup check ran: " + gallery.menu_button._settings._check_label.text.replace("\n", " | "))
	gallery.menu_button._login.about_to_popup.emit()
	var login_size: Vector2i = gallery.menu_button._login.get_script().get_script_constant_map().get("DIALOG_SIZE", Vector2.ZERO)
	_check(login_size.x > 0, "login dialog size constant %s" % login_size)
	var screen := DisplayServer.screen_get_usable_rect().size
	for dialog in [gallery.menu_button._login, gallery.menu_button._settings, gallery.details]:
		var fitted: Vector2i = dialog.get_script().get_script_constant_map().get("DIALOG_SIZE", Vector2.ZERO)
		var fit := preload("res://addons/godotfab/ui/dialogs.gd").fit_to_screen(dialog, fitted)
		_check(screen.x <= 0 or (fit.x <= screen.x * 0.85 + 1 and fit.y <= screen.y * 0.85 + 1), "%s fits the screen: %s of %s" % [dialog.get_class(), fit, screen])
		var scrolls := false
		for child in dialog.get_children():
			if child is ScrollContainer:
				scrolls = true
		_check(scrolls, "%s content scrolls" % dialog.title)
	# A fake job to see the card states.
	var listing := {"uid": "smoke-uid", "title": "Smoke Pack", "assetFormats": [{"assetFormatType": {"code": "unreal-engine"}}]}
	var card = gallery.search.grid.get_child(0) if count > 0 else null
	if card:
		card.set_job({"state": Jobs.State.DOWNLOADING, "progress": 0.5, "message": "10 / 20 chunks"})
		_check(card._progress_track.visible and card._state_label.visible, "card shows progress")
		card.set_job({"state": Jobs.State.ERROR, "error": "boom"})
		_check(card._status_icon.visible, "card shows error icon")
	print("SMOKE %s" % ("OK" if _failures.is_empty() else "FAIL: " + "; ".join(_failures)))
	get_tree().quit(0 if _failures.is_empty() else 1)
