extends Node3D

const PhMapDoc := preload("ph_map_doc.gd")
const PhMaterials := preload("ph_materials.gd")
const PhProps := preload("ph_props.gd")

## A map document, built: the building, the furniture, the lights and the sky.
##
## [b]The same document on every machine, and a server builds only what collides.[/b] Boxes
## become one static body of box shapes on the world layer; props become one static body of
## box shapes on the prop layer, each shape knowing which prop it is. A client also draws them.
## A server draws nothing, so a dedicated server holds a few thousand shapes and no meshes.
##
## [b]Boxes are drawn batched, by material and by twelve-metre chunk.[/b] A school is a
## thousand boxes, and a mesh per box is a thousand draw calls, which a browser does not give
## you. One mesh per material is the other extreme and is wrong for a reason only the renderer
## knows: the compatibility renderer the shell uses lights each mesh with at most eight omni
## lights, so one floor mesh for the whole school would be lit by eight of its forty lamps and
## every other room would be dark. A chunk is about a room, which is about a lamp.
##
## [b]Props are drawn as [MultiMeshInstance3D]s, one per model mesh.[/b] Two hundred chairs are
## one draw call per chair mesh, not two hundred. They never move: a prop a player is hiding AS
## is the player, drawn by [PhPlayer]; the props here are the room.
##
## [b]A prop's collision is its catalogue pieces (or its box), turned the way the map turns
## it.[/b] A tree is its trunk, branch stubs and leaf clumps, a table its top and legs (dot-props'
## [DotPropPieces], measured offline into `props/pieces.json`). What a hunter's shot stops on and
## what a player walks into are the same shapes, so the two can never disagree about where the
## sofa is; what a disguise copies is still the prop's size.

const CHANNEL := "ph.map"

const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"

## Metres of world one batched mesh covers. See the class notes.
const CHUNK := 12.0

## A shot's impact closer than this to a prop's box counts as hitting it: a bullet stops on the
## surface, and a point exactly on a face is outside a strict test half the time.
const HIT_MARGIN := 0.06

signal built()

var physics: DotPhysicsLayout = null

## The catalogue every prop's size and model come from.
var catalogue: PhProps = null

## Whether this machine draws anything: a client does, a server does not.
var draw_world: bool = false

## The normalised document this was built from.
var doc: Dictionary = {}

## Every prop in the map: `{id, transform, size, shapes, broken}`. The transform's origin is the
## middle of the prop's footprint on the floor.
var props: Array[Dictionary] = []

## Prop index -> where it is drawn: `[[MultiMesh, instance, Transform3D], ...]`, or a stand-in
## node. What [method break_prop] hides and [method restore_all] puts back.
var _drawn_at: Dictionary = {}

## The map's toys (dot-props' [DotPropToyBox]): loose ones only on this game's maps (barrels,
## tyres, balls, pins), simulated where [member authoritative], posed from snapshots elsewhere,
## under the game's `sv_toys*` [member toy_rules]. Set by the game before it builds.
var toys: DotPropToyBox = null
var authoritative: bool = true
var toy_rules: DotPropToyRules = null
var gravity: float = 20.0

var _solid: StaticBody3D = null
var _furniture: StaticBody3D = null
var _drawn: Node3D = null
## The boxes the contact shade is built from, gathered by the box and furniture builders.
var _shade_boxes: Array = []
var _environment: WorldEnvironment = null

## Source units to metres, which dot-lighting's fog distances are written in.
const METRES_PER_UNIT := 0.01905
var _sun: DirectionalLight3D = null
var _bounds: AABB = AABB()
var _missing: PackedStringArray = PackedStringArray()


func id() -> StringName:
	return StringName(str(doc.get("id", "")))


