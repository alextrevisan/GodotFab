extends "res://tests/test_case.gd"

const Fixes = preload("res://addons/godotfab/export_fixes.gd")

const SHADER := """[gd_resource type="VisualShader" load_steps=5 format=3 uid="uid://bbocd70t8doda"]

[sub_resource type="VisualShaderNodeBooleanParameter" id="VisualShaderNodeBooleanParameter_a"]
parameter_name = "Emissive_"

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_frag"]
parameter_name = "Emissive"
color_default = 1

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_vert"]
parameter_name = "Emissive"
color_default = 1

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_only"]
parameter_name = "Opacity_Map_VS"

[resource]
code = "x"
nodes/vertex/2/node = SubResource("VisualShaderNodeTexture2DParameter_vert")
nodes/vertex/3/node = SubResource("VisualShaderNodeTexture2DParameter_only")
nodes/fragment/2/node = SubResource("VisualShaderNodeTexture2DParameter_frag")
nodes/fragment/3/node = SubResource("VisualShaderNodeBooleanParameter_a")
"""

const MATERIAL := """[gd_resource type = "ShaderMaterial" load_steps=3 format=3 uid="uid://bcteak5hdinhm"]

[ext_resource type="Shader" uid="uid://bbocd70t8doda" path="res://fab_assets/p/Shaders/MI_Bed_01a.tres" id="5_b8a3r"]
[ext_resource type="Texture2D" uid="uid://dn56twg38y10p" path="res://fab_assets/p/T.png" id="1_nckw5"]

[resource]
shader = ExtResource("5_b8a3r")
shader_parameter/Emissive_ = false
shader_parameter/Emissive = ExtResource("1_nckw5")
shader_parameter/Emissive__VS = false
"""


func test_fix_visual_shader_renames_vertex_duplicate() -> void:
	var result := Fixes.fix_visual_shader_text(SHADER)
	assert_eq(result.renamed, ["Emissive"])
	var text: String = result.text
	assert_contains(text, "id=\"VisualShaderNodeTexture2DParameter_vert\"]\nparameter_name = \"Emissive_VS\"")
	assert_contains(text, "id=\"VisualShaderNodeTexture2DParameter_frag\"]\nparameter_name = \"Emissive\"\n")
	assert_eq(text.count("parameter_name = \"Emissive\""), 1)
	assert_eq(text.count("parameter_name = \"Opacity_Map_VS\""), 1, "unique names untouched")
	assert_eq(Fixes.fix_visual_shader_text(text).renamed, [], "idempotent")


func test_fix_material_duplicates_texture_value() -> void:
	assert_eq(Fixes.material_shader_file(MATERIAL), "MI_Bed_01a.tres")
	var fixed := Fixes.fix_material_text(MATERIAL, ["Emissive"])
	assert_contains(fixed, "shader_parameter/Emissive = ExtResource(\"1_nckw5\")\nshader_parameter/Emissive_VS = ExtResource(\"1_nckw5\")")
	assert_eq(fixed.count("shader_parameter/Emissive__VS"), 1, "the bool's _VS line is not touched")
	assert_eq(Fixes.fix_material_text(fixed, ["Emissive"]), fixed, "idempotent")


func test_fix_export_tree_end_to_end() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Shaders/MI_Bed_01a.tres"), SHADER)
	write_file(root.path_join("Pack/Materials/MI_Bed_01a.tres"), MATERIAL)
	write_file(root.path_join("Pack/Materials/Other.tres"), MATERIAL.replace("MI_Bed_01a.tres", "Other_shader.tres"))
	var result := Fixes.fix_export_tree(root)
	assert_eq(result, {"shaders_fixed": 1, "materials_fixed": 1, "prefabs_fixed": 0, "scenes_fixed": 0})
	assert_contains(FileAccess.get_file_as_string(root.path_join("Pack/Materials/MI_Bed_01a.tres")), "Emissive_VS")
	assert_false(FileAccess.get_file_as_string(root.path_join("Pack/Materials/Other.tres")).contains("Emissive_VS"))
	assert_eq(Fixes.fix_export_tree(root), {"shaders_fixed": 0, "materials_fixed": 0, "prefabs_fixed": 0, "scenes_fixed": 0}, "second pass changes nothing")


const PREFAB := """[gd_scene load_steps=4 format=3 uid="uid://b1"]

[ext_resource type="PackedScene" uid="uid://b2" path="res://fab_assets/p/Pack/Meshes/SM_Bed_01a.glb" id="1_bn82r"]

[sub_resource type="ConcavePolygonShape3D" id="0_c6n0r"]
data = PackedVector3Array(0.6, 0.8, 0.9, 1.0, 0.5, 0.9, -1.0, 0.1, 0.9)

[sub_resource type="BoxShape3D" id="0_box"]
size = Vector3(1, 1, 1)

[node name = "SM_Bed_01a" instance = ExtResource("1_bn82r")]

[node name="Mesh" parent="." index="0"]

[node name="StaticBody" type="StaticBody3D" parent="." ]

[node name="SM_Bed_01a" type="CollisionShape3D" parent="StaticBody" ]
transform = Transform3D(-1.000000, 0.000000, 0.000004, 0.000000, 1.000000, -0.000000, -0.000004, -0.000000, -1.000000, 10.610139, -0.000001, -3.016006)
shape = SubResource("0_c6n0r")
debug_fill = false

[node name="Box0" type="CollisionShape3D" parent="StaticBody" ]
transform = Transform3D(1.000000, 0.000000, 0.000000, 0.000000, 0.000000, -1.000000, 0.000000, 1.000000, 0.000000, 0.000000, 0.500000, 0.000000)
shape = SubResource("0_box")
debug_fill = false
"""


func test_fix_prefab_collision_resets_mesh_shape_only() -> void:
	var fixed := Fixes.fix_prefab_collision_text(PREFAB)
	assert_false(fixed.contains("10.610139"), "instance transform removed from the mesh collision")
	assert_contains(fixed, "[node name=\"SM_Bed_01a\" type=\"CollisionShape3D\" parent=\"StaticBody\" ]\nshape = SubResource(\"0_c6n0r\")")
	assert_contains(fixed, "0.000000, 0.500000, 0.000000)", "primitive box keeps its local transform")
	assert_eq(Fixes.fix_prefab_collision_text(fixed), fixed, "idempotent")


func test_fix_export_tree_fixes_prefabs() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Prefabs/SM_Bed_01a.tscn"), PREFAB)
	write_file(root.path_join("Overview.tscn"), PREFAB)
	var result := Fixes.fix_export_tree(root)
	assert_eq(result.prefabs_fixed, 1, "only files under Prefabs/ are touched")
	assert_contains(FileAccess.get_file_as_string(root.path_join("Overview.tscn")), "10.610139")


