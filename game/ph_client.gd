extends "ph_client_settings.gd"

const KillPovView := preload("ph_kill_pov_view.gd")
const PhBreakFx := preload("ph_break_fx.gd")
const PhServices := preload("ph_services.gd")
const PhNetCommand := preload("net/ph_net_command.gd")
const PhPlayerNet := preload("net/ph_player_net.gd")

const PhConfig := preload("ph_config.gd")
const PhPaths := preload("ph_paths.gd")
const PhProjectileView := preload("ph_projectile_view.gd")

## One local player, a camera and a HUD over a [PhGame], offline or against a server. The offline half is not a demo mode:
## the same world class with `authoritative` true, and all the difference is [PhNetBridge]. A [DotClientLink] in the registry
## under `dot_client_link` means connected; `--offline` forces solo. A prop sees itself in third person (F5 swaps), a hunter down a gun.


## How far behind a prop the camera hangs: this plus its size.
const CHASE_BACK := 2.4
const CHASE_UP := 0.8

@export var config_file: String = "user://cfg/prophunt.json"
@export var force_offline: bool = false

## How many stand-ins an offline round gets.
@export_range(0, 12, 1) var offline_bots: int = 5

var camera: Camera3D = null

## The grenades in the air, drawn from the world's list (`PhProjectiles`).
var projectile_view: PhProjectileView = null

## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null

## Whether the camera hangs behind the player. Follows the side; F5 swaps it.
var third_person: bool = false

## The flashlight on the eye and the others' beams (dot-flashlight); the server owns on/off.
var flash: DotFlashlight = null
var flash_crowd: DotFlashlightCrowd = null
var _flash_msec := -100000
var _flash_retain := 0.0

## Whether the player chose the view with F5 this round, which the side then leaves alone.
var _view_chosen: bool = false

var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null
var _rig_height: float = 0.0

var _firing: bool = false
var _alt: bool = false

## The lens before an aim zooms it: the menu's field of view lands here, not on the camera, so
## the zoom always scales the player's own setting and never compounds frame to frame.
var base_fov: float = 90.0
var _reloading: bool = false
var _slot: int = 0
var _wheel: DotWeaponWheel

## The last whole second of the hide a beep was played for.
var _beeped: int = -1

## Covers the screen, and keeps the local body and the input still, until the level is built,
## the local player exists and its camera is current. It is [member DotGameClient.gate].
var gate: DotLoadGate = null


func _ready() -> void:
	# First, before anything can be drawn: the platform puts the loading cover up, held until the
	# player exists and the camera is current, and finds the link.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.spawned_fn = func() -> bool: return player != null
	platform.scoreboard_action = PhBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate
	ZeeModelCache.set_asset_root(PhPaths.root())

	var config := PhConfig.new()
	var binder := PhConfig.make_binder(config, config_file)
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	link = platform.link as Node
	_offline = platform.offline

	game = PhGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.authoritative = _offline
	game.register_service = _offline
	game.tick_rate = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64))
	game.draw_world = true
	# Before the world is added, in case a world lays its first map out in its own _ready.
	_hold_for_maps()
	add_child(game)
	_build_ragdolls()
	_build_projectile_view()

	_sampler = PhPlayer.make_sampler(PhPlayer.tunables_for(config))
	PhPlayer.register_actions(_sampler)

	_build_hud()
	_build_touch()
	_build_chat()
	_build_audio()
	_build_settings()
	_build_killcam()
	_build_break_rules()
	_build_break_fx()

	if _offline:
		_start_offline()
	else:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "the netcode", netted)
		if netted.ok and link != null:
			_start_remote_workbench()


## The load gate is [member DotGameClient.gate]. Without it the first frames showed a half-built world: the body fell while shaders
## compiled, a HUD had no player until JOIN, and a map change tore the level down in front of a falling body. A frozen player is also
## skipped by [method PhPlayer.simulate]. Held while the old map goes, released once the new one stands ([signal PhGame.world_clearing], [signal PhGame.world_rebuilt]).
func _hold_for_maps() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the map"))
	game.world_rebuilt.connect(func() -> void: gate.release(&"map"))


## True while the load gate covers the screen: no input, no prediction sampling.
func _covered() -> bool:
	return gate != null and not gate.is_open()


func _exit_tree() -> void:
	ZeeModelCache.set_asset_root("res://")


## The grenades drawn, and a burst and a bang where each goes off: offline from the world's own,
## online from the copies the server's LAUNCH events start, which go off where the server's did.
func _build_projectile_view() -> void:
	projectile_view = PhProjectileView.new()
	projectile_view.name = "Projectiles"
	projectile_view.projectiles = game.projectiles
	add_child(projectile_view)
	game.blast_drawn.connect(_on_blast)


func _on_blast(at: Vector3, _weapon_id: StringName) -> void:
	if game.effects != null:
		var _burst := game.effects.spawn(PhGame.BLAST_FX, Transform3D(Basis.IDENTITY, at))
	if audio != null:
		var _heard := audio.on_blast(at)


func _start_offline() -> void:
	for i in range(offline_bots):
		var bot := game.add_player(StringName("u%d" % (PhNetBridge.FIRST_BOT_SESSION + i)), _bot_name(i))
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 0, true))
	_hear_the_world()

	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	# Offline the world is the authority, so its own word on a hit is the confirmation.
	game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
		if id == &"local":
			_on_hit(point, killed, headshot))
	game.start()
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## A solo stand-in's name: the server's list, through dot-bot's pick, so solo and a server
## name them alike.
static func _bot_name(index: int) -> String:
	var taken: Array = []
	for i in range(index):
		taken.append(DotBotNames.pick(taken, i, PhGame.BOT_NAMES))
	return DotBotNames.pick(taken, index, PhGame.BOT_NAMES)


## The client's network manager, configured and added; `net.setup()` follows.
func _make_net() -> void:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = game.tick_rate
	net_config.snapshot_rate = PhGame.NET_SNAPSHOT_RATE
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 0
	net_config.world_extent = PhGame.NET_WORLD_EXTENT
	net.config = net_config
	add_child(net)


