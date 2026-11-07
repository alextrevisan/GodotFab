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
