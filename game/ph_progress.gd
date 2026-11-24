extends GSStatsPlayerProgress

## What a player keeps from a round: the numbers this game produces, and what they earn.
## Numbers (rounds survived as furniture; props found and real chairs shot) are declared once in [method schema] and reported by gs-stats as a DELTA, so two servers reporting one player add up.
## Achievements are rules over them through [GSAchievementStatsLink]; stand-ins are never counted. Filed under the scoped profile key when there is one ([member durable_key_fn]), else the world's id. The shared parts are [GSStatsPlayerProgress]'s.

## Rounds a player was in from the start to the end, and won.
const ROUNDS_PLAYED := &"ph.rounds_played"
const ROUNDS_WON := &"ph.rounds_won"
## Rounds as each side.
const PROP_ROUNDS := &"ph.prop_rounds"
const HUNTER_ROUNDS := &"ph.hunter_rounds"
## A round got through as a prop, alive at the end.
const SURVIVED := &"ph.survived"
## A prop found, by the hunter who found them.
const PROPS_FOUND := &"ph.props_found"
const BEST_ROUND_FOUND := &"ph.best_round_found"
## Found, as a prop.
const TIMES_FOUND := &"ph.times_found"
## Taken the shape of something.
const DISGUISES := &"ph.disguises"
## A taunt chosen, and one forced by standing still.
const TAUNTS := &"ph.taunts"
const FORCED_TAUNTS := &"ph.forced_taunts"
## A shot that hit the furniture, and a hunter the furniture finished.
const DECOYS_SHOT := &"ph.decoys_shot"
const DECOY_DEATHS := &"ph.decoy_deaths"
const DEATHS := &"ph.deaths"
## The published skill figure the site orders by (gs-stats' GSStatsRank).
const RANK_SCORE := &"rank_score"

## The world's own side dictionary, shared. See [PhSpectate] for why not a reference to it.
var sides: Dictionary = {}

## player id -> props they found this round, for [constant BEST_ROUND_FOUND].
var _round_found: Dictionary = {}


static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_WON, PROP_ROUNDS, HUNTER_ROUNDS, SURVIVED, PROPS_FOUND,
		BEST_ROUND_FOUND, TIMES_FOUND, DISGUISES, TAUNTS, FORCED_TAUNTS, DECOYS_SHOT,
		DECOY_DEATHS, DEATHS, RANK_SCORE,
	]


