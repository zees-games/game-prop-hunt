extends Node

const PhBindings := preload("../game/ph_bindings.gd")
const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhController := preload("../game/ph_controller.gd")
const PhGame := preload("../game/ph_game.gd")
const PhInterest := preload("../game/net/ph_interest.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")
const PhPlayer := preload("../game/ph_player.gd")
const PhProgress := preload("../game/ph_progress.gd")
const PhProps := preload("../game/ph_props.gd")
const ZeeIds := preload("res://addons/zee_weapons/content/zee_weapon_ids.gd")
const PhSettings := preload("../game/ph_settings.gd")
const PhEvents := preload("../game/net/ph_events.gd")

## The simulation, headless: the prop catalogue and the map documents, the draw, the hide, every
## part of hiding as a prop, taunts, shots at props and at the furniture, the beacon, and how a
## round is decided.
##
## [b]Counts sections AND checks, and the second is the one that matters.[/b] A script error
## inside a section aborts that function and the section counter is already satisfied,
## because the section announced itself on the way in. dot-settings has the story.
##
## Every number about the map here is the built-in practice house's
## ([method PhCatalogue.practice]), whose comment lists where everything is.

const SECTIONS := 29

const CHECKS := 166

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)

## The bookcase on the south wall of the living room, a decoy to shoot.
const BOOKCASE_AT := Vector3(-4.0, 0.0, 7.6)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _worlds: Array[PhGame] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("prophunt headless run")
	print("")

	_test_config()
	_test_catalogue()
	_test_documents()
	await _test_world_builds()
	await _test_the_draw()
	await _test_the_hide()
	await _test_disguise()
	await _test_reveal()
	await _test_turning()
	await _test_lean_on_the_floor()
	await _test_room()
	await _test_taunts()
	await _test_shots()
	await _test_toys()
	await _test_decoys()
	await _test_breaking()
	await _test_grenades()
	await _test_the_round()
	await _test_the_beacon()
	_test_interest()
	await _test_bots()
	await _test_the_client()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_offline_trigger()
	await _test_hunter_weapons()
	await _test_hunter_loadout()
	await _test_bodies()
	await _test_free_roam()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Without a world ------------------------------------------------------------

func _test_config() -> void:
	_section("the configuration")
	var config := PhConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(config.hunters_for(1) == 0, "one person is not a round")
	_check(config.hunters_for(2) == 1 and config.hunters_for(3) == 1, "one hunter up to three players")
	_check(config.hunters_for(7) == 3, "one per three, rounded up (7 players, 3)")
	_check(config.hunters_for(60) == config.max_hunters, "never more than the most")

	var rules := config.disguise_rules()
	_check(is_equal_approx(rules.reach, config.disguise_reach) and is_equal_approx(rules.reveal_cooldown, config.reveal_cooldown),
		"the disguise rules are the configuration's")
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "every weapon model the art table names is vendored", "" if models.ok else models.error.message)

	config.hunter_pick = 9
	_check(not config.validate().ok, "a way of picking hunters that is none of the three is refused")

	var timing := PhGame.new()
	timing.config = PhConfig.new()
	var pause := DotMatchRules.new()
	_check(is_equal_approx(timing.config.killcam_seconds, 7.0), "the killcam is seven seconds by default")
	timing.apply_intermission(pause)
	_check(is_equal_approx(pause.intermission_sec, timing.config.intermission_seconds + 7.0), "the intermission carries the killcam")
	timing.config.killcam_seconds = 0.0
	timing.apply_intermission(pause)
	_check(is_equal_approx(pause.intermission_sec, timing.config.intermission_seconds), "no killcam, the intermission as it was")
	timing.config.intermission_seconds = 0.0
	timing.config.killcam_seconds = 7.0
	timing.apply_intermission(pause)
	_check(is_zero_approx(pause.intermission_sec), "an intermission of 0 stays 0 whatever the killcam")
	timing.free()
	_finished()


func _test_catalogue() -> void:
	_section("the prop catalogue is what the models measure")
	var props := PhProps.new()
	var count := props.load_file()
	_check(count > 100, "it reads (%d props)" % count)
	_check((props.size_of(&"furniture_chair") - Vector3(0.46, 1.08, 0.46)).length() < 0.01,
		"a chair is the size measured", str(props.size_of(&"furniture_chair")))
	_check(props.may_disguise(&"furniture_chair") and not props.may_disguise(&"furniture_ceiling_fan"),
		"a chair may be worn and a ceiling fan may not")

	var bad := 0
	for id in props.order:
		var e := props.entry(id)
		if not ResourceLoader.exists("res://" + str(e["model"])):
			bad += 1
	_check(bad == 0, "every prop's model is in the game", "%d missing" % bad)
	_finished()


func _test_documents() -> void:
	_section("a map is a document, and a bad one is refused with a reason")
	var practice := PhCatalogue.practice()
	_check(str(practice.get("id", "")) == "ph_practice", "the practice house validates")
	_check(practice["boxes"][0]["at"] is Array, "positions are normalised to plain arrays")

	var props := PhProps.new()
	var _n := props.load_file()
	var unknown := 0
	for prop: Dictionary in practice["props"]:
		if not props.has(StringName(str(prop["id"]))):
			unknown += 1
	_check(unknown == 0, "every prop it names is in the catalogue")

	var bare := practice.duplicate(true)
	bare["spawns"] = {"props": [], "hunters": [{"at": [0, 0, 0]}]}
	var refused := PhMapDoc.validate(bare)
	_check(not refused.ok and str(refused.error).contains("props"), "a map with no props' spawns is refused, saying so")

	var wrong := practice.duplicate(true)
	wrong["kind"] = "course"
	_check(not PhMapDoc.validate(wrong).ok, "a document of another kind is refused")

	var encoded := PhMapDoc.encode(practice)
	var decoded := PhMapDoc.decode(encoded)
	_check(decoded.ok and PhMapDoc.digest(decoded.value) == PhMapDoc.digest(practice),
		"it survives the wire whole (%d bytes)" % encoded.size())

	var torn := encoded.slice(0, encoded.size() - 3)
	_check(not PhMapDoc.decode(torn).ok, "a torn one is refused rather than half built")
	_finished()


# --- A world ---------------------------------------------------------------------

func _test_world_builds() -> void:
	_section("the practice house builds, solid where it should be")
	var game := await _world()
	_check(game.map.id() == &"ph_practice", "the map is built")
	_check(game.map.props.size() == (game.map_doc["props"] as Array).size(), "every prop is in it (%d)" % game.map.props.size())

	var space := game.get_world_3d().direct_space_state
	var clear := 0
	var floored := 0
	var spawns: Array = (game.map_doc["spawns"] as Dictionary)["props"] + (game.map_doc["spawns"] as Dictionary)["hunters"]

	for spawn: Dictionary in spawns:
		var at := PhMapDoc.v3(spawn["at"])
		var hull := CapsuleShape3D.new()
		hull.radius = 0.35
		hull.height = 1.8
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = hull
		query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.95, 0.0))
		query.collision_mask = game.physics.collision_mask(&"player")
		if space.intersect_shape(query, 1).is_empty():
			clear += 1
		var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at + Vector3.DOWN * 1.0)
		if not space.intersect_ray(ray).is_empty():
			floored += 1

	_check(clear == spawns.size(), "nobody starts inside anything (%d of %d clear)" % [clear, spawns.size()])
	_check(floored == spawns.size(), "and every spawn has a floor under it (%d of %d)" % [floored, spawns.size()])

	var chair := _prop_near(game, CHAIR_AT)
	_check(chair >= 0 and game.map.prop_id(chair) == &"furniture_chair", "the chair is where the document puts it")
	_check(game.map.prop_containing(CHAIR_AT + Vector3(0.0, 0.5, 0.0)) == chair, "and a point inside it is on it")
	_finished()


func _test_the_draw() -> void:
	_section("who hunts: the draw, the wishes and the equal share")
	var game := await _world(func(c: PhConfig) -> void:
		c.hunter_pick = 1
		c.players_per_hunter = 3.0)
	var ids: Array[StringName] = []
	for i in range(6):
		var p := game.add_player(StringName("u%d" % (100 + i)), "P%d" % i)
		ids.append(p.player_id)

	game.start()
	await _step(game, 2)
	_check(game.players_on(PhGame.HUNTERS).size() == 2, "six players, two hunters")

	var turns := {}
	for round_index in range(6):
		for id in ids:
			if game.team_of(id) == PhGame.HUNTERS:
				turns[id] = int(turns.get(id, 0)) + 1
		await _end_round(game)
	var spread := _spread(turns, ids)
	_check(spread.y - spread.x <= 1, "an equal share over six rounds (%d..%d each)" % [spread.x, spread.y])

	game.wish_side(ids[0], PhGame.PROPS)
	for id in ids.slice(1):
		game.wish_side(id, PhGame.PROPS)
	game.wish_side(ids[3], PhGame.HUNTERS)
	await _end_round(game)
	_check(game.team_of(ids[3]) == PhGame.HUNTERS, "somebody who asked to hunt hunts")
	_finished()


