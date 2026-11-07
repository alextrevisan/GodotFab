@tool
extends RefCounted
## Thumbnail textures for the cards: downloaded through the API into the
## cache folder, decoded a few per frame, kept in a small memory cache.

const Log = preload("res://addons/godotfab/log.gd")

const MEMORY_CACHE := 300
const PER_FRAME := 6

var api
var cache_dir: String
var _textures: Dictionary = {}
var _order: Array = []
var _queue: Array = []
var _pumping := false


func _init(new_api, new_cache_dir: String) -> void:
	api = new_api
	cache_dir = new_cache_dir


## Calls [param on_ready](texture or null) once the listing's thumbnail is
## decoded; from memory right away when cached.
func request(listing: Dictionary, on_ready: Callable) -> void:
	var key := str(listing.get("uid", ""))
	if _textures.has(key):
		on_ready.call(_textures[key])
		return
	_queue.append([listing, on_ready])
	if not _pumping:
		_pump()


func _pump() -> void:
	_pumping = true
	var tree := Engine.get_main_loop() as SceneTree
	while not _queue.is_empty():
		var batch: Array = _queue.slice(0, PER_FRAME)
		_queue = _queue.slice(PER_FRAME)
		# A shared counter: a lambda captures ints by value.
		var pending := [batch.size()]
		for entry in batch:
			_load_one(entry[0], entry[1], func(): pending[0] -= 1)
		while pending[0] > 0:
			await tree.process_frame
	_pumping = false


func _load_one(listing: Dictionary, on_ready: Callable, done: Callable) -> void:
	var key := str(listing.get("uid", ""))
	var texture: Texture2D = null
	if _textures.has(key):
		texture = _textures[key]
	else:
		var path: String = await api.thumbnail(listing, cache_dir)
		if not path.is_empty():
			var image := Image.load_from_file(path)
			if image != null:
				texture = ImageTexture.create_from_image(image)
		_store(key, texture)
	if on_ready.is_valid():
		on_ready.call(texture)
	done.call()


func _store(key: String, texture: Texture2D) -> void:
	_textures[key] = texture
	_order.append(key)
	while _order.size() > MEMORY_CACHE:
		_textures.erase(_order.pop_front())