## Builds [param p_doc], which [PhMapDoc.validate] has already normalised.
func build(p_doc: Dictionary) -> DotResult:
	clear()
	doc = p_doc

	_solid = StaticBody3D.new()
	_solid.name = "Solid"
	add_child(_solid)
	_put_on(_solid, &"world")

	_furniture = StaticBody3D.new()
	_furniture.name = "Furniture"
	add_child(_furniture)
	_put_on(_furniture, &"prop")

	if draw_world:
		_drawn = Node3D.new()
		_drawn.name = "Drawn"
		add_child(_drawn)

	_build_boxes()
	_build_props()
	_add_contact_shade(_shade_boxes)
	_shade_boxes = []
	_build_toys()

	if draw_world:
		_build_lights()
		_build_environment()

	if not _missing.is_empty():
		DotLog.warn(CHANNEL, "a map names props this server's catalogue does not have; they are left out", {
			"map": String(id()), "missing": ", ".join(_missing),
		})

	DotLog.debug(CHANNEL, "built a map", {
		"id": String(id()), "boxes": (doc["boxes"] as Array).size(), "props": props.size(),
	})
	built.emit()
	return DotResult.success(null)


## The toys, on their own layer: a loose one (a barrel, a ball) on `toy`, which the world, the
## furniture and other toys stop and a survivor or a zombie never does (they walk through it,
## and a survivor pushes it, `ZzGame._advance_toys`).
func _build_toys() -> void:
	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.draw = draw_world
	if toy_rules != null:
		toys.rules = toy_rules
	toys.gravity = gravity
	toys.kill_y = kill_height()
	if physics != null:
		toys.loose_layer = physics.layer_mask(&"toy")
		toys.loose_mask = physics.collision_mask(&"toy")
		toys.solid_layer = physics.layer_mask(&"prop")
		toys.solid_mask = physics.collision_mask(&"prop")
		toys.footprint_layer = physics.layer_mask(&"footprint")
		toys.aim_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop") | physics.layer_mask(&"toy")
	add_child(toys)
	var built := toys.build(doc.get("toys", []))
	if not built.ok:
		DotLog.warn(CHANNEL, "a map's toys would not build", {"map": String(id()), "why": built.error.message})


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	props.clear()
	_drawn_at.clear()
	_missing.clear()
	_bounds = AABB()
	toys = null
	_solid = null
	_furniture = null
	_drawn = null
	_environment = null
	_sun = null


func _put_on(body: CollisionObject3D, layer: StringName) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, layer)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a map body could not be put on its layer", {"layer": String(layer)})


# --- Building --------------------------------------------------------------