func _test_the_hide() -> void:
	_section("the hide: hunters held still and blind, props free")
	var game := await _world(func(c: PhConfig) -> void: c.hide_seconds = 1.0)
	var hunter := game.add_player(&"u200", "Hunter", PhGame.HUNTERS)
	var prop := game.add_player(&"u201", "Prop")
	game.wish_side(hunter.player_id, PhGame.HUNTERS)
	game.wish_side(prop.player_id, PhGame.PROPS)
	game.start()
	await _step(game, 2)
	_check(game.phase == PhGame.Phase.HIDE, "a round starts with the hide")
	_check(game.team_of(hunter.player_id) == PhGame.HUNTERS and hunter.controller.has_modifier(PhController.BLINDFOLD),
		"the hunter is blindfolded")

	var hunter_from := hunter.controller.state.position
	var prop_from := prop.controller.state.position
	for i in range(30):
		_drive(hunter, Vector2(0.0, 1.0))
		_drive(prop, Vector2(0.0, 1.0))
		await _step(game, 1)
	var walked := Vector2(hunter.controller.state.position.x - hunter_from.x, hunter.controller.state.position.z - hunter_from.z)
	_check(walked.length() < 0.05, "a blindfolded hunter does not move", "%.2f m" % walked.length())
	_check(prop.controller.state.position.distance_to(prop_from) > 1.0, "a prop does")
	_check(hunter.weapons != null, "a hunter is armed from the start")

	await _step(game, TICK_RATE)
	_check(game.phase == PhGame.Phase.SEEK and not hunter.controller.has_modifier(PhController.BLINDFOLD),
		"after the hide the hunters are let go")
	_finished()


func _test_disguise() -> void:
	_section("becoming a prop: the hull, the health and the hitbox are the prop's")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]

	_check(not game.request_disguise(hunter.player_id), "a hunter cannot hide")

	# From the west, across the empty end of the kitchen: the table is on the chair's other side.
	_stand_facing(prop, CHAIR_AT + Vector3(-2.0, 0.05, 0.0), CHAIR_AT + Vector3(0.0, 0.6, 0.0))
	await _step(game, 1)
	_check(game.request_disguise(prop.player_id) and prop.disguise.prop_id == &"furniture_chair",
		"a prop looking at a chair becomes a chair", String(prop.disguise.prop_id))

	var size := game.props_catalogue.size_of(&"furniture_chair")
	var hull := DotPropDisguise.hull(size, game.rules)
	_check(is_equal_approx(prop.controller.tunables.radius, hull.x) and is_equal_approx(prop.controller.tunables.stand_height, hull.y),
		"the controller sweeps the chair's hull (r %.2f, h %.2f)" % [hull.x, hull.y])
	_check(is_equal_approx(prop.health.max_health, DotPropDisguise.health(size, game.rules)),
		"and has a chair's health (%d)" % int(prop.health.max_health))

	var box := prop.hitboxes.get_node("Prop") as DotHitbox
	_check(box.enabled and (prop.hitboxes.get_node("Chest") as DotHitbox).enabled == false
		and box.half_extents.is_equal_approx(size * 0.5), "its hitbox is the chair's box and not a person's")

	_check(not game.disguise_as(prop.player_id, &"furniture_ceiling_fan"), "a ceiling fan cannot be worn")
	_check(not game.disguise_as(prop.player_id, &"furniture_computer_mouse"), "nor something too small to find")

	prop.health.health = prop.health.max_health * 0.5
	var _became := game.disguise_as(prop.player_id, &"furniture_bookcase_closed")
	_check(absf(prop.health.health / prop.health.max_health - 0.5) < 0.02,
		"a hurt prop keeps the share of health it had in a bigger one (%d of %d)" % [int(prop.health.health), int(prop.health.max_health)])
	_finished()


func _test_reveal() -> void:
	_section("showing yourself: paid by the second, and not again for a while")
	var game := await _hide_round(func(c: PhConfig) -> void:
		c.reveal_cooldown = 10.0
		c.reveal_points_per_second = 1.0)
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	var points := prop.points

	_check(game.reveal(prop.player_id) and not prop.is_disguised() and prop.set_aside != null,
		"a prop takes the chair off and keeps it")
	await _step(game, TICK_RATE * 3 + 2)
	_check(prop.points - points == 3, "and is paid a point a second while it shows itself (+%d)" % (prop.points - points))

	_check(game.reveal(prop.player_id) and prop.disguise.prop_id == &"furniture_chair", "the same key puts the chair back on")
	_check(not game.reveal(prop.player_id), "and it cannot show itself again straight away")
	_finished()


## A hull changes size where the player stands, so the server looks for room first.
func _test_room() -> void:
	_section("a bigger hull needs room: moved a step, or refused")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]

	# Against the living room's west wall (inner face x -10.0) as a bedside cabinet, which fits,
	# then a bookcase, whose hull would be inside the wall where the cabinet stands.
	var _small := game.disguise_as(prop.player_id, &"furniture_cabinet_bed")
	prop.place_at(Vector3(-9.75, 0.05, 2.0), 0.0)
	await _step(game, 2)
	var before := prop.controller.state.position
	_check(game.disguise_as(prop.player_id, &"furniture_bookcase_closed"), "a cabinet against a wall may become a bookcase")
	var moved := prop.controller.state.position.x - before.x
	var hull := DotPropDisguise.hull(game.props_catalogue.size_of(&"furniture_bookcase_closed"), game.rules)
	_check(moved > 0.02 and prop.controller.state.position.x - hull.x >= -10.0 - 0.01,
		"and is moved off the wall by enough for its hull", "moved %.2f m, hull %.2f" % [moved, hull.x])

	# Under the kitchen table (top at 0.75 m, chairs on both sides) as a bedside cabinet: there
	# is no room to stand up anywhere a step away.
	var _under := game.disguise_as(prop.player_id, &"furniture_cabinet_bed")
	prop.place_at(Vector3(4.5, 0.05, 2.0), 0.0)
	await _step(game, 2)
	var refusals: Array = []
	game.refused.connect(func(id: StringName, why: String) -> void: refusals.append(why))
	_check(not game.reveal(prop.player_id) and prop.is_disguised(), "under a table a prop cannot stand up as a person")
	_check(not refusals.is_empty() and str(refusals[-1]).contains("room"), "and is told why", str(refusals))
	_finished()


func _test_turning() -> void:
	_section("turning a prop: locked, tilted, upright again")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	prop.controller.state.yaw = 40.0
	var _locked := game.turn(prop.player_id, PhGame.Turn.LOCK)
	prop.controller.state.yaw = 120.0
	_check(prop.disguise.locked and prop.prop_basis().is_equal_approx(Basis(Vector3.UP, deg_to_rad(40.0))),
		"locked, the chair keeps the facing it was locked at")
	var _tilted := game.turn(prop.player_id, PhGame.Turn.TILT_FORWARD)
	_check(is_equal_approx(prop.disguise.pitch, game.config.tilt_step), "a tilt leans it by the step")
	var _upright := game.turn(prop.player_id, PhGame.Turn.STRAIGHTEN)
	_check(is_zero_approx(prop.disguise.pitch) and is_zero_approx(prop.disguise.roll), "and it stands up again")
	_finished()