const SHADER_SAME_GRAPH := """[gd_resource type="VisualShader" format=3]

[sub_resource type="VisualShaderNodeTexture2DParameter" id="P_f1"]
parameter_name = "Ripple"
texture_type = 2

[sub_resource type="VisualShaderNodeTexture2DParameter" id="P_f2"]
parameter_name = "Ripple"
texture_type = 2

[sub_resource type="VisualShaderNodeTexture2DParameter" id="P_v1"]
parameter_name = "Ripple_VS"
texture_type = 2

[sub_resource type="VisualShaderNodeTexture2DParameter" id="P_v2"]
parameter_name = "Ripple_VS"
texture_type = 2

[sub_resource type="VisualShaderNodeTexture" id="T_f1"]
source = 5

[sub_resource type="VisualShaderNodeTexture" id="T_f2"]
source = 5

[sub_resource type="VisualShaderNodeTexture" id="T_v1"]
source = 5

[sub_resource type="VisualShaderNodeTexture" id="T_v2"]
source = 5

[resource]
nodes/vertex/10/node = SubResource("P_v1")
nodes/vertex/10/position = Vector2(0, 0)
nodes/vertex/12/node = SubResource("P_v2")
nodes/vertex/12/position = Vector2(0, 100)
nodes/fragment/5/node = SubResource("P_f1")
nodes/fragment/5/position = Vector2(0, 0)
nodes/fragment/7/node = SubResource("P_f2")
nodes/fragment/7/position = Vector2(0, 100)
nodes/fragment/8/node = SubResource("T_f1")
nodes/fragment/9/node = SubResource("T_f2")
nodes/vertex/13/node = SubResource("T_v1")
nodes/vertex/14/node = SubResource("T_v2")
nodes/vertex/connections = PackedInt32Array(10, 0, 13, 2, 12, 0, 14, 2, 13, 0, 0, 0)
nodes/fragment/connections = PackedInt32Array(5, 0, 8, 2, 7, 0, 9, 2, 8, 0, 0, 0, 9, 0, 0, 9)
"""


func test_fix_visual_shader_merges_same_graph_duplicates() -> void:
	var result := Fixes.fix_visual_shader_text(SHADER_SAME_GRAPH)
	assert_eq(result.merged, 2)
	assert_eq(result.renamed, [], "the vertex copy already has its own name")
	var text: String = result.text
	assert_false(text.contains("nodes/fragment/7/"), "duplicate fragment node removed")
	assert_false(text.contains("nodes/vertex/12/"), "duplicate vertex node removed")
	assert_contains(text, "nodes/vertex/connections = PackedInt32Array(10, 0, 13, 2, 10, 0, 14, 2, 13, 0, 0, 0)")
	assert_contains(text, "nodes/fragment/connections = PackedInt32Array(5, 0, 8, 2, 5, 0, 9, 2, 8, 0, 0, 0, 9, 0, 0, 9)")
	assert_eq(Fixes.fix_visual_shader_text(text).merged, 0, "idempotent")


func test_fixed_same_graph_shader_compiles() -> void:
	var path := "user://godotfab_test_same_graph.tres"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_visual_shader_text(SHADER_SAME_GRAPH).text)
	f.close()
	var vs: VisualShader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var code := vs.get_code()
	assert_eq(code.count("uniform sampler2D Ripple :"), 1)
	assert_eq(code.count("uniform sampler2D Ripple_VS :"), 1)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


const SCENE_PARENTS := """[gd_scene format=3]

[node name="Root" type="Node3D"]

[node name="Lamp" type="Node3D" parent="." ]

[node name="StaticMesh" type="Node3D" parent="Lamp" ]

[node name="LOD0" type="Node3D" parent="StaticMesh/Lamp" ]

[node name="Bulb" parent="LOD0" instance=ExtResource("1_a")]

[node name="Mesh" parent="Bulb" index="0"]

[node name="Other" type="Node3D" parent="." ]
"""


func test_fix_scene_parent_paths() -> void:
	var fixed := Fixes.fix_scene_parent_paths(SCENE_PARENTS)
	assert_contains(fixed, "[node name=\"LOD0\" type=\"Node3D\" parent=\"Lamp/StaticMesh\" ]")
	assert_contains(fixed, "[node name=\"Bulb\" parent=\"Lamp/StaticMesh/LOD0\" instance=")
	assert_contains(fixed, "[node name=\"Mesh\" parent=\"Lamp/StaticMesh/LOD0/Bulb\" index=\"0\"]")
	assert_contains(fixed, "[node name=\"Other\" type=\"Node3D\" parent=\".\" ]")
	assert_eq(Fixes.fix_scene_parent_paths(fixed), fixed, "idempotent")
	var into_instance := "[node name=\"R\" type=\"Node3D\"]\n\n[node name=\"I\" parent=\".\" instance=ExtResource(\"1\")]\n\n[node name=\"X\" parent=\"I/Inner/Deep\"]\n"
	assert_eq(Fixes.fix_scene_parent_paths(into_instance), into_instance, "paths into instances untouched")



func test_fix_light_energy_text() -> void:
	var light := "[node name=\"PointLight\" type=\"OmniLight3D\" parent=\"L\" ]\nomni_range = 5.000000\nlight_intensity_lumens = 463000.000000\nlight_color = Color(1.000000, 0.800000, 0.600000, 1.000000)\nlight_energy = 16.000000\n"
	var fixed := Fixes.fix_light_energy_text(light)
	assert_contains(fixed, "light_color = Color(1.000000, 0.800000, 0.600000, 1.000000)\nlight_energy = 0.160000\n")
	assert_eq(Fixes.fix_light_energy_text(fixed), fixed, "idempotent")
	var other := "[node name=\"Mesh\" type=\"MeshInstance3D\"]\nlight_energy = 16.000000\n"
	assert_eq(Fixes.fix_light_energy_text(other), other, "only converter lights")


