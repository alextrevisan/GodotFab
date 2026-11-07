@tool
extends Node
## Epic account login through the Epic Games Launcher's OAuth client (spec §3.2).
##
## The launcher client id and secret are public; they identify the launcher,
## not an account. Tokens are kept in `auth_path` as JSON readable only by the
## owner (mode 0600), like ssh keys and the GitHub CLI's token.
##
## `fetch` is the HTTP Callable of http.gd: `await fetch.call(req)` with
## `req = {method, url, headers: PackedStringArray, body, timeout}` returning
## `{ok, status, body: PackedByteArray, json, error}`.

const Log = preload("res://addons/godotfab/log.gd")

## Any UI-relevant change (tokens, name, error).
signal changed
## Logged in, logged out or switched account.
signal account_changed

const CLIENT_ID := "34a02cf8f4414e29b15921876da36f9a"
const CLIENT_SECRET := "daafbccc737745039dffe53d94fc76cf"
const OAUTH_HOST := "https://account-public-service-prod03.ol.epicgames.com"
const AUTH_FILE := "godotfab_auth.json"
## Refresh when fewer seconds than this remain.
const REFRESH_MARGIN := 600.0
const REQUEST_TIMEOUT := 30.0

var fetch: Callable
## Where the session is stored; set before `load()`.
var auth_path: String = _default_auth_path()

var access_token := ""
var refresh_token := ""
var account_id := ""
var display_name := ""
## Unix time (UTC) when `access_token` expires; 0 when unknown.
var expires_at := 0.0
## Message of the last failed login/refresh, "" when the last one worked.
var last_error := ""

var _loaded := false
var _refreshing: bool = false


func _ready() -> void:
	if not _loaded:
		self.load()


static func _default_auth_path() -> String:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_paths().get_data_dir().path_join(AUTH_FILE)
	return ProjectSettings.globalize_path("user://" + AUTH_FILE)


# MARK: public API

## Page the user signs in on; it then shows JSON with `authorizationCode`.
static func login_url() -> String:
	var redirect := "https://www.epicgames.com/id/api/redirect?clientId=%s&responseType=code" % CLIENT_ID
	return "https://www.epicgames.com/id/login?redirectUrl=" + redirect.uri_encode()


## Accepts the bare code or the whole JSON page Epic shows after signing in.
## Returns "" when the text holds no code.
static func parse_authorization_code(text: String) -> String:
	text = text.strip_edges()
	var code: Variant = ""
	if text.begins_with("{"):
		var data := _parse_json(text)
		if data is Dictionary:
			code = data.get("authorizationCode", "")
	else:
		code = text.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'").strip_edges()
	if not code is String or code.is_empty():
		return ""
	var code_str: String = code
	for c: String in code_str:
		var ok: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")
		if not ok:
			return ""
	return code_str


## True when fewer than REFRESH_MARGIN seconds remain (or the expiry is unknown).
static func needs_refresh(p_expires_at: float, now: float) -> bool:
	return p_expires_at - now < REFRESH_MARGIN


## ISO 8601 `2026-11-06T12:00:00.000Z` (UTC) -> unix time; 0 when invalid.
static func parse_expires(iso: String) -> float:
	var text := iso.strip_edges().trim_suffix("Z")
	var dot := text.find(".")
	if dot >= 0:
		text = text.left(dot)
	if text.is_empty():
		return 0.0
	return float(Time.get_unix_time_from_datetime_string(text))


func is_logged_in() -> bool:
	return not access_token.is_empty()


## Exchanges the code (or JSON) from Epic's login page for a session and
## saves it. Returns `{ok: bool, error: String}`.
func sign_in(code_text: String) -> Dictionary:
	var code := parse_authorization_code(code_text)
	if code.is_empty():
		last_error = 'That is not an authorization code. Copy the "authorizationCode" value from the page.'
		changed.emit()
		return {"ok": false, "error": last_error}
	var result: Dictionary = await _token_request({"grant_type": "authorization_code", "code": code})
	if not result.ok:
		last_error = result.error
		changed.emit()
		return {"ok": false, "error": result.error}
	_apply_tokens(result.data)
	Log.info("Logged in as %s" % display_name)
	return {"ok": true, "error": ""}


## The access token for API calls, refreshed when fewer than 10 minutes
## remain. Returns "" when logged out or when the refresh fails (the session
## is then cleared and a new sign-in is needed).
func ensure_token() -> String:
	if not is_logged_in():
		return ""
	if not needs_refresh(expires_at, _now()):
		return access_token
	if refresh_token.is_empty():
		_clear("Login expired.")
		return ""
	while _refreshing:
		# Another caller is refreshing; share its result.
		await Engine.get_main_loop().process_frame
		if not is_logged_in():
			return ""
		if not needs_refresh(expires_at, _now()):
			return access_token
	_refreshing = true
	var result: Dictionary = await _token_request({"grant_type": "refresh_token", "refresh_token": refresh_token})
	_refreshing = false
	if not result.ok:
		Log.warning("Login expired, logging out: %s" % result.error)
		_clear(result.error)
		return ""
	_apply_tokens(result.data)
	Log.verbose("Login refreshed")
	return access_token


