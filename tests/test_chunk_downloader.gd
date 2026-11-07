extends "res://tests/test_case.gd"

const Manifest = preload("res://addons/godotfab/manifest.gd")
const ChunkDownloader = preload("res://addons/godotfab/chunk_downloader.gd")

const BASE_A := "https://cdn-a.example/pack"
const BASE_B := "https://cdn-b.example/pack/"
const GUID_1 := "11111111222222223333333344444444"
const GUID_2 := "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD"


## Serves chunk files by URL; `missing` URLs answer 404.
class FakeCdn extends RefCounted:
	var files: Dictionary = {}
	var missing: Dictionary = {}
	var requests: Array = []
	var corrupt: Dictionary = {}
	var delay_frames := 0
	var tree: SceneTree

	func fetch_bytes(url: String) -> Dictionary:
		requests.append(url)
		for i in delay_frames:
			await tree.process_frame
		if missing.has(url) or not files.has(url):
			return {"ok": false, "status": 404, "body": PackedByteArray(), "error": "HTTP 404"}
		return {"ok": true, "status": 200, "body": files[url], "error": ""}


func _manifest() -> Dictionary:
	var parsed := Manifest.parse(FileAccess.get_file_as_bytes("res://tests/fixtures/manifest_v20.manifest"))
	assert_true(parsed.ok, parsed.get("error", ""))
	return parsed


func _cdn(manifest: Dictionary) -> FakeCdn:
	var cdn := FakeCdn.new()
	cdn.tree = Engine.get_main_loop()
	var expected: Dictionary = read_json("res://tests/fixtures/expected.json")
	var bytes := {GUID_1: FileAccess.get_file_as_bytes("res://tests/fixtures/chunk_compressed.chunk"),
		GUID_2: FileAccess.get_file_as_bytes("res://tests/fixtures/chunk_plain.chunk")}
	for guid in bytes:
		var path: String = expected.chunks[guid].path_v20
		assert_eq(Manifest.chunk_path(manifest.chunks[guid], manifest.feature_level), path)
		cdn.files[BASE_A + "/" + path] = bytes[guid]
		cdn.files[BASE_B.rstrip("/") + "/" + path] = bytes[guid]
	return cdn


func _downloader(manifest: Dictionary, cdn: FakeCdn, staging: String, workers := 2) -> ChunkDownloader:
	var dl := ChunkDownloader.new(manifest, [BASE_A, BASE_B], staging, cdn.fetch_bytes, workers)
	dl.retry_delays = [0.0]
	return dl