## Routes the bridge's signals to this client's handlers.
func _connect_bridge() -> void:
	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.armed_received.connect(_on_armed)
	bridge.weapon_net.lost_received.connect(_on_weapon_lost)
	bridge.hit_received.connect(_on_hit)
	bridge.map_received.connect(_on_map)
	bridge.disguise_received.connect(_on_disguise)
	bridge.taunt_received.connect(_on_taunt)
	bridge.decoy_received.connect(_on_decoy)
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
		if audio != null:
			var _denied := audio.deny())
	bridge.weapon_used_by.connect(func(session_id: int, _times: int, kind: int) -> void:
		if session_id == _watch_id or audio == null:
			return
		var who: PhPlayer = game.players.get(PhNetBridge.player_key(session_id))
		if who != null:
			var _heard := audio.on_weapon(who.global_position, kind))


func _build_netcode() -> DotResult:
	# The server's `mp_teammate_passthrough` and every change to it, through the link: this end traces its own shots,
	# and against a server on 0 or 2 they ended in (or went through) a team-mate where the server's did not.
	# An older shell's link cannot say, and the manager keeps its default.
	if game.combat != null and link != null:
		var _following := game.combat.follow_cvars(link)

	_make_net()

	var started := net.setup()

	if not started.ok:
		return started

	bridge = PhNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	bridge.open_link(link)
	_follow_server_cvars()
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame.
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()

	_connect_bridge()

	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


## Follows the server's replicated cvars this end draws by: view, ambience, free camera, ragdolls, toys and the killcam time.
func _follow_server_cvars() -> void:
	# The server's mp_forceview: this end places its own camera.
	var _view := game.view_rules.follow_cvars(link)
	var _mobile := game.mobile_rules.follow_cvars(link)
	var _ambient := game.ambient_rules.follow_cvars(link)
	# mp_forcecamera, mp_freeroam and mp_freeroam_speed: whether the free camera is offered, and
	# how fast it flies. A change redraws the hint, so a key that would now be refused is not
	# advertised.
	if game.spectate != null and game.spectate.manager != null:
		var _roam := game.spectate.manager.rules.follow_cvars(link)
		game.spectate.manager.rules.rules_changed.connect(_refresh_watching_line)
	# The server's sv_ragdoll* set: this end draws the bodies.
	var _dead := game.ragdoll_rules.follow_cvars(link)
	# And sv_toys*: a client hides the toys a server took away.
	var _toys := game.toy_rules.follow_cvars(link)
	# And zee_ads_rules: this end predicts the server's aimed pace and spread.
	var _ads := game.ads_rules.follow_cvars(link)
	if link.has_method(&"replicated_cvar"):
		_on_killcam_cvar("mp_killcam_time", String(link.call(&"replicated_cvar", "mp_killcam_time", "")))
		_on_killcam_cvar("mp_killview_camera", String(link.call(&"replicated_cvar", "mp_killview_camera", "")))
		if link.has_signal(&"replicated_cvar_changed"):
			link.connect(&"replicated_cvar_changed", _on_killcam_cvar)


func _say_ready() -> void:
	if workbench_remote != null:
		workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(PhNetBridge.player_key(session_id)))


func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(PhNetBridge.player_key(session_id)))

	if session_id == _watch_id:
		_follow_side()


func _adopt(candidate: PhPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	# A client built without its _ready (a suite adopting a body) has no gate.
	if gate != null:
		gate.freeze(player)

	_follow_side()
	_build_camera()

	# Offline the world samples this player's movement itself, so the buttons go onto that
	# sample (`command_stamp`); stamping `current_command` below only reaches the drawn gun.
	if _offline:
		player.command_stamp = _stamp

	if settings != null:
		settings.bind_camera(self, &"base_fov")
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)

	_bind_touch_sampler(player.sampler)

	_restore_loadout.call_deferred()


## Third person for a prop, first for a hunter — unless the player chose with F5 this round.
func _follow_side() -> void:
	if player == null or _view_chosen:
		return

	var want := game.view_rules.resolve(game.team_of(player.player_id) != PhGame.HUNTERS)

	if want != third_person:
		third_person = want
		_place_camera()


## Offline: the world is the authority, so its own signals are what happened. A connected
## client hears the same from the bridge and calls the same functions with the same arguments,
## so the two can only differ in where a fact came from.
func _hear_the_world() -> void:
	game.world_rebuilt.connect(func() -> void: _on_map(game.map.id()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _map: StringName) -> void: _on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: _on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName, weapon_id: StringName) -> void:
		_on_death(_session(id), _session(by) if by != &"" else 0, why, weapon_id))
	game.disguise_changed.connect(func(id: StringName) -> void:
		var who: PhPlayer = game.players.get(id)
		_on_disguise(_session(id), who != null and who.set_aside != null and not who.is_disguised()))
	game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
		_on_taunt(_session(id), taunt_id, forced))
	game.decoy_hit.connect(func(id: StringName, amount: float) -> void:
		if id == &"local":
			_on_decoy(amount))
	game.refused.connect(func(id: StringName, why: String) -> void:
		if id == &"local" and chat != null:
			chat.notice(why)
			if audio != null:
				var _denied := audio.deny())
	game.weapon_layer.lost.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_weapon_lost(_watch_id, weapon))
	game.weapon_layer.picked.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon))
	game.player_armed.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon)
		else:
			_hear_rig(game.players.get(id)))
	game.side_changed.connect(func(id: StringName, _side: int) -> void:
		if id == &"local":
			_follow_side())


## The local world's ids are `local` for this keyboard and `u<session>` for everybody else.
func _session(id: StringName) -> int:
	return _watch_id if id == &"local" else PhNetBridge.session_of(id)


func _hear_rig(armed: PhPlayer) -> void:
	if armed == null or audio == null or armed.weapons == null:
		return
	if armed.weapons.used.is_connected(_on_rig_used.bind(armed)):
		return
	armed.weapons.used.connect(_on_rig_used.bind(armed))


