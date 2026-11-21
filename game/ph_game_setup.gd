extends "ph_game_rotation.gd"

## The setup half of [code]ph_game.gd[/code]: the effects, progress and spectate nodes, sides drawn and set, a hunter armed, movement adopted.

signal side_changed(player_id: StringName, side: int)
signal achievement_earned(player_id: StringName, title: String, points: int)
signal player_armed(player_id: StringName, weapon_id: StringName)

## Aim-down-sights numbers (`zee_ads_rules`, REPLICATED): the server's cfg over the shipped defaults, handed to every weapon
## rig. Bound by the module and followed by a client, so its prediction agrees. Nothing sets the aim bit yet.
var ads_rules: ZeeAdsRules = ZeeAdsRules.load_config()
## The burst drawn where a grenade went off (dot-fx).
const BLAST_FX := &"blast"
var effects: GSFxManager = null
## Who has had the hunters' role, for [GSTeamRotation].
var hunter_history: Dictionary = {}
const HUNTERS := 2
var map: PhMap = null
## The map this round is played on.
var map_doc: Dictionary = {}
var match_node: GSMatch = null
const PhMap := preload("ph_map.gd")
const PhPaths := preload("ph_paths.gd")
const PhPlayer := preload("ph_player.gd")
const PhProgress := preload("ph_progress.gd")
const PhProjectiles := preload("ph_projectiles.gd")
const PhSpectate := preload("ph_spectate.gd")
## player id -> PhPlayer.
var players: Dictionary = {}
var progress: PhProgress = null
## The hunters' grenades in flight (`ph_projectiles.gd`): flown on the server and solo, and as
## copies on a client from the LAUNCH events (`PhNetBridge`), which decide nothing.
var projectiles: PhProjectiles = null
## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const PROPS := 1
var round_number: int = 0
var _round_seed: int = 0
## player id -> side.
var sides: Dictionary = {}
var spectate: PhSpectate = null
var _tick: int = 0
@export var authoritative: bool = true
@export_range(1, 240, 1) var tick_rate: int = 64
## Whether the map is drawn. A client sets it.
@export var draw_world: bool = false


## The gravity the movement is tuned against, on this world's own physics SPACE: a project
## setting does not travel with a delivered pack.
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


## The server's movement numbers (its HELLO), so this client predicts with what the server simulates.
func adopt_movement(move: PackedFloat32Array, auto_hop: bool) -> void:
	if move.size() < 9:
		return
	config.run_speed = move[0]
	config.walk_speed_scale = move[1]
	config.jump_height = move[2]
	config.gravity = move[3]
	config.air_accelerate = move[4]
	config.accelerate = move[5]
	config.friction = move[6]
	config.stop_speed = move[7]
	config.crouch_speed_scale = move[8]
	config.auto_bunny_hop = auto_hop
	_apply_gravity()
	if projectiles != null:
		projectiles.set_gravity(config.gravity)
	if map != null:
		map.gravity = config.gravity
	for id: StringName in players:
		(players[id] as PhPlayer).retune()


func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var fx := GSFxCatalogue.new()

	var go := GSFxDef.new()
	go.id = &"go"
	go.kind = GSFxDef.Kind.SCREEN
	go.flash_peak = 0.18
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	fx.add(go)

	var hurt := GSFxDef.new()
	hurt.id = &"hurt"
	hurt.kind = GSFxDef.Kind.SCREEN
	hurt.flash_peak = 0.3
	hurt.flash_colour = Color(0.9, 0.1, 0.1, 1.0)
	hurt.flash_decay_ms = 260
	fx.add(hurt)

	# A grenade going off: a fireball, smoke, sparks and a light (game-fatal-contact's scene, copied). At
	# every quality: where something went off is information, not decoration.
	var blast := GSFxDef.new()
	blast.id = BLAST_FX
	blast.scene_path = PhPaths.rebase("res://scenes/fx/explosion.tscn")
	blast.lifetime_ms = 1400
	blast.cost = 10
	blast.priority = 85
	blast.max_distance = 140.0
	fx.add(blast)

	effects = GSFxManager.new()
	effects.name = "Effects"
	effects.catalogue = fx
	effects.config = GSFxConfig.new()
	effects.register_as_service = false
	add_child(effects)
	GSLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_spectate() -> void:
	spectate = PhSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.authoritative = authoritative
	spectate.tick_rate = tick_rate
	spectate.force_camera = config.spectate_camera
	add_child(spectate)

	var ready_now := spectate.setup()

	if not ready_now.ok:
		GSLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = PhProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		GSLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


## Who hunts this round: [GSTeamRotation], with the server's mode and the players' wishes.
func _draw_sides() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var wishes := {}

	if config.allow_side_choice:
		for id in keys:
			match (players[id] as PhPlayer).side_wish:
				HUNTERS:
					wishes[id] = 1
				PROPS:
					wishes[id] = -1

	# A map may ask for its own share of hunters: a big school with a hiding place every few
	# metres wants more of them than a cottage (`ph-bots-map-spread-1`).
	var want := config.hunters_for(keys.size(), float(map_doc.get("players_per_hunter", 0.0)))
	var picked: Dictionary = GSTeamRotation.pick(
		keys, want, config.hunter_pick as GSTeamRotation.Mode, hunter_history, _round_seed, wishes
	)
	GSTeamRotation.note(hunter_history, keys, picked["picked"], round_number)

	for id in keys:
		_set_side(id, HUNTERS if (picked["picked"] as Array).has(id) else PROPS)

	if not keys.is_empty():
		GSLog.debug(CHANNEL, "hunters drawn", {"why": str(picked["why"])})


func _set_side(id: StringName, side: int) -> void:
	var player: PhPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


## The next map, built; also every map this server plays, as the map menu (M) lists them: `{id, name, detail, current}`.
## Solo the client's list, online the server's (the module hands it to dot-vote's map menu), so both say the same.
func map_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(map_doc.get("id", "")))
	for id in catalogue.playable(config.map_ids):
		var doc: Dictionary = catalogue.maps.get(id, {})
		var detail := str(doc.get("blurb", ""))
		if not catalogue.in_rotation(id):
			detail = ("%s (not in rotation)" % detail).strip_edges()
		var row := {"id": String(id), "name": catalogue.label_of(id), "current": id == now,
			"detail": detail}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


func weapon_command_for(player: PhPlayer) -> GSWeaponCommand:
	var command := GSWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(GSWeaponCommand.BUTTON_ATTACK, pending.is_pressed(GSFpsCommand.BUTTON_USER_0))
	command.set_button(GSWeaponCommand.BUTTON_ALT, pending.is_pressed(GSFpsCommand.BUTTON_USER_1))
	command.set_button(GSWeaponCommand.BUTTON_RELOAD, pending.is_pressed(GSFpsCommand.BUTTON_USER_2))
	command.set_button(GSWeaponCommand.BUTTON_AIM, player.aiming)
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


## Everybody against the map's toys, after they moved: a walk into a barrel or a ball
## sends it on; then the box's own tick (the awake cap, the lost sent home). Server side.
func _advance_toys(delta: float) -> void:
	if map == null or map.toys == null or map.toys.count() == 0:
		return
	for id: StringName in players:
		var player: PhPlayer = players[id]
		if not player.is_alive() or player.watching:
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := map.toys.push_from(state.position, state.velocity, radius, height)
	map.toys.advance(delta)
