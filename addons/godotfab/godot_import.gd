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

## Copies an UnrealToGodot export into `target_res_dir` (minus `project.godot`
## and `.godot/`), rewriting resource paths, and writes `.godotfab.json`.
## `target_abs` overrides the globalized target directory (tests).
static func import_export(export_dir: String, target_res_dir: String, meta: Dictionary, target_abs := "") -> Dictionary:
	var src := export_dir.rstrip("/")
	if not DirAccess.dir_exists_absolute(src):
		return _fail("Export folder not found: %s" % src)
	var target := _target_abs_of(target_res_dir, target_abs)
	var prefix := _prefix_of(target_res_dir)
	return _replace_target(target, func() -> Dictionary:
		var err := _copy_export_tree(src, target, "", prefix)
		if err != "":
			return _fail(err)
		ExportFixes.remap_uids(target, target_res_dir)
		ExportFixes.fix_stale_uid_refs(target, target_res_dir)
		ExportFixes.fix_export_tree(target)
		ExportFixes.register_uids(target, target_res_dir)
		# The commandlet names the level in godotfab_done.txt (scene=X.tscn);
		# a manual export falls back to the first root scene.
		var scene := ""
		var done_file := target.path_join("godotfab_done.txt")
		if FileAccess.file_exists(done_file):
			for line in FileAccess.get_file_as_string(done_file).split("\n"):
				if line.begins_with("scene=") and FileAccess.file_exists(target.path_join(line.substr(6).strip_edges())):
					scene = _res_path(target_res_dir, line.substr(6).strip_edges())
			DirAccess.remove_absolute(done_file)
		if scene == "":
			for file in _sorted_files(target):
				if file.get_extension() == "tscn" and file != "WorldEnvironment.tscn":
					scene = _res_path(target_res_dir, file)
					break
		if scene == "":
			Log.warning("No level scene found in export %s" % src)
		return _finish(target, meta, scene)
	)


static func _copy_export_tree(src: String, dst: String, relative: String, prefix: String) -> String:
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
		else:
			err = DirAccess.copy_absolute(from, to)
			if err != OK:
				return "Cannot copy %s: %s" % [from, error_string(err)]
	for sub in dir.get_directories():
		if relative == "" and sub == ".godot":
			continue
		var sub_err := _copy_export_tree(src, dst, relative.path_join(sub) if relative != "" else sub, prefix)
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
static func extract_zips(dir: String) -> Dictionary:
	var extracted := 0
	while true:
		var zips := _find_zips(dir.rstrip("/"))
		if zips.is_empty():
			break
		for zip_path in zips:
			var err := _extract_zip(zip_path)
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


static func _extract_zip(zip_path: String) -> String:
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
	for entry in entries:
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
static func import_direct(files_dir: String, target_res_dir: String, meta: Dictionary, target_abs := "") -> Dictionary:
	var src := files_dir.rstrip("/")
	if not DirAccess.dir_exists_absolute(src):
		return _fail("Files folder not found: %s" % src)
	var target := _target_abs_of(target_res_dir, target_abs)
	var root := _model_root(src)
	return _replace_target(target, func() -> Dictionary:
		var copied: Array[String] = []
		var err := _copy_assets(root, target, "", copied)
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


static func _copy_assets(src: String, dst: String, relative: String, copied: Array[String]) -> String:
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
		err = DirAccess.copy_absolute(src_dir.path_join(file), dst_dir.path_join(file))
		if err != OK:
			return "Cannot copy %s: %s" % [src_dir.path_join(file), error_string(err)]
		copied.append(relative.path_join(file) if relative != "" else file)
	var subs := d.get_directories()
	subs.sort()
	for sub in subs:
		var sub_err := _copy_assets(src, dst, relative.path_join(sub) if relative != "" else sub, copied)
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


static func _rescan() -> void:
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()


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