func test_remap_uids_makes_packs_unique() -> void:
	var base := ProjectSettings.globalize_path("user://godotfab_test_uids")
	var trees := []
	for pack in ["a", "b"]:
		var root := base.path_join(pack)
		DirAccess.make_dir_recursive_absolute(root.path_join("Prefabs"))
		Fixes._write(root.path_join("WorldEnvironment.tscn"), "[gd_scene format=3 uid=\"uid://dbbeq4jwg3egn\"]\n\n[ext_resource type=\"CameraAttributesPractical\" uid=\"uid://4cfoi3npjx37\" path=\"res://x/CameraAttributes.tres\" id=\"1\"]\n")
		Fixes._write(root.path_join("CameraAttributes.tres"), "[gd_resource type=\"CameraAttributesPractical\" format=3 uid=\"uid://4cfoi3npjx37\"]\n")
		Fixes._write(root.path_join("Prefabs/notify_player.gd.uid"), "uid://kd5y1qbhyq04\n")
		Fixes._write(root.path_join("Prefabs/SK.tscn"), "[gd_scene format=3 uid=\"uid://abc\"]\n\n[ext_resource type=\"Script\" uid=\"uid://kd5y1qbhyq04\" path=\"res://x/notify_player.gd\" id=\"1\"]\n[ext_resource type=\"Texture2D\" uid=\"uid://external1\" path=\"res://y.png\" id=\"2\"]\n")
		assert_eq(Fixes.remap_uids(root, "res://fab_assets/" + pack), 4)
		trees.append(root)
	var env_a := FileAccess.get_file_as_string(trees[0].path_join("WorldEnvironment.tscn"))
	var env_b := FileAccess.get_file_as_string(trees[1].path_join("WorldEnvironment.tscn"))
	assert_false(env_a.contains("dbbeq4jwg3egn") or env_a.contains("4cfoi3npjx37"), "converter uids replaced")
	assert_true(env_a != env_b, "each pack gets its own uids")
	var cam_uid := FileAccess.get_file_as_string(trees[0].path_join("CameraAttributes.tres")).get_slice("uid=\"", 1).get_slice("\"", 0)
	assert_contains(env_a, "uid=\"%s\" path=\"res://x/CameraAttributes.tres\"" % cam_uid, "references follow the declaration")
	var gd_uid := FileAccess.get_file_as_string(trees[0].path_join("Prefabs/notify_player.gd.uid")).strip_edges()
	assert_contains(FileAccess.get_file_as_string(trees[0].path_join("Prefabs/SK.tscn")), "uid=\"%s\" path=\"res://x/notify_player.gd\"" % gd_uid)
	assert_contains(FileAccess.get_file_as_string(trees[0].path_join("Prefabs/SK.tscn")), "uid://external1", "uids not declared in the pack untouched")
	assert_eq(ResourceUID.text_to_id(cam_uid) != ResourceUID.INVALID_ID, true, "valid uid text")
	assert_eq(Fixes.remap_uids(trees[0], "res://fab_assets/a"), 0, "second pass is a no-op")
	for root in trees:
		for f in ["WorldEnvironment.tscn", "CameraAttributes.tres", "Prefabs/notify_player.gd.uid", "Prefabs/SK.tscn", ".godotfab_uids"]:
			DirAccess.remove_absolute(root.path_join(f))
		DirAccess.remove_absolute(root.path_join("Prefabs"))
		DirAccess.remove_absolute(root)
	DirAccess.remove_absolute(base)


func test_fix_stale_uid_refs() -> void:
	var root := ProjectSettings.globalize_path("user://godotfab_test_stale")
	DirAccess.make_dir_recursive_absolute(root.path_join("Prefabs"))
	Fixes._write(root.path_join("Prefabs/notify_player.gd.uid"), "uid://bla4l78velam5\n")
	var scene := "[gd_scene format=3 uid=\"uid://sk1\"]\n\n[ext_resource type=\"Script\" uid=\"uid://kd5y1qbhyq04\" path=\"res://fab_assets/p/Prefabs/notify_player.gd\" id=\"1\"]\n[ext_resource type=\"Texture2D\" uid=\"uid://zzz\" path=\"res://elsewhere.png\" id=\"2\"]\n"
	Fixes._write(root.path_join("Prefabs/SK.tscn"), scene)
	assert_eq(Fixes.fix_stale_uid_refs(root, "res://fab_assets/p"), 1)
	var out := FileAccess.get_file_as_string(root.path_join("Prefabs/SK.tscn"))
	assert_contains(out, "uid=\"uid://bla4l78velam5\" path=\"res://fab_assets/p/Prefabs/notify_player.gd\"")
	assert_contains(out, "uid=\"uid://zzz\" path=\"res://elsewhere.png\"", "outside the pack untouched")
	assert_eq(Fixes.fix_stale_uid_refs(root, "res://fab_assets/p"), 0, "idempotent")
	for f in ["Prefabs/notify_player.gd.uid", "Prefabs/SK.tscn", "Prefabs", ""]:
		DirAccess.remove_absolute(root.path_join(f))


# UnrealToGodot keeps Unreal parameter names verbatim ("Level 1 Wind") and
# replaces COMPILER_HLSL in custom expressions with a float ("#if 0.0").
const SHADER_UNREAL_NAMES := """[gd_resource type="VisualShader" format=3]

[sub_resource type="VisualShaderNodeBooleanParameter" id="VisualShaderNodeBooleanParameter_wind"]
parameter_name = "Level 1 Wind"
default_value_enabled = true
default_value = true

[sub_resource type="VisualShaderNodeFloatParameter" id="VisualShaderNodeFloatParameter_digit"]
parameter_name = "2nd-Strength"

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_hlsl"]
size = Vector2(250, 150)
expression = "#if 0.0//COMPILER_HLSL
o = vec3(1.0);
#elif 1.0
o = vec3(0.5);
#else
o = vec3(0.0);
#endif"

[resource]
nodes/fragment/2/node = SubResource("VisualShaderNodeBooleanParameter_wind")
nodes/fragment/3/node = SubResource("VisualShaderNodeFloatParameter_digit")
nodes/fragment/4/node = SubResource("VisualShaderNodeExpression_hlsl")
nodes/fragment/4/input_ports = "0,6,w;1,0,s;"
nodes/fragment/4/output_ports = "0,4,o;"
nodes/fragment/4/expression = "#if 0.0//COMPILER_HLSL
o = vec3(1.0);
#elif 1.0
o = vec3(0.5);
#else
o = vec3(0.0);
#endif"
nodes/fragment/connections = PackedInt32Array(2, 0, 4, 0, 3, 0, 4, 1, 4, 0, 0, 0)
"""


func test_fix_visual_shader_integer_preprocessor_conditions() -> void:
	var result := Fixes.fix_visual_shader_text(SHADER_UNREAL_NAMES)
	var text: String = result.text
	assert_eq(result.conditions, 4)
	assert_eq(text.count("#if 0//COMPILER_HLSL"), 2)
	assert_eq(text.count("#elif 1\n"), 2)
	assert_false(text.contains("#if 0.0"))
	assert_eq(Fixes.fix_visual_shader_text(text).conditions, 0, "idempotent")


func test_fix_visual_shader_sanitizes_parameter_names() -> void:
	var result := Fixes.fix_visual_shader_text(SHADER_UNREAL_NAMES)
	assert_eq(result.sanitized, {"Level 1 Wind": "Level_1_Wind", "2nd-Strength": "p_2nd_Strength"})
	var text: String = result.text
	assert_contains(text, "parameter_name = \"Level_1_Wind\"")
	assert_contains(text, "parameter_name = \"p_2nd_Strength\"")
	assert_eq(Fixes.fix_visual_shader_text(text).sanitized, {}, "idempotent")


