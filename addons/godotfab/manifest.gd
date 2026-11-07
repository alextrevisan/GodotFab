@tool
extends RefCounted
## Epic build manifest parser (binary and JSON), chunk file decoder and chunk CDN path.
##
## All functions are static and never raise or push_error on bad input: they return
## dictionaries with `ok: bool` and `error: String`.
##
## parse() result:
##   { ok, error, feature_level: int, build_version: String,
##     chunks: { guid_hex: { guid: Array[4 ints, u32 each], hash: int (u64 bits),
##                           group: int, secret: Array[4] | null } },
##     files: [ { filename: String, sha1: PackedByteArray(20),
##                parts: [ { guid: String (hex), offset: int, size: int } ], size: int } ] }

const MANIFEST_MAGIC := 0x44BEC00C
const CHUNK_MAGIC := 0xB1FE3AA2

const _STORED_COMPRESSED := 0x1
const _STORED_ENCRYPTED := 0x2

## Manifest header: magic, header size, uncompressed size, compressed size (4×u32),
## SHA-1 (20), stored_as (u8).
const _MANIFEST_HEADER_MIN := 4 * 4 + 20 + 1
## Chunk header: magic, version, header size, compressed size (4×u32), GUID (16),
## rolling hash (u64), stored_as (u8).
const _CHUNK_HEADER_MIN := 4 * 4 + 16 + 8 + 1


## Bounds-checked little-endian reader; the first failure is kept in `error`.
class Reader:
	var buf := StreamPeerBuffer.new()
	var size := 0
	var error := ""

	func _init(data: PackedByteArray) -> void:
		buf.big_endian = false
		buf.data_array = data
		size = data.size()

	var pos: int:
		get:
			return buf.get_position()

	func need(n: int) -> bool:
		if error != "":
			return false
		if n < 0 or buf.get_position() + n > size:
			error = "Unexpected end of data"
			return false
		return true

	func u8() -> int:
		return buf.get_u8() if need(1) else 0

	func u32() -> int:
		return buf.get_u32() if need(4) else 0

	func i32() -> int:
		return buf.get_32() if need(4) else 0

	func u64() -> int:
		return buf.get_u64() if need(8) else 0

	func bytes(n: int) -> PackedByteArray:
		if not need(n):
			return PackedByteArray()
		return buf.get_data(n)[1]

	func skip(n: int) -> void:
		if need(n):
			buf.seek(buf.get_position() + n)

	func guid() -> Array:
		if not need(16):
			return [0, 0, 0, 0]
		return [buf.get_u32(), buf.get_u32(), buf.get_u32(), buf.get_u32()]

	## Epic FString: i32 length including the terminator; > 0 ASCII, < 0 UTF-16LE chars.
	func fstring() -> String:
		var length := i32()
		if length > 0:
			var raw := bytes(length)
			if error != "":
				return ""
			raw.resize(length - 1)
			return raw.get_string_from_ascii()
		if length < 0:
			if length < -0x3FFFFFFF:
				error = "Invalid string length"
				return ""
			var raw := bytes(-length * 2)
			if error != "":
				return ""
			raw.resize(raw.size() - 2)
			return raw.get_string_from_utf16()
		return ""

	## Jump to the end of a section whose declared size is known, skipping fields newer
	## than this parser (and failing when we already read past it).
	func end_section(start: int, section_size: int) -> void:
		if error != "":
			return
		var end := start + section_size
		if buf.get_position() > end:
			error = "Section is larger than its declared size"
			return
		if end > size:
			error = "Unexpected end of data"
			return
		buf.seek(end)


static func _fail(error: String) -> Dictionary:
	return {"ok": false, "error": error}


## Parse a manifest in Epic's binary format (magic 0x44BEC00C) or its JSON format.
static func parse(data: PackedByteArray) -> Dictionary:
	if data.size() >= 4 and data.decode_u32(0) == MANIFEST_MAGIC:
		return _parse_binary(data)
	return _parse_json(data)


