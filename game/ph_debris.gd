extends Node3D

## A piece of furniture shot to bits: its own meshes as loose pieces, and a handful of chips in
## its colour, thrown away from the shot and gone after a few seconds. Drawn only (a client),
## never on a server.
##
## [b]Its own meshes, not a generic burst.[/b] A bottle's pieces are a bottle's glass and label;
## a lamp's its shade and stand. Kenney's models are a few meshes each, which is a few pieces.
## [b]They collide with the building and nothing else[/b] (the world layer only): a piece a
## player could stand on or push about would be a piece the server does not know of, and the
## decoy check reads the furniture the server built, never this.

const LIFETIME := 4.0
const CHIPS := 7

## Seconds over which the thrown pieces shrink to nothing: 0 (furniture) keeps them whole to
## the end. A found player's prop pops (`PhClient._burst_prop`): most of Kenney's furniture is
## one mesh, and one whole bookcase thrown is a bookcase knocked over, not a player found.
var pop_seconds: float = 0.0

## How many chips a burst throws.
var chips: int = CHIPS

var _left := LIFETIME
var _bodies: Array[RigidBody3D] = []
var _pieces: Array[MeshInstance3D] = []
var _age := 0.0


## Throws [param parts] (`[Mesh, Transform3D]` in the world) away from [param direction], and
## chips the size of a tenth of [param size] from [param centre]. [param world_mask] is the layer
## the pieces land on. [param seed_value] makes the throw the same for a replay.
func burst(parts: Array, centre: Vector3, size: Vector3, direction: Vector3, world_mask: int, seed_value: int) -> void:
	var rng := DotRandomStream.new(seed_value, &"ph_debris")
	var push := direction.normalized() if direction.length() > 0.01 else Vector3.UP
	var colour := Color(0.8, 0.8, 0.8)

	for part: Array in parts:
		var mesh: Mesh = part[0]
		var at: Transform3D = part[1]
		var body := _body(world_mask, mesh.get_aabb().size * at.basis.get_scale())
		var drawn := MeshInstance3D.new()
		drawn.mesh = mesh
		# The body's origin is the piece's middle; the mesh sits about it as it did.
		var middle := at * mesh.get_aabb().get_center()
		drawn.transform = Transform3D(at.basis, at.origin - middle)
		body.add_child(drawn)
		_pieces.append(drawn)
		add_child(body)
		body.global_position = middle
		body.linear_velocity = (push * 2.5 + Vector3(rng.next_range_f(-1.0, 1.0), rng.next_range_f(1.0, 3.0), rng.next_range_f(-1.0, 1.0)))
		body.angular_velocity = Vector3(rng.next_range_f(-6.0, 6.0), rng.next_range_f(-6.0, 6.0), rng.next_range_f(-6.0, 6.0))
		var material := mesh.surface_get_material(0) if mesh.get_surface_count() > 0 else null
		if material is BaseMaterial3D:
			colour = (material as BaseMaterial3D).albedo_color

	var chip_material := StandardMaterial3D.new()
	chip_material.albedo_color = colour
	var chip_size := Vector3.ONE * clampf(maxf(size.x, maxf(size.y, size.z)) * 0.12, 0.02, 0.12)

	for i in range(chips):
		var body := _body(world_mask, chip_size)
		var cube := BoxMesh.new()
		cube.size = chip_size * rng.next_range_f(0.5, 1.2)
		cube.material = chip_material
		var drawn := MeshInstance3D.new()
		drawn.mesh = cube
		body.add_child(drawn)
		add_child(body)
		body.global_position = centre + Vector3(rng.next_range_f(-0.5, 0.5) * size.x, rng.next_range_f(-0.3, 0.3) * size.y, rng.next_range_f(-0.5, 0.5) * size.z)
		body.linear_velocity = push * rng.next_range_f(1.5, 4.0) + Vector3(rng.next_range_f(-2.0, 2.0), rng.next_range_f(1.0, 4.0), rng.next_range_f(-2.0, 2.0))
		body.angular_velocity = Vector3(rng.next_range_f(-10.0, 10.0), rng.next_range_f(-10.0, 10.0), rng.next_range_f(-10.0, 10.0))


func _body(world_mask: int, size: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = world_mask
	body.mass = 0.2
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(size.x, 0.02), maxf(size.y, 0.02), maxf(size.z, 0.02))
	shape.shape = box
	body.add_child(shape)
	_bodies.append(body)
	return body


func _process(delta: float) -> void:
	_age += delta
	if pop_seconds > 0.0:
		var left := 1.0 - _age / pop_seconds
		for piece in _pieces:
			if is_instance_valid(piece):
				piece.visible = left > 0.0
				if left > 0.0:
					piece.scale = Vector3.ONE * maxf(left * left, 0.01)
	_left -= delta
	if _left <= 0.0:
		queue_free()
