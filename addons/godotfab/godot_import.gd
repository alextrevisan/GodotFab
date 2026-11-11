@tool
extends RefCounted
## Imports a downloaded asset into the Godot project: either an UnrealToGodot
## export (`import_export`) or a direct glTF/FBX download (`extract_zips` +
## `import_direct`). Every function is static and headless-safe.

const Log = preload("res://addons/godotfab/log.gd")
const ExportFixes = preload("res://addons/godotfab/export_fixes.gd")

const MANIFEST_FILE := ".godotfab.json"
const SLUG_MAX := 48
## Text files of an export whose `res://` references are rewritten.
const TEXT_EXTENSIONS := ["tscn", "tres", "import", "gd", "gdshader", "gdshaderinc"]
const MODEL_EXTENSIONS := ["glb", "gltf", "bin", "fbx", "obj", "mtl"]
const TEXTURE_EXTENSIONS := ["png", "jpg", "jpeg", "tga", "exr", "webp", "tif", "tiff", "bmp", "hdr"]
## Scene candidates for the direct path, in order of preference.
const SCENE_EXTENSIONS := ["glb", "gltf", "fbx"]


# --- Names and paths -----------------------------------------------------------

## Folder name for a listing title: ASCII letters, digits, `_` and `-`, lowercase,
## at most SLUG_MAX characters; "asset" when nothing is left.
static func slug(title: String) -> String:
	var out := ""
	for ch in title.to_lower():
		var code := ch.unicode_at(0)
		var is_alnum := (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		if is_alnum or ch == "-":
			out += ch
		elif ch == " " or ch == "_":
			out += "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.lstrip("_-").rstrip("_-")
	out = out.left(SLUG_MAX).rstrip("_-")
	return out if out != "" else "asset"


## Rewrites `res:///x` and `res://x` to `res://<prefix>/x`; `uid://` is left alone.
static func rewrite_paths(text: String, prefix: String) -> String:
	var clean := prefix.strip_edges().lstrip("/").rstrip("/")
	if clean == "":
		return text
	return text.replace("res:///", "res://").replace("res://", "res://" + clean + "/")


## `res://fab_assets/p` -> `fab_assets/p` (also accepts a plain prefix).
static func _prefix_of(target_res_dir: String) -> String:
	return target_res_dir.trim_prefix("res://").lstrip("/").rstrip("/")


static func _res_path(target_res_dir: String, relative: String) -> String:
	return "res://" + _prefix_of(target_res_dir) + "/" + relative.lstrip("/")


static func _target_abs_of(target_res_dir: String, target_abs: String) -> String:
	if target_abs != "":
		return target_abs.rstrip("/")
	return ProjectSettings.globalize_path(target_res_dir).rstrip("/")


# --- UnrealToGodot export ------------------------------------------------------

## Imports an UnrealToGodot export into `target_res_dir` (minus `project.godot`
## and `.godot/`), rewriting resource paths, and writes `.godotfab.json`.
## The new tree is built and fixed next to the target, then synced into it:
## files with the same size and MD5 are left untouched, so a reimport (after
## fixing the exporter) only makes Godot reimport what really changed.
## [param consume] moves the export's binary files instead of copying them
## (instant when the export is on the project's disk); the jobs pass true for
## their own staging folder. `target_abs` overrides the globalized target
## directory (tests). [param progress] is called as (done, total, label)
## (total 0 when unknown); it and the whole import may run off the main
## thread. Returns {ok, error, scene, updated, unchanged, removed}.
static func import_export(export_dir: String, target_res_dir: String, meta: Dictionary, target_abs := "", consume := false, progress := Callable()) -> Dictionary:
	var src := export_dir.rstrip("/")
	if not DirAccess.dir_exists_absolute(src):
		return _fail("Export folder not found: %s" % src)
	var target := _target_abs_of(target_res_dir, target_abs)
	var prefix := _prefix_of(target_res_dir)
	var build := target + ".godotfab-new"
	_remove_dir(build)
	var copied := [0]
	var err := _copy_export_tree(src, build, "", prefix, consume, func(file: String) -> void:
		copied[0] += 1
		if copied[0] % 20 == 1:
			_report(progress, copied[0], 0, "Copying %s" % file))
	if err != "":
		_remove_dir(build)
		return _fail(err)
	_report(progress, 0, 0, "Fixing the export")
	ExportFixes.remap_uids(build, target_res_dir)
	ExportFixes.fix_stale_uid_refs(build, target_res_dir)
	ExportFixes.fix_export_tree(build)
	# The commandlet names the level in godotfab_done.txt (scene=X.tscn);
	# a manual export falls back to the first root scene.
	var scene_file := ""
	var done_file := build.path_join("godotfab_done.txt")
	if FileAccess.file_exists(done_file):
		for line in FileAccess.get_file_as_string(done_file).split("\n"):
			if line.begins_with("scene=") and FileAccess.file_exists(build.path_join(line.substr(6).strip_edges())):
				scene_file = line.substr(6).strip_edges()
		DirAccess.remove_absolute(done_file)
	if scene_file == "":
		for file in _sorted_files(build):
			if file.get_extension() == "tscn" and file != "WorldEnvironment.tscn":
				scene_file = file
				break
	if scene_file == "":
		Log.warning("No level scene found in export %s" % src)
	_report(progress, 0, 0, "Moving files into the project")
	var synced := _sync_tree(build, target)
	_remove_dir(build)
	if synced.error != "":
		return _fail(synced.error)
	ExportFixes.register_uids(target, target_res_dir)
	Log.info("Synced %s: %d files updated, %d unchanged, %d removed" % [target, synced.updated, synced.unchanged, synced.removed])
	var result := _finish(target, meta, _res_path(target_res_dir, scene_file) if scene_file != "" else "")
	if result.ok:
		_rescan()
	result.merge({"updated": synced.updated, "unchanged": synced.unchanged, "removed": synced.removed})
	return result


## Moves the files of [param build] into [param target], skipping those that
## are already identical. A `.import` whose asset didn't change keeps Godot's
## rewritten version (cache paths and every parameter) when it has the same
## uid. Files missing from [param build] are removed, except the manifest and
## the `.import`/`.uid` Godot generated for files that are still there.
static func _sync_tree(build: String, target: String) -> Dictionary:
	var result := {"error": "", "updated": 0, "unchanged": 0, "removed": 0}
	var files: Array[String] = []
	_list_relative(build, "", files)
	var in_build := {}
	for rel in files:
		in_build[rel] = true
	var unchanged := {}
	# Assets first, so each .import knows whether its asset changed.
	files.sort_custom(func(a: String, b: String): return (not a.ends_with(".import")) and b.ends_with(".import") or (a.ends_with(".import") == b.ends_with(".import") and a < b))
	for rel in files:
		var from := build.path_join(rel)
		var to := target.path_join(rel)
		if FileAccess.file_exists(to) and (_same_file(from, to) or _keep_godot_import(rel, from, to, in_build, unchanged)):
			unchanged[rel] = true
			result.unchanged += 1
			continue
		var err := DirAccess.make_dir_recursive_absolute(to.get_base_dir())
		if err == OK and FileAccess.file_exists(to):
			err = DirAccess.remove_absolute(to)
		if err == OK and DirAccess.rename_absolute(from, to) != OK:
			err = DirAccess.copy_absolute(from, to)
		if err != OK:
			result.error = "Cannot update %s: %s" % [to, error_string(err)]
			return result
		if rel.ends_with(".import"):
			forget_import_cache(to.trim_suffix(".import"))
		result.updated += 1
	var existing: Array[String] = []
	_list_relative(target, "", existing)
	for rel in existing:
		if in_build.has(rel) or rel == MANIFEST_FILE:
			continue
		var base := rel.get_basename()
		if rel.get_extension() in ["import", "uid"] and in_build.has(base):
			continue
		DirAccess.remove_absolute(target.path_join(rel))
		result.removed += 1
	_remove_empty_dirs(target)
	return result


## Deletes the "<file>-<md5 of res path>.md5" Godot keeps in
## .godot/imported for [param asset_abs] (an absolute path inside the
## project). A new .import from the exporter has no cache paths; when the
## asset itself is byte-identical to what Godot imported before (the pack
## was deleted and downloaded again), that md5 file still matches and Godot
## skips the reimport, so the .import never gets its paths and every texture
## and mesh fails to load. Without the md5 file Godot always reimports.
## Returns true when a file was deleted.
static func forget_import_cache(asset_abs: String) -> bool:
	var res := ProjectSettings.localize_path(asset_abs)
	if not res.begins_with("res://"):
		return false
	var md5 := ProjectSettings.globalize_path("res://.godot/imported/%s-%s.md5" % [res.get_file(), res.md5_text()])
	return FileAccess.file_exists(md5) and DirAccess.remove_absolute(md5) == OK


static func _same_file(a: String, b: String) -> bool:
	var fa := FileAccess.open(a, FileAccess.READ)
	var fb := FileAccess.open(b, FileAccess.READ)
	if fa == null or fb == null or fa.get_length() != fb.get_length():
		return false
	fa.close()
	fb.close()
	return FileAccess.get_md5(a) == FileAccess.get_md5(b)


static func _keep_godot_import(rel: String, from: String, to: String, in_build: Dictionary, unchanged: Dictionary) -> bool:
	if not rel.ends_with(".import"):
		return false
	var asset := rel.trim_suffix(".import")
	if not in_build.has(asset) or not unchanged.has(asset):
		return false
	var uid_re := RegEx.create_from_string("(?m)^uid=\"([^\"]*)\"")
	var a := uid_re.search(FileAccess.get_file_as_string(from))
	var b := uid_re.search(FileAccess.get_file_as_string(to))
	return a != null and b != null and a.get_string(1) == b.get_string(1)


static func _list_relative(root: String, relative: String, out: Array[String]) -> void:
	var dir := DirAccess.open(root.path_join(relative) if relative != "" else root)
	if dir == null:
		return
	dir.include_hidden = true
	for file in dir.get_files():
		out.append(relative.path_join(file) if relative != "" else file)
	for sub in dir.get_directories():
		_list_relative(root, relative.path_join(sub) if relative != "" else sub, out)


static func _remove_empty_dirs(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	dir.include_hidden = true
	var empty := dir.get_files().is_empty()
	for sub in dir.get_directories():
		if not _remove_empty_dirs(path.path_join(sub)):
			empty = false
	if empty:
		DirAccess.remove_absolute(path)
	return empty


static func _copy_export_tree(src: String, dst: String, relative: String, prefix: String, consume := false, on_file := Callable()) -> String:
	var src_dir := src.path_join(relative) if relative != "" else src
	var dir := DirAccess.open(src_dir)
	if dir == null:
		return "Cannot open %s: %s" % [src_dir, error_string(DirAccess.get_open_error())]
	dir.include_hidden = true
	var dst_dir := dst.path_join(relative) if relative != "" else dst
	var err := DirAccess.make_dir_recursive_absolute(dst_dir)
	if err != OK:
		return "Cannot create %s: %s" % [dst_dir, error_string(err)]
	for file in dir.get_files():
		if relative == "" and file == "project.godot":
			continue
		var from := src_dir.path_join(file)
		var to := dst_dir.path_join(file)
		var ext := file.get_extension().to_lower()
		if on_file.is_valid():
			on_file.call(file)
		if ext in TEXT_EXTENSIONS:
			var text := FileAccess.get_file_as_string(from)
			if FileAccess.get_open_error() != OK:
				return "Cannot read %s" % from
			if ext == "import":
				text = _strip_import_cache_lines(text)
			text = rewrite_paths(text, prefix)
			var f := FileAccess.open(to, FileAccess.WRITE)
			if f == null:
				return "Cannot write %s: %s" % [to, error_string(FileAccess.get_open_error())]
			f.store_string(text)
			f.close()
		elif consume and DirAccess.rename_absolute(from, to) == OK:
			pass
		else:
			err = DirAccess.copy_absolute(from, to)
			if err != OK:
				return "Cannot copy %s: %s" % [from, error_string(err)]
	for sub in dir.get_directories():
		if relative == "" and sub == ".godot":
			continue
		var sub_err := _copy_export_tree(src, dst, relative.path_join(sub) if relative != "" else sub, prefix, consume, on_file)
		if sub_err != "":
			return sub_err
	return ""


## Drops the `path=`, `path.<fmt>=` and `dest_files=` lines of a `.import` file:
## they point into `.godot/imported/` and are regenerated on the next scan.
static func _strip_import_cache_lines(text: String) -> String:
	var kept: PackedStringArray = []
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("dest_files=") or trimmed.begins_with("path=") or trimmed.begins_with("path."):
			continue
		kept.append(line)
	return "\n".join(kept)


# --- Direct glTF/FBX download --------------------------------------------------

## Extracts every `*.zip` under `dir` (recursively, nested zips too) into a
## `<name>_extracted/` folder next to it and deletes the zip. Entries whose path
## would escape that folder abort the extraction of that zip.
## [param progress] is called as (done, total, label) per entry.
static func extract_zips(dir: String, progress := Callable()) -> Dictionary:
	var extracted := 0
	while true:
		var zips := _find_zips(dir.rstrip("/"))
		if zips.is_empty():
			break
		for zip_path in zips:
			var err := _extract_zip(zip_path, progress)
			if err != "":
				return {"ok": false, "error": err, "extracted": extracted}
			extracted += 1
	return {"ok": true, "error": "", "extracted": extracted}


static func _find_zips(dir: String) -> Array[String]:
	var found: Array[String] = []
	var d := DirAccess.open(dir)
	if d == null:
		return found
	d.include_hidden = true
	for file in d.get_files():
		if file.get_extension().to_lower() == "zip":
			found.append(dir.path_join(file))
	for sub in d.get_directories():
		found.append_array(_find_zips(dir.path_join(sub)))
	return found


static func _extract_zip(zip_path: String, progress := Callable()) -> String:
	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		return "Cannot open zip %s: %s" % [zip_path, error_string(err)]
	var out_dir := zip_path.get_basename() + "_extracted"
	var entries := reader.get_files()
	# Validate every entry before writing anything.
	for entry in entries:
		if not _is_safe_entry(entry):
			reader.close()
			return "Unsafe path in %s: %s" % [zip_path.get_file(), entry]
	err = DirAccess.make_dir_recursive_absolute(out_dir)
	if err != OK:
		reader.close()
		return "Cannot create %s: %s" % [out_dir, error_string(err)]
	for i in entries.size():
		var entry := entries[i]
		_report(progress, i, entries.size(), "Extracting %s" % zip_path.get_file())
		var dest := out_dir.path_join(entry.replace("\\", "/").simplify_path())
		if entry.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(dest)
			continue
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var f := FileAccess.open(dest, FileAccess.WRITE)
		if f == null:
			reader.close()
			return "Cannot write %s: %s" % [dest, error_string(FileAccess.get_open_error())]
		f.store_buffer(reader.read_file(entry))
		f.close()
	reader.close()
	err = DirAccess.remove_absolute(zip_path)
	if err != OK:
		return "Cannot delete %s: %s" % [zip_path, error_string(err)]
	Log.verbose("Extracted %s (%d entries)" % [zip_path.get_file(), entries.size()])
	return ""


## True when the zip entry stays inside the extraction folder.
static func _is_safe_entry(entry: String) -> bool:
	var p := entry.replace("\\", "/")
	if p == "" or p.begins_with("/"):
		return false
	if p.length() >= 2 and p[1] == ":":
		return false
	for part in p.split("/"):
		if part == "..":
			return false
	var norm := p.simplify_path()
	return not (norm == ".." or norm.begins_with("../") or norm.begins_with("/"))


## Copies the model (`MODEL_EXTENSIONS`) and texture (`TEXTURE_EXTENSIONS`)
## files of a direct download into `target_res_dir`, keeping their layout
## relative to the shallowest folder that holds a model file; `scene` is the
## first `.glb`, else `.gltf`, else `.fbx`.
## [param extras] are folders of the listing's additional files (a separate
## textures.zip, say): their contents land next to the model, with each
## extracted zip's own layout, so the paths the model references resolve.
## [param progress] is called as (done, total, label) per copied file.
static func import_direct(files_dir: String, target_res_dir: String, meta: Dictionary, target_abs := "", extras: Array = [], progress := Callable()) -> Dictionary:
	var src := files_dir.rstrip("/")
	if not DirAccess.dir_exists_absolute(src):
		return _fail("Files folder not found: %s" % src)
	var target := _target_abs_of(target_res_dir, target_abs)
	var root := _model_root(src)
	var count := [0]
	var on_file := func(file: String) -> void:
		count[0] += 1
		_report(progress, count[0], 0, "Copying %s" % file)
	return _replace_target(target, func() -> Dictionary:
		var copied: Array[String] = []
		var err := _copy_assets(root, target, "", copied, on_file)
		if err != "":
			return _fail(err)
		for extra in extras:
			err = _copy_extras(str(extra).rstrip("/"), target, on_file)
			if err != "":
				return _fail(err)
		if copied.is_empty():
			return _fail("No model or texture files found in %s" % src)
		var scene := ""
		for ext in SCENE_EXTENSIONS:
			for rel in copied:
				if rel.get_extension().to_lower() == ext:
					scene = _res_path(target_res_dir, rel)
					break
			if scene != "":
				break
		return _finish(target, meta, scene)
	)


## The shallowest directory (breadth-first, sorted) that directly contains a
## model file; `src` itself when there is none.
static func _model_root(src: String) -> String:
	var queue: Array[String] = [src]
	while not queue.is_empty():
		var dir: String = queue.pop_front()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for file in _sorted_files(dir):
			if file.get_extension().to_lower() in MODEL_EXTENSIONS:
				return dir
		var subs := d.get_directories()
		subs.sort()
		for sub in subs:
			queue.append(dir.path_join(sub))
	return src


## Copies the assets of an additional-files folder into [param dst]: an
## extracted zip (`<name>_extracted`) is merged at the top, keeping its
## inner layout; loose files and other folders keep their place.
static func _copy_extras(src: String, dst: String, on_file := Callable()) -> String:
	var d := DirAccess.open(src)
	if d == null:
		return ""
	var ignored: Array[String] = []
	for file in _sorted_files(src):
		var ext := file.get_extension().to_lower()
		if ext in MODEL_EXTENSIONS or ext in TEXTURE_EXTENSIONS:
			DirAccess.make_dir_recursive_absolute(dst)
			if on_file.is_valid():
				on_file.call(file)
			var err := DirAccess.copy_absolute(src.path_join(file), dst.path_join(file))
			if err != OK:
				return "Cannot copy %s: %s" % [src.path_join(file), error_string(err)]
	var subs := d.get_directories()
	subs.sort()
	for sub in subs:
		var sub_dst := dst if sub.ends_with("_extracted") else dst.path_join(sub)
		var err := _copy_assets(src.path_join(sub), sub_dst, "", ignored, on_file)
		if err != "":
			return err
	return ""


static func _copy_assets(src: String, dst: String, relative: String, copied: Array[String], on_file := Callable()) -> String:
	var src_dir := src.path_join(relative) if relative != "" else src
	var d := DirAccess.open(src_dir)
	if d == null:
		return "Cannot open %s: %s" % [src_dir, error_string(DirAccess.get_open_error())]
	var dst_dir := dst.path_join(relative) if relative != "" else dst
	for file in _sorted_files(src_dir):
		var ext := file.get_extension().to_lower()
		if not (ext in MODEL_EXTENSIONS or ext in TEXTURE_EXTENSIONS):
			continue
		var err := DirAccess.make_dir_recursive_absolute(dst_dir)
		if err != OK:
			return "Cannot create %s: %s" % [dst_dir, error_string(err)]
		if on_file.is_valid():
			on_file.call(file)
		err = DirAccess.copy_absolute(src_dir.path_join(file), dst_dir.path_join(file))
		if err != OK:
			return "Cannot copy %s: %s" % [src_dir.path_join(file), error_string(err)]
		copied.append(relative.path_join(file) if relative != "" else file)
	var subs := d.get_directories()
	subs.sort()
	for sub in subs:
		var sub_err := _copy_assets(src, dst, relative.path_join(sub) if relative != "" else sub, copied, on_file)
		if sub_err != "":
			return sub_err
	return ""


# --- Shared helpers ------------------------------------------------------------

## Runs `fill` into a fresh `target`: an existing target is moved to
## `<target>.old` first, deleted on success and restored on failure.
static func _replace_target(target: String, fill: Callable) -> Dictionary:
	var backup := target + ".old"
	var had_backup := false
	if DirAccess.dir_exists_absolute(target):
		if DirAccess.dir_exists_absolute(backup):
			_remove_dir(backup)
		var err := DirAccess.rename_absolute(target, backup)
		if err != OK:
			return _fail("Cannot move %s aside: %s" % [target, error_string(err)])
		had_backup = true
	var result: Dictionary = fill.call()
	if result.ok:
		if had_backup:
			_remove_dir(backup)
		_rescan()
	else:
		_remove_dir(target)
		if had_backup:
			DirAccess.rename_absolute(backup, target)
	return result


static func _finish(target: String, meta: Dictionary, scene: String) -> Dictionary:
	var info := meta.duplicate()
	info["scene"] = scene
	info["imported_at"] = int(Time.get_unix_time_from_system())
	info["format"] = meta.get("format", "")
	var f := FileAccess.open(target.path_join(MANIFEST_FILE), FileAccess.WRITE)
	if f == null:
		return _fail("Cannot write %s: %s" % [target.path_join(MANIFEST_FILE), error_string(FileAccess.get_open_error())])
	f.store_string(JSON.stringify(info, "\t"))
	f.close()
	Log.info("Imported into %s (scene: %s)" % [target, scene if scene != "" else "none"])
	return {"ok": true, "error": "", "scene": scene}


## Asks the editor to scan for the new files; deferred to the main thread
## when the import runs on a background thread.
static func _rescan() -> void:
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		fs.scan()
	else:
		fs.scan.call_deferred()


static func _report(progress: Callable, done: int, total: int, label: String) -> void:
	if progress.is_valid():
		progress.call(done, total, label)


static func _fail(error: String) -> Dictionary:
	Log.error(error)
	return {"ok": false, "error": error, "scene": ""}


static func _sorted_files(dir: String) -> PackedStringArray:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	return files


static func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for file in d.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
