extends "ph_module_commands.gd"

const PhAmbience := preload("ph_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"
const PhPlayer := preload("ph_player.gd")
const PhAvatars := preload("ph_avatars.gd")
const PhVote := preload("ph_vote.gd")

## This game as a module a dedicated server loads; [DotGameModule] holds the netcode, bridge, roster and tick.
## No `class_name`: [method DotModuleHost.load_module] takes a path, and a pack's globals are not registered in the host.

# No `const CHANNEL`: [DotGameModule] declares one and a subclass cannot redeclare it, and a second
# channel would split one module's records across two places an operator must turn up separately.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments; empty is [DotGameServices]'s default, the real store.
## Static because dot-server constructs the module from a path, so no instance exists to set a field on;
## `examples/dedicated.tscn` points it elsewhere so a run does not append to the real store.
static var punishments_file: String = ""

## The `ph_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The players' vote for the next map; null when it could not be built.
var vote: PhVote = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const MAP_BALLOT_TOPIC := &"map_ballot"


func _module_name() -> String:
	return "prophunt"


## The cvars a map's per-map file may set (dot-game's DotGameMapConfig); the file is cfg/game/mg-prop-hunt/dot_map/map/<map>.yml.
func _map_config_keys() -> Dictionary:
	return {
		"ph_hide_seconds": {"type": "float", "min": 0.0, "max": 600.0},
		"ph_round_seconds": {"type": "float", "min": 10.0, "max": 3600.0},
		"ph_timeout_winner": {"type": "int", "min": 0, "max": 2},
		"ph_players_per_hunter": {"type": "float", "min": 1.0, "max": 64.0},
		"ph_min_hunters": {"type": "int", "min": 1, "max": 16},
		"ph_max_hunters": {"type": "int", "min": 1, "max": 16},
		"ph_auto_taunt_seconds": {"type": "float", "min": 0.0, "max": 600.0},
		"ph_beacon_props_left": {"type": "int", "min": 0, "max": 64},
		"mp_killcam_time": {"type": "float", "min": 0.0, "max": 30.0},
		"ph_decoy_penalty": {"type": "float", "min": 0.0, "max": 5.0},
		"ph_reveal_cooldown": {"type": "float", "min": 0.0, "max": 600.0},
		"ph_beacon_seconds_left": {"type": "float", "min": 0.0, "max": 600.0},
		"ph_taunt_cooldown": {"type": "float", "min": 0.0, "max": 60.0},
	}


func _map_config_game() -> String:
	return "mg-prop-hunt"


func _game_service() -> StringName:
	return PhGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an PhGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(PhGame.SERVICE)
	)


## The netcode's numbers. Tick rate comes from the world so `sv_tickrate` reaches it; a number written
## here would run the netcode at a rate the operator did not choose.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as PhGame).tick_rate
	config.snapshot_rate = PhGame.NET_SNAPSHOT_RATE
	config.world_extent = PhGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# On, and the bridge wires the two callables that make it real ([method PhNetBridge._wire_lag_compensation]);
	# a flag reported enabled with nothing behind it misleads the first reader who trusts it.
	# A hunter shooting a prop running across a room is the ordinary reason to want it.
	config.enable_lag_compensation = true
	# Everybody playing, and nothing else: the furniture is the map document, not entities, so
	# a snapshot is a full server's players and room to spare.
	config.max_entities_per_snapshot = 64
	return config


func _make_bridge() -> Node:
	return PhNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
## The bridge is the link (`send_chat`, `send_voice`); [DotGameModule] assigns `voice_relay_fn`, checks
## `check_admission` and has the roster follow this layer so a leaver is forgotten everywhere.
func _make_services() -> Node:
	var services := PhServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: [DotPlatformIdentity] over this game's one-slot schema.
