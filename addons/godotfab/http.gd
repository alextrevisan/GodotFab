@tool
extends RefCounted
## HTTP for the addon: one awaitable `fetch(req)` built on a temporary
## HTTPRequest node, so services can be tested with a fake Callable.
##
## req: {method: "GET"|"POST"|"DELETE", url: String, headers: PackedStringArray,
##       body: String|PackedByteArray, timeout: float}
## result: {ok: bool (transport ok and 2xx), status: int, body: PackedByteArray,
##          json: Variant|null, headers: PackedStringArray, error: String}

const Log = preload("res://addons/godotfab/log.gd")

## Epic's services expect a launcher user agent.
const USER_AGENT := "UELauncher/17.0.1-37584233+++Portal+Release-Live Windows/10.0.19043.1.0.64bit"
const DEFAULT_TIMEOUT := 60.0

## The node the HTTPRequest children are added to.
var parent: Node
## Last request time per throttle key, msec.
static var _last_call: Dictionary = {}


func _init(new_parent: Node) -> void:
	parent = new_parent


## The caller must keep the returned Http alive (a Callable doesn't hold a
## RefCounted), e.g. `var http := Http.new(self)` then `api.fetch = http.fetch`.


func fetch(req: Dictionary) -> Dictionary:
	var result := {"ok": false, "status": 0, "body": PackedByteArray(), "json": null, "headers": PackedStringArray(), "error": ""}
	if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
		result.error = "no node to make the request from"
		return result
	var request := HTTPRequest.new()
	request.use_threads = true
	request.accept_gzip = true
	request.timeout = float(req.get("timeout", DEFAULT_TIMEOUT))
	parent.add_child(request)
	var headers := PackedStringArray(req.get("headers", PackedStringArray()))
	if not _has_header(headers, "User-Agent"):
		headers.append("User-Agent: " + USER_AGENT)
	var method := _method(str(req.get("method", "GET")))
	var body = req.get("body", PackedByteArray())
	var body_bytes: PackedByteArray = body.to_utf8_buffer() if body is String else PackedByteArray(body)
	var url := str(req.url)
	Log.debug("%s %s" % [req.get("method", "GET"), url.split("?")[0]])
	var err := request.request_raw(url, headers, method, body_bytes)
	if err != OK:
		request.queue_free()
		result.error = "request failed to start (%s)" % error_string(err)
		return result
	var response: Array = await request.request_completed
	request.queue_free()
	var transport: int = response[0]
	result.status = response[1]
	result.headers = response[2]
	result.body = response[3]
	if transport != HTTPRequest.RESULT_SUCCESS:
		result.error = _transport_error(transport)
		return result
	var content_type := header_value(result.headers, "Content-Type").to_lower()
	if content_type.contains("json") and result.body.size() > 0:
		result.json = JSON.parse_string(result.body.get_string_from_utf8())
	result.ok = result.status >= 200 and result.status < 300
	if not result.ok:
		result.error = "HTTP %d" % result.status
		if result.json is Dictionary:
			var message := str(result.json.get("errorMessage", result.json.get("detail", result.json.get("errorCode", ""))))
			if message:
				result.error += ": " + message
	return result


## Waits so that calls with the same [param key] are at least
## [param min_interval_ms] apart.
static func throttle(key: String, min_interval_ms: int) -> void:
	var now := Time.get_ticks_msec()
	var last: int = _last_call.get(key, -min_interval_ms)
	var wait := last + min_interval_ms - now
	if wait > 0:
		await Engine.get_main_loop().create_timer(wait / 1000.0).timeout
	_last_call[key] = Time.get_ticks_msec()


static func header_value(headers: PackedStringArray, name: String) -> String:
	var prefix := name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(prefix.length()).strip_edges()
	return ""


## The value of cookie [param name] from the Set-Cookie headers, "" if absent.
static func cookie_value(headers: PackedStringArray, name: String) -> String:
	for h in headers:
		if not h.to_lower().begins_with("set-cookie:"):
			continue
		var cookie := h.substr("set-cookie:".length()).strip_edges()
		var pair := cookie.split(";")[0].strip_edges()
		if pair.begins_with(name + "="):
			return pair.substr(name.length() + 1)
	return ""


static func _has_header(headers: PackedStringArray, name: String) -> bool:
	return not header_value(headers, name).is_empty()


static func _method(name: String) -> HTTPClient.Method:
	match name.to_upper():
		"POST": return HTTPClient.METHOD_POST
		"DELETE": return HTTPClient.METHOD_DELETE
		"PUT": return HTTPClient.METHOD_PUT
		"HEAD": return HTTPClient.METHOD_HEAD
		_: return HTTPClient.METHOD_GET


static func _transport_error(code: int) -> String:
	match code:
		HTTPRequest.RESULT_CANT_CONNECT: return "can't connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "can't resolve host"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS handshake error"
		HTTPRequest.RESULT_NO_RESPONSE: return "no response"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "body too large"
		HTTPRequest.RESULT_REQUEST_FAILED: return "request failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: return "can't open download file"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: return "download file write error"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "too many redirects"
		HTTPRequest.RESULT_TIMEOUT: return "timeout"
		_: return "transport error %d" % code
