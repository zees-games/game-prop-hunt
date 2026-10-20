extends Node

const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")

## Every map the game can be sent, built the way a server builds it and looked over for the
## mistakes a map document makes without any error: a spawn inside a wall or over nothing, a
## prop the catalogue does not have (built as nothing), a prop sunk into a wall or floating
## over the floor, too few things to hide as, and a document too big to send.
##
## [b]Why this exists apart from `headless_run`.[/b] The maps are generated in
## mg-prop-hunt-maps by `tools/build_maps.py`, a few hundred boxes and props each, and none of
## those mistakes stops a round: a prop floating a hand's width over a table is a prop every
## hunter shoots first, and a spawn inside a locker is a player stuck for the round. The
## renders find the ugly ones; this finds the rest, on every map, every time.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.
## Adding a map adds a section and CHECKS_PER_MAP checks.

const MAPS := ["ph_practice", "ph_school", "ph_house", "ph_office", "ph_woods", "ph_frontyard", "ph_office221", "ph_apartment", "ph_hotel", "ph_abandoned_church", "ph_abandoned_hotel", "ph_elementary_school", "ph_autumngetaway", "ph_bank", "ph_volcano", "ph_westerncity", "ph_gas_station", "ph_bikinibottom", "ph_swimmingpool", "ph_restaurant_os", "ph_oceanwaves", "ph_midwestapartment", "ph_cyber_dinner", "ph_islandhouse"]
const CHECKS_PER_MAP := 11

## The maps actually checked: all of MAPS, or only the practice house where `maps/` is not
## linked in (CI, which clones this repository alone). As mg-deathrun's headless_courses
## does: the delivered maps are checked wherever they are present, which is every machine
## that has run dot-bootstrap. Sections and checks are counted against this list.
var _maps: Array = []

## A person's capsule, for "is this spawn clear".
const RADIUS := 0.4
const HEIGHT := 1.8

## Fewest spawns of each kind a map may have: one per player up to these, laps after.
const MIN_PROP_SPAWNS := 6
const MIN_HUNTER_SPAWNS := 3

## Fewest different props a map must offer to hide as.
const MIN_WEARABLE := 8

## Furniture covered less than this by its own shapes is listed (see [method _partly_covered]).
const PARTIAL := 0.8

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("prophunt maps")
	print("")

	await _test_the_catalogue()

	for id: String in _maps:
		await _test_map(StringName(id))

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	var sections := 1 + _maps.size()
	var checks := 1 + CHECKS_PER_MAP * _maps.size()

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [_sections_finished, _sections_entered, sections])
		code = 1

	if _passed + _failed != checks or _maps.is_empty():
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	get_tree().quit(code)


func _test_the_catalogue() -> void:
	_section("the catalogue")
	var game := await _world(&"")
	var ids: Array = []

	for id: StringName in game.catalogue.maps:
		ids.append(String(id))

	ids.sort()
	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	_maps = MAPS.duplicate() if linked else ["ph_practice"]
	# `-- --map ph_x` audits one map: for a converted map while it is being tuned.
	var user_args := OS.get_cmdline_user_args()
	var only := user_args.find("--map")
	if linked and only >= 0 and only + 1 < user_args.size():
		_maps = [user_args[only + 1]]

	if not linked:
		print("(no map directory: the built-in practice house only)")

	var missing: Array = []

	for id: String in _maps:
		if not ids.has(id):
			missing.append(id)

	_check(missing.is_empty() and game.catalogue.refused.is_empty(),
		"every map is in it, and no file was refused", "have %s, missing %s, refused %s" % [ids, missing, game.catalogue.refused])
	await _dispose(game)
	_finished()


