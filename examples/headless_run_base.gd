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
