@tool
extends RefCounted
## Fab's web endpoints, the ones the Epic Games Launcher and the Fab Unreal
## plugin use (Fab has no public API). Every call returns a Dictionary with
## `ok` and `error`; nothing here touches the UI.
##
## URL families: /i/ is the site's own API (anonymous for search and
## listings, cookie + CSRF for actions), /e/ and /p/ accept the Epic bearer.

const Log = preload("res://addons/godotfab/log.gd")
const Http = preload("res://addons/godotfab/http.gd")

const HOST := "https://www.fab.com"
const SEARCH_URL := HOST + "/i/listings/search"
const LISTING_URL := HOST + "/listings/%s"
const ALL_FORMATS := ["gltf", "fbx", "unreal-engine"]
const DIRECT_FORMATS := ["gltf", "fbx"]
const UNREAL_FORMAT := "unreal-engine"
## [value, label] pairs.
const SORTS := [["-relevance", "Relevance"], ["-createdAt", "Newest"], ["price", "Price: low to high"], ["-price", "Price: high to low"], ["-averageRating", "Rating"]]
const LISTING_TYPES := [["", "All types"], ["3d-model", "3D Models"], ["environment", "Environments"], ["material", "Materials"], ["animation", "Animations"], ["vfx", "VFX"], ["audio", "Audio"], ["game-template", "Templates"], ["tool-and-plugin", "Tools & Plugins"], ["hdri", "HDRI"], ["2d-asset", "2D Assets"]]
const FORMAT_LABELS := {"gltf": "glTF", "fbx": "FBX", "unreal-engine": "UE", "blender": "Blender", "obj": "OBJ", "unity": "Unity", "usd": "USD", "additional-files": "Files", "converted-files": "Converted"}
const LIBRARY_PAGE := 100
const NEEDS_WEB_MESSAGE := "Add it to your library on fab.com (the page opens in your browser), then click Refresh library."

## The HTTP fetch Callable, see Http.
var fetch: Callable
## EpicAuth (or a test double with ensure_token(), is_logged_in(), account_id).
var auth
## Minimum spacing between searches, ms (Fab answers 429 to bursts).
var throttle_ms := 1000
## Wait before the single retry of a 429.
var retry_wait_s := 2.0

var _library: Array = []
var _library_loaded := false


# MARK: search and listings

## The first page of a search. Later pages come from the `next` URL the
## result carries, passed back to search().
static func build_search_url(q: String, listing_type: String, free_only: bool, sort: String, formats := PackedStringArray(ALL_FORMATS)) -> String:
	var params := PackedStringArray()
	if formats.size() > 0:
		params.append("asset_formats=" + ",".join(formats))
	if not q.strip_edges().is_empty():
		params.append("q=" + q.strip_edges().uri_encode())
	if not listing_type.is_empty():
		params.append("listing_types=" + listing_type)
	if free_only:
		params.append("is_free=1")
	if not sort.is_empty():
		params.append("sort_by=" + sort)
	return SEARCH_URL + ("?" + "&".join(params) if params.size() > 0 else "")


func search(url: String) -> Dictionary:
	await Http.throttle("search", throttle_ms)
	var response: Dictionary = await _get_json(url, false)
	if response.status == 429:
		Log.verbose("Search rate limited, retrying")
		await Engine.get_main_loop().create_timer(retry_wait_s).timeout
		response = await _get_json(url, false)
	if not response.ok:
		return {"ok": false, "error": response.error, "results": [], "next": "", "count": 0}
	var data = response.json
	if not data is Dictionary:
		return {"ok": false, "error": "unexpected search response", "results": [], "next": "", "count": 0}
	var results: Array = data.get("results", []) if data.get("results") is Array else []
	var next = data.get("next")
	return {"ok": true, "error": "", "results": results, "next": str(next) if next is String else "", "count": results.size()}


func listing(uid: String) -> Dictionary:
	var response: Dictionary = await _get_json(HOST + "/i/listings/" + uid, false)
	return {"ok": response.ok and response.json is Dictionary, "error": response.error, "data": response.json if response.json is Dictionary else {}}


## The files of one asset format of a listing ({uid, name, size, fileType})
## and, for Unreal, its builds ({artifactId, engineVersions, name, uid}).
func listing_format(uid: String, code: String) -> Dictionary:
	var response: Dictionary = await _get_json(HOST + "/i/listings/%s/asset-formats/%s" % [uid, code], false)
	if not response.ok or not response.json is Dictionary:
		return {"ok": false, "error": response.error if response.error else "unexpected response", "files": [], "versions": []}
	var files: Array = response.json.get("files", []) if response.json.get("files") is Array else []
	var versions: Array = response.json.get("versions", []) if response.json.get("versions") is Array else []
	return {"ok": true, "error": "", "files": files, "versions": versions}


