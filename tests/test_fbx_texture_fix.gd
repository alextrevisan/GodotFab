extends "res://tests/test_case.gd"

const FbxRefs = preload("res://addons/godotfab/fbx_refs.gd")
const FbxTextureFix = preload("res://addons/godotfab/fbx_texture_fix.gd")
## An imported texture of the project, standing in for pack textures.
const PROJECT_TEXTURE := "res://addons/godotfab/logo/godotfab-icon.svg"


# MARK: minimal binary FBX writer (version 7400, 32-bit node headers)

static func _prop(value: Variant) -> PackedByteArray:
	var out := PackedByteArray()
	if value is String:
		# "##" stands for the "\x00\x01" of FBX names (a String can't hold a NUL).
		var data := PackedByteArray()
		for part in value.split("##"):
			if not data.is_empty() or value.begins_with("##"):
				data.append_array(PackedByteArray([0, 1]))
			data.append_array(part.to_utf8_buffer())
		out.append("S".unicode_at(0))
		out.resize(5)
		out.encode_u32(1, data.size())
		out.append_array(data)
	elif value is int:
		out.append("L".unicode_at(0))
		out.resize(9)
		out.encode_s64(1, value)
	elif value is PackedFloat64Array:
		# An array property, to check the reader skips it.
		var data := PackedByteArray()
		data.resize(value.size() * 8)
		for i in value.size():
			data.encode_double(i * 8, value[i])
		out.append("d".unicode_at(0))
		out.resize(13)
		out.encode_u32(1, value.size())
		out.encode_u32(5, 0)
		out.encode_u32(9, data.size())
		out.append_array(data)
	return out


static func _node(offset: int, name: String, props: Array, children: Array = []) -> PackedByteArray:
	var prop_bytes := PackedByteArray()
	for p in props:
		prop_bytes.append_array(_prop(p))
	var header_len := 13 + name.length()
	var body := PackedByteArray()
	var child_offset := offset + header_len + prop_bytes.size()
	for c in children:
		var bytes: PackedByteArray = c.call(child_offset)
		body.append_array(bytes)
		child_offset += bytes.size()
	if not children.is_empty():
		body.resize(body.size() + 13)
	var out := PackedByteArray()
	out.resize(13)
	out.encode_u32(0, offset + header_len + prop_bytes.size() + body.size())
	out.encode_u32(4, props.size())
	out.encode_u32(8, prop_bytes.size())
	out[12] = name.length()
	out.append_array(name.to_ascii_buffer())
	out.append_array(prop_bytes)
	out.append_array(body)
	return out


static func _n(name: String, props: Array, children: Array = []) -> Callable:
	return func(offset: int) -> PackedByteArray: return _node(offset, name, props, children)


## {material name: [[texture id, property, relative, file]]}
static func make_fbx(materials: Dictionary) -> PackedByteArray:
	var objects: Array = [_n("Geometry", [1, "Geo##Geometry", "Mesh"], [_n("Vertices", [PackedFloat64Array([0.0, 1.0, 2.0])])])]
	var connections: Array = []
	var id := 100
	for material in materials:
		var material_id := id
		id += 1
		objects.append(_n("Material", [material_id, material + "##Material", ""]))
		for tex in materials[material]:
			var tex_id := id
			id += 1
			objects.append(_n("Texture", [tex_id, "Tex##Texture", ""], [_n("FileName", [tex[2]]), _n("RelativeFilename", [tex[1]])]))
			connections.append(_n("C", ["OP", tex_id, material_id, tex[0]]))
	var out := ("Kaydara FBX Binary  ").to_ascii_buffer()
	out.append_array(PackedByteArray([0, 0x1A, 0]))
	out.resize(27)
	out.encode_u32(23, 7400)
	var top: Array = [_n("FBXHeaderExtension", [], [_n("FBXVersion", [7400])]), _n("Objects", [], objects), _n("Connections", [], connections)]
	for node in top:
		out.append_array(node.call(out.size()))
	out.resize(out.size() + 13)
	return out


# MARK: tests

