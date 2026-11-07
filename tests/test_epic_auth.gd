extends "res://tests/test_case.gd"

const EpicAuth = preload("res://addons/godotfab/epic_auth.gd")

const TOKEN_JSON := {
	"access_token": "a",
	"refresh_token": "r",
	"account_id": "id",
	"displayName": "Alex",
	"expires_at": "2030-01-01T00:00:00.000Z",
}


## Fake HTTP: records every request and answers with `responses` in order
## (the last one repeats).
class FakeFetch:
	var recorded: Array[Dictionary] = []
	var responses: Array = []

	func _init(p_responses: Array) -> void:
		responses = p_responses

	func fetch(req: Dictionary) -> Dictionary:
		recorded.append(req)
		await Engine.get_main_loop().process_frame
		var index := mini(recorded.size() - 1, responses.size() - 1)
		return responses[index]


static func ok_response(json: Dictionary) -> Dictionary:
	return {"ok": true, "status": 200, "body": PackedByteArray(), "json": json, "error": ""}


func make_auth(fake: FakeFetch) -> EpicAuth:
	var auth := EpicAuth.new()
	auth.auth_path = tmp_dir().path_join("auth.json")
	auth.fetch = fake.fetch
	return auth


func test_login_url() -> void:
	var url := EpicAuth.login_url()
	assert_true(url.begins_with("https://www.epicgames.com/id/login?redirectUrl="), "login prefix")
	assert_contains(url, "https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")


func test_parse_authorization_code_bare() -> void:
	assert_eq(EpicAuth.parse_authorization_code("  abc123DEF \n"), "abc123DEF")
	assert_eq(EpicAuth.parse_authorization_code("\"abc123\""), "abc123")


func test_parse_authorization_code_json() -> void:
	var text := '{"redirectUrl":"x","authorizationCode":"8f2a9c","exchangeCode":null}'
	assert_eq(EpicAuth.parse_authorization_code(text), "8f2a9c")


func test_parse_authorization_code_invalid() -> void:
	assert_eq(EpicAuth.parse_authorization_code(""), "")
	assert_eq(EpicAuth.parse_authorization_code("abc-123"), "")
	assert_eq(EpicAuth.parse_authorization_code("{not json"), "")
	assert_eq(EpicAuth.parse_authorization_code('{"authorizationCode": null}'), "")
	assert_eq(EpicAuth.parse_authorization_code('{"authorizationCode": "bad code"}'), "")


func test_needs_refresh() -> void:
	assert_true(EpicAuth.needs_refresh(1000.0, 500.0), "less than 10 min left")
	assert_true(EpicAuth.needs_refresh(1000.0, 2000.0), "already expired")
	assert_false(EpicAuth.needs_refresh(1000.0, 399.0), "more than 10 min left")
	assert_true(EpicAuth.needs_refresh(0.0, 1.0), "unknown expiry")


func test_parse_expires() -> void:
	assert_eq(EpicAuth.parse_expires("2030-01-01T00:00:00.000Z"), 1893456000.0)
	assert_eq(EpicAuth.parse_expires("2026-11-06T12:00:00Z"), 1793966400.0)
	assert_eq(EpicAuth.parse_expires(""), 0.0)


func test_sign_in_saves_session() -> void:
	var fake := FakeFetch.new([ok_response(TOKEN_JSON)])
	var auth := make_auth(fake)
	var changed_count := [0]
	var account_count := [0]
	auth.changed.connect(func(): changed_count[0] += 1)
	auth.account_changed.connect(func(): account_count[0] += 1)

	var result: Dictionary = await auth.sign_in('{"authorizationCode":"c0de"}')

	assert_true(result.ok, "sign_in ok: %s" % result.get("error", ""))
	assert_true(auth.is_logged_in(), "logged in")
	assert_eq(auth.access_token, "a")
	assert_eq(auth.refresh_token, "r")
	assert_eq(auth.account_id, "id")
	assert_eq(auth.display_name, "Alex")
	assert_eq(auth.expires_at, 1893456000.0)
	assert_eq(changed_count[0], 1, "changed emitted")
	assert_eq(account_count[0], 1, "account_changed emitted")

	# Request shape.
	assert_eq(fake.recorded.size(), 1)
	var req: Dictionary = fake.recorded[0]
	assert_eq(req.method, "POST")
	assert_eq(req.url, "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token")
	assert_contains(str(req.body), "grant_type=authorization_code")
	assert_contains(str(req.body), "code=c0de")
	assert_contains(str(req.body), "token_type=eg1")
	var headers := "\n".join(req.headers)
	assert_contains(headers, "Authorization: basic " + Marshalls.utf8_to_base64("34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf"))
	assert_contains(headers, "Content-Type: application/x-www-form-urlencoded")

	# Saved file.
	assert_true(FileAccess.file_exists(auth.auth_path), "auth file exists")
	var saved = read_json(auth.auth_path)
	assert_eq(saved.access_token, "a")
	assert_eq(saved.refresh_token, "r")
	assert_eq(saved.account_id, "id")
	assert_eq(saved.display_name, "Alex")
	assert_eq(float(saved.expires_at), 1893456000.0)
	if not OS.has_feature("windows"):
		assert_eq(FileAccess.get_unix_permissions(auth.auth_path), FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER, "0600")

	# A fresh instance loads it back.
	var again := EpicAuth.new()
	again.auth_path = auth.auth_path
	again.load()
	assert_true(again.is_logged_in(), "loaded")
	assert_eq(again.display_name, "Alex")
	assert_eq(again.expires_at, 1893456000.0)
	again.free()
	auth.free()