func _build_boxes() -> void:
	var batches := {}
	var any := false
	for box: Dictionary in doc["boxes"]:
		var size := PhMapDoc.v3(box["size"])
		var at := PhMapDoc.v3(box["at"])
		var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(float(box.get("yaw", 0.0)))), at)

		var corner := AABB(at - size * 0.5, size)
		_bounds = corner if not any else _bounds.merge(corner)
		any = true

		if bool(box.get("solid", true)):
			var shape := CollisionShape3D.new()
			var cube := BoxShape3D.new()
			cube.size = size
			shape.shape = cube
			shape.transform = frame
			# What a footstep on it sounds like (dot-audio's DotAudioFootsteps reads the hit
			# shape's meta; "wood_floor", "tile_small" and the rest fold onto its surfaces).
			shape.set_meta(&"surface", str(box.get("mat", "")))
			_solid.add_child(shape)

		if not draw_world or not bool(box.get("visible", true)):
			continue

		var tint := PhMapDoc.colour(box.get("tint", [1, 1, 1]))
		var cell := Vector2i(floori(at.x / CHUNK), floori(at.z / CHUNK))
		# Seen and not hit (a line on the floor, glass painted on, a lamp) is batched apart from
		# the solid boxes, so the whole chunk can say it is meant to be walked through.
		var ghost := not bool(box.get("solid", true))
		var key := "%s|%s|%d|%d|%s" % [str(box["mat"]), tint.to_html(), cell.x, cell.y, ghost]

		if not batches.has(key):
			var tool := SurfaceTool.new()
			tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			batches[key] = {"tool": tool, "mat": str(box["mat"]), "tint": tint, "ghost": ghost}

		_add_box((batches[key] as Dictionary)["tool"], frame, size)
		if not PhMaterials.is_transparent(str(box["mat"])):
			_shade_boxes.append({"transform": frame, "size": size})

	for key: String in batches:
		var batch: Dictionary = batches[key]
		var tool: SurfaceTool = batch["tool"]
		var mesh := MeshInstance3D.new()
		mesh.name = "Boxes"
		# dot-core's DotCollisionAudit: a chunk of `"solid": false` boxes is decoration by the
		# map's own say-so.
		if bool(batch["ghost"]):
			mesh.set_meta(&"dot_no_collision", true)
		mesh.mesh = tool.commit()
		mesh.material_override = PhMaterials.material(batch["mat"], batch["tint"])
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
			if PhMaterials.is_transparent(batch["mat"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_drawn.add_child(mesh)


## Whether map furniture [param prop_id] casts a contact shade: only a furniture-kit block (a
## cabinet, a counter, a fridge, a bookcase, a washer) that collides as its box, never breaks and
## stands upright. Its box is then its shape, so the shade is where its foot is, and the shade can
## never outlive it. A piece-built prop (a chair, a table, a tree) is open underneath and its
## box would shade floor that is lit; a breakable one would leave its shade behind when it broke
## (the shade is one mesh, built at load). See docs/drawing.md#contact-shade.
func _shades_floor(prop_id: StringName, raw: Dictionary) -> bool:
	if catalogue == null or not catalogue.pieces_of(prop_id).is_empty() or catalogue.breaks(prop_id) > 0.0:
		return false
	if str(catalogue.entry(prop_id).get("kit", "")) != "furniture":
		return false
	return is_zero_approx(float(raw.get("pitch", 0.0))) and is_zero_approx(float(raw.get("roll", 0.0)))


## dot-lighting's contact shade (API 4) where a box meets the floor, a wall or another box: the
## Compatibility renderer has no ambient occlusion, and a counter or a wall met the floor with
## no shade at its foot. Glass and water neither cast nor take one. By path, behind the level,
## so a client shell older than the helper still runs the map without it.
func _add_contact_shade(boxes: Array) -> void:
	if boxes.is_empty() or DotAddonApi.build_level("dot_lighting") < 4 or not ResourceLoader.exists(CONTACT_SHADE_SCRIPT):
		return
	var shade: Variant = (load(CONTACT_SHADE_SCRIPT) as GDScript).call(&"node", boxes)
	if shade is MeshInstance3D and (shade as MeshInstance3D).mesh != null:
		_drawn.add_child(shade)
	elif shade is Node:
		(shade as Node).free()


## Six faces of a box, outward normals, into [param tool]. No UVs: every surface material is
## mapped in world space.
static func _add_box(tool: SurfaceTool, frame: Transform3D, size: Vector3) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3.RIGHT, Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.LEFT, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)],
		[Vector3.UP, Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z)],
		[Vector3.DOWN, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.BACK, Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z)],
		[Vector3.FORWARD, Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z)],
	]

	for face: Array in faces:
		var normal: Vector3 = frame.basis * (face[0] as Vector3)
		var a: Vector3 = frame * (face[1] as Vector3)
		var b: Vector3 = frame * (face[2] as Vector3)
		var c: Vector3 = frame * (face[3] as Vector3)
		var d: Vector3 = frame * (face[4] as Vector3)

		# Godot's front face winds so that (b - a) x (c - a) points AGAINST the normal (measured
		# against BoxMesh's own arrays). The corners above go round the other way, so each
		# triangle is emitted reversed; the other order is a map drawn inside out, every wall
		# invisible from the room it bounds.
		for v: Vector3 in [a, c, b, a, d, c]:
			tool.set_normal(normal)
			tool.add_vertex(v)


