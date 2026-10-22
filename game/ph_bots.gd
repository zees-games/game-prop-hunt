extends RefCounted

const PhPlayer := preload("ph_player.gd")
const PhNavAnnotator := preload("ph_nav_annotator.gd")

## The stand-ins: props that hide as something that belongs where they stand, and hunters that
## search the rooms and test what looks wrong, on dot-bot's settings and hiding helpers.
##
## [b]What the first play test saw[/b] (2026-10-11): "the bots don't know how to play the game
## at all". A bot prop walked to the nearest piece of furniture it could become, became it where
## it stood (four sinks and bins out in the school's hallway, which is where the props start),
## and hopped whenever it thought it was stuck, so the "furniture" slid and jumped about. A bot
## hunter walked from one random prop to another and fired at whatever was nearest now and
## then. The board said "4 props left" for the whole hunt because nobody found anybody.
##
## - [b]The map is surveyed once[/b] when it is built: dot-bot's [DotBotNav] bakes where a body
##   can walk from the walls and the furniture, and [DotBotHiding.survey] scores a place beside
##   each piece of floor furniture a prop may become by how many of the map's sight lines reach
##   it. Each place remembers the piece it is beside: that is the disguise.
## - [b]A prop hides as what belongs there[/b]: a chair beside the classroom's chairs, a bin by
##   the bins. A place counts for more the more of its kind stand round it (a chair among
##   thirty is lost; a sink in a corridor is not), less the more it is seen, apart from the
##   other props, away from the hunters' start, and only if it can walk there before the
##   hunters are let go. It walks the mesh's path as a person, turns to the piece's own facing,
##   becomes it, locks it, and keeps still. Shot, it runs to somewhere out of that hunter's
##   sight and settles again. Before the standing-still clock forces a taunt it moves to
##   another of its kind nearby, if no hunter has been near; now and then it taunts of its own
##   accord when none has been near for a while.
## - [b]A hunter searches[/b] with a [DotBotSearch] over the same places: likely ones first as
##   far as `bot_map_knowledge` goes, near first, never where another hunter is going; a taunt
##   it hears puts the places round it first and sends it there.
## - [b]It tests what looks wrong, and pays for guessing.[/b] Every piece of furniture in view
##   gathers suspicion: a little for nothing (`ph_bot_suspicion`), much for one it remembers
##   was not there (a hunter who knows the map, `bot_map_knowledge`, notices the extra chair),
##   for one alone of its kind, for one tilted, and for one near a taunt it heard. Past a
##   threshold it shoots it for a moment: a prop that bleeds is found and hunted down, real
##   furniture costs the decoy penalty and is crossed off. One test at a time, a few seconds
##   apart, and below 40% health only what it is nearly sure of.
## - [b]Nobody cheats.[/b] A hunter knows a prop only by seeing it move, seeing a face, hitting
##   it, or the game's beacon; what it doubts is what a person who knows the map would doubt.
##
## Pure state per bot, deterministic: every draw is the bot's own [DotRandomStream] and the
## clock is the game's tick, so a seeded round replays the same (`examples/headless_bots`).

const CHANNEL := "ph.bots"

const PROPS := 1
const HUNTERS := 2

## Places surveyed (beside the furniture) and the watchers that score them.
const SURVEY_PLACES := 320

## Most places a map's annotations give the bots, and the score that is the best a spot can have
## (out of sight 2, tucked in 1.5, among its kind 2), which a hunter's weight is measured from.
const NAV_PLACES := 260
const NAV_BEST := 5.5
const WATCHERS := 80

## Metres from a piece's side to where a prop stands beside it.
const BESIDE := 0.45

## Metres within which others of a kind make a place plausible, and how many make it perfect.
const KIN_RADIUS := 6.0
const KIN_FULL := 4

## A hunter's suspicion that starts a test, how long a test fires, and the least gap between two.
const SUSPECT_AT := 1.0
const TEST_SECONDS := 1.1
const TEST_GAP := 4.0

## Metres a hunter weighs furniture within, and the closeness a piece needs to be doubted at all.
const DOUBT_REACH := 12.0

## Metres within which a heard taunt makes a piece suspicious.
const TAUNT_NEAR := 5.0

## The target id a test of real furniture engages: no player has it.
const FURNITURE_TARGET := -7

var game: Node = null

var nav: DotBotNav = DotBotNav.new()

## `[{at, exposure, prop, kind, yaw, kin}]` for the map built, or empty.
var spots: Array[Dictionary] = []

## Survey places as the hunters' search sees them (`[{at, exposure}]`).
var _places: Array[Dictionary] = []

var _surveyed: String = ""
var _baked: String = ""
var _first_survey: String = ""

## The map's annotations (dot-npc-ai), made after the first survey on every map so a suite can
## measure against them; the bots use them only with `bot_nav`. Stepped a few slices a tick.
var annotations: DotNpcAiNavAnnotations = null
var _job: PhNavAnnotator = null
## True once the annotations replaced the first survey's places.
var _nav_places: bool = false
## Slices of the annotator stepped each tick: a fixed number, so a seeded round replays the same.
const SLICES_PER_TICK := 48
var _survey_at: int = 0

## player id -> the bot's own state.
var _state: Dictionary = {}

## Map prop index -> how many others of its kind stand within 3.5 m.
var _kin_near: PackedInt32Array = PackedInt32Array()

## Taunts heard lately: `[{at, by, t}]`.
var _taunts: Array[Dictionary] = []

## How long the last survey took, milliseconds.
var survey_ms: float = 0.0

## Counters for the suite: tests fired at players and at furniture.
var tests_on_props: int = 0
var tests_on_furniture: int = 0


func _init(p_game: Node = null) -> void:
	game = p_game


func settings() -> DotBotSettings:
	return DotBotSettings.of(game)


func config_of() -> Object:
	return game.get("config")


func now() -> float:
	return float(int(game.get("_tick"))) / float(maxi(int(game.get("tick_rate")), 1))


func dt() -> float:
	return 1.0 / float(maxi(int(game.get("tick_rate")), 1))


## A new round: every bot forgets what it was doing.
func reset() -> void:
	_state.clear()
	_taunts.clear()
	tests_on_props = 0
	tests_on_furniture = 0


func forget(player_id: StringName) -> void:
	_state.erase(player_id)