func _on_rig_used(outcome: DotWeaponOutcome, armed: PhPlayer) -> void:
	if audio != null and is_instance_valid(armed):
		var _heard := audio.on_weapon(armed.global_position, ZeeWeaponNet.kind_number(outcome.kind))


func _on_phase(phase: int) -> void:
	if hud == null or player == null:
		return

	var hunter := is_hunter()

	match phase:
		PhGame.Phase.HIDE:
						# Only a prop puts last round's gun down: a round arms its hunters BEFORE the hide starts,
						# so dropping every gun here took the one just handed out and a hunter sought all round with a gun nobody could see.
			if not hunter:
				_disarm_locally()
			_view_chosen = false
			_follow_side()
			if audio != null:
				var _heard := audio.on_hide()
			if hunter:
				hud.shout("YOU ARE A HUNTER — wait while they hide", 3.5)
			else:
				hud.shout("HIDE — %s becomes what you look at" % _key(PhBindings.DISGUISE), 3.5)
		PhGame.Phase.SEEK:
			if audio != null:
				var _heard := audio.on_seek()
			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
			hud.shout("READY OR NOT" if hunter else "THE HUNTERS ARE COMING", 2.4)


func is_hunter() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == PhGame.HUNTERS


func _on_map(map_id: StringName) -> void:
	if flash != null:
		flash.allowed = DotFlashlightRules.allowed_on(game.flashlight_conf(), str(map_id))

	# The new map's toys are heard: a ball's bounce, a barrel's knock.
	if game.map != null and game.map.toys != null and audio != null and not game.map.toys.sound.is_connected(_toy_sound):
		var _c := game.map.toys.sound.connect(_toy_sound)

	if ragdolls != null:
		# A body on the old map would hang in the new one's air.
		ragdolls.clear()

	if audio != null:
		audio.on_map_doc(map_id, game.map_doc)

	var name_of := str(game.map_doc.get("name", ""))
	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.map_doc.get("author", ""))
		var blurb := str(game.map_doc.get("blurb", ""))
		chat.say_locally("%s%s%s" % [name_of, " by %s" % author if author != "" else "",
			" — %s" % blurb if blurb != "" else ""], Color(0.80, 0.90, 1.0))


func _on_round(number: int, began: bool, winner: int, why: String = "") -> void:
	if began:
		hud.shout("ROUND %d" % number, 2.0)
		_end_round_presentation()
		return

	if audio != null and player != null:
		var _heard := audio.on_round_end(winner != 0 and game.team_of(player.player_id) == winner)

	var who := game.side_name(winner).to_upper() + " WIN" if winner != 0 else "DRAW"
	hud.shout("%s — %s" % [who, why] if why != "" else who, 4.0)

	_begin_round_end(number, winner, why)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))


func _on_disguise(session_id: int, revealed: bool) -> void:
	var who := _player_of(session_id)

	if who == null:
		return

	if audio != null:
		var _heard := audio.on_disguise(who.global_position, revealed)

	if session_id == _watch_id and hud != null:
		if who.is_disguised():
			hud.shout("You are a %s" % game.props_catalogue.title_of(who.disguise.prop_id).to_lower(), 1.4)
		elif revealed:
			hud.shout("Showing yourself — %s to hide again" % _key(PhBindings.REVEAL), 1.8)

		_place_camera()


func _on_taunt(session_id: int, taunt_id: StringName, forced: bool) -> void:
	var who := _player_of(session_id)

	if who == null or game.taunts == null:
		return

	var entry := game.taunts.entry(taunt_id)

	if audio != null and not entry.is_empty():
		var _voice := audio.taunt(who, str(entry["sound"]), game.config.taunt_range)

	if session_id == _watch_id and hud != null:
		hud.shout("%s%s" % ["You stood still: " if forced else "", str(entry.get("title", ""))], 1.5)


func _on_decoy(amount: float) -> void:
	if audio != null:
		var _heard := audio.on_decoy()

	if game.effects != null:
		var _flashed := game.effects.flash(&"hurt")

	if hud != null:
		hud.shout("That was furniture (-%d)" % int(ceilf(amount)), 1.0)


func _on_armed(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id:
		return

	_arm_locally(weapon_id)


## A gun left the watched player's hands (thrown, or left where they fell): the drawn rig lets go of it too.
func _on_weapon_lost(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id or weapons == null:
		return
	var def := weapons.arsenal.catalogue.get_def(weapon_id)
	if def != null:
		var empty: Array[int] = []
		var _gone := weapons.arsenal.drop_from_slot(def.slot, empty)


func _arm_locally(weapon_id: StringName = &"") -> void:
	if player == null:
		return

	if weapons != null:
		_give_locally(weapon_id)
		_select_locally(weapon_id)
		return

	if camera == null:
		_build_camera()

	if camera == null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "ViewModel"
	camera.add_child(view_model)

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = ZeeWeaponRig.Role.LOCAL
	weapons.authority = false
	weapons.catalogue = PhGame.weapon_catalogue()
	weapons.tick_rate = game.tick_rate
	# The held weapon lowers at every brush that stops the player, fences and clip included.
	weapons.wall_extra_mask = player.controller.tunables.collision_mask if player.controller != null else 0
	weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())
	weapons.player_ref = DotNodeRef.of_path(player.get_path())
	weapons.ads_rules = game.ads_rules
	player.add_child(weapons)

	var ready_now := weapons.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "the view model would not set up", {"why": ready_now.error.message})
		_disarm_locally()
		return

	# Only what the server armed, one weapon as each is armed (`player_armed`), never the whole pack.
	# `give_everything` put all twenty-seven in five slots so each held the last one given, none the gun the server fired.
	# headless_run's "the drawn gun is the armed one" holds it.
	_give_locally(weapon_id)

	weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if audio != null and camera != null:
			var _heard := audio.on_weapon(camera.global_position, ZeeWeaponNet.kind_number(outcome.kind)))

	_select_locally(weapon_id)