func test_fix_material_renames_sanitized_parameters() -> void:
	var material := MATERIAL + "shader_parameter/Level 1 Wind = false\n"
	var fixed := Fixes.rename_material_parameters(material, {"Level 1 Wind": "Level_1_Wind"})
	assert_contains(fixed, "shader_parameter/Level_1_Wind = false\n")
	assert_false(fixed.contains("shader_parameter/Level 1 Wind"))
	assert_eq(Fixes.rename_material_parameters(fixed, {"Level 1 Wind": "Level_1_Wind"}), fixed, "idempotent")


func test_fix_export_tree_unreal_names_end_to_end() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Shaders/MI_Spruce.tres"), SHADER_UNREAL_NAMES)
	write_file(root.path_join("Materials/MI_Spruce.tres"), MATERIAL.replace("MI_Bed_01a.tres", "MI_Spruce.tres") + "shader_parameter/Level 1 Wind = false\n")
	var result := Fixes.fix_export_tree(root)
	assert_eq(result, {"shaders_fixed": 1, "materials_fixed": 1, "prefabs_fixed": 0, "scenes_fixed": 0})
	assert_contains(FileAccess.get_file_as_string(root.path_join("Materials/MI_Spruce.tres")), "shader_parameter/Level_1_Wind = false")
	assert_eq(Fixes.fix_export_tree(root), {"shaders_fixed": 0, "materials_fixed": 0, "prefabs_fixed": 0, "scenes_fixed": 0}, "second pass changes nothing")


func test_fixed_unreal_names_shader_code_is_valid() -> void:
	var path := "user://godotfab_test_unreal_names.tres"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_visual_shader_text(SHADER_UNREAL_NAMES).text)
	f.close()
	var vs: VisualShader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var code := vs.get_code()
	assert_contains(code, "uniform bool Level_1_Wind = true;")
	assert_contains(code, "uniform float p_2nd_Strength;")
	assert_contains(code, "#if 0//COMPILER_HLSL")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# UnrealToGodot writes the CollisionShape3D even when it skipped the shape's
# sub_resource (mesh without convex hulls): the prefab doesn't parse and every
# scene instancing it fails to open in the editor.
const PREFAB_MISSING_SHAPE := """[gd_scene load_steps=3 format=3 uid="uid://b1xs3op7mtdvh"]

[ext_resource type="PackedScene" uid="uid://bw3hdofarp41b" path="res://fab_assets/p/SM_Wall.glb" id="1_b6a5v"]

[sub_resource type="BoxShape3D" id="0_box"]
size = Vector3(1, 1, 1)

[node name = "SM_Wall" instance = ExtResource("1_b6a5v")]

[node name="StaticBody" type="StaticBody3D" parent="." ]


[node name="SM_Wall_0" type="CollisionShape3D" parent="StaticBody" ]
shape = SubResource("0_c6n0r")
debug_fill = false

[node name="Box0" type="CollisionShape3D" parent="StaticBody" ]
shape = SubResource("0_box")
debug_fill = false

"""


func test_fix_missing_shape_subresources() -> void:
	var fixed := Fixes.fix_missing_shape_subresources(PREFAB_MISSING_SHAPE)
	assert_false(fixed.contains("SM_Wall_0"), "node with an undefined shape removed")
	assert_false(fixed.contains("0_c6n0r"))
	assert_contains(fixed, "[node name=\"Box0\" type=\"CollisionShape3D\" parent=\"StaticBody\" ]\nshape = SubResource(\"0_box\")")
	assert_eq(Fixes.fix_missing_shape_subresources(fixed), fixed, "idempotent")
	assert_eq(Fixes.fix_missing_shape_subresources(PREFAB), PREFAB, "defined shapes untouched")


func test_fixed_missing_shape_prefab_loads() -> void:
	var path := "user://godotfab_test_missing_shape.tscn"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_missing_shape_subresources(PREFAB_MISSING_SHAPE).replace("[ext_resource type=\"PackedScene\" uid=\"uid://bw3hdofarp41b\" path=\"res://fab_assets/p/SM_Wall.glb\" id=\"1_b6a5v\"]\n", "").replace("[node name = \"SM_Wall\" instance = ExtResource(\"1_b6a5v\")]", "[node name=\"SM_Wall\" type=\"Node3D\"]"))
	f.close()
	var scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_not_null(scene, "prefab parses")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fix_export_tree_removes_missing_shapes() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Prefabs/SM_Wall.tscn"), PREFAB_MISSING_SHAPE)
	var result := Fixes.fix_export_tree(root)
	assert_eq(result.prefabs_fixed, 1)
	assert_false(FileAccess.get_file_as_string(root.path_join("Prefabs/SM_Wall.tscn")).contains("0_c6n0r"))


# UnrealToGodot writes WorldPosition as "INV_VIEW_MATRIX * VERTEX" in every
# graph; in the vertex graph VERTEX is in model space, so wind/bending offsets
# follow the camera (the tree stretches as the camera moves).
const SHADER_WORLD_POSITION := """[gd_resource type="VisualShader" load_steps=3 format=3 uid="uid://cwpvs0test01"]

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_vtx"]
size = Vector2(980, 390)
expression = "//WorldPosition:593(PN_WindAnimation)
output0 = ( INV_VIEW_MATRIX * vec4( VERTEX, 1.0)).xyz;
output0 += ( INV_VIEW_MATRIX * vec4( NORMAL, 0.0)).xyz * 0.0;
"

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_frg"]
size = Vector2(980, 390)
expression = "//CameraVectorWS:33(FuzzyShadingGrass)
vec3 WorldPosition = ( INV_VIEW_MATRIX * vec4( VERTEX, 1.0)).xyz;
output0 = normalize( CAMERA_POSITION_WORLD - WorldPosition );
"

[resource]
nodes/vertex/2/node = SubResource("VisualShaderNodeExpression_vtx")
nodes/vertex/2/position = Vector2(0, 0)
nodes/vertex/2/size = Vector2(980, 390)
nodes/vertex/2/input_ports = ""
nodes/vertex/2/output_ports = "0,4,output0;"
nodes/vertex/2/expression = "//WorldPosition:593(PN_WindAnimation)
output0 = ( INV_VIEW_MATRIX * vec4( VERTEX, 1.0)).xyz;
output0 += ( INV_VIEW_MATRIX * vec4( NORMAL, 0.0)).xyz * 0.0;
"
nodes/vertex/connections = PackedInt32Array(2, 0, 0, 0)
nodes/fragment/2/node = SubResource("VisualShaderNodeExpression_frg")
nodes/fragment/2/position = Vector2(0, 0)
nodes/fragment/2/size = Vector2(980, 390)
nodes/fragment/2/input_ports = ""
nodes/fragment/2/output_ports = "0,4,output0;"
nodes/fragment/2/expression = "//CameraVectorWS:33(FuzzyShadingGrass)
vec3 WorldPosition = ( INV_VIEW_MATRIX * vec4( VERTEX, 1.0)).xyz;
output0 = normalize( CAMERA_POSITION_WORLD - WorldPosition );
"
nodes/fragment/connections = PackedInt32Array(2, 0, 0, 0)
"""