func _test_map(id: StringName) -> void:
	_section(String(id))
	var game := await _world(id)
	var doc := game.map_doc
	_check(str(doc.get("id", "")) == String(id), "it is the map that was built", str(doc.get("id", "")))

	var bytes := PhMapDoc.encode(doc).size()
	_check(bytes > 0 and bytes < PhMapDoc.WIRE_LIMIT, "it fits on the wire", "%d of %d bytes" % [bytes, PhMapDoc.WIRE_LIMIT])

	var missing: PackedStringArray = game.map.get("_missing")
	_check(missing.is_empty() and game.map.props.size() == (doc["props"] as Array).size(),
		"every prop in it is one the catalogue has", ", ".join(missing))

	await _report_colliderless(id, doc)

	var wearable := {}

	for prop: Dictionary in game.map.props:
		if game.props_catalogue.may_disguise(prop["id"]):
			wearable[prop["id"]] = true

	_check(wearable.size() >= MIN_WEARABLE, "it has enough different things to hide as", "%d" % wearable.size())

	var spawns: Dictionary = doc.get("spawns", {})
	var props_n := (spawns.get("props", []) as Array).size()
	var hunters_n := (spawns.get("hunters", []) as Array).size()
	_check(props_n >= MIN_PROP_SPAWNS and hunters_n >= MIN_HUNTER_SPAWNS, "it has enough spawns",
		"%d props, %d hunters" % [props_n, hunters_n])

	var bad_spawns: Array = []

	for side: String in ["props", "hunters"]:
		for seat in range((spawns.get(side, []) as Array).size()):
			var at: Vector3 = game.map.spawn(side, seat)[0]
			var why := _spawn_fault(game, at)
			if why != "":
				bad_spawns.append("%s %d at %s: %s" % [side, seat, at, why])

	_check(bad_spawns.is_empty(), "every spawn stands on a floor with room for a person", "; ".join(bad_spawns))

	var buried: Array = []
	var floating: Array = []

	for index in range(game.map.props.size()):
		var prop: Dictionary = game.map.props[index]
		var frame: Transform3D = prop["transform"]
		var size: Vector3 = prop["size"]
		var centre := frame * Vector3(0.0, size.y * 0.5, 0.0)

		if _inside_world(game, centre):
			buried.append("%s at %s" % [prop["id"], frame.origin])

		# Hung from a ceiling, or floating on water (which is not solid), by design.
		var hangs := String(prop["id"]).contains("ceiling") or String(prop["id"]).contains("lily")

		if not hangs and not _rests_on_something(game, frame, size):
			floating.append("%s at %s" % [prop["id"], frame.origin])

	_check(buried.is_empty(), "no prop is sunk into a wall or a floor", "; ".join(buried.slice(0, 6)))
	_check(floating.is_empty(), "every prop stands on something", "%d: %s" % [floating.size(), "; ".join(floating.slice(0, 6))])
	# The toys (dot-props', loose only): all built, none inside a wall, a car or a shelf, and two
	# seconds of physics later every one still where the map put it, not through a floor.
	var box := game.map.toys
	var placed := (doc.get("toys", []) as Array).size()
	var stuck: Array = []
	var own: Array[RID] = []
	for toy in box.toys:
		if toy.body != null:
			own.append(toy.body.get_rid())
	var space := game.get_world_3d().direct_space_state
	for toy in box.toys:
		for child in toy.body.get_children():
			var shape := child as CollisionShape3D
			if shape == null or shape.shape == null:
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform.translated(Vector3(0, 0.05, 0))
			query.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
			query.exclude = own
			if not space.intersect_shape(query, 1).is_empty():
				stuck.append("%s %d at %s" % [toy.def["id"], toy.index, toy.global_position.snapped(Vector3.ONE * 0.1)])
				break
	_check(box.count() == placed and placed > 0 and box.missing.is_empty() and stuck.is_empty(),
		"%d toys, every one dot-props', standing clear" % placed, "%d built; %s" % [box.count(), "; ".join(stuck.slice(0, 6))])
	for _i in range(120):
		await get_tree().physics_frame
	var strayed: Array = []
	for toy in box.toys:
		if toy.body.global_position.distance_to(toy.rest.origin) > 0.6:
			strayed.append("%s %d: %s to %s" % [toy.def["id"], toy.index, toy.rest.origin.snapped(Vector3.ONE * 0.1), toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(strayed.is_empty(), "two seconds on, every toy is still where the map put it", "; ".join(strayed.slice(0, 6)))
	await _dispose(game)
	_finished()


## Why a person could not stand at [param at], or "" when they can.
func _spawn_fault(game: PhGame, at: Vector3) -> String:
	var space := game.get_world_3d().direct_space_state
	var mask := game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	var down := PhysicsRayQueryParameters3D.create(at + Vector3(0.0, 0.5, 0.0), at + Vector3(0.0, -0.6, 0.0), mask)
	if space.intersect_ray(down).is_empty():
		return "nothing under it"

	var capsule := CapsuleShape3D.new()
	capsule.radius = RADIUS
	capsule.height = HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = mask
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, HEIGHT * 0.5 + 0.08, 0.0))

	var hits := space.intersect_shape(query, 4)

	if not hits.is_empty():
		var what: Array = []
		for hit: Dictionary in hits:
			var index := game.map.prop_from_hit(hit["collider"], int(hit["shape"]))
			what.append(String(game.map.prop_id(index)) if index >= 0 else "a wall")
		return "in the way: %s" % ", ".join(what)

	return ""


