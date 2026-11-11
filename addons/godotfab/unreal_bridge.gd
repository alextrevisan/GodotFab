@tool
extends RefCounted
## Bridge to an Unreal Engine install and project: installs a downloaded pack
## into the project's Content folder, runs the UnrealToGodot commandlet and
## checks that engine, project and plugin are in place.
##
## Everything is static and pure except `run_commandlet` / `cancel`, which hold
## the process id of the running commandlet.

const Log = preload("res://addons/godotfab/log.gd")

const FINISHED_LINE := "GodotFab: export finished"
const FAILED_LINE := "GodotFab: export failed"
const COMPLETE_LINE := "Export Complete"
const PLUGIN_NAME := "UnrealToGodot"
const COMMANDLET_MARKER := "UnrealToGodotCommandlet"
const LOG_TAIL_LINES := 30
const LOG_TAIL_BYTES := 65536

## Override for tests: `func(executable: String, args: PackedStringArray) -> int`
## returning a pid (-1 on failure). Invalid Callable = `OS.create_process`.
var process_runner: Callable = Callable()
## Seconds between two polls of the process and its log.
var poll_interval: float = 1.0

var _pid: int = -1
var _cancelled: bool = false


# --- install -----------------------------------------------------------------

## Moves every file under `<files_dir>/Content/` into `<project>/Content/`,
## merging with what is there. Existing target files are moved first to
## `backup_root` (default `<project>/Saved/GodotFabBackups/<YYYYmmdd-HHMMSS>`)
## keeping their path relative to Content; target files identical to the
## downloaded ones stay as they are (downloading a pack again that is still
## installed backs nothing up). Files outside Content (manifest.json)
## are ignored. `uproject` is the .uproject file or the project directory.
## Returns {ok, error, content_folders: Array[String], maps: Array[String], backed_up: int, unchanged: int}.
static func install_pack(files_dir: String, uproject: String, backup_root := "", progress := Callable()) -> Dictionary:
	var result := {"ok": false, "error": "", "content_folders": [] as Array[String], "maps": [] as Array[String], "backed_up": 0, "unchanged": 0}
	var project_dir := project_dir_of(uproject)
	if project_dir.is_empty() or not DirAccess.dir_exists_absolute(project_dir):
		result.error = "Unreal project not found: %s" % uproject
		return result
	var source_root := files_dir.path_join("Content")
	if not DirAccess.dir_exists_absolute(source_root):
		result.error = "No Content folder in the downloaded pack: %s" % files_dir
		return result
	var target_root := project_dir.path_join("Content")
	if backup_root.is_empty():
		backup_root = project_dir.path_join("Saved/GodotFabBackups").path_join(_timestamp())
	var relative_files: Array[String] = []
	_list_files(source_root, "", relative_files)
	var folders := {}
	var maps: Array[String] = []
	for i in relative_files.size():
		var rel := relative_files[i]
		if progress.is_valid() and i % 20 == 0:
			progress.call(i, relative_files.size(), "Installing into the Unreal project")
		var source := source_root.path_join(rel)
		var target := target_root.path_join(rel)
		if FileAccess.file_exists(target) and same_content(source, target):
			DirAccess.remove_absolute(source)
			result.unchanged += 1
		else:
			if FileAccess.file_exists(target):
				var backup := backup_root.path_join(rel)
				var err := _move_file(target, backup)
				if err != OK:
					result.error = "Cannot back up %s to %s (%s)" % [target, backup, error_string(err)]
					return result
				result.backed_up += 1
			var err := _move_file(source, target)
			if err != OK:
				result.error = "Cannot move %s to %s (%s)" % [source, target, error_string(err)]
				return result
		if rel.contains("/") and not rel.get_slice("/", 0).begins_with("__External"):
			folders[rel.get_slice("/", 0)] = true
		if rel.get_extension().to_lower() == "umap":
			maps.append("/Game/" + rel.get_basename())
	_remove_empty_dirs(source_root)
	var content_folders: Array[String] = []
	content_folders.assign(folders.keys())
	content_folders.sort()
	result.content_folders = content_folders
	result.maps = order_maps(maps, target_root)
	result.ok = true
	Log.info("Installed %d files into %s (%d already there, %d backed up to %s)" % [relative_files.size(), target_root, result.unchanged, result.backed_up, backup_root if result.backed_up > 0 else "-"])
	return result


## True when both files have the same size and bytes.
static func same_content(a: String, b: String) -> bool:
	var fa := FileAccess.open(a, FileAccess.READ)
	var fb := FileAccess.open(b, FileAccess.READ)
	if fa == null or fb == null or fa.get_length() != fb.get_length():
		return false
	const BLOCK := 1 << 20
	while fa.get_position() < fa.get_length():
		if fa.get_buffer(BLOCK) != fb.get_buffer(BLOCK):
			return false
	return true


