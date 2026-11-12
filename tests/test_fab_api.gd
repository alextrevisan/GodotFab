extends "res://tests/test_case.gd"

const FabApi = preload("res://addons/godotfab/fab_api.gd")
const Http = preload("res://addons/godotfab/http.gd")
const FakeFetch = preload("res://tests/fakes/fake_fetch.gd")


class FakeAuth extends RefCounted:
	var token := "tok"
	var account_id := "acc1"
	var logged_out := false
	func is_logged_in() -> bool: return not token.is_empty()
	func ensure_token() -> String: return token
	func logout() -> void:
		logged_out = true
		token = ""


func _api() -> Array:
	var fake := FakeFetch.new()
	var api := FabApi.new()
	api.fetch = fake.fetch
	api.auth = FakeAuth.new()
	api.throttle_ms = 0
	return [api, fake]


func test_build_search_url() -> void:
	var url := FabApi.build_search_url("wood chair", "3d-model", true, "-createdAt")
	assert_eq(url, "https://www.fab.com/i/listings/search?asset_formats=gltf,fbx,unreal-engine&q=wood%20chair&listing_types=3d-model&is_free=1&sort_by=-createdAt")
	var minimal := FabApi.build_search_url("", "", false, "-relevance")
	assert_eq(minimal, "https://www.fab.com/i/listings/search?asset_formats=gltf,fbx,unreal-engine&sort_by=-relevance")
	var ue_only := FabApi.build_search_url("", "", false, "", PackedStringArray(["unreal-engine"]))
	assert_eq(ue_only, "https://www.fab.com/i/listings/search?asset_formats=unreal-engine")


func test_search_parses_results_and_next() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	fake.add("listings/search", {"json": read_json("res://tests/fixtures/search.json")})
	var result = await api.search(FabApi.build_search_url("chair", "", true, "-relevance"))
	assert_true(result.ok, result.get("error", ""))
	assert_eq(result.results.size(), 24)
	assert_eq(result.results[0].uid, "d62376d5-c183-424b-964d-6c3d6a8a0f70")
	assert_contains(result.next, "cursor=bz0yNA")
	assert_eq(FakeFetch.header(fake.requests[0], "Accept"), "application/json")
	assert_eq(FakeFetch.header(fake.requests[0], "Authorization"), "", "search is anonymous")


func test_search_retries_on_429() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	api.retry_wait_s = 0.0
	fake.add("", {"status": 429})
	fake.add("", {"json": {"results": [], "cursors": {"next": null}, "next": null}})
	var result = await api.search("https://www.fab.com/i/listings/search?q=x")
	assert_true(result.ok)
	assert_eq(fake.requests.size(), 2)
	assert_eq(result.next, "")


func test_search_error() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	fake.add("", {"status": 500})
	var result = await api.search("https://www.fab.com/i/listings/search?q=x")
	assert_false(result.ok)
	assert_contains(result.error, "500")


func test_thumbnail_url_picks_min_width() -> void:
	var listing: Dictionary = read_json("res://tests/fixtures/search.json").results[0]
	var url := FabApi.thumbnail_url(listing, 300)
	assert_true(url.ends_with(".jpg"))
	var images: Array = listing.thumbnails[0].images
	var chosen: Dictionary = {}
	for img in images:
		if img.url == url:
			chosen = img
	assert_eq(int(chosen.get("width", 0)), 320)
	assert_eq(FabApi.thumbnail_url(listing, 10000), images.back().url, "largest when none is wide enough")
	assert_eq(FabApi.thumbnail_url({}, 100), "")
	assert_eq(FabApi.thumbnail_url({"thumbnails": [{"mediaUrl": "m.jpg", "images": []}]}, 100), "m.jpg")


