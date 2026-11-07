extends DotVoteRoundGame

## The players choose the next map: dot-vote's [DotVoteRoundGame] with Prop Hunt's names. A ballot opens [member open_after_sec] into
## the LAST round on a map ([member due_fn]) and applies at its end; the rest is dot-vote's settings (`user://cfg/prophunt_vote.json`,
## `game.yml` metadata `map_vote:`). When the rotation alone decides, the operator turns the vote off with `{"enabled": false}`.

const PhCatalogue := preload("ph_catalogue.gd")

const CHANNEL := "prophunt.vote"

const METADATA_KEY := "map_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	config_path = "user://cfg/prophunt_vote.json"


func _default_kinds() -> PackedStringArray:
	return PhCatalogue.accepted_map_kinds()
