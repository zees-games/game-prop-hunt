extends "ph_bots_doubt.gd"

## The hunters' senses for a tick, all of them in one call into gs-sim ([code]GSSimHunterSeek[/code]):
## who each can see is a prop ([method _prey]), the places each crosses off ([method GSBotSearch.observe])
## and the doubt rows each weighs ([method _doubt_rows]), the same answers in the same order as the
## script, rays and all. What a hunter does with them (chase, test, walk, look) stays in script.
## [code]headless_native_seek[/code] holds the two to the bit.


## "native": the seeking hunters' senses in one native call a tick when the library has it;
## "script": each hunter asks on its own (also the fallback with no library).
static var seek_mode: String = "native"
## Runs the script's senses beside every native answer, acts on the script's and counts any
## difference (a check: slow). [code]PH_SEEK_VERIFY=1[/code].
static var seek_verify: bool = OS.get_environment("PH_SEEK_VERIFY") == "1"
## Native answers that differed from the script's while [member seek_verify] was on.
static var seek_mismatches: int = 0
## Native batches asked (the suites check the native path ran).
static var seek_scans: int = 0

const _CAREFUL := 1
const _SENSE := 2
const _OBSERVE := 4

var _seek_table: RefCounted = null
var _seek_ray: RefCounted = null
var _seek_map: Object = null
var _seek_version: int = -1
var _seek_kin: PackedInt32Array = PackedInt32Array()
## Piece kind (as a String) to the code the native table knows it by.
var _seek_kinds: Dictionary = {}
## The props as listed for this tick's batch (what a native prop index means).
var _seek_props: Array = []
## This tick's native answers by hunter id: `[prey index, sensed, observed, crossed, keys, deltas, capped]`.
var _sensed: Dictionary = {}
var _no_rids: Array[RID] = []


func reset() -> void:
	super()
	_sensed.clear()
	if _seek_table != null:
		_seek_table.call(&"reset")


func forget(player_id: StringName) -> void:
	super(player_id)
	_sensed.erase(player_id)
	if _seek_table != null:
		_seek_table.call(&"forget", String(player_id))


## The native table, made on first ask; null in script mode or with no library.
func _seek_native() -> RefCounted:
	if seek_mode != "native":
		return null
	if _seek_table == null:
		if not GSSim.has(&"seek") or not GSSim.has(&"sight"):
			return null
		_seek_table = ClassDB.instantiate(GSSim.MODULES[&"seek"])
		_seek_ray = ClassDB.instantiate(GSSim.MODULES[&"sight"])
		_seek_table.call(&"set_sight", _seek_ray)
	return _seek_table


## The map's pieces into the native table, again whenever they (or the kin counts) changed.
func _seek_pieces(map: Object, props: Array) -> void:
	var version := int(map.get("props_version"))
	if map == _seek_map and version == _seek_version and _kin_near == _seek_kin:
		return
	var middles := PackedVector3Array()
	var feet := PackedVector3Array()
	var kinds := PackedInt32Array()
	middles.resize(props.size())
	feet.resize(props.size())
	kinds.resize(props.size())
	_seek_kinds.clear()
	for i in range(props.size()):
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		middles[i] = frame.origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
		feet[i] = frame.origin
		var kind := String(prop["id"])
		if not _seek_kinds.has(kind):
			_seek_kinds[kind] = _seek_kinds.size()
		kinds[i] = int(_seek_kinds[kind])
	_seek_table.call(&"set_pieces", middles, feet, kinds, _kin_near)
	for i in range(props.size()):
		if bool((props[i] as Dictionary).get("broken", false)):
			_seek_table.call(&"set_broken", i, true)
	_seek_map = map
	_seek_version = version
	_seek_kin = _kin_near


## Asks every hunter in [param hunters] (in the order they will seek) for this tick's senses in
## one native call; the answers wait in [member _sensed]. Nothing with no native table.
func _sense_hunters(hunters: Array[PhPlayer]) -> void:
	_sensed.clear()
	var table := _seek_native()
	if table == null or hunters.is_empty():
		return
	var map: Node3D = game.get("map")
	_seek_pieces(map, map.get("props"))

	var world: World3D = game.get_world_3d()
	var physics: Object = game.get("physics")
	var mask: int = (int(physics.layer_mask(&"world")) | int(physics.layer_mask(&"prop"))) if physics != null else 1
	_seek_ray.call(&"bind", world.direct_space_state if world != null else null, mask, _no_rids, null, null, 0, Vector3.ZERO, 0.0, 0.0)

	var index_of := _seek_send_props(table)
	var taunt_at := PackedVector3Array()
	var taunt_t := PackedFloat64Array()
	for heard: Dictionary in _taunts:
		taunt_at.append(heard["at"])
		taunt_t.append(float(heard["t"]))

	var profile := settings().profile
	var t := now()
	var rows := _seek_hunter_rows(table, hunters, index_of, profile, t)
	var flags: PackedInt32Array = rows[3]
	var config: Object = game.get("config")
	var rules := PackedFloat64Array([t, 4.0 * dt(), float(config.get("bot_suspicion")) / 100.0, profile.fov, profile.sight,
		profile.memory, profile.map_knowledge, profile.aggression, float(int(game.get("round_number")))])
	var out: Array = table.call(&"sense", rules, taunt_at, taunt_t, rows[0], rows[1], rows[2], flags, rows[4], rows[5], rows[6])
	if out.size() != 2:
		push_error("GSSimHunterSeek.sense refused the batch: the hunters ask in script this tick")
		return
	_seek_take_answers(hunters, flags, out)


