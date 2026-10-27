extends DotGameCheckSuite

## A map's file sets the whitelisted round cvars and the next map gets the previous values back.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]

const CHECKS := 7


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-prop-hunt: per-map cvars")
	if not ResourceLoader.exists(DotGameMapConfig.SCRIPT_PATH):
		print("SKIPPED: dot-map is not linked")
		get_tree().quit(0)
		return
	var module = load("res://game/ph_module.gd").new()
	var keys: Dictionary = module._map_config_keys()
	var game_id: String = module._map_config_game()
	module.free()
	_check(keys.has("ph_round_seconds") and keys.has("mp_killcam_time") and not keys.has("sv_cheats"), "the module whitelists round cvars only")
	_check(game_id == "mg-prop-hunt", "the files are read from cfg/game/mg-prop-hunt")

	var console := DotConsole.new()
	add_child(console)
	console.cvar("ph_round_seconds", "300", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("ph_hide_seconds", "30", "", DotConVar.FLAG_ARCHIVE)
	DotAddonConfig.config_root = ProjectSettings.globalize_path("res://examples/fixtures/mapcfg")
	var cfg := DotGameMapConfig.for_console(game_id, console, keys)
	var got := cfg.apply("ph_short_house")
	_check(not got.is_empty(), "a map's file applies something (%s)" % [got])
	_check(console.find_cvar("ph_round_seconds").get_float() == 120.0 and console.find_cvar("ph_hide_seconds").get_float() == 15.0, "the file's values are set")
	cfg.apply("ph_other_unmatched_zz")
	_check(console.find_cvar("ph_round_seconds").get_float() == 300.0, "the next map has the round length back")
	_check(console.find_cvar("ph_hide_seconds").get_float() == 30.0, "and the hide time")
	_check(console.find_cvar("sv_cheats") == null, "a key outside the whitelist is never set")

	_report(CHECKS)
