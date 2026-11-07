extends "res://tests/test_case.gd"

const UnrealBridge = preload("res://addons/godotfab/unreal_bridge.gd")

const MARKER := "UnrealToGodotCommandlet"


func _make_pack(files_dir: String) -> void:
	write_file(files_dir.path_join("Content/Pack/Meshes/a.uasset"), "new-a")
	write_file(files_dir.path_join("Content/Pack/Maps/Overview.umap"), "map")
	write_file(files_dir.path_join("manifest.json"), "{}")


func test_install_pack_merges_content() -> void:
	var files_dir := tmp_dir()
	var project_dir := tmp_dir()
	_make_pack(files_dir)
	write_file(project_dir.path_join("X.uproject"), "{}")
	var result := UnrealBridge.install_pack(files_dir, project_dir.path_join("X.uproject"))
	assert_true(result.ok, "install ok: %s" % result.get("error", ""))
	assert_eq(FileAccess.get_file_as_string(project_dir.path_join("Content/Pack/Meshes/a.uasset")), "new-a", "mesh moved")
	assert_true(FileAccess.file_exists(project_dir.path_join("Content/Pack/Maps/Overview.umap")), "map moved")
	assert_false(FileAccess.file_exists(files_dir.path_join("Content/Pack/Meshes/a.uasset")), "source removed")
	assert_true(FileAccess.file_exists(files_dir.path_join("manifest.json")), "manifest.json left alone")
	assert_false(FileAccess.file_exists(project_dir.path_join("Content/manifest.json")), "manifest.json not installed")
	assert_eq(result.content_folders, ["Pack"], "content_folders")
	assert_eq(result.maps, ["/Game/Pack/Maps/Overview"], "maps")
	assert_eq(result.backed_up, 0, "nothing backed up")
	assert_false(DirAccess.dir_exists_absolute(project_dir.path_join("Saved/GodotFabBackups")), "no backup dir created")


func test_install_pack_accepts_project_dir() -> void:
	var files_dir := tmp_dir()
	var project_dir := tmp_dir()
	_make_pack(files_dir)
	write_file(project_dir.path_join("X.uproject"), "{}")
	var result := UnrealBridge.install_pack(files_dir, project_dir)
	assert_true(result.ok, "install ok")
	assert_true(FileAccess.file_exists(project_dir.path_join("Content/Pack/Meshes/a.uasset")), "mesh moved")


func test_install_pack_backs_up_existing() -> void:
	var files_dir := tmp_dir()
	var project_dir := tmp_dir()
	_make_pack(files_dir)
	write_file(project_dir.path_join("X.uproject"), "{}")
	write_file(project_dir.path_join("Content/Pack/Meshes/a.uasset"), "old-a")
	write_file(project_dir.path_join("Content/Pack/Meshes/user.uasset"), "user")
	var result := UnrealBridge.install_pack(files_dir, project_dir.path_join("X.uproject"))
	assert_true(result.ok, "install ok")
	assert_eq(result.backed_up, 1, "one file backed up")
	assert_eq(FileAccess.get_file_as_string(project_dir.path_join("Content/Pack/Meshes/a.uasset")), "new-a", "new bytes installed")
	assert_eq(FileAccess.get_file_as_string(project_dir.path_join("Content/Pack/Meshes/user.uasset")), "user", "user file untouched")
	var backups := project_dir.path_join("Saved/GodotFabBackups")
	var stamps := DirAccess.get_directories_at(backups)
	assert_eq(stamps.size(), 1, "one backup timestamp dir")
	var stamp := String(stamps[0])
	assert_true(stamp.length() == 15 and stamp[8] == "-", "timestamp YYYYmmdd-HHMMSS: %s" % stamp)
	assert_eq(FileAccess.get_file_as_string(backups.path_join(stamp).path_join("Pack/Meshes/a.uasset")), "old-a", "old bytes in backup")
	assert_false(FileAccess.file_exists(backups.path_join(stamp).path_join("Pack/Meshes/user.uasset")), "user file not backed up")


func test_install_pack_custom_backup_root() -> void:
	var files_dir := tmp_dir()
	var project_dir := tmp_dir()
	var backup_root := tmp_dir().path_join("bk")
	_make_pack(files_dir)
	write_file(project_dir.path_join("X.uproject"), "{}")
	write_file(project_dir.path_join("Content/Pack/Maps/Overview.umap"), "oldmap")
	var result := UnrealBridge.install_pack(files_dir, project_dir, backup_root)
	assert_true(result.ok, "install ok")
	assert_eq(result.backed_up, 1, "backed up")
	assert_eq(FileAccess.get_file_as_string(backup_root.path_join("Pack/Maps/Overview.umap")), "oldmap", "backup in custom root")


