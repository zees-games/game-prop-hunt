extends "dedicated_vote.gd"
const PHTestPorts := preload("test_ports.gd")

const PhAmbience := preload("../game/ph_ambience.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhPlayer := preload("../game/ph_player.gd")
const PhProgress := preload("../game/ph_progress.gd")
const PhNetBridge := preload("../game/net/ph_net_bridge.gd")
const PhNetLink := preload("../game/net/ph_net_link.gd")

## The game as a deployed server runs it: a real [GSServer] booted from a config file, the module loaded BY PATH as an operator names it.
## The only suite where [PhModule] loads, [GSGameModule]'s order runs, a cvar is typed at a console and a round is played by the stand-ins the module seats itself (`headless_run` and `headless_net` cannot reach these).

const SECTIONS := 14
const CHECKS := 120

const SERVER_DIR := "user://ph_dedicated"
var PORT := PHTestPorts.free_port(2)
var QUERY_PORT := PORT + 1
const TICK_RATE := 60


var _stats_errors: PackedStringArray = []


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	GSLog.signals().record.connect(_on_log_record)
	_run.call_deferred()


## An ERROR from the stats layer would otherwise scroll past and leave a stat dead with every check green.
func _on_log_record(rec: Dictionary) -> void:
	if int(rec.get("level", 0)) >= GSLog.Level.ERROR and String(rec.get("channel", "")).begins_with("stats"):
		_stats_errors.append(str(rec.get("message", rec)))


func _run() -> void:
	print("prophunt as a dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	GSPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == GSServer.State.RUNNING:
		await _test_the_module_loads()
		await _test_the_commands()
		await _test_a_round_runs()
		await _test_a_reload_keeps_delivered_maps()
		await _test_the_map_vote()
		_test_map_rotation_file()
		await _test_a_module_reload()
		_test_finish_round_waits_for_a_live_round()
		await _test_ambient_cvars_reach_the_client()
		await _test_it_unloads_cleanly()

	_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	_check(_stats_errors.is_empty(), "the stats layer logged no error", str(_stats_errors))
	_check(PhProgress.schema().validate().ok, "the stats schema, hitzones included, validates")

	await _shut_down()
	GSPaths.remove_tree(SERVER_DIR)
	_report_sections(_sections_entered, _sections_finished, sections, checks)


## Takes the server down before quitting: a booted [GSServer]'s listener holds the main loop,
## and a run that only called `quit()` prints its results and hangs. See mg-smash-copter.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	if is_instance_valid(game):
		remove_child(game)
		game.free()
		game = null

	if is_instance_valid(server):
		remove_child(server)
		server.free()
		server = null

	await get_tree().process_frame


func _boot() -> void:
	_section("booting")

	# `startup_config`, because `sv_tickrate` is startup-only and dot-server execs this file
	# before the listener for exactly that reason.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.close()

	var config := GSServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.hostname = "prophunt test"
	config.max_players = 24
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# Off, or this run never ends: a thread blocked in a read of stdin is one Godot will not
	# exit without.
	config.stdin_console_enabled = false

	server = GSServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	for _i in range(120):
		await get_tree().process_frame

		if server.state == GSServer.State.RUNNING:
			break

	_check(server.state == GSServer.State.RUNNING, "the server boots", GSServer.State.keys()[server.state])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "and sv_tickrate reached the engine",
		"%d" % Engine.physics_ticks_per_second)
	_finished()


func _test_the_module_loads() -> void:
	_section("the module")

	# The world is built after the server (whose tick rate it reads) and before the module
	# (which refuses to load without a world to run; it cannot build one).
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.hide_seconds = 3.0
	config.round_seconds = 30.0
	config.minimum_players = 3
	config.map_ids = PackedStringArray(["ph_practice"])

	game = PhGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = PhConfig.make_binder(config)
	game.config_binder.strict = true
	var _layers := game.config_binder.load_layers()
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	_check(GSRegistry.get_node_service(PhGame.SERVICE) == game, "the world publishes itself where a module looks")
	_check(not game.map_doc.is_empty(), "and already has a map")

	(load("res://game/ph_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: GSResult = await server.modules.load_module("res://game/ph_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")

	var module := _module()
	_check(game != null and game.progress != null and game.progress.durable_key_fn.is_valid(),
		"progress is filed under dot-game's stable stats key")
	_check(module != null and module.get("net") != null and module.get("bridge") != null,
		"with its netcode and the game's bridge")

	var net: GSNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.tick_rate == TICK_RATE, "the netcode runs at the configured rate")
	_check(net != null and absf(net.config.world_extent - PhGame.NET_WORLD_EXTENT) < 0.01,
		"against the world extent both ends decode with")
	_noblock_and_config(module)
	_test_stats_report()
	_finished()


## The family cvar `stats_report` is registered, off, and turning it on makes the tracker report.
func _test_stats_report() -> void:
	var cv: GSConVar = server.console.find_cvar("stats_report")
	var progress = game.progress if game != null else null
	_check(cv != null and cv.get_string() == "0", "stats_report is registered and off by default")
	_check(progress != null and progress.stats != null and not progress.stats.report_to_backbone,
		"and the tracker does not report at boot")
	if cv == null or progress == null:
		return
	var _on := cv.set_value("1")
	_check(not progress.stats.report_to_backbone, "on with no backbone client stays off, not a crash")

	var client := Node.new()
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc post_integration(_a = null, _b = null, _c = null): return null\n"
	var _reloaded := script.reload()
	client.set_script(script)
	GSRegistry.register(&"dot_backbone_client", client)
	var _r0 := cv.set_value("0")
	var _r1 := cv.set_value("1")
	_check(progress.stats.report_to_backbone, "on with a backbone client makes the tracker report")
	var _r2 := cv.set_value("0")
	_check(not progress.stats.report_to_backbone, "off stops it again")
	GSRegistry.unregister_instance(&"dot_backbone_client", client)
	client.free()

	var zoned := GSDamage.make(1, 2, 5.0, game.combat.damage_type(&"kinetic"))
	zoned.hit_group = GSHitGroup.NECK
	zoned.weapon_id = &"probe"
	progress.stats.begin(&"ph-test", "ph-test")
	progress.report_hit(&"ph-test", &"ph-victim", zoned)
	_check(
		progress.stats.session_values(&"ph-test").get_cell(GSStatsHitzones.HITS, "zone:neck") >= 1.0,
		"a hit with a hit_group is filed by body zone through the dot-stats hitzone hook"
	)
	_check(progress.stats.schema.has(&"rank_score") and progress.rank != null, "rank_score is declared and the rank is set up")
	var _held := GSStatsValues.new()
	_held.values = {"ph.rounds_won": 10.0}
	progress.rank.seed_baseline(&"ph-rank", _held)
	var _life: float = progress.rank.publish_lifetime(&"ph-rank", GSStatsValues.new(), progress.stats.schema)
	_check(_life == 20.0, "a stored lifetime baseline (10 wins) is what the published rank is built on")


## Config cvars, the workbench, and dot-team's block rules through dot-game's GSGameNoblock.
func _noblock_and_config(module: GSModule) -> void:
	var teamblock := server.console.find_cvar("mp_teamblock")
	var enemyblock := server.console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1",
		"mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(server.console.has_name("ph_decoy_penalty") and server.console.has_name("ph_friendly_fire") and server.console.has_name("ph_accelerate"),
		"config fields are ph_ cvars")
	_check(module.get("workbench") != null, "the module hosts the workbench")
	var wb: GSGameWorkbench = module.get("workbench")
	var amb: GSResult = wb.api.handle(GSGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "ambience", "id": GSGameWorkbench.CVAR_SET_ID, "key": "ph_ambient_volume", "value": 0.2})
	_check(amb.ok and is_equal_approx(server.console.get_float("ph_ambient_volume"), 0.2), "the ph_ambient* cvars are a workbench set and an edit moves the cvar", "" if amb.ok else amb.error.message)
	var rotation := server.console.find_cvar("sv_map_rotation_file")
	game.config.map_rotation_file = "cfg/other.yml"
	module.call("_on_config_field", "map_rotation_file", game.config.map_rotation_file, "workbench")
	_check(rotation != null and rotation.get_string() == "cfg/other.yml", "a workbench edit reaches the older sv_map_rotation_file")
	game.config.map_rotation_file = "cfg/maps.yml"
	module.call("_on_config_field", "map_rotation_file", game.config.map_rotation_file, "workbench")
	game.config.friendly_fire = true
	module.call("_on_config_field", "friendly_fire", true, "workbench")
	_check(game.combat.rules.friendly_fire, "friendly_fire reaches the live damage rules")
	game.config.friendly_fire = false
	module.call("_on_config_field", "friendly_fire", false, "workbench")
	_check(game.block_rules != null and not game.body_rules.solid and not game.body_rules.blocks(&"a", &"b"),
		"players stay non-solid, so the block rules change nothing physical")
	_check(game.team_of_side(&"nobody") == "", "a player with no side has none")


