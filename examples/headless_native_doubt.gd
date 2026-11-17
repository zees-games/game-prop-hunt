extends DotGameCheckSuite

const PhBots := preload("../game/ph_bots.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhGame := preload("../game/ph_game.gd")

## A hunter's doubt walk over the map's own pieces in dot-sim ([code]DotSimPropDoubt[/code], [member PhBots.native_doubt]) keeps exactly the pieces
## the script keeps, in the same order: seeded pieces, eyes, forwards and fields of view against [method PhBots.doubt_script_kept], then real maps
## as a server builds them, with pieces broken and restored through the bots' own table. With no library the native half is skipped;
## [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead. Line of sight, the cleared list and oddness stay the script's and are not asked here.

## Maps checked when `maps/` is linked in; the practice house alone otherwise (CI clones this repository alone).
const MAPS := ["ph_practice", "ph_house", "ph_school", "ph_office", "ph_woods"]
const ASKS := 20000
const MAP_ASKS := 4000
const CHECKS_PER_MAP := 3

var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Prop Hunt native doubt")
	print("")
	var maps: Array = MAPS if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps")) else ["ph_practice"]

	_entered += 1
	print("the doubt walk is native by default, and the library has it")
	_check(PhBots.native_doubt, "PhBots.native_doubt is on without the game turning it on")
	if not DotSim.has(&"doubt"):
		print("  dot-sim's doubt module is not loaded: the native half is skipped")
		_check((OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("DOT_SIM_REQUIRE_NATIVE")) != "1", "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_finished += 1
		_report_sections(_entered, _finished, 1, 2)
		return
	_check(true, "the library has the doubt walk")
	_finished += 1

	_entered += 1
	print("seeded pieces, eyes and fields of view: native against the script")
	_seeded()
	_finished += 1

	for id: String in maps:
		_entered += 1
		print("%s as a server builds it" % id)
		await _on_map(StringName(id))
		_finished += 1

	_report_sections(_entered, _finished, 2 + maps.size(), 5 + CHECKS_PER_MAP * maps.size())


## Pieces as the map keeps them: a transform, a size and a broken flag. Scattered over a few rooms and
## stacked on each other (equal middles, ties in distance), some far out, some broken.
func _seeded() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261117
	var props: Array = []
	for i in range(1500):
		var at := Vector3(rng.randf_range(-30.0, 30.0), rng.randf_range(-2.0, 6.0), rng.randf_range(-30.0, 30.0))
		if i % 50 == 7 and not props.is_empty():
			at = (props[rng.randi() % props.size()]["transform"] as Transform3D).origin
		if i % 97 == 3:
			at *= 1000.0
		var basis := Basis(Vector3.UP, rng.randf_range(-PI, PI))
		props.append({"id": &"piece", "transform": Transform3D(basis, at), "size": Vector3(rng.randf_range(0.1, 2.0), rng.randf_range(0.0, 3.0), rng.randf_range(0.1, 2.0)), "broken": rng.randf() < 0.1})

	var table: RefCounted = ClassDB.instantiate(DotSim.MODULES[&"doubt"])
	var middles := PackedVector3Array()
	for prop: Dictionary in props:
		middles.append((prop["transform"] as Transform3D).origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0))
	table.call(&"set_pieces", middles)
	for i in range(props.size()):
		if bool(props[i]["broken"]):
			table.call(&"set_broken", i, true)
	_check(int(table.call(&"count")) == props.size(), "the table holds every piece", "%d of %d" % [int(table.call(&"count")), props.size()])

	var differ := 0
	var first := ""
	var kept_total := 0
	for k in range(ASKS):
		var eye := Vector3(rng.randf_range(-32.0, 32.0), rng.randf_range(-1.0, 6.0), rng.randf_range(-32.0, 32.0))
		if k % 10 == 0:
			# Right on a piece's middle, or exactly the reach or half a metre from it.
			var m: Vector3 = middles[rng.randi() % middles.size()]
			eye = [m, m + Vector3(PhBots.DOUBT_REACH, 0.0, 0.0), m + Vector3(0.0, 0.0, -0.5), m + Vector3(0.0, 0.5, 0.0)][k / 10 % 4]
		var forward := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.6, 0.6), rng.randf_range(-1.0, 1.0)).normalized()
		if k % 7 == 0:
			forward = Vector3.FORWARD
		var fov: float = [90.0, 75.0, 110.0, 179.5, rng.randf_range(10.0, 170.0)][k % 5]
		var want := PhBots.doubt_script_kept(props, eye, forward, fov)
		var got: PackedInt32Array = table.call(&"scan", eye, forward, fov, PhBots.DOUBT_REACH)
		kept_total += want.size()
		if got != want:
			differ += 1
			if first.is_empty():
				first = "eye %s forward %s fov %s: native %s, script %s" % [eye, forward, fov, got, want]
	_check(differ == 0, "every ask keeps the same pieces in the same order (%d asks)" % ASKS, "%d differ; first %s" % [differ, first])
	_check(kept_total > ASKS, "the asks kept pieces (not all empty)", "%d kept" % kept_total)


## A real map: random eyes over its bounds through the bots' own table, then pieces broken and the
## round restored, the table written again each time.
func _on_map(id: StringName) -> void:
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([String(id)])
	var game := PhGame.new()
	game.name = "World_%s" % String(id)
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.draw_world = false
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var map: Node3D = game.get("map")
	var props: Array = map.get("props")
	_check(props.size() > 0, "the map has pieces", "%d" % props.size())
	var bots: Object = game.bots
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(id))
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for prop: Dictionary in props:
		var o := (prop["transform"] as Transform3D).origin
		lo = lo.min(o)
		hi = hi.max(o)

	var phases := [[], [], []]
	var differ := 0
	var first := ""
	for phase in range(3):
		if phase == 1:
			for n in range(maxi(1, props.size() / 5)):
				map.call("break_prop", rng.randi() % props.size())
		elif phase == 2:
			map.call("restore_all")
		var broken := 0
		for prop: Dictionary in props:
			broken += 1 if bool(prop["broken"]) else 0
		phases[phase] = broken
		for k in range(MAP_ASKS / 3):
			var eye := Vector3(rng.randf_range(lo.x - 2.0, hi.x + 2.0), rng.randf_range(lo.y, hi.y + 2.0), rng.randf_range(lo.z - 2.0, hi.z + 2.0))
			var forward := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.5, 0.5), rng.randf_range(-1.0, 1.0)).normalized()
			var fov: float = [90.0, 110.0, 75.0][k % 3]
			var table: RefCounted = bots.call("_doubt_pieces", map, props)
			var got: PackedInt32Array = table.call(&"scan", eye, forward, fov, PhBots.DOUBT_REACH)
			var want := PhBots.doubt_script_kept(props, eye, forward, fov)
			if got != want:
				differ += 1
				if first.is_empty():
					first = "phase %d eye %s: native %s, script %s" % [phase, eye, got, want]
	_check(int(phases[1]) > 0 and int(phases[2]) == 0, "pieces broke and came back (%d broken, then %d)" % [phases[1], phases[2]])
	_check(differ == 0, "whole, broken and restored, every ask keeps the script's pieces (%d asks)" % (MAP_ASKS / 3 * 3), "%d differ; first %s" % [differ, first])
	remove_child(game)
	game.free()
	await get_tree().process_frame
