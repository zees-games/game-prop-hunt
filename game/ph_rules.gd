extends DotMatchRules

## A round ends when the game says so, and the game says who won.
## dot-match's elimination rule nearly fits: a mid-round joiner is benched rather than dead, hiding must never end on a count, and the clock's winner is a server setting.
## So [PhGame] decides and [DotMatchRules] only reads it, a pure function of what the game decided; a game that has not decided returns NONE every tick.

## `func() -> Dictionary`: `{decided: bool, winner: int}`. Set by [PhGame].
var decision_fn: Callable = Callable()


static func make() -> DotMatchRules:
	# Not this class's own name, for dot-match's reason: a script that names itself in an
	# expression cuts Godot 4.7.2's exit teardown short. See docs/gdscript-hazards.md.
	var rules := new()
	rules.id = &"prophunt"
	rules.display_name = "Prop Hunt"
	rules.score_limit = 0
		# The round keeps its own clock; this is the BACKSTOP, set by [PhGame] to the hiding, the seeking and a minute more.
		# A round the game never decided ends on it as a draw rather than running for ever, and dot-match stops warning that only a custom outcome can end one.
	rules.time_limit_sec = 600.0
	rules.rounds_to_win = 999
	rules.respawn_disabled = true
	rules.kill_points = 1
	rules.suicide_points = 0
	return rules


func _round_outcome(
	_scoreboard: DotScoreboard,
	_teams: DotTeamManager,
	_elapsed_sec: float
) -> Outcome:
	if not decision_fn.is_valid():
		return Outcome.NONE

	var decision: Dictionary = decision_fn.call()

	if bool(decision.get("decided", false)):
		return Outcome.CUSTOM

	# Only the backstop clock is left to the parent: there is no score limit to reach.
	return super._round_outcome(_scoreboard, _teams, _elapsed_sec)


func _round_winner(_scoreboard: DotScoreboard, _teams: DotTeamManager) -> int:
	if not decision_fn.is_valid():
		return 0

	return int((decision_fn.call() as Dictionary).get("winner", 0))
