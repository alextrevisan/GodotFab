@tool
extends RefCounted
## Reads which texture files each material of an FBX (binary or ASCII) uses, straight
## from the file (Godot's FBX importer drops the references it can't load).
## Only the Objects (Material, Texture) and Connections sections are read;
## array properties (geometry) are skipped by length, never decompressed.

const MAGIC := "Kaydara FBX Binary  "

## {ok, error, materials: {material name: [{property, relative, file}]}}.
## `property` is the FBX material property the texture feeds (DiffuseColor,
## NormalMap...); `relative` and `file` are the RelativeFilename and FileName
## of the texture, with "/" separators.
static func parse(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 27:
		return _fail("Cannot read %s" % path)
	return parse_bytes(bytes)


static func parse_bytes(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 27 or bytes.slice(0, 20).get_string_from_ascii() != MAGIC:
		var head := bytes.slice(0, 512).get_string_from_utf8()
		if head.contains("FBX") and (head.contains("Objects:") or head.begins_with(";")):
			return _parse_ascii(bytes.get_string_from_utf8())
		return _fail("Not an FBX")
	var version := bytes.decode_u32(23)
	var wide := version >= 7500
	var objects := {}
	var connections: Array = []
	var pos := 27
	while pos < bytes.size():
		var node := _read_header(bytes, pos, wide)
		if node.is_empty() or node.end == 0:
			break
		if node.name == "Objects":
			_read_objects(bytes, node, wide, objects)
		elif node.name == "Connections":
			for child in _children(bytes, node, wide):
				var props := _read_props(bytes, child)
				if props.size() >= 3:
					connections.append(props)
		pos = node.end
	return _link(objects, connections)


## {ok, error, materials} from the objects {id: {type, name, relative?, file?}}
## and the connections [kind, child id, parent id, property?].
static func _link(objects: Dictionary, connections: Array) -> Dictionary:
	var materials := {}
	for c in connections:
		if str(c[0]) != "OP" or not objects.has(c[1]) or not objects.has(c[2]):
			continue
		var texture: Dictionary = objects[c[1]]
		var material: Dictionary = objects[c[2]]
		if texture.type != "Texture" or material.type != "Material":
			continue
		if not materials.has(material.name):
			materials[material.name] = []
		materials[material.name].append({"property": str(c[3]) if c.size() > 3 else "",
			"relative": texture.get("relative", ""), "file": texture.get("file", "")})
	return {"ok": true, "error": "", "materials": materials}


## The ASCII FBX form: one node per line ("Name: props {"), so the Material
## and Texture blocks of Objects and the "C:" lines of Connections are read
## line by line; geometry arrays are skipped by brace depth.
static func _parse_ascii(text: String) -> Dictionary:
	var objects := {}
	var connections: Array = []
	var section := ""
	var depth := 0
	var current := {}
	var current_id := 0
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with(";"):
			continue
		var key := line.get_slice(":", 0).strip_edges()
		var value := line.substr(line.find(":") + 1).strip_edges() if line.contains(":") else ""
		if depth == 0 and line.ends_with("{"):
			section = key
		elif depth == 1 and section == "Objects" and line.ends_with("{") and (key == "Material" or key == "Texture"):
			var props := _ascii_props(value.trim_suffix("{"))
			if props.size() >= 2:
				var name := str(props[1])
				current_id = int(props[0])
				current = {"type": key, "name": name.substr(name.find("::") + 2) if name.contains("::") else name}
				objects[current_id] = current
		elif depth == 2 and not current.is_empty() and (key == "RelativeFilename" or key == "FileName"):
			var props := _ascii_props(value)
			if props.size() > 0:
				current["relative" if key == "RelativeFilename" else "file"] = str(props[0]).replace("\\", "/")
		elif depth == 1 and section == "Connections" and key == "C":
			var props := _ascii_props(value)
			if props.size() >= 3:
				connections.append(props)
		depth += line.count("{") - line.count("}")
		if depth <= 1:
			current = {}
		if depth == 0:
			section = ""
	return _link(objects, connections)


## The comma-separated values of an ASCII FBX line: quoted strings, integers.
static func _ascii_props(text: String) -> Array:
	var out: Array = []
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "\"":
			var end := text.find("\"", i + 1)
			if end < 0:
				end = text.length()
			out.append(text.substr(i + 1, end - i - 1))
			i = text.find(",", end)
			if i < 0:
				break
		elif c != " " and c != ",":
			var end := text.find(",", i)
			if end < 0:
				end = text.length()
			var token := text.substr(i, end - i).strip_edges()
			out.append(int(token) if token.is_valid_int() else token)
			i = end
		i += 1
	return out


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "materials": {}}


static func _read_objects(bytes: PackedByteArray, objects_node: Dictionary, wide: bool, out: Dictionary) -> void:
	for child in _children(bytes, objects_node, wide):
		if child.name != "Material" and child.name != "Texture":
			continue
		var props := _read_props(bytes, child)
		if props.size() < 2:
			continue
		# Names are "Name\x00\x01Class"; strings are cut at the NUL.
		var info := {"type": child.name, "name": str(props[1])}
		if child.name == "Texture":
			for sub in _children(bytes, child, wide):
				if sub.name == "RelativeFilename" or sub.name == "FileName":
					var value := _read_props(bytes, sub)
					if value.size() > 0:
						info["relative" if sub.name == "RelativeFilename" else "file"] = str(value[0]).replace("\\", "/")
		out[props[0]] = info


## {name, end, props_at, num_props, children_at}; {} past the data.
static func _read_header(bytes: PackedByteArray, pos: int, wide: bool) -> Dictionary:
	var header := 25 if wide else 13
	if pos + header > bytes.size():
		return {}
	var end := bytes.decode_u64(pos) if wide else bytes.decode_u32(pos)
	var num_props := bytes.decode_u64(pos + 8) if wide else bytes.decode_u32(pos + 4)
	var props_len := bytes.decode_u64(pos + 16) if wide else bytes.decode_u32(pos + 8)
	var name_len := bytes[pos + header - 1]
	var name := bytes.slice(pos + header, pos + header + name_len).get_string_from_ascii()
	var props_at := pos + header + name_len
	if end > bytes.size() or end < 0:
		return {}
	return {"name": name, "end": end, "props_at": props_at, "num_props": num_props, "children_at": props_at + props_len}


static func _children(bytes: PackedByteArray, node: Dictionary, wide: bool) -> Array:
	var out: Array = []
	var sentinel := 25 if wide else 13
	var pos: int = node.children_at
	while pos < node.end - sentinel:
		var child := _read_header(bytes, pos, wide)
		if child.is_empty() or child.end == 0 or child.end <= pos:
			break
		out.append(child)
		pos = child.end
	return out


## The scalar and string properties of a node; arrays and raw data are null.
static func _read_props(bytes: PackedByteArray, node: Dictionary) -> Array:
	var out: Array = []
	var pos: int = node.props_at
	for i in node.num_props:
		if pos >= bytes.size():
			break
		var type := char(bytes[pos])
		pos += 1
		match type:
			"S", "R":
				var length := bytes.decode_u32(pos)
				var data := bytes.slice(pos + 4, pos + 4 + length)
				var nul := data.find(0)
				if nul >= 0:
					data = data.slice(0, nul)
				out.append(data.get_string_from_utf8() if type == "S" else null)
				pos += 4 + length
			"L":
				out.append(bytes.decode_s64(pos))
				pos += 8
			"I":
				out.append(bytes.decode_s32(pos))
				pos += 4
			"D":
				out.append(bytes.decode_double(pos))
				pos += 8
			"F":
				out.append(bytes.decode_float(pos))
				pos += 4
			"Y":
				out.append(bytes.decode_s16(pos))
				pos += 2
			"C":
				out.append(bytes[pos] != 0)
				pos += 1
			"f", "d", "l", "i", "b":
				out.append(null)
				pos += 12 + bytes.decode_u32(pos + 8)
			_:
				break
	return out