## A taunt was played: every hunter within earshot hears where.
func on_taunted(player_id: StringName) -> void:
	var players: Dictionary = game.get("players")
	if not players.has(player_id):
		return
	var who: PhPlayer = players[player_id]
	_taunts.append({"at": who.controller.state.position, "by": player_id, "t": now()})


# --- The map ------------------------------------------------------------------

## Bakes the map just built, ahead of the round's first tick, so the survey still lands on the
## same tick but the bake is not in it. Only where bots already are.
func prepare_ahead() -> void:
	var map: Node3D = game.get("map")
	if map == null or not bool(game.get("authoritative")):
		return
	var players: Dictionary = game.get("players")
	for id: StringName in players:
		if (players[id] as PhPlayer).is_bot:
			var doc: Dictionary = game.get("map_doc")
			var key := "%s|%d" % [str(doc.get("id", "")), map.get_instance_id()]
			if key != _baked:
				_bake(map, doc, key)
			return


func _bake(map: Node3D, doc: Dictionary, key: String) -> void:
	_baked = key
	spots.clear()
	_places.clear()
	_nav_places = false
	var still: Array = [map.get("_solid"), map.get("_furniture")]
	var baked := nav.bake(map, {"radius": PhPlayer.BODY_RADIUS, "height": PhPlayer.BODY_CROUCH, "climb": PhPlayer.BODY_STEP}, 0, still)
	if not baked.ok:
		_surveyed = key
		DotLog.warn(CHANNEL, "no walkable mesh for the bots; they walk straight", {"map": str(doc.get("id", "")), "why": baked.error.message})
	_survey_at = -1


## The survey comes a quarter second of game time after the first round tick, always the same tick.
func _set_survey_tick() -> void:
	_survey_at = int(game.get("_tick")) + maxi(int(game.get("tick_rate")) / 4, 1)


## Bakes and surveys the map now built, once per map. Only where bots run.
func _prepare() -> void:
	var map: Node3D = game.get("map")
	var doc: Dictionary = game.get("map_doc")
	var key := "%s|%d" % [str(doc.get("id", "")), map.get_instance_id() if map != null else 0]

	if map == null or key == _surveyed:
		return

	if _job != null and key == _first_survey:
		_step_annotator(key)
		return

	if key != _baked:
		_bake(map, doc, key)
		_set_survey_tick()
		return

	if _survey_at < 0:
		_set_survey_tick()
		return

	if int(game.get("_tick")) < _survey_at or not nav.is_ready():
		return

	_first_survey = key
	var started := Time.get_ticks_usec()
	var random: DotRandomManager = game.get("random")
	var stream := random.stream_for(&"bot_survey", hash(str(doc.get("id", ""))) % 65536)
	var catalogue: Object = game.get("props_catalogue")
	var rules: DotPropDisguiseRules = game.get("rules")
	var props: Array = map.get("props")

	# Every piece of floor furniture a prop may become, and a place beside it.
	var usable: Array[int] = []
	for i in range(props.size()):
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		if frame.origin.y > 0.3:
			continue
		if not bool(catalogue.call("may_disguise", prop["id"])) or not DotPropDisguise.may_take(prop["size"], rules).ok:
			continue
		usable.append(i)

	var candidates := PackedVector3Array()
	var owners: Array[int] = []
	var step := maxf(1.0, float(usable.size()) / float(SURVEY_PLACES))
	var k := 0.0
	while int(k) < usable.size():
		var i := usable[int(k)]
		k += step
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		var size: Vector3 = prop["size"]
		var sides := [Vector3(size.x * 0.5 + BESIDE, 0.0, 0.0), Vector3(-size.x * 0.5 - BESIDE, 0.0, 0.0),
			Vector3(0.0, 0.0, size.z * 0.5 + BESIDE), Vector3(0.0, 0.0, -size.z * 0.5 - BESIDE)]
		var first := stream.next_range_i(0, 3)
		for j in range(4):
			var local: Vector3 = sides[(first + j) % 4]
			var beside := frame.origin + frame.basis * local
			beside.y = frame.origin.y
			var on := nav.closest(beside)
			if Vector2(on.x - beside.x, on.z - beside.z).length() < 0.35 and absf(on.y - beside.y) < 0.5:
				candidates.append(on)
				owners.append(i)
				break

	var watchers := PackedVector3Array()
	for _i in range(WATCHERS):
		watchers.append(nav.random_point(stream) + Vector3(0.0, PhPlayer.EYE_HEIGHT, 0.0))

	_kin_near.resize(props.size())
	for i in range(props.size()):
		_kin_near[i] = _kin_count(props, props[i]["id"], (props[i]["transform"] as Transform3D).origin) - 1

	var surveyed := DotBotHiding.survey(candidates, watchers, _los, DotBotHiding.REACH, 0.5)
	for n in range(surveyed.size()):
		var prop: Dictionary = props[owners[n]]
		var frame: Transform3D = prop["transform"]
		var kin := 0
		for other: Dictionary in props:
			if other["id"] == prop["id"] and (other["transform"] as Transform3D).origin.distance_to(frame.origin) < KIN_RADIUS:
				kin += 1
		var spot := surveyed[n]
		spot["prop"] = owners[n]
		spot["kind"] = prop["id"]
		spot["yaw"] = rad_to_deg(frame.basis.get_euler(EULER_ORDER_YXZ).y)
		spot["kin"] = kin
		spots.append(spot)
		_places.append({"at": spot["at"], "exposure": spot["exposure"]})

	survey_ms = (Time.get_ticks_usec() - started) / 1000.0 + nav.bake_ms
	DotLog.debug(CHANNEL, "surveyed the map for the bots", {
		"map": str(doc.get("id", "")), "spots": spots.size(), "nav_ms": snappedf(nav.bake_ms, 0.1), "ms": snappedf(survey_ms, 0.1),
	})
	_start_annotator(map, props, usable, catalogue)