func _test_the_commands() -> void:
	_section("the console")
	_check(_said(_run_command("ph_status"), "prophunt"), "ph_status says what the round is doing")
	_check(_said(_run_command("ph_maps"), "ph_practice"), "ph_maps lists the maps")
	_check(_said(_run_command("ph_taunts"), "You lose"), "ph_taunts lists the taunts")
	_check(_said(_run_command("ph_net"), "bridge"), "ph_net says what the netcode is doing")

	# A cvar's default is the value the world was built with, and setting one writes through.
	_check(_said(_run_command("ph_round_seconds"), "30"), "ph_round_seconds reports the world's own value")
	var _set := _run_command("ph_round_seconds 45")
	_check(is_equal_approx(game.config.round_seconds, 45.0), "and setting it writes through to the world",
		"%.1f" % game.config.round_seconds)
	var _many := _run_command("ph_max_hunters 40")
	_check(game.config.max_hunters == 40, "the most hunters takes any count, not a ceiling",
		"%d" % game.config.max_hunters)
	var _back := _run_command("ph_max_hunters 0")
	_check(game.config.max_hunters == 0, "and 0 is no limit", "%d" % game.config.max_hunters)
	var _min := _run_command("ph_min_hunters 20")
	_check(game.config.min_hunters == 20, "the least hunters takes any count too", "%d" % game.config.min_hunters)
	var _min_back := _run_command("ph_min_hunters 1")
	var _max_back := _run_command("ph_max_hunters 8")
	# And it is REPLICATED: dot-server sends it to every client before its scene loads and on
	# every change, so a client's own combat manager (following its link) predicts tracers
	# under the server's level rather than its default.
	var shared := server.console.find_cvar("mp_teammate_passthrough")
	var _two := _run_command("mp_teammate_passthrough 2")
	_check(shared != null and shared.has_flag(GSConVar.FLAG_REPLICATED)
			and server.console.replicated_values().get("mp_teammate_passthrough", "") == "2",
		"mp_teammate_passthrough is replicated: a client is sent the server's level",
		str(server.console.replicated_values()))
	var _one := _run_command("mp_teammate_passthrough 1")

	# Dead bodies are the owner's: dot-player-char's sv_ragdoll* set, REPLICATED (a client draws
	# the bodies) and on the world's own rules, which the server picks each death's fall from.
	var ragdoll := server.console.find_cvar("sv_ragdoll")
	var _no_ragdolls := _run_command("sv_ragdoll 0")
	var _no_limp := _run_command("sv_ragdoll_reactions limp=0")
	_check(ragdoll != null and ragdoll.has_flag(GSConVar.FLAG_REPLICATED) and not game.ragdoll_rules.enabled
			and server.console.replicated_values().get("sv_ragdoll", "") == "0"
			and game.ragdoll_rules.reactions().find(&"limp").weight == 0.0,
		"sv_ragdoll* are registered, replicated, and reach the world's rules", str(game.ragdoll_rules.describe()))
	var _ragdolls_back := _run_command("sv_ragdoll 1")
	server.console.find_cvar("sv_ragdoll_reactions").reset()

	# B's server half: `loadout` and the owner's three cvars, enforced by the world's manager.
	_check(server.console.find_command("loadout") != null and server.console.find_cvar("mp_loadout_menu") != null
		and server.console.find_cvar("mp_loadout_allow") != null and server.console.find_cvar("mp_loadout_fixed") != null,
		"the server has the hunters' loadout command and the owner's mp_loadout_* cvars")
	var _fixed := _run_command("mp_loadout_fixed primary=shotgun")
	var _off := _run_command("mp_loadout_menu 0")
	var locked: GSResult = await game.loadouts.active_for(game.storage_key(&"u999"))
	var typo := _run_command("mp_loadout_allow barrel=smg")
	_check(locked.ok and (locked.value as GSLoadout).item_in(&"primary") == &"shotgun"
		and server.console.find_cvar("mp_loadout_allow").get_string() == "",
		"locked by the owner every hunter carries the fixed shotgun, and a slot that does not exist is refused",
		str(typo))
	var _on := _run_command("mp_loadout_menu 1")
	var _free := _run_command("mp_loadout_fixed \"\"")
	_finished()