func _give_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return
	var given := weapons.give(weapon_id)
	if not given.ok:
		DotLog.warn(CHANNEL, "the drawn rig refused a weapon", {"weapon": String(weapon_id), "why": given.error.message})


func _select_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"" or _slot != 0:
		return

	var def := weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		_slot = def.slot


func _disarm_locally() -> void:
	_slot = 0

	if weapons != null:
		if is_instance_valid(player) and weapons.get_parent() == player:
			player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 90.0
	camera.current = true

	# Other players, handed over: hidden at the lens, faded in third person between the
	# camera and you. It rides the camera wherever the camera goes.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)
	_place_camera()


## Hangs the camera where the view wants it: at the eyes, or on an arm behind a prop as far
## back as the prop is big.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	var eye := player.eye_position() - player.controller.state.position

	if not third_person:
		player.add_child(camera)
		_rig_height = eye.y
		camera.position = Vector3(0.0, eye.y, 0.0)
		camera.rotation = Vector3.ZERO

		if view_model != null and is_instance_valid(view_model):
			view_model.visible = true

		if _fade != null:
			_fade.focus = null

		return

	# dot-core's boom (it was a spring arm, which cast a ray and snapped to its hit), swept
	# from the eye or the prop's middle, the height above it added in the world's up.
	var size := player.disguise.standing_size() if player.is_disguised() else Vector3(0.7, 1.8, 0.7)
	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK + maxf(size.x, size.z)
	# Against the building and the furniture, never the player's own prop.
	_arm.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1
	_arm.add_excluded_object(player.get_rid())
	_arm.margin = 0.15
	_rig_height = maxf(eye.y, size.y * 0.6)
	_arm.lift = CHASE_UP
	player.add_child(_arm)
	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO

	if _fade != null:
		_fade.focus = _arm

	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false


## Swaps the view, where the server's `mp_forceview` allows.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_view_chosen = true
	_place_camera()

	if audio != null:
		var _heard := audio.click()


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera()


## The phone's buttons, over the HUD. Not built elsewhere.
func _build_touch() -> void:
	if not PhTouch.wanted():
		return

	touch = PhTouch.new()
	touch.client = platform
	touch.owner_client = self
	touch.build(_sampler, game.mobile_rules)
	touch.pressed.connect(_on_touch_button.bind(true))
	touch.released.connect(_on_touch_button.bind(false))
	add_child(touch)
	_bind_touch_sampler(_sampler)


## The overlay drives this sampler (offline play keeps its own on the player).
func _bind_touch_sampler(sampler: DotFpsSampler) -> void:
	if touch != null and sampler is DotFpsTouchSampler:
		touch.bind_sampler(sampler)


## Whether a screen position is the Menu button, which the overlay leaves to the button.
func touch_ignores(at: Vector2) -> bool:
	var button: Control = settings.menu.menu_button if settings != null and settings.menu != null else null
	return button != null and button.is_visible_in_tree() and button.get_global_rect().has_point(at)


## Whether auto-fire and aim assist may act: a living hunter who is not watching somebody.
func touch_live() -> bool:
	return player != null and player.is_alive() and is_hunter() and not is_spectating() and not _covered()


## A button press does what its key does: the same asks, the same held states.
func _on_touch_button(id: StringName, down: bool) -> void:
	var sampler := player.sampler if _offline and player != null and player.sampler != null else _sampler

	match id:
		&"jump":
			pass  # held on the sampler by the overlay (the row's `hold`)
		&"fire":
			_firing = down and is_hunter() and not is_spectating()
		&"reload":
			_reloading = down and is_hunter()
		&"aim":
			_aiming = down and is_hunter()
		&"disguise":
			if down and _prop_acts():
				ask_disguise()
		&"lock":
			if down and _prop_acts():
				ask_turn(PhGame.Turn.LOCK)
		&"taunt":
			if down and _prop_acts():
				ask_taunt()
		&"loadout":
			if down and loadout_menu != null:
				loadout_menu.call(&"open")


func _prop_acts() -> bool:
	return player != null and player.is_alive() and not is_spectating() and not is_hunter()


func _build_hud() -> void:
	hud = PhHud.new()
	hud.name = "Hud"
	hud.key_fn = _key
	# The counter reads the gun the hunter sees (corrected from the server's by correct_drawn).
	hud.weapons_fn = func() -> ZeeWeaponRig: return weapons
	add_child(hud)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := PhBindings.make().row_for_action(action)
	return str(row.get("default", action))


var _loadout_restored := false


## Sends the choice this player saved last time, once per join: solo into the world's manager,
## connected to the server.
func _restore_loadout() -> void:
	if loadout_menu == null or _loadout_restored:
		return
	_loadout_restored = true
	var _sent: Variant = await loadout_menu.call(&"restore")


func _build_killcam() -> void:
	killcam = PhKillcam.new()
	killcam.name = "RoundKillcam"
	killcam.players_fn = func() -> Array: return game.players.values() if game != null else []
	killcam.player_for_fn = func(key: StringName) -> Variant: return game.players.get(key) if game != null else null
	killcam.feet_fn = func(p: PhPlayer) -> Vector3: return drawn_position(p, net != null and net.is_running() and p != player)
	killcam.colour_fn = func(p: PhPlayer) -> Color: return game.side_colour(game.team_of(p.player_id))
	killcam.seconds_fn = func() -> float: return _killcam_sec if _killcam_sec >= 0.0 else game.config.killcam_seconds
	killcam.camera_mode_fn = func() -> int: return _killcam_camera
	killcam.world_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") if game.physics != null else 1
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_round())
	add_child(killcam)
	var _mounted := KillPovView.mount(self, killcam)
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = PhKillcam.SKIP_ACTIONS
	winner_reveal.hold_seconds = 4.0
	winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)