## Sets the annotator going over the baked mesh, told which pieces of furniture a prop may be.
func _start_annotator(map: Node3D, props: Array, usable: Array[int], _catalogue: Object) -> void:
	_job = null
	annotations = null
	if not nav.is_ready() or nav.mesh == null:
		_surveyed = _first_survey
		return
	var job := PhNavAnnotator.new(nav.mesh, map.get_world_3d())
	job.agent_radius = PhPlayer.BODY_RADIUS
	job.crouch_height = PhPlayer.BODY_CROUCH
	job.climb = PhPlayer.BODY_STEP
	job.beside = float(config_of().get("bot_beside"))
	job.kin_radius = KIN_RADIUS
	job.kin_full = KIN_FULL
	job.los_fn = _los
	var physics: Object = game.get("physics")
	job.collision_mask = (int(physics.call("layer_mask", &"world")) | int(physics.call("layer_mask", &"prop"))) if physics != null else 1
	var seeds := PackedVector3Array()
	for side in ["props", "hunters"]:
		for i in range(2):
			var spawn: Array = map.call("spawn", side, i)
			seeds.append(spawn[0])
	job.seeds = seeds
	var piece_list: Array[Dictionary] = []
	for i in usable:
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		piece_list.append({
			"i": i, "frame": frame, "size": prop["size"], "kind": prop["id"],
			"kin": _kin_count(props, prop["id"], frame.origin, KIN_RADIUS),
			"yaw": rad_to_deg(frame.basis.get_euler(EULER_ORDER_YXZ).y),
		})
	job.pieces = piece_list
	job.index_pieces()
	job.random_seed = hash(str((game.get("map_doc") as Dictionary).get("id", ""))) % 65536 + 1
	_job = job
	_annotate_ms = 0.0


var _annotate_ms: float = 0.0


func _step_annotator(key: String) -> void:
	var started := Time.get_ticks_usec()
	for _i in range(SLICES_PER_TICK):
		if not _job.step():
			break
	_annotate_ms += (Time.get_ticks_usec() - started) / 1000.0
	if not _job.is_settled():
		return
	var job := _job
	_job = null
	_surveyed = key
	if job.result == null or not job.result.ok:
		DotLog.warn(CHANNEL, "the map's annotations failed; the bots use the first survey", {"why": job.result.error.message if job.result != null else "no result"})
		return
	annotations = job.result.value
	DotLog.debug(CHANNEL, "annotated the map for the bots", {"ms": snappedf(_annotate_ms, 0.1), "spots": annotations.spots.size(), "hiding": annotations.hiding.size(), "chokepoints": annotations.chokepoints.size()})
	if bool(config_of().get("bot_nav")):
		_adopt_annotations(job)


## Hiding places for the props and search places for the hunters, from the annotations: the
## spots beside a piece a prop may be, best first, apart; and those, with the chokepoints.
func _adopt_annotations(job: PhNavAnnotator) -> void:
	var ranked: Array[Dictionary] = []
	for spot in annotations.spots:
		if int(spot.get("prop", -1)) >= 0:
			ranked.append(spot)
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	var chosen: Array[Dictionary] = []
	var apart := job.spot_spacing
	for spot in ranked:
		var at: Vector3 = spot["at"]
		var crowded := false
		for other in chosen:
			if (other["at"] as Vector3).distance_to(at) < apart:
				crowded = true
				break
		if crowded:
			continue
		chosen.append(spot)
		if chosen.size() >= NAV_PLACES:
			break
	if chosen.size() < 8:
		# A map with almost no furniture beside its walls: the first survey still stands.
		DotLog.debug(CHANNEL, "too few annotated places; the bots use the first survey", {"places": chosen.size()})
		return
	spots = chosen
	_nav_places = true
	if float(config_of().get("bot_sweep")) <= 0.0:
		# No sweeping: the hunters keep the first survey's places and only the props use the spots.
		return
	_places.clear()
	for spot in chosen:
		_places.append({"at": spot["at"], "exposure": 1.0 - clampf(float(spot["score"]) / NAV_BEST, 0.0, 1.0), "q": clampf((float(spot["score"]) / NAV_BEST - 0.3) / 0.6, 0.0, 1.0)})
	for choke in annotations.chokepoints:
		# Where routes cross: not where a prop hides, but where a hunter sees down the way, so
		# visited, and after the places that are likelier.
		_places.append({"at": choke["at"], "exposure": 0.6, "q": 0.35})


func _los(a: Vector3, b: Vector3) -> bool:
	return bool(game.call("_clear_between", a, b, true))


## How plausible a place is for its disguise, 0..1: how many of its kind stand round it.
static func _kin_count(props: Array, kind: StringName, at: Vector3, within: float = 3.5) -> int:
	var count := 0
	for other: Dictionary in props:
		if other["id"] == kind and (other["transform"] as Transform3D).origin.distance_to(at) < within:
			count += 1
	return count


static func fit(spot: Dictionary) -> float:
	return clampf(float(int(spot.get("kin", 1)) - 1) / float(KIN_FULL - 1), 0.0, 1.0)


# --- Every tick -----------------------------------------------------------------

## What every stand-in presses this tick. Called by the game before the bodies move.
func drive() -> void:
	var players: Dictionary = game.get("players")
	var any := false

	for id: StringName in players:
		if (players[id] as PhPlayer).is_bot:
			any = true
			break

	if not any:
		return

	var phase: int = game.get("phase")

	if phase != 0:
		_prepare()

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.watching:
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch
		aim_of(player).view_from(command.yaw, command.pitch)

		var side: int = game.call("team_of", id)

		if phase == 0:
			pass
		elif side == PROPS:
			_hide(player, command)
		elif phase == 2:
			_seek(player, command)

		player.controller.apply_command(command)

	var t := now()
	for i in range(_taunts.size() - 1, -1, -1):
		if t - float(_taunts[i]["t"]) > 12.0:
			_taunts.remove_at(i)


func _state_of(player: PhPlayer) -> Dictionary:
	if not _state.has(player.player_id):
		var seed := hash(String(player.player_id))
		_state[player.player_id] = {
			"aim": DotBotAim.new(seed, settings()),
			"stream": DotRandomStream.new(seed, &"ph_bot"),
			"goal": Vector3.INF, "path": PackedVector3Array(), "corner": 0, "path_at": -INF,
			"mode": &"", "stuck": [player.controller.state.position, now()],
			"spot": {}, "bad": [], "sprint": false,
			"search": null, "doubt": {}, "test": {}, "tested_at": -INF, "cleared": {},
			"prey": StringName(), "prey_seen_at": -INF, "prey_at": Vector3.INF,
			"hunter_seen_at": -INF, "hunter_at": Vector3.INF,
		}
	return _state[player.player_id]


func aim_of(player: PhPlayer) -> DotBotAim:
	return _state_of(player)["aim"]


