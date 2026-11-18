extends "res://tests/test_case.gd"

const CoincidentSurfaces = preload("res://addons/godotfab/coincident_surfaces.gd")


## A strip of square quads of side `side` along X on the XZ plane (normal
## up), the first at `first` quads from the origin: 4 vertices and 2 triangles
## per quad.
static func _strip(first: int, quads: int, material: Material = null, side := 1.0) -> ImporterMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for q in quads:
		var x := float(first + q)
		var base := vertices.size()
		vertices.append_array([Vector3(x, 0, 0) * side, Vector3(x + 1, 0, 0) * side, Vector3(x + 1, 0, 1) * side, Vector3(x, 0, 1) * side])
		normals.append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ImporterMesh.new()
	mesh.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, material, "strip")
	return mesh


static func _instance(parent: Node, mesh: ImporterMesh, name: String) -> ImporterMeshInstance3D:
	var node := ImporterMeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	parent.add_child(node)
	return node


static func _vertices(mesh: ImporterMesh) -> PackedVector3Array:
	return mesh.get_surface_arrays(0)[Mesh.ARRAY_VERTEX]


func test_pushes_out_a_mesh_lying_on_another() -> void:
	var scene := Node3D.new()
	var body := _strip(0, 8)
	var material := StandardMaterial3D.new()
	var overlay := _strip(2, 2, material)
	_instance(scene, body, "Body")
	_instance(scene, overlay, "Overlay")
	assert_eq(CoincidentSurfaces.separate(scene), 1, "one mesh separated")
	var lifted := _vertices(overlay)
	assert_eq(lifted.size(), 8, "overlay vertices")
	# The pair spans 8 units, so the overlay rises 8 * OFFSET.
	var expected := 8.0 * CoincidentSurfaces.OFFSET
	assert_true(absf(lifted[0].y - expected) < expected * 0.01, "overlay pushed along its normal: y %f" % lifted[0].y)
	assert_eq(Vector2(lifted[0].x, lifted[0].z), Vector2(2, 0), "and nowhere else")
	assert_eq(_vertices(body)[0], Vector3(0, 0, 0), "the body stays")
	assert_eq(overlay.get_surface_material(0), material, "the material is kept")
	assert_eq(overlay.get_surface_name(0), "strip", "the surface name is kept")
	assert_eq(overlay.get_surface_arrays(0)[Mesh.ARRAY_INDEX].size(), 12, "the triangles are kept")
	scene.free()


func test_follows_the_node_transforms() -> void:
	# The overlay is a child of the scaled body and scaled itself: it lies on the
	# body in the scene, not in its own coordinates.
	var scene := Node3D.new()
	var body_node := _instance(scene, _strip(0, 8), "Body")
	body_node.scale = Vector3(0.5, 0.5, 0.5)
	body_node.position = Vector3(10, 0, 0)
	var overlay := _strip(2, 2, null, 0.25)
	var overlay_node := _instance(body_node, overlay, "Overlay")
	overlay_node.scale = Vector3(4, 4, 4)
	assert_eq(CoincidentSurfaces.separate(scene), 1, "found through the transforms")
	# The pair spans 4 units of the scene, and a unit of the overlay is 2 of them.
	var expected := 4.0 * CoincidentSurfaces.OFFSET / 2.0
	var lifted := _vertices(overlay)
	assert_true(absf(lifted[0].y - expected) < expected * 0.01, "pushed in the overlay's units: y %f, expected %f" % [lifted[0].y, expected])
	scene.free()


func test_leaves_meshes_that_only_touch() -> void:
	var scene := Node3D.new()
	var left := _strip(0, 2)
	var right := _strip(2, 2)
	_instance(scene, left, "Left")
	_instance(scene, right, "Right")
	assert_eq(CoincidentSurfaces.separate(scene), 0, "a shared edge is no overlap")
	assert_eq(_vertices(left)[0], Vector3(0, 0, 0), "left untouched")
	assert_eq(_vertices(right)[0], Vector3(2, 0, 0), "right untouched")
	scene.free()


func test_pushes_split_vertices_together() -> void:
	# Two faces meeting at a hard edge have one vertex per face there: both
	# must move the same way, or the edge would open.
	var scene := Node3D.new()
	var overlay := _strip(0, 2)
	var arrays := overlay.get_surface_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in range(4, 8):
		normals[i] = Vector3.RIGHT
	arrays[Mesh.ARRAY_NORMAL] = normals
	var bent := ImporterMesh.new()
	bent.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_instance(scene, _strip(0, 2), "Body")
	_instance(scene, bent, "Overlay")
	# Equal overlap both ways: the later mesh is the one pushed.
	assert_eq(CoincidentSurfaces.separate(scene), 1, "separated")
	var lifted := _vertices(bent)
	# Vertex 1 (first quad) and vertex 4 (second quad) are both at (1, 0, 0).
	assert_true(lifted[1].is_equal_approx(lifted[4]), "split vertices stay together: %s %s" % [lifted[1], lifted[4]])
	assert_true(lifted[1].y > 0.0 and lifted[1].x > 1.0, "pushed along both faces' normals: %s" % lifted[1])
	scene.free()


func test_skips_skinned_and_morphed_meshes() -> void:
	var scene := Node3D.new()
	_instance(scene, _strip(0, 8), "Body")
	var overlay := _strip(2, 2)
	var overlay_node := _instance(scene, overlay, "Overlay")
	overlay_node.skin = Skin.new()
	assert_eq(CoincidentSurfaces.separate(scene), 0, "a skinned mesh moves with its bones")
	assert_eq(_vertices(overlay)[0], Vector3(2, 0, 0), "untouched")
	scene.free()