## A whole round, played by the stand-ins the module seats on its own.
func _test_a_round_runs() -> void:
	_section("a round, played by the stand-ins")
	var rounds: Array = []
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: rounds.append([n, winner, why]))

	# Real time: the server ticks itself and the module tops it up every two seconds; a round is
	# three seconds of hiding and at most forty-five of seeking.
	var until := Time.get_ticks_msec() + 75000

	while Time.get_ticks_msec() < until and rounds.is_empty():
		await get_tree().physics_frame

	var bots := 0

	for id: StringName in game.players:
		if (game.players[id] as PhPlayer).is_bot:
			bots += 1

	var landed := await _until(func() -> bool: return game.bots.nav.is_ready() and not game.bots.nav.is_baking(), 20.0)
	_check(landed, "the async nav bake landed and the stand-ins have a mesh", "baking=%s" % game.bots.nav.is_baking())
	_check(bots == game.config.minimum_players, "the module seated stand-ins up to the minimum", "%d" % bots)
	_check(game.players_on(PhGame.HUNTERS).size() == 1, "and drew one of them to hunt")
	_check(not rounds.is_empty(), "and a round was decided", str(rounds))
	_check(not rounds.is_empty() and str(rounds[0][2]) != "", "with a sentence saying why", str(rounds))
	# A person takes a stand-in's place and leaving gives it back (GSBotQuota fill mode). The
	# roster check is called directly, with a person added through the bridge (peer zero).
	var quota_module := _module()
	var quota_bridge: Object = quota_module.get("bridge") if quota_module != null else null
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota_mode") != null,
		"the shared bot_quota cvars are registered")
	# How the stand-ins aim and shoot is dot-bot's: the family's names, medium by default.
	var bot_settings := GSBotSettings.of(game)
	_check(server.console.get_string("bot_difficulty", "") == "medium" and bot_settings.difficulty() == "medium",
		"bot_difficulty is the module's and medium is the default")
	var _hard := _run_command("bot_difficulty hard")
	_check(bot_settings.difficulty() == "hard" and is_equal_approx(server.console.get_float("bot_reaction"), GSBotProfile.preset_value("hard", "reaction")),
		"bot_difficulty hard writes every bot_* setting", server.console.get_string("bot_reaction"))
	var _medium := _run_command("bot_difficulty medium")
	var _alias := _run_command("ph_min_players 3")
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota").get_int() == 3,
		"and the old ph_min_players sets bot_quota",
		server.console.find_cvar("bot_quota").get_string() if server.console.find_cvar("bot_quota") != null else "missing")

	if quota_module != null and quota_bridge != null:
		quota_module.call("_keep_the_round_full")
		var bots_before: int = (quota_module.get("_bot_ids") as Array).size()
		var joined: GSResult = quota_bridge.call("add_player", 0, 9001, "Person")
		quota_module.call("_keep_the_round_full")
		var bots_with: int = (quota_module.get("_bot_ids") as Array).size()
		_check(joined.ok and bots_before == 3 and bots_with == bots_before - 1,
			"a person joining takes a stand-in's place", "%d -> %d" % [bots_before, bots_with])
		quota_bridge.call("remove_player", 9001)
		quota_module.call("_keep_the_round_full")
		var bots_after: int = (quota_module.get("_bot_ids") as Array).size()
		_check(bots_after == bots_before, "and a stand-in comes back when they leave",
			"%d -> %d" % [bots_with, bots_after])
		_covered_seat_cannot_be_harmed(quota_module, quota_bridge)
	else:
		_check(false, "a person joining takes a stand-in's place", "no module")
		_check(false, "and a stand-in comes back when they leave", "no module")

	var _restored := _run_command("ph_min_players 3")

	_check(_said(_run_command("ph_status"), "round"), "and ph_status still answers")
	_finished()