# --- Hiding ---------------------------------------------------------------------

func _hide(player: PhPlayer, command: DotFpsCommand) -> void:
	var state := _state_of(player)
	var t := now()
	var phase: int = game.get("phase")
	var at := player.controller.state.position


	if (state["spot"] as Dictionary).is_empty():
		if spots.is_empty() or t < float(state.get("retry_at", -INF)):
			# Nothing surveyed (no mesh): the old way, something near, so a prop is never a
			# person in the open when the hunters come.
			if spots.is_empty() and _surveyed == _baked and phase == 2 and not player.is_disguised():
				_become_nearest(player)
			return
		_pick_spot(player, state)
		if (state["spot"] as Dictionary).is_empty():
			return

	if phase == 2:
		_watch_for_hunters(player, state)

	var spot: Dictionary = state["spot"]

	# Early: a person in the open is the thing a hunter would be glad of, so put the piece on
	# once the delay has passed and walk the rest of the way as it. Once only: a refusal (no
	# room here for the bigger hull) is tried again on arriving.
	if phase == 1 and not player.is_disguised() and not state.has("early") \
			and float(game.get("phase_elapsed")) >= float(config_of().get("bot_disguise_delay")):
		state["early"] = true
		var _early: bool = _become(player, spot)

	# Late: the hunters are out and it is still a person. Become the thing now and keep going;
	# a moving chair is a risk, a person is certain death.
	if phase == 2 and not player.is_disguised():
		var _worn := _become(player, spot)

	if state["mode"] == &"hidden":
		command.move = Vector2.ZERO
		if phase == 2:
			_hidden_tick(player, state, command)
		return

	var arrived := _walk_to(player, command, state, spot["at"], bool(state["sprint"]))

	if not arrived:
		return

	command.move = Vector2.ZERO
	state["sprint"] = false

	# Face the way the piece faces, then become it and lock it there.
	if not player.is_disguised() or (player.disguise.prop_id != StringName(spot["kind"])):
		if not _become(player, spot):
			var bad: Array = state["bad"]
			bad.append(int(spot["prop"]))
			state["spot"] = {}
			return
	_settle(player, spot)
	state["mode"] = &"hidden"
	state["settled_at"] = t


## Wears [param spot]'s piece, facing as the piece faces. False when the game refuses.
func _become(player: PhPlayer, spot: Dictionary) -> bool:
	player.controller.state.yaw = float(spot["yaw"])
	return bool(game.call("disguise_as", player.player_id, StringName(spot["kind"])))


## Locks the prop at the piece's facing, upright.
func _settle(player: PhPlayer, spot: Dictionary) -> void:
	if not player.is_disguised():
		return
	var d := player.disguise
	if d.pitch != 0.0 or d.roll != 0.0:
		var _straight: bool = game.call("turn", player.player_id, 5)
	if d.locked:
		var _unlocked: bool = game.call("turn", player.player_id, 0)
	player.controller.state.yaw = float(spot["yaw"])
	var _locked: bool = game.call("turn", player.player_id, 0)


## No mesh to survey: becomes the nearest piece it may.
func _become_nearest(player: PhPlayer) -> void:
	var map: Node3D = game.get("map")
	var catalogue: Object = game.get("props_catalogue")
	var rules: DotPropDisguiseRules = game.get("rules")
	var at := player.controller.state.position
	var best: StringName = &""
	var best_d := INF
	for prop: Dictionary in (map.get("props") as Array):
		var d := at.distance_to((prop["transform"] as Transform3D).origin)
		if d < best_d and bool(catalogue.call("may_disguise", prop["id"])) and DotPropDisguise.may_take(prop["size"], rules).ok:
			best_d = d
			best = prop["id"]
	if best != &"":
		var _worn: bool = game.call("disguise_as", player.player_id, best)


## A place: plausible for its piece, little seen, apart from the others, away from the hunters'
## start, reachable before they are let go. [param near] limits it to places within so many
## metres of [param from] (a move before a forced taunt), [param kind] to one disguise.
func _pick_spot(player: PhPlayer, state: Dictionary, near: float = INF, kind: StringName = &"") -> void:
	var at := player.controller.state.position
	var taken := PackedVector3Array()
	for id: StringName in _state:
		if id == player.player_id:
			continue
		var other: Dictionary = (_state[id] as Dictionary).get("spot", {})
		if not other.is_empty():
			taken.append(other["at"])

	var threats := PackedVector3Array()
	var map: Node3D = game.get("map")
	for i in range(2):
		var spawn: Array = map.call("spawn", "hunters", i)
		threats.append(spawn[0])

	var bad: Array = state["bad"]
	var pool: Array = []
	# Annotated: at first only where the piece has company (three or more of its kind round it)
	# and the place is tucked in; a move to somewhere near, or a map without such places, takes
	# what there is.
	var snug := _nav_places and near == INF
	for attempt in range(2):
		for spot: Dictionary in spots:
			if snug and (int(spot["kin"]) < 3 or float(spot["enclosure"]) < 0.25):
				continue
			if bad.has(int(spot["prop"])):
				continue
			if near < INF:
				var d := (spot["at"] as Vector3).distance_to(at)
				if d > near or d < 2.0:
					continue
			if kind != &"" and StringName(spot["kind"]) != kind:
				continue
			# What dot-bot's choose weighs as exposure: how much the place is seen, and how out
			# of place its piece would be there; an annotated place is also judged by how tucked
			# in it is (a chair in a corner, not mid-floor).
			var scored := spot.duplicate()
			if spot.has("enclosure"):
				scored["exposure"] = float(spot["exposure"]) * 0.3 + (1.0 - fit(spot)) * 0.3 + (1.0 - float(spot["enclosure"])) * 0.4
			else:
				scored["exposure"] = float(spot["exposure"]) * 0.5 + (1.0 - fit(spot)) * 0.5
			pool.append(scored)
		if pool.size() >= 6 or not snug:
			break
		snug = false
		pool.clear()

	if pool.is_empty():
		state["retry_at"] = now() + 1.0
		return

	var phase: int = game.get("phase")
	var left: float = float(game.call("seconds_left")) if phase == 1 else 20.0
	var speed := player.controller.tunables.max_speed
	var start := nav.closest(at) if nav.is_ready() else at
	var reachable := func(spot_at: Vector3) -> bool:
		var length := nav.path_length(start, spot_at) if nav.is_ready() else at.distance_to(spot_at)
		return length < maxf(left - 3.0, 6.0) * speed * 0.85

	var stream: DotRandomStream = state["stream"]
	# With annotations it looks hard at the best of them: the pool is already scored for being
	# tucked in, out of sight and among its kind, so a bot that knows the map takes the top few.
	var skill := settings().profile.map_knowledge
	var chosen := DotBotHiding.choose(pool, at, threats if near == INF else PackedVector3Array(), taken, stream,
		skill, reachable)
	if chosen.is_empty() and int(state.get("retries", 0)) >= 3:
		chosen = DotBotHiding.choose(pool, at, threats, taken, stream, settings().profile.map_knowledge)
	state["retries"] = int(state.get("retries", 0)) + 1

	if chosen.is_empty():
		state["retry_at"] = now() + 1.0
		return

	state["spot"] = chosen
	state["mode"] = &"going"
	state["path"] = PackedVector3Array()


