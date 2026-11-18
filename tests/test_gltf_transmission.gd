extends "res://tests/test_case.gd"

const GltfTransmission = preload("res://addons/godotfab/gltf_transmission.gd")


static func _glass(factor: Variant) -> Dictionary:
	var extension := {} if factor == null else {"transmissionFactor": factor}
	return {"extensions": {"KHR_materials_transmission": extension}}


func test_transmission_of() -> void:
	assert_eq(GltfTransmission.transmission_of(_glass(0.5)), 0.5, "factor")
	assert_eq(GltfTransmission.transmission_of(_glass(null)), 0.0, "the factor defaults to 0")
	assert_eq(GltfTransmission.transmission_of({"name": "Wood"}), 0.0, "no extension")
	assert_eq(GltfTransmission.transmission_of({"extensions": {"KHR_materials_ior": {"ior": 1.3}}}), 0.0, "another extension")


func test_apply_lets_through_what_the_base_color_does() -> void:
	var clear := StandardMaterial3D.new()
	clear.albedo_color = Color(1, 1, 1)
	GltfTransmission.apply(clear, 1.0)
	assert_eq(clear.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "clear glass blends")
	assert_true(absf(clear.albedo_color.a - GltfTransmission.MIN_ALPHA) < 0.01, "clear glass keeps a minimum of surface: alpha %f" % clear.albedo_color.a)
	var half := StandardMaterial3D.new()
	half.albedo_color = Color(1, 1, 1)
	GltfTransmission.apply(half, 0.5)
	assert_true(absf(half.albedo_color.a - 0.5) < 0.01, "half transmission: alpha %f" % half.albedo_color.a)
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(1, 0, 0)
	GltfTransmission.apply(red, 1.0)
	assert_true(absf(red.albedo_color.a - 2.0 / 3.0) < 0.01, "red glass: alpha %f" % red.albedo_color.a)
	assert_eq(Color(red.albedo_color, 1.0), Color(1, 0, 0), "the color is kept")


func test_apply_leaves_black_glass_opaque() -> void:
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0, 0, 0)
	GltfTransmission.apply(black, 1.0)
	assert_eq(black.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED, "nothing gets through black")
	assert_eq(black.albedo_color.a, 1.0, "alpha")


func test_import_makes_transmissive_materials_see_through() -> void:
	var glass := _glass(1.0)
	glass["name"] = "Glass"
	glass["pbrMetallicRoughness"] = {"baseColorFactor": [0.8, 0.8, 0.8, 1.0]}
	var wood := {"name": "Wood", "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.6, 0.4, 1.0]}}
	var path := tmp_dir().path_join("glass.gltf")
	write_file(path, JSON.stringify({"asset": {"version": "2.0"}, "extensionsUsed": ["KHR_materials_transmission"], "materials": [glass, wood]}))
	var extension := GltfTransmission.new()
	GLTFDocument.register_gltf_document_extension(extension)
	var state := GLTFState.new()
	var err := GLTFDocument.new().append_from_file(path, state)
	GLTFDocument.unregister_gltf_document_extension(extension)
	assert_eq(err, OK, "the glTF loads")
	var materials := state.get_materials()
	assert_eq(materials.size(), 2, "materials")
	if materials.size() != 2:
		return
	var imported_glass: BaseMaterial3D = materials[0]
	assert_eq(imported_glass.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "glass blends")
	assert_true(absf(imported_glass.albedo_color.a - 0.2) < 0.01, "glass alpha %f" % imported_glass.albedo_color.a)
	var imported_wood: BaseMaterial3D = materials[1]
	assert_eq(imported_wood.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED, "wood stays opaque")
	assert_eq(imported_wood.albedo_color.a, 1.0, "wood alpha")