## A seat behind its client's loading cover cannot be hurt or eliminated (dot-game's "still loading"): a real peer marked loading takes a lethal hit that must be refused,
## and once the cover lifts the same hit lands. Stand-in rounds never reach this, a bot never being loading.
func _covered_seat_cannot_be_harmed(module: Object, bridge: Object) -> void:
	_section("a covered seat cannot be harmed")
	var roster: Object = module.get("roster")
	var joined: GSResult = bridge.call("add_player", 7, 9002, "Covered")
	var who: PhPlayer = game.players.get(PhNetBridge.player_key(9002))
	_check(joined.ok and who != null and roster != null, "a person with a peer is seated")
	if not (joined.ok and who != null and roster != null):
		return
	# What the roster's spawn hook does for a person, by hand: the peer's seat, then loading.
	(roster.get("_peer_seat") as Dictionary)[7] = 9002
	roster.call("_start_loading", 9002, true)
	_check(bool(module.call("is_peer_loading", 7)) and not game.can_be_harmed(PhNetBridge.player_key(9002)),
		"the seat is loading and the world will not harm it")
	var before := who.health.health
	var hit := GSDamage.make(0, who.entity_id, who.health.max_health * 10.0, null)
	hit.context = {"why": &"test"}
	var _applied: Variant = game.combat.apply_damage(hit)
	_check(who.is_alive() and is_equal_approx(who.health.health, before),
		"a lethal hit on a loading seat is refused and the seat stays up",
		"%s -> %s" % [before, who.health.health])
	roster.call("_finish_loading", 9002, "test")
	var hit2 := GSDamage.make(0, who.entity_id, 1.0, null)
	hit2.context = {"why": &"test"}
	var _applied2: Variant = game.combat.apply_damage(hit2)
	_check(who.health.health < before, "and once the cover lifts the same kind of hit lands",
		"%s -> %s" % [before, who.health.health])
	bridge.call("remove_player", 9002)
	_finished()