func test_formats_of_and_choose_format() -> void:
	var listing: Dictionary = read_json("res://tests/fixtures/search.json").results[0]
	assert_eq(FabApi.formats_of(listing), ["blender", "fbx", "obj", "gltf", "additional-files"])
	assert_true(FabApi.has_unreal_format({"assetFormats": [{"assetFormatType": {"code": "unreal-engine"}}]}))
	assert_false(FabApi.has_unreal_format(listing))
	assert_eq(FabApi.choose_format(listing, "gltf"), "gltf")
	assert_eq(FabApi.choose_format(listing, "fbx"), "fbx")
	assert_eq(FabApi.choose_format(listing, "unreal-engine"), "gltf", "falls back to gltf when UE missing")
	var ue := {"assetFormats": [{"assetFormatType": {"code": "unreal-engine"}}, {"assetFormatType": {"code": "fbx"}}]}
	assert_eq(FabApi.choose_format(ue, "gltf"), "fbx")
	assert_eq(FabApi.choose_format(ue, "unreal-engine"), "unreal-engine")
	assert_eq(FabApi.choose_format({"assetFormats": [{"assetFormatType": {"code": "blender"}}]}, "gltf"), "")


func test_price_label() -> void:
	assert_eq(FabApi.price_label({"isFree": true}), "Free")
	assert_eq(FabApi.price_label({"isFree": false, "startingPrice": {"price": 0.0}}), "Free")
	assert_eq(FabApi.price_label({"isFree": false, "startingPrice": {"price": 12.5, "currencyCode": "USD"}}), "USD 12.50")
	assert_eq(FabApi.price_label({"isFree": false, "startingPrice": {"price": 12.5}}), "$ 12.50")
	assert_eq(FabApi.price_label({}), "")


func test_library_pages_with_cursor_and_bearer() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	fake.add("cursor=", {"json": {"results": [{"assetId": "b", "title": "B"}], "cursors": {"next": null}}})
	fake.add("ue/library", {"json": {"results": [{"assetId": "a", "title": "A"}], "cursors": {"next": "c2"}}})
	api.auth.account_id = "acc1"
	var result = await api.library()
	assert_true(result.ok, result.get("error", ""))
	assert_eq(result.items.size(), 2)
	assert_eq(fake.requests.size(), 2)
	assert_eq(fake.requests[0].url, "https://www.fab.com/e/accounts/acc1/ue/library?count=100")
	assert_contains(fake.requests[1].url, "cursor=c2")
	assert_eq(FakeFetch.header(fake.requests[0], "Authorization"), "Bearer tok")
	# Cached afterwards.
	var again = await api.library()
	assert_eq(fake.requests.size(), 2)
	assert_eq(again.items.size(), 2)
	await api.library(true)
	assert_eq(fake.requests.size(), 3, "force refreshes")


func test_library_401_flags_unauthorized() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	api.auth.account_id = "acc1"
	fake.add("", {"status": 401})
	var result = await api.library()
	assert_false(result.ok)
	assert_true(result.unauthorized)


func test_library_logged_out() -> void:
	var pair := _api()
	var api = pair[0]
	api.auth.token = ""
	var result = await api.library()
	assert_false(result.ok)
	assert_true(result.unauthorized)
	assert_eq(pair[1].requests.size(), 0)


func test_library_item_for_by_url_and_asset_id() -> void:
	var items := [
		{"assetId": "x1", "url": "https://www.fab.com/listings/aaaa-1111"},
		{"assetId": "bbbb-2222", "url": ""},
	]
	assert_eq(FabApi.library_item_for(items, "aaaa-1111").assetId, "x1")
	assert_eq(FabApi.library_item_for(items, "bbbb-2222").assetId, "bbbb-2222")
	assert_eq(FabApi.library_item_for(items, "zzzz"), {})
	assert_eq(FabApi.listing_uid_of(items[0]), "aaaa-1111")
	assert_eq(FabApi.listing_uid_of(items[1]), "bbbb-2222")


func test_pick_project_version() -> void:
	var item := {"projectVersions": [
		{"artifactId": "old", "engineVersions": ["UE_5.3", "UE_5.4"]},
		{"artifactId": "new", "engineVersions": ["UE_5.7", "UE_5.8"]},
	]}
	assert_eq(FabApi.pick_project_version(item, "UE_5.8").artifactId, "new")
	assert_eq(FabApi.pick_project_version(item, "UE_5.4").artifactId, "old")
	assert_eq(FabApi.pick_project_version(item, "UE_6.0").artifactId, "new", "newest when no match")
	assert_eq(FabApi.pick_project_version({}, "UE_5.8"), {})


func _download_info_json() -> Dictionary:
	return {"downloadInfo": [{
		"artifactId": "art1", "buildVersion": "1.2",
		"distributionPointBaseUrls": ["https://cdn-a.example/path", "https://cdn-b.example/other/"],
		"distributionPoints": [
			{"manifestUrl": "https://cdn-b.example/other/m.manifest?sig=2"},
			{"manifestUrl": "https://cdn-a.example/path/m.manifest?sig=1"},
		],
	}]}