## The props, as players_on lists them, into the native table; returns each prop's index by player id.
func _seek_send_props(table: Object) -> Dictionary:
	_seek_props = game.call("players_on", PROPS)
	var n := _seek_props.size()
	var p_at := PackedVector3Array()
	var p_velocity := PackedVector3Array()
	var p_hull := PackedFloat64Array()
	var p_flags := PackedInt32Array()
	var p_kinds := PackedInt32Array()
	var p_ids := PackedStringArray()
	p_at.resize(n)
	p_velocity.resize(n)
	p_hull.resize(n)
	p_flags.resize(n)
	p_kinds.resize(n)
	p_ids.resize(n)
	var index_of := {}
	for i in range(n):
		var prop: PhPlayer = _seek_props[i]
		index_of[prop.player_id] = i
		p_at[i] = prop.controller.state.position
		p_velocity[i] = prop.controller.state.velocity
		p_hull[i] = prop.hull_height()
		var disguised := prop.is_disguised()
		var flags := (1 if prop.is_alive() else 0) | (2 if prop.watching else 0) | (4 if prop.marked else 0) | (8 if disguised else 0)
		if disguised and (absf(prop.disguise.pitch) > 1.0 or absf(prop.disguise.roll) > 1.0):
			flags |= 16
		p_flags[i] = flags
		p_kinds[i] = int(_seek_kinds.get(String(prop.disguise.prop_id), -1)) if disguised else -1
		p_ids[i] = String(prop.player_id)
	table.call(&"set_props", p_at, p_velocity, p_hull, p_flags, p_kinds, p_ids)
	return index_of


## Each hunter's row for [code]sense[/code] (its native mind refreshed first where the script's
## search moved): [ids, eye, forward, flags, found, found_at, clearing].
func _seek_hunter_rows(table: Object, hunters: Array[PhPlayer], index_of: Dictionary, profile: GSBotProfile, t: float) -> Array:
	var doubt_tick := int(game.get("_tick")) % 4 == 0
	var m := hunters.size()
	var ids := PackedStringArray()
	var eye := PackedVector3Array()
	var forward := PackedVector3Array()
	var flags := PackedInt32Array()
	var found := PackedInt32Array()
	var found_at := PackedFloat64Array()
	var clearing := PackedStringArray()
	ids.resize(m)
	eye.resize(m)
	forward.resize(m)
	flags.resize(m)
	found.resize(m)
	found_at.resize(m)
	clearing.resize(m)
	for k in range(m):
		var player := hunters[k]
		var id := String(player.player_id)
		var state: Dictionary = call(&"_state_of", player)
		if state["search"] == null:
			state["search"] = call(&"_new_search", profile)
		var search: GSBotSearch = state["search"]
		if not state.has("seek_sync"):
			# A new state (a new round, or this hunter forgotten): its native mind starts again.
			table.call(&"forget", id)
			state["seek_sync"] = true
			state["seek_dirty"] = true
		var careful := player.health != null and player.health.health < player.health.max_health * 0.4
		# What _seek reaches with no prey in sight: the remembered prey's walk, a test holding the
		# turn, or the senses (a test that ends this tick is crossed off first).
		var remembering: bool = state["prey"] != StringName() and t - float(state["prey_seen_at"]) < profile.memory + 2.0
		var test: Dictionary = state["test"]
		var holding := not test.is_empty() and t - float(test["since"]) < TEST_SECONDS and not (careful and float(test["odd"]) < 1.0)
		var sense := doubt_tick and not remembering and not holding
		# A taunt this hunter has not heard may move its search before it looks: the script looks then.
		var observe := sense
		if observe:
			var heard_by := "heard_by_" + id
			for heard: Dictionary in _taunts:
				if not heard.get(heard_by, false):
					observe = false
					break
		if observe and bool(state["seek_dirty"]):
			var places: Array[Dictionary] = search.places
			var at := PackedVector3Array()
			var seen := PackedFloat64Array()
			at.resize(places.size())
			seen.resize(places.size())
			for i in range(places.size()):
				at[i] = places[i]["at"]
				seen[i] = float(places[i]["seen_at"])
			table.call(&"set_search", id, at, seen, search.recheck, search.look_reach)
			state["seek_dirty"] = false
		ids[k] = id
		eye[k] = player.eye_position()
		forward[k] = player.aim_direction()
		flags[k] = (_CAREFUL if careful else 0) | (_SENSE if sense else 0) | (_OBSERVE if observe else 0)
		found[k] = int(index_of.get(state.get("found", StringName()), -1))
		found_at[k] = float(state.get("found_at", -INF))
		clearing[k] = String(test["key"]) if not test.is_empty() and not holding and not remembering else ""
	return [ids, eye, forward, flags, found, found_at, clearing]


