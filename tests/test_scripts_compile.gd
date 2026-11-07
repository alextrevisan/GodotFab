extends "res://tests/test_case.gd"
## Every addon script must parse and compile, UI scripts included (the
## other tests only load the services).


func test_all_addon_scripts_compile() -> void:
	var scripts: Array[String] = []
	_collect("res://addons/godotfab", scripts)
	assert_true(scripts.size() >= 20, "found %d scripts" % scripts.size())
	for path in scripts:
		var script = load(path)
		assert_true(script != null and script.can_instantiate(), "%s compiles" % path)


func _collect(dir: String, out: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(sub), out)
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			out.append(dir.path_join(file))