## Hex key of a GUID: 4 × %08X concatenated (32 upper-case hex chars).
static func guid_hex(guid: Array) -> String:
	return "%08X%08X%08X%08X" % [guid[0] & 0xFFFFFFFF, guid[1] & 0xFFFFFFFF, guid[2] & 0xFFFFFFFF, guid[3] & 0xFFFFFFFF]


## Path of a chunk relative to a CDN base URL.
## Level >= 22: ChunksV5/<secret b64url|plain>/<group:02d>/<b64url(hash LE u64)>_<b64url(guid 4×u32 LE)>.chunk
## Otherwise:   ChunksV4|V3|V2|Chunks/<group:02d>/<hash:016X>_<GUIDHEX>.chunk
static func chunk_path(chunk: Dictionary, feature_level: int) -> String:
	var folder := _chunk_folder(feature_level)
	var group: int = chunk.get("group", 0)
	var hash_value: int = chunk.get("hash", 0)
	var guid: Array = chunk.get("guid", [0, 0, 0, 0])
	if feature_level >= 22:
		var secret = chunk.get("secret", null)
		var secret_part := "plain"
		if secret is Array and secret.size() == 4 and not (secret[0] == 0 and secret[1] == 0 and secret[2] == 0 and secret[3] == 0):
			secret_part = _b64url(_guid_bytes(secret))
		var hash_bytes := PackedByteArray()
		hash_bytes.resize(8)
		hash_bytes.encode_u64(0, hash_value)
		return "%s/%s/%02d/%s_%s.chunk" % [folder, secret_part, group, _b64url(hash_bytes), _b64url(_guid_bytes(guid))]
	return "%s/%02d/%s_%s.chunk" % [folder, group, _hash_hex(hash_value), guid_hex(guid)]


## Decode a downloaded chunk file: {ok, error, guid: String (hex), payload: PackedByteArray}.
static func decode_chunk(data: PackedByteArray) -> Dictionary:
	if data.size() < _CHUNK_HEADER_MIN:
		return _fail("Invalid chunk: truncated header")
	var reader := Reader.new(data)
	if reader.u32() != CHUNK_MAGIC:
		return _fail("Invalid chunk: bad magic")
	reader.u32()  # header version
	var header_size := reader.u32()
	reader.u32()  # compressed size
	var guid := reader.guid()
	reader.u64()  # rolling hash
	var stored_as := reader.u8()
	if reader.error != "":
		return _fail("Invalid chunk: " + reader.error)
	if stored_as & _STORED_ENCRYPTED:
		return _fail("Encrypted chunks are not supported")
	if header_size < _CHUNK_HEADER_MIN or header_size > data.size():
		return _fail("Invalid chunk: header is larger than the file")
	var payload := data.slice(header_size)
	if stored_as & _STORED_COMPRESSED:
		if payload.is_empty():
			return _fail("Invalid chunk: empty compressed payload")
		payload = payload.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
		if payload.is_empty():
			return _fail("Invalid chunk: zlib decompression failed")
	return {"ok": true, "error": "", "guid": guid_hex(guid), "payload": payload}


## Normalize a manifest file name to a relative path with "/" separators, or "" when it
## could escape the staging directory: empty, contains ":", starts with "/", or has a
## segment that is ".." or empty.
static func safe_relative_path(filename: String) -> String:
	if filename.is_empty():
		return ""
	var path := filename.replace("\\", "/")
	if path.contains(":") or path.begins_with("/"):
		return ""
	for segment in path.split("/"):
		if segment.is_empty() or segment == "..":
			return ""
	return path


# --- binary -------------------------------------------------------------------------------------