func test_manifest_pointers_pairs_sources() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	fake.add("artifacts/art1/manifest", {"json": _download_info_json()})
	var item := {"assetId": "asset1", "assetNamespace": "ns1"}
	var result = await api.manifest_pointers(item, {"artifactId": "art1"})
	assert_true(result.ok, result.get("error", ""))
	assert_eq(result.build_version, "1.2")
	assert_eq(result.sources.size(), 2)
	assert_eq(result.sources[0], {"manifest_url": "https://cdn-a.example/path/m.manifest?sig=1", "base_url": "https://cdn-a.example/path"})
	assert_eq(result.sources[1].base_url, "https://cdn-b.example/other")
	var req: Dictionary = fake.requests[0]
	assert_eq(req.method, "POST")
	assert_eq(JSON.parse_string(req.body), {"item_id": "asset1", "namespace": "ns1", "platform": "Windows"})
	assert_eq(FakeFetch.header(req, "Content-Type"), "application/json")
	assert_eq(FakeFetch.header(req, "Authorization"), "Bearer tok")


func test_pair_sources_without_matching_base_uses_manifest_folder() -> void:
	var info := {
		"distributionPointBaseUrls": ["https://other.example/Builds/x/CloudDir"],
		"distributionPoints": [
			{"manifestUrl": "https://cdn-a.example/Builds/x/CloudDir/m.manifest?sig=1"},
			{"manifestUrl": ""},
		],
	}
	assert_eq(FabApi.pair_sources(info), [{"manifest_url": "https://cdn-a.example/Builds/x/CloudDir/m.manifest?sig=1", "base_url": "https://cdn-a.example/Builds/x/CloudDir"}])
	info.erase("distributionPointBaseUrls")
	assert_eq(FabApi.pair_sources(info).size(), 1)


func test_file_download_info_direct_url() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("download-info", {"json": {"downloadInfo": [{"assetFormat": "fbx", "downloadUrl": "https://cdn.example/f.zip?sig=1", "expires": "x", "type": "file"}]}})
	var result = await api.file_download_info("uid1", "fbx", "f1")
	assert_true(result.ok, result.get("error", ""))
	assert_eq(result.download_url, "https://cdn.example/f.zip?sig=1")
	assert_eq(result.sources, [])


func test_file_download_info_404_means_not_owned() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("download-info", {"status": 404, "json": {"detail": "Not found."}})
	var result = await api.file_download_info("uid1", "fbx", "f1")
	assert_false(result.ok)
	assert_true(result.get("not_owned", false), "404: the account doesn't own the listing")
	assert_false(result.unauthorized)


func test_manifest_pointers_403_message() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("", {"status": 403})
	var result = await api.manifest_pointers({"assetId": "a", "assetNamespace": "n"}, {"artifactId": "x"})
	assert_false(result.ok)
	assert_contains(result.error, "rate")


func test_manifest_pointers_no_sources() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("", {"json": {"downloadInfo": [{"distributionPointBaseUrls": [], "distributionPoints": []}]}})
	var result = await api.manifest_pointers({"assetId": "a", "assetNamespace": "n"}, {"artifactId": "x"})
	assert_false(result.ok)


func test_listing_format_files() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("asset-formats/gltf", {"json": read_json("res://tests/fixtures/format_gltf.json")})
	var result = await api.listing_format("uid1", "gltf")
	assert_true(result.ok)
	assert_eq(result.files.size(), 1)
	assert_eq(result.files[0].name, "source.zip")
	assert_eq(pair[1].requests[0].url, "https://www.fab.com/i/listings/uid1/asset-formats/gltf")


func test_file_download_info_parses_sources() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("download-info", {"json": _download_info_json()})
	var result = await api.file_download_info("uid1", "gltf", "file1")
	assert_true(result.ok)
	assert_eq(result.sources.size(), 2)
	assert_eq(pair[1].requests[0].url, "https://www.fab.com/p/egl/listings/uid1/asset-formats/gltf/files/file1/download-info")
	assert_eq(FakeFetch.header(pair[1].requests[0], "Authorization"), "Bearer tok")