func test_refs_read_material_textures() -> void:
	var bytes := make_fbx({"Jacket1": [["DiffuseColor", "Textures\\Jacket_BaseColor.jpg", "G:\\x\\Jacket_BaseColor.jpg"]],
		"Body:Eye": [["DiffuseColor", "G:\\kit\\darkBrownEye_albedo.png", "G:\\kit\\darkBrownEye_albedo.png"]]})
	var refs := FbxRefs.parse_bytes(bytes)
	assert_true(refs.ok, refs.error)
	assert_eq(refs.materials.keys(), ["Jacket1", "Body:Eye"])
	assert_eq(refs.materials["Jacket1"][0], {"property": "DiffuseColor", "relative": "Textures/Jacket_BaseColor.jpg", "file": "G:/x/Jacket_BaseColor.jpg"})


func test_refs_reject_non_binary() -> void:
	assert_false(FbxRefs.parse_bytes("; FBX 7.4.0 project file".to_utf8_buffer()).ok)


func test_slot_of() -> void:
	assert_eq(FbxTextureFix.slot_of("DiffuseColor", ""), "albedo")
	assert_eq(FbxTextureFix.slot_of("NormalMap", ""), "normal")
	assert_eq(FbxTextureFix.slot_of("TransparencyFactor", ""), "opacity")
	assert_eq(FbxTextureFix.slot_of("ReflectionFactor", "Body_OcclusionRoughnessMetallic.png"), "orm")
	assert_eq(FbxTextureFix.slot_of("ReflectionFactor", "Body_Metal.png"), "")


func _pack() -> String:
	var root := tmp_dir()
	write_file(root.path_join(".godotfab.json"), "{}")
	for tile in ["1001", "1002", "1004"]:
		write_file(root.path_join("Textures/Body/Body_BaseColor.%s.png" % tile), "png")
		write_file(root.path_join("Textures/Body/Body_Normal.%s.png" % tile), "png")
	write_file(root.path_join("Textures/Body/Body_Cavity_1001.png"), "png")
	write_file(root.path_join("Textures/Jacket/Jacket_BaseColor.jpg"), "jpg")
	write_file(root.path_join("Textures/Jacket/Jacket_OcclusionRoughnessMetallic.jpg"), "jpg")
	write_file(root.path_join("Textures/Eye/Eye_BaseColor.png"), "png")
	write_file(root.path_join("Textures/Eye/Eye_SpecularColourBrown.png"), "png")
	write_file(root.path_join("Textures/Eyebrow_EyeLeashes/Eyebrows_BaseColor.jpg"), "jpg")
	write_file(root.path_join("Textures/Moved/Shoes_Normal.jpg"), "jpg")
	return root


func test_plan_udim_missing_and_resolved() -> void:
	var root := _pack()
	var fbx := root.path_join("model.fbx")
	var materials := {
		"Head": [{"property": "DiffuseColor", "relative": "Textures/Body/Body_BaseColor.<UDIM>.png", "file": "G:/a/Body_BaseColor.<UDIM>.png"},
			{"property": "NormalMap", "relative": "Textures/Body/Body_Normal.<UDIM>.png", "file": ""}],
		"Jacket1": [{"property": "DiffuseColor", "relative": "Textures/Jacket/Jacket_BaseColor.jpg", "file": ""},
			{"property": "ShininessExponent", "relative": "Textures/Jacket/Jacket_OcclusionRoughnessMetallic.jpg", "file": ""}],
		"Body_Arkit:Eye": [{"property": "DiffuseColor", "relative": "G:/kit/darkBrownEye_light_albedo_4k.png", "file": "G:/kit/darkBrownEye_light_albedo_4k.png"}],
		"Shoes1": [{"property": "NormalMap", "relative": "Textures/Shoes/Shoes_Normal.jpg", "file": ""}],
		"Cape": [{"property": "DiffuseColor", "relative": "Textures/Cape/Cape_BaseColor.jpg", "file": ""}],
	}
	var fixes := FbxTextureFix.plan_from_refs(fbx, materials)
	assert_eq(fixes["Head"]["albedo"], {"udim": {0: root.path_join("Textures/Body/Body_BaseColor.1001.png"), 1: root.path_join("Textures/Body/Body_BaseColor.1002.png"), 3: root.path_join("Textures/Body/Body_BaseColor.1004.png")}})
	assert_eq(fixes["Head"]["normal"].udim.size(), 3)
	assert_eq(fixes["Jacket1"], {"orm": {"file": root.path_join("Textures/Jacket/Jacket_OcclusionRoughnessMetallic.jpg")}},
		"Godot finds the base color itself, but never applies an ORM map")
	assert_eq(fixes["Body_Arkit:Eye"], {"albedo": {"file": root.path_join("Textures/Eye/Eye_BaseColor.png")}})
	assert_eq(fixes["Shoes1"], {"normal": {"file": root.path_join("Textures/Moved/Shoes_Normal.jpg")}}, "same file name elsewhere in the pack")
	assert_false(fixes.has("Cape"), "no texture qualifies")


