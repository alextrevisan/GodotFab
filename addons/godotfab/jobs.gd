@tool
extends Node
## One job per asset download: library lookup, manifest, chunks, then either
## the Unreal conversion (install pack → commandlet → import export) or the
## direct path (extract zips → import glTF/FBX). The UI listens to the
## signals and reads get_job().

signal job_changed(uid: String)
signal job_finished(uid: String, ok: bool)

const Log = preload("res://addons/godotfab/log.gd")
const Settings = preload("res://addons/godotfab/settings.gd")
const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Manifest = preload("res://addons/godotfab/manifest.gd")
const ChunkDownloader = preload("res://addons/godotfab/chunk_downloader.gd")
const UnrealBridge = preload("res://addons/godotfab/unreal_bridge.gd")
const GodotImport = preload("res://addons/godotfab/godot_import.gd")
const ProjectAssets = preload("res://addons/godotfab/project_assets.gd")

enum State { QUEUED, MANIFEST, NEEDS_LIBRARY, NEEDS_LOGIN, ADDING_TO_LIBRARY, DOWNLOADING, INSTALLING, CONVERTING, EXTRACTING, IMPORTING, DONE, ERROR, CANCELLED }
const ACTIVE := [State.QUEUED, State.MANIFEST, State.ADDING_TO_LIBRARY, State.DOWNLOADING, State.INSTALLING, State.CONVERTING, State.EXTRACTING, State.IMPORTING]
const STATE_LABELS := {
	State.QUEUED: "Queued", State.MANIFEST: "Preparing…", State.NEEDS_LIBRARY: "Not in your library",
	State.NEEDS_LOGIN: "Log in to download", State.ADDING_TO_LIBRARY: "Adding to library…",
	State.DOWNLOADING: "Downloading", State.INSTALLING: "Installing in Unreal project",
	State.CONVERTING: "Converting with Unreal", State.EXTRACTING: "Extracting", State.IMPORTING: "Importing",
	State.DONE: "Done", State.ERROR: "Failed", State.CANCELLED: "Cancelled",
}
const MAX_DOWNLOADS := 2
const MAX_CONVERSIONS := 1

## Services; the tests replace them with fakes.
## FabApi, or a test double with the same methods.
var api
var auth
var bridge = UnrealBridge.new()
var importer = GodotImport
var manifest_parser: Callable = Manifest.parse
## downloader_factory(manifest, base_urls, staging_dir, fetch_bytes, workers) -> object with run(), cancel(), progress signal.
var downloader_factory: Callable = _make_downloader
var staging_root := ""
var engine_version := ""
var unreal_project := ""
var unreal_engine := ""
var download_dir := ""
var parallel_chunks := 4
var export_options: Dictionary = {}

var _jobs: Dictionary = {}
var _downloaders: Dictionary = {}
## The single commandlet runner is in use (a cancelled job's process may
## still be winding down).
var _commandlet_busy := false


func _ready() -> void:
	if staging_root.is_empty():
		staging_root = _default_staging_root()


func configure_from_settings() -> void:
	engine_version = Settings.engine_version()
	unreal_project = Settings.unreal_project()
	unreal_engine = Settings.unreal_engine()
	download_dir = Settings.download_dir()
	parallel_chunks = int(Settings.get_editor(Settings.PARALLEL_CHUNKS))
	export_options = Settings.export_options()


static func _default_staging_root() -> String:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_paths().get_data_dir().path_join("godotfab/downloads")
	return ProjectSettings.globalize_path("user://godotfab/downloads")


# MARK: public

## [param engine_version] like "UE_5.8" picks the Unreal build; "" uses the
## configured version, else the newest build.
func start(listing: Dictionary, format: String, scene_pref := "auto", engine_version := "") -> void:
	var uid := str(listing.get("uid", ""))
	if uid.is_empty() or is_active(uid):
		return
	_jobs[uid] = {
		"uid": uid, "title": str(listing.get("title", uid)), "listing": listing, "format": format,
		"scene_pref": scene_pref, "engine_version": engine_version, "state": State.QUEUED, "progress": 0.0, "message": "", "error": "",
		"log_tail": "", "scene": "", "maps": [], "content_folders": [], "target": "", "started_at": Time.get_unix_time_from_system(),
		"cancelled": false, "staging": staging_root.path_join(uid), "needs_web": false,
	}
	_emit(uid)
	_run(uid)


