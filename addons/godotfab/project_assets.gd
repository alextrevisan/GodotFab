@tool

extends RefCounted
## Reads the `.godotfab.json` manifests written by godot_import.gd to know
## which Fab assets are already in the project.

const MANIFEST_FILE := ".godotfab.json"


## Every manifest found one level below `download_dir_abs`, each with the
## `folder` name added. Unreadable manifests are skipped.
static func scan(download_dir_abs: String) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var dir := DirAccess.open(download_dir_abs)
	if dir == null:
		return items
	var folders := dir.get_directories()
	folders.sort()
	for folder in folders:
		var path := download_dir_abs.path_join(folder).path_join(MANIFEST_FILE)
		if not FileAccess.file_exists(path):
			continue
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
			continue
		var item: Dictionary = json.data
		item["folder"] = folder
		items.append(item)
	return items


## The manifest whose `uid` matches, or `{}`.
static func find(download_dir_abs: String, uid: String) -> Dictionary:
	for item in scan(download_dir_abs):
		if str(item.get("uid", "")) == uid:
			return item
	return {}