func test_fix_vertex_world_space_only_in_vertex_graph() -> void:
	var result := Fixes.fix_visual_shader_text(SHADER_WORLD_POSITION)
	assert_eq(result.world_space, 4, "VERTEX and NORMAL, in the node and its copy")
	var text: String = result.text
	var frg_start := text.find("id=\"VisualShaderNodeExpression_frg\"")
	var resource_start := text.find("[resource]")
	var vertex_node := text.substr(0, frg_start)
	assert_false(vertex_node.contains("INV_VIEW_MATRIX"), "vertex sub-resource uses MODEL_MATRIX")
	assert_contains(vertex_node, "( MODEL_MATRIX * vec4( VERTEX, 1.0)).xyz")
	assert_contains(vertex_node, "( MODEL_MATRIX * vec4( NORMAL, 0.0)).xyz")
	assert_contains(text.substr(frg_start, resource_start - frg_start), "( INV_VIEW_MATRIX * vec4( VERTEX, 1.0))", "fragment node untouched")
	var vertex_copy := text.substr(text.find("nodes/vertex/2/expression"), text.find("nodes/vertex/connections") - text.find("nodes/vertex/2/expression"))
	assert_false(vertex_copy.contains("INV_VIEW_MATRIX"), "vertex expression copy fixed")
	assert_contains(text.substr(text.find("nodes/fragment/2/expression")), "( INV_VIEW_MATRIX * vec4( VERTEX, 1.0))", "fragment copy untouched")
	assert_eq(Fixes.fix_visual_shader_text(text).world_space, 0, "idempotent")
	assert_eq(Fixes.fix_visual_shader_text(text).text, text, "second pass changes nothing")


func test_fixed_world_space_shader_code_is_valid() -> void:
	var path := "user://godotfab_test_world_space.tres"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_visual_shader_text(SHADER_WORLD_POSITION).text)
	f.close()
	var vs: VisualShader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var code := vs.get_code()
	var vertex_code := code.substr(code.find("void vertex()"), code.find("void fragment()") - code.find("void vertex()"))
	var fragment_code := code.substr(code.find("void fragment()"))
	assert_contains(vertex_code, "MODEL_MATRIX * vec4( VERTEX, 1.0)")
	assert_false(vertex_code.contains("INV_VIEW_MATRIX"))
	assert_contains(fragment_code, "INV_VIEW_MATRIX * vec4( VERTEX, 1.0)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_fix_export_tree_world_space_end_to_end() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Shaders/spruce_leaf.tres"), SHADER_WORLD_POSITION)
	assert_eq(Fixes.fix_export_tree(root).shaders_fixed, 1)
	assert_false(FileAccess.get_file_as_string(root.path_join("Shaders/spruce_leaf.tres")).substr(0, 400).contains("INV_VIEW_MATRIX * vec4( VERTEX"))
	assert_eq(Fixes.fix_export_tree(root).shaders_fixed, 0, "second pass changes nothing")


const EXR_IMPORT := """[remap]

importer="texture"
type="CompressedTexture2D"
uid="uid://b0exrtest01"
metadata={
"imported_formats": ["s3tc_bptc"],
"vram_texture": true
}

[deps]

source_file="res://fab_assets/p/T_Spruce_PIV.exr"

[params]

compress/mode=2
compress/hdr_compression=1
mipmaps/generate=true
mipmaps/limit=-1
"""


func test_fix_float_texture_import_text() -> void:
	var fixed := Fixes.fix_float_texture_import_text(EXR_IMPORT)
	assert_contains(fixed, "\ncompress/mode=0\n")
	assert_contains(fixed, "\nmipmaps/generate=false\n")
	assert_contains(fixed, "\nmipmaps/limit=-1\n", "other settings kept")
	assert_contains(fixed, "compress/hdr_compression=1")
	assert_eq(Fixes.fix_float_texture_import_text(fixed), fixed, "idempotent")


func test_fix_export_tree_float_textures_only_exr() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Textures/T_Spruce_PIV.exr.import"), EXR_IMPORT)
	write_file(root.path_join("Textures/T_Bark_A.png.import"), EXR_IMPORT.replace(".exr", ".png"))
	Fixes.fix_export_tree(root)
	assert_contains(FileAccess.get_file_as_string(root.path_join("Textures/T_Spruce_PIV.exr.import")), "\ncompress/mode=0\n")
	assert_contains(FileAccess.get_file_as_string(root.path_join("Textures/T_Bark_A.png.import")), "\ncompress/mode=2\n", "PNG textures untouched")
	assert_contains(FileAccess.get_file_as_string(root.path_join("Textures/T_Bark_A.png.import")), "\nmipmaps/generate=true\n", "PNG textures untouched")


# A Pivot Painter shader: the vertex graph samples a parameter texture (set by
# the material) and a texture set on its node; the fragment graph samples
# another parameter.
const SHADER_VERTEX_TEXTURES := """[gd_resource type="VisualShader" load_steps=6 format=3 uid="uid://cvtxtex0001"]

[ext_resource type="Texture2D" uid="uid://bwind0001" path="res://fab_assets/p/Engine/Wind.png" id="1_wind"]

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_vec"]
parameter_name = "X_Vector_Texture"

[sub_resource type="VisualShaderNodeTexture" id="VisualShaderNodeTexture_wind"]
source = 0
texture = ExtResource("1_wind")

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_albedo"]
parameter_name = "Albedo"

[resource]
nodes/vertex/2/node = SubResource("VisualShaderNodeTexture2DParameter_vec")
nodes/vertex/3/node = SubResource("VisualShaderNodeTexture_wind")
nodes/fragment/2/node = SubResource("VisualShaderNodeTexture2DParameter_albedo")
"""

const MATERIAL_VERTEX_TEXTURES := """[gd_resource type="ShaderMaterial" load_steps=4 format=3 uid="uid://cmvtx0001"]

[ext_resource type="Shader" uid="uid://cvtxtex0001" path="res://fab_assets/p/Shaders/M_Spruce.tres" id="1_sh"]
[ext_resource type="Texture2D" uid="uid://bvec0001" path="res://fab_assets/p/Textures/T_Spruce_VEC.png" id="2_vec"]
[ext_resource type="Texture2D" uid="uid://balb0001" path="res://fab_assets/p/Textures/T_Spruce_A.png" id="3_alb"]

[resource]
shader = ExtResource("1_sh")
shader_parameter/X_Vector_Texture = ExtResource("2_vec")
shader_parameter/Albedo = ExtResource("3_alb")
"""

const PNG_IMPORT := """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=0
mipmaps/generate=true
detect_3d/compress_to=1
"""