func test_cookie_value() -> void:
	var headers := PackedStringArray(["Content-Type: text/html", "Set-Cookie: fab_csrftoken=abc123; Path=/; Secure", "set-cookie: other=1"])
	assert_eq(Http.cookie_value(headers, "fab_csrftoken"), "abc123")
	assert_eq(Http.cookie_value(headers, "other"), "1")
	assert_eq(Http.cookie_value(headers, "none"), "")


func test_add_to_library_sends_csrf() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	fake.add("/i/csrf", {"status": 200, "headers": PackedStringArray(["Set-Cookie: fab_csrftoken=abc; Path=/"])})
	fake.add("add-to-library", {"status": 204})
	var result = await api.add_to_library("uid1")
	assert_true(result.ok, result.get("error", ""))
	assert_eq(fake.requests.size(), 2)
	var post: Dictionary = fake.requests[1]
	assert_eq(post.method, "POST")
	assert_eq(post.url, "https://www.fab.com/i/listings/uid1/add-to-library")
	assert_eq(FakeFetch.header(post, "X-CSRFToken"), "abc")
	assert_contains(FakeFetch.header(post, "Cookie"), "fab_csrftoken=abc")
	assert_eq(FakeFetch.header(post, "Authorization"), "Bearer tok")
	assert_eq(FakeFetch.header(post, "Referer"), "https://www.fab.com/listings/uid1")


func test_add_to_library_401_needs_web() -> void:
	var pair := _api()
	var api = pair[0]
	pair[1].add("/i/csrf", {"status": 200, "headers": PackedStringArray(["Set-Cookie: fab_csrftoken=abc; Path=/"])})
	pair[1].add("add-to-library", {"status": 401})
	var result = await api.add_to_library("uid1")
	assert_false(result.ok)
	assert_true(result.needs_web)
	assert_contains(result.error, "fab.com")


func test_listing() -> void:
	var pair := _api()
	pair[1].add("/i/listings/8aac", {"json": read_json("res://tests/fixtures/listing.json")})
	var result = await pair[0].listing("8aac261f-4818-4526-a36e-ff815f6693af")
	assert_true(result.ok)
	assert_eq(result.data.title, "Table and Chair Game Prop")


func test_thumbnail_caches_file() -> void:
	var pair := _api()
	var api = pair[0]
	var fake = pair[1]
	var dir := tmp_dir()
	var png := PackedByteArray([1, 2, 3])
	fake.add("media.fab.com", {"status": 200, "body": png}, true)
	var listing := {"uid": "u1", "thumbnails": [{"images": [{"url": "https://media.fab.com/a.jpg", "width": 320, "height": 180}]}]}
	var path = await api.thumbnail(listing, dir, 300)
	assert_eq(path, dir.path_join("u1_320.jpg"))
	assert_eq(FileAccess.get_file_as_bytes(path), png)
	var again = await api.thumbnail(listing, dir, 300)
	assert_eq(again, path)
	assert_eq(fake.requests.size(), 1, "second call served from disk")


func test_engine_versions_of_and_build_for_engine() -> void:
	var builds := [
		{"artifactId": "a", "engineVersions": ["UE_4.27", "UE_5.0"]},
		{"artifactId": "b", "engineVersions": ["UE_5.3", "UE_5.8", "UE_5.0"]},
		"junk",
	]
	assert_eq(FabApi.engine_versions_of(builds), ["UE_5.8", "UE_5.3", "UE_5.0", "UE_4.27"])
	assert_eq(FabApi.build_for_engine(builds, "UE_5.3").artifactId, "b")
	assert_eq(FabApi.build_for_engine(builds, "UE_4.27").artifactId, "a")
	assert_eq(FabApi.build_for_engine(builds, "UE_6.0"), {})
	assert_eq(FabApi.engine_versions_of([]), [])


func test_listing_format_versions() -> void:
	var pair := _api()
	pair[1].add("asset-formats/unreal-engine", {"json": {"files": [], "versions": [{"artifactId": "art", "engineVersions": ["UE_5.8"], "name": "1.0"}]}})
	var result = await pair[0].listing_format("uid1", "unreal-engine")
	assert_true(result.ok)
	assert_eq(result.versions.size(), 1)
	assert_eq(result.versions[0].artifactId, "art")