func test_plan_opacity_material_takes_every_texture() -> void:
	var root := _pack()
	write_file(root.path_join("Textures/Hair/Hair_Diffuse.jpg"), "jpg")
	write_file(root.path_join("Textures/Hair/Hair_Alpha.jpg"), "jpg")
	var materials := {"Hair3": [{"property": "DiffuseColor", "relative": "Textures/Hair/Hair_Diffuse.jpg", "file": ""},
		{"property": "TransparencyFactor", "relative": "Textures/Hair/Hair_Alpha.jpg", "file": ""}]}
	var fixes := FbxTextureFix.plan_from_refs(root.path_join("model.fbx"), materials)
	assert_eq(fixes["Hair3"], {"albedo": {"file": root.path_join("Textures/Hair/Hair_Diffuse.jpg")},
		"opacity": {"file": root.path_join("Textures/Hair/Hair_Alpha.jpg")}}, "Godot finds both, but the shader needs both")


func test_opacity_shader_code() -> void:
	var tex := load(PROJECT_TEXTURE)
	var code := FbxTextureFix.udim_shader_code({"albedo": {-1: tex}, "opacity": {-1: tex}})
	assert_contains(code, "render_mode cull_disabled;")
	assert_contains(code, "ALPHA = opacity_s.r;")
	assert_contains(code, "ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;")
	var shader := Shader.new()
	shader.code = code
	assert_eq(shader.get_shader_uniform_list().size(), 4, "the code parses: color, threshold + 2 samplers")


func test_apply_opacity_makes_shader() -> void:
	var texture_path := ProjectSettings.globalize_path(PROJECT_TEXTURE)
	var hair := StandardMaterial3D.new()
	hair.resource_name = "Hair3"
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, hair)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	assert_eq(FbxTextureFix.apply(instance, {"Hair3": {"albedo": {"file": texture_path}, "opacity": {"file": texture_path}}}), 1)
	var fixed = mesh.surface_get_material(0)
	assert_true(fixed is ShaderMaterial)
	assert_not_null(fixed.get_shader_parameter("opacity_tex"))
	assert_not_null(fixed.get_shader_parameter("albedo_tex"))
	instance.free()


func test_find_candidate_needs_slot_keyword_and_a_name_match() -> void:
	var textures: Array[String] = ["/p/Eye/Eye_SpecularColourBrown.png", "/p/Rock/Rock_BaseColor.png"]
	assert_eq(FbxTextureFix.find_candidate(textures, "Eye", "albedo", "darkBrownEye_albedo.png"), "")


func test_udim_shader_code() -> void:
	var tex := load(PROJECT_TEXTURE)
	var code := FbxTextureFix.udim_shader_code({"albedo": {0: tex, 1: tex}, "orm": {-1: tex}})
	assert_contains(code, "uniform sampler2D albedo_1001 : source_color")
	assert_contains(code, "uniform sampler2D albedo_1002")
	assert_contains(code, "int tile = int(floor(UV.x)) + 10 * int(floor(1.0 - UV.y));")
	assert_contains(code, "if (tile == 0) { albedo_s = textureGrad(albedo_1001, UV, uv_dx, uv_dy); }")
	assert_contains(code, "else if (tile == 1) { albedo_s = textureGrad(albedo_1002")
	assert_contains(code, "orm_s = texture(orm_tex, UV);")
	assert_contains(code, "ROUGHNESS = orm_s.g;")
	var shader := Shader.new()
	shader.code = code
	assert_eq(shader.get_shader_uniform_list().size(), 4, "the code parses: albedo_color + 3 samplers")