func retry(uid: String) -> void:
	var job: Dictionary = _jobs.get(uid, {})
	if job.is_empty() or is_active(uid):
		return
	start(job.listing, job.format, job.scene_pref, job.engine_version)


func set_scene_and_retry(uid: String, scene: String) -> void:
	var job: Dictionary = _jobs.get(uid, {})
	if job.is_empty() or is_active(uid):
		return
	start(job.listing, job.format, scene, job.engine_version)


func cancel(uid: String) -> void:
	var job: Dictionary = _jobs.get(uid, {})
	if job.is_empty() or not is_active(uid):
		return
	job.cancelled = true
	if _downloaders.has(uid):
		_downloaders[uid].cancel()
	if job.state == State.CONVERTING and bridge.has_method("cancel"):
		bridge.cancel()
	_set_state(uid, State.CANCELLED)
	job_finished.emit(uid, false)


## Adds a free listing to the library, then starts the download again.
func add_to_library(uid: String) -> void:
	var job: Dictionary = _jobs.get(uid, {})
	if job.is_empty() or is_active(uid):
		return
	_set_state(uid, State.ADDING_TO_LIBRARY)
	var result: Dictionary = await api.add_to_library(uid)
	if job.cancelled:
		return
	if result.get("unauthorized", false):
		_needs_login(uid, result.error)
		return
	if not result.ok:
		_set_state(uid, State.NEEDS_LIBRARY)
		job.needs_web = result.get("needs_web", false)
		job.error = result.error
		Log.warning("%s: %s" % [job.title, result.error])
		_emit(uid)
		return
	_jobs.erase(uid)
	start(job.listing, job.format, job.scene_pref, job.engine_version)


## After the library was refreshed: jobs waiting for a listing that is now
## owned start again.
func retry_waiting_for_library(items: Array) -> void:
	for uid in _jobs.keys():
		if _jobs[uid].state == State.NEEDS_LIBRARY and not FabApi.library_item_for(items, uid).is_empty():
			var job: Dictionary = _jobs[uid]
			_jobs.erase(uid)
			start(job.listing, job.format, job.scene_pref, job.engine_version)


func get_job(uid: String) -> Dictionary:
	return _jobs.get(uid, {})


func is_active(uid: String) -> bool:
	return _jobs.has(uid) and _jobs[uid].state in ACTIVE


func count_active() -> int:
	var n := 0
	for uid in _jobs:
		if is_active(uid):
			n += 1
	return n


func active_jobs() -> Array:
	var jobs := []
	for uid in _jobs:
		if is_active(uid):
			jobs.append(_jobs[uid])
	return jobs


static func state_label(state: int) -> String:
	return STATE_LABELS.get(state, "")


# MARK: the pipeline

