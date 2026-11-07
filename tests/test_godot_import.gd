extends "res://tests/test_case.gd"

const ExportFixesRef = preload("res://addons/godotfab/export_fixes.gd")

const GodotImport = preload("res://addons/godotfab/godot_import.gd")
const ProjectAssets = preload("res://addons/godotfab/project_assets.gd")


func test_slug() -> void:
	assert_eq(GodotImport.slug("My Pack: Vol 1"), "my_pack_vol_1")
	assert_eq(GodotImport.slug("Café-Été 2"), "caf-t_2")
	assert_eq(GodotImport.slug("   "), "asset")
	assert_eq(GodotImport.slug("!!!"), "asset")
	assert_eq(GodotImport.slug("a".repeat(100)).length(), 48)
	assert_eq(GodotImport.slug("Trailing __ "), "trailing")


func test_rewrite_paths() -> void:
	var text := '[ext_resource type="PackedScene" uid="uid://abc" path="res://Prefabs/A.tscn" id="1"]'
	var out := GodotImport.rewrite_paths(text, "fab_assets/p")
	assert_contains(out, 'path="res://fab_assets/p/Prefabs/A.tscn"')
	assert_contains(out, 'uid="uid://abc"', "uid untouched")
	assert_false(out.contains("res://fab_assets/p/fab_assets"), "no double prefix")


func test_rewrite_triple_slash() -> void:
	var out := GodotImport.rewrite_paths('source_file="res:///Engine/E.png"', "fab_assets/p")
	assert_eq(out, 'source_file="res://fab_assets/p/Engine/E.png"')
	# Same destination as the double-slash form.
	assert_eq(out, GodotImport.rewrite_paths('source_file="res://Engine/E.png"', "fab_assets/p"))


func test_rewrite_paths_strips_prefix_slashes() -> void:
	assert_eq(GodotImport.rewrite_paths("res://A.tscn", "/fab_assets/p/"), "res://fab_assets/p/A.tscn")


func _make_export(export_dir: String) -> void:
	write_file(export_dir.path_join("project.godot"), "config_version=5\n")
	write_file(export_dir.path_join(".godot/imported/junk.md5"), "x")
	write_file(export_dir.path_join("Untitled.tscn"),
		'[gd_scene format=3 uid="uid://lvl"]\n[ext_resource type="PackedScene" uid="uid://pa" path="res://Prefabs/A.tscn" id="1"]\n')
	write_file(export_dir.path_join("WorldEnvironment.tscn"), '[gd_scene format=3 uid="uid://we"]\n')
	write_file(export_dir.path_join("Prefabs/A.tscn"),
		'[gd_scene format=3 uid="uid://pa"]\n[ext_resource type="PackedScene" uid="uid://glb" path="res://Pack/Meshes/A.glb" id="1"]\n')
	write_file(export_dir.path_join("Pack/Meshes/A.glb"), PackedByteArray([0x67, 0x6C, 0x54, 0x46, 0, 1, 2, 3]))
	write_file(export_dir.path_join("Pack/Meshes/A.glb.import"),
		'[remap]\n\nimporter="scene"\ntype="PackedScene"\nuid="uid://glb"\npath="res://.godot/imported/A.glb-abc.scn"\n\n[deps]\n\nsource_file="res://Pack/Meshes/A.glb"\ndest_files=["res://.godot/imported/A.glb-abc.scn"]\n\n[params]\n\nnodes/root_type=""\n')
	write_file(export_dir.path_join("Engine/E.png.import"),
		'[remap]\n\nimporter="texture"\nuid="uid://png"\npath.s3tc="res://.godot/imported/E.png-1.s3tc.ctex"\n\n[deps]\n\nsource_file="res:///Engine/E.png"\n')


