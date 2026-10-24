extends Node

## PhConfig through DotGameConfigBinder: fields, cvars, strict refusal, the diff, a shipped yml loading back, the workbench round trip and the HELLO's movement.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const PhConfig := preload("../game/ph_config.gd")
const PhEvents := preload("../game/net/ph_events.gd")
const CHECKS := 24

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String, _detail := "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _run() -> void:
	print("mg-prop-hunt: config binder")
	var config := PhConfig.new()
	var binder := DotGameConfigBinder.create(config, "mg-prop-hunt", "ph")
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	var keys := PackedStringArray()
	for e: Dictionary in binder.schema():
		keys.append(e["key"])
	for k in ["hide_seconds", "round_seconds", "players_per_hunter", "decoy_penalty", "reveal_cooldown", "taunt_cooldown",
			"friendly_fire", "min_players_to_start", "accelerate", "friction", "gravity", "map_rotation_file", "hunter_weapons"]:
		_check(keys.has(k), "%s is exposed" % k)

	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	console.set_cvar("ph_rounds_per_map", "7")
	_check(config.rounds_per_map == 7 and binder.source_of("rounds_per_map") == "cvar", "a cvar writes the field")
	_check(binder.diff_yaml().contains("rounds_per_map: 7"), "the diff names the edit")
	var schema_path := "user://ph_config_schema.json"
	_check(binder.write_schema(schema_path).ok and FileAccess.file_exists(schema_path), "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)

	var bad := FileAccess.open("user://ph_config_bad.json", FileAccess.WRITE)
	bad.store_string('{"no_such_field": 1}')
	bad.close()
	var strict := DotGameConfigBinder.create(PhConfig.new(), "mg-prop-hunt", "ph", "user://ph_config_bad.json")
	strict.strict = true
	_check(not strict.load_layers().ok, "strict: an unknown key is refused")
	DirAccess.remove_absolute("user://ph_config_bad.json")

	var shipped := "res://cfg/game/mg-prop-hunt/config/game.yml"
	DirAccess.make_dir_recursive_absolute("res://cfg/game/mg-prop-hunt/config")
	var yml := FileAccess.open(shipped, FileAccess.WRITE)
	yml.store_string("hide_seconds: 25.0\nfriendly_fire: true\n")
	yml.close()
	var loaded := PhConfig.new()
	var from_yml := DotGameConfigBinder.create(loaded, "mg-prop-hunt", "ph")
	from_yml.strict = true
	var got := from_yml.load_layers()
	_check(got.ok and loaded.hide_seconds == 25.0 and loaded.friendly_fire and from_yml.source_of("hide_seconds") != "default",
		"an exported cfg/game/<game>/config/game.yml loads back as defaults", "" if got.ok else got.error.message)
	DirAccess.remove_absolute(shipped)
	DirAccess.remove_absolute("res://cfg/game/mg-prop-hunt/config")

	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	wb.add_set(binder.profile_set(), "Game settings")
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var set: DotProfileSet = binder.profile_set()
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": set.rel_path, "id": binder.profile_id, "key": "hide_seconds", "value": 90.0})
	_check(res.ok and config.hide_seconds == 90.0, "a workbench edit reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/mg-prop-hunt/config/game.yml", "")
	_check(text.contains("hide_seconds: 90"), "the export holds the edit in the cfg layout")

	var move := config.movement_floats()
	var hello := PhEvents.read_hello(DotNetReader.new(PhEvents.write_hello(3, 64, 10, 30.0, 300.0, 2.0, 60.0, move, true)))
	_check(bool(hello["ok"]) and hello["move"] == move and bool(hello["auto_hop"]), "the HELLO carries the movement numbers")

	wb.free()
	console.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