func _build_props() -> void:
	var by_id := {}

	for raw: Dictionary in doc["props"]:
		var prop_id := StringName(str(raw["id"]))

		if catalogue == null or not catalogue.has(prop_id):
			if not _missing.has(String(prop_id)):
				_missing.append(String(prop_id))
			continue

		var size := catalogue.size_of(prop_id)
		var basis := Basis.from_euler(Vector3(
			deg_to_rad(float(raw.get("pitch", 0.0))),
			deg_to_rad(float(raw.get("yaw", 0.0))),
			deg_to_rad(float(raw.get("roll", 0.0)))
		), EULER_ORDER_YXZ)
		var frame := Transform3D(basis, PhMapDoc.v3(raw["at"]))

		# Its pieces (a tree's trunk, branches and clumps), or its box when it has none.
		var shapes: Array = []

		for part: Array in catalogue.shapes_of(prop_id):
			var shape := CollisionShape3D.new()
			shape.shape = part[0]
			shape.transform = frame * (part[1] as Transform3D)
			shape.set_meta(&"ph_prop", props.size())
			_furniture.add_child(shape)
			shapes.append(shape)

		props.append({"id": prop_id, "transform": frame, "size": size, "shapes": shapes, "broken": false})

		if draw_world and _shades_floor(prop_id, raw):
			# Its box casts and takes none: bands on a cabinet's own sides would float off its model.
			_shade_boxes.append({"transform": frame.translated_local(Vector3(0.0, size.y * 0.5, 0.0)),
				"size": size, "casts": true, "shaded": false})

		if draw_world:
			if not by_id.has(prop_id):
				by_id[prop_id] = []
			(by_id[prop_id] as Array).append([frame, props.size() - 1])

	if not draw_world:
		return

	for prop_id: StringName in by_id:
		var frames: Array = by_id[prop_id]
		var parts := catalogue.parts(prop_id)

		if parts.is_empty():
			for placed: Array in frames:
				var stand_in := catalogue.instance(prop_id)
				stand_in.transform = placed[0]
				_drawn.add_child(stand_in)
				_drawn_at[int(placed[1])] = stand_in
			continue

		for part: Array in parts:
			var multi := MultiMesh.new()
			multi.transform_format = MultiMesh.TRANSFORM_3D
			multi.mesh = part[0]
			multi.instance_count = frames.size()

			for i in range(frames.size()):
				var placed: Array = frames[i]
				var at := (placed[0] as Transform3D) * (part[1] as Transform3D)
				multi.set_instance_transform(i, at)
				if not _drawn_at.has(int(placed[1])):
					_drawn_at[int(placed[1])] = []
				(_drawn_at[int(placed[1])] as Array).append([multi, i, at])

			var drawn := MultiMeshInstance3D.new()
			drawn.name = "Props_%s" % String(prop_id)
			drawn.multimesh = multi
			_drawn.add_child(drawn)


func _build_lights() -> void:
	for light: Dictionary in doc["lights"]:
		var omni := OmniLight3D.new()
		omni.position = PhMapDoc.v3(light["at"])
		omni.omni_range = float(light["range"])
		omni.light_energy = float(light["energy"])
		omni.light_color = PhMapDoc.colour(light["colour"])
		omni.omni_attenuation = 1.2
		omni.shadow_enabled = false
		_drawn.add_child(omni)