static func _parse_binary(data: PackedByteArray) -> Dictionary:
	if data.size() < _MANIFEST_HEADER_MIN:
		return _fail("Invalid manifest: truncated header")
	var header := Reader.new(data)
	header.u32()  # magic
	var header_size := header.u32()
	header.u32()  # uncompressed size
	header.u32()  # compressed size
	var sha1 := header.bytes(20)
	var stored_as := header.u8()
	if header.error != "":
		return _fail("Invalid manifest: " + header.error)
	if stored_as & _STORED_ENCRYPTED:
		return _fail("Encrypted manifests are not supported")
	if header_size < _MANIFEST_HEADER_MIN or header_size > data.size():
		return _fail("Invalid manifest: header is larger than the file")

	var body := data.slice(header_size)
	if stored_as & _STORED_COMPRESSED:
		if body.is_empty():
			return _fail("Invalid manifest: empty compressed body")
		body = body.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
		if body.is_empty():
			return _fail("Invalid manifest: zlib decompression failed")
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA1)
		ctx.update(body)
		if ctx.finish() != sha1:
			return _fail("Manifest hash does not match its contents")

	var reader := Reader.new(body)
	var meta := _read_meta(reader)
	if reader.error != "":
		return _fail("Invalid manifest: " + reader.error)
	var chunks := _read_chunks(reader, meta.feature_level)
	if reader.error != "":
		return _fail("Invalid manifest: " + reader.error)
	var files := _read_files(reader)
	if reader.error != "":
		return _fail("Invalid manifest: " + reader.error)
	return {
		"ok": true,
		"error": "",
		"feature_level": meta.feature_level,
		"build_version": meta.build_version,
		"chunks": chunks,
		"files": files,
	}


static func _read_meta(reader: Reader) -> Dictionary:
	var start := reader.pos
	var section_size := reader.u32()
	var data_version := reader.u8()
	var feature_level := reader.u32()
	reader.u8()  # is_file_data
	reader.u32()  # app_id
	reader.fstring()  # app_name
	var build_version := reader.fstring()
	reader.fstring()  # launch_exe
	reader.fstring()  # launch_command
	var prereq_count := reader.u32()
	for _i in prereq_count:
		if reader.error != "":
			break
		reader.fstring()  # prerequisite ids
	reader.fstring()  # prereq_name
	reader.fstring()  # prereq_path
	reader.fstring()  # prereq_args
	if data_version >= 1:
		reader.fstring()  # build_id
	if data_version >= 2:
		reader.fstring()  # uninstall_action_path
		reader.fstring()  # uninstall_action_args
	reader.end_section(start, section_size)
	return {"feature_level": feature_level, "build_version": build_version}


## Chunk data list: each field is stored for every chunk before the next field starts.
static func _read_chunks(reader: Reader, feature_level: int) -> Dictionary:
	var chunks := {}
	var start := reader.pos
	var section_size := reader.u32()
	reader.u8()  # version
	var count := reader.u32()
	if reader.error != "":
		return chunks
	# Fixed-size columns: validate the whole block before reading it.
	var fixed := count * (16 + 8 + 20 + 1 + 4 + 8)
	if feature_level >= 22:
		fixed += count * (16 + 4 + 16)
	if not reader.need(fixed):
		return chunks
	var buf := reader.buf
	var guids: Array = []
	guids.resize(count)
	for i in count:
		guids[i] = [buf.get_u32(), buf.get_u32(), buf.get_u32(), buf.get_u32()]
	var hashes := PackedInt64Array()
	hashes.resize(count)
	for i in count:
		hashes[i] = buf.get_u64()
	buf.seek(buf.get_position() + 20 * count)  # SHA-1 hashes
	var groups := PackedByteArray()
	if count > 0:
		groups = buf.get_data(count)[1]
	buf.seek(buf.get_position() + 4 * count)  # window sizes
	buf.seek(buf.get_position() + 8 * count)  # compressed file sizes
	var secrets: Array = []
	if feature_level >= 22:
		secrets.resize(count)
		for i in count:
			secrets[i] = [buf.get_u32(), buf.get_u32(), buf.get_u32(), buf.get_u32()]
		buf.seek(buf.get_position() + 4 * count)  # compressed window sizes
		buf.seek(buf.get_position() + 16 * count)  # encryption tags
	reader.end_section(start, section_size)
	if reader.error != "":
		return chunks
	for i in count:
		var guid: Array = guids[i]
		chunks[guid_hex(guid)] = {
			"guid": guid,
			"hash": hashes[i],
			"group": groups[i],
			"secret": secrets[i] if feature_level >= 22 else null,
		}
	return chunks


