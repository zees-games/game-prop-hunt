extends DotNetInterest

const PhGame := preload("../ph_game.gd")
const PhPlayer := preload("../ph_player.gd")

## Who a client is told about: everybody, except that a hunter is told nothing about the props while they hide.
## The blindfold made true on the wire: a client never told where somebody is cannot draw them, whatever it does to its renderer.
## Evaluated every snapshot with nothing lingering, unlike the default's quarter-second cache: a prop sent for a second after the hide began would show where everybody ran.

## The world whose phase and sides this reads. Set by the bridge.
var game: PhGame = null


func _init() -> void:
	strategy_name = "prophunt"
	evaluation_interval_sec = 0.0


func _is_relevant(observer: DotNetIdentity, entity: DotNetIdentity, _context: Dictionary) -> bool:
	if game == null or observer == null or entity == null:
		return true

	if game.phase != PhGame.Phase.HIDE:
		return true

	var watcher := observer.get_parent() as PhPlayer

	if watcher == null:
		return true

	# A toy: not to a hunter while the props hide, or a ball rolling away from where a prop just
	# walked would be that prop on the wire. Sent as it stands when the seek starts.
	if entity.get_parent() is DotPropToy:
		return game.team_of(watcher.player_id) != PhGame.HUNTERS

	var seen := entity.get_parent() as PhPlayer

	if seen == null:
		return true

	return not (
		game.team_of(watcher.player_id) == PhGame.HUNTERS
		and game.team_of(seen.player_id) == PhGame.PROPS
	)