func test_sign_in_invalid_code() -> void:
	var fake := FakeFetch.new([ok_response(TOKEN_JSON)])
	var auth := make_auth(fake)
	var result: Dictionary = await auth.sign_in("not a code!")
	assert_false(result.ok)
	assert_contains(result.error, "authorizationCode")
	assert_eq(fake.recorded.size(), 0, "no request sent")
	assert_false(auth.is_logged_in())
	auth.free()


func test_sign_in_error_message() -> void:
	var fake := FakeFetch.new([{"ok": false, "status": 400, "body": PackedByteArray(), "json": {"errorMessage": "bad", "errorCode": "errors.com.epicgames.x"}, "error": ""}])
	var auth := make_auth(fake)
	var result: Dictionary = await auth.sign_in("abc")
	assert_eq(result, {"ok": false, "error": "bad"})
	assert_false(auth.is_logged_in())
	assert_false(FileAccess.file_exists(auth.auth_path), "nothing saved")
	auth.free()


func test_sign_in_transport_error() -> void:
	var fake := FakeFetch.new([{"ok": false, "status": 0, "body": PackedByteArray(), "json": null, "error": "Connection failed"}])
	var auth := make_auth(fake)
	var result: Dictionary = await auth.sign_in("abc")
	assert_false(result.ok)
	assert_eq(result.error, "Connection failed")
	auth.free()


func test_ensure_token_refreshes() -> void:
	var refreshed := TOKEN_JSON.duplicate()
	refreshed.access_token = "new"
	refreshed.refresh_token = "r2"
	var fake := FakeFetch.new([ok_response(refreshed)])
	var auth := make_auth(fake)
	auth.access_token = "old"
	auth.refresh_token = "r"
	auth.account_id = "id"
	auth.display_name = "Alex"
	auth.expires_at = Time.get_unix_time_from_system() + 60.0
	var account_count := [0]
	auth.account_changed.connect(func(): account_count[0] += 1)

	var token: String = await auth.ensure_token()

	assert_eq(token, "new")
	assert_eq(auth.access_token, "new")
	assert_eq(auth.refresh_token, "r2")
	assert_eq(auth.expires_at, 1893456000.0)
	assert_eq(fake.recorded.size(), 1)
	assert_contains(str(fake.recorded[0].body), "grant_type=refresh_token")
	assert_contains(str(fake.recorded[0].body), "refresh_token=r")
	assert_eq(account_count[0], 0, "same account: no account_changed")
	assert_true(FileAccess.file_exists(auth.auth_path), "refresh saved")

	# Still valid: no second request.
	token = await auth.ensure_token()
	assert_eq(token, "new")
	assert_eq(fake.recorded.size(), 1, "no request when far from expiry")
	auth.free()


func test_ensure_token_refresh_failure_clears() -> void:
	var fake := FakeFetch.new([{"ok": false, "status": 400, "body": PackedByteArray(), "json": {"errorMessage": "expired"}, "error": ""}])
	var auth := make_auth(fake)
	auth.access_token = "old"
	auth.refresh_token = "r"
	auth.account_id = "id"
	auth.expires_at = Time.get_unix_time_from_system() + 60.0
	auth.save()
	assert_true(FileAccess.file_exists(auth.auth_path))
	var account_count := [0]
	auth.account_changed.connect(func(): account_count[0] += 1)

	var token: String = await auth.ensure_token()

	assert_eq(token, "")
	assert_false(auth.is_logged_in())
	assert_false(FileAccess.file_exists(auth.auth_path), "file removed")
	assert_eq(account_count[0], 1, "account_changed on forced logout")
	assert_contains(auth.last_error, "expired")
	auth.free()


func test_ensure_token_logged_out() -> void:
	var fake := FakeFetch.new([ok_response(TOKEN_JSON)])
	var auth := make_auth(fake)
	var token: String = await auth.ensure_token()
	assert_eq(token, "")
	assert_eq(fake.recorded.size(), 0)
	auth.free()


func test_logout_clears() -> void:
	var fake := FakeFetch.new([ok_response(TOKEN_JSON), {"ok": false, "status": 500, "body": PackedByteArray(), "json": null, "error": "boom"}])
	var auth := make_auth(fake)
	await auth.sign_in("abc")
	assert_true(auth.is_logged_in())
	var account_count := [0]
	auth.account_changed.connect(func(): account_count[0] += 1)

	await auth.logout()

	assert_false(auth.is_logged_in())
	assert_eq(auth.access_token, "")
	assert_eq(auth.refresh_token, "")
	assert_eq(auth.account_id, "")
	assert_eq(auth.display_name, "")
	assert_eq(auth.expires_at, 0.0)
	assert_false(FileAccess.file_exists(auth.auth_path), "file removed")
	assert_eq(account_count[0], 1)
	assert_eq(fake.recorded.size(), 2)
	var req: Dictionary = fake.recorded[1]
	assert_eq(req.method, "DELETE")
	assert_eq(req.url, "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/sessions/kill/a")
	assert_contains("\n".join(req.headers), "Authorization: bearer a")

	# Logging out while logged out sends nothing.
	await auth.logout()
	assert_eq(fake.recorded.size(), 2)
	auth.free()


func test_load_ignores_bad_file() -> void:
	var auth := EpicAuth.new()
	auth.auth_path = tmp_dir().path_join("auth.json")
	write_file(auth.auth_path, "not json")
	auth.load()
	assert_false(auth.is_logged_in())
	write_file(auth.auth_path, '{"access_token": "", "refresh_token": "r"}')
	auth.load()
	assert_false(auth.is_logged_in())
	auth.free()
