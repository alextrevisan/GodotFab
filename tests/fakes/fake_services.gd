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
	var format_files: Array = [{"uid": "f1", "name": "source.zip", "status": "ready"}]
	var format_versions: Array = []
	var manifest_bytes := PackedByteArray([1, 2, 3])
	var add_result := {"ok": true, "error": "", "needs_web": false, "unauthorized": false}
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
		return {"ok": true, "error": "", "files": format_files, "versions": format_versions}

	func file_download_info(uid: String, code: String, file_uid: String) -> Dictionary:
		calls.append(["file_download_info", uid, code, file_uid])
		await Engine.get_main_loop().process_frame
		return _pointers()

	func _pointers() -> Dictionary:
		if pointers_unauthorized:
			return {"ok": false, "error": "401", "unauthorized": true, "build_version": "", "sources": []}
		if not pointers_ok:
			return {"ok": false, "error": "rate limited", "unauthorized": false, "build_version": "", "sources": []}
		return {"ok": true, "error": "", "unauthorized": false, "build_version": "1",
			"sources": [{"manifest_url": "https://cdn/m?sig", "base_url": "https://cdn"}]}

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
		return {"ok": true, "error": "", "files_dir": staging.path_join("files"), "files": [staging.path_join("files/Content/P/a.uasset")]}


class FakeBridge extends RefCounted:
	var calls: Array = []
	var install_ok := true
	var convert_ok := true
	var convert_frames := 2
	var running := 0
	var max_running := 0
	var cancelled := false
	func install_pack(files_dir: String, uproject: String, backup_root := "") -> Dictionary:
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
	func import_export(export_dir: String, target_res_dir: String, meta: Dictionary) -> Dictionary:
		calls.append(["import_export", export_dir, target_res_dir, meta])
		return {"ok": import_ok, "error": "" if import_ok else "import failed", "scene": target_res_dir + "/Overview.tscn"}
	func extract_zips(dir: String) -> Dictionary:
		calls.append(["extract_zips", dir])
		return {"ok": true, "error": "", "extracted": 1}
	func import_direct(files_dir: String, target_res_dir: String, meta: Dictionary) -> Dictionary:
		calls.append(["import_direct", files_dir, target_res_dir, meta])
		return {"ok": import_ok, "error": "" if import_ok else "import failed", "scene": target_res_dir + "/model.glb"}