func test_install_pack_missing_content() -> void:
	var files_dir := tmp_dir()
	var project_dir := tmp_dir()
	write_file(files_dir.path_join("manifest.json"), "{}")
	write_file(project_dir.path_join("X.uproject"), "{}")
	var result := UnrealBridge.install_pack(files_dir, project_dir)
	assert_false(result.ok, "no Content folder fails")
	assert_contains(result.error, "Content", "error mentions Content")
	var result2 := UnrealBridge.install_pack(files_dir, tmp_dir().path_join("missing"))
	assert_false(result2.ok, "missing project fails")


func test_editor_cmd_path() -> void:
	assert_eq(UnrealBridge.editor_cmd("/engine", "Linux"), "/engine/Engine/Binaries/Linux/UnrealEditor-Cmd")
	assert_eq(UnrealBridge.editor_cmd("/engine/", "Linux"), "/engine/Engine/Binaries/Linux/UnrealEditor-Cmd", "trailing slash")
	assert_eq(UnrealBridge.editor_cmd("C:/UE", "Windows"), "C:/UE/Engine/Binaries/Win64/UnrealEditor-Cmd.exe")
	assert_eq(UnrealBridge.editor_cmd("/engine", "macOS"), "/engine/Engine/Binaries/Mac/UnrealEditor-Cmd")
	assert_true(UnrealBridge.editor_cmd("/engine").ends_with("UnrealEditor-Cmd"), "default os")


func test_commandlet_args() -> void:
	var args := UnrealBridge.commandlet_args("/p/X.uproject", "/Game/Pack", "/Game/Pack/Maps/Overview", "/out", "/out/convert.log",
		{"skinned_as_static": true, "nanite_original": true, "no_textures": true, "no_physics": true})
	assert_eq(Array(args), [
		"/p/X.uproject", "-run=UnrealToGodot.UnrealToGodot", "-ContentPath=/Game/Pack", "-Map=/Game/Pack/Maps/Overview", "-Output=/out",
		"-SkinnedAsStatic", "-NaniteOriginal", "-NoTextures", "-NoPhysics",
		"-unattended", "-nopause", "-nosplash", "-AllowCommandletRendering", "-log", "-abslog=/out/convert.log",
	], "all options")
	var minimal := UnrealBridge.commandlet_args("/p/X.uproject", "/Game/Pack", "", "/out", "/out/convert.log", {})
	assert_eq(Array(minimal), [
		"/p/X.uproject", "-run=UnrealToGodot.UnrealToGodot", "-ContentPath=/Game/Pack", "-Output=/out",
		"-unattended", "-nopause", "-nosplash", "-AllowCommandletRendering", "-log", "-abslog=/out/convert.log",
	], "no map, no options")


func test_install_pack_world_partition() -> void:
	var files_dir := tmp_dir()
	var project_dir := tmp_dir()
	write_file(files_dir.path_join("Content/Maps/Atmospherics_WP.umap"), "small-sublevel-map")
	write_file(files_dir.path_join("Content/Maps/Village_P_WP.umap"), "wp")
	write_file(files_dir.path_join("Content/__ExternalActors__/Maps/Village_P_WP/0/AB/actor1.uasset"), "actor-actor-actor")
	write_file(files_dir.path_join("Content/__ExternalActors__/Maps/Village_P_WP/1/CD/actor2.uasset"), "actor-actor-actor")
	write_file(files_dir.path_join("Content/Megascans/Props/SM_Barrel.uasset"), "mesh")
	var result := UnrealBridge.install_pack(files_dir, project_dir)
	assert_true(result.ok, "install ok: %s" % result.get("error", ""))
	assert_eq(result.content_folders, ["Maps", "Megascans"], "external actor folders are not content")
	assert_eq(result.maps, ["/Game/Maps/Village_P_WP", "/Game/Maps/Atmospherics_WP"], "heaviest map first")
	assert_eq(UnrealBridge.pick_scene(result.maps, "auto"), "/Game/Maps/Village_P_WP", "auto picks the main level")