## The sky and the sun: a dot-lighting document made from the map's `environment`
## ([method light_document]), so every map has the family's light (game-arena's built-in maps:
## a warm sun with soft shadows, a pale cool fill, filmic tone map, glow) while keeping its
## own sun angle, sun colour and sky: the woods are still golden hour and the office still
## late afternoon.
func _build_environment() -> void:
	var env_doc: Dictionary = doc["environment"]
	var lighting := Node3D.new()
	lighting.name = "Lighting"
	add_child(lighting)
	_sun = DotLightRig.apply(lighting, DotLightDocument.from_dictionary(light_document(env_doc)),
		light_profile(float(env_doc["ambient_energy"])))

	if _sun != null:
		# The map's own angle, in Godot's degrees as the map document has always written it,
		# rather than through dot-lighting's source convention.
		_sun.rotation_degrees = Vector3(float(env_doc["sun_pitch"]), float(env_doc["sun_yaw"]), 0.0)
		# The rig aimed its fill opposite the sun it was given; turned with the sun here, or it
		# lights the faces the sun already does.
		var fill := lighting.get_node_or_null("Fill") as DirectionalLight3D
		if fill != null:
			var aimed := DotLightRig.fill(DotLightDocument.from_dictionary(light_document(env_doc)), _sun.rotation,
				light_profile(float(env_doc["ambient_energy"])))
			fill.rotation = aimed.rotation
			aimed.free()
		_sun.shadow_blur = 1.5
		_sun.directional_shadow_max_distance = 60.0

	for node in lighting.get_children():
		if node is WorldEnvironment:
			_environment = node as WorldEnvironment
			var sky := (node as WorldEnvironment).environment.sky
			if sky != null and sky.sky_material is ProceduralSkyMaterial:
				# The map's blue at the zenith (the rig draws it in the ambient colour, a grey
				# chosen for the shade) and again under the horizon, where an overview used to
				# see a dark void round the map.
				var material := sky.sky_material as ProceduralSkyMaterial
				material.sky_top_color = PhMapDoc.colour(env_doc["sky_top"])
				material.ground_bottom_color = material.sky_top_color


## The dot-lighting document a map's `environment` describes.
##
## Brightness is 380 (game-arena's daylight) times the square of the map's `sun_energy`, so a
## map that asked for a dimmer sun still gets one. The ambient is the light in the shade, a
## near-neutral pale grey whatever the map, at the map's strength ([method light_profile]):
## game-arena's pale cool fill turned every room, which is lit mostly by the fill, a cold
## lavender; the map's own `ambient` colour is mixed in a quarter of the way, so a map lit by a
## blue sky is a little cooler in its shade and one lit by a night is not grey. The fog is the
## map's own when it has `fog_end` (colour, start and end in metres, a density cap), else its
## horizon from 120 m out (source units, metres / 0.01905), so it hazes the distance and never
## a room; the map's old `fog` density is no longer read.
static func light_document(env_doc: Dictionary) -> Dictionary:
	var sun := PhMapDoc.colour(env_doc["sun_colour"])
	var horizon := PhMapDoc.colour(env_doc["sky_horizon"])
	var energy := float(env_doc["sun_energy"])
	var shade := Color(0.86, 0.86, 0.90).lerp(PhMapDoc.colour(env_doc["ambient"], Color(0.86, 0.86, 0.90)), 0.25)
	var fog := {
		"enabled": true,
		"colour": [horizon.r, horizon.g, horizon.b],
		"start": 6300.0,
		"end": 40000.0,
		"max_density": 0.25,
	}

	if env_doc.has("fog_end"):
		var fog_colour := PhMapDoc.colour(env_doc["fog_colour"], horizon)
		fog = {
			"enabled": true,
			"colour": [fog_colour.r, fog_colour.g, fog_colour.b],
			"start": float(env_doc["fog_start"]) / METRES_PER_UNIT,
			"end": float(env_doc["fog_end"]) / METRES_PER_UNIT,
			"max_density": float(env_doc["fog_max"]),
		}

	return {
		"sun": {
			"colour": [sun.r, sun.g, sun.b],
			"brightness": 380.0 * energy * energy,
			"spread_degrees": 1.0,
			"ambient_colour": [shade.r, shade.g, shade.b],
		},
		"fog": fog,
	}


