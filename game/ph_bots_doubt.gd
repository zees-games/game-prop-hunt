extends "ph_bots_survey.gd"

## The hunters' doubt: what they weigh in view (the map's pieces, native or in script, and the still props), the layer between the survey and the stand-ins' drive.


## The walk over the map's own pieces in dot-sim ([code]DotSimPropDoubt[/code], one call per
## doubt instead of a dictionary, transform and size read per piece) when the library has it; off,
## or with no library, the script walks them. The same pieces in the same order either way
## ([code]headless_native_doubt[/code]).
static var native_doubt: bool = true
## Walks the pieces in script beside every native scan and reports any difference (a check: slow).
static var doubt_verify: bool = OS.get_environment("PH_DOUBT_VERIFY") == "1"
## Native scans that differed from the script's walk while [member doubt_verify] was on.
static var doubt_mismatches: int = 0
## Native scans made (the suites check the native path ran).
static var doubt_scans: int = 0

var _doubt_table: RefCounted = null
var _doubt_map: Object = null
var _doubt_version: int = -1


## Suspicion of everything in view: real furniture and props alike, as a person who knows the
## map so well and heard what they heard would weigh it.
func _doubt(player: PhPlayer, state: Dictionary, careful: bool) -> void:
	var profile := settings().profile
	var config: Object = game.get("config")
	var base := float(config.get("bot_suspicion")) / 100.0
	var eye := player.eye_position()
	var forward := player.aim_direction()
	var doubt: Dictionary = state["doubt"]
	var cleared: Dictionary = state["cleared"]
	var map: Node3D = game.get("map")
	var props: Array = map.get("props")
	var step := 4.0 * dt()
	var t := now()

	# Doubt fades for what is out of view.
	for key: Variant in doubt.keys():
		doubt[key] = maxf(float(doubt[key]) - step * 0.15, 0.0)

	var seen: Array = []

	# The map's own pieces, near and in view.
	var table := _doubt_pieces(map, props)
	if table == null:
		_doubt_walk(props, eye, seen)
	else:
		var kept: PackedInt32Array = table.call(&"scan", eye, forward, profile.fov, DOUBT_REACH)
		doubt_scans += 1
		for i in kept:
			var prop: Dictionary = props[i]
			var frame: Transform3D = prop["transform"]
			seen.append([i, StringName(), frame.origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0), prop["id"], frame.origin, false])
		if doubt_verify:
			_doubt_check(props, eye, forward, profile.fov, kept)

	# The props, still and disguised (a moving one is prey, not a doubt).
	for other in (game.call("players_on", PROPS) as Array):
		var prop := other as PhPlayer
		if not prop.is_alive() or prop.watching or not prop.is_disguised():
			continue
		var at := prop.controller.state.position
		if absf(at.x - eye.x) > DOUBT_REACH or absf(at.z - eye.z) > DOUBT_REACH:
			continue
		var tilted := absf(prop.disguise.pitch) > 1.0 or absf(prop.disguise.roll) > 1.0
		seen.append([-1, prop.player_id, at + Vector3(0.0, prop.hull_height() * 0.5, 0.0), prop.disguise.prop_id, at, tilted])

	for row: Array in seen:
		var middle: Vector3 = row[2]
		var d := eye.distance_to(middle)
		if d > DOUBT_REACH or d < 0.5:
			continue
		if rad_to_deg(forward.angle_to(middle - eye)) > profile.fov * 0.5:
			continue
		var key: String = ("p%d" % int(row[0])) if int(row[0]) >= 0 else ("u" + String(row[1]))
		# Real furniture tested is crossed off for the round; a prop that did not bleed (a miss)
		# is believed for twenty seconds.
		if cleared.has(key) and (key.begins_with("p") or t - float(cleared[key]) < 20.0):
			continue
		if not _los(eye, middle):
			continue
		var odd := _oddness(player, row, props, base, t)
		var closeness := clampf(1.0 - d / DOUBT_REACH, 0.0, 1.0)
		doubt[key] = float(doubt.get(key, 0.0)) + step * odd * (0.5 + closeness) * (0.6 + profile.aggression * 0.8)
		if careful and odd < 1.0:
			doubt[key] = minf(float(doubt[key]), SUSPECT_AT * 0.9)


