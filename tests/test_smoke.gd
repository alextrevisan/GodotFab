extends "res://tests/test_case.gd"

const Settings = preload("res://addons/godotfab/settings.gd")


func test_settings_defaults() -> void:
	assert_eq(Settings.KEYS[Settings.DOWNLOAD_DIR].default, "res://fab_assets")
	assert_eq(Settings.engine_version(), "UE_5.8")
	assert_eq(Settings.preferred_format(), "gltf")


func test_async_tests_are_awaited() -> void:
	await Engine.get_main_loop().process_frame
	assert_true(true)