func test_import_export_copies_and_rewrites() -> void:
	var root := tmp_dir()
	var export_dir := root.path_join("export")
	_make_export(export_dir)
	var target := root.path_join("fab_assets/p")
	var res := GodotImport.import_export(export_dir, "res://fab_assets/p", {"uid": "u1", "title": "T", "format": "unreal-engine"}, target)
	assert_true(res.ok, "import ok: %s" % res.get("error", ""))
	assert_true(res.scene.ends_with("Untitled.tscn"), "scene: %s" % res.scene)
	assert_eq(res.scene, "res://fab_assets/p/Untitled.tscn")
	assert_false(FileAccess.file_exists(target.path_join("project.godot")), "project.godot skipped")
	assert_false(DirAccess.dir_exists_absolute(target.path_join(".godot")), ".godot skipped")
	assert_true(FileAccess.file_exists(target.path_join("WorldEnvironment.tscn")))
	assert_eq(FileAccess.get_file_as_bytes(target.path_join("Pack/Meshes/A.glb")), PackedByteArray([0x67, 0x6C, 0x54, 0x46, 0, 1, 2, 3]), "binary copied intact")
	var level := FileAccess.get_file_as_string(target.path_join("Untitled.tscn"))
	assert_contains(level, 'path="res://fab_assets/p/Prefabs/A.tscn"')
	# UIDs are remapped per pack (ExportFixes.remap_uids); references follow.
	var pa := "uid://" + ExportFixesRef.derived_uid("res://fab_assets/p", "pa")
	var glb := "uid://" + ExportFixesRef.derived_uid("res://fab_assets/p", "glb")
	assert_contains(level, 'uid="%s"' % pa)
	assert_false(level.contains('uid="uid://pa"'))
	var prefab := FileAccess.get_file_as_string(target.path_join("Prefabs/A.tscn"))
	assert_contains(prefab, '[gd_scene format=3 uid="%s"]' % pa)
	assert_contains(prefab, 'uid="%s" path=' % glb)
	assert_contains(prefab, 'path="res://fab_assets/p/Pack/Meshes/A.glb"')
	var imp := FileAccess.get_file_as_string(target.path_join("Pack/Meshes/A.glb.import"))
	assert_contains(imp, 'source_file="res://fab_assets/p/Pack/Meshes/A.glb"')
	assert_contains(imp, 'uid="%s"' % glb)
	assert_contains(imp, "[params]")
	assert_false(imp.contains("dest_files"), "dest_files stripped")
	assert_false(imp.contains(".godot/imported"), "imported path stripped")
	var png_imp := FileAccess.get_file_as_string(target.path_join("Engine/E.png.import"))
	assert_contains(png_imp, 'source_file="res://fab_assets/p/Engine/E.png"')
	assert_false(png_imp.contains("path.s3tc"), "path.s3tc stripped")
	var meta: Dictionary = read_json(target.path_join(".godotfab.json"))
	assert_eq(meta.get("uid"), "u1")
	assert_eq(meta.get("title"), "T")
	assert_eq(meta.get("scene"), "res://fab_assets/p/Untitled.tscn")
	assert_eq(meta.get("format"), "unreal-engine")
	assert_true(int(meta.get("imported_at", 0)) > 0, "imported_at set")


func test_import_export_replaces_existing_target() -> void:
	var root := tmp_dir()
	var export_dir := root.path_join("export")
	_make_export(export_dir)
	var target := root.path_join("fab_assets/p")
	write_file(target.path_join("stale.txt"), "old")
	var res := GodotImport.import_export(export_dir, "res://fab_assets/p", {"uid": "u1"}, target)
	assert_true(res.ok, res.get("error", ""))
	assert_false(FileAccess.file_exists(target.path_join("stale.txt")), "old content removed")
	assert_false(DirAccess.dir_exists_absolute(target + ".old"), ".old removed on success")
	assert_true(FileAccess.file_exists(target.path_join("Untitled.tscn")))


func test_import_export_missing_dir_fails() -> void:
	var root := tmp_dir()
	var res := GodotImport.import_export(root.path_join("nope"), "res://fab_assets/p", {}, root.path_join("t"))
	assert_false(res.ok)
	assert_true(res.error != "", "error message")


