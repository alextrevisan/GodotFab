@tool
extends RefCounted
## Logging with a level, prefixed "GodotFab: ".

enum Level { ERROR, WARNING, INFO, VERBOSE, DEBUG }

static var level: int = Level.INFO


static func _log(lvl: int, msg: String) -> void:
	if lvl > level:
		return
	var prefix := "GodotFab: " if lvl == Level.INFO else "GodotFab %s: " % Level.keys()[lvl]
	match lvl:
		Level.ERROR:
			push_error(prefix + msg)
		Level.WARNING:
			push_warning(prefix + msg)
		_:
			print(prefix + msg)


static func error(msg: String) -> void: _log(Level.ERROR, msg)
static func warning(msg: String) -> void: _log(Level.WARNING, msg)
static func info(msg: String) -> void: _log(Level.INFO, msg)
static func verbose(msg: String) -> void: _log(Level.VERBOSE, msg)
static func debug(msg: String) -> void: _log(Level.DEBUG, msg)
