extends Node

const PhConfig := preload("ph_config.gd")
const PhGame := preload("ph_game.gd")

## What a [DotServer] loads as its game scene. Never a client. Small on purpose: everything a dedicated server does is in `ph_module.gd`.
## It exists because dot-server loads a SCENE, and the world must be in the tree under [constant PhGame.SERVICE] before the module looks for it.
## It lives in `game/`, not `scenes/`: a vendored game copies only the `.tscn` from `scenes/`, so a script there never reaches the build.

const CHANNEL := "ph.server"

## The world this server is running. What the module will find in the registry.
var game: PhGame = null


func _ready() -> void:
	var config := PhConfig.new()

	# The family's `defaults < JSON < environment < argv` chain, on the server too, through DotGameConfigBinder (strict on a dedicated server).
	# An operator sets `PH_HIDE_SECONDS` or `--ph-round-seconds` without editing anything; the module's cvars are the live half.
	var binder := PhConfig.make_binder(config, "user://cfg/prophunt.json")
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	game = PhGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	# The engine's rate, read rather than chosen: the server set it from `sv_tickrate` before this scene loaded.
	# A game that picked its own would simulate at one rate inside a process ticking at another.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	DotLog.info(CHANNEL, "the world is up", {
		"tick_rate": game.tick_rate,
		"maps": config.map_directory,
		"round": config.round_seconds,
	})

	# Not started here: `start()` builds the map, and nothing listens yet, because the module builds the bridge that answers `world_rebuilt`.
	# A map built now would reach no client, so the module starts it on the last line of its own load.