## A hidden prop during the seek: keeps still; moves only when shot, or before a forced taunt
## with no hunter near; taunts now and then of its own accord.
func _hidden_tick(player: PhPlayer, state: Dictionary, command: DotFpsCommand) -> void:
	var t := now()
	var at := player.controller.state.position
	var profile := settings().profile

	# Look about, as a person in a chair would, toward wherever a hunter was last seen.
	var watched: Vector3 = state["hunter_at"]
	if watched != Vector3.INF and t - float(state["hunter_seen_at"]) < profile.memory + 4.0:
		_look(player, command, watched + Vector3(0.0, 1.2, 0.0))

	# Shot: run, out of that hunter's sight, at a sprint. Hurt is health lost under the same
	# disguise: a new one changes the maximum and carries the share across, which is no shot
	# (the first measured rounds had every prop "fleeing" the moment it put a chair on).
	var health := player.health.health if player.health != null else 0.0
	var top := player.health.max_health if player.health != null else 0.0
	var was: Vector2 = state.get("hp", Vector2(-1.0, -1.0))
	state["hp"] = Vector2(health, top)
	if was.y == top and health < was.x - 0.01:
		var threat: Vector3 = state["hunter_at"] if state["hunter_at"] != Vector3.INF else at + Vector3(0.0, 0.0, 1.0)
		var taken := PackedVector3Array()
		var away := DotBotHiding.flee_spot(spots, at, threat, threat + Vector3(0.0, PhPlayer.EYE_HEIGHT, 0.0), _los, taken, 25.0, 7.0, 0.5)
		if away.is_empty():
			var dir := Vector3(at.x - threat.x, 0.0, at.z - threat.z).normalized()
			away = {"at": nav.closest(at + dir * 8.0), "prop": -1, "kind": player.disguise.prop_id, "yaw": player.controller.state.yaw, "kin": 1}
		state["spot"] = away
		state["mode"] = &"fleeing"
		state["sprint"] = true
		state["path"] = PackedVector3Array()
		return

	# Before the game's standing-still clock forces a taunt (a shout every hunter walks to):
	# another place close by, of its kind if there is one, when no hunter is in sight now.
	# With a hunter watching, keeping still and taking the taunt is the lesser risk.
	var watched_now := t - float(state["hunter_seen_at"]) < 3.0
	var taunts: DotPropTaunts = game.get("taunts")
	var meter := taunts.meter(player.player_id, t) if taunts != null else 0.0
	var stream: DotRandomStream = state["stream"]
	var cfg := config_of()
	var every := float(cfg.get("bot_relocate_seconds"))
	# Now and then, with no hunter seen for a good while (one far off), a prop of a kind that
	# is plentiful here changes its place: a person who never moves is a prop that is found.
	var restless := every > 0.0 and t - float(state["hunter_seen_at"]) > 8.0 \
			and stream.next_unit() < dt() / every
	if (meter > 0.8 or restless) and not watched_now and t - float(state.get("shuffled_at", -INF)) > 4.0:
		state["shuffled_at"] = t
		var keep: Dictionary = state["spot"]
		var reach := float(cfg.get("bot_relocate_range"))
		state["spot"] = {}
		_pick_spot(player, state, reach, player.disguise.prop_id)
		if (state["spot"] as Dictionary).is_empty():
			_pick_spot(player, state, reach)
		if (state["spot"] as Dictionary).is_empty():
			state["spot"] = keep
			state["mode"] = &"hidden"
		return

	# Now and then (about once in four minutes) a taunt of its own, for the points, when no
	# hunter has been near for half a minute: a taunt is a shout every hunter walks to.
	if stream.next_unit() < dt() / 240.0 and t - float(state["hunter_seen_at"]) > 30.0:
		var _taunted: bool = game.call("taunt", player.player_id)


## Remembers where a hunter it can see is.
func _watch_for_hunters(player: PhPlayer, state: Dictionary) -> void:
	if int(game.get("_tick")) % 4 != 0:
		return
	var profile := settings().profile
	var eye := player.eye_position()
	for other in (game.call("players_on", HUNTERS) as Array):
		var hunter := other as PhPlayer
		if not hunter.is_alive() or hunter.watching:
			continue
		var head := hunter.eye_position()
		if eye.distance_to(head) < profile.sight and _los(eye, head):
			state["hunter_seen_at"] = now()
			state["hunter_at"] = hunter.controller.state.position
			return


# --- Hunting ----------------------------------------------------------------------

