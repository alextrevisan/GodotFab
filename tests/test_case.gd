extends RefCounted
## Base of the headless tests: assertions and a temporary directory.

var failures: Array[String] = []
var passed: int = 0
var _tmp_dirs: Array[String] = []
static var _tmp_counter := 0


func assert_true(cond: bool, msg := "") -> void:
	if cond:
		passed += 1
	else:
		failures.append("assert_true failed: %s" % msg)


func assert_false(cond: bool, msg := "") -> void:
	assert_true(not cond, msg)


func assert_eq(a: Variant, b: Variant, msg := "") -> void:
	if a == b:
		passed += 1
	else:
		failures.append("assert_eq failed: %s\n    got:      %s\n    expected: %s" % [msg, str(a).left(400), str(b).left(400)])


func assert_null(a: Variant, msg := "") -> void:
	assert_true(a == null, msg)


func assert_not_null(a: Variant, msg := "") -> void:
	assert_true(a != null, msg)


func assert_contains(s: String, sub: String, msg := "") -> void:
	if s.contains(sub):
		passed += 1
	else:
		failures.append("assert_contains failed: %s\n    '%s' not in '%s'" % [msg, sub, s.left(400)])


## A fresh empty directory (absolute path), removed when the test ends.
func tmp_dir() -> String:
	_tmp_counter += 1
	var path := ProjectSettings.globalize_path("user://tests/t%d_%d" % [Time.get_ticks_usec(), _tmp_counter])
	DirAccess.make_dir_recursive_absolute(path)
	_tmp_dirs.append(path)
	return path


func cleanup() -> void:
	for dir in _tmp_dirs:
		remove_dir(dir)
	_tmp_dirs.clear()


static func remove_dir(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for dir in folder.get_directories():
		remove_dir(path.path_join(dir))
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


static func write_file(path: String, content: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if content is PackedByteArray:
		f.store_buffer(content)
	else:
		f.store_string(str(content))
	f.close()


static func read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))
