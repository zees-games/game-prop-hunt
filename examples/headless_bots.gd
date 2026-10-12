extends Node

const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")
const PhPlayer := preload("../game/ph_player.gd")
const PhBots := preload("../game/ph_bots.gd")

## Stand-ins play whole rounds against each other on the real maps, and the suite measures how
## they hide and how they hunt.
##
## [b]Why rounds, not a unit test.[/b] Christian's first play test: "the bots don't know how to
## play the game at all". Four stand-in props stood in the school's hallway as sinks and bins,
## hopping when they thought they were stuck, and the board said "4 props left" for the whole
## hunt because the stand-in hunter wandered and found nobody. Whether a bot hides well is how
## long it lasts against hunters that search, and whether a hunter hunts well is whether it
## finds props without shooting the furniture to pieces, so this plays rounds (eight
## stand-ins, the game drawing its own hunters, `bot_difficulty medium`) and holds the numbers
## to bands:
##
## - every prop is disguised when the hunters are let go, as something that belongs where it
##   stands (others of its kind round it), and the props are apart;
## - a disguised prop keeps still unless it was shot (seconds moving per prop-minute);
## - at medium a close game: the props win 35-55% of rounds (a hunt that finds everybody is as
##   broken as one that finds nobody), and the hunters find somebody in most; easy leaves the
##   props at least half the rounds, hard at most two in five;
## - the hunters test props more than furniture, and the decoy penalty kills few of them;
## - the board's "props left" is the props alive, after every find;
## - every place a prop may hide is reachable from where the props start (the school's
##   bathrooms once had a toilet in each doorway).
##
## Twenty-four rounds by default, six a map, about four minutes: a band on eight rounds was a
## band on noise. `-- --rounds N` plays another number, `-- --first N` starts
## at the Nth round's map and seed, `-- --difficulty hard` plays another preset, and
## `PH_BOTS_TRACE=1` prints where everybody is every few seconds. Without `maps/` linked it plays
## the practice house.

const MAPS := ["ph_school", "ph_house", "ph_office", "ph_woods"]

const TICK_RATE := 32
const TICK := 1.0 / float(TICK_RATE)
const BOTS := 8

const SECTIONS := 3