## Engine versions ("UE_5.8") offered by builds (library `projectVersions`
## or a format's `versions`), newest first, each once.
static func engine_versions_of(builds: Array) -> Array:
	var seen := {}
	for build in builds:
		if not build is Dictionary:
			continue
		var engines = build.get("engineVersions")
		if engines is Array:
			for engine in engines:
				seen[str(engine)] = true
	var versions := seen.keys()
	versions.sort_custom(func(a, b): return _engine_key(a) > _engine_key(b))
	return versions


## The build whose engineVersions contain [param engine_version], {} if none.
static func build_for_engine(builds: Array, engine_version: String) -> Dictionary:
	for build in builds:
		if build is Dictionary and build.get("engineVersions") is Array and engine_version in build.engineVersions:
			return build
	return {}


static func listing_page_url(uid: String) -> String:
	return LISTING_URL % uid


## Format codes the listing offers, in the listing's order.
static func formats_of(listing: Dictionary) -> Array:
	var codes := []
	for format in listing.get("assetFormats", []):
		if format is Dictionary and format.get("assetFormatType") is Dictionary:
			codes.append(str(format.assetFormatType.get("code", "")))
	return codes


static func has_unreal_format(listing: Dictionary) -> bool:
	return UNREAL_FORMAT in formats_of(listing)


## The format to download: [param preferred] if offered, else glTF, FBX,
## Unreal in that order; "" when the listing offers none of them.
static func choose_format(listing: Dictionary, preferred: String) -> String:
	var offered := formats_of(listing)
	if preferred in offered and preferred in ALL_FORMATS:
		return preferred
	for code in ALL_FORMATS:
		if code in offered:
			return code
	return ""


static func is_free(listing: Dictionary) -> bool:
	if listing.get("isFree") == true:
		return true
	var price = listing.get("startingPrice")
	return price is Dictionary and float(price.get("price", -1)) == 0.0


static func price_label(listing: Dictionary) -> String:
	if listing.is_empty():
		return ""
	if is_free(listing):
		return "Free"
	var price = listing.get("startingPrice")
	if not price is Dictionary or not price.has("price"):
		return ""
	var currency := str(price.get("currencyCode", "")) if price.get("currencyCode") else "$"
	return "%s %.2f" % [currency, float(price.price)]


static func seller_name(listing: Dictionary) -> String:
	var user = listing.get("user")
	if user is Dictionary:
		return str(user.get("sellerName", ""))
	return ""


## URL of the smallest thumbnail at least [param min_width] wide, else the
## largest, else the media URL; "" without thumbnails.
static func thumbnail_url(listing: Dictionary, min_width: int) -> String:
	var thumbs = listing.get("thumbnails")
	if not thumbs is Array or thumbs.is_empty() or not thumbs[0] is Dictionary:
		return ""
	var images = thumbs[0].get("images")
	var best: Dictionary = {}
	if images is Array:
		for image in images:
			if not image is Dictionary or not image.has("url"):
				continue
			var width := int(image.get("width", 0))
			if width >= min_width and (best.is_empty() or width < int(best.width)):
				best = image
		if best.is_empty():
			for image in images:
				if image is Dictionary and image.has("url") and (best.is_empty() or int(image.get("width", 0)) > int(best.get("width", 0))):
					best = image
	if not best.is_empty():
		return str(best.url)
	return str(thumbs[0].get("mediaUrl", ""))


## Local path of the listing's thumbnail, downloaded into [param cache_dir]
## when missing; "" when it can't be fetched.
func thumbnail(listing: Dictionary, cache_dir: String, min_width := 320) -> String:
	var url := thumbnail_url(listing, min_width)
	if url.is_empty():
		return ""
	var width := _width_of(listing, url)
	var ext := url.get_extension().split("?")[0].to_lower()
	if ext.is_empty() or ext.length() > 4:
		ext = "jpg"
	var path := cache_dir.path_join("%s_%d.%s" % [str(listing.get("uid", url.md5_text())), width, ext])
	if FileAccess.file_exists(path):
		return path
	var response: Dictionary = await fetch_bytes(url)
	if not response.ok or response.body.is_empty():
		Log.verbose("Thumbnail failed: %s" % response.error)
		return ""
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(response.body)
	file.close()
	return path


