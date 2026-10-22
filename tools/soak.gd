extends Node

const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")
const PhPlayer := preload("../game/ph_player.gd")

## Bot soak on the real game: N stand-ins play rounds on one map for M simulated minutes through
## dot-bot's DotBotSoak, fed by dot-spawn's DotSpawnWatch.
##
## [codeblock]
## ./game.sh soak [map] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map ph_house --bots 6 --minutes 2
## [/codeblock]
##
## Takes the harness's own flags too (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<map>.json, prints the SOAK line, exits 1 when the run fails.
## Rounds run back to back. Only a live hunter in the seek counts as a mover with a goal: props
## stand still by design and hunters are held in the hide.

const DEFAULT_MAP := &"ph_house"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 6
const TICK_RATE := 32

var _game: PhGame
var _rounds_over := 0
var _seek_ticks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := _arg("map", String(DEFAULT_MAP))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])
	# Short rounds so a run sees several rounds and teardowns, not one long hide.
	config.hide_seconds = 10.0
	config.round_seconds = 90.0

	_game = PhGame.new()
	_game.name = "World"
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.authoritative = true
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)
	_game.round_over.connect(func(_n: int, _w: int, _name: String) -> void: _rounds_over += 1)
	await get_tree().physics_frame
	await get_tree().physics_frame

	for i in range(cfg.bots):
		var bot := _game.add_player(StringName("u%d" % (900100 + i)), "Bot%d" % i)
		bot.is_bot = true
	_game.start()
	if String(_game.map_doc.get("id", "")) != map_id:
		_fail("no map %s (playing %s)" % [map_id, _game.map_doc.get("id", "none")])
		return

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so deferred frees run.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = map_id
	report["rounds"] = _game.round_number
	report["rounds_over"] = _rounds_over
	report["seek_sec"] = snappedf(float(_seek_ticks) / float(TICK_RATE), 0.1)
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	await _release_game()
	get_tree().quit(0 if report["ok"] else 1)


## Frees the game before quitting: a world still loaded at quit can abort the process.
func _release_game() -> void:
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame


func _step(delta: float) -> void:
	if _game.phase == PhGame.Phase.SEEK:
		_seek_ticks += 1
	_game.simulate(delta)


func _movers() -> Array:
	var out: Array = []
	var seeking: bool = _game.phase == PhGame.Phase.SEEK
	for id: StringName in _game.players:
		var body: PhPlayer = _game.players[id]
		if body.controller == null:
			continue
		var hunting: bool = seeking and _game.team_of(id) == PhGame.HUNTERS and body.is_alive() and not body.watching
		out.append({"id": id, "position": body.controller.state.position, "kind": &"bot", "has_goal": hunting})
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