func _sha1_hex(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


func test_downloads_and_assembles_files() -> void:
	var manifest := _manifest()
	var cdn := _cdn(manifest)
	var staging := tmp_dir()
	var dl := _downloader(manifest, cdn, staging)
	var events: Array = []
	dl.progress.connect(func(done, total, _bd, _bt): events.append([done, total]))
	var result = await dl.run()
	assert_true(result.ok, result.error)
	var expected: Dictionary = read_json("res://tests/fixtures/expected.json")
	assert_eq(result.files.size(), expected.files.size())
	for i in expected.files.size():
		var entry: Dictionary = expected.files[i]
		var path: String = staging.path_join("files").path_join(entry.filename)
		assert_true(FileAccess.file_exists(path), path)
		assert_eq(FileAccess.get_file_as_bytes(path).size(), int(entry.size), entry.filename)
		assert_eq(_sha1_hex(path), entry.sha1_hex, entry.filename)
		assert_eq(result.files[i], path)
	assert_eq(events.back(), [2, 2])
	assert_eq(cdn.requests.size(), 2, "each chunk fetched once from the first CDN")
	assert_true(FileAccess.file_exists(staging.path_join("chunks").path_join(GUID_1 + ".bin")))


func test_resumes_from_existing_chunks() -> void:
	var manifest := _manifest()
	var cdn := _cdn(manifest)
	var staging := tmp_dir()
	var expected: Dictionary = read_json("res://tests/fixtures/expected.json")
	# Chunk 1 already decoded on disk from an earlier attempt.
	var decoded := Manifest.decode_chunk(FileAccess.get_file_as_bytes("res://tests/fixtures/chunk_compressed.chunk"))
	assert_true(decoded.ok)
	write_file(staging.path_join("chunks").path_join(GUID_1 + ".bin"), decoded.payload)
	# And a half-written temp chunk to be cleaned.
	write_file(staging.path_join("chunks").path_join(GUID_2 + ".bin.tmp"), PackedByteArray([1]))
	var result = await _downloader(manifest, cdn, staging).run()
	assert_true(result.ok, result.error)
	assert_eq(cdn.requests.size(), 1)
	assert_true(cdn.requests[0].contains(expected.chunks[GUID_2].path_v20))
	assert_false(FileAccess.file_exists(staging.path_join("chunks").path_join(GUID_2 + ".bin.tmp")))


func test_falls_back_to_second_cdn() -> void:
	var manifest := _manifest()
	var cdn := _cdn(manifest)
	var expected: Dictionary = read_json("res://tests/fixtures/expected.json")
	cdn.missing[BASE_A + "/" + expected.chunks[GUID_2].path_v20] = true
	var result = await _downloader(manifest, cdn, tmp_dir()).run()
	assert_true(result.ok, result.error)
	assert_eq(cdn.requests.size(), 3)
	assert_true(cdn.requests.back().begins_with(BASE_B.rstrip("/")))


func test_chunk_missing_everywhere_errors() -> void:
	var manifest := _manifest()
	var cdn := _cdn(manifest)
	var expected: Dictionary = read_json("res://tests/fixtures/expected.json")
	for base in [BASE_A, BASE_B.rstrip("/")]:
		cdn.missing[base + "/" + expected.chunks[GUID_2].path_v20] = true
	var dl := _downloader(manifest, cdn, tmp_dir())
	dl.retry_delays = [0.0, 0.0]
	var result = await dl.run()
	assert_false(result.ok)
	assert_contains(result.error, "Could not download chunk")
	# 1 for chunk 1 + 2 CDNs x 3 rounds for chunk 2
	assert_eq(cdn.requests.size(), 7)


func test_sha1_mismatch_deletes_chunks_and_errors() -> void:
	var manifest := _manifest()
	var cdn := _cdn(manifest)
	var staging := tmp_dir()
	# A stored chunk with the right size but wrong bytes: the assembled file fails SHA-1.
	var bad := PackedByteArray()
	bad.resize(5000)
	bad.fill(7)
	write_file(staging.path_join("chunks").path_join(GUID_2 + ".bin"), bad)
	var result = await _downloader(manifest, cdn, staging).run()
	assert_false(result.ok)
	assert_contains(result.error, "SHA-1")
	assert_false(FileAccess.file_exists(staging.path_join("chunks").path_join(GUID_2 + ".bin")), "bad chunk dropped for the next attempt")


func test_unsafe_path_rejected() -> void:
	var manifest := _manifest()
	manifest.files[0].filename = "../evil.uasset"
	var cdn := _cdn(_manifest())
	var result = await _downloader(manifest, cdn, tmp_dir()).run()
	assert_false(result.ok)
	assert_contains(result.error, "unsafe")
	assert_eq(cdn.requests.size(), 0)


func test_unknown_chunk_rejected() -> void:
	var manifest := _manifest()
	manifest.files[0].parts[0].guid = "00000000000000000000000000000000"
	var result = await _downloader(manifest, _cdn(_manifest()), tmp_dir()).run()
	assert_false(result.ok)
	assert_contains(result.error, "unknown chunk")


func test_cancel_stops() -> void:
	var manifest := _manifest()
	var cdn := _cdn(manifest)
	cdn.delay_frames = 3
	var dl := _downloader(manifest, cdn, tmp_dir(), 1)
	var box := {}
	_run_into(dl, box)
	await Engine.get_main_loop().process_frame
	dl.cancel()
	while not box.has("result"):
		await Engine.get_main_loop().process_frame
	var result: Dictionary = box.result
	assert_false(result.ok)
	assert_eq(result.error, "cancelled")
	assert_eq(cdn.requests.size(), 1)


## Fire-and-forget run() whose result lands in [param box].
func _run_into(dl: ChunkDownloader, box: Dictionary) -> void:
	box.result = await dl.run()