func test_content_paths() -> void:
	assert_eq(UnrealBridge.content_paths(["Pack"]), "/Game/Pack")
	assert_eq(UnrealBridge.content_paths(["Maps", "Megascans"]), "/Game/Maps,/Game/Megascans")


func test_editor_open_args() -> void:
	assert_eq(Array(UnrealBridge.editor_open_args("/p/X.uproject", "/Game/Pack/Maps/Overview")), ["/p/X.uproject", "/Game/Pack/Maps/Overview"])
	assert_eq(Array(UnrealBridge.editor_open_args("/p/X.uproject", "")), ["/p/X.uproject"])


func test_pick_scene() -> void:
	var maps := ["/Game/Pack/Maps/Demo_Night", "/Game/Pack/Maps/Overview", "/Game/Pack/Maps/Other"]
	assert_eq(UnrealBridge.pick_scene(maps, "auto"), "/Game/Pack/Maps/Overview", "Overview wins")
	assert_eq(UnrealBridge.pick_scene(["/Game/Pack/Maps/Other", "/Game/Pack/Maps/DemoMap"], "auto"), "/Game/Pack/Maps/DemoMap", "Demo second")
	assert_eq(UnrealBridge.pick_scene(["/Game/Pack/Maps/Other", "/Game/Pack/Maps/Second"], "auto"), "/Game/Pack/Maps/Other", "first map")
	assert_eq(UnrealBridge.pick_scene([], "auto"), "", "no maps")
	assert_eq(UnrealBridge.pick_scene(maps, "meshes"), "", "meshes mode")
	assert_eq(UnrealBridge.pick_scene(maps, "/Game/Pack/Maps/Other"), "/Game/Pack/Maps/Other", "explicit map")
	assert_eq(UnrealBridge.pick_scene(maps, ""), "", "empty preference")


func test_parse_progress() -> void:
	var mesh := "[2026.11.05-02.30.19:651][188]LogTemp: Writing Mesh /run/media/alex/S Backup L/Linux_Unreal_Engine_5.8.4/UnrealToGodot1/SmallStructures/VOL1/Meshes/SM_Loafing_Shed_01a.glb (1/540)\n"
	var mesh2 := "[2026.11.05-02.30.34:968][188]LogTemp: Writing Mesh /run/media/alex/S Backup L/Linux_Unreal_Engine_5.8.4/UnrealToGodot1/SmallStructures/VOL1/Meshes/SM_Loafing_Shed_01b.glb (2/540)\n"
	var material := "[2026.11.05-02.28.21:014][188]LogTemp: Processing Materials ( 1 / 191 )\n"
	var texture := "[2026.11.05-02.29.00:000][188]LogTemp: Writing Texture /tmp/out/T_Wood_D.png (3/12)\n"
	var noise := "[2026.11.05-02.28.16:980][188]LogTemp: Warning: GetTotalFoliageInstances = 0\n"
	assert_eq(UnrealBridge.parse_progress(""), {"current": 0, "total": 0, "stage": ""}, "empty")
	assert_eq(UnrealBridge.parse_progress(noise), {"current": 0, "total": 0, "stage": ""}, "noise only")
	assert_eq(UnrealBridge.parse_progress(material + noise), {"current": 1, "total": 191, "stage": "material"}, "materials")
	assert_eq(UnrealBridge.parse_progress(material + mesh + mesh2 + noise), {"current": 2, "total": 540, "stage": "mesh"}, "last mesh line wins")
	assert_eq(UnrealBridge.parse_progress(mesh + texture), {"current": 3, "total": 12, "stage": "texture"}, "texture")
	assert_eq(UnrealBridge.parse_progress(mesh2 + "[2026.11.05-02.44.15:847][188]Message dialog closed, result: Cancel, title: Message, text: Export Complete !\n"),
		{"current": 540, "total": 540, "stage": "done"}, "Export Complete")
	assert_eq(UnrealBridge.parse_progress(mesh2 + "[2026.11.05-02.44.16:000][188]LogTemp: GodotFab: export finished\n"),
		{"current": 540, "total": 540, "stage": "done"}, "export finished")
	assert_eq(UnrealBridge.parse_progress("LogTemp: GodotFab: export finished\n"), {"current": 0, "total": 0, "stage": "done"}, "done without counts")
	assert_eq(UnrealBridge.parse_progress(mesh + "LogTemp: Error: GodotFab: export failed: no assets\n"), {"current": 1, "total": 540, "stage": "failed"}, "failed")
	assert_eq(UnrealBridge.parse_progress(mesh2.strip_edges()), {"current": 2, "total": 540, "stage": "mesh"}, "no trailing newline")


