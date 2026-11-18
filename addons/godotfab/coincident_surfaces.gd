@tool
extends RefCounted
## Separates meshes modelled on top of each other. A part made by duplicating
## faces of another one sits exactly on it: both surfaces have the same depth
## and flicker through each other (z-fighting). A path tracer hides it, a
## rasterizer does not.
##
## A mesh with a good share of its triangles on the vertices of another mesh
## is pushed out along its normals, by a distance too small to see. Runs on
## the scene as the format loader made it (ImporterMeshInstance3D nodes), so
## the LODs and shadow meshes are generated from the separated geometry.
## Headless-safe and static; FbxPostImport calls it from the import.

## Share of a mesh's triangles that must lie on the other mesh.
const MIN_SHARE := 0.1
## How close two vertices are the same one, as a part of the other mesh's size.
const TOLERANCE := 1e-5
## How far the mesh is pushed out, as a part of the size of the pair.
const OFFSET := 5e-4


## Pushes out the meshes of `scene` that lie on another; returns how many.
static func separate(scene: Node) -> int:
	var items := _items(scene)
	items.sort_custom(func(a, b): return a.box.position.x < b.box.position.x)
	var pushes := {}
	for i in items.size():
		var a: Dictionary = items[i]
		for j in range(i + 1, items.size()):
			var b: Dictionary = items[j]
			if b.box.position.x > a.box.end.x:
				break
			if a.mesh == b.mesh or not a.box.intersects(b.box):
				continue
			var a_on_b := _share(a, b)
			var b_on_a := _share(b, a)
			if max(a_on_b, b_on_a) < MIN_SHARE:
				continue
			# The mesh lying on the other is the one with more of itself there;
			# of two copies of the same faces, the later in the scene.
			var a_is_shell: bool = a_on_b > b_on_a or (a_on_b == b_on_a and a.order > b.order)
			var shell := i if a_is_shell else j
			var distance: float = a.box.merge(b.box).get_longest_axis_size() * OFFSET
			pushes[shell] = max(pushes.get(shell, 0.0), distance)
	var done := {}
	for index in pushes:
		var item: Dictionary = items[index]
		if not done.has(item.mesh):
			done[item.mesh] = true
			_push(item.mesh, pushes[index] / item.scale)
	return done.size()


## One entry per static mesh of the scene, in scene coordinates: {mesh,
## order, scale, points, indices (triangles), box, cell}. Skinned and morphed
## meshes are left out: they don't stay where the file puts them.
static func _items(scene: Node) -> Array:
	var out := []
	var nodes: Array[Node] = [scene]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		nodes.append_array(node.get_children())
		var instance := node as ImporterMeshInstance3D
		if instance == null or instance.mesh == null or instance.skin != null or instance.mesh.get_blend_shape_count() > 0:
			continue
		var xform := _scene_transform(instance)
		var points := PackedVector3Array()
		var indices := PackedInt32Array()
		for surface in instance.mesh.get_surface_count():
			if instance.mesh.get_surface_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := instance.mesh.get_surface_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var base := points.size()
			var surface_indices = arrays[Mesh.ARRAY_INDEX]
			if surface_indices is PackedInt32Array and not surface_indices.is_empty():
				for index in surface_indices:
					indices.append(base + index)
			else:
				for index in vertices.size():
					indices.append(base + index)
			points.append_array(xform * vertices)
		if indices.size() < 3:
			continue
		var box := AABB(points[0], Vector3.ZERO)
		for point in points:
			box = box.expand(point)
		# Vertices further apart than the coordinates can tell are the same too.
		var reach: float = max(box.position.abs()[box.position.abs().max_axis_index()], box.end.abs()[box.end.abs().max_axis_index()])
		var cell: float = max(box.get_longest_axis_size() * TOLERANCE, reach * 1e-6)
		var scale := xform.basis.get_scale().abs()
		out.append({"mesh": instance.mesh, "order": out.size(), "scale": max((scale.x + scale.y + scale.z) / 3.0, 1e-9), "points": points, "indices": indices, "box": box.grow(cell), "cell": cell})
	# Children were visited last to first: number the meshes in scene order.
	out.reverse()
	for i in out.size():
		out[i].order = i
	return out


## The node's transform in the scene, which is not in the tree during the import.
static func _scene_transform(node: Node3D) -> Transform3D:
	var xform := node.transform
	var parent := node.get_parent()
	while parent is Node3D:
		xform = parent.transform * xform
		parent = parent.get_parent()
	return xform


## Share of the triangles of `shell` whose three vertices are vertices of `body`.
static func _share(shell: Dictionary, body: Dictionary) -> float:
	if not body.has("cells"):
		var cells := {}
		for point in body.points:
			cells[Vector3i(((point - body.box.position) / body.cell).floor())] = true
		body["cells"] = cells
	var cells: Dictionary = body.cells
	var box: AABB = body.box
	var points: PackedVector3Array = shell.points
	var on_body := PackedByteArray()
	on_body.resize(points.size())
	for i in points.size():
		if box.has_point(points[i]) and _has_vertex_near(cells, (points[i] - box.position) / body.cell):
			on_body[i] = 1
	var indices: PackedInt32Array = shell.indices
	var count := 0
	for t in range(0, indices.size() - 2, 3):
		if on_body[indices[t]] and on_body[indices[t + 1]] and on_body[indices[t + 2]]:
			count += 1
	return float(count) / float(indices.size() / 3)


## True when a cell around the nearest cell corner holds a vertex: every
## vertex within half a cell of `at` (in cells) is in one of the eight.
static func _has_vertex_near(cells: Dictionary, at: Vector3) -> bool:
	var corner := Vector3i(at.round())
	for x in 2:
		for y in 2:
			for z in 2:
				if cells.has(corner - Vector3i(x, y, z)):
					return true
	return false


## Moves the vertices of the mesh along their normals, `distance` in its own
## units. Vertices at one position (split by a hard edge or a UV seam) move
## together, along the sum of their normals, so no gap opens.
static func _push(mesh: ImporterMesh, distance: float) -> void:
	var surfaces := []
	var directions := {}
	for i in mesh.get_surface_count():
		var arrays := mesh.get_surface_arrays(i)
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var pushed: bool = mesh.get_surface_primitive_type(i) == Mesh.PRIMITIVE_TRIANGLES and normals is PackedVector3Array and normals.size() == vertices.size()
		if pushed:
			for v in vertices.size():
				directions[vertices[v]] = directions.get(vertices[v], Vector3.ZERO) + normals[v]
		surfaces.append({"primitive": mesh.get_surface_primitive_type(i), "arrays": arrays, "pushed": pushed, "material": mesh.get_surface_material(i), "name": mesh.get_surface_name(i), "flags": mesh.get_surface_format(i)})
	mesh.clear()
	for surface in surfaces:
		if surface.pushed:
			var vertices: PackedVector3Array = surface.arrays[Mesh.ARRAY_VERTEX]
			for v in vertices.size():
				var at := vertices[v]
				vertices[v] = at + (directions[at] as Vector3).normalized() * distance
			surface.arrays[Mesh.ARRAY_VERTEX] = vertices
		mesh.add_surface(surface.primitive, surface.arrays, [], {}, surface.material, surface.name, surface.flags)