## `time_up: finish_round` waits for a round being played, never for warmup: without the game's `round_in_progress_fn` a limit that ran out in warmup held the change for `finish_round_max_sec`.
## Run on a director of its own carrying the game's hook, so the real vote's clock is untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: GSVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: GSMatch = game.match_node
	var was := match_node.state
	match_node.state = GSMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = GSMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = GSMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> GSVoteDirector:
	var source := GSVoteListSource.new()
	var _a := source.add(GSVoteChoice.of(&"a", "A"))
	var _b := source.add(GSVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> GSResult:
		applied.append(id)
		return GSResult.success(id)

	var rules := GSVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = GSVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = GSVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := GSVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## A reload keeps the maps the server names: `ph_reload` calls `load_from`, which forgets everything read before, and every delivered map vanished until a restart with nothing logged.
## A pack "mounted" on disk and a descriptor naming it stand in for dot-cloud and the deployment's `cfg/content.yml`.
func _test_a_reload_keeps_delivered_maps() -> void:
	_section("a reload keeps the maps the server names")
	var key := "dot-test/ph-delivered@1.0.0"
	var mount := GSGameContent.mount_of(key)
	var dir := mount.path_join("maps")
	var id := &"ph_delivered_check"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = game.catalogue.practice()
	doc["id"] = String(id)
	var file := FileAccess.open(dir.path_join("delivered_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(doc))
	file.close()

	# The manager's running descriptor, named the way a deployment names it. Restored below:
	# `_current` is the manager's own, and nothing else in this suite should see the pack.
	var manager: Object = server.games
	var was: Variant = manager.get("_current")
	var named := GSGameDescriptor.new()
	named.maps = PackedStringArray([key])
	manager.set("_current", named)

	var _first := _run_command("ph_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(game.catalogue.maps.has(id), "a map the server names is in the catalogue after ph_reload",
		str(game.catalogue.maps.keys()))
	_check(game.catalogue.maps.has(&"ph_practice"),
		"beside the built-in one")

		# The ballot sees them from boot, not only after a reload: _game_load builds the vote before the delivered maps arrive, and a list read then held only the practice map.
		# A module unloaded and loaded with the pack named is a boot (not module_reload, which reloads the script under live instances); the world still holds the map from the ph_reload above,
		# which a vote built at load would read without the fix.
	var only := game.config.map_ids
	game.config.map_ids = PackedStringArray()
	var _builtin := game.catalogue.load_from(game.config.map_directory)
	var reloaded := _run_command("module_unload prophunt")
	reloaded.append_array(_run_command("module_load res://game/ph_module.gd"))
	for _i in range(60):
		await get_tree().process_frame

		if _module() != null and _module().get("vote") != null:
			break
	var booted_vote: Node = _module().get("vote") if _module() != null else null
	var booted_ids: Array = []

	if booted_vote != null:
		for choice: GSVoteChoice in (booted_vote.get("source") as GSVoteListSource).entries:
			booted_ids.append(String(choice.id))

	_check(booted_ids.has(String(id)), "and on the ballot of a module that boots with it named, unrefreshed",
		"%s %s" % [reloaded, booted_ids])
	game.config.map_ids = only

	manager.set("_current", was)
	var _second := _run_command("ph_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(not game.catalogue.maps.has(id), "and it came from the server's list: unnamed, a reload drops it")

	DirAccess.remove_absolute(dir.path_join("delivered_check.json"))
	var path := dir
	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()
	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


## A module reload must leave ONE link under the server, named for the client's route: a second, the live one renamed `@Node@n`, lost every RPC to a real client without an error.
## The proof is a real client over the socket: signing on is server events.
func _test_a_module_reload() -> void:
	_section("a module reload leaves one live link")

	for _i in range(2):
		_check(server.modules.unload_module("prophunt").ok, "the module unloads")
		var back: GSResult = await server.modules.load_module("res://game/ph_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == PhNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(PhNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := GSClientLink.new()
	link.name = "Server"
	link.player_name = "Reloaded"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(PhNetLink.NODE_NAME)) == null:
			var sink := PhNetLink.attached_to(link, null, false)
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == GSClientLink.Phase.FAILED, 30.0)
	_check(joined and spawned[0], "a real client still hears the server's events after two reloads")
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_finished()


func _test_ambient_cvars_reach_the_client() -> void:
	_section("the server's ph_ambient* reaches a client's ambience director, live")
	var side := Node.new()
	side.name = "AmbientClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	var link := GSClientLink.new()
	link.name = "Server"
	link.player_name = "Ambient"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var rules := PhAmbience.make_rules()
	var _followed := rules.follow_cvars(link)
	var director := GSAmbienceDirector.new()
	director.ambient = GSAmbience.new()
	director.follow_settings(null, rules)
	var joined := await _until(func() -> bool:
		return link.replicated_cvar("ph_ambient_volume", "") != "", 30.0)
	_check(joined and link.replicated_cvar("ph_ambient_dir", "x") == "x",
		"the join carried ph_ambient_volume, and the machine-local ph_ambient_dir stayed home", str(link.replicated_cvars))
	var _vol := server.console.set_cvar("ph_ambient_volume", "0.8")
	var _mood := server.console.set_cvar("ph_ambient_mood", "swamp")
	var _off := server.console.set_cvar("ph_ambient", "0")
	var arrived := await _until(func() -> bool:
		return is_equal_approx(director.ambient.config.volume, 0.8) and director.ambient.config.mood == "swamp" \
			and not director.ambient.config.enabled, 15.0)
	_check(arrived, "a change of volume, mood and the switch reaches the director live", str(rules.describe()))
	var _back_vol := server.console.set_cvar("ph_ambient_volume", "0.3")
	var _back_mood := server.console.set_cvar("ph_ambient_mood", "")
	var _back_on := server.console.set_cvar("ph_ambient", "1")
	var back := await _until(func() -> bool: return rules.is_on() and rules.mood == "", 15.0)
	_check(back, "and back", str(rules.describe()))
	director.ambient.free()
	director.free()
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_finished()


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _test_it_unloads_cleanly() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(server.console.find_command("ph_status") == null if server.console.has_method("find_command") else true,
		"and takes its commands with it")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished()


## No message script preloads itself: in mg-buses-from-hell that one line leaked the whole
## script graph at exit (8ed866c), and the leak is printed after `quit()`, where no assertion
## reaches. So the cause is checked, on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()
	var dir := DirAccess.open("res://game/net")

	for file in dir.get_files():
		if not file.ends_with(".gd"):
			continue

		var source := FileAccess.get_file_as_string("res://game/net/" + file)

		if source.contains("extends GSNetMessage") and source.contains("preload(\"%s\")" % file):
			offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished()
