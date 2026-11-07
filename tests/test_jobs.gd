extends "res://tests/test_case.gd"

const Jobs = preload("res://addons/godotfab/jobs.gd")
const Fakes = preload("res://tests/fakes/fake_services.gd")

const LISTING := {"uid": "uid-1", "title": "My Pack", "listingType": "3d-model", "user": {"sellerName": "S"}}
const LIBRARY_ITEM := {"assetId": "asset-1", "assetNamespace": "ns", "url": "https://www.fab.com/listings/uid-1",
	"projectVersions": [{"artifactId": "art", "engineVersions": ["UE_5.8"]}]}

var _downloaders: Array = []
var _downloader_ok := true


func _jobs(api: Fakes.FakeApi) -> Jobs:
	var jobs := Jobs.new()
	jobs.api = api
	jobs.auth = Fakes.FakeAuth.new()
	jobs.bridge = Fakes.FakeBridge.new()
	jobs.importer = Fakes.FakeImporter.new()
	jobs.manifest_parser = func(bytes: PackedByteArray) -> Dictionary:
		return {"ok": true, "error": "", "feature_level": 20, "build_version": "1", "chunks": {}, "files": [{"filename": "Content/P/a.uasset", "size": 3, "parts": []}]}
	jobs.downloader_factory = func(manifest, base_urls, staging, fetch_bytes, workers):
		var dl := Fakes.FakeDownloader.new()
		dl.staging = staging
		dl.ok = _downloader_ok
		_downloaders.append(dl)
		return dl
	jobs.staging_root = tmp_dir()
	jobs.download_dir = "res://fab_assets_test"
	jobs.engine_version = "UE_5.8"
	jobs.unreal_project = "/tmp/x/X.uproject"
	jobs.unreal_engine = "/tmp/engine"
	jobs.export_options = {"scene": "auto"}
	Engine.get_main_loop().root.add_child(jobs)
	return jobs


func _api_with_library() -> Fakes.FakeApi:
	var api := Fakes.FakeApi.new()
	api.library_items = [LIBRARY_ITEM]
	return api


func _wait_finished(jobs: Jobs, uid: String, max_frames := 400) -> void:
	for i in max_frames:
		if not jobs.is_active(uid):
			return
		await Engine.get_main_loop().process_frame
	failures.append("job %s still active after %d frames (state %s)" % [uid, max_frames, Jobs.state_label(jobs.get_job(uid).state)])


func _states(jobs: Jobs) -> Array:
	var states: Array = []
	jobs.job_changed.connect(func(uid: String):
		var state: int = jobs.get_job(uid).state
		if states.is_empty() or states.back() != state:
			states.append(state))
	return states


func test_happy_path_reaches_done() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	var states := _states(jobs)
	var finished: Array = []
	jobs.job_finished.connect(func(uid, ok): finished.append([uid, ok]))
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	var job := jobs.get_job("uid-1")
	assert_eq(job.state, Jobs.State.DONE, job.error)
	assert_eq(states, [Jobs.State.QUEUED, Jobs.State.MANIFEST, Jobs.State.DOWNLOADING, Jobs.State.INSTALLING, Jobs.State.CONVERTING, Jobs.State.IMPORTING, Jobs.State.DONE])
	assert_eq(finished, [["uid-1", true]])
	assert_eq(job.scene, "res://fab_assets_test/my_pack/Overview.tscn")
	assert_eq(job.target, "res://fab_assets_test/my_pack")
	assert_eq(job.maps, ["/Game/P/Maps/Overview"])
	assert_eq(api.calls[1][0], "manifest_pointers")
	assert_eq(api.calls[1][2].artifactId, "art")
	var bridge: Fakes.FakeBridge = jobs.bridge
	assert_eq(bridge.calls[0][0], "install_pack")
	assert_eq(bridge.calls[1], ["commandlet_args", "/Game/P", "/Game/P/Maps/Overview", jobs.staging_root.path_join("uid-1/export")])
	assert_eq(bridge.calls[2][1], "/tmp/engine/UnrealEditor-Cmd")
	var importer: Fakes.FakeImporter = jobs.importer
	assert_eq(importer.calls[0][0], "import_export")
	assert_eq(importer.calls[0][3].uid, "uid-1")
	assert_false(DirAccess.dir_exists_absolute(jobs.staging_root.path_join("uid-1")), "staging removed on DONE")
	jobs.queue_free()


