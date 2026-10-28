extends RefCounted

## The stand-ins' survey layer (places, kin counts, map annotations); ph_bots.gd is the driving on top of it.

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