## Christian's first play test: "When I'm a water bottle and default up, I should be able to
## put it on each side or on its nose ... WITHOUT going into the ground (since that'd be
## cheating)." Every prop a player may become, turned every way a player can turn it (each side,
## back, front, upside down), drawn: the lowest point of its real meshes stays on the floor, the
## feet stay on it, and the hull is as tall as the leant prop.
func _test_lean_on_the_floor() -> void:
	_section("every prop turned every way up rests on the floor, never in it")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	# Where the floor is: where the body comes to rest (a spawn is a few centimetres above it).
	await _step(game, 16)
	var floor_y := prop.controller.state.position.y
	var spot := prop.controller.state.position
	var turns := [
		[], [PhGame.Turn.TILT_LEFT], [PhGame.Turn.TILT_RIGHT], [PhGame.Turn.TILT_FORWARD], [PhGame.Turn.TILT_BACK],
		[PhGame.Turn.TILT_FORWARD, PhGame.Turn.TILT_FORWARD],
	]
	var presses := int(round(90.0 / game.config.tilt_step))
	var worst_mesh := INF
	var worst_feet := INF
	var hull_short := 0
	var turned := 0
	var asked := 0
	var tried := 0
	for id: StringName in game.props_catalogue.props:
		if not game.props_catalogue.may_disguise(id) or not DotPropDisguise.may_take(game.props_catalogue.size_of(id), game.rules).ok:
			continue
		tried += 1
		var parts: Array = game.props_catalogue.parts(id)
		for way: Array in turns:
			# Its own body again, directly: reveal's cooldown is another test's business.
			prop.apply_disguise(DotPropDisguise.new())
			prop.place_at(spot, 0.0)
			await _step(game, 1)
			if not game.disguise_as(prop.player_id, id):
				continue
			for t: int in way:
				for _p in range(presses):
					asked += 1
					if game.turn(prop.player_id, t):
						turned += 1
			await _step(game, 2)
			var feet := prop.controller.state.position
			worst_feet = minf(worst_feet, feet.y - floor_y)
			var frame := prop.disguise.model_transform(feet, prop.controller.state.yaw)
			for part: Array in parts:
				var box: AABB = (frame * (part[1] as Transform3D)) * (part[0] as Mesh).get_aabb()
				worst_mesh = minf(worst_mesh, box.position.y - floor_y)
			var standing := prop.disguise.standing_size().y
			if prop.hull_height() + 0.001 < minf(standing, game.rules.hull_max_height):
				hull_short += 1
	_check(worst_mesh > -0.03, "the lowest point of any prop's meshes, at any turn, is on the floor",
		"%d props x %d ways; lowest %.3f m" % [tried, turns.size(), worst_mesh])
	_check(worst_feet > -0.01, "and the feet never sink", "lowest %.3f m" % worst_feet)
	_check(hull_short == 0 and turned * 10 >= asked * 9, "the hull is as tall as the leant prop, and the turns are allowed in the open",
		"%d short; %d of %d presses turned" % [hull_short, turned, asked])
	_finished()


func _test_taunts() -> void:
	_section("taunts: chosen and paid, or forced on a prop that stands still")
	var game := await _hide_round(func(c: PhConfig) -> void:
		c.hide_seconds = 0.5
		c.auto_taunt_seconds = 2.0
		c.taunt_cooldown = 0.25
		c.taunt_points = 2)
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	_check(game.taunt_ids().size() > 10, "the taunt list is read (%d)" % game.taunt_ids().size())

	var heard: Array = []
	game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
		heard.append([id, taunt_id, forced]))
	var points := prop.points
	_check(not game.taunt(prop.player_id, &"you_lose") and prop.points == points,
		"no taunt while the hunters are blindfolded")

	while game.phase != PhGame.Phase.SEEK:
		await _step(game, 1)

	_check(game.taunt(prop.player_id, &"you_lose") and prop.points == points + 2,
		"a chosen taunt while they hunt is paid (+%d)" % (prop.points - points))
	_check(not game.taunt(prop.player_id), "and a second straight after is refused")

	await _step(game, TICK_RATE)
	_check(prop.taunt_meter > 0.3 and prop.taunt_meter < 0.8, "standing still fills the meter (%.2f at one second of two)" % prop.taunt_meter)
	await _step(game, TICK_RATE + 4)
	var forced := heard.filter(func(h: Array) -> bool: return bool(h[2]) and h[0] == prop.player_id)
	_check(forced.size() == 1, "and two seconds of it forces one taunt on it", "%d" % forced.size())
	_finished()


func _test_shots() -> void:
	_section("a hunter finds a prop by shooting it")
	var game := await _seek_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	prop.place_at(Vector3(-6.0, 0.05, 2.0), 0.0)
	# The other prop off the line of fire: the props' second spawn is where this one now stands.
	(game.players_on(PhGame.PROPS)[1] as PhPlayer).place_at(Vector3(-8.5, 0.05, 6.0), 0.0)
	_stand_facing(hunter, Vector3(-6.0, 0.05, -2.0), Vector3(-6.0, 0.6, 2.0))

	var died: Array = []
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void: died.append([id, by, why]))
	var points := hunter.points
	var hurt_before := prop.health.health

	for i in range(TICK_RATE * 10):
		_aim(hunter, Vector3(-6.0, 0.6, 2.0))
		# A magazine runs dry, and nothing reloads on its own: a reload every three seconds,
		# as a player would.
		var reloading := i % (TICK_RATE * 3) > TICK_RATE * 2
		_fire(hunter, not reloading)
		_reload(hunter, reloading)
		await _step(game, 1)
		if not prop.is_alive():
			break
	_fire(hunter, false)
	_check(prop.health.health < hurt_before, "the shots land on the chair the prop is")
	_check(not prop.is_alive() and died.size() >= 1 and died[0][2] == PhGame.DIED_SHOT and died[0][1] == hunter.player_id,
		"until the prop is found, by that hunter", "health %.0f of %.0f, deaths %s, weapon %s, magazine %d" % [
			prop.health.health, prop.health.max_health, str(died),
			hunter.weapons.arsenal.current_def().id if hunter.weapons.arsenal.current_def() != null else &"-",
			hunter.weapons.arsenal.magazine_of(hunter.weapons.arsenal.current_def().id) if hunter.weapons.arsenal.has_method("magazine_of") else -1])
	_check(hunter.points >= points + game.config.find_points, "and the hunter is paid for it")
	_finished()


## dot-props' toys in the practice garden: walked into and sent on, shot and sent off while the
## combat's trace sees straight through them (no cover, nothing a hunter pays for), and home
## again at the next round.
func _test_toys() -> void:
	_section("the garden's toys")
	var game := await _seek_round()
	var box := game.map.toys
	_check(box != null and box.count() == 3 and box.missing.is_empty(), "the practice garden has its three toys", str(box.describe()) if box != null else "none")
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var ball := box.toy(0)
	var b0 := ball.body.global_position
	hunter.place_at(b0 + Vector3(-0.4, -0.12, 0.0), 0.0)
	for _i in range(10):
		hunter.controller.state.velocity = Vector3(5.0, 0.0, 0.0)
		game._advance_toys(TICK)
		await _physics_frame()
	for _i in range(20):
		await _physics_frame()
	_check(ball.body.global_position.x > b0.x + 0.4, "a hunter walking into the football sends it on", "%.2f m" % (ball.body.global_position.x - b0.x))

	var beach := box.toy(1)
	var o0 := beach.body.global_position
	var health := hunter.health.health
	var shot := DotShot.make(&"test", hunter.entity_id, game.current_tick(), 0)
	shot.origin = o0 + Vector3(-5.0, 0.0, 0.0)
	shot.direction = Vector3(1.0, 0.0, 0.0)
	shot.damage = 25.0
	shot.max_range = 40.0
	var through := game.combat.trace.line_of_sight(shot.origin, o0 + Vector3(2.0, 0.0, 0.0))
	game._shoot_toys(shot)
	for _i in range(20):
		await _physics_frame()
	_check(beach.body.global_position.distance_to(o0) > 0.4 and through and hunter.health.health == health,
		"a shot sends the beach ball off, the combat's trace sees through it, and the hunter pays nothing",
		"%.2f m, clear %s, health %.0f to %.0f" % [beach.body.global_position.distance_to(o0), str(through), health, hunter.health.health])

	game._on_round_started(game.round_number + 1)
	await _physics_frame()
	_check(ball.body.global_position.distance_to(ball.rest.origin) < 0.05 and beach.body.global_position.distance_to(beach.rest.origin) < 0.05,
		"a new round puts every toy home")
	_finished()


func _test_decoys() -> void:
	_section("shooting the furniture costs a hunter, and can finish one")
	var game := await _seek_round(func(c: PhConfig) -> void:
		c.decoy_penalty = 2.0
		c.hunter_health = 30.0)
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	_stand_facing(hunter, BOOKCASE_AT + Vector3(0.0, 0.05, -3.0), BOOKCASE_AT + Vector3(0.0, 1.0, 0.0))

	var cost: Array = []
	game.decoy_hit.connect(func(id: StringName, amount: float) -> void: cost.append(amount))
	var died: Array = []
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void: died.append([id, why]))
	var start := hunter.health.health

	for i in range(TICK_RATE * 6):
		_aim(hunter, BOOKCASE_AT + Vector3(0.0, 1.0, 0.0))
		_fire(hunter, true)
		await _step(game, 1)
		if not hunter.is_alive():
			break
	_fire(hunter, false)

	_check(not cost.is_empty() and hunter.health.health < start, "a shot at the real bookcase costs the hunter health")
	_check(not hunter.is_alive() and died.size() == 1 and died[0][1] == PhGame.DIED_DECOY,
		"and enough of them finish the hunter, as the furniture's")
	_finished()