static func _width_of(listing: Dictionary, url: String) -> int:
	var images = listing.thumbnails[0].get("images")
	if images is Array:
		for image in images:
			if image is Dictionary and image.get("url") == url:
				return int(image.get("width", 0))
	return 0


# MARK: library (owned Unreal assets)

## The account's Unreal library, cached for the session.
func library(force := false) -> Dictionary:
	if _library_loaded and not force:
		return {"ok": true, "error": "", "items": _library, "unauthorized": false}
	var token: String = await _token()
	if token.is_empty():
		return {"ok": false, "error": "Log in to see your library", "items": [], "unauthorized": true}
	var items: Array = []
	var url := "%s/e/accounts/%s/ue/library?count=%d" % [HOST, str(auth.account_id).uri_encode(), LIBRARY_PAGE]
	while true:
		var response: Dictionary = await _get_json(url, true)
		if response.status == 401 or response.status == 403:
			return {"ok": false, "error": "Fab rejected the login (%s)" % response.error, "items": [], "unauthorized": true}
		if not response.ok or not response.json is Dictionary:
			return {"ok": false, "error": response.error if response.error else "unexpected library response", "items": [], "unauthorized": false}
		var page: Array = response.json.get("results", []) if response.json.get("results") is Array else []
		items.append_array(page)
		var cursors = response.json.get("cursors")
		var next = cursors.get("next") if cursors is Dictionary else null
		if not next is String or next.is_empty():
			break
		url = "%s/e/accounts/%s/ue/library?cursor=%s&count=%d" % [HOST, str(auth.account_id).uri_encode(), str(next).uri_encode(), LIBRARY_PAGE]
	_library = items
	_library_loaded = true
	Log.info("Library: %d items" % items.size())
	return {"ok": true, "error": "", "items": items, "unauthorized": false}


func clear_library() -> void:
	_library = []
	_library_loaded = false


## The listing uid a library item refers to: from its url, else its assetId.
static func listing_uid_of(item: Dictionary) -> String:
	var url := str(item.get("url", ""))
	var marker := "/listings/"
	if url.contains(marker):
		return url.substr(url.find(marker) + marker.length()).split("?")[0].split("/")[0].split("#")[0]
	return str(item.get("assetId", ""))


static func library_item_for(items: Array, uid: String) -> Dictionary:
	for item in items:
		if item is Dictionary and listing_uid_of(item) == uid:
			return item
	for item in items:
		if item is Dictionary and str(item.get("assetId", "")) == uid:
			return item
	return {}


## The projectVersions entry for [param engine_version] (like "UE_5.8"),
## else the newest; {} when the item has none.
static func pick_project_version(item: Dictionary, engine_version: String) -> Dictionary:
	var versions = item.get("projectVersions")
	if not versions is Array or versions.is_empty():
		return {}
	var newest: Dictionary = {}
	var newest_key := -1.0
	for version in versions:
		if not version is Dictionary:
			continue
		var engines: Array = version.get("engineVersions", []) if version.get("engineVersions") is Array else []
		if engine_version in engines:
			return version
		var key := -1.0
		for engine in engines:
			key = maxf(key, _engine_key(str(engine)))
		if key > newest_key or newest.is_empty():
			newest_key = key
			newest = version
	return newest


static func _engine_key(engine: String) -> float:
	var parts := engine.trim_prefix("UE_").split(".")
	if parts.size() >= 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		return float(parts[0]) * 100.0 + float(parts[1])
	return -1.0


# MARK: downloads

## Signed manifest URLs of an owned Unreal asset build.
func manifest_pointers(item: Dictionary, version: Dictionary) -> Dictionary:
	var token: String = await _token()
	if token.is_empty():
		return _pointers_error("Log in to download", true)
	var body := JSON.stringify({"item_id": str(item.get("assetId", "")), "namespace": str(item.get("assetNamespace", "")), "platform": "Windows"})
	var url := "%s/e/artifacts/%s/manifest" % [HOST, str(version.get("artifactId", "")).uri_encode()]
	var response: Dictionary = await fetch.call({"method": "POST", "url": url, "body": body,
		"headers": PackedStringArray(["Accept: application/json", "Content-Type: application/json", "Authorization: Bearer " + token])})
	return _parse_download_info(response)


## Signed manifest URLs of one file of a non-Unreal format (glTF, FBX…).
func file_download_info(uid: String, code: String, file_uid: String) -> Dictionary:
	var url := "%s/p/egl/listings/%s/asset-formats/%s/files/%s/download-info" % [HOST, uid, code, file_uid]
	var response: Dictionary = await _get_json(url, true)
	return _parse_download_info(response)