func test_direct_path_reaches_done() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	var states := _states(jobs)
	jobs.start(LISTING, "gltf")
	await _wait_finished(jobs, "uid-1")
	var job := jobs.get_job("uid-1")
	assert_eq(job.state, Jobs.State.DONE, job.error)
	assert_eq(states, [Jobs.State.QUEUED, Jobs.State.MANIFEST, Jobs.State.DOWNLOADING, Jobs.State.EXTRACTING, Jobs.State.IMPORTING, Jobs.State.DONE])
	assert_eq(api.calls[1], ["listing_format", "uid-1", "gltf"])
	assert_eq(api.calls[2], ["file_download_info", "uid-1", "gltf", "f1"])
	var importer: Fakes.FakeImporter = jobs.importer
	assert_eq(importer.calls[0][0], "extract_zips")
	assert_eq(importer.calls[1][0], "import_direct")
	assert_eq(job.scene, "res://fab_assets_test/my_pack/model.glb")
	assert_eq(jobs.bridge.calls.size(), 0, "no Unreal involved")
	jobs.queue_free()


func test_not_in_library_sets_needs_library() -> void:
	var api := Fakes.FakeApi.new()
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.NEEDS_LIBRARY)
	assert_eq(api.calls.filter(func(c): return c[0] == "library"), [["library", false], ["library", true]], "library refreshed once")
	jobs.queue_free()


func test_add_to_library_then_restart() -> void:
	var api := Fakes.FakeApi.new()
	var jobs := _jobs(api)
	jobs.start(LISTING, "gltf")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.NEEDS_LIBRARY)
	api.library_items = [LIBRARY_ITEM]
	jobs.add_to_library("uid-1")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE, jobs.get_job("uid-1").error)
	assert_true(api.calls.any(func(c): return c[0] == "add_to_library"))
	jobs.queue_free()


func test_add_to_library_needs_web_then_refresh_restarts() -> void:
	var api := Fakes.FakeApi.new()
	api.add_result = {"ok": false, "error": "Add it on fab.com", "needs_web": true, "unauthorized": false}
	var jobs := _jobs(api)
	jobs.start(LISTING, "gltf")
	await _wait_finished(jobs, "uid-1")
	jobs.add_to_library("uid-1")
	await _wait_finished(jobs, "uid-1")
	var job := jobs.get_job("uid-1")
	assert_eq(job.state, Jobs.State.NEEDS_LIBRARY)
	assert_true(job.needs_web)
	assert_contains(job.error, "fab.com")
	# The user added it on the website and refreshed the library: the job restarts.
	api.library_items = [LIBRARY_ITEM]
	jobs.retry_waiting_for_library(api.library_items)
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE, jobs.get_job("uid-1").error)
	jobs.queue_free()


func test_job_needs_login_on_401() -> void:
	var api := _api_with_library()
	api.pointers_unauthorized = true
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.NEEDS_LOGIN)
	assert_true(jobs.auth.logged_out)
	assert_eq(api.calls.filter(func(c): return c[0] == "manifest_pointers").size(), 1, "no retry loop")
	jobs.queue_free()


func test_library_401_needs_login() -> void:
	var api := Fakes.FakeApi.new()
	api.library_unauthorized = true
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.NEEDS_LOGIN)
	jobs.queue_free()