func test_bytes_contain() -> void:
	var hay := PackedByteArray([0, 1, 85, 85, 110, 0])
	hay.append_array("xxUnrealToGodotCommandlet".to_utf8_buffer())
	hay.append(0)
	hay.append_array("yy".to_utf8_buffer())
	assert_true(UnrealBridge.bytes_contain(hay, MARKER.to_utf8_buffer()), "found")
	assert_false(UnrealBridge.bytes_contain(hay, "UnrealToGodotCommandletX".to_utf8_buffer()), "not found")
	assert_false(UnrealBridge.bytes_contain(PackedByteArray(), MARKER.to_utf8_buffer()), "empty haystack")
	assert_false(UnrealBridge.bytes_contain(hay, PackedByteArray()), "empty needle")


func test_check_setup() -> void:
	var engine := tmp_dir()
	var project_dir := tmp_dir()
	var uproject := project_dir.path_join("X.uproject")
	var missing := UnrealBridge.check_setup(engine, uproject)
	assert_false(missing.engine_ok, "engine missing")
	assert_false(missing.project_ok, "project missing")
	assert_false(missing.plugin_ok, "plugin missing")
	assert_false(missing.commandlet_ok, "commandlet missing")
	assert_false(missing.ok, "overall not ok")
	assert_eq(missing.messages.size(), 4, "four messages")

	write_file(UnrealBridge.editor_cmd(engine, "Linux"), "#!/bin/sh\n")
	write_file(uproject, "{}")
	var plugin := project_dir.path_join("Plugins/UnrealToGodot")
	write_file(plugin.path_join("UnrealToGodot.uplugin"), "{}")
	var so := PackedByteArray([0x7F, 0x45, 0x4C, 0x46, 0, 0])
	so.append_array("something else".to_utf8_buffer())
	write_file(plugin.path_join("Binaries/Linux/libUnrealEditor-UnrealToGodot.so"), so)
	var partial := UnrealBridge.check_setup(engine, uproject)
	assert_true(partial.engine_ok, "engine ok")
	assert_true(partial.project_ok, "project ok")
	assert_true(partial.plugin_ok, "plugin ok")
	assert_false(partial.commandlet_ok, "commandlet not in .so")
	assert_false(partial.ok, "overall not ok without commandlet")
	assert_eq(partial.messages.size(), 4, "still four messages")
	assert_contains(partial.messages[3], "commandlet", "last message about the commandlet")

	so.append_array(MARKER.to_utf8_buffer())
	so.append(0)
	write_file(plugin.path_join("Binaries/Linux/libUnrealEditor-UnrealToGodot.so"), so)
	var full := UnrealBridge.check_setup(engine, uproject)
	assert_true(full.commandlet_ok, "commandlet found")
	assert_true(full.ok, "all ok")
	assert_eq(full.messages.size(), 4, "messages for every check")


func _sh_script(log_path: String, lines: Array[String], exit_code: int) -> PackedStringArray:
	var script := ""
	for line in lines:
		script += 'echo "%s" >> "$0"; ' % line
	script += "exit %d" % exit_code
	return PackedStringArray(["-c", script, log_path])


func test_run_commandlet_success_and_failure() -> void:
	var log_path := tmp_dir().path_join("convert.log")
	var bridge := UnrealBridge.new()
	bridge.poll_interval = 0.2
	var seen: Array[Dictionary] = []
	var result: Dictionary = await bridge.run_commandlet("/bin/sh",
		_sh_script(log_path, ["LogTemp: Writing Mesh /x/a.glb (1/2)", "LogTemp: Writing Mesh /x/b.glb (2/2)", "LogTemp: GodotFab: export finished"], 0),
		log_path, func(p: Dictionary) -> void: seen.append(p))
	assert_true(result.ok, "success: %s" % result.get("error", ""))
	assert_eq(result.exit_code, 0, "exit code 0")
	assert_contains(result.log_tail, "export finished", "log tail has the finished line")
	assert_true(seen.size() >= 1, "progress reported")
	assert_eq(seen.back(), {"current": 2, "total": 2, "stage": "done"}, "final progress is done")

	var log2 := tmp_dir().path_join("convert.log")
	var bridge2 := UnrealBridge.new()
	bridge2.poll_interval = 0.2
	var result2: Dictionary = await bridge2.run_commandlet("/bin/sh",
		_sh_script(log2, ["LogTemp: Writing Mesh /x/a.glb (1/2)", "LogTemp: Error: GodotFab: export failed: boom"], 1),
		log2, Callable())
	assert_false(result2.ok, "failure")
	assert_eq(result2.exit_code, 1, "exit code 1")
	assert_contains(result2.log_tail, "export failed: boom", "log tail contains the log")
	assert_contains(result2.error, "1", "error mentions the exit code")

	var log3 := tmp_dir().path_join("convert.log")
	var bridge3 := UnrealBridge.new()
	bridge3.poll_interval = 0.2
	var result3: Dictionary = await bridge3.run_commandlet("/bin/sh", _sh_script(log3, ["LogTemp: Writing Mesh /x/a.glb (1/2)"], 0), log3, Callable())
	assert_false(result3.ok, "exit 0 without the finished line is not ok")
	assert_eq(result3.exit_code, 0, "exit code 0")
	assert_contains(result3.error, "finished", "error says the finished line is missing")