## Unpacks the native [code]sense[/code] answer into [member _sensed], one entry per hunter.
func _seek_take_answers(hunters: Array[PhPlayer], flags: PackedInt32Array, out: Array) -> void:
	var m := hunters.size()
	seek_scans += 1
	var ints: PackedInt32Array = out[0]
	var floats: PackedFloat64Array = out[1]
	var a := 0
	var f := 0
	for k in range(m):
		var prey := ints[a]
		var sensed := ints[a + 1] != 0
		var crossed := ints.slice(a + 3, a + 3 + ints[a + 2])
		a += 3 + ints[a + 2]
		var rows := ints[a]
		a += 1
		var keys := PackedStringArray()
		var capped := PackedByteArray()
		keys.resize(rows)
		capped.resize(rows)
		for r in range(rows):
			var key := ints[a]
			keys[r] = ("p%d" % key) if key >= 0 else ("u" + String((_seek_props[-1 - key] as PhPlayer).player_id))
			capped[r] = ints[a + 1]
			a += 2
		_sensed[hunters[k].player_id] = [prey, sensed, flags[k] & _OBSERVE != 0, crossed, keys, floats.slice(f, f + rows), capped]
		f += rows

## The prop [param player] has in sight and knows for one: the native answer when there is one
## (checked against the script's with [member seek_verify]), else the script's.
func _seek_prey(player: PhPlayer, state: Dictionary, sensed: Array) -> PhPlayer:
	if sensed.is_empty():
		return call(&"_prey", player, state)
	var prey: PhPlayer = _seek_props[int(sensed[0])] if int(sensed[0]) >= 0 else null
	if seek_verify:
		var want: PhPlayer = call(&"_prey", player, state)
		if want != prey:
			_seek_differs(player, "prey %s, script %s" % [prey.player_id if prey != null else &"-", want.player_id if want != null else &"-"])
			return want
	return prey


## Observe and doubt for [param player] this doubt tick: the native answer when there is one,
## else (or for the look after an unheard taunt) the script's.
func _seek_sense(player: PhPlayer, state: Dictionary, careful: bool, search: GSBotSearch, t: float, sensed: Array) -> void:
	var profile := settings().profile
	if not sensed.is_empty() and not bool(sensed[1]):
		_seek_differs(player, "the native senses did not run where the script's do")
		sensed = []
	if sensed.is_empty() or not bool(sensed[2]) or seek_verify:
		var before := PackedFloat64Array()
		if seek_verify and not sensed.is_empty() and bool(sensed[2]):
			before.resize(search.places.size())
			for i in range(search.places.size()):
				before[i] = float(search.places[i]["seen_at"])
		var _crossed := search.observe(player.eye_position(), player.aim_direction(), profile.fov, profile.sight, _los, t, 0.5)
		state["seek_dirty"] = true
		if not before.is_empty():
			var want := PackedInt32Array()
			for i in range(before.size()):
				if before[i] != t and float(search.places[i]["seen_at"]) == t:
					want.append(i)
			if want != sensed[3]:
				_seek_differs(player, "crossed %s, script %s" % [sensed[3], want])
	else:
		var crossed: PackedInt32Array = sensed[3]
		for i in crossed:
			var place: Dictionary = search.places[i]
			place["seen_at"] = t
			place["heard_at"] = -INF
	if sensed.is_empty():
		_doubt(player, state, careful)
		return
	if seek_verify:
		var rows := _doubt_rows(player, state, careful)
		if rows[0] != sensed[4] or rows[1] != sensed[5] or rows[2] != sensed[6]:
			_seek_differs(player, "doubt %s %s %s, script %s %s %s" % [sensed[4], sensed[5], sensed[6], rows[0], rows[1], rows[2]])
		_doubt_add(state, rows[0], rows[1], rows[2])
		return
	_doubt_add(state, sensed[4], sensed[5], sensed[6])


func _seek_differs(player: PhPlayer, what: String) -> void:
	seek_mismatches += 1
	push_error("seek_verify: %s at tick %d: native %s" % [player.player_id, int(game.get("_tick")), what])
