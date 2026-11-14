extends RefCounted
## Fakes of the services Jobs orchestrates. Every call is recorded in
## `calls` as [method, args...]; outcomes are configured by the fields.

class FakeApi extends RefCounted:
	var calls: Array = []
	var library_items: Array = []
	var library_ok := true
	var library_unauthorized := false
	var pointers_ok := true
	var pointers_unauthorized := false
	## download-info answers 404: the account doesn't own the listing.
	var pointers_not_owned := false
	var format_files: Array = [{"uid": "f1", "name": "source.zip", "status": "ready"}]
	var format_versions: Array = []
	var manifest_bytes := PackedByteArray([1, 2, 3])
	var add_result := {"ok": true, "error": "", "needs_web": false, "unauthorized": false}
	## When set, the pointers are a single signed file URL (FBX, glTF…).
	var direct_url := ""
	## The listing's additional files (format "additional-files"); none by default.
	var extra_files: Array = []
	var download_ok := true
	var library_calls := 0

	func library(force := false) -> Dictionary:
		calls.append(["library", force])
		library_calls += 1
		await Engine.get_main_loop().process_frame
		if library_unauthorized:
			return {"ok": false, "error": "unauthorized", "items": [], "unauthorized": true}
		if not library_ok:
			return {"ok": false, "error": "library down", "items": [], "unauthorized": false}
		return {"ok": true, "error": "", "items": library_items, "unauthorized": false}

	func clear_library() -> void:
		calls.append(["clear_library"])

	func manifest_pointers(item: Dictionary, version: Dictionary) -> Dictionary:
		calls.append(["manifest_pointers", item, version])
		await Engine.get_main_loop().process_frame
		return _pointers()

	func listing_format(uid: String, code: String) -> Dictionary:
		calls.append(["listing_format", uid, code])
		await Engine.get_main_loop().process_frame
		if code == "additional-files":
			return {"ok": not extra_files.is_empty(), "error": "" if extra_files else "HTTP 404", "files": extra_files, "versions": []}
		return {"ok": true, "error": "", "files": format_files, "versions": format_versions}

	func file_download_info(uid: String, code: String, file_uid: String) -> Dictionary:
		calls.append(["file_download_info", uid, code, file_uid])
		await Engine.get_main_loop().process_frame
		return _pointers()

	func _pointers() -> Dictionary:
		if pointers_unauthorized:
			return {"ok": false, "error": "401", "unauthorized": true, "build_version": "", "sources": []}
		if pointers_not_owned:
			return {"ok": false, "error": "Not in your library", "unauthorized": false, "not_owned": true, "build_version": "", "sources": []}
		if not pointers_ok:
			return {"ok": false, "error": "rate limited", "unauthorized": false, "build_version": "", "sources": []}
		if not direct_url.is_empty():
			return {"ok": true, "error": "", "unauthorized": false, "build_version": "", "sources": [], "download_url": direct_url}
		return {"ok": true, "error": "", "unauthorized": false, "build_version": "1",
			"sources": [{"manifest_url": "https://cdn/m?sig", "base_url": "https://cdn"}]}

	## [downloaded, total] byte counts every download reports before it ends
	## (total -1: the server doesn't tell the size).
	var download_progress: Array = []

	func download_file(url: String, path: String, _timeout := 3600.0, progress := Callable()) -> Dictionary:
		calls.append(["download_file", url, path])
		await Engine.get_main_loop().process_frame
		for step in download_progress:
			progress.call(step[0], step[1])
			await Engine.get_main_loop().process_frame
		if download_ok:
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_string("zip")
			f.close()
		return {"ok": download_ok, "status": 200 if download_ok else 404, "body": PackedByteArray(), "error": "" if download_ok else "HTTP 404"}

	func fetch_bytes(url: String, _timeout := 120.0) -> Dictionary:
		calls.append(["fetch_bytes", url])
		await Engine.get_main_loop().process_frame
		return {"ok": true, "status": 200, "body": manifest_bytes, "error": ""}

	func add_to_library(uid: String) -> Dictionary:
		calls.append(["add_to_library", uid])
		await Engine.get_main_loop().process_frame
		return add_result


class FakeAuth extends RefCounted:
	var logged_out := false
	var account_id := "acc"
	func is_logged_in() -> bool: return not logged_out
	func ensure_token() -> String: return "" if logged_out else "tok"
	func logout() -> void: logged_out = true


