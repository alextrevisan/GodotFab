@tool
extends RefCounted
## Downloads the chunks of an Epic build manifest from the CDNs and
## assembles its files, verifying each one's SHA-1. Chunks are kept in the
## staging folder, so a failed or cancelled download resumes.
##
## staging layout: <staging>/chunks/<GUIDHEX>.bin and <staging>/files/<relative>

signal progress(done: int, total: int, bytes_done: int, bytes_total: int)

const Log = preload("res://addons/godotfab/log.gd")
const Manifest = preload("res://addons/godotfab/manifest.gd")

## Seconds before each new round of attempts on every CDN.
var retry_delays: Array = [2.0, 5.0, 15.0]
## Parts assembled between frames, to keep the editor responsive.
const PARTS_PER_FRAME := 16

var manifest: Dictionary
var base_urls: Array
var staging_dir: String
## fetch_bytes(url: String) -> {ok, status, body, error}, awaited.
var fetch_bytes: Callable
var workers: int

var _cancelled := false
var _todo: Array = []
var _done := 0
var _total := 0
var _bytes_done := 0
var _bytes_total := 0
var _error := ""
var _running_workers := 0


func _init(new_manifest: Dictionary, new_base_urls: Array, new_staging_dir: String, new_fetch_bytes: Callable, new_workers := 4) -> void:
	manifest = new_manifest
	base_urls = new_base_urls
	staging_dir = new_staging_dir
	fetch_bytes = new_fetch_bytes
	workers = maxi(1, new_workers)


func cancel() -> void:
	_cancelled = true


func chunks_dir() -> String:
	return staging_dir.path_join("chunks")


func files_dir() -> String:
	return staging_dir.path_join("files")


## Downloads and assembles; {ok, error, files_dir, files: Array[String]}.
func run() -> Dictionary:
	var files: Array = manifest.get("files", [])
	var chunks: Dictionary = manifest.get("chunks", {})
	if files.is_empty():
		return _fail("The manifest lists no files")
	if base_urls.is_empty():
		return _fail("No download location")
	# Validate paths and chunk references before touching the network.
	var targets: Array = []
	for entry in files:
		var relative := Manifest.safe_relative_path(str(entry.filename))
		if relative.is_empty():
			return _fail("Refusing unsafe file path in manifest: %s" % entry.filename)
		targets.append(relative)
		for part in entry.parts:
			if not chunks.has(part.guid):
				return _fail("The manifest references unknown chunk %s" % part.guid)
	DirAccess.make_dir_recursive_absolute(chunks_dir())
	_remove_dir(files_dir())
	DirAccess.make_dir_recursive_absolute(files_dir())
	_clean_tmp_chunks()

	# Unique chunks in first-use order; skip those already on disk.
	var needed: Array = []
	var seen := {}
	for entry in files:
		for part in entry.parts:
			if not seen.has(part.guid):
				seen[part.guid] = true
				needed.append(part.guid)
	_total = needed.size()
	_bytes_total = 0
	for entry in files:
		_bytes_total += int(entry.get("size", 0))
	_todo = []
	for guid in needed:
		if FileAccess.file_exists(_chunk_file(guid)):
			_done += 1
		else:
			_todo.append(guid)
	_emit_progress()

	# Parallel workers pull from the shared queue.
	_running_workers = 0
	for i in mini(workers, _todo.size()):
		_running_workers += 1
		_worker()
	while _running_workers > 0:
		await Engine.get_main_loop().process_frame
	if _cancelled:
		return _fail("cancelled")
	if not _error.is_empty():
		return _fail(_error)

	# Assemble and verify.
	var out_files: Array = []
	var parts_since_yield := 0
	for i in files.size():
		var entry: Dictionary = files[i]
		var target: String = files_dir().path_join(targets[i])
		var result := _assemble(entry, target)
		if not result.ok:
			for part in entry.parts:
				DirAccess.remove_absolute(_chunk_file(part.guid))
			return _fail(result.error)
		out_files.append(target)
		parts_since_yield += entry.parts.size()
		if parts_since_yield >= PARTS_PER_FRAME:
			parts_since_yield = 0
			await Engine.get_main_loop().process_frame
			if _cancelled:
				return _fail("cancelled")
	return {"ok": true, "error": "", "files_dir": files_dir(), "files": out_files}