## Christian's first play test: "props should be breakable and more should be added". A pot
## plant shot enough breaks: nothing collides with it or draws it, the shots still cost the
## decoy penalty, and the next round has it back.
func _test_breaking() -> void:
	_section("breakable furniture breaks when shot, still costs, and is back next round")
	var breakable := 0
	for id: StringName in game_catalogue_ids():
		if _props_catalogue.breaks(id) > 0.0:
			breakable += 1
	_check(_props_catalogue.props.size() >= 200 and breakable >= 50,
		"the catalogue is larger and much of it breaks", "%d props, %d break" % [_props_catalogue.props.size(), breakable])

	var game := await _seek_round(func(c: PhConfig) -> void:
		c.decoy_penalty = 0.05
		c.hunter_health = 400.0)
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var index := -1
	for i in range(game.map.props.size()):
		var prop: Dictionary = game.map.props[i]
		if prop["id"] == &"furniture_potted_plant" and (prop["transform"] as Transform3D).origin.y < 0.1:
			index = i
			break
	var plant: Dictionary = game.map.props[index]
	var middle: Vector3 = (plant["transform"] as Transform3D).origin + Vector3(0.0, (plant["size"] as Vector3).y * 0.5, 0.0)
	# Somewhere 2.5 m off with a clear view of it: a plant stands against a wall.
	var away := Vector3.INF
	for k in range(16):
		var spot := Vector3(middle.x, 0.05, middle.z) + Vector3(cos(TAU * k / 16.0), 0.0, sin(TAU * k / 16.0)) * 2.5
		var probe := DotPropDisguise.of(&"x", plant["size"])
		if game._clear_between(spot + Vector3(0.0, 1.6, 0.0), middle + (spot - middle).normalized() * 0.3 * probe.size.x, true) \
				and game._clear_between(spot + Vector3(0.0, 0.3, 0.0), spot + Vector3(0.0, 1.7, 0.0), true):
			away = spot
			break
	_stand_facing(hunter, away, middle)

	var broke: Array = []
	game.prop_broken.connect(func(i: int, _d: Vector3) -> void: broke.append(i))
	var cost: Array = []
	game.decoy_hit.connect(func(_id: StringName, amount: float) -> void: cost.append(amount))
	for i in range(TICK_RATE * 6):
		_aim(hunter, middle)
		_fire(hunter, true)
		await _step(game, 1)
		if not broke.is_empty():
			break
	_fire(hunter, false)
	await _step(game, 2)

	_check(broke == [index] and bool(game.map.props[index]["broken"]), "a pot plant shot enough breaks", str(broke))
	_check(game._clear_between(hunter.eye_position(), middle, true) and game.map.prop_containing(middle) < 0,
		"and is gone: a shot passes where it stood, and no decoy is charged there again")
	_check(not cost.is_empty(), "the shots that broke it still cost the decoy penalty (%d)" % cost.size())
	await _end_round(game)
	_check(not bool(game.map.props[index]["broken"]) and game.map.prop_containing(middle) == index, "the next round has it back")
	_finished()


var _props_catalogue: PhProps = null


## The hunters' grenades (`PhProjectiles`): a frag thrown on B's slot five flies, bursts on its
## fuse and finds the prop beside it, for nothing; one that goes off by the bookcase and finds
## nobody costs one decoy at its full damage; one in the open garden costs nothing and throws
## the football. Armed: with `PhGame._advance_weapons` dropping `outcome.spawns` again the first
## checks fail; with `blast_cost` charging regardless, the third does.
func _test_grenades() -> void:
	_section("a hunter's grenade flies, bursts, finds a prop, and costs a decoy on the furniture")
	var game := await _seek_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	prop.place_at(Vector3(-6.0, 0.05, 2.0), 0.0)
	(game.players_on(PhGame.PROPS)[1] as PhPlayer).place_at(Vector3(7.0, 0.05, -3.0), 0.0)
	# Clear of the television (-7, -1), which the throw once met a hand's breadth out.
	_stand_facing(hunter, Vector3(-5.0, 0.05, -1.5), Vector3(-6.0, 0.3, 2.0))
	var armed := game.arm(hunter, &"frag")
	hunter.wanted_slot = ZeeWeaponIds.SLOT_THROWN
	# The SMG put away and the frag drawn (0.25 s and 0.35 s): a press during the switch is a
	# press already down when it ends, which starts no cook.
	await _step(game, TICK_RATE)

	var launched: Array = []
	game.projectiles.launched.connect(func(f: RefCounted) -> void: launched.append(f))
	var blasts: Array = []
	game.projectiles.blasted.connect(func(at: Vector3, _spawn: DotWeaponSpawn, shot: DotShot) -> void: blasts.append([at, shot]))
	var cost: Array = []
	game.decoy_hit.connect(func(_id: StringName, amount: float) -> void: cost.append(amount))
	var health := prop.health.health
	var furthest := 0.0

	# Pin out, a short cook, and let go: zee's grenades throw on release.
	for i in range(TICK_RATE * 5):
		_aim(hunter, Vector3(-6.0, 0.3, 2.0))
		_fire(hunter, i < 6)
		await _step(game, 1)
		for f: RefCounted in launched:
			furthest = maxf(furthest, (f.get(&"position") as Vector3).distance_to((f.get(&"spawn") as DotWeaponSpawn).origin))
		if not blasts.is_empty():
			break
	_fire(hunter, false)
	_check(armed and launched.size() == 1 and furthest > 1.5, "a frag thrown from slot five leaves the hand and flies",
		"armed %s, slot %d, %d launched, %.1f m" % [str(armed), hunter.weapons.arsenal.current_slot(), launched.size(), furthest])
	_check(blasts.size() == 1 and prop.health.health < health and cost.is_empty(),
		"it bursts on its fuse and hurts the prop beside it, and finding somebody costs nothing",
		"%d blasts, prop %.0f -> %.0f, charged %s" % [blasts.size(), health, prop.health.health, str(cost)])

	# By the bookcase with nobody near: one decoy, at the frag's full damage.
	var frag := ZeeWeaponPack.catalogue().get_def(&"frag")
	var tuning := frag.tuning as DotWeaponBallistics
	# Everybody in the kitchen, well out of its reach: a prop the first frag only hurt, left
	# where it was, was 5.3 m from this one and took its splash.
	for i in range(2):
		(game.players_on(PhGame.PROPS)[i] as PhPlayer).place_at(Vector3(7.5 + float(i), 0.05, -3.0), 0.0)
	hunter.place_at(Vector3(6.0, 0.05, -1.0), 0.0)
	await _step(game, 2)
	cost.clear()
	var hunter_before := hunter.health.health
	var _f := game.projectiles.launch(_still_grenade(BOOKCASE_AT + Vector3(0.0, 0.3, -0.7), hunter, tuning))
	await _step(game, 4)
	var expected := maxf(tuning.splash_damage * game.config.decoy_penalty, game.config.decoy_penalty_min)
	_check(cost.size() == 1 and absf(float(cost[0]) - expected) < 0.01 and hunter.health.health < hunter_before,
		"one that goes off by the bookcase and finds nobody costs one decoy at its full damage",
		"charged %s, expected %.1f, health %.0f -> %.0f" % [str(cost), expected, hunter_before, hunter.health.health])

	# In the open garden, beside the football: nothing to pay, and the ball goes.
	var ball := game.map.toys.toy(0)
	var b0 := ball.body.global_position
	cost.clear()
	var open := _still_grenade(b0 + Vector3(-1.0, 0.3, -1.0), hunter, tuning)
	open.splash_radius = 2.5
	var _g := game.projectiles.launch(open)
	await _step(game, 4)
	for _i in range(20):
		await _physics_frame()
	_check(cost.is_empty() and ball.body.global_position.distance_to(b0) > 0.5,
		"one in the open garden costs nothing and throws the football",
		"charged %s, ball moved %.2f m" % [str(cost), ball.body.global_position.distance_to(b0)])
	_finished()


## A grenade lying at [param at], two ticks from going off, thrown by [param thrower].
func _still_grenade(at: Vector3, thrower: PhPlayer, tuning: DotWeaponBallistics) -> DotWeaponSpawn:
	var spawn := DotWeaponSpawn.make(&"frag", at, Vector3.ZERO, thrower.entity_id)
	spawn.fuse_ticks = 2
	spawn.life_ticks = TICK_RATE * 4
	spawn.splash_radius = tuning.splash_radius
	spawn.splash_damage = tuning.splash_damage
	spawn.damage_type = tuning.damage_type
	spawn.radius = tuning.radius
	return spawn


func game_catalogue_ids() -> Array:
	if _props_catalogue == null:
		_props_catalogue = PhProps.new()
		var _n := _props_catalogue.load_file()
	return _props_catalogue.props.keys()


func _test_the_round() -> void:
	_section("a round: the hunters find everybody, or the props hold out")
	var game := await _seek_round(func(c: PhConfig) -> void:
		c.round_seconds = 30.0)
	var winners: Array = []
	game.round_over.connect(func(_n: int, winner: int, _why: String) -> void: winners.append(winner))
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var points := hunter.points

	for prop in game.players_on(PhGame.PROPS):
		_kill(game, prop, hunter)
	await _step(game, 4)
	_check(winners == [PhGame.HUNTERS], "every prop found is the hunters' round")
	_check(hunter.points >= points + game.config.winner_points, "and the hunters are paid for winning")

	await _wait_for(game, PhGame.Phase.SEEK)
	var survivor: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var kept := survivor.points
	game.seek_elapsed = game.round_limit() - 0.05
	await _step(game, 6)
	_check(winners.size() == 2 and winners[1] == PhGame.PROPS, "the clock is the props' round")
	_check(survivor.points >= kept + game.config.winner_points + game.config.survive_points,
		"and a prop alive at the end is paid for winning and for surviving")
	_finished()