## dot-game's chat box and microphone, with this game's channels and voice format.
func _build_chat() -> void:
	chat = DotGameChatClient.new()
	chat.name = "Chat"
	chat.channels = [
		{"id": PhServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": PhServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": PhServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	chat.max_length = PhServices.chat_rules().max_length
	chat.voice_config = PhServices.voice_format()
	add_child(chat)


func _build_audio() -> void:
	audio = PhAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote). The sets are the game's own; the rows are the server's, through the bridge's profile link.
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var _fl := game.flashlight_conf()
	if game.flashlight_binder != null:
		for set: DotProfileSet in game.flashlight_binder.profile_sets():
			wb.add_set(set, "Flashlight")
	add_child(wb)
	var started := wb.start(game.ensure_runtime())
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.add_workbench(wb)



func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)



func _build_break_fx() -> void:
	break_fx = PhBreakFx.new()
	add_child(break_fx)
	game.prop_broken.connect(_on_prop_broken_fx)


## Pieces where a broken prop stood; a prop told on joining (already broken) never reaches here.
func _on_prop_broken_fx(index: int, direction: Vector3) -> void:
	if game.map == null or index < 0 or index >= game.map.props.size():
		return
	var prop: Dictionary = game.map.props[index]
	var size: Vector3 = prop["size"]
	break_fx.shatter(prop["id"], (prop["transform"] as Transform3D) * Vector3(0.0, size.y * 0.5, 0.0), size, direction)


func _build_break_rules() -> void:
	if game.config.hunter_break == 0:
		return

	_break_rules = DotPlayerBreakRules.new()
	_break_rules.mode = DotPlayerBreakRules.Mode.EXPLODE if game.config.hunter_break == 2 \
		else DotPlayerBreakRules.Mode.LIMBS
	_break_rules.limbs = 3
	_break_rules.criticals_only = false
	_break_rules.force = 7.0
	_break_rules.lift = 4.0
	_break_rules.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func ask_disguise() -> void:
	if bridge != null:
		bridge.ask_disguise()
	elif player != null:
		game.queue_disguise(player.player_id)


## Throw the gun in hand (the hunters' Q).
func ask_drop_weapon() -> void:
	if bridge != null:
		bridge.ask_drop_weapon()
	elif player != null:
		var _id := game.weapon_layer.throw_for(player.player_id)


func ask_reveal() -> void:
	if bridge != null:
		bridge.ask_reveal()
	elif player != null:
		game.queue_reveal(player.player_id)


func ask_turn(how: int) -> void:
	if bridge != null:
		bridge.ask_turn(how)
	elif player != null:
		var _turned := game.turn(player.player_id, how)


func open_taunts() -> void:
	if settings == null or settings.menu == null or game.taunts == null:
		return

	var items: Array = []

	for id in game.taunt_ids():
		var entry := game.taunts.entry(id)
		items.append({"id": id, "name": str(entry.get("title", id)), "tags": ["%.1f s" % float(entry.get("seconds", 0.0))]})

	settings.menu.open_picker(items, "Taunt")


func _physics_process(delta: float) -> void:
	if _offline:
		_drive_offline()
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock still advances; only the sampling waits, so the mouse does not pile up a turn
	# behind the cover and the server sees an idle body until it lifts.
	var move := _sampler.sample(delta) if _sampler != null and not _covered() else DotFpsCommand.new()
	_stamp(move)

	# Snapshots read since the last frame are reconciled before the clock moves: the replay runs to the clock's
	# tick, and after `advance` that is a tick `predict_tick` has yet to simulate, so it was played twice.
	net.flush_reconcile()

	var ticks := net.clock.advance(delta)

	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move, _slot, _aim_sent())

	_drive_view_model(move)


func _drive_offline() -> void:
	if player == null or player.sampler == null:
		return

	var pending := player.controller.current_command

	if pending != null:
		_stamp(pending)
		player.wanted_slot = _slot
		player.aiming = _aim_sent()

	_drive_view_model(pending)


func _stamp(command: DotFpsCommand) -> void:
	if command == null:
		return

	# A thumb on FIRE sets `_firing`; auto-fire (the server's `sv_autofire`, off by default) is read here, the Fire key's own path.
	var auto := touch != null and touch.is_held(&"fire") and is_hunter() and not is_spectating()
	command.set_button(PhNetCommand.BUTTON_FIRE, _firing or auto)
	command.set_button(PhNetCommand.BUTTON_ALT, _alt)
	command.set_button(PhNetCommand.BUTTON_RELOAD, _reloading)


func _drive_view_model(command: DotFpsCommand) -> void:
	if weapons == null or player == null:
		return

	var weapon_command := DotWeaponCommand.new()
	weapon_command.set_button(DotWeaponCommand.BUTTON_AIM, _aim_sent())

	if command != null:
		weapon_command.set_button(DotWeaponCommand.BUTTON_ATTACK, command.is_pressed(PhNetCommand.BUTTON_FIRE))
		weapon_command.set_button(DotWeaponCommand.BUTTON_ALT, command.is_pressed(PhNetCommand.BUTTON_ALT))
		weapon_command.set_button(DotWeaponCommand.BUTTON_RELOAD, command.is_pressed(PhNetCommand.BUTTON_RELOAD))
		weapon_command.yaw = command.yaw
		weapon_command.pitch = command.pitch

	weapon_command.slot = _slot
	var _outcome := weapons.simulate_tick(weapon_command, game.round_number * 100000 + Engine.get_physics_frames())

	var busy := weapon_command.is_pressed(DotWeaponCommand.BUTTON_ATTACK) \
		or weapon_command.is_pressed(DotWeaponCommand.BUTTON_RELOAD) \
		or weapons.arsenal.is_reloading() or weapons.arsenal.is_switching()
	_drawn_quiet = 0.0 if busy else _drawn_quiet + 1.0 / float(maxi(game.tick_rate, 1))
	var _corrected := correct_drawn()


## Seconds the drawn gun must be quiet before the server's count may overwrite it: longer than a
## shot's trip to the server and its snapshot back, so no shot still in flight is undone.
## game-zombie-zone's `VIEW_RIG_SETTLE_SEC`.
const DRAWN_SETTLE_SEC := 0.6

