extends SceneTree
## Runs every res://tests/test_*.gd: each `func test_*()` of the script
## (coroutines allowed). Exits 1 on failure.
##   godot --headless --path . -s tests/run_tests.gd [-- name_filter]


func _initialize() -> void:
	_run()


func _run() -> void:
	var filter := ""
	for arg in OS.get_cmdline_user_args():
		filter = arg
	var files := DirAccess.get_files_at("res://tests")
	files.sort()
	var total_passed := 0
	var total_failed := 0
	var failed_names: Array[String] = []
	for file in files:
		if not file.begins_with("test_") or not file.ends_with(".gd"):
			continue
		if filter and not file.contains(filter):
			continue
		var script: GDScript = load("res://tests/" + file)
		if script == null or not script.can_instantiate():
			print("  FAIL %s: script does not compile" % file)
			total_failed += 1
			failed_names.append(file)
			continue
		for method in script.get_script_method_list():
			var name: String = method.name
			if not name.begins_with("test_"):
				continue
			var test = script.new()
			await test.call(name)
			test.cleanup()
			total_passed += test.passed
			if test.failures.is_empty() and test.passed == 0:
				test.failures.append("no assertions ran (script error?)")
			if test.failures.is_empty():
				print("  ok   %s::%s" % [file, name])
			else:
				total_failed += test.failures.size()
				failed_names.append("%s::%s" % [file, name])
				print("  FAIL %s::%s" % [file, name])
				for failure in test.failures:
					print("       " + failure)
	print("PASS %d / FAIL %d" % [total_passed, total_failed])
	if total_failed > 0:
		print("Failed tests:\n  " + "\n  ".join(failed_names))
	quit(1 if total_failed > 0 or total_passed == 0 else 0)

