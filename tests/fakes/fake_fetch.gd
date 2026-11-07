extends RefCounted
## A fake of the Http fetch Callable: answers from a queue or by URL match.
## responses: Array of {match: String (url substring, "" = any), ok, status,
## json, body, headers}. Each matching entry is consumed once unless
## `keep` is true. Records every request in `requests`.

var responses: Array = []
var requests: Array = []
## Frames to wait before answering, to exercise cancellation.
var delay_frames := 0


func add(match: String, response: Dictionary, keep := false) -> void:
	response = response.duplicate()
	response["match"] = match
	response["keep"] = keep
	responses.append(response)


func fetch(req: Dictionary) -> Dictionary:
	requests.append(req)
	for i in delay_frames:
		await Engine.get_main_loop().process_frame
	for i in responses.size():
		var r: Dictionary = responses[i]
		if r.match.is_empty() or str(req.url).contains(r.match):
			if not r.keep:
				responses.remove_at(i)
			return _normalize(r)
	return {"ok": false, "status": 0, "body": PackedByteArray(), "json": null, "headers": PackedStringArray(), "error": "no fake response for %s" % req.url}


static func _normalize(r: Dictionary) -> Dictionary:
	var status: int = r.get("status", 200)
	var body: PackedByteArray = r.get("body", PackedByteArray())
	var json = r.get("json", null)
	if json != null and body.is_empty():
		body = JSON.stringify(json).to_utf8_buffer()
	return {
		"ok": r.get("ok", status >= 200 and status < 300),
		"status": status,
		"body": body,
		"json": json,
		"headers": r.get("headers", PackedStringArray()),
		"error": r.get("error", "" if status >= 200 and status < 300 else "HTTP %d" % status),
	}


static func header(req: Dictionary, name: String) -> String:
	for h in req.get("headers", PackedStringArray()):
		var line := str(h)
		if line.to_lower().begins_with(name.to_lower() + ":"):
			return line.substr(name.length() + 1).strip_edges()
	return ""