func _run(uid: String) -> void:
	var job: Dictionary = _jobs[uid]
	_set_state(uid, State.MANIFEST)
	var item: Dictionary = await _find_library_item(uid)
	if job.cancelled:
		return
	if item.has("_unauthorized"):
		_needs_login(uid, item._unauthorized)
		return
	if item.has("_error"):
		_fail(uid, item._error)
		return
	if item.is_empty() and FabApi.is_free(job.listing):
		# Free listings are claimed on the way, like "Add to project" on fab.com.
		_set_state(uid, State.ADDING_TO_LIBRARY)
		var added: Dictionary = await api.add_to_library(uid)
		if job.cancelled:
			return
		if added.get("unauthorized", false):
			_needs_login(uid, added.error)
			return
		if added.ok:
			_set_state(uid, State.MANIFEST)
			item = await _find_library_item(uid)
			if job.cancelled:
				return
			if item.has("_unauthorized") or item.has("_error"):
				_fail(uid, str(item.get("_error", item.get("_unauthorized", ""))))
				return
		else:
			_set_state(uid, State.NEEDS_LIBRARY)
			job.needs_web = added.get("needs_web", false)
			job.error = added.error
			_emit(uid)
			return
	if item.is_empty():
		job.message = "Add it to your library on Fab first"
		_set_state(uid, State.NEEDS_LIBRARY)
		return
	job.library_item = item

	var builds: Array = await _collect_builds(uid, item)
	if job.cancelled or job.state == State.ERROR or job.state == State.NEEDS_LOGIN:
		return
	if builds.is_empty():
		_fail(uid, "Nothing to download")
		return

	# Downloads: at most MAX_DOWNLOADS jobs at once.
	await _wait_for_slot(uid, State.DOWNLOADING, MAX_DOWNLOADS, State.MANIFEST, "Waiting for other downloads…")
	if job.cancelled:
		return
	_set_state(uid, State.DOWNLOADING)
	var files_dirs: Array = []
	var all_files: Array = []
	for i in builds.size():
		var build: Dictionary = builds[i]
		var staging: String = job.staging.path_join("dl%d" % i)
		var downloader = downloader_factory.call(build.manifest, build.base_urls, staging, api.fetch_bytes, parallel_chunks)
		_downloaders[uid] = downloader
		var base_progress := float(i) / builds.size()
		downloader.progress.connect(func(done: int, total: int, bytes_done: int, bytes_total: int):
			job.progress = base_progress + (float(done) / maxf(1.0, total)) / builds.size()
			job.message = "%d / %d chunks (%s)" % [done, total, _mb(bytes_done, bytes_total)]
			_emit(uid))
		var result: Dictionary = await downloader.run()
		if _downloaders.get(uid) == downloader:
			_downloaders.erase(uid)
		if job.cancelled:
			return
		if not result.ok:
			_fail(uid, result.error)
			return
		files_dirs.append(result.files_dir)
		all_files.append_array(result.files)
	job.progress = 1.0

	if job.format == FabApi.UNREAL_FORMAT:
		await _unreal_path(uid, files_dirs)
	else:
		await _direct_path(uid, files_dirs)
	if job.cancelled or job.state != State.IMPORTING:
		return
	_set_state(uid, State.DONE)
	_remove_dir(job.staging)
	job_finished.emit(uid, true)


## The library item of the job's listing, refreshing the library once.
## {} when the account doesn't own it; {_unauthorized: msg} / {_error: msg}.
func _find_library_item(uid: String) -> Dictionary:
	for force in [false, true]:
		var library: Dictionary = await api.library(force)
		if library.get("unauthorized", false):
			return {"_unauthorized": library.error}
		if not library.ok:
			return {"_error": library.error}
		var item := FabApi.library_item_for(library.items, uid)
		if not item.is_empty():
			return item
	return {}


