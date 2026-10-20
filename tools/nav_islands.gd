extends Node

const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")

## Bakes a map's bot navigation the way a round does and says where it is cut in pieces:
##   godot --headless --path . res://tools/nav_islands.tscn -- --map ph_frontyard [--dir=/folder/of/map/documents] [--dump=/path/mesh.json]
##
## Each island is a set of polygons a body can walk between; a hiding place on an island the props'
## start is not on is "cut off" (headless_bots fails the map for it). The islands print biggest
## first with their bounds, the props' start island, and how many hiding places each holds; --dump
## writes the mesh (vertices and polygons) for plotting. Importers and builders use it to see WHY a
## map is cut: a ladder, a step above a body's climb, a doorway under 0.7 m, a pit.

func _ready() -> void:
	var map_id := ""
	var dump := ""
	var dir := ""
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--map" and i + 1 < args.size():
			map_id = args[i + 1]
		elif args[i].begins_with("--dir="):
			dir = args[i].substr(6)
		elif args[i].begins_with("--dump="):
			dump = args[i].substr(7)
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.bot_nav = true
	config.map_ids = PackedStringArray([map_id])
	var game := PhGame.new()
	game.config = config
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	if dir != "":
		# An absolute folder of documents (a map being converted), added beside the game's own.
		var _added: int = game.catalogue.add_directory(dir)
	await get_tree().physics_frame
	for i in range(8):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	for tick in range(600):
		game.simulate(1.0 / 32.0)
		await get_tree().physics_frame
		if game.phase == PhGame.Phase.SEEK or (game.bots.nav.is_ready() and not game.bots.spots.is_empty()):
			break
	var nav: DotBotNav = game.bots.nav
	if not nav.is_ready():
		print("nav not ready")
		get_tree().quit(1)
		return
	var start: Vector3 = (game.map.spawn("props", 0) as Array)[0]
	var home := nav.island_at(nav.closest(start), 2.0)
	print("map %s (%d): props start %s on island %d" % [map_id, 0, start.snapped(Vector3.ONE * 0.1), home])
	var per := {}
	for spot: Dictionary in game.bots.spots:
		var k := nav.island_at(spot["at"], 1.0)
		per[k] = int(per.get(k, 0)) + 1
	for isl in nav.islands():
		if float(isl["area"]) < 1.0 and not per.has(int(isl["index"])):
			continue
		var bb: AABB = isl["bounds"]
		print("  island %d%s: area %.1f m2, x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f, %d places" % [int(isl["index"]), " (HOME)" if int(isl["index"]) == home else "", float(isl["area"]), bb.position.x, bb.end.x, bb.position.y, bb.end.y, bb.position.z, bb.end.z, int(per.get(int(isl["index"]), 0))])
	print("  places off the home island: %d of %d" % [game.bots.spots.size() - int(per.get(home, 0)), game.bots.spots.size()])
	if dump != "":
		var mesh := nav.mesh
		var polys := []
		for i in range(mesh.get_polygon_count()):
			polys.append(Array(mesh.get_polygon(i)))
		var verts := []
		for v in mesh.get_vertices():
			verts.append([v.x, v.y, v.z])
		var spots := []
		for spot: Dictionary in game.bots.spots:
			var a: Vector3 = spot["at"]
			spots.append([a.x, a.y, a.z, nav.island_at(a, 1.0)])
		var f := FileAccess.open(dump, FileAccess.WRITE)
		f.store_string(JSON.stringify({"verts": verts, "polys": polys, "spots": spots, "home": home}))
	get_tree().quit(0)