## Simulated seconds the drawn gun has gone without a trigger, a reload or a switch.
var _drawn_quiet: float = 0.0


## Brings the drawn gun's magazine and reserve (what the HUD counts) to the server's once quiet for [constant DRAWN_SETTLE_SEC].
## The drawn gun predicts, so a shot the server refused or a fresh round's refill would leave the counter wrong with nothing to correct it.
## Returns true when it changed anything.
func correct_drawn() -> bool:
	if weapons == null or weapons.arsenal == null or _drawn_quiet < DRAWN_SETTLE_SEC:
		return false

	var source := _server_count()

	if source.is_empty() or bool(source.busy):
		return false

	var arsenal := weapons.arsenal
	var held := arsenal.current()

	if held == null or int(source.slot) != arsenal.current_slot() or arsenal.is_reloading() or arsenal.is_switching():
		return false

	var changed := false

	if held.def.uses_magazine() and held.magazine != int(source.magazine):
		held.magazine = clampi(int(source.magazine), 0, held.def.magazine)
		changed = true

	if held.def.ammo_type != &"" and not held.def.infinite_reserve \
			and arsenal.ammo().count(held.def.ammo_type) != int(source.reserve):
		arsenal.ammo().set_count(held.def.ammo_type, maxi(int(source.reserve), 0))
		changed = true

	return changed


## The server's count for this player's gun: `{magazine, reserve, slot, busy}`, or empty.
func _server_count() -> Dictionary:
	if _offline:
		var world: ZeeWeaponRig = player.weapons if player != null else null
		if world == null or world == weapons or world.arsenal == null or world.arsenal.current() == null:
			return {}
		var def := world.current_def()
		return {
			"magazine": world.arsenal.current().magazine,
			"reserve": world.arsenal.ammo().count(def.ammo_type) if def.ammo_type != &"" else 0,
			"slot": world.arsenal.current_slot(),
			"busy": world.arsenal.is_reloading() or world.arsenal.is_switching(),
		}

	var mine: Variant = bridge._behaviours.get(_watch_id) if bridge != null else null
	if not (mine is PhPlayerNet):
		return {}
	var behaviour := mine as PhPlayerNet
	return {
		"magazine": behaviour.net_magazine, "reserve": behaviour.net_reserve, "slot": behaviour.net_slot,
		"busy": behaviour.net_reloading or behaviour.net_switching,
	}


## A hit the server confirmed for this player's shot: the marker, and zee's red burst on the body
## at the server's point (`ZeeShotFx.play_body_hit`, by `has_method` for an older shell's zee;
## it skips a burst its own presentation ray already drew).
func _on_hit(point: Vector3, killed: bool, headshot: bool) -> void:
	if hud != null:
		hud.confirm_hit(killed, headshot)
	if weapons == null or not is_instance_valid(weapons) or not weapons.has_method(&"shot_fx"):
		return
	var fx: Object = weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = camera.global_position if camera != null else point + Vector3.UP
	fx.call(&"play_body_hit", point, point - from)


func _process(delta: float) -> void:
	if touch != null:
		touch.show_for(is_hunter())
		touch.sync(_covered() or (platform != null and platform.is_input_blocked()))

	var _shown := present_frame(net, game, player, not third_person, delta, -1.0, _watched_through_eyes())
	_present_hide()
	_killcam_frame()
	if audio != null and audio.ambient != null and camera != null and camera.is_inside_tree() and game.physics != null:
		audio.ambient.follow_roof(delta, camera.global_position, camera.get_world_3d().direct_space_state, game.physics.mask_of([&"world"]))

	if camera == null or player == null:
		return

	_present_aim()

	if _drive_spectator_camera():
		_present_effects(delta)
		return

	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)
	var rig: Node3D = _arm if _arm != null and is_instance_valid(_arm) else camera

	if weapons != null:
		var punch := weapons.view_punch()
		pitch += deg_to_rad(punch.x)
		yaw += deg_to_rad(punch.y)

	rig.rotation = Vector3(pitch, yaw, 0.0)

	var drawn := player.controller.render_state()
	rig.global_position = drawn.position + Vector3(0.0, _rig_height, 0.0)

	if weapons != null:
		var speed := Vector2(state.velocity.x, state.velocity.z).length()
		weapons.drive_view(Vector2(state.yaw, state.pitch), speed, state.mode != DotFpsState.Mode.AIR, state.crouch_fraction > 0.5)

	_present_effects(delta)


## Down the sights: a hunter's hands come up while Aim is held, the lens zooms by the weapon's `aim_fov_scale` (from [member base_fov], so nothing compounds),
## and the HUD fades its dot and shows a scope. Nobody aims as a prop, dead, blindfolded, watching, in third person or with the pointer free.
func _present_aim() -> void:
	var hands := view_model if view_model != null and is_instance_valid(view_model) else null
	if hands != null:
		hands.aim_input(_aiming and _aim_allowed())
	camera.fov = base_fov * (hands.aim_fov_scale() if hands != null and not is_spectating() else 1.0)
	if hud != null:
		hud.follow_hands(hands)


## Whether the sights may come up: not as a prop, dead, blindfolded, watching, in third person or with the pointer free.
func _aim_allowed() -> bool:
	var blind := hud != null and hud.is_blindfolded()
	return _pointer_ours() and is_hunter() and not third_person and not is_spectating() and player != null and player.is_alive() and not blind


## What the command says about the sights: the view model's own state (a toggle in the rules reaches the server's spread and pace as it does the
## picture), and nothing when the sights may not come up.
func _aim_sent() -> bool:
	var hands := view_model if view_model != null and is_instance_valid(view_model) else null
	return _aim_allowed() and (hands.is_aim_held() if hands != null else _aiming)


## The last seconds of the hide, beeped.
func _present_hide() -> void:
	if game == null or game.phase != PhGame.Phase.HIDE:
		_beeped = -1
		return

	var second := int(ceilf(game.seconds_left()))

	if second != _beeped and second <= 5 and second > 0:
		_beeped = second

		if audio != null:
			var _heard := audio.on_countdown()


