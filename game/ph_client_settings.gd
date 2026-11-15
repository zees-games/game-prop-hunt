extends "ph_client_round.gd"

## The settings half of [code]ph_client.gd[/code]: the settings menu and its loadout, taunt and touch hooks, and how a death is drawn (the fall, the prop that bursts).

## The Aim key held (`PhBindings.AIM`, right mouse): a hunter's view model comes up and the
## lens zooms. Presentation only.
var _aiming: bool = false
var audio: PhAudio = null
## Splinters and shards where furniture breaks.
var break_fx: Node = null
## The rules a hunter's body comes apart by when the furniture finishes them.
var _break_rules: DotPlayerBreakRules = null
var bridge: PhNetBridge = null
## The player's console (the platform's).
var console: DotConsoleController = null
var link: Node = null
## dot-menu's loadout menu, or null on a host whose dot-menu predates it (API 6).
var loadout_menu: Object = null
var _offline: bool = true
const PhAudio := preload("ph_audio.gd")
const PhBindings := preload("ph_bindings.gd")
const PhDebris := preload("ph_debris.gd")
const PhTouch := preload("ph_touch.gd")
const PhWeaponIcons := preload("ph_weapon_icons.gd")
## How long a found prop's own pieces take to shrink away as it pops.
const PROP_POP_SECONDS := 0.35
## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null
var _sampler: DotFpsSampler = null
## The phone's buttons; null on a device without touch.
var touch: PhTouch = null
var _watch_id: int = -1
var _weapon_cards: Script = null
const WEAPON_CARDS_SCRIPT := "res://addons/zee_weapons/content/zee_weapon_cards.gd"
var _weapon_defs: Dictionary = {}
const WEAPON_ICON_DIR := "res://assets/weapon_icons"
## A hunter's own gun, drawn. Never decides anything: every shot is the server's.
var weapons: ZeeWeaponRig = null
## The tuning panel's host: F9 solo or hosting, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null
## Whether B's choice is remembered on this device and sent again on the next join. A suite or a
## render turns it off: neither may write, or read back, a player's real choice.
@export var remember_loadout: bool = true


## The figure an avatar action plays on: that peer's player, or the local one offline. A disguised player has
## no figure drawn (they are a prop), so nothing plays on them.
func _avatar_figure(peer_id: int) -> Object:
	var who: PhPlayer = null
	if bridge != null and peer_id != 0:
		who = game.players.get(PhNetBridge.player_key(bridge.player_for_peer(peer_id)), null)
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	if who == null or who.figure == null or who.is_disguised():
		return null
	return who.figure.person


## Solo, `bot_difficulty` and every `bot_*` setting at the console, the names a server has.
## Connected, the server's console holds them and a local copy would shadow it.
func _bind_bot_console() -> void:
	if console != null:
		var local: Array = console.sources()
		if not local.is_empty() and local[0] is DotConsoleLocal:
			var _icons := PhWeaponIcons.shared.bind_console(local[0])
	if not _offline or console == null or game == null:
		return
	var sources: Array = console.sources()
	if sources.is_empty() or not (sources[0] is DotConsoleLocal):
		return
	var _bound := DotBotSettings.of(game).bind_console(sources[0])
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", DotBotSettings.of(game).set_difficulty(args[index + 1]))


func _player_of(session_id: int) -> PhPlayer:
	if session_id == _watch_id and player != null:
		return player
	return game.players.get(PhNetBridge.player_key(session_id))


func _on_death(session_id: int, by: int, why: StringName, weapon_id: StringName = &"") -> void:
	var who := _player_of(session_id)
	var mine := session_id == _watch_id
	var was_hunter := who != null and game.team_of(who.player_id) == PhGame.HUNTERS

	_note_death(who, _player_of(by) if by != 0 else null, weapon_id)

	if audio != null and who != null:
		var _heard := audio.on_death(who.global_position, mine, was_hunter)

	# The furniture finished a hunter: they come apart, the way the brief asked. Anybody else
	# falls (a person) or bursts (a prop): see _fall.
	if why == PhGame.DIED_DECOY and who != null and _break_rules != null:
		var _broke := who.break_body(_break_rules, Vector3.UP, session_id * 7919 + game.round_number)
	else:
		_fall(who)

	if chat == null:
		return

	var name_of := who.display_name if who != null else "somebody"
	var hunter := _player_of(by)
	var line := "%s is out" % name_of

	match why:
		PhGame.DIED_SHOT:
			line = "%s was found by %s" % [name_of, hunter.display_name] if hunter != null else "%s was found" % name_of
		PhGame.DIED_DECOY:
			line = "%s was beaten by the furniture" % name_of
		PhGame.DIED_FELL:
			line = "%s fell" % name_of

	chat.say_locally(line, Color(0.80, 0.82, 0.86))