func _inside_world(game: PhGame, point: Vector3) -> bool:
	var query := PhysicsPointQueryParameters3D.new()
	query.position = point
	query.collision_mask = game.physics.layer_mask(&"world")
	return not game.get_world_3d().direct_space_state.intersect_point(query, 1).is_empty()


## A ray down from just inside the prop's base finds a floor, a table or another prop within
## a few centimetres. A tilted prop is tested from its lowest corner's height.
func _rests_on_something(game: PhGame, frame: Transform3D, size: Vector3) -> bool:
	var space := game.get_world_3d().direct_space_state
	var mask := game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	var base := frame.origin

	for x in [-0.3, 0.0, 0.3]:
		for z in [-0.3, 0.0, 0.3]:
			var from := frame * Vector3(size.x * x, 0.04, size.z * z)
			var query := PhysicsRayQueryParameters3D.create(from, Vector3(from.x, base.y - 0.12, from.z), mask)
			query.hit_from_inside = false
			if not space.intersect_ray(query).is_empty():
				return true

	return false


func _world(id: StringName, drawn := false) -> PhGame:
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([String(id)]) if id != &"" else PackedStringArray()

	var game := PhGame.new()
	game.name = "World_%s" % String(id)
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.draw_world = drawn
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return game


## dot-core's [DotCollisionAudit] over the map as a client draws it. The map keeps its drawing in
## `Drawn` (batched into chunks) and its shapes in `Solid` and `Furniture`, so the audit is the
## lenient one (a mesh that merely touches a shape passes); [method _partly_covered] is the
## stricter half for furniture, which a hunter or a disguised prop walks into.
func _report_colliderless(id: StringName, doc: Dictionary) -> void:
	var drawn := await _world(id, true)
	var res := DotCollisionAudit.audit(drawn.map, true)
	var found: PackedStringArray = (res.value as DotCollisionAudit).paths() if res.ok else PackedStringArray()

	if res.ok:
		var report: DotCollisionAudit = res.value
		print("  collision audit: %d findings of %d examined, %d opted out" % [report.count(), report.examined, report.opted_out])

		for line in report.describe_lines().slice(1, 12):
			print("    %s" % line)

	var partial := _partly_covered(drawn)
	print("  partly covered furniture (<%d%%): %d" % [int(PARTIAL * 100.0), partial.size()])

	for line in partial.slice(0, 20):
		print("    %s" % line)

	_check(res.ok and (res.value as DotCollisionAudit).examined > 0 and found.is_empty(),
		"everything drawn has collision, or says it is decoration (dot_no_collision)",
		"; ".join(found.slice(0, 6)) if res.ok else res.error.message)
	await _dispose(drawn)
	# Both worlds share one physics space: let the drawn one's bodies go before the checks that
	# follow ask it about the same spot.
	await get_tree().physics_frame


## Furniture whose catalogue box is under [constant PARTIAL] covered by its own shapes, sampled on
## a grid: the "walk into it" geometry the lenient audit cannot see. Reported, not failed, because
## a chair is open under its seat and a tree is a trunk under a crown on purpose.
func _partly_covered(game: PhGame) -> PackedStringArray:
	var out := PackedStringArray()
	var worst := {}

	for prop: Dictionary in game.map.props:
		var size: Vector3 = prop["size"]
		var frame: Transform3D = prop["transform"]
		var boxes: Array = []

		for shape: CollisionShape3D in prop["shapes"]:
			if shape.shape != null:
				boxes.append([shape.global_transform.affine_inverse(), shape.shape.get_debug_mesh().get_aabb()])

		var hit := 0
		var total := 0

		for ix in range(6):
			for iy in range(6):
				for iz in range(6):
					var local := Vector3(((ix + 0.5) / 6.0 - 0.5) * size.x, (iy + 0.5) / 6.0 * size.y, ((iz + 0.5) / 6.0 - 0.5) * size.z)
					var world := frame * local
					total += 1

					for pair: Array in boxes:
						if (pair[1] as AABB).has_point((pair[0] as Transform3D) * world):
							hit += 1
							break

		var share := float(hit) / float(total)

		if share < PARTIAL:
			var key := str(prop["id"])
			var entry: Array = worst.get(key, [0, 1.0, size])
			entry[0] += 1
			entry[1] = minf(entry[1], share)
			worst[key] = entry

	for key: String in worst:
		var entry: Array = worst[key]
		out.append("%s x%d, least %d%% of %s" % [key, entry[0], int(entry[1] * 100.0), (entry[2] as Vector3).snapped(Vector3.ONE * 0.01)])

	out.sort()
	return out


func _dispose(game: PhGame) -> void:
	remove_child(game)
	game.free()
	await get_tree().process_frame


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)