func test_project_assets_scan() -> void:
	var root := tmp_dir()
	write_file(root.path_join("pack_a/.godotfab.json"), JSON.stringify({"uid": "a", "title": "A", "scene": "res://fab_assets/pack_a/Untitled.tscn"}))
	write_file(root.path_join("pack_b/.godotfab.json"), JSON.stringify({"uid": "b", "title": "B"}))
	write_file(root.path_join("pack_c/notes.txt"), "no manifest")
	write_file(root.path_join("pack_d/.godotfab.json"), "{not json")
	write_file(root.path_join("deep/x/.godotfab.json"), JSON.stringify({"uid": "deep"}))
	var items := ProjectAssets.scan(root)
	assert_eq(items.size(), 2)
	var folders := []
	for item in items:
		folders.append(item.folder)
	folders.sort()
	assert_eq(folders, ["pack_a", "pack_b"])
	assert_eq(ProjectAssets.find(root, "a").get("folder"), "pack_a")
	assert_eq(ProjectAssets.find(root, "a").get("title"), "A")
	assert_eq(ProjectAssets.find(root, "zzz"), {})
	assert_eq(ProjectAssets.scan(root.path_join("missing")).size(), 0)


# --- Task 7b: direct import ---------------------------------------------------

static func _make_zip(path: String, entries: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var packer := ZIPPacker.new()
	var err := packer.open(path)
	assert(err == OK)
	for name in entries:
		packer.start_file(name)
		var content = entries[name]
		packer.write_file(content if content is PackedByteArray else str(content).to_utf8_buffer())
		packer.close_file()
	packer.close()


func test_extract_zips_nested() -> void:
	var root := tmp_dir()
	var inner_path := root.path_join("build/inner.zip")
	_make_zip(inner_path, {"Chair/": PackedByteArray(), "Chair/model.glb": "glb", "Chair/textures/tex.png": "png"})
	var inner_bytes := FileAccess.get_file_as_bytes(inner_path)
	DirAccess.remove_absolute(inner_path)
	_make_zip(root.path_join("files/source.zip"), {"readme.txt": "hi", "inner.zip": inner_bytes})
	var res := GodotImport.extract_zips(root.path_join("files"))
	assert_true(res.ok, res.get("error", ""))
	assert_eq(res.extracted, 2)
	var ex := root.path_join("files/source_extracted")
	assert_true(FileAccess.file_exists(ex.path_join("readme.txt")))
	assert_eq(FileAccess.get_file_as_string(ex.path_join("inner_extracted/Chair/model.glb")), "glb")
	assert_eq(FileAccess.get_file_as_string(ex.path_join("inner_extracted/Chair/textures/tex.png")), "png")
	assert_false(FileAccess.file_exists(root.path_join("files/source.zip")), "zip deleted")
	assert_false(FileAccess.file_exists(ex.path_join("inner.zip")), "nested zip deleted")
	# Idempotent: nothing left to extract.
	var again := GodotImport.extract_zips(root.path_join("files"))
	assert_true(again.ok)
	assert_eq(again.extracted, 0)


func test_extract_zip_rejects_traversal() -> void:
	var root := tmp_dir()
	_make_zip(root.path_join("files/evil.zip"), {"ok.txt": "fine", "../escape.txt": "bad"})
	var res := GodotImport.extract_zips(root.path_join("files"))
	assert_false(res.ok)
	assert_contains(res.error, "Unsafe path in evil.zip")
	assert_false(FileAccess.file_exists(root.path_join("escape.txt")), "nothing written outside")
	assert_false(FileAccess.file_exists(root.path_join("files/escape.txt")), "nothing written outside")
	assert_true(FileAccess.file_exists(root.path_join("files/evil.zip")), "bad zip kept")
	_make_zip(root.path_join("files2/abs.zip"), {"/etc/x.txt": "bad"})
	assert_false(GodotImport.extract_zips(root.path_join("files2")).ok)
	_make_zip(root.path_join("files3/drive.zip"), {"C:/x.txt": "bad"})
	assert_false(GodotImport.extract_zips(root.path_join("files3")).ok)


func test_import_direct_copies_models_and_textures() -> void:
	var root := tmp_dir()
	var files := root.path_join("files")
	write_file(files.path_join("source_extracted/Chair/model.glb"), "glb")
	write_file(files.path_join("source_extracted/Chair/textures/a.png"), "png")
	write_file(files.path_join("source_extracted/Chair/readme.txt"), "skip me")
	write_file(files.path_join("source_extracted/License.pdf"), "skip me")
	var target := root.path_join("fab_assets/chair")
	var res := GodotImport.import_direct(files, "res://fab_assets/chair", {"uid": "c1", "format": "gltf"}, target)
	assert_true(res.ok, res.get("error", ""))
	assert_eq(res.scene, "res://fab_assets/chair/model.glb")
	assert_eq(FileAccess.get_file_as_string(target.path_join("model.glb")), "glb")
	assert_eq(FileAccess.get_file_as_string(target.path_join("textures/a.png")), "png")
	assert_false(FileAccess.file_exists(target.path_join("readme.txt")), "non-asset skipped")
	assert_false(FileAccess.file_exists(target.path_join("Chair/model.glb")), "paths relative to model root")
	var meta: Dictionary = read_json(target.path_join(".godotfab.json"))
	assert_eq(meta.get("uid"), "c1")
	assert_eq(meta.get("scene"), "res://fab_assets/chair/model.glb")
	assert_eq(meta.get("format"), "gltf")


func test_import_direct_prefers_glb_and_falls_back_to_root() -> void:
	var root := tmp_dir()
	var files := root.path_join("files")
	write_file(files.path_join("x_extracted/b.fbx"), "fbx")
	write_file(files.path_join("x_extracted/a.gltf"), "gltf")
	write_file(files.path_join("x_extracted/a.bin"), "bin")
	var target := root.path_join("t1")
	var res := GodotImport.import_direct(files, "res://fab_assets/t1", {}, target)
	assert_true(res.ok, res.get("error", ""))
	assert_eq(res.scene, "res://fab_assets/t1/a.gltf")
	assert_true(FileAccess.file_exists(target.path_join("a.bin")))
	assert_true(FileAccess.file_exists(target.path_join("b.fbx")))
	# No model anywhere: textures at the root are copied, scene is "".
	var files2 := root.path_join("files2")
	write_file(files2.path_join("only.jpg"), "jpg")
	write_file(files2.path_join("sub/deep.png"), "png")
	var target2 := root.path_join("t2")
	var res2 := GodotImport.import_direct(files2, "res://fab_assets/t2", {}, target2)
	assert_true(res2.ok, res2.get("error", ""))
	assert_eq(res2.scene, "")
	assert_true(FileAccess.file_exists(target2.path_join("only.jpg")))
	assert_true(FileAccess.file_exists(target2.path_join("sub/deep.png")))


func test_import_export_uses_done_file_scene() -> void:
	var export_dir := tmp_dir()
	var target := tmp_dir().path_join("pack")
	write_file(export_dir.path_join("project.godot"), "config_version=5\n")
	write_file(export_dir.path_join("AAA_First.tscn"), "[gd_scene format=3]\n")
	write_file(export_dir.path_join("VOL2_Laundry.tscn"), "[gd_scene format=3]\n")
	write_file(export_dir.path_join("godotfab_done.txt"), "scene=VOL2_Laundry.tscn\nworld=VOL2_Laundry\n")
	var importer = preload("res://addons/godotfab/godot_import.gd")
	var result: Dictionary = importer.import_export(export_dir, "res://fab_assets/pack", {"uid": "u"}, target)
	assert_true(result.ok, result.get("error", ""))
	assert_eq(result.scene, "res://fab_assets/pack/VOL2_Laundry.tscn")
	assert_false(FileAccess.file_exists(target.path_join("godotfab_done.txt")), "done file not copied")