## The manifests to download: one for an Unreal pack, one per file for a
## direct format. Each {manifest: Dictionary, base_urls: Array}.
func _collect_builds(uid: String, item: Dictionary) -> Array:
	var job: Dictionary = _jobs[uid]
	var pointer_sets: Array = []
	if job.format == FabApi.UNREAL_FORMAT:
		var wanted: String = job.engine_version if not str(job.engine_version).is_empty() else engine_version
		var version := FabApi.pick_project_version(item, wanted)
		if version.is_empty() or (not str(job.engine_version).is_empty() and not wanted in version.get("engineVersions", [])):
			# The library may lag behind the listing's builds: ask the listing.
			var format: Dictionary = await api.listing_format(uid, FabApi.UNREAL_FORMAT)
			var build := FabApi.build_for_engine(format.get("versions", []), wanted) if format.ok else {}
			if not build.is_empty():
				version = build
		if version.is_empty():
			_fail(uid, "This asset has no Unreal Engine build in your library")
			return []
		var engines: Array = version.get("engineVersions", [])
		if not wanted in engines:
			if not str(job.engine_version).is_empty():
				_fail(uid, "This asset has no %s build (available: %s)" % [wanted, ", ".join(FabApi.engine_versions_of(item.get("projectVersions", [])))])
				return []
			job.message = "No %s build; using %s" % [wanted, ", ".join(engines)]
		pointer_sets.append(await api.manifest_pointers(item, version))
	else:
		var format: Dictionary = await api.listing_format(uid, job.format)
		if not format.ok:
			_fail(uid, format.error)
			return []
		if format.files.is_empty():
			_fail(uid, "This asset has no %s files" % job.format)
			return []
		for file in format.files:
			if not file is Dictionary or str(file.get("status", "ready")) != "ready":
				continue
			pointer_sets.append(await api.file_download_info(uid, job.format, str(file.get("uid", ""))))
	var builds: Array = []
	for pointers in pointer_sets:
		if job.cancelled:
			return []
		if pointers.get("unauthorized", false):
			_needs_login(uid, pointers.error)
			return []
		if not pointers.ok:
			_fail(uid, pointers.error)
			return []
		var fetched := await _fetch_manifest(pointers.sources)
		if not fetched.ok:
			_fail(uid, fetched.error)
			return []
		var base_urls := []
		for source in pointers.sources:
			base_urls.append(source.base_url)
		builds.append({"manifest": fetched.manifest, "base_urls": base_urls})
	return builds


func _fetch_manifest(sources: Array) -> Dictionary:
	var last_error := "no download location"
	for source in sources:
		var response: Dictionary = await api.fetch_bytes(source.manifest_url)
		if not response.ok:
			last_error = response.error
			continue
		var parsed: Dictionary = manifest_parser.call(response.body)
		if parsed.ok:
			return {"ok": true, "error": "", "manifest": parsed}
		last_error = parsed.error
	return {"ok": false, "error": "Could not get the build manifest: %s" % last_error}


func _unreal_path(uid: String, files_dirs: Array) -> void:
	var job: Dictionary = _jobs[uid]
	_set_state(uid, State.INSTALLING)
	var installed: Dictionary = bridge.install_pack(files_dirs[0], unreal_project)
	if not installed.ok:
		_fail(uid, installed.error)
		return
	job.maps = installed.maps
	job.content_folders = installed.content_folders
	if installed.content_folders.is_empty():
		_fail(uid, "The pack has no Content folder to convert")
		return
	await _wait_for_slot(uid, State.CONVERTING, MAX_CONVERSIONS, State.INSTALLING, "Waiting for Unreal…")
	if job.cancelled:
		return
	_set_state(uid, State.CONVERTING)
	var export_dir: String = job.staging.path_join("export")
	var log_path: String = job.staging.path_join("convert.log")
	var content_path := UnrealBridge.content_paths(installed.content_folders)
	var scene := bridge.pick_scene(installed.maps, job.scene_pref)
	var options := export_options.duplicate()
	var args := bridge.commandlet_args(unreal_project, content_path, scene, export_dir, log_path, options)
	var on_progress := func(p: Dictionary):
		if int(p.get("total", 0)) > 0:
			job.progress = float(p.current) / float(p.total)
		job.message = "%s %s" % [str(p.get("stage", "")), ("%d / %d" % [p.current, p.total]) if int(p.get("total", 0)) > 0 else ""]
		_emit(uid)
	_commandlet_busy = true
	var result: Dictionary = await bridge.run_commandlet(bridge.editor_cmd(unreal_engine), args, log_path, on_progress)
	_commandlet_busy = false
	if job.cancelled:
		return
	job.log_tail = str(result.get("log_tail", ""))
	if not result.ok:
		_fail(uid, "Unreal conversion failed (exit %s)" % str(result.get("exit_code", "?")))
		return
	_set_state(uid, State.IMPORTING)
	var target := _target_res_dir(job)
	job.target = target
	var imported: Dictionary = importer.import_export(export_dir, target, _meta(job))
	if not imported.ok:
		_fail(uid, imported.error)
		return
	job.scene = imported.scene