## B: a hunter's primary and secondary, as cards. Solo the world's loadouts answer; connected the server does (dot-loadout's `/loadout`).
## A prop may choose too, kept for the round they hunt. Guarded on the host's dot-menu and dot-loadout levels, so an older shell runs without it.
func _use_loadout_menu() -> void:
	if DotAddonApi.build_level("dot_menu") < 6 or DotAddonApi.build_level("dot_loadout") < 2:
		return
	if settings == null or not settings.has_method(&"use_loadout"):
		return
	loadout_menu = settings.call(&"use_loadout", loadout_offer, choose_loadout, decorate_loadout_choice)
	if loadout_menu != null:
		if touch != null:
			touch.offer_loadout(true)
		loadout_menu.set(&"title", "Hunter's loadout")
		loadout_menu.call(&"remember_as", "prophunt" if remember_loadout else "", "local")
		if hud != null:
			hud.loadout_offered = true


## Solo: what this player may pick, from the world's own manager.
func loadout_offer() -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the round first.")
	return await game.loadout_command.call(&"offer", PhGame.storage_key(player.player_id))


## Solo: saves [param picks], and hands them over now while the hunters are blindfolded.
func choose_loadout(picks: Dictionary) -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the round first.")
	return await game.loadout_command.call(&"choose", null, PhGame.storage_key(player.player_id), picks)


## A card's picture (the copied weapon silhouettes) and numbers (zee's `ZeeWeaponCards`, zee API 3).
func decorate_loadout_choice(_slot_id: String, choice: Dictionary) -> Dictionary:
	var id := StringName(str(choice.get("id", "")))
	if _weapon_cards == null and DotAddonApi.build_level("zee_weapons") >= 3 and ResourceLoader.exists(WEAPON_CARDS_SCRIPT):
		_weapon_cards = load(WEAPON_CARDS_SCRIPT) as Script
	if _weapon_defs.is_empty():
		for def in ZeeWeaponPack.weapons():
			_weapon_defs[def.id] = def
	var out: Dictionary = {}
	# The weapon's silhouette: game-fatal-contact's `tools/build_weapon_icons.sh` renders, copied for the
	# guns a hunter is offered. A gun an owner adds without one is drawn as its letters.
	var icon_path := "%s/%s.png" % [WEAPON_ICON_DIR, String(id)]
	var sprite := PhWeaponIcons.shared.menu_texture(id)
	if sprite != null:
		out["icon"] = sprite
	elif ResourceLoader.exists(icon_path):
		out["icon"] = load(icon_path)
	if _weapon_cards != null and _weapon_defs.has(id):
		var card: Variant = _weapon_cards.call(&"card", _weapon_defs[id])
		if card is Dictionary:
			out.merge(card as Dictionary)
	return out


## dot-team's block rules followed from the server, or, solo, the F9 tuning panel over this process's own config.
func _add_noblock_and_workbench() -> void:
	if link != null and not _offline:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "team_of_side")))
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	workbench = wb
	wb.config = {"enabled": false}
	for set: DotProfileSet in game.config_binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var _fl := game.flashlight_conf()
	if game.flashlight_binder != null:
		for set: DotProfileSet in game.flashlight_binder.profile_sets():
			wb.add_set(set, "Flashlight")
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok and wb.api != null:
		game.config_binder.attach(wb.api.runtime as DotProfileRuntime)
		if game.flashlight_binder != null:
			game.flashlight_binder.attach(wb.api.runtime as DotProfileRuntime)
	platform.add_workbench(wb)