## File manifest list: each field is stored for every file before the next field starts.
static func _read_files(reader: Reader) -> Array:
	var files: Array = []
	var start := reader.pos
	var section_size := reader.u32()
	reader.u8()  # version
	var count := reader.u32()
	if reader.error != "" or count < 0:
		return files
	# Every file needs at least its name length, symlink length, hash, flag, tag count and part count.
	if not reader.need(count * (4 + 4 + 20 + 1 + 4 + 4)):
		return files
	var names := PackedStringArray()
	names.resize(count)
	for i in count:
		names[i] = reader.fstring()
		if reader.error != "":
			return files
	for _i in count:
		reader.fstring()  # symlink target
		if reader.error != "":
			return files
	if not reader.need(20 * count):
		return files
	var hashes: Array = []
	hashes.resize(count)
	for i in count:
		hashes[i] = reader.buf.get_data(20)[1]
	reader.skip(count)  # flags
	for _i in count:
		var tag_count := reader.u32()
		for _j in tag_count:
			reader.fstring()  # install tags
			if reader.error != "":
				return files
		if reader.error != "":
			return files
	var parts_per_file: Array = []
	parts_per_file.resize(count)
	for i in count:
		parts_per_file[i] = _read_file_parts(reader)
		if reader.error != "":
			return files
	# MD5 hashes, MIME types and SHA-256 hashes follow in newer versions; not needed.
	reader.end_section(start, section_size)
	if reader.error != "":
		return files
	files.resize(count)
	for i in count:
		var parts: Array = parts_per_file[i]
		var total := 0
		for part in parts:
			total += part.size
		files[i] = {"filename": names[i], "sha1": hashes[i], "parts": parts, "size": total}
	return files


static func _read_file_parts(reader: Reader) -> Array:
	var parts: Array = []
	var count := reader.u32()
	if not reader.need(count * 28):
		return parts
	parts.resize(count)
	for i in count:
		var start := reader.pos
		var entry_size := reader.u32()
		var guid := reader.guid()
		var offset := reader.u32()
		var length := reader.u32()
		reader.end_section(start, entry_size)
		if reader.error != "":
			return []
		parts[i] = {"guid": guid_hex(guid), "offset": offset, "size": length}
	return parts


# --- JSON ----------------------------------------------------------------------------------------