func _worker() -> void:
	while not _todo.is_empty() and not _cancelled and _error.is_empty():
		var guid: String = _todo.pop_front()
		var err := await _download_chunk(guid)
		if not err.is_empty():
			if _error.is_empty():
				_error = err
			break
		_done += 1
		_emit_progress()
	_running_workers -= 1


## Tries every CDN, then waits each retry delay and tries them all again.
func _download_chunk(guid: String) -> String:
	var chunk: Dictionary = manifest.chunks[guid]
	var path := Manifest.chunk_path(chunk, int(manifest.get("feature_level", 0)))
	var last_error := ""
	var delays := [0.0] + retry_delays
	for delay in delays:
		if delay > 0.0:
			await Engine.get_main_loop().create_timer(delay).timeout
		if _cancelled or not _error.is_empty():
			return "cancelled"
		for base_url in base_urls:
			if _cancelled or not _error.is_empty():
				return "cancelled"
			var url := "%s/%s" % [str(base_url).rstrip("/"), path]
			var response: Dictionary = await fetch_bytes.call(url)
			if _cancelled:
				return "cancelled"
			if not response.get("ok", false):
				last_error = str(response.get("error", "download failed"))
				continue
			var decoded: Dictionary = Manifest.decode_chunk(response.body)
			if not decoded.ok:
				last_error = decoded.error
				continue
			if decoded.guid != guid:
				last_error = "%s contains chunk %s" % [path, decoded.guid]
				continue
			var target := _chunk_file(guid)
			var tmp := target + ".tmp"
			var file := FileAccess.open(tmp, FileAccess.WRITE)
			if file == null:
				return "Can't write %s" % tmp
			file.store_buffer(decoded.payload)
			file.close()
			DirAccess.remove_absolute(target)
			if DirAccess.rename_absolute(tmp, target) != OK:
				return "Can't rename %s" % tmp
			_bytes_done += decoded.payload.size()
			return ""
	return "Could not download chunk %s: %s" % [path, last_error]


func _assemble(entry: Dictionary, target: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var out := FileAccess.open(target, FileAccess.WRITE)
	if out == null:
		return {"ok": false, "error": "Can't write %s" % target}
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	var cache := {}
	var cache_order: Array = []
	for part in entry.parts:
		var data: PackedByteArray
		if cache.has(part.guid):
			data = cache[part.guid]
		else:
			data = FileAccess.get_file_as_bytes(_chunk_file(part.guid))
			cache[part.guid] = data
			cache_order.append(part.guid)
			if cache_order.size() > 8:
				cache.erase(cache_order.pop_front())
		var offset := int(part.offset)
		var size := int(part.size)
		if offset + size > data.size():
			out.close()
			return {"ok": false, "error": "%s: a chunk part lies outside its chunk" % entry.filename}
		var piece := data.slice(offset, offset + size)
		out.store_buffer(piece)
		ctx.update(piece)
	out.close()
	var digest := ctx.finish()
	if digest != PackedByteArray(entry.sha1):
		return {"ok": false, "error": "%s failed its SHA-1 check" % entry.filename}
	return {"ok": true, "error": ""}


func _chunk_file(guid: String) -> String:
	return chunks_dir().path_join(guid + ".bin")


func _clean_tmp_chunks() -> void:
	var dir := DirAccess.open(chunks_dir())
	if dir == null:
		return
	for file in dir.get_files():
		if file.ends_with(".tmp"):
			DirAccess.remove_absolute(chunks_dir().path_join(file))


func _emit_progress() -> void:
	progress.emit(_done, _total, _bytes_done, _bytes_total)


func _fail(message: String) -> Dictionary:
	if message != "cancelled":
		Log.warning("Download failed: %s" % message)
	return {"ok": false, "error": message, "files_dir": files_dir(), "files": []}


static func _remove_dir(path: String) -> void:
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	for dir in folder.get_directories():
		_remove_dir(path.path_join(dir))
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