func _present_effects(delta: float) -> void:
	_present_flashlights(delta)
	if audio != null:
		audio.listen_from(camera.global_position)
		audio.keep_walkers(game.players.values())

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


## The pose the free camera holds between frames, seeded from the camera as it was the frame
## the roam began, so the spectator starts where they were looking.
var _free_cam: DotSpectatorFreeCam = null
var _roam_seeded := false
var _roam_look := Vector2.ZERO


func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


func _watched_through_eyes() -> PhPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false

	if game.spectate.is_roaming(player.player_id):
		_drive_free_camera()

		if hud != null:
			hud.set_watching(_watching_line())

		return true

	_roam_seeded = false

	# Chase and death cameras pulled out of the house by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	var where := game.spectate.camera_for(player.player_id)

	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		hud.set_watching(_watching_line())

	return true


## The HUD line, with the free-camera key named only while the server offers one.
func _watching_line() -> String:
	game.spectate.roam_key = _key(PhBindings.ROAM)
	return game.spectate.line_for(player.player_id)


func _refresh_watching_line() -> void:
	if hud != null and player != null and game != null and game.spectate != null:
		hud.set_watching(_watching_line() if is_spectating() else "")


## The free camera, once a frame: WASD along the view, Space and Ctrl up and down, Shift fast, Alt slow, mouse to look; the body stays where it fell.
## The speed is the server's (`mp_freeroam_speed`), so a client cannot fly faster than it was told; the server holds only the mode.
func _drive_free_camera() -> void:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()

	_free_cam.rules = game.spectate.manager.rules

	if not _roam_seeded:
		# The camera still holds last frame's pose: where this spectator was looking.
		_free_cam.seed_from(camera.global_transform)
		_roam_seeded = true
		_roam_look = Vector2.ZERO

	_free_cam.look(_roam_look)
	_roam_look = Vector2.ZERO

	var move := Vector3.ZERO

	if not _covered() and not (platform != null and platform.is_input_blocked()):
		move = Vector3(
			Input.get_axis(&"dot_fps_left", &"dot_fps_right"),
			Input.get_axis(&"dot_fps_crouch", &"dot_fps_jump"),
			Input.get_axis(&"dot_fps_back", &"dot_fps_forward"))

	var shift := Input.is_physical_key_pressed(KEY_SHIFT)
	var alt := Input.is_physical_key_pressed(KEY_ALT)
	camera.global_transform = _free_cam.step(
		move, shift, alt and not shift, get_process_delta_time())


## Mouse motion while roaming, as radians for [method DotSpectatorFreeCam.look]: positive x
## turns left (mouse right is negative), positive y looks up (mouse down is negative).
func _roam_mouse(motion: InputEventMouseMotion) -> void:
	var sampler := _sampler if _sampler != null else player.sampler
	var degrees := 0.12
	var invert := 1.0

	if sampler != null and sampler.tunables != null:
		degrees = sampler.tunables.mouse_sensitivity
		invert = -1.0 if sampler.tunables.invert_look_y else 1.0

	_roam_look += Vector2(-motion.relative.x, -motion.relative.y * invert) * deg_to_rad(degrees)


func is_roaming() -> bool:
	return is_spectating() and game.spectate.is_roaming(player.player_id)


## The free-camera key: into a free camera from watching, back onto a player from one. Only
## for somebody already out; a stray press must not turn a player into a spectator.
func toggle_roam() -> void:
	if not is_spectating():
		return

	if not is_roaming() and not game.spectate.can_roam(player.player_id):
		if chat != null:
			chat.notice("Free camera is off on this server.")
		return

	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate_roam()
		return

	var res := game.spectate.toggle_roam(player.player_id)

	if not res.ok and chat != null:
		chat.notice(res.error.message)


func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)