func test_vertex_textures() -> void:
	var found := Fixes.vertex_textures(SHADER_VERTEX_TEXTURES)
	assert_eq(found.params, ["X_Vector_Texture"], "only the vertex graph's parameters")
	assert_eq(found.paths, ["res://fab_assets/p/Engine/Wind.png"], "texture set on a vertex node")
	var none := Fixes.vertex_textures(SHADER_VERTEX_TEXTURES.replace("nodes/vertex/", "nodes/fragment/9"))
	assert_true(none.params.is_empty() and none.paths.is_empty(), "fragment-only textures ignored")


func test_material_textures() -> void:
	assert_eq(Fixes.material_textures(MATERIAL_VERTEX_TEXTURES, ["X_Vector_Texture"]), ["res://fab_assets/p/Textures/T_Spruce_VEC.png"])
	assert_true(Fixes.material_textures(MATERIAL_VERTEX_TEXTURES, []).is_empty())


func test_fix_vertex_texture_import_text() -> void:
	var fixed := Fixes.fix_vertex_texture_import_text(PNG_IMPORT.replace("compress/mode=0", "compress/mode=2"))
	assert_contains(fixed, "\ncompress/mode=0\n", "lossless")
	assert_contains(fixed, "\ndetect_3d/compress_to=0\n", "never recompressed by the editor")
	assert_contains(fixed, "\nmipmaps/generate=true\n", "mipmaps kept")
	assert_eq(Fixes.fix_vertex_texture_import_text(fixed), fixed, "idempotent")


func test_fix_export_tree_vertex_textures_only() -> void:
	var root := tmp_dir()
	write_file(root.path_join("Shaders/M_Spruce.tres"), SHADER_VERTEX_TEXTURES)
	write_file(root.path_join("Materials/MI_Spruce.tres"), MATERIAL_VERTEX_TEXTURES)
	for tex in ["Textures/T_Spruce_VEC.png", "Textures/T_Spruce_A.png", "Engine/Wind.png", "Other/T_Spruce_VEC.png"]:
		write_file(root.path_join(tex + ".import"), PNG_IMPORT)
	Fixes.fix_export_tree(root)
	for tex in ["Textures/T_Spruce_VEC.png", "Engine/Wind.png"]:
		assert_contains(FileAccess.get_file_as_string(root.path_join(tex + ".import")), "\ndetect_3d/compress_to=0\n", tex)
	for tex in ["Textures/T_Spruce_A.png", "Other/T_Spruce_VEC.png"]:
		assert_contains(FileAccess.get_file_as_string(root.path_join(tex + ".import")), "\ndetect_3d/compress_to=1\n", tex + " untouched")
	assert_eq(FileAccess.get_file_as_string(root.path_join("Shaders/M_Spruce.tres")), SHADER_VERTEX_TEXTURES, "shader unchanged")


# Pivot Painter foliage (Spruce Forest): the converter's vertex graph works in
# Unreal space, but leaves the local-to-world transforms as pass-throughs and
# adds the Unreal world offset to VERTEX unconverted.
const SHADER_UNREAL_TRANSFORMS := """[gd_resource type="VisualShader" load_steps=5 format=3 uid="uid://cutrtest0001"]

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_out"]
size = Vector2(980, 500)
expression = "//Scale down to Godot Units, Unreal is in cm
output0 = input0 + input1 / 100.0;"

[sub_resource type="VisualShaderNodeInput" id="VisualShaderNodeInput_vtx"]
input_name = "vertex"

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_piv"]
size = Vector2(980, 390)
expression = "//TransformPosition:541(ms_PivotPainter2_DecodePostion)
//Unimplemented
output0 =  input0;
"

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_axis"]
size = Vector2(980, 390)
expression = "//Transform:548(ms_PivotPainter2_DecodeAxisVector)
//Unimplemented
output0 =  input0;
"

[sub_resource type="VisualShaderNodeExpression" id="VisualShaderNodeExpression_frg"]
size = Vector2(980, 390)
expression = "//Transform:33(ObjectScale)
//Unimplemented
output0 =  input0;
"

[resource]
nodes/vertex/2/node = SubResource("VisualShaderNodeExpression_out")
nodes/vertex/2/position = Vector2(0, 0)
nodes/vertex/2/size = Vector2(980, 500)
nodes/vertex/2/input_ports = "0,4,input0;1,4,input1;"
nodes/vertex/2/output_ports = "0,4,output0;"
nodes/vertex/2/expression = "//Scale down to Godot Units, Unreal is in cm
output0 = input0 + input1 / 100.0;"
nodes/vertex/3/node = SubResource("VisualShaderNodeInput_vtx")
nodes/vertex/3/position = Vector2(-400, 0)
nodes/vertex/4/node = SubResource("VisualShaderNodeExpression_piv")
nodes/vertex/4/position = Vector2(-800, 0)
nodes/vertex/4/size = Vector2(980, 390)
nodes/vertex/4/input_ports = "0,4,input0;"
nodes/vertex/4/output_ports = "0,4,output0;"
nodes/vertex/4/expression = "//TransformPosition:541(ms_PivotPainter2_DecodePostion)
//Unimplemented
output0 =  input0;
"
nodes/vertex/5/node = SubResource("VisualShaderNodeExpression_axis")
nodes/vertex/5/position = Vector2(-1200, 0)
nodes/vertex/5/size = Vector2(980, 390)
nodes/vertex/5/input_ports = "0,4,input0;"
nodes/vertex/5/output_ports = "0,4,output0;"
nodes/vertex/5/expression = "//Transform:548(ms_PivotPainter2_DecodeAxisVector)
//Unimplemented
output0 =  input0;
"
nodes/vertex/connections = PackedInt32Array(3, 0, 2, 0, 3, 0, 5, 0, 5, 0, 4, 0, 4, 0, 2, 1, 2, 0, 0, 0)
nodes/fragment/2/node = SubResource("VisualShaderNodeExpression_frg")
nodes/fragment/2/position = Vector2(0, 0)
nodes/fragment/2/size = Vector2(980, 390)
nodes/fragment/2/input_ports = "0,4,input0;"
nodes/fragment/2/output_ports = "0,4,output0;"
nodes/fragment/2/expression = "//Transform:33(ObjectScale)
//Unimplemented
output0 =  input0;
"
nodes/fragment/connections = PackedInt32Array(2, 0, 0, 0)
"""


func test_fix_vertex_unreal_transforms() -> void:
	var result := Fixes.fix_visual_shader_text(SHADER_UNREAL_TRANSFORMS)
	assert_eq(result.unreal_transforms, 6, "offset, position and axis, in the nodes and their copies")
	var text: String = result.text
	var vertex_part := text.substr(0, text.find("nodes/fragment/2/node"))
	assert_false(vertex_part.substr(0, vertex_part.find("id=\"VisualShaderNodeExpression_frg\"")).contains("//Unimplemented"), "vertex pass-throughs replaced")
	assert_contains(vertex_part, "output0 = input0 + (inverse(MODEL_MATRIX) * vec4(input1.xzy / 100.0, 0.0)).xyz;")
	assert_contains(vertex_part, "output0 = ((MODEL_MATRIX * vec4(input0.xzy / 100.0, 1.0)).xyz * 100.0).xzy;")
	assert_contains(vertex_part, "output0 = (MODEL_MATRIX * vec4(input0.xzy, 0.0)).xyz.xzy;")
	assert_contains(text.substr(text.find("id=\"VisualShaderNodeExpression_frg\"")), "//Unimplemented\noutput0 =  input0;", "fragment graph untouched")
	assert_eq(Fixes.fix_visual_shader_text(text).unreal_transforms, 0, "idempotent")
	assert_eq(Fixes.fix_visual_shader_text(text).text, text, "second pass changes nothing")