## Authentication is the host's `dot_auth_server`, not this layer's; with it off everybody is a guest
## with a profile of their own, which is what a LAN server is.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = PhAvatars.schema()
	identity_layer.stock_avatar_fn = PhAvatars.stock_avatar
	identity_layer.avatar_translate_fn = PhAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as PhGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an PhGame.")

	add_command("ph_status", _cmd_status, "Show the round, the map and who is hiding as what")
	add_command("ph_net", _cmd_net, "Show what the netcode is doing")
	# maps.yml, before the commands: its `commands: names:` block renames ph_maps / ph_map (roles
	# of those names) as it does dot-vote's, and the ballot reads the marks it sets.
	var _rotation := world.load_rotation()
	add_command(world.command_name("ph_maps", "ph_maps"), _cmd_maps, "List the maps, and any refused file")
	add_command("ph_reload", _cmd_reload, "Read the map directory again (from the next map)")
	add_command("ph_taunts", _cmd_taunts, "List the taunts")
	add_command(world.command_name("ph_map", "ph_map"), _cmd_map, "Play a map next: ph_map <id> (at the end of this round)", "")
	# A player's wish for the next draw, from chat as !hunter / !prop / !any.
	add_command("hunter", _cmd_wish.bind(PhGame.HUNTERS), "Ask to hunt in the next draw", "")
	add_command("prop", _cmd_wish.bind(PhGame.PROPS), "Ask to hide in the next draw", "")
	add_command("any", _cmd_wish.bind(0), "Either side in the next draw", "")
	add_command("ph_say", _cmd_say, "Say something to everybody, as the server")

	# dot-game's "still loading": the server refuses to hurt or eliminate a seat whose client is
	# behind its cover (see PhGame.harm_gate). Asked by peer, resolved through the bridge.
	world.harm_gate = func(player_id: StringName) -> bool:
		if bridge == null:
			return true
		var peer := int((bridge as PhNetBridge).peer_for_player(PhNetBridge.session_of(player_id)))
		return peer <= 0 or can_peer_be_harmed(peer)

	_wire_chat()
	_wire_identity()
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)

	# Whether shots pass through team-mates: `mp_teammate_passthrough` 0 never, 1 a muzzle-holder (default),
	# 2 every team-mate in the line; dot-combat's cvar. NOTIFY so players know; REPLICATED because every
	# client's manager predicts its tracers under it (the client follows it through its link).
	if world.combat != null:
		var _passthrough := world.combat.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)

	_build_vote(world)

	# B, a hunter's loadout: `/loadout` and its notice, and the owner's mp_loadout_menu,
	# mp_loadout_allow and mp_loadout_fixed (dot-loadout's DotLoadoutCommand). Absent on a host
	# whose dot-loadout predates it, and then B says the server did not answer.
	if world.loadout_command != null:
		world.loadout_command.call(&"bind", self)

	_bind_rule_cvars(world)
	_bind_config(world)

	# REPLICATED: the clients play the killcam, the server only lengthens the intermission for it.
	var killcam := add_cvar("mp_killcam_time", _number(world.config.killcam_seconds),
		"Seconds the killcam of a round's last moment plays, added to the intermission (0 for none)",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED)
	_killcam_cvar = killcam
	if killcam != null:
		killcam.changed.connect(func(_old: String, new_value: String) -> void:
			world.config.killcam_seconds = clampf(new_value.to_float(), 0.0, 30.0)
			world.apply_intermission())

	_bots = add_cvar(
		"ph_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# `bot_quota` and `bot_quota_mode` are dot-server's [DotBotQuota], so they mean the same on every server.
	# The default is this game's `minimum_players` in fill mode: stand-ins top the round up, a person who
	# joins takes a stand-in's place. `ph_bots` stays the switch it always was.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# Started here, not in the world's `_ready`: `start()` builds the map, and doing that before the bridge
	# exists leaves nothing listening to `world_rebuilt`, so players stand on floors no client was told about.
	var _delivered: int = await _add_delivered_maps(world)
	# A rotation file's wildcards match what is installed, so match again with the delivered maps.
	world.apply_rotation()

	# The vote was built above, before these arrived; read without them, its list held only
	# the practice map and never opened a ballot. ph_reload refreshes it the same way.
	if vote != null:
		vote.refresh_maps()

	world.start()

	log_info("the map is up", world.describe())
	return DotResult.success(null)


## The rule sets of the player, body and ambience addons, each as cvars: server-side only, or REPLICATED where a client draws or predicts under it.
func _bind_rule_cvars(world: PhGame) -> void:
	# sv_falldamage and its tunables: dot-combat's, on by default in this game. Server-side
	# only, so no REPLICATED: the damage is the server's and arrives as health.
	var _fall := world.fall_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# dot-player-controller's mp_forceview: first or third person, the player's choice or one
	# held. REPLICATED, because each client places its own camera under it.
	var _views := world.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's reaction
	# from them; REPLICATED, because the clients draw the bodies (see the client's netcode).
	var _ragdolls := world.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# The map's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away.
	var _toys := world.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# ph_ambient*: REPLICATED, because each client plays its own ambience under the server's intent; the directory cvar stays local.
	var _ambient := world.ambient_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)


## The maps the SERVER names for this game, fetched and added to the catalogue; returns how many documents.
## The owner names them in the deployment's map config (`cfg/content.yml`, [member DotGameDescriptor.maps]),
## and [DotGameContent] fetches each pack. Called after EVERY catalogue load: `load_from` forgets what was read before.
func _add_delivered_maps(world: PhGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "maps"):
		read += world.catalogue.add_directory(root)

	return read