## The script's walk over the map's pieces: every whole one inside the square reach of
## [param eye], appended to [param seen] as a doubt row.
static func _doubt_walk(props: Array, eye: Vector3, seen: Array) -> void:
	for i in range(props.size()):
		var prop: Dictionary = props[i]
		if bool(prop.get("broken", false)):
			continue
		var frame: Transform3D = prop["transform"]
		var middle := frame.origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
		if absf(middle.x - eye.x) > DOUBT_REACH or absf(middle.z - eye.z) > DOUBT_REACH:
			continue
		seen.append([i, StringName(), middle, prop["id"], frame.origin, false])


## The native piece table for [param map], written again whenever its pieces changed; null when
## [member native_doubt] is off or the library has no doubt module.
func _doubt_pieces(map: Object, props: Array) -> RefCounted:
	if not native_doubt:
		return null
	if _doubt_table == null:
		if not DotSim.has(&"doubt"):
			return null
		_doubt_table = ClassDB.instantiate(DotSim.MODULES[&"doubt"])
	var version := int(map.get("props_version"))
	if map != _doubt_map or version != _doubt_version:
		var middles := PackedVector3Array()
		middles.resize(props.size())
		for i in range(props.size()):
			var prop: Dictionary = props[i]
			var frame: Transform3D = prop["transform"]
			middles[i] = frame.origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
		_doubt_table.call(&"set_pieces", middles)
		for i in range(props.size()):
			if bool((props[i] as Dictionary).get("broken", false)):
				_doubt_table.call(&"set_broken", i, true)
		_doubt_map = map
		_doubt_version = version
	return _doubt_table


## The map's pieces the script keeps for a doubt from [param eye] along [param forward]: its walk,
## then the row loop's reach and field of view tests. What the native scan must equal.
static func doubt_script_kept(props: Array, eye: Vector3, forward: Vector3, fov: float) -> PackedInt32Array:
	var rows: Array = []
	_doubt_walk(props, eye, rows)
	var want := PackedInt32Array()
	for row: Array in rows:
		var middle: Vector3 = row[2]
		var d := eye.distance_to(middle)
		if d > DOUBT_REACH or d < 0.5:
			continue
		if rad_to_deg(forward.angle_to(middle - eye)) > fov * 0.5:
			continue
		want.append(int(row[0]))
	return want


## The script's pieces against the native [param kept]; a difference is counted and reported.
func _doubt_check(props: Array, eye: Vector3, forward: Vector3, fov: float, kept: PackedInt32Array) -> void:
	var want := doubt_script_kept(props, eye, forward, fov)
	if want != kept:
		doubt_mismatches += 1
		push_error("doubt_verify: native %s, script %s (eye %s, forward %s, fov %s)" % [kept, want, eye, forward, fov])


## How wrong [param row] looks to [param player]: [index, player id, middle, kind, feet, tilted].
func _oddness(player: PhPlayer, row: Array, props: Array, base: float, t: float) -> float:
	var profile := settings().profile
	var index := int(row[0])
	var kind: StringName = row[3]
	var feet: Vector3 = row[4]
	var odd := base

	# Alone of its kind: a sink in a corridor, a chair with no table.
	var kin := _kin_near[index] if index >= 0 and index < _kin_near.size() else _kin_count(props, kind, feet)
	if kin == 0:
		odd += 0.35

		# Remembered: a hunter who knows the map knows this one was there (real) or was not (a prop), drawn once per hunter and piece from its own seed so it holds all round.
		# The more of its kind round it the harder: a third sink is noticed, a thirty-first chair is not.
	var memory := _memory_draw(player, row)
	if memory < profile.map_knowledge / (1.0 + float(kin) * 0.6):
		if index >= 0:
			odd *= 0.15
		else:
			odd += 1.2

	if bool(row[5]):
		odd += 0.5

	for heard: Dictionary in _taunts:
		if t - float(heard["t"]) < 10.0 and (heard["at"] as Vector3).distance_to(feet) < TAUNT_NEAR:
			odd += 1.4
			break
	return odd


func _memory_draw(player: PhPlayer, row: Array) -> float:
	var key := "%s|%d|%s|%d" % [String(player.player_id), int(row[0]), String(row[1]), int(game.get("round_number"))]
	return float(hash(key) & 0xFFFF) / 65535.0