func _seek(player: PhPlayer, command: DotFpsCommand) -> void:
	var state := _state_of(player)
	var t := now()
	var profile := settings().profile
	var at := player.controller.state.position
	var stream: DotRandomStream = state["stream"]
	var aim := aim_of(player)

	if state["search"] == null:
		var search := DotBotSearch.new()
		var sweep := float(config_of().get("bot_sweep")) if _nav_places else 0.0
		search.setup(_places, maxf(profile.map_knowledge, sweep))
		if _nav_places:
			# Weight the places the annotations call good (a snug spot, a chokepoint), so a hunter
			# looks at the best hiding places before the near ones: sweeping, not wandering.
			for n in range(mini(search.places.size(), _places.size())):
				var q: float = float(_places[n].get("q", 0.0))
				search.places[n]["weight"] = lerpf(1.0, 0.1 + 3.5 * q * q, sweep)
		state["search"] = search
	var search: DotBotSearch = state["search"]

	var careful := player.health != null and player.health.health < player.health.max_health * 0.4

	# A prop seen moving, showing its face, beaconed, or one a test found: shoot it.
	var prey := _prey(player, state)
	if prey != null:
		var eye := player.eye_position()
		var middle := prey.controller.state.position + Vector3(0.0, minf(prey.hull_height(), 1.4) * 0.5, 0.0)
		if state["prey"] != prey.player_id:
			state["why"] = "prey %s marked %s face %s moving %.1f" % [prey.player_id, prey.marked, not prey.is_disguised(), Vector2(prey.controller.state.velocity.x, prey.controller.state.velocity.z).length()]
		state["prey"] = prey.player_id
		state["prey_seen_at"] = t
		state["prey_at"] = prey.controller.state.position
		var fire: bool = shoot(player, command, prey.entity_id, middle, prey.controller.state.velocity)
		command.set_button(DotFpsCommand.BUTTON_USER_0, fire)
		var d := at.distance_to(prey.controller.state.position)
		if d > 5.0:
			var _close := _walk_to(player, command, state, prey.controller.state.position, d > 10.0, false)
		state["test"] = {}
		return

	# Lost it: to where it was, and look round there.
	if state["prey"] != StringName() and t - float(state["prey_seen_at"]) < profile.memory + 2.0:
		aim.release()
		var where: Vector3 = state["prey_at"]
		if _walk_to(player, command, state, where, true):
			search.heard(where, t, 8.0)
			state["prey"] = StringName()
		return
	state["prey"] = StringName()

	# A test under way: keep firing at the piece for its moment.
	var test: Dictionary = state["test"]
	if not test.is_empty():
		if t - float(test["since"]) < TEST_SECONDS and not (careful and float(test["odd"]) < 1.0):
			command.move = Vector2.ZERO
			var point: Vector3 = test["at"]
			var target := _player_by_id(test.get("player", StringName()))
			if target != null:
				point = target.controller.state.position + Vector3(0.0, minf(target.hull_height(), 1.4) * 0.5, 0.0)
				# Bleeding: found.
				if target.health != null and target.health.health < float(test["health"]) - 0.01:
					state["found"] = target.player_id
					state["found_at"] = t
			var fire: bool = shoot(player, command, int(test["id"]), point, Vector3.ZERO)
			command.set_button(DotFpsCommand.BUTTON_USER_0, fire)
			return
		var cleared: Dictionary = state["cleared"]
		cleared[test["key"]] = t
		state["test"] = {}
		state["tested_at"] = t
		aim.forget()

	# Heard a taunt: the places round it first, and go.
	for heard: Dictionary in _taunts:
		if heard.get("heard_by_" + String(player.player_id), false):
			continue
		heard["heard_by_" + String(player.player_id)] = true
		var where: Vector3 = heard["at"]
		var d := at.distance_to(where)
		if d > float(game.get("config").get("taunt_range")):
			continue
		var vague := where + Vector3(stream.next_range_f(-1.0, 1.0), 0.0, stream.next_range_f(-1.0, 1.0)) * minf(d * 0.12, 4.0)
		search.heard(vague, t, 6.0)
		state["goal_place"] = {"at": nav.closest(vague) if nav.is_ready() else vague, "since": t, "picked_at": t}
		state["path"] = PackedVector3Array()

	# Doubt what is in view; test the most doubtful once it is doubtful enough.
	if int(game.get("_tick")) % 4 == 0:
		var _crossed := search.observe(player.eye_position(), player.aim_direction(), profile.fov, profile.sight, _los, t, 0.5)
		_doubt(player, state, careful)
		if t - float(state["tested_at"]) > TEST_GAP:
			var started := _start_test(player, state, careful)
			if started:
				return

	# Search: the next likely place.
	var place: Dictionary = state.get("goal_place", {})
	if place.is_empty() or at.distance_to(place["at"]) < 1.2 or t - float(place.get("since", t)) > 25.0 \
			or float(place.get("seen_at", -INF)) > float(place.get("picked_at", -INF)):
		var claimed := PackedVector3Array()
		for id: StringName in _state:
			if id != player.player_id:
				var theirs: Dictionary = (_state[id] as Dictionary).get("goal_place", {})
				if not theirs.is_empty():
					claimed.append(theirs["at"])
		var distance := func(a: Vector3, b: Vector3) -> float: return nav.path_length(a, b) if nav.is_ready() else a.distance_to(b)
		place = search.next(at, t, claimed, stream, distance)
		if place.is_empty():
			search.recheck = 30.0
			place = search.next(at, t, claimed, stream, distance)
		if place.is_empty():
			place = {"at": nav.random_point(stream) if nav.is_ready() else at}
		place["since"] = t
		place["picked_at"] = t
		state["goal_place"] = place
		state["path"] = PackedVector3Array()

	var _there := _walk_to(player, command, state, place["at"], false)

	var target_at: Vector3 = place["at"]
	if at.distance_to(target_at) < search.look_reach:
		_look(player, command, target_at + Vector3(0.0, 0.5, 0.0))
	else:
		var ahead := _next_corner(state, at)
		var sweep := sin(t * 1.3 + float(player.entity_id % 7)) * 40.0
		var dir := Vector3(ahead.x - at.x, 0.0, ahead.z - at.z)
		if dir.length() > 0.1:
			dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(sweep))
			_look(player, command, player.eye_position() + dir * 5.0 + Vector3(0.0, -0.8, 0.0))


func _player_by_id(id: StringName) -> PhPlayer:
	var players: Dictionary = game.get("players")
	return players.get(id) if id != StringName() else null


## The prop this hunter knows is a prop and can see: one moving, one showing a face, one the
## beacon gives away, or one a test drew blood from.
func _prey(player: PhPlayer, state: Dictionary) -> PhPlayer:
	var profile := settings().profile
	var eye := player.eye_position()
	var forward := player.aim_direction()
	var best: PhPlayer = null
	var best_d := INF
	var found: StringName = state.get("found", StringName())

	for other in (game.call("players_on", PROPS) as Array):
		var prop := other as PhPlayer
		if not prop.is_alive() or prop.watching:
			continue
		var middle := prop.controller.state.position + Vector3(0.0, minf(prop.hull_height(), 1.4) * 0.5, 0.0)
		var d := eye.distance_to(middle)
		var v := prop.controller.state.velocity
		var moving := Vector2(v.x, v.z).length() > 1.0
		var known := prop.marked or not prop.is_disguised() or moving \
			or (prop.player_id == found and now() - float(state.get("found_at", -INF)) < profile.memory + 4.0)
		if not known:
			continue
		# Seen with its own eyes: a moving chair across the hall is a chair at 25 m; past that
		# it does not read as moving.
		var sight := minf(profile.sight, 25.0) if not prop.marked else profile.sight
		if d > sight or d >= best_d:
			continue
		if not prop.marked and d > 2.0 and rad_to_deg(forward.angle_to(middle - eye)) > profile.fov * 0.5:
			continue
		if not _los(eye, middle):
			continue
		best = prop
		best_d = d
	return best