func test_apply_sets_udim_shader_and_missing_texture() -> void:
	var texture_path := ProjectSettings.globalize_path(PROJECT_TEXTURE)
	var head := StandardMaterial3D.new()
	head.resource_name = "Head"
	head.albedo_color = Color(0.5, 0.5, 0.5)
	var eye := StandardMaterial3D.new()
	eye.resource_name = "Body_Arkit:Eye"
	var jacket := StandardMaterial3D.new()
	jacket.resource_name = "Jacket1"
	var mesh := ArrayMesh.new()
	for material in [head, eye, jacket, head]:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var root := Node3D.new()
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	root.add_child(instance)
	var fixes := {"Head": {"albedo": {"udim": {0: texture_path, 1: texture_path}}}, "Eye": {"albedo": {"file": texture_path}}}
	assert_eq(FbxTextureFix.apply(root, fixes), 2)
	var fixed_head := mesh.surface_get_material(0)
	assert_true(fixed_head is ShaderMaterial)
	assert_eq(fixed_head.resource_name, "Head")
	assert_eq(fixed_head.get_shader_parameter("albedo_color"), Color(0.5, 0.5, 0.5))
	assert_not_null(fixed_head.get_shader_parameter("albedo_1002"))
	assert_true(mesh.surface_get_material(3) == fixed_head, "shared material fixed once")
	var fixed_eye: StandardMaterial3D = mesh.surface_get_material(1)
	assert_not_null(fixed_eye.albedo_texture, "namespace-stripped name matches")
	assert_true(mesh.surface_get_material(2) == jacket, "untouched")
	root.free()


func test_flip_shader_code() -> void:
	var tex := load(PROJECT_TEXTURE)
	var code := FbxTextureFix.udim_shader_code({"normal": {-1: tex}}, true)
	assert_contains(code, "NORMAL_MAP = vec3(normal_s.r, 1.0 - normal_s.g, normal_s.b);")
	assert_contains(code, "NORMAL_MAP_DEPTH = normal_strength;")
	assert_false(FbxTextureFix.udim_shader_code({"normal": {-1: tex}}).contains("1.0 - normal_s.g"))
	var shader := Shader.new()
	shader.code = code
	assert_eq(shader.get_shader_uniform_list().size(), 3, "the code parses: color, strength + 1 sampler")


func _material_mesh(material: Material) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	return instance


func test_apply_flip_keeps_existing_textures() -> void:
	var tex := load(PROJECT_TEXTURE)
	var skin := StandardMaterial3D.new()
	skin.resource_name = "Skin"
	skin.albedo_texture = tex
	skin.normal_enabled = true
	skin.normal_texture = tex
	skin.normal_scale = 0.5
	FbxTextureFix._set_orm(skin, tex)
	var instance := _material_mesh(skin)
	assert_eq(FbxTextureFix.apply(instance, {}, {"Skin": {"normal_flip_y": true}}), 1)
	var fixed = instance.mesh.surface_get_material(0)
	assert_true(fixed is ShaderMaterial)
	assert_contains(fixed.shader.code, "1.0 - normal_s.g")
	assert_eq(fixed.get_shader_parameter("normal_strength"), 0.5)
	assert_not_null(fixed.get_shader_parameter("albedo_tex"))
	assert_not_null(fixed.get_shader_parameter("orm_tex"))
	instance.free()


func test_apply_flip_leaves_separate_roughness_map() -> void:
	var tex := load(PROJECT_TEXTURE)
	var cloth := StandardMaterial3D.new()
	cloth.resource_name = "Cloth"
	cloth.normal_enabled = true
	cloth.normal_texture = tex
	cloth.roughness_texture = tex
	var instance := _material_mesh(cloth)
	assert_eq(FbxTextureFix.apply(instance, {}, {"Cloth": {"normal_flip_y": true}}), 0)
	assert_true(instance.mesh.surface_get_material(0) == cloth)
	instance.free()


func test_prepare_materials_restores_zero_strength_and_scales() -> void:
	var tex := load(PROJECT_TEXTURE)
	var jacket := StandardMaterial3D.new()
	jacket.resource_name = "Jacket1"
	jacket.normal_enabled = true
	jacket.normal_texture = tex
	jacket.normal_scale = 0.0
	var instance := _material_mesh(jacket)
	assert_eq(FbxTextureFix.prepare_materials(instance, {}, false), 0, "only FBX imports read 0")
	assert_eq(jacket.normal_scale, 0.0)
	assert_eq(FbxTextureFix.prepare_materials(instance, {"Jacket1": {"normal_strength": 0.5}}, true), 1)
	assert_eq(jacket.normal_scale, 0.5)
	instance.free()