## Every number, once. [b]`publish` on the ones a player page would show[/b]; deaths and
## rounds played are inputs to a ratio rather than figures anybody reads.
static func schema() -> GSStatsSchema:
	var out := GSStatsSchema.new()
	add_def(out, ROUNDS_PLAYED, GSStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	add_def(out, ROUNDS_WON, GSStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	add_def(out, PROP_ROUNDS, GSStatsDef.Kind.COUNTER, "Rounds as a prop", "rounds", true)
	add_def(out, HUNTER_ROUNDS, GSStatsDef.Kind.COUNTER, "Rounds as a hunter", "rounds", true)
	add_def(out, SURVIVED, GSStatsDef.Kind.COUNTER, "Rounds survived hidden", "rounds", true)
	add_def(out, PROPS_FOUND, GSStatsDef.Kind.COUNTER, "Props found", "props", true)
	add_def(out, BEST_ROUND_FOUND, GSStatsDef.Kind.BEST, "Most props found in a round", "props", true)
	add_def(out, TIMES_FOUND, GSStatsDef.Kind.COUNTER, "Times found", "times", true)
	add_def(out, DISGUISES, GSStatsDef.Kind.COUNTER, "Disguises", "props", true)
	add_def(out, TAUNTS, GSStatsDef.Kind.COUNTER, "Taunts", "taunts", true)
	add_def(out, FORCED_TAUNTS, GSStatsDef.Kind.COUNTER, "Taunts forced by standing still", "taunts", false)
	add_def(out, DECOYS_SHOT, GSStatsDef.Kind.COUNTER, "Shots at the furniture", "shots", true)
	add_def(out, DECOY_DEATHS, GSStatsDef.Kind.COUNTER, "Beaten by the furniture", "deaths", true)
	add_def(out, DEATHS, GSStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	GSStatsHitzones.declare(out)
	GSStatsRank.declare(out, RANK_SCORE, "Rank score")
	return out


## What a player can earn, as rules over [method schema]'s numbers.
## Every stat read here must be one [method schema] declares and this file records, or the achievement never unlocks and nothing errors; the suite checks both ways.
static func catalogue() -> GSAchievementCatalogue:
	var made: Array[GSAchievement] = []

	made.append(_sum(&"ph.hidden", "Hidden in Plain Sight", SURVIVED, 1.0, 10,
		"Get through a round as a prop.", &"ph.hider", 1))
	made.append(_sum(&"ph.furniture", "Part of the Furniture", SURVIVED, 25.0, 30,
		"Get through twenty-five rounds as a prop.", &"ph.hider", 2))
	made.append(_sum(&"ph.seeker", "Found One", PROPS_FOUND, 1.0, 10,
		"Find a prop.", &"ph.seeker", 1))
	made.append(_sum(&"ph.bloodhound", "Bloodhound", PROPS_FOUND, 50.0, 30,
		"Find fifty props.", &"ph.seeker", 2))
	made.append(_sum(&"ph.chameleon", "Chameleon", DISGUISES, 100.0, 20,
		"Take the shape of a hundred things."))
	made.append(_sum(&"ph.loudmouth", "Loudmouth", TAUNTS, 50.0, 15,
		"Taunt the hunters fifty times."))

	# A BEST: four in one round, not four over a career.
	var sweep := GSAchievement.make(&"ph.clean_sweep", "Clean Sweep", [
		GSAchievementRule.make(
			BEST_ROUND_FOUND, 4.0, GSAchievementRule.Op.AT_LEAST,
			GSAchievementRule.Merge.HIGHEST
		),
	])
	sweep.description = "Find four props in one round."
	sweep.points = 30
	made.append(sweep)

	# Secret: earned by the mistake every hunter makes, and only funny afterwards.
	var collateral := _sum(&"ph.collateral", "Collateral Damage", DECOY_DEATHS, 1.0, 10,
		"Be beaten by the furniture.")
	collateral.secret = true
	made.append(collateral)

	var out := GSAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> GSAchievement:
	var out := GSAchievement.make(id, title, [
		GSAchievementRule.make(
			stat, target, GSAchievementRule.Op.AT_LEAST, GSAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


func _label() -> String:
	return "prophunt"


func _make_schema() -> GSStatsSchema:
	return schema()


func _make_catalogue() -> Object:
	return catalogue()


func _rank_stat() -> StringName:
	return RANK_SCORE


func _rank_terms() -> Array:
	return [
		{"stat": String(PROPS_FOUND), "weight": 1.0},
		{"stat": String(SURVIVED), "weight": 1.5},
		{"stat": String(ROUNDS_WON), "weight": 2.0},
		{"stat": String(DECOY_DEATHS), "weight": -0.25},
		{"stat": String(DEATHS), "weight": -0.05},
	]


func _on_leave(player_id: StringName) -> void:
	_round_found.erase(player_id)


func on_round_began() -> void:
	_in_round.clear()
	_round_found.clear()

	for id: StringName in players:
		_in_round[id] = true
		record(id, HUNTER_ROUNDS if int(sides.get(id, 0)) == 2 else PROP_ROUNDS)


## A round ended. [param winner] is a side, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		if not players.has(id):
			continue

		record(id, ROUNDS_PLAYED)

		if winner > 0 and int(sides.get(id, 0)) == winner:
			record(id, ROUNDS_WON)

		var found := int(_round_found.get(id, 0))

		if found > 0:
			record(id, BEST_ROUND_FOUND, float(found))

		publish_rank(id)

	_in_round.clear()
	_round_found.clear()


## A prop alive at the end of a round.
func on_survived(player_id: StringName) -> void:
	record(player_id, SURVIVED)


func on_disguised(player_id: StringName) -> void:
	record(player_id, DISGUISES)


func on_taunted(player_id: StringName, forced: bool) -> void:
	record(player_id, FORCED_TAUNTS if forced else TAUNTS)


func on_decoy(player_id: StringName) -> void:
	record(player_id, DECOYS_SHOT)


## Somebody is out. [param by] is the hunter who found them, or empty; [param why] is the
## world's reason: `shot`, `decoy` (a hunter the furniture finished), `fell`.
func on_died(player_id: StringName, by: StringName, why: StringName) -> void:
	record(player_id, DEATHS)

	if why == &"decoy":
		record(player_id, DECOY_DEATHS)
		return

	if int(sides.get(player_id, 0)) == 1:
		record(player_id, TIMES_FOUND)

	if by == &"" or by == player_id or not players.has(by):
		return

	if int(sides.get(by, 0)) == 2 and int(sides.get(player_id, 0)) == 1:
		record(by, PROPS_FOUND)
		_round_found[by] = int(_round_found.get(by, 0)) + 1
