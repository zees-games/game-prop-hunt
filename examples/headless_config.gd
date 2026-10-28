extends DotGameCheckSuite

## PhConfig through DotGameConfigBinder: fields, cvars, strict refusal, the diff, a shipped yml, the workbench round trip and HELLO.
## Run: godot --headless --path . res://examples/headless_config.tscn

const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")
const PhEvents := preload("../game/net/ph_events.gd")
const ROOT := "user://ph_cfgtest"
const GAME := "mg-prop-hunt"
const CHECKS := 36


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("mg-prop-hunt: config binder")
	var config := PhConfig.new()
	var binder := PhConfig.make_binder(config)
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
	var fall := _fall_rules(console)
	console.set_cvar("sv_falldamage", "0")
	_check(not fall.enabled and fall.damage_for(60.0) == 0.0, "the cvar turns it off")
	_check(config.rounds_per_map == 7 and binder.source_of("rounds_per_map") == "cvar", "a cvar writes the field")
	_check(binder.diff_yaml().contains("rounds_per_map: 7"), "the diff names the edit")
	var schema_path := "user://ph_config_schema.json"
	_check(binder.write_schema(schema_path).ok and FileAccess.file_exists(schema_path), "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)

	_strict_refuses_an_unknown_key()

	_layers()
	_templates(binder)

	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for k in keys:
		if not listed.has(k):
			missing.append(k)
	_check(missing.is_empty() and binder.profile_sets().size() == 4, "the workbench lists all %d keys over %d files" % [keys.size(), binder.profile_sets().size()], ",".join(missing))
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_round", "id": binder.profile_id, "key": "hide_seconds", "value": 90.0})
	_check(res.ok and config.hide_seconds == 90.0, "a workbench edit reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/mg-prop-hunt/config_round/game.yml", "")
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


func _strict_refuses_an_unknown_key() -> void:
	var bad := FileAccess.open("user://ph_config_bad.json", FileAccess.WRITE)
	bad.store_string('{"no_such_field": 1}')
	bad.close()
	var strict := PhConfig.make_binder(PhConfig.new(), "user://ph_config_bad.json")
	strict.strict = true
	_check(not strict.load_layers().ok, "strict: an unknown key is refused")
	DirAccess.remove_absolute("user://ph_config_bad.json")


## Fall damage as this game binds it: on by default, a hard landing hurts, only a very high speed kills.
func _fall_rules(console: DotConsole) -> DotFallDamageRules:
	var fall := PhGame.make_fall_rules()
	var _made := fall.bind_cvars(console.cvar, DotConVar.FLAG_NOTIFY)
	_check(console.get_int("sv_falldamage") == 1 and fall.enabled, "fall damage is on in this game")
	_check(fall.damage_for(20.0) > 0.0 and fall.damage_for(5.0) == 0.0, "a hard landing hurts, a small one does not")
	_check(console.get_int("sv_falldamage_lethal") == 40 and fall.damage_for(45.0) > 1000.0, "only a very high speed kills outright")
	return fall


## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := PhConfig.new()
	var binder := PhConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s round=%s round_src=%s cooldown=%s cooldown_src=%s cvar=%s speed=%s speed_src=%s penalty=%s penalty_src=%s" % [
		loaded.ok, config.round_seconds, binder.source_of("round_seconds"), config.reveal_cooldown, binder.source_of("reveal_cooldown"),
		console.find_cvar("ph_reveal_cooldown").get_string(), config.run_speed, binder.source_of("run_speed"),
		config.decoy_penalty, binder.source_of("decoy_penalty")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", "--ph-run-speed=7.5", "--ph-decoy-penalty=0.9"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_round/game.yml" % GAME, "round_seconds: 222.0\n")
	_write("game/%s/config_props/game.yml" % GAME, "reveal_cooldown: 4.5\n")
	OS.set_environment("PH_REVEAL_COOLDOWN", "3.25")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process", text.right(300))
	_check(text.contains("round=222") and text.contains("round_src=yml"), "a cfg file reaches the live config")
	_check(text.contains("cooldown=3.25") and text.contains("cooldown_src=env") and text.contains("cvar=3.25"), "the environment beats a second file and reaches the cvar")
	_check(text.contains("speed=7.5") and text.contains("speed_src=argv"), "argv alone reaches the config")
	_check(text.contains("penalty=0.9") and text.contains("penalty_src=argv"), "a second argv flag reaches it too")
	OS.unset_environment("PH_REVEAL_COOLDOWN")
	_write("game/%s/config_round/game.yml" % GAME, "reveal_cooldown: 4.5\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	for f in ["config_round", "config_props"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/%s/game.yml" % [GAME, f])))


## The shipped cfg files hold every key, in step with PhConfig, and change nothing as they are.
func _templates(binder: DotGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 4, "four shipped cfg files", str(files.size()))
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/dot_game/qa/dot_game_cfg_templates.gd)", ",".join(stale))