## Suspicion of everything in view: real furniture and props alike, as a person who knows the
## map so well and heard what they heard would weigh it.
func _doubt(player: PhPlayer, state: Dictionary, careful: bool) -> void:
	var profile := settings().profile
	var config: Object = game.get("config")
	var base := float(config.get("bot_suspicion")) / 100.0
	var eye := player.eye_position()
	var forward := player.aim_direction()
	var doubt: Dictionary = state["doubt"]
	var cleared: Dictionary = state["cleared"]
	var map: Node3D = game.get("map")
	var props: Array = map.get("props")
	var step := 4.0 * dt()
	var t := now()

	# Doubt fades for what is out of view.
	for key: Variant in doubt.keys():
		doubt[key] = maxf(float(doubt[key]) - step * 0.15, 0.0)

	var seen: Array = []

	# The map's own pieces, near and in view.
	for i in range(props.size()):
		var prop: Dictionary = props[i]
		if bool(prop.get("broken", false)):
			continue
		var frame: Transform3D = prop["transform"]
		var middle := frame.origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
		if absf(middle.x - eye.x) > DOUBT_REACH or absf(middle.z - eye.z) > DOUBT_REACH:
			continue
		seen.append([i, StringName(), middle, prop["id"], frame.origin, false])

	# The props, still and disguised (a moving one is prey, not a doubt).
	for other in (game.call("players_on", PROPS) as Array):
		var prop := other as PhPlayer
		if not prop.is_alive() or prop.watching or not prop.is_disguised():
			continue
		var at := prop.controller.state.position
		if absf(at.x - eye.x) > DOUBT_REACH or absf(at.z - eye.z) > DOUBT_REACH:
			continue
		var tilted := absf(prop.disguise.pitch) > 1.0 or absf(prop.disguise.roll) > 1.0
		seen.append([-1, prop.player_id, at + Vector3(0.0, prop.hull_height() * 0.5, 0.0), prop.disguise.prop_id, at, tilted])

	for row: Array in seen:
		var middle: Vector3 = row[2]
		var d := eye.distance_to(middle)
		if d > DOUBT_REACH or d < 0.5:
			continue
		if rad_to_deg(forward.angle_to(middle - eye)) > profile.fov * 0.5:
			continue
		var key: String = ("p%d" % int(row[0])) if int(row[0]) >= 0 else ("u" + String(row[1]))
		# Real furniture tested is crossed off for the round; a prop that did not bleed (a miss)
		# is believed for twenty seconds.
		if cleared.has(key) and (key.begins_with("p") or t - float(cleared[key]) < 20.0):
			continue
		if not _los(eye, middle):
			continue
		var odd := _oddness(player, row, props, base, t)
		var closeness := clampf(1.0 - d / DOUBT_REACH, 0.0, 1.0)
		doubt[key] = float(doubt.get(key, 0.0)) + step * odd * (0.5 + closeness) * (0.6 + profile.aggression * 0.8)
		if careful and odd < 1.0:
			doubt[key] = minf(float(doubt[key]), SUSPECT_AT * 0.9)


## How wrong [param row] looks to [param player]: [index, player id, middle, kind, feet, tilted].
func _oddness(player: PhPlayer, row: Array, props: Array, base: float, t: float) -> float:
	var profile := settings().profile
	var index := int(row[0])
	var kind: StringName = row[3]
	var feet: Vector3 = row[4]
	var odd := base

	# Alone of its kind: a sink in a corridor, a chair with no table.
	var kin := _kin_near[index] if index >= 0 and index < _kin_near.size() else _kin_count(props, kind, feet)
	if kin == 0:
		odd += 0.35

	# Remembered: a hunter who knows the map knows this one was there (real) or was not (a
	# prop). Drawn once per hunter and piece from the hunter's own seed, so it holds all round.
	# The more of its kind round it the harder: a third sink is noticed, a thirty-first chair
	# is not.
	var memory := _memory_draw(player, row)
	if memory < profile.map_knowledge / (1.0 + float(kin) * 0.6):
		if index >= 0:
			odd *= 0.15
		else:
			odd += 1.2

	if bool(row[5]):
		odd += 0.5

	for heard: Dictionary in _taunts:
		if t - float(heard["t"]) < 10.0 and (heard["at"] as Vector3).distance_to(feet) < TAUNT_NEAR:
			odd += 1.4
			break
	return odd


func _memory_draw(player: PhPlayer, row: Array) -> float:
	var key := "%s|%d|%s|%d" % [String(player.player_id), int(row[0]), String(row[1]), int(game.get("round_number"))]
	return float(hash(key) & 0xFFFF) / 65535.0


## Starts shooting the most doubted thing in view, if it is doubted enough.
func _start_test(player: PhPlayer, state: Dictionary, careful: bool) -> bool:
	var doubt: Dictionary = state["doubt"]
	var best_key := ""
	var best := SUSPECT_AT
	for key: String in doubt:
		if float(doubt[key]) >= best:
			best = float(doubt[key])
			best_key = key
	if best_key == "":
		return false

	var test := {"key": best_key, "since": now(), "odd": best}
	if best_key.begins_with("u"):
		var target := _player_by_id(StringName(best_key.substr(1)))
		if target == null or not target.is_alive():
			doubt.erase(best_key)
			return false
		test["player"] = target.player_id
		test["id"] = target.entity_id
		test["health"] = target.health.health if target.health != null else 0.0
		test["at"] = target.controller.state.position + Vector3(0.0, target.hull_height() * 0.5, 0.0)
	else:
		var map: Node3D = game.get("map")
		var prop: Dictionary = (map.get("props") as Array)[int(best_key.substr(1))]
		test["id"] = FURNITURE_TARGET
		test["at"] = (prop["transform"] as Transform3D).origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
	if careful and best < SUSPECT_AT * 1.5:
		return false
	state["why"] = "test %s odd %.2f" % [best_key, best]
	if test.has("player"):
		tests_on_props += 1
	else:
		tests_on_furniture += 1
	doubt.erase(best_key)
	state["test"] = test
	return true