## Ends the session on Epic's side (best effort) and forgets it locally.
func logout() -> void:
	var token := access_token
	_clear("")
	if token.is_empty():
		return
	Log.info("Logged out")
	if not fetch.is_valid():
		return
	var result = await fetch.call({
		"method": "DELETE",
		"url": "%s/account/api/oauth/sessions/kill/%s" % [OAUTH_HOST, token.uri_encode()],
		"headers": PackedStringArray(["Authorization: bearer " + token]),
		"body": "",
		"timeout": REQUEST_TIMEOUT,
	})
	if result is Dictionary and not result.get("ok", false):
		# The token may already have expired; the local copy is gone either way.
		Log.verbose("Session kill ignored: %s" % _error_of(result))


# MARK: storage

func load() -> void:
	_loaded = true
	if not FileAccess.file_exists(auth_path):
		return
	var data := _parse_json(FileAccess.get_file_as_string(auth_path))
	if not data is Dictionary:
		Log.warning("Ignoring unreadable login file %s" % auth_path)
		return
	access_token = str(data.get("access_token", ""))
	refresh_token = str(data.get("refresh_token", ""))
	account_id = str(data.get("account_id", ""))
	display_name = str(data.get("display_name", ""))
	expires_at = float(data.get("expires_at", 0))
	if not is_logged_in():
		refresh_token = ""


## Writes the session with mode 0600; removes the file when logged out.
func save() -> void:
	_loaded = true
	if not is_logged_in():
		if FileAccess.file_exists(auth_path):
			DirAccess.remove_absolute(auth_path)
		return
	DirAccess.make_dir_recursive_absolute(auth_path.get_base_dir())
	if not FileAccess.file_exists(auth_path):
		# Restrict access before the tokens are written.
		var created := FileAccess.open(auth_path, FileAccess.WRITE)
		if created == null:
			Log.warning("Could not save login to %s" % auth_path)
			return
		created.close()
		if not OS.has_feature("windows"):
			FileAccess.set_unix_permissions(auth_path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	var file := FileAccess.open(auth_path, FileAccess.WRITE)
	if file == null:
		Log.warning("Could not save login to %s" % auth_path)
		return
	file.store_string(JSON.stringify({
		"access_token": access_token,
		"refresh_token": refresh_token,
		"expires_at": expires_at,
		"account_id": account_id,
		"display_name": display_name,
	}, "\t"))
	file.close()


# MARK: helpers

## JSON.parse_string without the engine error on invalid text.
static func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _now() -> float:
	return Time.get_unix_time_from_system()


## Stores a token response and saves it.
func _apply_tokens(data: Dictionary) -> void:
	var old_account := account_id
	var was_logged_in := is_logged_in()
	access_token = str(data.get("access_token", ""))
	refresh_token = str(data.get("refresh_token", ""))
	account_id = str(data.get("account_id", ""))
	display_name = str(data.get("displayName", display_name))
	expires_at = parse_expires(str(data.get("expires_at", "")))
	last_error = ""
	save()
	changed.emit()
	if not was_logged_in or old_account != account_id:
		account_changed.emit()


func _clear(error: String) -> void:
	var had_account := is_logged_in()
	access_token = ""
	refresh_token = ""
	account_id = ""
	display_name = ""
	expires_at = 0.0
	last_error = error
	_refreshing = false
	save()
	changed.emit()
	if had_account:
		account_changed.emit()


## POST /account/api/oauth/token. Returns `{ok, error, data: Dictionary}`.
func _token_request(form: Dictionary) -> Dictionary:
	if not fetch.is_valid():
		return {"ok": false, "error": "No HTTP client.", "data": {}}
	form = form.duplicate()
	form["token_type"] = "eg1"
	var parts := PackedStringArray()
	for key in form:
		parts.append("%s=%s" % [str(key).uri_encode(), str(form[key]).uri_encode()])
	var basic := Marshalls.utf8_to_base64("%s:%s" % [CLIENT_ID, CLIENT_SECRET])
	var result = await fetch.call({
		"method": "POST",
		"url": OAUTH_HOST + "/account/api/oauth/token",
		"headers": PackedStringArray([
			"Authorization: basic " + basic,
			"Content-Type: application/x-www-form-urlencoded",
		]),
		"body": "&".join(parts),
		"timeout": REQUEST_TIMEOUT,
	})
	if not result is Dictionary:
		return {"ok": false, "error": "No response from Epic.", "data": {}}
	var data = result.get("json")
	if not result.get("ok", false):
		return {"ok": false, "error": _error_of(result), "data": {}}
	if not data is Dictionary or data.has("errorCode"):
		var message := _epic_error_message(data)
		return {"ok": false, "error": message if message else "Epic rejected the login.", "data": {}}
	for key in ["access_token", "refresh_token", "account_id", "expires_at"]:
		if not data.has(key):
			return {"ok": false, "error": "Epic's token response is missing %s." % key, "data": {}}
	return {"ok": true, "error": "", "data": data}


## Best message for a failed fetch result.
static func _error_of(result: Dictionary) -> String:
	var message := _epic_error_message(result.get("json"))
	if message:
		return message
	var error := str(result.get("error", ""))
	if error:
		return error
	var body: Variant = result.get("body")
	if body is PackedByteArray and body.size() > 0:
		return str(body.get_string_from_utf8()).left(200)
	return "HTTP %d" % int(result.get("status", 0))


static func _epic_error_message(details: Variant) -> String:
	if not details is Dictionary:
		return ""
	var message := str(details.get("errorMessage", ""))
	if message.is_empty():
		message = str(details.get("errorCode", ""))
	if message and details.get("continuationUrl"):
		message += " Open %s to continue." % details["continuationUrl"]
	return message