func test_download_error_sets_error_and_retry_restarts() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	_downloader_ok = false
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	var job := jobs.get_job("uid-1")
	assert_eq(job.state, Jobs.State.ERROR)
	assert_eq(job.error, "chunk missing")
	_downloader_ok = true
	jobs.retry("uid-1")
	assert_true(jobs.is_active("uid-1"))
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE)
	jobs.queue_free()


func test_conversion_failure_keeps_log_tail() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	jobs.bridge.convert_ok = false
	DirAccess.make_dir_recursive_absolute(jobs.staging_root.path_join("uid-1"))
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	var job := jobs.get_job("uid-1")
	assert_eq(job.state, Jobs.State.ERROR)
	assert_contains(job.error, "Unreal conversion failed")
	assert_eq(job.log_tail, "last lines")
	assert_true(DirAccess.dir_exists_absolute(jobs.staging_root.path_join("uid-1")), "staging kept for retry")
	jobs.queue_free()


func test_only_one_conversion_at_a_time() -> void:
	var api := _api_with_library()
	api.library_items = [LIBRARY_ITEM, {"assetId": "asset-2", "assetNamespace": "ns", "url": "https://www.fab.com/listings/uid-2",
		"projectVersions": [{"artifactId": "art2", "engineVersions": ["UE_5.8"]}]}]
	var jobs := _jobs(api)
	jobs.bridge.convert_frames = 6
	jobs.start(LISTING, "unreal-engine")
	jobs.start({"uid": "uid-2", "title": "Other"}, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	await _wait_finished(jobs, "uid-2")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE, jobs.get_job("uid-1").error)
	assert_eq(jobs.get_job("uid-2").state, Jobs.State.DONE, jobs.get_job("uid-2").error)
	assert_eq(jobs.bridge.max_running, 1)
	assert_eq(jobs.count_active(), 0)
	jobs.queue_free()


func test_cancel_during_download() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine")
	for i in 100:
		await Engine.get_main_loop().process_frame
		if jobs.get_job("uid-1").state == Jobs.State.DOWNLOADING and not _downloaders.is_empty():
			break
	jobs.cancel("uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.CANCELLED)
	assert_true(_downloaders.back().cancelled)
	for i in 10:
		await Engine.get_main_loop().process_frame
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.CANCELLED, "stays cancelled after the downloader returns")
	assert_eq(jobs.bridge.calls.size(), 0)
	jobs.queue_free()


func test_start_twice_is_ignored_while_active() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine")
	jobs.start(LISTING, "unreal-engine")
	await _wait_finished(jobs, "uid-1")
	assert_eq(api.calls.filter(func(c): return c[0] == "manifest_pointers").size(), 1)
	jobs.queue_free()


func test_waiting_message_shows_while_queued() -> void:
	var api := _api_with_library()
	api.library_items = [LIBRARY_ITEM, {"assetId": "asset-2", "assetNamespace": "ns", "url": "https://www.fab.com/listings/uid-2",
		"projectVersions": [{"artifactId": "art2", "engineVersions": ["UE_5.8"]}]}]
	var jobs := _jobs(api)
	jobs.bridge.convert_frames = 40
	jobs.start(LISTING, "unreal-engine")
	jobs.start({"uid": "uid-2", "title": "Other"}, "unreal-engine")
	var saw_waiting := false
	for i in 200:
		await Engine.get_main_loop().process_frame
		var job := jobs.get_job("uid-2")
		if job.state == Jobs.State.INSTALLING and job.message == "Waiting for Unreal…":
			saw_waiting = true
			break
	assert_true(saw_waiting, "second job shows the waiting message")
	await _wait_finished(jobs, "uid-1")
	await _wait_finished(jobs, "uid-2")
	assert_eq(jobs.get_job("uid-2").state, Jobs.State.DONE)
	jobs.queue_free()


