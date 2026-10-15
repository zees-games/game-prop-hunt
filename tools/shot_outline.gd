extends RefCounted

## Draws a movement hull and hitboxes as see-through shapes over a body, for a screenshot that
## compares what is collided with what is drawn. Drawn on top (no depth test) so a hull inside the
## body still shows; translucent so the body still shows through it. Tools only, never shipped.


## The movement capsule: [param radius] wide, [param height] tall, feet at [param feet].
static func hull(parent: Node, feet: Vector3, radius: float, height: float) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = maxf(height, radius * 2.0)
	var shape := _shape(parent, mesh, Color(0.1, 1.0, 0.2, 0.22))
	shape.global_position = feet + Vector3(0.0, mesh.height * 0.5, 0.0)
	return shape


## One [DotHitbox] where it is now.
static func hitbox(parent: Node, box: DotHitbox) -> MeshInstance3D:
	var mesh: PrimitiveMesh = null
	match box.shape:
		DotHitbox.Shape.CAPSULE:
			var capsule := CapsuleMesh.new()
			capsule.radius = box.radius
			capsule.height = maxf(box.height, box.radius * 2.0)
			mesh = capsule
		DotHitbox.Shape.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = box.radius
			sphere.height = box.radius * 2.0
			mesh = sphere
		_:
			var cube := BoxMesh.new()
			cube.size = box.half_extents * 2.0
			mesh = cube
	var shape := _shape(parent, mesh, Color(1.0, 0.15, 0.1, 0.22))
	shape.global_transform = box.global_transform
	return shape


static func _shape(parent: Node, mesh: Mesh, colour: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = colour
	var shape := MeshInstance3D.new()
	shape.mesh = mesh
	shape.material_override = material
	shape.top_level = true
	parent.add_child(shape)
	return shape
