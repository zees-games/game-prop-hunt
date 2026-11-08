extends DotGameClientBench

const PhConfig := preload("../game/ph_config.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## The world is the server scene and module a dedicated server loads, on ph_school with no warmup; `--bots` is ignored (the module's stand-ins are off).


func _configure() -> void:
	client_scene = "res://game/ph.tscn"


func _boot_server(_bots_wanted: int, data_dir: String) -> DotNetManager:
	var config := make_server_config(data_dir)
	config.max_players = 16
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var scene: Node = (load("res://scenes/ph_server.tscn") as PackedScene).instantiate()
	add_child(scene)
	scene.game.config.map_ids = PackedStringArray(["ph_school"])
	scene.game.config.warmup_seconds = 0.0
	scene.game.config.minimum_players = 0
	await get_tree().process_frame
	var loaded: DotResult = await server.modules.load_module("res://game/ph_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	var bots: DotConVar = server.console.find_cvar("ph_bots")
	if bots != null:
		bots.force_set("0")
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