func test_run_commandlet_process_runner_override() -> void:
	var log_path := tmp_dir().path_join("convert.log")
	var bridge := UnrealBridge.new()
	bridge.poll_interval = 0.1
	var captured := {}
	bridge.process_runner = func(executable: String, args: PackedStringArray) -> int:
		captured["executable"] = executable
		captured["args"] = args
		return -1
	var result: Dictionary = await bridge.run_commandlet("/engine/UnrealEditor-Cmd", PackedStringArray(["a", "b"]), log_path, Callable())
	assert_false(result.ok, "failed to start")
	assert_eq(result.exit_code, -1, "exit code -1")
	assert_eq(captured.get("executable"), "/engine/UnrealEditor-Cmd", "runner got the executable")
	assert_eq(Array(captured.get("args", PackedStringArray())), ["a", "b"], "runner got the args")
	assert_contains(result.error, "start", "error says it could not start")


func test_run_commandlet_cancel() -> void:
	var log_path := tmp_dir().path_join("convert.log")
	var bridge := UnrealBridge.new()
	bridge.poll_interval = 0.1
	var done := {}
	var runner := func() -> void:
		done["result"] = await bridge.run_commandlet("/bin/sh", PackedStringArray(["-c", "sleep 30"]), log_path, Callable())
	runner.call()
	await Engine.get_main_loop().create_timer(0.3).timeout
	bridge.cancel()
	var waited := 0.0
	while not done.has("result") and waited < 5.0:
		await Engine.get_main_loop().create_timer(0.1).timeout
		waited += 0.1
	assert_true(done.has("result"), "run_commandlet returned after cancel")
	var result: Dictionary = done.get("result", {})
	assert_false(result.get("ok", true), "cancelled is not ok")
	assert_true(result.get("cancelled", false), "cancelled flag")


func test_parse_progress_loading_stage() -> void:
	var log := "[2026.11.06-12.00.00:000][  0]LogTemp: Display: GodotFab: found 151 mesh assets under /Game/P\n[2026.11.06-12.00.01:000][  0]LogTemp: GodotFab: Loading Mesh /Game/P/Meshes/X.X (3/151)\n"
	var bridge = preload("res://addons/godotfab/unreal_bridge.gd")
	assert_eq(bridge.parse_progress(log), {"current": 3, "total": 151, "stage": "load"})


func test_run_commandlet_finished_with_nonzero_exit_is_ok() -> void:
	var log_path := tmp_dir().path_join("convert.log")
	var bridge := UnrealBridge.new()
	bridge.poll_interval = 0.2
	var result: Dictionary = await bridge.run_commandlet("/bin/sh", PackedStringArray(["-c",
		"echo 'LogInit: Error: Vulkan InitSDL() failed' >> '%s'; echo 'LogTemp: Display: GodotFab: export finished' >> '%s'; exit 1" % [log_path, log_path]]), log_path, Callable())
	assert_true(result.ok, "finished line wins over the exit code")
	assert_eq(result.exit_code, 1)
	var result2: Dictionary = await bridge.run_commandlet("/bin/sh", PackedStringArray(["-c",
		"echo 'LogTemp: Error: GodotFab: export failed: no meshes' >> '%s'; echo 'GodotFab: export finished' >> '%s'; exit 0" % [log_path, log_path]]), log_path, Callable())
	assert_false(result2.ok, "a failed line beats a finished line")
	assert_contains(result2.error, "no meshes")