## Everything a frame draws that a tick does not, in order: the netcode's interpolation, every player (or the prop they are), every beacon.
## Returns how many are shown. Static so the net suite drives exactly this and not a copy.
## [param first_person] hides [param own]'s body; a prop is always drawn to its own player in third person.
static func present_frame(
	p_net: DotNetManager,
	p_game: PhGame,
	own: PhPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: PhPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the clock stretches its ticks while settling on the server,
	# and at the engine's fraction the eye stood still one frame and moved double the next. Read from `render_clock` by name both ways,
	# so an older shell draws as before. Null offline, where every physics frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0
	var period := p_game.config.beacon_period if p_game.config != null else 2.0

	for key: StringName in p_game.players:
		var body: PhPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.side_colour(p_game.team_of(key))
		var hidden := (mine and first_person) or body == watched

		if body.present_body(hidden, at, colour):
			shown += 1

		var _pinged := body.present_beacon(delta, at, mine and first_person, period)

	return shown


static func drawn_position(body: PhPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		# The button's release goes to the menu, so the aim is let go here or it sticks up.
		_aiming = false
		if settings != null:
			settings.open()
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not event.is_echo():
		if _key_pressed(event):
			get_viewport().set_input_as_handled()
			return

	if event.is_action_released(PhBindings.RELOAD):
		_reloading = false
	if event.is_action_released(PhBindings.AIM):
		_aiming = false
	if event.is_action_released(PhBindings.BASH):
		_alt = false

	if _wheel_pressed(event):
		get_viewport().set_input_as_handled()
		return

	# A free camera turns on the mouse, and the sampler must not turn the body with it.
	if event is InputEventMouseMotion and is_roaming():
		if _pointer_ours():
			_roam_mouse(event as InputEventMouseMotion)
		return

	# dot-mobile's overlay forwards every touch to the sampler itself, and Godot's mouse from a touch would turn the view
	# and fire a second time.
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		return
	if touch != null and touch.takes(event):
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if is_spectating():
			_firing = false
			_alt = false

			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

		if button.button_index == MOUSE_BUTTON_LEFT:
			_firing = button.pressed and is_hunter()
		elif button.is_action(PhBindings.AIM):
			_aiming = button.pressed and is_hunter()
		elif button.is_action(PhBindings.BASH):
			_alt = button.pressed and is_hunter()

	if player == null:
		return

	# Every event, not only motion: the sampler latches a press that a wheel tick sends with its
	# release in the same frame, and reads its own actions off the events it is shown.
	if _pointer_ours():
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The wheel (or whatever the Controls page moved it to) walks a hunter's carried slots. Props
## carry nothing and have no item switching, so for them it does nothing.
func _wheel_pressed(event: InputEvent) -> bool:
	if _wheel == null:
		_wheel = DotWeaponWheel.new()
		_wheel.ring_provider = func() -> Array:
			return weapons.arsenal.slots() if weapons != null and weapons.arsenal != null else []
		_wheel.current_provider = func() -> Variant:
			return _slot if _slot != 0 else weapons.arsenal.current_slot()
		_wheel.blocked = func() -> bool:
			return not _pointer_ours() or player == null or not player.is_alive() or is_spectating() or not is_hunter()
		_wheel.chosen.connect(func(slot: Variant) -> void: _slot = int(slot))
	return _wheel.handle_event(event)


## The game's own keys, from the bindings. True when one was used.
func _key_pressed(event: InputEvent) -> bool:
	if event.is_action_pressed(PhBindings.ROAM):
		toggle_roam()
		return true

	if event.is_action_pressed(PhBindings.VIEW):
		if is_spectating():
			spectate_step(0)
		else:
			toggle_view()
		return true

	if player == null or not player.is_alive() or is_spectating():
		return false

	if event.is_action_pressed(PhBindings.FLASHLIGHT):
		if flash != null:
			var _asked := flash.toggle()
		return true

	if is_hunter():
		if event.is_action_pressed(PhBindings.DROP_WEAPON):
			ask_drop_weapon()
			return true

		if event.is_action_pressed(PhBindings.RELOAD):
			_reloading = true
			return true

		if event.is_action_pressed(PhBindings.AIM):
			_aiming = true
			return true

		if event.is_action_pressed(PhBindings.BASH):
			_alt = true
			return true

		for i in range(PhBindings.SLOTS.size()):
			if event.is_action_pressed(PhBindings.SLOTS[i]):
				_slot = i + 1
				return true

		return false

	if event.is_action_pressed(PhBindings.DISGUISE):
		ask_disguise()
	elif event.is_action_pressed(PhBindings.REVEAL):
		ask_reveal()
	elif event.is_action_pressed(PhBindings.LOCK):
		ask_turn(PhGame.Turn.LOCK)
	elif event.is_action_pressed(PhBindings.TAUNT):
		ask_taunt()
	elif event.is_action_pressed(PhBindings.TAUNT_MENU):
		open_taunts()
	elif event.is_action_pressed(PhBindings.TILT_FORWARD):
		ask_turn(PhGame.Turn.TILT_FORWARD)
	elif event.is_action_pressed(PhBindings.TILT_BACK):
		ask_turn(PhGame.Turn.TILT_BACK)
	elif event.is_action_pressed(PhBindings.TILT_LEFT):
		ask_turn(PhGame.Turn.TILT_LEFT)
	elif event.is_action_pressed(PhBindings.TILT_RIGHT):
		ask_turn(PhGame.Turn.TILT_RIGHT)
	elif event.is_action_pressed(PhBindings.STRAIGHTEN):
		ask_turn(PhGame.Turn.STRAIGHTEN)
	else:
		return false

	return true


## The sound manager the flashlight clicks play through, or null before audio is up.
func _flash_audio_ref() -> DotNodeRef:
	if audio == null or audio.manager == null or not audio.manager.is_inside_tree():
		return null
	return DotNodeRef.of_path(audio.manager.get_path())


## The light on the eye follows the server's state (but not for 0.4 s after our own switch); everybody else's beam, and ours when the camera is not our eye, comes from the crowd.
func _present_flashlights(delta: float) -> void:
	var cfg := game.flashlight_conf()
	var map_id := game.map_id_str()

	if flash == null or not is_instance_valid(flash):
		_make_flash(cfg)

	flash.allowed = DotFlashlightRules.allowed_on(cfg, map_id)

	if flash_crowd == null:
		flash_crowd = DotFlashlightCrowd.new()
		flash_crowd.name = "Flashlights"
		flash_crowd.config = cfg
		flash_crowd.audio = _flash_audio_ref()
		add_child(flash_crowd)

	var own_eye := not third_person and not is_spectating()
	var lit := player.flashlight and player.is_alive() and not player.watching

	if own_eye and Time.get_ticks_msec() - _flash_msec > 400:
		flash.apply_state({"on": lit})
	elif not own_eye:
		flash.apply_state({"on": false})

	flash_crowd.set_viewer(camera.global_position)

	for key: Variant in game.players:
		var other: PhPlayer = game.players[key]
		var shown := other.flashlight and other.is_alive() and not other.watching and (other != player or not own_eye)
		flash_crowd.set_lit(key, shown)
		if shown:
			flash_crowd.place(key, other.eye_position(), other.aim_direction())

	_flash_retain -= delta
	if _flash_retain <= 0.0:
		_flash_retain = 2.0
		flash_crowd.retain(game.players.keys())


func _make_flash(cfg: DotFlashlightConfig) -> void:
	flash = DotFlashlight.new()
	flash.name = "Flashlight"
	flash.config = cfg
	flash.handle_input = false
	flash.authoritative = false
	flash.audio = _flash_audio_ref()
	if not flash.switch_requested.is_connected(_on_flash_switch):
		flash.switch_requested.connect(_on_flash_switch)
	camera.add_child(flash)


## Our own switch: shown at once, asked of the server (or done here, offline).
func _on_flash_switch(_want: bool) -> void:
	_flash_msec = Time.get_ticks_msec()
	if bridge != null:
		bridge.ask_flashlight()
	elif game != null and player != null:
		var _switched := game.toggle_flashlight(player.player_id)


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
		"armed": weapons != null,
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