func _test_the_beacon() -> void:
	_section("the last prop is given away")
	var game := await _seek_round(func(c: PhConfig) -> void:
		c.beacon_props_left = 1
		c.beacon_seconds_left = 0.0)
	var props := game.players_on(PhGame.PROPS)
	await _step(game, 2)
	_check(props.filter(func(p: PhPlayer) -> bool: return p.marked).is_empty(), "nobody is marked while several are hidden")
	for i in range(props.size() - 1):
		_kill(game, props[i], game.players_on(PhGame.HUNTERS)[0])
	await _step(game, 2)
	_check(props[props.size() - 1].marked, "the last one is")
	_finished()


func _test_interest() -> void:
	_section("a hunter is told nothing about the props while they hide")
	var game := PhGame.new()
	var config := PhConfig.new()
	game.config = config
	var interest := PhInterest.new()
	interest.game = game
	var hunter := PhPlayer.new()
	hunter.player_id = &"u1"
	var prop := PhPlayer.new()
	prop.player_id = &"u2"
	game.sides[&"u1"] = PhGame.HUNTERS
	game.sides[&"u2"] = PhGame.PROPS
	var watcher := DotNetIdentity.new()
	var seen := DotNetIdentity.new()
	hunter.add_child(watcher)
	prop.add_child(seen)

	game.phase = PhGame.Phase.HIDE
	_check(not interest._is_relevant(watcher, seen, {}), "a prop is not in a hunter's snapshot while the props hide")
	_check(interest._is_relevant(seen, watcher, {}), "a hunter is in a prop's")
	game.phase = PhGame.Phase.SEEK
	_check(interest._is_relevant(watcher, seen, {}), "and once the hunters are let go, everybody is in everybody's")

	hunter.free()
	prop.free()
	game.free()
	_finished()


func _test_bots() -> void:
	_section("stand-ins hide and seek")
	var game := await _world(func(c: PhConfig) -> void:
		c.hide_seconds = 8.0
		c.players_per_hunter = 3.0)
	for i in range(6):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	await _step(game, TICK_RATE * 8)
	var hidden := game.players_on(PhGame.PROPS).filter(func(p: PhPlayer) -> bool: return p.is_disguised())
	# Every one, not most: a stand-in whose look met the wrong thing used to ask again every
	# tick for the rest of the round, in the open.
	_check(hidden.size() == game.players_on(PhGame.PROPS).size(),
		"every stand-in prop is hiding as something by the end of the hide (%d of %d)" % [hidden.size(), game.players_on(PhGame.PROPS).size()])
	await _step(game, TICK_RATE * 6)
	_check(game.phase == PhGame.Phase.SEEK or game.phase == PhGame.Phase.IDLE, "and the round goes on without anybody at the keyboard")

	# A stand-in hunter's shot is dot-bot's DotBotAim: turned onto the prop at bot_turn_rate,
	# fired only bot_reaction after it first saw it. Driven through the game's own _bot_shoot.
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0] if not game.players_on(PhGame.HUNTERS).is_empty() else null
	var profile := DotBotSettings.of(game).profile
	if hunter != null:
		var eye := hunter.eye_position()
		var behind := eye + Vector3(-8.0, -0.4, 6.0)
		var first := -1.0
		var fastest := 0.0
		var command := DotFpsCommand.new()
		command.yaw = hunter.controller.state.yaw
		var start: float = game._bot_now()
		for i in range(TICK_RATE * 2):
			var before := command.yaw
			game._bot_aim_of(hunter).view_from(command.yaw, command.pitch)
			if game._bot_shoot(hunter, command, 424242, behind, Vector3.ZERO) and first < 0.0:
				first = game._bot_now() - start
			fastest = maxf(fastest, absf(wrapf(command.yaw - before, -180.0, 180.0)) * TICK_RATE)
			game._tick += 1
		_check(first >= profile.reaction * 0.85 and fastest <= profile.turn_rate * 1.02,
			"a stand-in hunter turns at bot_turn_rate and fires only after bot_reaction (first shot %.2f s, %.0f deg/s)" % [first, fastest])
	else:
		_check(false, "a stand-in hunter to aim with")

	_finished()


