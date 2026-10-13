extends Node3D

const PhProjectiles := preload("ph_projectiles.gd")

## Every grenade the world is flying, drawn. Client side; game-arena's `ArenaProjectileView`, copied.
##
## Reads the list the simulation advances (the world's own offline, the copies the server's
## LAUNCH events started online) once a frame and moves one node per entry; it writes nothing
## back, so dropping it changes no outcome. A grenade is its own model from zee-dot-weapons' art
## table, turned and scaled as the pack draws it in a hand, with a small red fuse light: rendered
## without one in the arena, a frag fourteen metres away was two brown pixels on the floor, and a
## grenade nobody sees is one nobody gets away from.

const ROUND_RADIUS := 0.11
const ROUND_COLOUR := Color(1.0, 0.62, 0.22)
const FUSE_COLOUR := Color(1.0, 0.18, 0.12)

## The layer whose list is drawn.
var projectiles: PhProjectiles = null

var _drawn: Dictionary = {}
var _round_mesh: SphereMesh = null
var _round_material: StandardMaterial3D = null


func _ready() -> void:
	# Top level, so the world's position is the only one.
	top_level = true


func _process(_delta: float) -> void:
	present()


## Moves every drawn node to where its entry is, adding and freeing as they come and go. Public
## so a suite can step it with no frame.
func present() -> void:
	var live: Array = projectiles.flying() if projectiles != null else []
	var seen := {}

	for f: PhProjectiles.Flying in live:
		seen[f] = true
		var node: Node3D = _drawn.get(f)

		if node == null:
			node = _make(f)
			add_child(node)
			_drawn[f] = node

		node.global_position = f.position

		# A grenade tumbles in the air, which is what a thrown thing does.
		if not f.resting:
			node.rotate_x(0.2)

	for f in _drawn.keys():
		if not seen.has(f):
			(_drawn[f] as Node3D).queue_free()
			_drawn.erase(f)


func drawn_count() -> int:
	return _drawn.size()


func clear() -> void:
	for node in _drawn.values():
		(node as Node3D).queue_free()
	_drawn.clear()


func _make(f: PhProjectiles.Flying) -> Node3D:
	var root := Node3D.new()
	root.name = "Grenade"

	var art: Variant = ZeeWeaponArtTable.table().get(f.spawn.id)

	if art is ZeeWeaponArt and (art as ZeeWeaponArt).has_model():
		var model := ZeeModelCache.instantiate((art as ZeeWeaponArt).model_path)

		if model != null:
			var placed := (art as ZeeWeaponArt).world_transform()
			placed.origin = Vector3.ZERO
			model.transform = placed
			root.add_child(model)
			root.add_child(_fuse_light())
			return root

	root.add_child(_round())
	return root


func _fuse_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "Fuse"
	light.light_color = FUSE_COLOUR
	light.light_energy = 2.2
	light.omni_range = 1.6
	light.position = Vector3(0.0, 0.15, 0.0)
	light.shadow_enabled = false
	return light


## A small hot sphere with a light: anything without a model.
func _round() -> Node3D:
	if _round_mesh == null:
		_round_mesh = SphereMesh.new()
		_round_mesh.radius = ROUND_RADIUS
		_round_mesh.height = ROUND_RADIUS * 2.0
		_round_material = StandardMaterial3D.new()
		_round_material.albedo_color = ROUND_COLOUR
		_round_material.emission_enabled = true
		_round_material.emission = ROUND_COLOUR
		_round_material.emission_energy_multiplier = 3.0
		_round_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var holder := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = _round_mesh
	mesh.material_override = _round_material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mesh)
	holder.add_child(_fuse_light())
	return holder
