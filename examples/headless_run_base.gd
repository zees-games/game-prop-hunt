extends DotGameCheckSuite

## Shared constants and helpers for headless_run.gd: world builders, stepping and driving.

const PhBindings := preload("../game/ph_bindings.gd")
const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhClient := preload("../game/ph_client.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhController := preload("../game/ph_controller.gd")
const PhFigure := preload("../game/ph_figure.gd")
const PhGame := preload("../game/ph_game.gd")
const PhInterest := preload("../game/net/ph_interest.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")
const PhPlayer := preload("../game/ph_player.gd")
const PhProgress := preload("../game/ph_progress.gd")
const PhProps := preload("../game/ph_props.gd")
const ZeeIds := preload("res://addons/zee_weapons/content/zee_weapon_ids.gd")
const PhSettings := preload("../game/ph_settings.gd")
const PhEvents := preload("../game/net/ph_events.gd")

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)
## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)

## The bookcase on the south wall of the living room, a decoy to shoot.
const BOOKCASE_AT := Vector3(-4.0, 0.0, 7.6)

var _sections_entered := 0
var _sections_finished := 0
var _worlds: Array[PhGame] = []


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1



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


## Somebody who is out can fly a free camera: on by default, off by mp_freeroam, held off by
## mp_forcecamera, and a free view survives the wire with nobody in it.
func _test_free_roam() -> void:
	_section("free roam: on by default, mp_freeroam and mp_forcecamera refuse it, the mode crosses the wire")
	var stock_host: DotSpectatorHost = (load("res://game/ph_spectate.gd") as GDScript).new()
	stock_host.tick_rate = TICK_RATE
	var stock := stock_host.tune_rules(DotSpectatorRules.new())
	stock_host.free()
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
	var playing: PhPlayer = game.players[&"u300"]
	var refused := spec.toggle_roam(playing.player_id)
	_check(not spec.is_spectating(playing.player_id) and not refused.ok and not spec.can_roam(playing.player_id),
		"somebody still playing cannot roam")

	var wire := PhEvents.read_spectate(DotNetReader.new(PhEvents.write_spectate(
		7, DotSpectatorView.Mode.ROAMING, 0, 0, Vector3.ZERO)))
	_check(bool(wire["ok"]) and int(wire["mode"]) == DotSpectatorView.Mode.ROAMING and int(wire["target"]) == 0,
		"a free view crosses the wire as ROAMING with nobody in it")

	var mirror: Node = (load("res://game/ph_spectate.gd") as GDScript).new()
	mirror.set(&"authoritative", false)
	mirror.set(&"tick_rate", TICK_RATE)
	add_child(mirror)
	var made: DotResult = mirror.call(&"setup")
	mirror.call(&"apply_view", &"u301", DotSpectatorView.Mode.ROAMING, &"", &"", Vector3.ZERO)
	_check(made.ok and bool(mirror.call(&"is_roaming", &"u301")) and bool(mirror.call(&"is_spectating", &"u301")),
		"a mirror told ROAMING with no target is roaming, not 'stopped watching'")
	var told: DotResult = mirror.call(&"toggle_roam", &"u301")
	_check(not told.ok, "a spectating mirror cannot ask to roam; it is told")
	remove_child(mirror)
	mirror.free()

	var ask := PhEvents.read_ask_spectate(DotNetReader.new(PhEvents.write_ask_spectate_roam()))
	var step := PhEvents.read_ask_spectate(DotNetReader.new(PhEvents.write_ask_spectate(1)))
	_check(bool(ask["ok"]) and bool(ask["roam"]) and not bool(step["roam"]) and int(step["direction"]) == 1,
		"the roam request is its own value of the spectate ask; a step is still a step")

	var binding := PhBindings.make().row_for_action(PhBindings.ROAM)
	_check(str(binding.get("default", "")) == "G", "G is the free-camera key, and a row the help screen lists")
	_finished()


func _test_fall_damage() -> void:
	_section("sv_falldamage: a hard landing costs health, a short drop and the cvar off cost none")
	var game := await _seek_round()
	var me = game.players[&"u300"]
	_check(game.fall_rules.enabled and me.get_node_or_null("FallDamage") != null, "on in this game, a component per player")
	var floor_at: Vector3 = me.controller.state.position
	var hurt := {}
	for case in [["high", 14.0, true], ["short", 0.6, true], ["off", 14.0, false]]:
		game.fall_rules.enabled = case[2]
		me.health.health = me.health.max_health
		me.place_at(floor_at + Vector3(0.0, case[1], 0.0), 0.0)
		await _step(game, TICK_RATE * 2)
		hurt[case[0]] = me.health.max_health - me.health.health
	_check(hurt["high"] > 0.0, "a drop from 14 m hurts", "lost %.1f" % hurt["high"])
	_check(hurt["short"] == 0.0, "a short drop does not", "lost %.1f" % hurt["short"])
	_check(hurt["off"] == 0.0, "cvar off: a 14 m drop does not hurt", "lost %.1f" % hurt["off"])
	_finished()


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
	var prop_bots: Array[PhPlayer] = []
	for id: StringName in world.players:
		var p: PhPlayer = world.players[id]
		if id == &"local" or not p.is_alive():
			continue
		if person == null and not p.is_disguised() and p.figure != null and p.figure.visible:
			person = p
		elif world.team_of(id) == PhGame.PROPS and person != p:
			prop_bots.append(p)
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
		# The reaction is seeded by the world's tick, which depends on how many physics frames the
		# process frames above spanned, so a launch may still be airborne at 1.5 s: wait up to 6 s
		# for the body to lie down rather than assume which fall was picked.
		var down := bodies.size() == 1 and is_instance_valid(bodies[0])
		var floor_y := person.controller.state.position.y
		var lies := false
		for i in 360:
			await get_tree().physics_frame
			down = bodies.size() == 1 and is_instance_valid(bodies[0])
			lies = down and bodies[0].centre().y < floor_y + 0.8 and bodies[0].lowest_point() > floor_y - 0.25
			if i >= 89 and lies:
				break
		_check(lies,
			"within six seconds the body lies on the floor: not standing, not through it",
			str(bodies[0].describe()) if down else "gone")
	else:
		for k in 3:
			_check(false, "a stand-in drawn as a person to slay")

	await _check_prop_bursts(world, ragdolls, prop_bots)

	_check_death_wire()

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## A found prop bursts (or topples under `prop_death` 1) and leaves no body.
func _check_prop_bursts(world: PhGame, ragdolls: DotPlayerRagdolls, prop_bots: Array[PhPlayer]) -> void:
	var prop: PhPlayer = null
	# A prop, disguised and drawn as what it is wearing: found, it bursts and leaves no body.
	var burst := false
	var toppled := false
	# A bot may be hiding where a bookcase does not fit (the server refuses with "no room"), so
	# the first stand-in that has room for one is the one found.
	for candidate in prop_bots:
		if world.disguise_as(candidate.player_id, &"furniture_bookcase_closed"):
			prop = candidate
			break
	if prop != null:
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


## The fall rides DEATH last and optional; the death sounds are in the catalogue.
func _check_death_wire() -> void:
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