func _parse_download_info(response: Dictionary) -> Dictionary:
	if response.status == 403:
		return _pointers_error("Fab rate-limited the download (HTTP 403). Wait a minute and try again.", false)
	if response.status == 401:
		return _pointers_error("Fab rejected the login; log in again", true)
	if not response.ok or not response.json is Dictionary:
		return _pointers_error(response.error if response.error else "unexpected download response", false)
	var infos = response.json.get("downloadInfo", response.json.get("download_info"))
	if not infos is Array or infos.is_empty() or not infos[0] is Dictionary:
		return _pointers_error("Fab returned no download information", false)
	var info: Dictionary = infos[0]
	var sources := pair_sources(info)
	if sources.is_empty():
		return _pointers_error("Fab returned no usable download location", false)
	return {"ok": true, "error": "", "unauthorized": false, "build_version": str(info.get("buildVersion", info.get("build_version", ""))), "sources": sources}


static func _pointers_error(message: String, unauthorized: bool) -> Dictionary:
	return {"ok": false, "error": message, "unauthorized": unauthorized, "build_version": "", "sources": []}


## Each CDN base URL paired with the signed manifest URL on the same CDN.
static func pair_sources(info: Dictionary) -> Array:
	var manifest_urls := []
	for point in info.get("distributionPoints", info.get("distribution_points", [])):
		if point is Dictionary:
			manifest_urls.append(str(point.get("manifestUrl", point.get("manifest_url", ""))))
	var sources := []
	for base in info.get("distributionPointBaseUrls", info.get("distribution_point_base_urls", [])):
		var base_url := str(base)
		for manifest_url in manifest_urls:
			if manifest_url.begins_with(base_url):
				sources.append({"manifest_url": manifest_url, "base_url": base_url.rstrip("/")})
				break
	return sources


## Plain GET of bytes (manifests, chunks, thumbnails).
func fetch_bytes(url: String, timeout := 120.0) -> Dictionary:
	return await fetch.call({"method": "GET", "url": url, "headers": PackedStringArray(), "timeout": timeout})


# MARK: library actions

## Tries to add a free listing to the account's library. Fab's /i/ endpoints
## want the website's session cookie, which the launcher bearer can't
## provide (the SSO exchange sits behind a bot check), so this usually
## answers 401 and needs_web is true: the user adds it on fab.com instead.
func add_to_library(uid: String) -> Dictionary:
	var token: String = await _token()
	if token.is_empty():
		return {"ok": false, "error": "Log in first", "needs_web": false, "unauthorized": true}
	var csrf_response: Dictionary = await fetch.call({"method": "GET", "url": HOST + "/i/csrf",
		"headers": PackedStringArray(["Accept: application/json", "Authorization: Bearer " + token])})
	var csrf := Http.cookie_value(csrf_response.headers, "fab_csrftoken")
	if csrf.is_empty():
		return {"ok": false, "error": "Could not get Fab's CSRF token (%s)" % (csrf_response.error if csrf_response.error else "no cookie"), "needs_web": true, "unauthorized": false}
	var response: Dictionary = await fetch.call({"method": "POST", "url": HOST + "/i/listings/%s/add-to-library" % uid, "body": "",
		"headers": PackedStringArray(["Accept: application/json", "Authorization: Bearer " + token, "X-CSRFToken: " + csrf,
			"Cookie: fab_csrftoken=" + csrf, "Referer: " + listing_page_url(uid), "Origin: " + HOST])})
	if response.ok:
		clear_library()
		return {"ok": true, "error": "", "needs_web": false, "unauthorized": false}
	if response.status == 401 or response.status == 403:
		return {"ok": false, "error": NEEDS_WEB_MESSAGE, "needs_web": true, "unauthorized": false}
	return {"ok": false, "error": response.error, "needs_web": true, "unauthorized": false}


# MARK: helpers

func _token() -> String:
	if auth == null or not auth.is_logged_in():
		return ""
	return await auth.ensure_token()


func _get_json(url: String, with_bearer: bool) -> Dictionary:
	var headers := PackedStringArray(["Accept: application/json"])
	if with_bearer:
		var token: String = await _token()
		if token.is_empty():
			return {"ok": false, "status": 401, "body": PackedByteArray(), "json": null, "headers": PackedStringArray(), "error": "not logged in"}
		headers.append("Authorization: Bearer " + token)
	return await fetch.call({"method": "GET", "url": url, "headers": headers})