## Who somebody is reaches the world: a face as they are seated, and the real name and face
## once dot-platform has them. All three events end in [method PhNetBridge.refresh_player].
func _wire_identity() -> void:
	var link := bridge as PhNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
## Through the platform module's `player_for`, never the hub by a key made here: the hub keys by scoped
## profile key, so a `u<session>` lookup finds nobody and reads as "no avatar". Duck-typed; no platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(PhNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as PhNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


func _add_tunables(world: PhGame) -> void:
	# [b]How the stand-ins aim and shoot is dot-bot's[/b]: `bot_difficulty` and every `bot_*`
	# setting it bundles, the names every game in the family uses. On the game as metadata.
	var _bot_cvars := DotBotSettings.of(world).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)


## Older cvar names kept for shipped server configs and map files: alias -> PhConfig field.
const ALIASES := {
	"ph_side_choice": "allow_side_choice",
	"ph_autobhop": "auto_bunny_hop",
	"ph_reveal_points": "reveal_points_per_second",
	"ph_min_players": "minimum_players",
	"sv_map_rotation_file": "map_rotation_file",
}

## dot-workbench over the config; the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled`.
var workbench: DotGameWorkbench = null

var _killcam_cvar: DotConVar = null


## Every [PhConfig] field as a `ph_<field>` cvar, a cfg/ yml key and a workbench set, the cfg/ diff commands, and the older names as aliases that follow the field.
func _bind_config(world: PhGame) -> void:
	var binder := world.config_binder
	if binder == null:
		return
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return server != null and server.admins != null and actor is String \
			and bool(server.admins.uid_has_permission(actor, flag))
	for set: DotProfileSet in binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var ambient_set := DotGameWorkbench.cvar_set(console, PhAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		workbench.add_set(ambient_set, "Ambience (ph_ambient*)")
	add_child(workbench)
	var started := workbench.start(world.ensure_runtime())
	# Off until the owner sets sv_workbench_remote 1; then flagged admins edit from a client.
	if started.ok and net != null:
		var _served := workbench.serve_remote(net)
	var runtime: DotProfileRuntime = workbench.api.runtime if started.ok and workbench.api != null else null
	if not started.ok:
		log_warn("the workbench did not start", {"why": started.error.message})
	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY,
		func(name: String) -> bool: return console.has_name(name))
	binder.bind_commands(add_command)
	for alias: String in ALIASES:
		_alias(world, alias, ALIASES[alias])
	binder.field_changed.connect(_on_config_field)
	if runtime != null:
		binder.attach(runtime)
		if ambient_set != null:
			var _applied := DotGameWorkbench.bind_cvar_set(ambient_set, runtime, console)


## An older cvar name for a config field: it reports the field and writes through the field's own cvar.
func _alias(world: PhGame, alias: String, key: String) -> void:
	var target := world.config_binder.cvar_for(key)
	var cvar := add_cvar(alias, _field_text(world.config.get(key)), "Same as ph_%s" % key)
	if cvar == null or target == null:
		return
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		var value: Variant = world.config.get(key)
		var text := new_value
		if value is bool:
			text = "1" if new_value.to_float() >= 0.5 else "0"
		elif value is int:
			text = str(roundi(new_value.to_float()))
		var _set: Variant = target.set_value(text))


static func _field_text(value: Variant) -> String:
	if value is bool:
		return "1" if value else "0"
	return str(value)


