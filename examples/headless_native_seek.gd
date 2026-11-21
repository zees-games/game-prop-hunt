extends GSGameCheckSuite

const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")
const PhSeek := preload("../game/ph_bots_seek.gd")
const PhPlayer := preload("../game/ph_player.gd")

## The seeking hunters' senses in one dot-sim call a tick ([code]GSSimHunterSeek[/code],
## [member PhSeek.seek_mode]) play exactly as the script's: two seeded servers of the same round in
## lockstep, one asking in script and one native, each in its own physics world, must match to the
## bit every tick (hunters' places, aims, doubt, tests and searches; props' places and lives).
## Then a native round with [member PhSeek.seek_verify] on asks the script beside every answer and
## must count no difference. With no library the native half is skipped;
## [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.

## Maps played when `maps/` is linked in; the practice house alone otherwise (CI clones this repository alone).
const MAPS := ["ph_practice", "ph_house", "ph_school"]
const BOTS := 16
const TICK_RATE := 32
## Seek ticks played after the hide phase, per map.
const SEEK_TICKS := 640
const CHECKS_PER_MAP := 6

var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Prop Hunt native seek")
	print("")
	var maps: Array = MAPS if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps")) else ["ph_practice"]

	_entered += 1
	print("the hunters' senses are native by default, and the library has them")
	_check(PhSeek.seek_mode == "native", "PhBots.seek_mode is native without the game turning it on")
	if not GSSim.has(&"seek") or not GSSim.has(&"sight"):
		print("  dot-sim's seek module is not loaded: the native half is skipped")
		_check((OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("DOT_SIM_REQUIRE_NATIVE")) != "1", "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_finished += 1
		_report_sections(_entered, _finished, 1, 2)
		return
	_check(true, "the library has the seek batch")
	_finished += 1

	for id: String in maps:
		_entered += 1
		print("%s: script and native in lockstep, then a checked native round" % id)
		await _on_map(id)
		_finished += 1

	PhSeek.seek_mode = "native"
	PhSeek.seek_verify = false
	_report_sections(_entered, _finished, 1 + maps.size(), 2 + CHECKS_PER_MAP * maps.size())


func _make_game(id: String, tag: String) -> PhGame:
	var view := SubViewport.new()
	view.name = "View_%s_%s" % [id, tag]
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(view)
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([id])
	config.seed_value = 20261117
	config.hide_seconds = 20.0
	config.round_seconds = 600.0
	var game := PhGame.new()
	game.name = "Game"
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.draw_world = false
	game.register_service = false
	view.add_child(game)
	game.set_physics_process(false)
	var _set := GSBotSettings.of(game).set_difficulty("medium")
	return game


func _start(game: PhGame) -> void:
	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()


func _drop(game: PhGame) -> void:
	var view := game.get_parent()
	remove_child(view)
	view.free()


## One tick of [param game] with the hunters asking [param mode]'s way.
func _step(game: PhGame, mode: String) -> void:
	PhSeek.seek_mode = mode
	game.simulate(1.0 / TICK_RATE)


## Everything the senses steer, to the bit: hunters' bodies, aims, doubt, tests, goals and searches,
## and the props' bodies and lives.
func _digest(game: PhGame) -> PackedByteArray:
	var bots: Object = game.bots
	var rows: Array = [game.phase]
	for player: PhPlayer in game.players_on(PhGame.HUNTERS):
		var s: Object = player.controller.state
		var row: Array = [player.player_id, s.position, s.velocity, s.yaw, s.pitch, player.is_alive()]
		var state: Dictionary = bots.call("_state_of", player)
		row.append(state["doubt"])
		row.append(state["test"])
		row.append(state.get("goal_place", {}))
		row.append(state["prey"])
		var search: Object = state["search"]
		if search != null:
			var seen := PackedFloat64Array()
			for place: Dictionary in search.get("places"):
				seen.append(float(place["seen_at"]))
			row.append(seen)
		rows.append(row)
	for player: PhPlayer in game.players_on(PhGame.PROPS):
		var s: Object = player.controller.state
		rows.append([player.player_id, s.position, player.is_alive()])
	return var_to_bytes(rows)


func _doubting(game: PhGame) -> int:
	var n := 0
	for player: PhPlayer in game.players_on(PhGame.HUNTERS):
		n += (game.bots.call("_state_of", player)["doubt"] as Dictionary).size()
	return n


func _testing(game: PhGame) -> int:
	var n := 0
	for player: PhPlayer in game.players_on(PhGame.HUNTERS):
		n += 0 if (game.bots.call("_state_of", player)["test"] as Dictionary).is_empty() else 1
	return n


func _on_map(id: String) -> void:
	PhSeek.seek_verify = false
	var a := _make_game(id, "script")
	var b := _make_game(id, "native")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(a.get_world_3d() != b.get_world_3d(), "two physics worlds, as two servers would have")
	_start(a)
	_start(b)

	var scans := PhSeek.seek_scans
	var script_scans := 0
	var ticks := 0
	var seek_ticks := 0
	var differ_at := -1
	var doubted := 0
	var tested := 0
	var guard := (int(a.config.hide_seconds) + 10) * TICK_RATE + SEEK_TICKS
	while ticks < guard and seek_ticks < SEEK_TICKS:
		var before := PhSeek.seek_scans
		_step(a, "script")
		script_scans += PhSeek.seek_scans - before
		_step(b, "native")
		ticks += 1
		if a.phase == PhGame.Phase.SEEK:
			seek_ticks += 1
		doubted += _doubting(a)
		tested += _testing(a)
		if differ_at < 0 and _digest(a) != _digest(b):
			differ_at = ticks
			print("  first difference at tick %d (phase %s)" % [ticks, a.phase])
			break
		await get_tree().physics_frame
	var native_scans := PhSeek.seek_scans - scans - script_scans
	_check(script_scans == 0, "the script side never asks the native batch (the fallback)", "%d batches" % script_scans)
	_check(native_scans > seek_ticks / 2, "the native side asked a batch on its seek ticks", "%d batches over %d seek ticks" % [native_scans, seek_ticks])
	_check(differ_at < 0 and seek_ticks >= SEEK_TICKS, "script and native match to the bit every tick (%d ticks, %d seeking; doubt rows %d, tests %d)" % [ticks, seek_ticks, doubted, tested],
		"differ at tick %d, %d seek ticks played" % [differ_at, seek_ticks])
	_check(doubted > 0 and tested > 0, "the hunters doubted and tested (the senses had work)", "doubt %d, tests %d" % [doubted, tested])
	var rays := int(b.bots.get("_seek_table").call(&"rays")) if b.bots.get("_seek_table") != null else 0
	_drop(a)
	_drop(b)
	await get_tree().process_frame

	# Live asks: every native answer against the script's, the script's acted on.
	PhSeek.seek_verify = true
	var mismatches := PhSeek.seek_mismatches
	scans = PhSeek.seek_scans
	var c := _make_game(id, "verify")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_start(c)
	ticks = 0
	seek_ticks = 0
	while ticks < guard and seek_ticks < SEEK_TICKS:
		_step(c, "native")
		ticks += 1
		if c.phase == PhGame.Phase.SEEK:
			seek_ticks += 1
		await get_tree().physics_frame
	PhSeek.seek_verify = false
	_check(PhSeek.seek_mismatches == mismatches and PhSeek.seek_scans > scans,
		"checked against the script beside every answer, none differs (%d batches, %d rays in lockstep)" % [PhSeek.seek_scans - scans, rays],
		"%d differ over %d batches" % [PhSeek.seek_mismatches - mismatches, PhSeek.seek_scans - scans])
	_drop(c)
	await get_tree().process_frame