static func _parse_json(data: PackedByteArray) -> Dictionary:
	if data.size() >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF:
		data = data.slice(3)  # UTF-8 BOM
	var text := data.get_string_from_utf8()
	if text.strip_edges().is_empty():
		return _fail("Invalid manifest: empty")
	var json := JSON.new()
	if json.parse(text) != OK:
		return _fail("Invalid manifest: not a binary manifest and not JSON (%s)" % json.get_error_message())
	var document = json.data
	if not (document is Dictionary):
		return _fail("Invalid manifest: JSON root is not an object")
	for key in ["ChunkFilesizeList", "ChunkHashList", "DataGroupList", "FileManifestList"]:
		if not document.has(key):
			return _fail("Invalid manifest: missing %s" % key)
	var sizes = document["ChunkFilesizeList"]
	var hashes = document["ChunkHashList"]
	var groups = document["DataGroupList"]
	var file_list = document["FileManifestList"]
	if not (sizes is Dictionary and hashes is Dictionary and groups is Dictionary and file_list is Array):
		return _fail("Invalid manifest: malformed chunk or file lists")

	var feature_level := _blob_to_int(str(document.get("ManifestFileVersion", "013000000000")))
	var chunks := {}
	for key in sizes:
		var guid := _guid_from_json(str(key))
		if guid.is_empty():
			return _fail("Invalid manifest: bad chunk GUID %s" % key)
		if not hashes.has(key) or not groups.has(key):
			return _fail("Invalid manifest: chunk %s has no hash or group" % key)
		chunks[guid_hex(guid)] = {
			"guid": guid,
			"hash": _blob_to_int(str(hashes[key])),
			"group": _blob_to_int(str(groups[key])),
			"secret": null,
		}

	var files: Array = []
	for entry in file_list:
		if not (entry is Dictionary) or not entry.has("FileHash") or not entry.has("FileChunkParts"):
			return _fail("Invalid manifest: malformed file entry")
		var sha1 := _blob_to_bytes(str(entry["FileHash"]))
		if sha1.size() != 20:
			return _fail("Invalid manifest: bad file hash for %s" % entry.get("Filename", ""))
		var parts: Array = []
		var total := 0
		var raw_parts = entry["FileChunkParts"]
		if not (raw_parts is Array):
			return _fail("Invalid manifest: malformed chunk parts")
		for raw in raw_parts:
			if not (raw is Dictionary) or not raw.has("Guid") or not raw.has("Offset") or not raw.has("Size"):
				return _fail("Invalid manifest: malformed chunk part")
			var guid := _guid_from_json(str(raw["Guid"]))
			if guid.is_empty():
				return _fail("Invalid manifest: bad part GUID %s" % raw["Guid"])
			var part_size := _blob_to_int(str(raw["Size"]))
			total += part_size
			parts.append({"guid": guid_hex(guid), "offset": _blob_to_int(str(raw["Offset"])), "size": part_size})
		files.append({"filename": str(entry.get("Filename", "")), "sha1": sha1, "parts": parts, "size": total})

	return {
		"ok": true,
		"error": "",
		"feature_level": feature_level,
		"build_version": str(document.get("BuildVersionString", "")),
		"chunks": chunks,
		"files": files,
	}


## JSON manifests store numbers as little-endian bytes, each written as three decimal digits.
static func _blob_to_int(blob: String) -> int:
	var value := 0
	var shift := 0
	var i := 0
	while i + 3 <= blob.length() and shift < 64:
		value |= blob.substr(i, 3).to_int() << shift
		shift += 8
		i += 3
	return value


static func _blob_to_bytes(blob: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(blob.length() / 3)
	for i in out.size():
		out[i] = blob.substr(i * 3, 3).to_int() & 0xFF
	return out


## 32 hex chars, big-endian per u32. Empty Array on malformed input.
static func _guid_from_json(text: String) -> Array:
	if text.length() != 32 or not text.is_valid_hex_number(false):
		return []
	var guid: Array = []
	for i in 4:
		guid.append(("0x" + text.substr(i * 8, 8)).hex_to_int())
	return guid


# --- helpers -------------------------------------------------------------------------------------

static func _chunk_folder(feature_level: int) -> String:
	if feature_level >= 22:
		return "ChunksV5"
	if feature_level >= 15:
		return "ChunksV4"
	if feature_level >= 6:
		return "ChunksV3"
	if feature_level >= 3:
		return "ChunksV2"
	return "Chunks"


## u64 bits of an int as 16 upper-case hex chars (no sign).
static func _hash_hex(value: int) -> String:
	return "%08X%08X" % [(value >> 32) & 0xFFFFFFFF, value & 0xFFFFFFFF]


static func _guid_bytes(guid: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(16)
	for i in 4:
		out.encode_u32(i * 4, guid[i])
	return out


## base64url without padding.
static func _b64url(data: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(data).replace("+", "-").replace("/", "_").rstrip("=")