## A field changed from a cvar, the workbench or a file: the aliases follow, and whatever the world copied from the config is told.
func _on_config_field(key: String, _value: Variant, _source: String) -> void:
	var world := game as PhGame
	if world == null:
		return
	var config := world.config
	for alias: String in ALIASES:
		if ALIASES[alias] == key and console != null and console.has_name(alias):
			var _set: Variant = console.set_cvar(alias, _field_text(config.get(key)))
	match key:
		"auto_taunt_seconds", "auto_taunt_radius", "taunt_points", "forced_taunt_points", "taunt_cooldown":
			if world.taunts != null:
				world.taunts.auto_after = config.auto_taunt_seconds
				world.taunts.auto_radius = config.auto_taunt_radius
				world.taunts.cooldown = config.taunt_cooldown
				world.taunts.points_voluntary = config.taunt_points
				world.taunts.points_forced = config.forced_taunt_points
		"disguise_reach", "prop_health_scale", "prop_health_exponent", "prop_min_health", "prop_max_health", \
		"prop_min_dimension", "prop_max_volume", "reveal_cooldown", "reveal_points_per_second", \
		"reveal_paid_seconds", "tilt_step", "max_tilt":
			if world.rules != null:
				config.apply_disguise_rules(world.rules)
		"friendly_fire":
			if world.combat != null and world.combat.rules != null:
				world.combat.rules.friendly_fire = config.friendly_fire
		"run_speed", "walk_speed_scale", "jump_height", "gravity", "air_accelerate", "accelerate", "friction", \
		"stop_speed", "crouch_speed_scale", "auto_bunny_hop":
			world.adopt_movement(config.movement_floats(), config.auto_bunny_hop)
		"killcam_seconds":
			if _killcam_cvar != null and _killcam_cvar.get_string() != _number(config.killcam_seconds):
				var _set: Variant = _killcam_cvar.set_value(_number(config.killcam_seconds))
		"spectate_camera":
			# Through the cvar, so what `mp_forcecamera` reports is what is in force.
			if _force_camera_cvar != null:
				var _held: Variant = _force_camera_cvar.set_value(str(config.spectate_camera))
			elif world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera)
		"minimum_players":
			if _quota != null and _quota.quota_cvar != null:
				var _set: Variant = _quota.quota_cvar.set_value(str(config.minimum_players))
		"map_rotation_file":
			config.map_rotation_file = config.map_rotation_file.strip_edges()
			var _read := world.load_rotation()
			if vote != null:
				vote.refresh_maps()


## The workbench's runtime, so its "noblock" kind is listed beside the config.
func _noblock_runtime() -> Object:
	return workbench.api.runtime if workbench != null and workbench.api != null else null


## Props pass props and hunters pass hunters under `mp_teamblock 0`; players are non-solid here, so nothing physical follows (see [member PhGame.body_rules]).
func _noblock_side(id: Variant) -> Variant:
	return (game as PhGame).team_of_side(id) if game != null else ""


## A number as an operator would type it: `34`, not `34.000000`.
## Not `%g`: the parser accepts it but it fails at RUNTIME ("unsupported format character"), inside `_game_load`,
## which unwinds the module sequence above it.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## mp_forcecamera, once bound. See where the module binds dot-spectate's cvars.
var _force_camera_cvar: DotConVar = null


## Nothing to undo: [DotModule] removes the commands and [DotGameModule] tears down the netcode, bridge and
## roster in reverse. The world is NOT freed here; it predates the module and `module reload` keeps the map.
func _game_unload() -> void:
	if workbench != null:
		workbench.queue_free()
		workbench = null
	if game != null and "block_rules" in game:
		game.set(&"block_rules", null)
	noblock = null
	_bot_ids.clear()

	if vote != null:
		vote.queue_free()
		vote = null


## The server slept or woke. The vote's director follows it on its own (DotGameModule finds
## it); the map ballot's timer is this game's, so it starts again here on waking.
func _game_hibernation(hibernating: bool) -> void:
	if not hibernating and vote != null:
		vote.note_woke()


## Keeps enough people in the round for there to be one.
## A hunter and a prop, or nothing: a round ends when a side has nobody alive, and an empty side satisfies that
## on the first tick, so one person would see rounds start and end forever with no error.
func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)

	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()
	_note_pings()


## Each session's ping onto its player, for the Tab board. dot-server already keeps it.
func _note_pings() -> void:
	var world := game as PhGame
	if world == null or server == null:
		return
	for session in server.playing_sessions():
		var who: PhPlayer = world.players.get(PhNetBridge.player_key(session.userid))
		if who != null:
			who.ping_ms = session.ping_ms


func _keep_the_round_full() -> void:
	var world := game as PhGame

	if world == null or bridge == null or _quota == null:
		return

	# People only: a stand-in is not one, nor is a bot added by hand (never in `_bot_ids`). A leaver
	# leaves `players` the moment the bridge removes them, so nobody half-disconnected is counted.
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as PhPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	# `ph_bots 0` takes the stand-ins out as well as not adding more: a switch that left the
	# ones already in until a map change would be an operator with no way to empty a server.
	var wanted := 0

	if _bots == null or _bots.get_bool():
		var slots: int = server.config.max_players if server != null and server.config != null else -1
		wanted = _quota.wanted(humans, slots)

	for _i in range(maxi(wanted - _bot_ids.size(), 0)):
		var bot: PhPlayer = bridge.call("add_bot", _bot_name(world))

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	# Newest first, so the stand-in a person replaces is the one that arrived last and the
	# ones that have been playing longest keep playing.
	while _bot_ids.size() > wanted:
		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", PhNetBridge.session_of(leaving))