func test_material_options_read_from_import_file() -> void:
	const FbxPostImport = preload("res://addons/godotfab/fbx_post_import.gd")
	var source := tmp_dir().path_join("model.fbx")
	write_file(source + ".import", "[params]\n\n_subresources={\n\"materials\": {\n\"Head\": {\n\"godotfab/normal_flip_y\": true,\n\"godotfab/normal_strength\": 0.7,\n\"use_external/enabled\": false\n},\n\"Cloth\": {\n\"use_external/enabled\": false\n}\n}\n}\n")
	assert_eq(FbxPostImport.material_options(source), {"Head": {"normal_strength": 0.7, "normal_flip_y": true}})
	assert_eq(FbxPostImport.material_options(source + "x"), {})


func test_plan_adds_sibling_maps_of_the_base_color() -> void:
	var root := _pack()
	for tile in ["1001", "1002", "1004"]:
		write_file(root.path_join("Textures/Body/Body_SSS.%s.png" % tile), "png")
	write_file(root.path_join("Textures/Jacket/jacket_specular.jpg"), "jpg")
	var materials := {
		"Head": [{"property": "DiffuseColor", "relative": "Textures/Body/Body_BaseColor.<UDIM>.png", "file": ""}],
		"Jacket1": [{"property": "DiffuseColor", "relative": "Textures/Jacket/Jacket_BaseColor.jpg", "file": ""}],
		"Eye": [{"property": "DiffuseColor", "relative": "Textures/Eye/Eye_BaseColor.png", "file": ""}],
	}
	var fixes := FbxTextureFix.plan_from_refs(root.path_join("model.fbx"), materials)
	assert_eq(fixes["Head"]["sss"].udim.size(), 3)
	assert_eq(fixes["Head"]["sss"].udim[1], root.path_join("Textures/Body/Body_SSS.1002.png"))
	assert_false(fixes["Head"].has("specular"))
	assert_eq(fixes["Jacket1"], {"specular": {"file": root.path_join("Textures/Jacket/jacket_specular.jpg")}}, "case-insensitive")
	assert_false(fixes.has("Eye"), "Eye_SpecularColourBrown is not a sibling")


func test_sss_specular_shader_code() -> void:
	var tex := load(PROJECT_TEXTURE)
	var code := FbxTextureFix.udim_shader_code({"albedo": {-1: tex}, "sss": {0: tex, 1: tex}, "specular": {-1: tex}})
	assert_contains(code, "SSS_STRENGTH = sss_s.r * sss_strength;")
	assert_contains(code, "SPECULAR = specular_s.r;")
	assert_contains(code, "uniform sampler2D sss_1002")
	var shader := Shader.new()
	shader.code = code
	assert_eq(shader.get_shader_uniform_list().size(), 6, "the code parses: color, sss strength + 4 samplers")


func test_plan_clears_references_that_are_not_images() -> void:
	var root := _pack()
	var materials := {"Wall": [{"property": "DiffuseColor", "relative": "FBX BLENDER.fbm", "file": "C:/Export/FBX BLENDER.fbm"},
		{"property": "NormalMap", "relative": "FBX BLENDER.fbm", "file": ""}]}
	var fixes := FbxTextureFix.plan_from_refs(root.path_join("model.fbx"), materials)
	assert_eq(fixes["Wall"], {"albedo": {"clear": "FBX BLENDER.fbm"}, "normal": {"clear": "FBX BLENDER.fbm"}})


func test_apply_clears_wrong_embedded_texture() -> void:
	var tex := load(PROJECT_TEXTURE)
	var wall := StandardMaterial3D.new()
	wall.resource_name = "Wall"
	wall.albedo_color = Color(0.4, 0.3, 0.2)
	wall.albedo_texture = tex
	wall.normal_enabled = true
	wall.normal_texture = tex
	var instance := _material_mesh(wall)
	assert_eq(FbxTextureFix.apply(instance, {"Wall": {"albedo": {"clear": "x.fbm"}, "normal": {"clear": "x.fbm"}}}), 1)
	var fixed: StandardMaterial3D = instance.mesh.surface_get_material(0)
	assert_null(fixed.albedo_texture)
	assert_null(fixed.normal_texture)
	assert_false(fixed.normal_enabled)
	assert_eq(fixed.albedo_color, Color(0.4, 0.3, 0.2), "the base color stays")
	instance.free()