class FakeDownloader extends RefCounted:
	signal progress(done: int, total: int, bytes_done: int, bytes_total: int)
	var ok := true
	var frames := 2
	var cancelled := false
	var staging: String
	func cancel() -> void: cancelled = true
	func run() -> Dictionary:
		for i in frames:
			await Engine.get_main_loop().process_frame
			progress.emit(i + 1, frames, 100 * (i + 1), 100 * frames)
			if cancelled:
				return {"ok": false, "error": "cancelled", "files_dir": staging, "files": []}
		if not ok:
			return {"ok": false, "error": "chunk missing", "files_dir": staging, "files": []}
		# Like ChunkDownloader: chunks are cached, files are assembled from them.
		for rel in ["chunks/C0.bin", "files/Content/P/a.uasset"]:
			DirAccess.make_dir_recursive_absolute(staging.path_join(rel).get_base_dir())
			FileAccess.open(staging.path_join(rel), FileAccess.WRITE).store_string("x")
		return {"ok": true, "error": "", "files_dir": staging.path_join("files"), "files": [staging.path_join("files/Content/P/a.uasset")]}


class FakeBridge extends RefCounted:
	var calls: Array = []
	var install_ok := true
	var convert_ok := true
	var convert_frames := 2
	var running := 0
	var max_running := 0
	var cancelled := false
	func install_pack(files_dir: String, uproject: String, backup_root := "", _progress := Callable()) -> Dictionary:
		calls.append(["install_pack", files_dir, uproject])
		if not install_ok:
			return {"ok": false, "error": "install failed", "content_folders": [], "maps": [], "backed_up": 0}
		return {"ok": true, "error": "", "content_folders": ["P"], "maps": ["/Game/P/Maps/Overview"], "backed_up": 0}
	func pick_scene(maps: Array, preference: String) -> String:
		return maps[0] if preference == "auto" and not maps.is_empty() else ("" if preference == "meshes" else preference)
	func commandlet_args(uproject, content_path, map, output_dir, log_path, options) -> PackedStringArray:
		calls.append(["commandlet_args", content_path, map, output_dir])
		return PackedStringArray([uproject, "-run=UnrealToGodot", "-ContentPath=" + content_path, "-Map=" + map, "-Output=" + output_dir])
	func editor_cmd(engine_dir: String) -> String:
		return engine_dir + "/UnrealEditor-Cmd"
	func run_commandlet(executable: String, args: PackedStringArray, log_path: String, on_progress: Callable) -> Dictionary:
		calls.append(["run_commandlet", executable, args])
		running += 1
		max_running = maxi(max_running, running)
		for i in convert_frames:
			await Engine.get_main_loop().process_frame
			on_progress.call({"current": i + 1, "total": convert_frames, "stage": "mesh"})
		running -= 1
		if cancelled:
			return {"ok": false, "exit_code": -1, "log_tail": "", "cancelled": true}
		return {"ok": convert_ok, "exit_code": 0 if convert_ok else 1, "log_tail": "last lines", "cancelled": false}
	func cancel() -> void:
		cancelled = true


class FakeImporter extends RefCounted:
	var calls: Array = []
	var import_ok := true
	func slug(title: String) -> String:
		return title.to_lower().replace(" ", "_")
	func import_export(export_dir: String, target_res_dir: String, meta: Dictionary, target_abs := "", consume := false, _progress := Callable()) -> Dictionary:
		calls.append(["import_export", export_dir, target_res_dir, meta])
		return {"ok": import_ok, "error": "" if import_ok else "import failed", "scene": target_res_dir + "/Overview.tscn"}
	## Name of an archive the extraction leaves behind (a .rar no tool could open).
	var leave_archive := ""
	func extract_zips(dir: String, _progress := Callable()) -> Dictionary:
		calls.append(["extract_zips", dir])
		var archives: Array = []
		if leave_archive != "":
			DirAccess.make_dir_recursive_absolute(dir.path_join("source"))
			var f := FileAccess.open(dir.path_join("source").path_join(leave_archive), FileAccess.WRITE)
			f.store_string("Rar!")
			f.close()
			archives.append(dir.path_join("source").path_join(leave_archive))
		return {"ok": true, "error": "", "extracted": 1, "archives": archives}
	## Runs on the jobs' background thread: reports progress and lasts a few
	## frames, so the main thread sees the report.
	func import_direct(files_dir: String, target_res_dir: String, meta: Dictionary, _target_abs := "", extras: Array = [], progress := Callable()) -> Dictionary:
		calls.append(["import_direct", files_dir, target_res_dir, meta, extras, OS.get_thread_caller_id() != OS.get_main_thread_id()])
		if progress.is_valid():
			progress.call(1, 2, "Copying model.glb")
		OS.delay_msec(100)
		return {"ok": import_ok, "error": "" if import_ok else "import failed", "scene": target_res_dir + "/model.glb"}