## Names for the stand-ins, so a scoreboard of four of them is readable: this game's own
## furniture names through dot-bot's [DotBotNames], never one already in [param world] (drawn
## at random they could double up).
static func _bot_name(world: PhGame) -> String:
	var taken: Array = []
	for id: StringName in world.players:
		taken.append((world.players[id] as PhPlayer).display_name)
	return DotBotNames.pick(taken, world.players.size(), PhGame.BOT_NAMES)


## Joins the bridge's chat seam to the services layer's router.
## Here because this is the only object holding both: only a channel id and a string cross the wire, so a
## client cannot send a line with somebody else's name on it.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## What the ballot asks the game: the maps, the voters, who may change the map and where a ballot goes.
func _set_vote_hooks(world: PhGame) -> void:
	vote.commands_spec_fn = world.rotation_commands
	vote.in_rotation_fn = func(id: StringName) -> bool: return world.catalogue.in_rotation(id)
	vote.rotation_order_fn = func() -> Array: return world.catalogue.rotation_order
	vote.maps_fn = func() -> Array:
		var out: Array = []

		# The game's own maps only: the Workshop's come from the source's own follow, which
		# reads the index on every ballot and so shows none of them online.
		for id in world.catalogue.playable(world.config.map_ids):
			# maps.yml: a map outside the active rotation is not balloted or nominated.
			if not world.catalogue.is_workshop(id) and world.catalogue.in_rotation(id):
				out.append([id, str((world.catalogue.maps.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_map_id = id
		return DotResult.success(id)
	vote.due_fn = func() -> bool:
		return world.rounds_left_on_map() <= 1
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: PhPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := PhNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, PhServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()


## The players' vote for the next map, over dot-vote: `!vote`, `!rtv`, `!nominate`.
## Opened [member PhVote.open_after_sec] into the last round and applied when it ends; configured in
## `user://cfg/prophunt_vote.json` or `game.yml`. A vote that cannot be built is a WARN, never a server that won't start.
func _build_vote(world: PhGame) -> void:
	if world.catalogue == null:
		return

	vote = PhVote.new()
	vote.name = "MapVote"
	_set_vote_hooks(world)

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the map vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the map vote's commands", commanded)

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# map now, not after its rounds, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_map_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.map_rows())

	var vote_after := add_cvar("ph_vote_after", _number(vote.open_after_sec),
		"Seconds into the last round on a map before the vote for the next one opens")
	if vote_after != null:
		vote_after.changed.connect(func(_old: String, new_value: String) -> void:
			if vote != null:
				vote.open_after_sec = maxf(new_value.to_float(), 0.0))

	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.map != null:
			vote.note_map(world.map.id())
	)
	world.round_began.connect(func(_number: int, _map: StringName) -> void:
		if vote != null:
			vote.note_round_start()
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


## The map is what a server listing prints, reported on every rebuild: the server forgets it
## whenever a game unloads, and a browser showing last round's map is a browser lying.
func _wire_map(world: PhGame) -> void:
	if world.map != null and not world.map.doc.is_empty():
		report_map(String(world.map.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.map.id()))
	)


## An achievement is told to the one person who earned it, as a notice (text for one player, which a client
## already draws in chat); a stand-in never earns one, as [PhProgress] does not count them.
func _wire_progress(world: PhGame) -> void:
	if bridge == null:
		return

	# Filed under dot-game's stable per-server key (guests too), so it outlives the connection
	# and a restart; see [PhProgress].
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(PhNetBridge.session_of(id)) \
				if server != null else null
			return String(stats_feed.key_for(session)) if session != null and stats_feed != null else ""

		var report := bind_stats_report(world.progress.set_reporting)
		if world.config.report_progress and report.get_string() != "1":
			var _on := report.set_value("1")

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", PhNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat, run through the console as the person who typed it: `run_command_as_uid`
## uses that player's own flags, so `!kick` is refused by the same file that refuses it at the console.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.map_directory)
	loaded += await _add_delivered_maps(world)
	world.apply_rotation()

	if vote != null:
		vote.refresh_maps()

	ctx.reply("%d documents read; %d refused. The next map draws from them." % [
		loaded, world.catalogue.refused.size()])


## This game's columns on the Tab board: the points, and which side.
func _game_board_fields(session: Object) -> Dictionary:
	var world := game as PhGame
	var who: PhPlayer = world.players.get(PhNetBridge.player_key(int(session.get(&"userid")))) if world != null and session != null else null

	if who == null:
		return {}

	return {"points": who.points, "team": world.team_of(who.player_id)}


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as PhGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