## Maps sorted by how much they hold, heaviest first (ties by path): the .umap
## size plus, for World Partition maps, every file under
## `__ExternalActors__/<map>` and `__ExternalObjects__/<map>`. Packs ship the
## main level next to small sublevels, and the heaviest one is the main level.
static func order_maps(maps: Array[String], content_root: String) -> Array[String]:
	var weights := {}
	for map in maps:
		var rel := map.trim_prefix("/Game/")
		var weight := _file_size(content_root.path_join(rel + ".umap"))
		for external in ["__ExternalActors__", "__ExternalObjects__"]:
			weight += _dir_size(content_root.path_join(external).path_join(rel))
		weights[map] = weight
	var ordered: Array[String] = maps.duplicate()
	ordered.sort_custom(func(a: String, b: String) -> bool:
		return weights[a] > weights[b] if weights[a] != weights[b] else a < b)
	return ordered


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file else 0


static func _dir_size(path: String) -> int:
	if not DirAccess.dir_exists_absolute(path):
		return 0
	var total := 0
	for file in DirAccess.get_files_at(path):
		total += _file_size(path.path_join(file))
	for dir in DirAccess.get_directories_at(path):
		total += _dir_size(path.path_join(dir))
	return total


## Content paths for the commandlet: every top-level folder of the pack, comma separated.
static func content_paths(content_folders: Array) -> String:
	var paths := PackedStringArray()
	for folder in content_folders:
		paths.append("/Game/" + str(folder))
	return ",".join(paths)


## True when every folder of a pack ([param content_folders], as recorded at
## install time) is still in the Unreal project's Content, so it can be
## converted again without downloading it.
static func pack_installed(uproject: String, content_folders: Array) -> bool:
	var project_dir := project_dir_of(uproject)
	if project_dir.is_empty() or content_folders.is_empty():
		return false
	for folder in content_folders:
		if not DirAccess.dir_exists_absolute(project_dir.path_join("Content").path_join(str(folder))):
			return false
	return true


## Directory of a project given its .uproject file or the directory itself.
static func project_dir_of(uproject: String) -> String:
	if uproject.is_empty():
		return ""
	var path := uproject.rstrip("/")
	if DirAccess.dir_exists_absolute(path):
		return path
	if path.get_extension().to_lower() == "uproject":
		return path.get_base_dir()
	return ""


static func _timestamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]


static func _list_files(root: String, rel_dir: String, out: Array[String]) -> void:
	var dir_path := root.path_join(rel_dir) if not rel_dir.is_empty() else root
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.include_hidden = true
	var subdirs := dir.get_directories()
	subdirs.sort()
	for sub in subdirs:
		_list_files(root, rel_dir.path_join(sub) if not rel_dir.is_empty() else sub, out)
	var files := dir.get_files()
	files.sort()
	for file in files:
		out.append(rel_dir.path_join(file) if not rel_dir.is_empty() else file)