## The share of rounds the props win: a band at medium, a floor at easy, a ceiling at hard.
const PROPS_WIN := Vector2(0.35, 0.55)
const EASY_PROPS_WIN := 0.5
const HARD_PROPS_WIN := 0.4

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = 1920
	Engine.max_physics_steps_per_frame = 64
	_run.call_deferred()


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func _run() -> void:
	print("prophunt bots")
	print("")
	var args := OS.get_cmdline_user_args()
	var rounds := maxi(1, int(_arg(args, "--rounds", "24")))
	var difficulty := _arg(args, "--difficulty", "medium")
	var first := maxi(0, int(_arg(args, "--first", "0")))
	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	var results: Array[Dictionary] = []

	_section("%d rounds of stand-ins at %s%s" % [rounds, difficulty, "" if linked else " (no maps/: the practice house)"])
	for r in range(first, first + rounds):
		var map_id: String = MAPS[r % MAPS.size()] if linked else "ph_practice"
		var result := await _round(map_id, r, difficulty)
		results.append(result)
		print("  round %2d %-11s %d hunters: found %d of %d props, mean last %5.1f s, %s; fit %.2f, spread %4.1f m; moving %4.1f s/prop-min; tests %2d props %2d furniture; decoy %5.1f hp, %d hunters killed by it; board %s; reach %d/%d" % [
			r + 1, map_id, result["hunters"], result["found"], result["props"], result["mean_last"],
			"props win" if result["props_won"] else "hunters win", result["fit"], result["spread"], result["moving"],
			result["tests_props"], result["tests_furniture"], result["decoy_hp"], result["decoy_deaths"],
			"ok" if result["board_ok"] else "WRONG", result["reach"], result["places"]])
	_completed += 1

	_section("the bands")
	var props := 0
	var found := 0
	var lasts := 0.0
	var props_won := 0
	var rounds_with_find := 0
	var disguised := 0
	var fit := 0.0
	var spread := 0.0
	var moving := 0.0
	var tests_props := 0
	var tests_furniture := 0
	var decoy_deaths := 0
	var hunters := 0
	var board_ok := true
	for result in results:
		props += int(result["props"])
		found += int(result["found"])
		lasts += float(result["sum_last"])
		disguised += int(result["disguised"])
		fit += float(result["fit"])
		spread += float(result["spread"])
		moving += float(result["moving"])
		tests_props += int(result["tests_props"])
		tests_furniture += int(result["tests_furniture"])
		decoy_deaths += int(result["decoy_deaths"])
		hunters += int(result["hunters"])
		board_ok = board_ok and bool(result["board_ok"])
		if bool(result["props_won"]):
			props_won += 1
		if int(result["found"]) > 0:
			rounds_with_find += 1
	var n := maxf(float(results.size()), 1.0)
	print("  a prop lasts %.1f s on average; %d of %d props found; props won %d of %d rounds; %d with a find; fit %.2f; spread %.1f m; moving %.1f s per prop-minute; tests %d on props, %d on furniture; %d of %d hunters killed by decoys" % [
		lasts / maxf(float(props), 1.0), found, props, props_won, results.size(), rounds_with_find, fit / n, spread / n, moving / n,
		tests_props, tests_furniture, decoy_deaths, hunters])
	_check(disguised == props, "every prop is disguised when the hunters are let go", "%d of %d" % [disguised, props])
	_check(board_ok, "the board's props left is the props alive after every find")
	if difficulty == "medium":
		_check(fit / n >= 0.5, "props hide as what belongs where they stand (others of the kind round them)", "fit %.2f" % (fit / n))
		_check(moving / n <= 3.0, "a disguised prop keeps still unless shot", "%.1f s moving per prop-minute" % (moving / n))
		_check(float(props_won) >= PROPS_WIN.x * n and float(props_won) <= PROPS_WIN.y * n,
			"a close game: the props win %.0f-%.0f%% of rounds" % [PROPS_WIN.x * 100.0, PROPS_WIN.y * 100.0], "props won %d of %d" % [props_won, results.size()])
		_check(rounds_with_find * 2 >= results.size(), "the hunters find somebody in at least half the rounds", "%d of %d" % [rounds_with_find, results.size()])
		_check(tests_furniture <= maxi(tests_props * 3, 4 * results.size()), "the hunters do not shoot the furniture to pieces", "%d furniture tests, %d prop tests" % [tests_furniture, tests_props])
		_check(decoy_deaths * 5 <= hunters, "the decoy penalty kills at most one hunter in five", "%d of %d" % [decoy_deaths, hunters])
	elif difficulty == "easy":
		_check(float(props_won) >= EASY_PROPS_WIN * n, "at easy the props win at least %.0f%% of rounds" % (EASY_PROPS_WIN * 100.0), "props won %d of %d" % [props_won, results.size()])
	elif difficulty == "hard":
		_check(float(props_won) <= HARD_PROPS_WIN * n, "at hard the props win at most %.0f%% of rounds" % (HARD_PROPS_WIN * 100.0), "props won %d of %d" % [props_won, results.size()])
	_completed += 1

	_section("every place a prop may hide is reachable from the props' start")
	var unreachable := 0
	var places := 0
	var worst := ""
	for result in results:
		places += int(result["places"])
		unreachable += int(result["places"]) - int(result["reach"])
		if int(result["places"]) > int(result["reach"]):
			worst += " %s:%d" % [result["map"], int(result["places"]) - int(result["reach"])]
	_check(unreachable * 50 <= places, "at most one place in fifty is cut off (a corner behind furniture)", "%d of %d%s" % [unreachable, places, worst])
	_completed += 1

	print("")
	print("%d sections entered, %d finished" % [_entered, _completed])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	var code := 1 if _failed > 0 else 0
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d of %d sections finished." % [_completed, SECTIONS])
		code = 1
	get_tree().quit(code)