## Aims at [param at] (target [param id]) and says whether to fire this tick: dot-bot's
## [DotBotAim], so the view turns at `bot_turn_rate`, the first shots miss by `bot_aim_error`
## and settle, and the trigger waits `bot_reaction` after first sight.
func shoot(player: PhPlayer, command: DotFpsCommand, id: int, at: Vector3, velocity: Vector3) -> bool:
	var aim := aim_of(player)
	var eye := player.eye_position()
	var t := now()
	var _new := aim.engage(id, eye, at, t)
	var view := aim.track(eye, at, velocity, t, dt())
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)
	var fire := aim.trigger(t, eye.distance_to(at))
	if fire:
		aim.note_shot(eye, at, t)
	return fire


# --- Moving -------------------------------------------------------------------------

## Walks [param player] along the mesh to [param goal]. Returns true when there.
func _walk_to(player: PhPlayer, command: DotFpsCommand, state: Dictionary, goal: Vector3, sprint: bool, look: bool = true) -> bool:
	var at := player.controller.state.position
	var flat := Vector2(goal.x - at.x, goal.z - at.z).length()

	if flat < 0.45 and absf(goal.y - at.y) < 1.2:
		state["path"] = PackedVector3Array()
		return true

	var t := now()
	var path: PackedVector3Array = state["path"]
	if path.is_empty() or (state["goal"] as Vector3).distance_to(goal) > 1.0 or t - float(state["path_at"]) > 3.0:
		path = nav.path(at, goal) if nav.is_ready() else PackedVector3Array()
		if path.size() < 2:
			path = PackedVector3Array([at, goal])
		state["path"] = path
		state["corner"] = 1
		state["goal"] = goal
		state["path_at"] = t

	var corner := _next_corner(state, at)
	var dir := Vector3(corner.x - at.x, 0.0, corner.z - at.z)

	if t < float(state.get("sidestep_until", -INF)) and dir.length() > 0.01:
		dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(110.0) * float(state.get("sidestep_side", 1.0)))

	if look:
		_look(player, command, Vector3(corner.x, player.eye_position().y + (corner.y - at.y) * 0.5, corner.z))
	_walk(command, dir)
	# Slow for the last metre, or a body overshoots the place beside the piece.
	if flat < 1.0:
		command.move *= clampf(flat, 0.35, 1.0)
	command.set_button(DotFpsCommand.BUTTON_SPRINT, sprint)
	_unstick(player, command, state)
	return false


func _next_corner(state: Dictionary, at: Vector3) -> Vector3:
	var path: PackedVector3Array = state["path"]
	var corner: int = state["corner"]
	while corner < path.size() - 1 and Vector2(path[corner].x - at.x, path[corner].z - at.z).length() < 0.4 \
			and absf(path[corner].y - at.y) < 0.9:
		corner += 1
	state["corner"] = corner
	return path[mini(corner, path.size() - 1)] if not path.is_empty() else at


## Moves along [param world_dir] (flat) whatever way the view is turned.
static func _walk(command: DotFpsCommand, world_dir: Vector3) -> void:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)
	if flat.length() < 0.01:
		command.move = Vector2.ZERO
		return
	flat = flat.normalized()
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	command.move = Vector2(flat.dot(right), flat.dot(forward)).limit_length(1.0)


## Turns toward [param point] at the bot's turn rate.
func _look(player: PhPlayer, command: DotFpsCommand, point: Vector3) -> void:
	var view := aim_of(player).look_at_point(player.eye_position(), point, dt())
	command.yaw = view.x
	command.pitch = clampf(view.y, -60.0, 60.0)


## Steps aside, then asks for a fresh path, when it has not moved in a second. Never a hop:
## a disguised prop that hops is a sink in mid-air (the first play test's sliding, jumping
## furniture in the hallway was stand-ins doing exactly that). A hop only as a person.
func _unstick(player: PhPlayer, command: DotFpsCommand, state: Dictionary) -> void:
	var mark: Array = state["stuck"]
	var at := player.controller.state.position
	var t := now()
	if t - float(mark[1]) < 1.0:
		return
	var stuck := Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.3
	if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
		var stream: DotRandomStream = state["stream"]
		if int(state.get("stuck_count", 0)) % 2 == 0 and not player.is_disguised():
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		else:
			state["sidestep_until"] = t + 0.7
			state["sidestep_side"] = 1.0 if stream.next_unit() < 0.5 else -1.0
		state["path"] = PackedVector3Array()
		state["stuck_count"] = int(state.get("stuck_count", 0)) + 1
		if int(state["stuck_count"]) >= 3:
			state["stuck_count"] = 0
			state["goal_place"] = {}
			# A prop that cannot reach its place: another one.
			if int(game.call("team_of", player.player_id)) == PROPS and state["mode"] != &"hidden":
				var spot: Dictionary = state["spot"]
				if not spot.is_empty() and int(spot.get("prop", -1)) >= 0:
					(state["bad"] as Array).append(int(spot["prop"]))
				if state["mode"] == &"fleeing":
					state["mode"] = &"hidden"
				else:
					_pick_spot(player, state)
	else:
		state["stuck_count"] = 0
	state["stuck"] = [at, t]


func describe() -> Dictionary:
	return {"spots": spots.size(), "survey_ms": snappedf(survey_ms, 0.1), "nav": nav.describe(), "bots": _state.size(),
		"tests_on_props": tests_on_props, "tests_on_furniture": tests_on_furniture}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["bots  %d places surveyed in %.0f ms; tests: %d on props, %d on furniture" % [
		spots.size(), survey_ms, tests_on_props, tests_on_furniture]])
	lines.append_array(nav.describe_lines())
	for id: StringName in _state:
		var s: Dictionary = _state[id]
		var spot: Dictionary = s.get("spot", {})
		lines.append("  %-10s %-8s %s %s" % [String(id), String(s["mode"]), str(spot.get("kind", "-")), str(spot.get("at", "-"))])
	return lines