func _build_settings() -> void:
	settings = PhSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: PhHud is a CanvasLayer and the platform's hud is a Control, so it follows
	# the menu's theme itself, below.
	platform.chat = chat
	platform.look_position_fn = _look_position
	platform.board_snapshot_fn = board_snapshot
	# M: the map list. Solo a choice changes the map at once; connected the server decides by `sv_map_menu_flag`, and anybody without it gets a vote
	# (dot-vote's map menu, wired in [PhModule]). Its choice goes to the map menu, never to the taunt list's `picked` handler.
	platform.maps_rows_fn = func() -> Array: return game.map_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_map_now(id)
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	# Disguised, the keys do nothing and send nothing: there is no figure to play on, and the others would draw none.
	if platform.avatar_actions != null:
		var menus_block := platform.avatar_actions.blocked_fn
		platform.avatar_actions.blocked_fn = func() -> bool:
			return (menus_block.is_valid() and bool(menus_block.call())) or (player != null and player.is_disguised())
	_add_noblock_and_workbench()
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler polls
	# the keyboard.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as PhSettings
	console = platform.console as DotConsoleController
	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if break_fx != null:
		break_fx.follow(settings.settings)

	if audio != null:
		settings.bind_audio(audio.manager)
		if audio.ambient != null:
			audio.ambient.follow_settings(settings.settings, game.ambient_rules)

	if settings.menu != null:
		settings.menu.picker_action = PhBindings.TAUNT_MENU
		settings.menu.picked.connect(_on_taunt_picked)
		# The HUD in the menu's theme and at the player's HUD size, live.
		if hud != null:
			hud.follow_menu(settings.menu)
		_bind_bot_console()
		board = platform.board as DotMenuScoreboard
		_dress_board()
		_use_loadout_menu()


## [param who]'s body goes down the way the server picked ([member PhPlayer.death]), from what this client draws of them.
## A person is copied into a ragdoll; a disguised prop does what `PhConfig.prop_death` says (burst, topple, or vanish).
## Nothing drawn here (your own first-person body), nothing. Called from [method _on_death] before the next frame hides it.
func _fall(who: PhPlayer) -> void:
	if who == null or ragdolls == null:
		return
	var death: DotPlayerDeath = who.death if who.death != null else DotPlayerDeath.new()
	if game.physics != null:
		# The building and the furniture: a body lands on them and on nothing else.
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	if who.prop_model != null and who.prop_model.visible and who.prop_model.is_inside_tree():
		match game.config.prop_death:
			0:
				_burst_prop(who, death)
			1:
				var _toppled := ragdolls.spawn(who.prop_model, death)
			_:
				who.prop_model.visible = false
		return

	if who.figure == null or not who.figure.visible or not who.figure.is_inside_tree():
		return
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, death, velocity)


## A found prop pops: its own meshes thrown the way the shot went and shrinking to nothing in
## [constant PROP_POP_SECONDS], in a spray of chips of its colour (`ph_debris.gd`, the debris a
## shot-up piece of furniture throws, which keeps its pieces whole).
func _burst_prop(who: PhPlayer, death: DotPlayerDeath) -> PhDebris:
	var parts: Array = []
	var bounds := AABB()
	var seeded := false
	for node: Node in who.prop_model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null or not mesh.is_visible_in_tree():
			continue
		parts.append([mesh.mesh, mesh.global_transform])
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if not seeded else bounds.merge(box)
		seeded = true
	who.prop_model.visible = false
	if not seeded:
		return null
	var debris := PhDebris.new()
	debris.name = "PropDebris_%s" % String(who.player_id)
	debris.pop_seconds = PROP_POP_SECONDS
	debris.chips = PhDebris.CHIPS * 3
	game.add_child(debris)
	var direction := death.direction if death.direction.length_squared() > 0.0001 else Vector3.UP
	debris.burst(parts, bounds.get_center(), bounds.size, direction,
		game.physics.layer_mask(&"world") if game.physics != null else 1, death.roll_seed)
	return debris


func _suspend_input(suspended: bool) -> void:
	if suspended:
		# The button's release goes to the menu, so the aim is let go here or it sticks up.
		_aiming = false

	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


func ask_taunt(taunt_id: StringName = &"") -> void:
	if bridge != null:
		bridge.ask_taunt(taunt_id)
	elif player != null:
		var _said := game.taunt(player.player_id, taunt_id)


func _on_taunt_picked(id: StringName) -> void:
	if game.taunts != null and game.taunts.has(id):
		ask_taunt(id)


## Where a roster row's player stands, for dot-game's look-to-gag key (G, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: PhPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null