## What this machine draws of a map's light: dot-lighting's `painted()`, with the map's fill.
##
## [b]Shadows stay on in the browser[/b], unlike dot-lighting's `web()`: a prop's shadow is
## part of what a hunter reads, and the boxes are batched into a few dozen meshes.
## `painted()` is the family's profile for flat-painted worlds (dot-lighting API 3): its light
## is matched to the renderer (the Compatibility renderer this game and the client shell use
## clips a sunlit pastel to white at Forward+'s numbers), with a lower exposure, a grade, and
## a shadowless fill from the side the sun is not on. That fill has no shadow, so it reaches
## into rooms as the ambient does, but from one side: a room's walls are different shades
## instead of one even haze, which is where a prop hides.
##
## [b]The ambient is the map's `ambient_energy` times 4 of `painted()`'s, the fill times
## 2.8[/b] (2 and 1.4 at the stock 0.5): a room is lit by the fill and its lamps, not the
## sun, and these keep a room as light as it was before `painted()` (a school corridor's
## median 0.63 -> 0.62) while the yard outside loses its glare.
static func light_profile(ambient_energy: float = 0.5) -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	p.sky_below_horizon = true
	p.ambient_energy *= ambient_energy * 4.0
	p.fill_energy *= ambient_energy * 2.8
	# Less contrast than painted()'s 1.12: the grade pivots at mid grey, and Kenney's dark
	# trunks, pines and furniture in shade went to black at 1.12 (2 % of a woods frame).
	p.contrast = 1.04
	# Glow only from what is brighter than white (the lamps), not from every pale wall: at
	# dot-lighting's 0.85 a room of near-white pastels glowed into one milky veil.
	p.glow_threshold = 1.0
	return p


# --- Asking ----------------------------------------------------------------

## Where seat [param seat] of [param of] on [param side] (`"props"` or `"hunters"`) starts:
## `[position, yaw]`. More people than spawns stand in rings round them, a metre and a bit
## apart, so nobody starts inside anybody else.
func spawn(side: String, seat: int) -> Array:
	var list: Array = (doc.get("spawns", {}) as Dictionary).get(side, [])

	if list.is_empty():
		return [Vector3(0.0, 1.0, 0.0), 0.0]

	var base: Dictionary = list[seat % list.size()]
	var lap := seat / list.size()
	var at := PhMapDoc.v3(base["at"])

	if lap > 0:
		var angle := float(lap) * 2.39996
		at += Vector3(cos(angle), 0.0, sin(angle)) * (1.1 * ceilf(float(lap) / 6.0))

	return [at, float(base.get("yaw", 0.0))]


func kill_height() -> float:
	return float(doc.get("kill_y", -30.0))


func bounds() -> AABB:
	return _bounds


## Which prop a physics query hit, from the collider and the shape index it reported; -1 for
## anything that is not a prop.
func prop_from_hit(collider: Object, shape_index: int) -> int:
	if collider == null or collider != _furniture:
		return -1

	var owner_id := _furniture.shape_find_owner(shape_index)
	var node := _furniture.shape_owner_get_owner(owner_id) as Node

	if node == null or not node.has_meta(&"ph_prop"):
		return -1

	return int(node.get_meta(&"ph_prop"))


## Which prop [param point] is on, within [constant HIT_MARGIN]: a hunter's shot that stopped
## on a decoy. -1 for none.
func prop_containing(point: Vector3) -> int:
	for index in range(props.size()):
		var prop: Dictionary = props[index]
		if bool(prop["broken"]):
			continue
		var size: Vector3 = prop["size"]
		var local: Vector3 = (prop["transform"] as Transform3D).affine_inverse() * point
		var half := size * 0.5 + Vector3.ONE * HIT_MARGIN
		var pieces := catalogue.pieces_of(prop["id"]) if catalogue != null else []

		# A shot through the gap under a tree's leaves hit no furniture, so it is no decoy.
		if not pieces.is_empty():
			if DotPropPieces.contains(pieces, local, HIT_MARGIN):
				return index
			continue

		if absf(local.x) <= half.x and local.y >= -HIT_MARGIN and local.y <= size.y + HIT_MARGIN \
				and absf(local.z) <= half.z:
			return index

	return -1