func test_cancel_then_retry_keeps_new_downloader() -> void:
	var api := _api_with_library()
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine")
	for i in 100:
		await Engine.get_main_loop().process_frame
		if jobs.get_job("uid-1").state == Jobs.State.DOWNLOADING and not _downloaders.is_empty():
			break
	var old = _downloaders.back()
	old.frames = 6
	jobs.cancel("uid-1")
	jobs.retry("uid-1")
	for i in 10:
		await Engine.get_main_loop().process_frame
	assert_true(jobs.get_job("uid-1").state != Jobs.State.CANCELLED, "retried job not cancelled by the old downloader returning")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE)
	jobs.queue_free()


func test_explicit_engine_version_picks_that_build() -> void:
	var api := Fakes.FakeApi.new()
	api.library_items = [{"assetId": "asset-1", "assetNamespace": "ns", "url": "https://www.fab.com/listings/uid-1",
		"projectVersions": [{"artifactId": "old", "engineVersions": ["UE_5.3"]}, {"artifactId": "new", "engineVersions": ["UE_5.8"]}]}]
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine", "auto", "UE_5.3")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE, jobs.get_job("uid-1").error)
	var pointers := api.calls.filter(func(c): return c[0] == "manifest_pointers")
	assert_eq(pointers.size(), 1)
	assert_eq(pointers[0][2].artifactId, "old")
	jobs.queue_free()


func test_explicit_engine_version_falls_back_to_listing_builds_or_fails() -> void:
	var api := _api_with_library()
	api.format_versions = [{"artifactId": "from-listing", "engineVersions": ["UE_5.5"]}]
	var jobs := _jobs(api)
	jobs.start(LISTING, "unreal-engine", "auto", "UE_5.5")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE, jobs.get_job("uid-1").error)
	var pointers := api.calls.filter(func(c): return c[0] == "manifest_pointers")
	assert_eq(pointers[0][2].artifactId, "from-listing")
	jobs.queue_free()
	# A version nobody offers fails with the available ones listed.
	var jobs2 := _jobs(_api_with_library())
	jobs2.start(LISTING, "unreal-engine", "auto", "UE_4.27")
	await _wait_finished(jobs2, "uid-1")
	assert_eq(jobs2.get_job("uid-1").state, Jobs.State.ERROR)
	assert_contains(jobs2.get_job("uid-1").error, "UE_5.8")
	jobs2.queue_free()


func test_free_listing_is_added_to_library_automatically() -> void:
	var api := Fakes.FakeApi.new()
	var free_listing := LISTING.duplicate()
	free_listing["isFree"] = true
	var jobs := _jobs(api)
	var states := _states(jobs)
	# The fake library is empty until add_to_library is called.
	api.add_result = {"ok": true, "error": "", "needs_web": false, "unauthorized": false}
	jobs.api = api
	api.library_items = []
	var watcher := func():
		while api.library_items.is_empty():
			await Engine.get_main_loop().process_frame
			if api.calls.any(func(c): return c[0] == "add_to_library"):
				api.library_items = [LIBRARY_ITEM]
	watcher.call()
	jobs.start(free_listing, "gltf")
	await _wait_finished(jobs, "uid-1")
	assert_eq(jobs.get_job("uid-1").state, Jobs.State.DONE, jobs.get_job("uid-1").error)
	assert_true(states.has(Jobs.State.ADDING_TO_LIBRARY), "went through ADDING_TO_LIBRARY: %s" % str(states))
	assert_eq(api.calls.filter(func(c): return c[0] == "add_to_library").size(), 1)
	jobs.queue_free()


func test_free_listing_needs_web_stops_at_needs_library() -> void:
	var api := Fakes.FakeApi.new()
	api.add_result = {"ok": false, "error": "Add it on fab.com", "needs_web": true, "unauthorized": false}
	var free_listing := LISTING.duplicate()
	free_listing["isFree"] = true
	var jobs := _jobs(api)
	jobs.start(free_listing, "gltf")
	await _wait_finished(jobs, "uid-1")
	var job := jobs.get_job("uid-1")
	assert_eq(job.state, Jobs.State.NEEDS_LIBRARY)
	assert_true(job.needs_web)
	jobs.queue_free()