func test_fixed_unreal_transforms_shader_code() -> void:
	var path := "user://godotfab_test_unreal_transforms.tres"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_visual_shader_text(SHADER_UNREAL_TRANSFORMS).text)
	f.close()
	var vs: VisualShader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var code := vs.get_code()
	var vertex_code := code.substr(code.find("void vertex()"), code.find("void fragment()") - code.find("void vertex()"))
	assert_contains(vertex_code, "inverse(MODEL_MATRIX)")
	assert_contains(vertex_code, "MODEL_MATRIX * vec4(n_out5p0.xzy / 100.0, 1.0)", "the pivot input is transformed")
	assert_contains(vertex_code, "MODEL_MATRIX * vec4(n_out3p0.xzy, 0.0)", "the axis input is transformed")
	assert_false(vertex_code.contains("//Unimplemented"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# Unreal Power -> vec3 pow node: input 0 connected, input 1 left at its default.
const SHADER_POWER := """[gd_resource type="VisualShader" load_steps=4 format=3 uid="uid://cpowtest0001"]

[sub_resource type="VisualShaderNodeInput" id="VisualShaderNodeInput_vtx"]
input_name = "vertex"

[sub_resource type="VisualShaderNodeVectorOp" id="VisualShaderNodeVectorOp_pow"]
operator = 5
default_input_values = [0, Vector3( 1.000000, 1.000000, 1.000000 ), 1, Vector3( 5.000000, 5.000000, 5.000000 )]
op_type = 1

[sub_resource type="VisualShaderNodeVectorOp" id="VisualShaderNodeVectorOp_add"]
operator = 0
op_type = 1

[resource]
nodes/vertex/2/node = SubResource("VisualShaderNodeInput_vtx")
nodes/vertex/2/position = Vector2(0, 0)
nodes/vertex/3/node = SubResource("VisualShaderNodeVectorOp_pow")
nodes/vertex/3/position = Vector2(200, 0)
nodes/vertex/4/node = SubResource("VisualShaderNodeVectorOp_add")
nodes/vertex/4/position = Vector2(400, 0)
nodes/vertex/connections = PackedInt32Array(2, 0, 3, 0, 3, 0, 4, 0, 2, 0, 4, 1, 4, 0, 0, 0)
"""


func test_fix_unreal_power() -> void:
	var result := Fixes.fix_unreal_power(SHADER_POWER)
	assert_eq(result.count, 1, "only the pow node")
	assert_contains(result.text, "[sub_resource type=\"VisualShaderNodeExpression\" id=\"VisualShaderNodeVectorOp_pow\"]")
	assert_contains(result.text, "output0 = pow(max(input0, vec3(0.0)), vec3(5.000000, 5.000000, 5.000000));", "unconnected exponent keeps its default")
	assert_contains(result.text, "nodes/vertex/3/input_ports = \"0,4,input0;1,4,input1;\"")
	assert_contains(result.text, "[sub_resource type=\"VisualShaderNodeVectorOp\" id=\"VisualShaderNodeVectorOp_add\"]", "other vector ops untouched")
	assert_eq(Fixes.fix_unreal_power(result.text).count, 0, "idempotent")


const SHADER_CLAMP := """[gd_resource type="VisualShader" load_steps=5 format=3 uid="uid://cclamptest01"]

[sub_resource type="VisualShaderNodeFloatParameter" id="VisualShaderNodeFloatParameter_x"]
parameter_name = "Extent"

[sub_resource type="VisualShaderNodeClamp" id="VisualShaderNodeClamp_min"]
default_input_values = [0, 0.000000, 1, 8.000000, 2, 1.000000]
op_type = 0

[sub_resource type="VisualShaderNodeClamp" id="VisualShaderNodeClamp_normal"]
default_input_values = [0, 0.000000, 1, 0.000000, 2, 1.000000]
op_type = 0

[sub_resource type="VisualShaderNodeClamp" id="VisualShaderNodeClamp_linked"]
default_input_values = [0, 0.000000, 1, 8.000000, 2, 1.000000]
op_type = 0

[resource]
nodes/vertex/2/node = SubResource("VisualShaderNodeFloatParameter_x")
nodes/vertex/2/position = Vector2(0, 0)
nodes/vertex/3/node = SubResource("VisualShaderNodeClamp_min")
nodes/vertex/3/position = Vector2(200, 0)
nodes/vertex/4/node = SubResource("VisualShaderNodeClamp_normal")
nodes/vertex/4/position = Vector2(400, 0)
nodes/vertex/5/node = SubResource("VisualShaderNodeClamp_linked")
nodes/vertex/5/position = Vector2(400, 200)
nodes/vertex/connections = PackedInt32Array(2, 0, 3, 0, 3, 0, 4, 0, 2, 0, 5, 0, 2, 0, 5, 2, 4, 0, 0, 0)
"""


func test_fix_clamp_min() -> void:
	var result := Fixes.fix_clamp_min(SHADER_CLAMP)
	assert_eq(result.count, 1, "only the unlinked clamp with min above max")
	assert_contains(result.text, "[sub_resource type=\"VisualShaderNodeFloatOp\" id=\"VisualShaderNodeClamp_min\"]\noperator = 6\ndefault_input_values = [0, 0.000000, 1, 8.000000]\n\n[")
	assert_contains(result.text, "[sub_resource type=\"VisualShaderNodeClamp\" id=\"VisualShaderNodeClamp_normal\"]", "a regular clamp is untouched")
	assert_contains(result.text, "[sub_resource type=\"VisualShaderNodeClamp\" id=\"VisualShaderNodeClamp_linked\"]", "a clamp with a linked max is untouched")
	assert_eq(Fixes.fix_clamp_min(result.text).count, 0, "idempotent")
	assert_eq(Fixes.fix_clamp_min(SHADER_POWER).text, SHADER_POWER, "shaders without clamps untouched")
	var path := "user://godotfab_test_clamp.tres"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_visual_shader_text(SHADER_CLAMP).text)
	f.close()
	var vs: VisualShader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var code := vs.get_code()
	assert_contains(code, "max(n_out2p0, n_in3p1)", "Clamp Min becomes max(x, min)")
	assert_contains(code, "clamp(n_out3p0, n_in4p1, n_in4p2)", "the next node still reads it")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


const SHADER_NEAREST := """[gd_resource type="VisualShader" load_steps=4 format=3 uid="uid://cnearest0001"]

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_piv"]
parameter_name = "Position_and_Index_Texture_VS"
texture_type = 0
texture_filter = 6
texture_repeat = 0

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_noise"]
parameter_name = "WindNoise"
texture_type = 0
texture_filter = 6
texture_repeat = 0

[sub_resource type="VisualShaderNodeTexture2DParameter" id="VisualShaderNodeTexture2DParameter_vec"]
parameter_name = "X_Vector"

[resource]
nodes/vertex/2/node = SubResource("VisualShaderNodeTexture2DParameter_piv")
nodes/vertex/3/node = SubResource("VisualShaderNodeTexture2DParameter_noise")
nodes/vertex/4/node = SubResource("VisualShaderNodeTexture2DParameter_vec")
"""

const MATERIAL_NEAREST := """[gd_resource type="ShaderMaterial" load_steps=4 format=3]

[ext_resource type="Shader" path="res://Shaders/nearest.tres" id="1_s"]
[ext_resource type="Texture2D" path="res://PN/Textures/tree_PIV.exr" id="2_p"]
[ext_resource type="Texture2D" path="res://Engine/Noise.png" id="3_n"]
[ext_resource type="Texture2D" path="res://PN/Textures/tree_VEC.png" id="4_v"]

[resource]
shader = ExtResource("1_s")
shader_parameter/Position_and_Index_Texture_VS = ExtResource("2_p")
shader_parameter/WindNoise = ExtResource("3_n")
shader_parameter/X_Vector = ExtResource("4_v")
"""


func test_set_texture_filter_text() -> void:
	var result := Fixes.set_texture_filter_text(SHADER_NEAREST, ["Position_and_Index_Texture_VS", "X_Vector"], 1)
	assert_eq(result.count, 2, "the two listed parameters")
	assert_contains(result.text, "parameter_name = \"Position_and_Index_Texture_VS\"\ntexture_type = 0\ntexture_filter = 1\n")
	assert_contains(result.text, "parameter_name = \"WindNoise\"\ntexture_type = 0\ntexture_filter = 6\n", "other parameters keep their filter")
	assert_contains(result.text, "parameter_name = \"X_Vector\"\ntexture_filter = 1\n", "a missing filter line is added")
	assert_eq(Fixes.set_texture_filter_text(result.text, ["Position_and_Index_Texture_VS", "X_Vector"], 1).count, 0, "idempotent")


func test_nearest_material_parameters() -> void:
	var nearest := {"PN/Textures/tree_PIV": true, "PN/Textures/tree_VEC": true}
	assert_eq(Fixes.nearest_material_parameters(MATERIAL_NEAREST, nearest), ["Position_and_Index_Texture_VS", "X_Vector"] as Array[String])
	var moved := MATERIAL_NEAREST.replace("res://PN/", "res://fab_assets/pack/PN/")
	assert_eq(Fixes.nearest_material_parameters(moved, nearest).size(), 2, "paths already under the pack folder match too")
	assert_eq(Fixes.nearest_material_parameters(MATERIAL_NEAREST, {"Textures/tree_PIV": true}).size(), 1, "matched on whole path segments")
	assert_eq(Fixes.nearest_material_parameters(MATERIAL_NEAREST, {"ree_PIV": true}).size(), 0, "not on partial names")


func test_fix_nearest_textures_tree() -> void:
	var root := ProjectSettings.globalize_path("user://godotfab_test_nearest")
	DirAccess.make_dir_recursive_absolute(root + "/Shaders")
	DirAccess.make_dir_recursive_absolute(root + "/Materials")
	var write := func(rel: String, text: String) -> void:
		var f := FileAccess.open(root + "/" + rel, FileAccess.WRITE)
		f.store_string(text)
		f.close()
	write.call("Shaders/nearest.tres", SHADER_NEAREST)
	write.call("Materials/tree.tres", MATERIAL_NEAREST)
	var files: Array[String] = [root + "/Shaders/nearest.tres", root + "/Materials/tree.tres"]
	assert_eq(Fixes.fix_nearest_textures(root, files), 0, "no list, nothing changes")
	write.call(Fixes.NEAREST_TEXTURES_FILE, "PN/Textures/tree_PIV\nPN/Textures/tree_VEC\n")
	assert_eq(Fixes.fix_nearest_textures(root, files), 2)
	var fixed := FileAccess.get_file_as_string(root + "/Shaders/nearest.tres")
	assert_contains(fixed, "parameter_name = \"WindNoise\"\ntexture_type = 0\ntexture_filter = 6\n", "wind noise stays linear")
	assert_eq(Fixes.fix_nearest_textures(root, files), 0, "idempotent")
	for rel in ["Shaders/nearest.tres", "Materials/tree.tres", Fixes.NEAREST_TEXTURES_FILE]:
		DirAccess.remove_absolute(root + "/" + rel)
	for rel in ["Shaders", "Materials", ""]:
		DirAccess.remove_absolute(root + "/" + rel)


func test_fix_world_normal_axes() -> void:
	var expr := "\"//Vertex/PixelNormalWS:255(null)\noutput0 = ( INV_VIEW_MATRIX * vec4( NORMAL, 0.0)).xyz;\n\""
	var vertex := "\"//Vertex/PixelNormalWS:12(null)\noutput0 = ( MODEL_MATRIX * vec4( NORMAL, 0.0)).xyz;\n\""
	var other := "\"//Transform:198(FuzzyShadingGrass)\nvec3 WorldNormal   = ( INV_VIEW_MATRIX * vec4( NORMAL, 0.0)).xyz;\n\""
	var text := "expression = %s\nnodes/fragment/255/expression = %s\nexpression = %s\nexpression = %s\n" % [expr, expr, vertex, other]
	var result := Fixes.fix_world_normal_axes(text)
	assert_eq(result.count, 3, "both copies of the fragment node and the vertex node")
	assert_contains(result.text, "0.0)).xyz;\noutput0 = output0.xzy;// GodotFab: Unreal axes, Z up\n\"")
	assert_contains(result.text, other, "other world-space nodes untouched")
	assert_eq(Fixes.fix_world_normal_axes(result.text).count, 0, "idempotent")
	assert_eq(Fixes.fix_world_normal_axes(SHADER_POWER).text, SHADER_POWER, "shaders without the node untouched")


func test_fixed_power_shader_code() -> void:
	var path := "user://godotfab_test_power.tres"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(Fixes.fix_visual_shader_text(SHADER_POWER).text)
	f.close()
	var vs: VisualShader = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var code := vs.get_code()
	assert_contains(code, "pow(max(n_out2p0, vec3(0.0)), vec3(5.000000, 5.000000, 5.000000))", "the connected base is clamped")
	assert_contains(code, "n_out3p0 + n_out2p0", "the result still feeds the next node")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