## One round on [param map_id]: eight stand-ins from a fresh world, played to its end.
func _round(map_id: String, index: int, difficulty: String) -> Dictionary:
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])
	config.seed_value = 20261012 + index * 7919

	var game := PhGame.new()
	game.name = "Bots_%d" % index
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	var _set := DotBotSettings.of(game).set_difficulty(difficulty)
	await get_tree().physics_frame

	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true

	var died_at := {}
	var decoy := {"hp": 0.0, "deaths": 0}
	var board := {"ok": true}
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName) -> void:
		if OS.has_environment("PH_BOTS_TRACE"):
			print("    died %s at %.1f s by %s (%s): %s" % [id, game.seek_elapsed, _by, why, (game.bots._state.get(_by, {}) as Dictionary).get("why", "")])
		if game.team_of(id) == PhGame.PROPS:
			died_at[id] = game.seek_elapsed
			# The board reads alive_on: it must drop with every find.
			var alive := 0
			for p in game.players_on(PhGame.PROPS):
				if p.is_alive() and not p.watching:
					alive += 1
			if game.alive_on(PhGame.PROPS) != alive:
				board["ok"] = false
		elif why == PhGame.DIED_DECOY:
			decoy["deaths"] = int(decoy["deaths"]) + 1)
	game.decoy_hit.connect(func(_id: StringName, amount: float) -> void: decoy["hp"] = float(decoy["hp"]) + amount)
	game.start()

	var props: Array[StringName] = []
	var seek_started := -1.0
	var disguised := 0
	var fit := 0.0
	var spread := 0.0
	var moving_ticks := 0
	var prop_ticks := 0
	var hurt := {}
	var reach := 0
	var places := 0
	var trace := OS.has_environment("PH_BOTS_TRACE")
	var limit := int((game.hide_limit() + game.round_limit() + 10.0) * TICK_RATE)
	for tick in range(limit):
		game.simulate(TICK)
		await get_tree().physics_frame
		if seek_started < 0.0 and game.phase == PhGame.Phase.SEEK:
			seek_started = game._now()
			var hidden: Array[PhPlayer] = []
			for p in game.players_on(PhGame.PROPS):
				props.append(p.player_id)
				hidden.append(p)
				if p.is_disguised():
					disguised += 1
					fit += _fit_of(game, p)
			fit /= maxf(float(props.size()), 1.0)
			spread = _spread(hidden)
			var counted := _reachable(game)
			reach = counted[0]
			places = counted[1]
			if trace:
				for p in hidden:
					var st: Dictionary = game.bots._state.get(p.player_id, {})
					print("    %s as %s at %s mode %s fit %.2f" % [p.player_id, p.disguise.prop_id, p.controller.state.position.snapped(Vector3.ONE * 0.1), st.get("mode", ""), _fit_of(game, p)])
		if seek_started >= 0.0 and game.phase != PhGame.Phase.SEEK:
			break
		if seek_started >= 0.0:
			for p in game.players_on(PhGame.PROPS):
				if not p.is_alive() or p.watching:
					continue
				if p.health != null and p.health.health < p.health.max_health - 0.01:
					hurt[p.player_id] = true
				prop_ticks += 1
				var v := p.controller.state.velocity
				if p.is_disguised() and Vector2(v.x, v.z).length() > 0.5 and not hurt.has(p.player_id):
					moving_ticks += 1
		if trace and seek_started >= 0.0 and tick % (TICK_RATE * 4) == 0:
			var line := "    %5.1f s" % game.seek_elapsed
			for id: StringName in game.players:
				var p: PhPlayer = game.players[id]
				var st: Dictionary = game.bots._state.get(id, {})
				line += "  %s%s%s %s" % [id.substr(3), "H" if game.team_of(id) == PhGame.HUNTERS else "p", String(st.get("mode", "")).substr(0, 4),
					str(Vector2(p.controller.state.position.x, p.controller.state.position.z).snapped(Vector2.ONE))]
			print(line)

	var sum_last := 0.0
	var found := 0
	var round_len := game.round_limit()
	for id in props:
		if died_at.has(id):
			found += 1
			sum_last += float(died_at[id])
		else:
			sum_last += round_len
	var bots: PhBots = game.bots
	var result := {
		"map": map_id, "hunters": BOTS - props.size(), "props": props.size(), "found": found, "sum_last": sum_last,
		"mean_last": sum_last / maxf(float(props.size()), 1.0), "props_won": found < props.size(),
		"disguised": disguised, "fit": fit, "spread": spread,
		"moving": float(moving_ticks) / maxf(float(prop_ticks), 1.0) * 60.0,
		"tests_props": bots.tests_on_props, "tests_furniture": bots.tests_on_furniture,
		"decoy_hp": decoy["hp"], "decoy_deaths": decoy["deaths"], "board_ok": board["ok"],
		"reach": reach, "places": places,
	}
	remove_child(game)
	game.free()
	await get_tree().process_frame
	return result


## How well [param p]'s disguise belongs where it stands: others of its kind within 6 m.
static func _fit_of(game: PhGame, p: PhPlayer) -> float:
	if not p.is_disguised():
		return 0.0
	var kin := PhBots._kin_count(game.map.props, p.disguise.prop_id, p.controller.state.position, PhBots.KIN_RADIUS)
	return PhBots.fit({"kin": kin + 1})


## Survey places reachable from the first props' spawn, and how many there are.
static func _reachable(game: PhGame) -> Array:
	var bots: PhBots = game.bots
	if not bots.nav.is_ready():
		return [0, 0]
	var start: Vector3 = (game.map.spawn("props", 0) as Array)[0]
	var from := bots.nav.closest(start)
	var ok := 0
	for spot: Dictionary in bots.spots:
		if bots.nav.path_length(from, spot["at"]) < INF:
			ok += 1
		elif OS.has_environment("PH_BOTS_TRACE"):
			print("    cut off: %s beside %s" % [(spot["at"] as Vector3).snapped(Vector3.ONE * 0.1), spot["kind"]])
	return [ok, bots.spots.size()]


static func _spread(players: Array[PhPlayer]) -> float:
	var total := 0.0
	for a in players:
		var nearest := INF
		for b in players:
			if a != b:
				nearest = minf(nearest, a.controller.state.position.distance_to(b.controller.state.position))
		if nearest < INF:
			total += nearest
	return total / maxf(float(players.size()), 1.0)


func _section(name: String) -> void:
	_entered += 1
	print(name)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return
	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)