## Rename when source and target share a filesystem, else copy and delete.
static func _move_file(source: String, target: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	if err != OK:
		return err
	if DirAccess.rename_absolute(source, target) == OK:
		return OK
	err = DirAccess.copy_absolute(source, target)
	if err != OK:
		return err
	return DirAccess.remove_absolute(source)


static func _remove_empty_dirs(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for sub in dir.get_directories():
		_remove_empty_dirs(path.path_join(sub))
	if DirAccess.get_files_at(path).is_empty() and DirAccess.get_directories_at(path).is_empty():
		DirAccess.remove_absolute(path)


# --- commandlet --------------------------------------------------------------

## Path of UnrealEditor-Cmd inside an engine install for the given OS name
## (`OS.get_name()` values: "Linux", "Windows", "macOS").
static func editor_cmd(engine_dir: String, os_name := OS.get_name()) -> String:
	var base := engine_dir.rstrip("/").path_join("Engine/Binaries")
	match os_name:
		"Windows":
			return base.path_join("Win64/UnrealEditor-Cmd.exe")
		"macOS":
			return base.path_join("Mac/UnrealEditor-Cmd")
		_:
			return base.path_join("Linux/UnrealEditor-Cmd")


## Arguments for `UnrealEditor-Cmd`. `options` keys (all optional bools):
## skinned_as_static, nanite_original, no_textures, no_physics.
static func commandlet_args(uproject: String, content_path: String, map: String, output_dir: String, log_path: String, options: Dictionary) -> PackedStringArray:
	var args := PackedStringArray([uproject, "-run=UnrealToGodot.UnrealToGodot", "-ContentPath=%s" % content_path])
	if not map.is_empty():
		args.append("-Map=%s" % map)
	args.append("-Output=%s" % output_dir)
	if options.get("skinned_as_static", false):
		args.append("-SkinnedAsStatic")
	if options.get("nanite_original", false):
		args.append("-NaniteOriginal")
	if options.get("no_textures", false):
		args.append("-NoTextures")
	if options.get("no_physics", false):
		args.append("-NoPhysics")
	args.append_array(PackedStringArray(["-unattended", "-nopause", "-nosplash", "-AllowCommandletRendering", "-log", "-abslog=%s" % log_path]))
	return args


## Arguments to open the project (and optionally a map) in the Unreal Editor.
static func editor_open_args(uproject: String, map: String) -> PackedStringArray:
	var args := PackedStringArray([uproject])
	if not map.is_empty():
		args.append(map)
	return args


## The map to export. "auto": a map named Overview, else one containing Demo,
## else the first (install_pack lists the heaviest map first); "meshes": none (grid of all meshes); anything else is a map path.
static func pick_scene(maps: Array, preference: String) -> String:
	match preference:
		"auto":
			for map in maps:
				if String(map).ends_with("/Overview"):
					return map
			for map in maps:
				if String(map).contains("Demo"):
					return map
			return maps[0] if not maps.is_empty() else ""
		"meshes", "":
			return ""
		_:
			return preference


## Progress from the last known line of an export log:
## {current, total, stage} with stage "load" | "mesh" | "texture" | "material" | "done" | "failed" | "".
static func parse_progress(log_text: String) -> Dictionary:
	var progress := {"current": 0, "total": 0, "stage": ""}
	var counted := RegEx.create_from_string("(Writing Mesh|Writing Texture|Processing Materials|GodotFab: Loading Mesh)\\b.*\\(\\s*(\\d+)\\s*/\\s*(\\d+)\\s*\\)\\s*$")
	var have_count := false
	var lines := log_text.split("\n")
	for i in range(lines.size() - 1, -1, -1):
		var line := lines[i].strip_edges()
		if line.is_empty():
			continue
		if progress.stage.is_empty():
			if line.contains(FAILED_LINE):
				progress.stage = "failed"
				continue
			if line.contains(FINISHED_LINE) or line.contains(COMPLETE_LINE):
				progress.stage = "done"
				continue
		var m := counted.search(line)
		if m == null:
			continue
		progress.current = int(m.get_string(2))
		progress.total = int(m.get_string(3))
		have_count = true
		if progress.stage.is_empty():
			match m.get_string(1):
				"Writing Mesh":
					progress.stage = "mesh"
				"Writing Texture":
					progress.stage = "texture"
				"GodotFab: Loading Mesh":
					progress.stage = "load"
				_:
					progress.stage = "material"
		break
	if progress.stage == "done" and have_count:
		progress.current = progress.total
	return progress


## Runs `executable args`, polling the process and `log_path` every
## `poll_interval` seconds; `on_progress(parse_progress(tail))` is called when
## the progress changes. Returns {ok, exit_code, log_tail, error, cancelled}:
## ok when the exit code is 0 and the log contains "GodotFab: export finished".
func run_commandlet(executable: String, args: PackedStringArray, log_path: String, on_progress: Callable) -> Dictionary:
	var result := {"ok": false, "exit_code": -1, "log_tail": "", "error": "", "cancelled": false}
	_cancelled = false
	Log.verbose("Running %s %s" % [executable, " ".join(args)])
	if process_runner.is_valid():
		_pid = process_runner.call(executable, args)
	else:
		_pid = OS.create_process(executable, args, false)
	if _pid <= 0:
		_pid = -1
		result.error = "Could not start %s" % executable
		Log.error(result.error)
		return result
	var last_progress := {}
	while not _cancelled and OS.is_process_running(_pid):
		await Engine.get_main_loop().create_timer(poll_interval).timeout
		if on_progress.is_valid():
			var progress := parse_progress(_read_tail(log_path))
			if progress != last_progress:
				last_progress = progress
				on_progress.call(progress)
	# OS.kill reaps the child, after which the pid cannot be queried any more.
	var exit_code := -1 if _cancelled else OS.get_process_exit_code(_pid)
	_pid = -1
	var tail := _read_tail(log_path)
	if on_progress.is_valid():
		var progress := parse_progress(tail)
		if progress != last_progress:
			on_progress.call(progress)
	result.exit_code = exit_code
	result.log_tail = last_lines(tail, LOG_TAIL_LINES)
	result.cancelled = _cancelled
	# The log decides: Unreal returns 1 whenever any "Error:" line was logged
	# during the run (e.g. a Vulkan init error on a headless shell) even
	# though the export finished and the files are complete.
	if _cancelled:
		result.error = "Cancelled"
	elif tail.contains(FAILED_LINE):
		result.error = "UnrealEditor-Cmd exited with code %d: %s" % [exit_code, _failed_reason(tail)]
	elif tail.contains(FINISHED_LINE):
		result.ok = true
		if exit_code != 0:
			Log.warning("Commandlet finished the export but exited with code %d (errors were logged; see %s)" % [exit_code, log_path])
	elif exit_code != 0:
		result.error = "UnrealEditor-Cmd exited with code %d" % exit_code
	else:
		result.error = "The commandlet exited with code 0 but never logged \"%s\"" % FINISHED_LINE
	if _cancelled:
		Log.info("Commandlet cancelled")
	elif not result.ok:
		Log.warning("Commandlet failed: %s" % result.error)
	return result


## Kills the commandlet started by `run_commandlet`, which then returns {ok: false, cancelled: true}.
func cancel() -> void:
	_cancelled = true
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)


func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


## The last `max_bytes` of a file as text ("" when missing).
static func _read_tail(path: String, max_bytes := LOG_TAIL_BYTES) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var length := f.get_length()
	if length > max_bytes:
		f.seek(length - max_bytes)
	var text := f.get_buffer(max_bytes).get_string_from_utf8()
	f.close()
	return text


## The reason after "GodotFab: export failed:" in the log, "" if absent.
static func _failed_reason(tail: String) -> String:
	var pos := tail.rfind(FAILED_LINE)
	if pos < 0:
		return ""
	var line := tail.substr(pos).split("\n")[0]
	return line.substr(FAILED_LINE.length()).trim_prefix(":").strip_edges()


static func last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges(false, true).split("\n")
	if lines.size() > count:
		lines = lines.slice(lines.size() - count)
	return "\n".join(lines)


# --- setup check -------------------------------------------------------------

## Verifies engine, project, plugin and commandlet. Returns
## {ok, engine_ok, project_ok, plugin_ok, commandlet_ok, messages: Array[String]}.
static func check_setup(engine_dir: String, uproject: String) -> Dictionary:
	var messages: Array[String] = []
	var cmd := editor_cmd(engine_dir)
	var engine_ok := FileAccess.file_exists(cmd)
	messages.append("Unreal Engine found: %s" % cmd if engine_ok else "Unreal Engine not found, expected %s. Set the engine path in the settings." % cmd)
	var project_ok := uproject.get_extension().to_lower() == "uproject" and FileAccess.file_exists(uproject)
	messages.append("Unreal project found: %s" % uproject if project_ok else "Unreal project not found: %s. Set the path of a .uproject file in the settings." % uproject)
	var plugin_dir := plugin_dir_of(uproject)
	var uplugin := plugin_dir.path_join("%s.uplugin" % PLUGIN_NAME)
	var plugin_ok := project_ok and FileAccess.file_exists(uplugin)
	messages.append("UnrealToGodot plugin found: %s" % plugin_dir if plugin_ok else "UnrealToGodot plugin not found, expected %s. Install the plugin into the project's Plugins folder." % uplugin)
	var so := plugin_dir.path_join("Binaries/Linux/libUnrealEditor-%s.so" % PLUGIN_NAME)
	var commandlet_ok := plugin_ok and FileAccess.file_exists(so) and bytes_contain(FileAccess.get_file_as_bytes(so), COMMANDLET_MARKER.to_utf8_buffer())
	if commandlet_ok:
		messages.append("UnrealToGodot commandlet found in %s" % so)
	elif plugin_ok and FileAccess.file_exists(so):
		messages.append("The plugin binary %s does not contain the UnrealToGodot commandlet. Rebuild the plugin with the commandlet source." % so)
	else:
		messages.append("Plugin binary with the UnrealToGodot commandlet not found: %s. Build the plugin for Linux." % so)
	return {
		"ok": engine_ok and project_ok and plugin_ok and commandlet_ok,
		"engine_ok": engine_ok,
		"project_ok": project_ok,
		"plugin_ok": plugin_ok,
		"commandlet_ok": commandlet_ok,
		"messages": messages,
	}


static func plugin_dir_of(uproject: String) -> String:
	return project_dir_of(uproject).path_join("Plugins").path_join(PLUGIN_NAME)


## Whether `needle` occurs in `haystack` (PackedByteArray.find only takes one byte).
static func bytes_contain(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	var n := needle.size()
	if n == 0 or haystack.size() < n:
		return false
	var first := needle[0]
	var last_start := haystack.size() - n
	var i := haystack.find(first, 0)
	while i != -1 and i <= last_start:
		if haystack.slice(i, i + n) == needle:
			return true
		i = haystack.find(first, i + 1)
	return false