## The point of prop [param index]'s box nearest [param point], in the world: what a blast at
## [param point] reaches first. Its box, not its pieces: a blast fills the gap under a table.
func nearest_on_prop(index: int, point: Vector3) -> Vector3:
	var prop: Dictionary = props[index]
	var size: Vector3 = prop["size"]
	var frame: Transform3D = prop["transform"]
	var local: Vector3 = frame.affine_inverse() * point
	var half := size * 0.5
	local = Vector3(clampf(local.x, -half.x, half.x), clampf(local.y, 0.0, size.y), clampf(local.z, -half.z, half.z))
	return frame * local


## Every unbroken prop whose box comes within [param radius] of [param point], nearest first.
func props_near(point: Vector3, radius: float) -> Array[int]:
	var found: Array[int] = []
	var distances := {}
	for index in range(props.size()):
		if bool(props[index]["broken"]):
			continue
		var d := nearest_on_prop(index, point).distance_to(point)
		if d <= radius:
			found.append(index)
			distances[index] = d
	found.sort_custom(func(a: int, b: int) -> bool: return float(distances[a]) < float(distances[b]))
	return found


## Breaks prop [param index]: nothing collides with it or draws it until [method restore_all].
## False when it was already broken or there is no such prop. Whether it MAY break is the
## game's (the catalogue's `breaks`).
func break_prop(index: int) -> bool:
	if index < 0 or index >= props.size() or bool(props[index]["broken"]):
		return false

	props[index]["broken"] = true

	for shape: CollisionShape3D in props[index]["shapes"]:
		shape.disabled = true

	var drawn: Variant = _drawn_at.get(index)

	if drawn is Node3D:
		(drawn as Node3D).visible = false
	elif drawn is Array:
		for entry: Array in drawn:
			var at: Transform3D = entry[2]
			(entry[0] as MultiMesh).set_instance_transform(int(entry[1]), Transform3D(Basis().scaled(Vector3.ZERO), at.origin))

	return true


## Every broken prop whole again: a new round.
func restore_all() -> void:
	for index in range(props.size()):
		if not bool(props[index]["broken"]):
			continue

		props[index]["broken"] = false

		for shape: CollisionShape3D in props[index]["shapes"]:
			shape.disabled = false

		var drawn: Variant = _drawn_at.get(index)

		if drawn is Node3D:
			(drawn as Node3D).visible = true
		elif drawn is Array:
			for entry: Array in drawn:
				(entry[0] as MultiMesh).set_instance_transform(int(entry[1]), entry[2])


func broken_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	for index in range(props.size()):
		if bool(props[index]["broken"]):
			out.append(index)
	return out


## The meshes prop [param index] is drawn with, each `[Mesh, Transform3D]` in the world: what
## its debris is made of. Empty on a server.
func drawn_parts(index: int) -> Array:
	var out: Array = []
	var drawn: Variant = _drawn_at.get(index)
	if drawn is Array:
		for entry: Array in drawn:
			out.append([(entry[0] as MultiMesh).mesh, entry[2]])
	return out


func prop_id(index: int) -> StringName:
	return (props[index] as Dictionary)["id"] if index >= 0 and index < props.size() else &""


## A camera for watching the whole map from above, for somebody with nobody left to watch.
func overview() -> Transform3D:
	var centre := _bounds.get_center()
	var reach := maxf(_bounds.size.length() * 0.45, 12.0)
	var eye := centre + Vector3(reach * 0.5, reach * 0.55, reach * 0.5)
	return Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"map        %s (%s)" % [str(doc.get("name", "")), String(id())],
		"boxes      %d" % (doc.get("boxes", []) as Array).size(),
		"props      %d" % props.size(),
		"lights     %d" % (doc.get("lights", []) as Array).size(),
	])