func _direct_path(uid: String, files_dirs: Array) -> void:
	var job: Dictionary = _jobs[uid]
	_set_state(uid, State.EXTRACTING)
	for files_dir in files_dirs:
		var extracted: Dictionary = importer.extract_zips(files_dir)
		if not extracted.ok:
			_fail(uid, extracted.error)
			return
	_set_state(uid, State.IMPORTING)
	var target := _target_res_dir(job)
	job.target = target
	var imported: Dictionary = importer.import_direct(files_dirs[0], target, _meta(job))
	if not imported.ok:
		_fail(uid, imported.error)
		return
	job.scene = imported.scene


## Blocks while [param limit] other jobs are in [param busy_state].
func _wait_for_slot(uid: String, busy_state: int, limit: int, wait_state: int, message: String) -> void:
	var job: Dictionary = _jobs[uid]
	while not job.cancelled:
		var busy := 0
		for other in _jobs:
			if other != uid and _jobs[other].state == busy_state:
				busy += 1
		if busy_state == State.CONVERTING and _commandlet_busy:
			busy = maxi(busy, limit)
		if busy < limit:
			return
		if job.state != wait_state or job.message != message:
			_set_state(uid, wait_state)
			job.message = message
			_emit(uid)
		await Engine.get_main_loop().create_timer(0.5).timeout


# MARK: helpers

func _target_res_dir(job: Dictionary) -> String:
	var slug: String = importer.slug(job.title)
	var base: String = download_dir.rstrip("/")
	var target := base.path_join(slug)
	var existing: Dictionary = ProjectAssets.find(ProjectSettings.globalize_path(base), job.uid)
	if not existing.is_empty():
		return base.path_join(existing.folder)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(target)):
		var other := ProjectAssets.scan(ProjectSettings.globalize_path(base)).filter(func(a): return a.folder == slug)
		if not other.is_empty() and other[0].get("uid", "") != job.uid:
			target = base.path_join("%s_%s" % [slug, job.uid.substr(0, 8)])
	return target


func _meta(job: Dictionary) -> Dictionary:
	var listing: Dictionary = job.listing
	return {"uid": job.uid, "title": job.title, "format": job.format, "seller": FabApi.seller_name(listing),
		"thumbnail": FabApi.thumbnail_url(listing, 320), "listing_type": str(listing.get("listingType", "")),
		"url": FabApi.listing_page_url(job.uid), "maps": job.maps, "content_folders": job.content_folders}


func _make_downloader(manifest: Dictionary, base_urls: Array, staging: String, fetch_bytes: Callable, workers: int):
	return ChunkDownloader.new(manifest, base_urls, staging, fetch_bytes, workers)


func _set_state(uid: String, state: int) -> void:
	var job: Dictionary = _jobs[uid]
	job.state = state
	if state != State.ERROR:
		job.error = ""
	if state in [State.MANIFEST, State.DOWNLOADING, State.INSTALLING, State.CONVERTING, State.EXTRACTING, State.IMPORTING]:
		job.progress = 0.0 if state != State.INSTALLING else job.progress
		if job.message.is_empty() or state != State.INSTALLING:
			job.message = ""
	Log.verbose("%s: %s" % [job.title, state_label(state)])
	_emit(uid)


func _fail(uid: String, error: String) -> void:
	var job: Dictionary = _jobs[uid]
	job.error = error
	job.state = State.ERROR
	Log.error("%s: %s" % [job.title, error])
	_emit(uid)
	job_finished.emit(uid, false)


func _needs_login(uid: String, error: String) -> void:
	var job: Dictionary = _jobs[uid]
	job.error = error
	if auth != null and auth.has_method("logout"):
		auth.logout()
	api.clear_library()
	_set_state(uid, State.NEEDS_LOGIN)
	job_finished.emit(uid, false)


func _emit(uid: String) -> void:
	job_changed.emit(uid)


static func _mb(done: int, total: int) -> String:
	if total <= 0:
		return "%.1f MB" % (done / 1048576.0)
	return "%.1f / %.1f MB" % [done / 1048576.0, total / 1048576.0]


static func _remove_dir(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for dir in folder.get_directories():
		_remove_dir(path.path_join(dir))
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