func _test_the_client() -> void:
	_section("the client boots offline: the keys, the HUD, the taunt list, the board")
	var client: Node = (load("res://game/ph_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"remember_loadout", false)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	# The map used to be drawn, and steered, while it was still being built.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 8:
		await get_tree().process_frame
	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")

	_check(InputMap.has_action(&"ph_disguise") and InputMap.has_action(&"ph_taunt_menu"),
		"the game's keys are actions, from the bindings table")
	_check(client.get("player") != null and client.get("hud") != null and (client.get("hud") as Node).get("game") != null,
		"a player and a HUD bound to the world")
	client.call("open_taunts")
	var menu: Variant = (client.get("settings") as Node).get("menu") if client.get("settings") != null else null
	_check(menu != null and (menu as DotMenu).picker.is_open(), "the taunt picker opens")
	if menu != null:
		(menu as DotMenu).picker.close()
	var snapshot: Dictionary = client.call("board_snapshot")
	_check((snapshot["players"] as Array).size() >= 2, "the board lists the room")
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	(menu as DotMenu).handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player picked out")
	tab.pressed = false
	(menu as DotMenu).handle_event(tab)

	# A round started the way dot-match starts one, with this keyboard drawn to hunt. The round
	# arms its hunters and THEN begins the hide, and the client used to drop every gun at the
	# start of a hide: a hunter seeking with a gun nobody could see, in every real round.
	var world: PhGame = client.get("game")
	world.wish_side(&"local", PhGame.HUNTERS)
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	_check(world.team_of(&"local") == PhGame.HUNTERS and world.phase == PhGame.Phase.HIDE
		and client.get("weapons") != null and client.get("view_model") != null,
		"a hunter's gun is in their hands through the hide",
		"side %d, phase %d, weapons %s" % [world.team_of(&"local"), world.phase, client.get("weapons")])

	# The HUD's glance pieces are dot-ui's, handed this world's numbers.
	var hud: Node = client.get("hud")
	var me: PhPlayer = client.get("player")
	hud.call("_process", 0.0)
	# Down the sights the dot fades with the aim (dot-ui's curve), and a scope hides it.
	hud.call("set_aim", 0.0, false)
	var hip: float = (hud.get("_crosshair") as Control).modulate.a
	hud.call("set_aim", 1.0, false)
	var aimed: float = (hud.get("_crosshair") as Control).modulate.a
	hud.call("set_aim", 1.0, true)
	var scope: Control = hud.get("scope")
	_check(is_equal_approx(hip, 1.0) and (aimed < 0.01 or DotAddonApi.build_level("dot_ui") < 5)
		and (hud.get("_crosshair") as Control).modulate.a == 0.0 and is_equal_approx(float(scope.get("fraction")), 1.0)
		and bool(hud.get("loadout_offered")) == (client.get("loadout_menu") != null),
		"the crosshair is whole at the hip, gone down the sights, a scope replaces it; B is named when offered",
		"hip %.2f aimed %.2f" % [hip, aimed])
	hud.call("set_aim", 0.0, false)
	var strip: DotScoreStrip = hud.get("strip")
	var vitals: DotVitals = hud.get("vitals")
	_check(
		strip.clock == DotScoreStrip.clock_text(world.seconds_left()) and strip.sides
		and strip.left_score == world.alive_on(PhGame.PROPS) and strip.right_score == world.alive_on(PhGame.HUNTERS),
		"the clock is DotScoreStrip's, with the props and hunters still up as its plates",
		str(strip.describe())
	)
	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var themed: DotMenu = (client.get("settings") as Node).get("menu")
	var accent: Color = (load("res://game/ph_hud.gd") as GDScript).get("MAP_COLOUR")
	var plate := strip.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and strip.colour(&"highlight") == accent,
		"the HUD is dark by default, in the menu's theme, with this game's colour as its accent", str(plate))
	var _t: Variant = themed.settings.set_value(&"ui_theme", &"contrast")
	var hints: Label = hud.get("_hints")
	_check(vitals.colour(&"plate") == themed.palette().hud_plate and hints.get_theme_color(&"font_color") == themed.palette().hud_text
		and strip.colour(&"highlight") == accent,
		"a theme picked in the menu reaches the pieces and the HUD's lines at once, the accent kept")
	_t = themed.settings.set_value(&"ui_theme", &"midnight")

	me.health.health = me.health.max_health * 0.2
	hud.call("_process", 0.0)
	_check(
		vitals.visible and vitals.is_low() and vitals.fill_colour == world.side_colour(PhGame.HUNTERS),
		"health is DotVitals in the side's colour, red at a quarter", str(vitals.describe())
	)
	me.health.health = me.health.max_health

	# An undisguised prop is prompted with the disguise key as the player has it bound.
	world._set_side(&"local", PhGame.PROPS)
	hud.call("_process", 0.0)
	var prompt: DotKeyPrompt = hud.get("prompt")
	var bound := str(client.call("_key", &"ph_disguise"))
	_check(
		not me.is_disguised() and prompt.visible and prompt.key == bound and bound != "",
		"an undisguised prop is prompted by DotKeyPrompt with the bound disguise key", prompt.text()
	)

	var chat: DotGameChatClient = client.get("chat")
	var w: DotChatWindow = chat.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var plate_bottom := -(vitals.offset_top + vitals.footprint().end.y)
	_check(
		plate_bottom >= log_top,
		"a full chat log stays under the health plate",
		"log reaches %.0f px off the bottom, the plate ends %.0f off it" % [log_top, plate_bottom]
	)

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so
	# the requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
## Offline the world samples the local player's movement itself, so the client's buttons
## have to go onto that sample. They were stamped on the controller's command and then sampled
## over, and offline no hunter's trigger ever reached the world's gun (found by
## game-zombie-zone's play test; the same lines were here).
func _test_offline_trigger() -> void:
	_section("offline, the client's trigger reaches the world's gun")
	var game := await _world()
	var me := game.add_player(&"local", "You", 0, true)
	await _step(game, 2)
	var client: Node = (load("res://game/ph_client.gd") as GDScript).new()
	client.set("game", game)
	client.call("_adopt", me)
	client.set("_firing", true)
	me.simulate(game.current_tick() + 1, 1.0 / float(TICK_RATE))
	var pressed := game.weapon_command_for(me).is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_check(me.sampler != null and pressed, "the world's weapon command has the trigger the client holds")
	client.free()
	_finished()


func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := PhSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# The right mouse button aims (the family's Aim row); zee's quick melee moved to F.
	_check(keys.key_for(PhBindings.AIM) == "Mouse 2" and keys.defaults_on("Mouse 2").size() == 1
		and keys.key_for(PhBindings.BASH) == "F" and keys.defaults_on("F").size() == 1,
		"aim is the only row on the right mouse button, quick melee the only one on F",
		"%s %s" % [keys.key_for(PhBindings.AIM), keys.key_for(PhBindings.BASH)])
	# The wheel cycles a hunter's weapons, one row per direction, and no longer jumps.
	_check(keys.key_for(&"dot_menu_weapon_previous") == "Wheel up" and keys.key_for(&"dot_menu_weapon_next") == "Wheel down"
		and keys.defaults_on("Wheel up").size() == 1 and keys.defaults_on("Wheel down").size() == 1,
		"the wheel is two rows, one per direction, with nothing else on it",
		"%s %s" % [keys.key_for(&"dot_menu_weapon_previous"), keys.key_for(&"dot_menu_weapon_next")])
	# Chat is two rows, so help lists Y and U and the Controls page moves them.
	var _t := settings.settings.set_value(&"bind_chat", "J")
	_check(keys.key_for(PhBindings.CHAT) == "J" and DotInputBinding.describe_action(PhBindings.CHAT) == "J"
		and keys.key_for(PhBindings.CHAT_TEAM) == "U", "chat (Y) and team chat (U) are rows: rebinding one moves its key",
		"%s %s" % [keys.key_for(PhBindings.CHAT), keys.key_for(PhBindings.CHAT_TEAM)])
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Prop Hunt",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The play test: "weapons are completely broken". The drawn rig was given the whole pack, so each
## slot held whatever was given last (a hammer, a pistol, a purple rifle, a green sniper) and never
## the gun the server fired; the default loadout put the SMG and the shotgun in one slot; and the
## HUD said "1-3 Weapons" and nothing about what was in hand. Armed: with `give_everything` back
## the first check fails; without `correct_drawn` the last does.
func _test_hunter_weapons() -> void:
	_section("a hunter draws the guns the server armed, counted on the HUD and corrected from it")
	_check(PhGame.hunter_slot_clash(PhConfig.new().hunter_weapons) == "",
		"no two of the default hunter weapons share a slot", PhGame.hunter_slot_clash(PhConfig.new().hunter_weapons))
	_check(PhGame.hunter_slot_clash(PackedStringArray(["smg", "shotgun"])) == "smg/shotgun",
		"and two that do are named")

	var client: Node = (load("res://game/ph_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"remember_loadout", false)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	for i in 8:
		await get_tree().process_frame
	var world: PhGame = client.get("game")
	world.wish_side(&"local", PhGame.HUNTERS)
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().physics_frame

	var me: PhPlayer = client.get("player")
	var drawn: ZeeWeaponRig = client.get("weapons")
	var held: Array[String] = []
	var same := drawn != null and me.weapons != null and drawn != me.weapons
	for slot in range(1, 6):
		var mine := drawn.arsenal.slot_at(slot) if drawn != null else null
		var theirs := me.weapons.arsenal.slot_at(slot) if me.weapons != null else null
		var a := String(mine.def.id) if mine != null else "-"
		var b := String(theirs.def.id) if theirs != null else "-"
		held.append("%d:%s/%s" % [slot, a, b])
		same = same and a == b
	_check(same, "the drawn gun holds exactly the server's weapons, slot for slot", " ".join(held))
	_check(drawn != null and drawn.arsenal.current_slot() == me.weapons.arsenal.current_slot(),
		"and holds the same one")

	# Blindfolded through the hide, the counter is under the cover with everything else; seeking.
	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	_check(counter != null and not counter.visible, "no counter under the blindfold")
	world._set_phase(PhGame.Phase.SEEK)
	hud.call("_process", 0.0)
	var def := drawn.current_def() if drawn != null else null
	var expected := "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] if def != null else "?"
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and counter.count_text() == expected,
		"a hunter's HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])

	# The hints name the keys of what is carried. They said "1-3 Weapons" after grenades went on
	# slot five (d516aec), so a grenade taken on B was on a key nothing named. Armed: the old line
	# fails both.
	var hints: Label = hud.get("_hints")
	_check(hints.text.contains("1 2 3  Weapons") and not hints.text.contains("Grenade"),
		"a hunter's hints name keys 1 2 3 for the weapons and no grenade by default", hints.text)
	drawn.arsenal.give(&"frag")
	hud.call("_process", 0.0)
	var with_grenade := hints.text
	drawn.arsenal.take(ZeeIds.SLOT_THROWN)
	hud.call("_process", 0.0)
	_check(with_grenade.contains("1 2 3  Weapons   5  Grenade") and not hints.text.contains("Grenade"),
		"and key 5 for a grenade while one is carried", with_grenade)

	# Bottom right, clear of the chat box and the health plate bottom left, and of the ballot
	# top right: the anchors put it in the bottom-right quarter at any frame size.
	_check(counter.anchor_left == 1.0 and counter.anchor_top == 1.0 and counter.offset_left >= -480.0
		and counter.offset_top >= -120.0 and counter.get_theme_color(&"plate", DotHudPiece.THEME_TYPE).a > 0.0,
		"it sits bottom right, in the game's theme, clear of the chat, the health plate and the ballot")

	# A shot the server never heard: the drawn gun is five down. It holds while it could still be
	# in flight, and takes the world's count once quiet.
	var world_count := me.weapons.arsenal.current().magazine
	drawn.arsenal.current().magazine = maxi(world_count - 5, 0)
	client.set("_drawn_quiet", 0.0)
	for i in 10:
		await get_tree().physics_frame
	var early := drawn.arsenal.current().magazine
	for i in 60:
		await get_tree().physics_frame
	_check(early == maxi(world_count - 5, 0) and drawn.arsenal.current().magazine == world_count,
		"the drawn gun takes the server's count once quiet, and not before",
		"after 10 ticks %d, after 70 %d, server %d" % [early, drawn.arsenal.current().magazine, world_count])

	# The play test's "no damage shooting sinks and boxes" after he had walked into them: the
	# furniture is one static body, so nothing a hunter does moves a prop out of the box the
	# decoy check reads (`PhMap.prop_containing`, from the document).
	_check(world.map.get("_furniture") is StaticBody3D, "furniture cannot be pushed out of the place a decoy is judged at")

	# A hit the world confirms (offline the world is the server): the marker flashes. Before
	# this nothing said a hunter's shot had landed at all.
	var marker: DotHitMarker = hud.get("hit_marker")
	world.hit_landed.emit(&"local", Vector3(0.0, 1.0, -4.0), false, true)
	_check(marker != null and marker.alpha() > 0.9 and marker.headshot, "a hit the world confirms flashes the hit marker")

	world._set_side(&"local", PhGame.PROPS)
	hud.call("_process", 0.0)
	_check(not counter.visible, "a prop has no counter")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


# --- Helpers --------------------------------------------------------------------

## The family's rule since the first play test: M opens the map list, and solo a choice
## changes it now. The server's half (the owner's flag, the vote) is in `dedicated` and dot-vote.
func _test_the_map_menu() -> void:
	_section("M opens the map list, and solo a choice changes it")
	var game := await _world(func(c: PhConfig) -> void: c.map_ids = PackedStringArray())
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 4)
	var settings := PhSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows: Array = game.map_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one to choose, the one playing marked", "%d" % rows.size())
	var _maps := settings.use_maps(game.map_rows, game.change_map_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and StringName(str(game.map_doc.get("id", ""))) == wanted, "choosing one changes to it now", "%s, now %s" % [wanted, StringName(str(game.map_doc.get("id", "")))])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## Somebody who is out can fly a free camera: on by default, off by mp_freeroam, held off by
## mp_forcecamera, and a free view survives the wire with nobody in it.
func _test_free_roam() -> void:
	_section("free roam: on by default, mp_freeroam and mp_forcecamera refuse it, the mode crosses the wire")
	var stock := (load("res://game/ph_spectate.gd") as GDScript).call(&"rules_for", TICK_RATE, PhConfig.new().spectate_camera) as DotSpectatorRules
	_check(stock.allow_roaming and stock.force_camera == 0 and stock.roaming_permitted(),
		"the stock policy allows roaming: the config's spectate_camera gives force_camera 0")

	var game := await _seek_round()
	var dead: PhPlayer = game.players[&"u301"]
	_kill(game, dead, game.players[&"u300"])
	await _step(game, 2)
	var spec := game.spectate
	_check(spec.is_spectating(dead.player_id) and spec.can_roam(dead.player_id),
		"somebody who is out is offered the free camera")

	var res := spec.toggle_roam(dead.player_id)
	_check(res.ok and spec.is_roaming(dead.player_id) and spec.mode_of(dead.player_id) == DotSpectatorView.Mode.ROAMING,
		"the key puts them in a free camera", "" if res.ok else res.error.message)

	var cam := DotSpectatorFreeCam.new()
	cam.rules = spec.manager.rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var flown := cam.step(Vector3(0, 0, 1), false, false, 1.0)
	_check(flown.origin.distance_to(Vector3(0, 2, 0)) > 0.5,
		"and a second of forward flies the camera away from where it was", str(flown.origin))
	_check(spec.camera_for(dead.player_id) == Transform3D(spec.manager.view(String(dead.player_id)).free_basis, spec.manager.view(String(dead.player_id)).free_position),
		"the manager's own pose for a roaming view is the free one (the client drives it per frame)")

	var back := spec.toggle_roam(dead.player_id)
	_check(back.ok and not spec.is_roaming(dead.player_id),
		"the key again goes back onto a player or the fixed view", "" if back.ok else back.error.message)

	spec.manager.rules.allow_roaming = false
	var off := spec.toggle_roam(dead.player_id)
	_check(not off.ok and not spec.can_roam(dead.player_id) and not spec.is_roaming(dead.player_id),
		"mp_freeroam 0 refuses it")
	spec.manager.rules.allow_roaming = true

	spec.set_force_camera(1)
	var held := spec.toggle_roam(dead.player_id)
	_check(not held.ok and not spec.can_roam(dead.player_id), "mp_forcecamera 1 refuses it, and the key is not offered")
	spec.set_force_camera(0)
	_check(spec.can_roam(dead.player_id), "and mp_forcecamera 0 gives it back")

	var wire := PhEvents.read_spectate(DotNetReader.new(PhEvents.write_spectate(
		7, DotSpectatorView.Mode.ROAMING, 0, 0, Vector3.ZERO)))
	_check(bool(wire["ok"]) and int(wire["mode"]) == DotSpectatorView.Mode.ROAMING and int(wire["target"]) == 0,
		"a free view crosses the wire as ROAMING with nobody in it")

	var mirror: Node = (load("res://game/ph_spectate.gd") as GDScript).new()
	add_child(mirror)
	var made: DotResult = mirror.call(&"setup", false, TICK_RATE, 0)
	mirror.call(&"apply_view", &"u301", DotSpectatorView.Mode.ROAMING, &"", &"", Vector3.ZERO)
	_check(made.ok and bool(mirror.call(&"is_roaming", &"u301")) and bool(mirror.call(&"is_spectating", &"u301")),
		"a mirror told ROAMING with no target is roaming, not 'stopped watching'")
	remove_child(mirror)
	mirror.free()

	var ask := PhEvents.read_ask_spectate(DotNetReader.new(PhEvents.write_ask_spectate_roam()))
	var step := PhEvents.read_ask_spectate(DotNetReader.new(PhEvents.write_ask_spectate(1)))
	_check(bool(ask["ok"]) and bool(ask["roam"]) and not bool(step["roam"]) and int(step["direction"]) == 1,
		"the roam request is its own value of the spectate ask; a step is still a step")

	var binding := PhBindings.make().row_for_action(PhBindings.ROAM)
	_check(str(binding.get("default", "")) == "G", "G is the free-camera key, and a row the help screen lists")
	_finished()


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


## A death: the server picks the fall and it rides DEATH; a client lays a person down as
## dot-player-char's ragdoll from the figure it draws, and a disguised prop bursts into its own
## pieces (or, under `prop_death` 1, topples as the prop).
func _test_bodies() -> void:
	_section("the dead: a person falls as a ragdoll, a found prop bursts")
	var client: Node = (load("res://game/ph_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"remember_loadout", false)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	for i in 8:
		await get_tree().process_frame
	var world: PhGame = client.get("game")
	var ragdolls: DotPlayerRagdolls = client.get("ragdolls")
	_check(ragdolls != null and ragdolls.rules == world.ragdoll_rules,
		"the client keeps the dead under the game's sv_ragdoll* rules")
	world.wish_side(&"local", PhGame.HUNTERS)
	world._on_round_started(world.round_number + 1)
	world._set_phase(PhGame.Phase.SEEK)
	for i in 20:
		await get_tree().process_frame

	# A person: a stand-in not in disguise, drawn as a figure.
	var person: PhPlayer = null
	var prop: PhPlayer = null
	for id: StringName in world.players:
		var p: PhPlayer = world.players[id]
		if id == &"local" or not p.is_alive():
			continue
		if person == null and not p.is_disguised() and p.figure != null and p.figure.visible:
			person = p
		elif prop == null and world.team_of(id) == PhGame.PROPS and person != p:
			prop = p
	if person != null:
		var slay := DotDamage.make(0, person.entity_id, person.health.max_health * 10.0, null)
		slay.tick = world._tick
		slay.direction = Vector3(1, 0, 0)
		var _applied: Variant = world.combat.apply_damage(slay)
		await get_tree().process_frame
		_check(person.death != null and DotPlayerDeathReactions.stock().has(person.death.reaction),
			"the world picked how the body falls", str(person.death.describe()) if person.death != null else "none")
		var bodies := ragdolls.live()
		_check(bodies.size() == 1 and not person.figure.visible,
			"and the client laid the body down from the figure, which is hidden", str(bodies.size()))
		for i in 90:
			await get_tree().physics_frame
		var down := bodies.size() == 1 and is_instance_valid(bodies[0])
		var floor_y := person.controller.state.position.y
		_check(down and bodies[0].centre().y < floor_y + 0.8 and bodies[0].lowest_point() > floor_y - 0.25,
			"a second and a half on, the body lies on the floor: not standing, not through it",
			str(bodies[0].describe()) if down else "gone")
	else:
		for k in 3:
			_check(false, "a stand-in drawn as a person to slay")

	# A prop, disguised and drawn as what it is wearing: found, it bursts and leaves no body.
	var burst := false
	var toppled := false
	if prop != null and world.disguise_as(prop.player_id, &"furniture_bookcase_closed"):
		for i in 4:
			await get_tree().process_frame
		var was := ragdolls.live().size()
		var shown := prop.prop_model != null and prop.prop_model.visible
		var slay := DotDamage.make(0, prop.entity_id, prop.health.max_health * 10.0, null)
		slay.tick = world._tick
		var _applied: Variant = world.combat.apply_damage(slay)
		await get_tree().process_frame
		burst = shown and ragdolls.live().size() == was and world.get_node_or_null("PropDebris_%s" % String(prop.player_id)) != null \
			and not prop.prop_model.visible
		# The same under prop_death 1: the prop topples as one piece.
		world.config.prop_death = 1
		prop.health.revive(1.0)
		var _back := world.disguise_as(prop.player_id, &"furniture_bookcase_closed")
		for i in 4:
			await get_tree().process_frame
		var again := DotDamage.make(0, prop.entity_id, prop.health.max_health * 10.0, null)
		again.tick = world._tick
		var _hit: Variant = world.combat.apply_damage(again)
		await get_tree().process_frame
		var live := ragdolls.live()
		toppled = live.size() == was + 1 and live[live.size() - 1].style != DotPlayerRagdollRules.Style.RAGDOLL
		world.config.prop_death = 0
	_check(burst, "a found prop bursts into its own pieces, and leaves no body")
	_check(toppled, "and under prop_death 1 it topples as the prop, one stiff piece")

	# The fall rides DEATH last and optional, so a death from an older server still reads.
	var fall := DotPlayerDeath.new()
	fall.reaction = &"face_plant"
	fall.roll_seed = 1234
	fall.direction = Vector3(1, 0, 0)
	var died := PhEvents.read_death(DotNetReader.new(PhEvents.write_death(5, 6, PhGame.DIED_SHOT, fall)))
	var carried: DotPlayerDeath = died.get("death")
	var bare := PhEvents.read_death(DotNetReader.new(PhEvents.write_death(5, 6, PhGame.DIED_SHOT)))
	_check(bool(died["ok"]) and carried != null and carried.reaction == &"face_plant" and carried.roll_seed == 1234
		and bool(bare["ok"]) and not bare.has("death"),
		"a DEATH carries the fall the server picked, and one without a fall still reads")

	var catalogue: DotAudioCatalogue = (load("res://game/ph_audio.gd") as GDScript).call("sound_catalogue")
	var listed := not DotPlayerDeathSounds.rows().is_empty()
	for row: Dictionary in DotPlayerDeathSounds.rows():
		listed = listed and catalogue.find(row["id"]) != null
	_check(listed, "the death sounds are in the game's catalogue")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## A world on the practice house, stepped by hand. The previous one is freed first: every
## world here shares ONE physics space, and every map is built at the origin.
func _world(configure: Callable = Callable()) -> PhGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["ph_practice"])
	config.keep_progress = true
	config.hide_seconds = 2.0

	if configure.is_valid():
		configure.call(config)

	var game := PhGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	await _physics_frame()
	await _physics_frame()
	return game


## A world in the hide, with a hunter and two props.
func _hide_round(configure: Callable = Callable()) -> PhGame:
	var game := await _world(configure)
	var hunter := game.add_player(&"u300", "Hunter")
	game.wish_side(hunter.player_id, PhGame.HUNTERS)
	for i in range(2):
		var prop := game.add_player(StringName("u%d" % (301 + i)), "Prop%d" % i)
		game.wish_side(prop.player_id, PhGame.PROPS)
	game.start()
	await _wait_for(game, PhGame.Phase.HIDE)
	return game


## A world where the hunters are seeking.
func _seek_round(configure: Callable = Callable()) -> PhGame:
	var game := await _hide_round(func(c: PhConfig) -> void:
		c.hide_seconds = 0.25
		if configure.is_valid():
			configure.call(c))
	await _wait_for(game, PhGame.Phase.SEEK)
	return game


func _wait_for(game: PhGame, phase: int) -> void:
	for i in range(TICK_RATE * 20):
		if game.phase == phase:
			return
		await _step(game, 1)


## Ends the round in play (the hunters win) and waits for the next to begin.
func _end_round(game: PhGame) -> void:
	var number := game.round_number
	for prop in game.players_on(PhGame.PROPS):
		if prop.is_alive():
			_kill(game, prop, null)
	for i in range(TICK_RATE * 20):
		await _step(game, 1)
		if game.round_number > number and game.phase == PhGame.Phase.HIDE:
			return


func _kill(game: PhGame, victim: PhPlayer, by: PhPlayer) -> void:
	var damage := DotDamage.make(by.entity_id if by != null else 0, victim.entity_id, 10000.0, null)
	damage.context = {"why": PhGame.DIED_SHOT}
	var _applied := game.combat.apply_damage(damage)


func _step(game: PhGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: PhGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


func _drive(player: PhPlayer, move: Vector2) -> void:
	var command := DotFpsCommand.new()
	command.yaw = player.controller.state.yaw
	command.move = move
	player.controller.apply_command(command)


## Puts [param player] at [param at], looking at [param target].
func _stand_facing(player: PhPlayer, at: Vector3, target: Vector3) -> void:
	player.place_at(at, 0.0)
	_aim(player, target)


func _aim(player: PhPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _fire(player: PhPlayer, on: bool) -> void:
	var command := player.controller.current_command
	if command == null:
		command = DotFpsCommand.new()
	command.set_button(DotFpsCommand.BUTTON_USER_0, on)
	player.controller.apply_command(command)


func _reload(player: PhPlayer, on: bool) -> void:
	var command := player.controller.current_command
	if command == null:
		command = DotFpsCommand.new()
	command.set_button(DotFpsCommand.BUTTON_USER_2, on)
	player.controller.apply_command(command)


func _prop_near(game: PhGame, at: Vector3) -> int:
	for index in range(game.map.props.size()):
		if ((game.map.props[index] as Dictionary)["transform"] as Transform3D).origin.distance_to(at) < 0.05:
			return index
	return -1


static func _spread(turns: Dictionary, ids: Array[StringName]) -> Vector2i:
	var lo := 999
	var hi := 0
	for id in ids:
		lo = mini(lo, int(turns.get(id, 0)))
		hi = maxi(hi, int(turns.get(id, 0)))
	return Vector2i(lo, hi)


## B, a hunter's loadout (dot-loadout's DotLoadoutCommand on the world's own manager, as the
## solo client asks it): a primary and a secondary from the hunters' weapons, in the hands at
## once while the hunters are blindfolded, and only from the next round once the seek is on.
func _test_hunter_loadout() -> void:
	_section("B: a hunter's loadout, handed over in the hide and kept for the next round in the seek")
	var game := await _hide_round()
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var cmd: Object = game.loadout_command
	var ready := game.loadouts != null and cmd != null and DotLoadoutKey.is_usable(PhGame.storage_key(hunter.player_id))
	_check(ready, "the world keeps loadouts, has the B menu's server half, and a usable key per player")
	if not ready:
		_finished()
		return
	var key := PhGame.storage_key(hunter.player_id)
	var offer: Dictionary = await cmd.call(&"offer", key)
	var choices := {}
	var current := {}
	for slot: Dictionary in offer.get("slots", []):
		choices[slot["id"]] = (slot["choices"] as Array).map(func(c: Dictionary) -> String: return str(c["id"]))
		current[slot["id"]] = str(slot["current"])
	_check(choices.keys().size() == 3 and (choices.get("primary", []) as Array).has("shotgun")
		and (choices.get("secondary", []) as Array).has("revolver") and not (choices.get("primary", []) as Array).has("hatchet")
		and current.get("primary") == "smg" and current.get("secondary") == "pistol",
		"the offer is a primary, a secondary and a grenade from the hunters' weapons, the SMG and the pistol by default", str(choices))
	_check((choices.get("thrown", []) as Array).has("frag") and (choices.get("thrown", []) as Array).has("sticky")
		and current.get("thrown", "") == "" and hunter.weapons != null and not hunter.weapons.arsenal.carries(&"frag"),
		"the grenade is a frag or a sticky, and nobody carries one they did not choose", "%s, current %s" % [str(choices.get("thrown")), str(current.get("thrown"))])

	var now: Dictionary = await cmd.call(&"choose", null, key, {"primary": "shotgun"})
	var arsenal := hunter.weapons.arsenal if hunter.weapons != null else null
	_check(bool(now.get("ok")) and bool(now.get("now")) and arsenal != null and arsenal.carries(&"shotgun")
		and not arsenal.carries(&"smg") and arsenal.carries(&"pistol") and arsenal.carries(&"hatchet"),
		"chosen in the hide, the shotgun is in the hunter's hands at once, beside the pistol and the hatchet", str(now))
	var with_frag: Dictionary = await cmd.call(&"choose", null, key, {"thrown": "frag"})
	arsenal = hunter.weapons.arsenal if hunter.weapons != null else null
	_check(bool(with_frag.get("ok")) and arsenal != null and arsenal.carries(&"frag") and arsenal.carries(&"shotgun"),
		"and a frag chosen in the hide is in slot five beside them", str(with_frag))

	await _wait_for(game, PhGame.Phase.SEEK)
	var later: Dictionary = await cmd.call(&"choose", null, key, {"primary": "carbine"})
	_check(bool(later.get("ok")) and not bool(later.get("now")) and arsenal.carries(&"shotgun"),
		"chosen in the seek it waits: no free reload in the middle of a search", str(later))

	game.wish_side(hunter.player_id, PhGame.HUNTERS)
	game._on_round_started(game.round_number + 1)
	await _step(game, 2)
	arsenal = hunter.weapons.arsenal if hunter.weapons != null else null
	_check(game.team_of(hunter.player_id) == PhGame.HUNTERS and arsenal != null and arsenal.carries(&"carbine")
		and not arsenal.carries(&"shotgun"), "and the next round hands it out")
	_finished()
