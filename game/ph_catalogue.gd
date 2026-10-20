extends RefCounted

const PhMapDoc := preload("ph_map_doc.gd")
const PhPaths := preload("ph_paths.gd")

## Every map this server can play, and which one is next.
##
## [b]Two sources, and the built-in one is a floor rather than a feature.[/b] The maps are
## documents read from [member PhConfig.map_directory] — `maps/`, a link to mg-prop-hunt-maps,
## in a checkout; a directory in a delivered pack. A server whose directory is missing or empty
## still has [method practice], so it plays rather than refusing to start.
##
## [b]A server reads documents; a client never does.[/b] The map travels in its own event (see
## [PhMapDoc]), so nothing here runs on a connected client.

const CHANNEL := "ph.catalogue"

const PRACTICE := &"ph_practice"

## id -> normalised document.
var maps: Dictionary = {}

## Files that were refused, with why. What `ph_maps` prints, so a mapper can see it.
var refused: Dictionary = {}

## id -> pack title, for the maps in [member maps] that a subscribed pack provided (solo only).
## The game's own maps are never in it, and an id of theirs is never taken by a pack.
var workshop: Dictionary = {}

## The Workshop's index and the `map_kind`s taken from it; see [method follow_content].
var content_index: DotContentIndex = null
var content_kinds: PackedStringArray = PackedStringArray()

var _order: Array[StringName] = []
var _next: int = 0
var _workshop_docs: Dictionary = {}

## `(StringName) -> bool`: whether maps.yml's active rotation plays this id. Unset, every map
## does. Read by the draw ([method next_map]) only: an operator's `ph_map`, the map menu and the
## ballot's own list ask [method playable], so an unlisted map stays installed and loadable.
var in_rotation_fn: Callable = Callable()

## The active rotation's written order, used by the draw when not shuffling. Empty is the
## catalogue's own (alphabetical) order.
var rotation_order: Array[StringName] = []

## The pack ref (`owner/map`) of each subscribed map, so maps.yml can name it.
var _content_refs: Dictionary = {}


## Reads every document under [param directory] (relative to this game's root), and adds the
## one built in. Forgets anything read before.
func load_from(directory: String) -> int:
	maps.clear()
	refused.clear()
	workshop.clear()

	_add(practice(), "built-in")

	var root := PhPaths.rebase("res://" + directory.trim_prefix("res://").trim_prefix("/"))
	var loaded := _read_directory(root)
	_rebuild_order()

	DotLog.info(CHANNEL, "maps loaded", {"maps": maps.size(), "refused": refused.size()})
	return loaded


## Adds every document under [param root], an absolute `res://` path: a maps pack mounted
## beside the game, at its OWN prefix, which this game's rebasing would put somewhere else.
func add_directory(root: String) -> int:
	var loaded := _read_directory(root)
	_rebuild_order()
	DotLog.info(CHANNEL, "maps added", {"from": root, "read": loaded, "maps": maps.size()})
	return loaded


func _read_directory(root: String) -> int:
	var dir := DirAccess.open(root)

	if dir == null:
		DotLog.info(CHANNEL, "no map directory here", {"looked_at": root})
		return 0

	var files := PackedStringArray()

	for file in dir.get_files():
		if file.ends_with(".json"):
			files.append(file)

	files.sort()
	var loaded := 0

	for file in files:
		var text := FileAccess.get_file_as_string(root.path_join(file))

		if text.is_empty():
			refused[file] = "empty or unreadable"
			continue

		var parsed := PhMapDoc.parse_json(text, file)

		if not parsed.ok:
			refused[file] = parsed.error.message
			DotLog.warn(CHANNEL, "a map was refused", {
				"file": file, "why": parsed.error.message, "detail": parsed.error.detail,
			})
			continue

		if _add(parsed.value, file):
			loaded += 1

	return loaded


func _add(doc: Dictionary, origin: String) -> bool:
	var id := StringName(str(doc["id"]))

	if maps.has(id) and origin != "built-in" and id != PRACTICE:
		refused[origin] = "a second map with id %s" % id
		return false

	maps[id] = doc
	return true


func _rebuild_order() -> void:
	_order.clear()

	for id: StringName in maps:
		_order.append(id)

	_order.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	_next = 0


## Takes the maps subscribed packs provide, for the index's current session only. Opt-in. A
## pack's map is a prop-hunt map document (the same JSON as `maps/`) named by the entry's
## `scene` path, with `map_kind` one of [param accepted_kinds] ("*" is every kind, empty none).
##
## [b]Synced on every read rather than copied once[/b]: the index filters by its current
## session, so a game that goes online loses them with no signal to miss. [method playable]
## is the read everything goes through.
func follow_content(index: DotContentIndex, accepted_kinds: PackedStringArray = PackedStringArray()) -> void:
	content_index = index
	content_kinds = accepted_kinds
	sync_content()


## Brings [member maps] in line with the index's current session: a pack map in, one that left
## out. The game's own ids win, and a pack map that is not a valid document is listed in
## [member refused] and left out.
func sync_content() -> void:
	var wanted := {}

	if content_index != null:
		for entry in content_index.entries(&"map"):
			var kind := str(entry.raw.get("map_kind", ""))

			if kind == "" or not (content_kinds.has("*") or content_kinds.has(kind)):
				continue

			var id := StringName(entry.id)

			if wanted.has(id) or (maps.has(id) and not workshop.has(id)):
				continue

			var doc := _workshop_doc(entry)

			if not doc.is_empty():
				wanted[id] = [doc, entry.pack_title]
				_content_refs[id] = str(entry.content_id)

	var changed := false

	for id: StringName in workshop.keys():
		if not wanted.has(id):
			maps.erase(id)
			workshop.erase(id)
			changed = true

	for id: StringName in wanted:
		if not maps.has(id):
			maps[id] = wanted[id][0]
			workshop[id] = wanted[id][1]
			changed = true

	if changed:
		_rebuild_order()


func _workshop_doc(entry: DotContentEntry) -> Dictionary:
	if _workshop_docs.has(entry.key):
		return _workshop_docs[entry.key]

	var path := entry.path("scene")
	var text := FileAccess.get_file_as_string(path) if path != "" else ""
	var parsed := PhMapDoc.parse_json(text, path) if text != "" \
		else DotResult.fail(DotError.CODE_IO, "empty or unreadable", path)
	var doc: Dictionary = {}

	if parsed.ok:
		doc = parsed.value
		doc["id"] = entry.id
	else:
		refused[entry.key] = parsed.error.message
		DotLog.warn(CHANNEL, "a Workshop map was refused", {
			"entry": entry.key, "why": parsed.error.message,
		})

	_workshop_docs[entry.key] = doc
	return doc


## The file a game pack states what it takes from subscriptions in (dot-cloud's
## docs/workshop.md, "What a game accepts"). Read from there so the site and this list cannot drift.
const PROVIDES_PATH := "res://provides.json"
const ACCEPTED_MAP_KINDS_FALLBACK := ["prophunt"]


## The `map_kind`s of subscribed maps this game takes: `accepts.map_kinds` in `provides.json`.
static func accepted_map_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	var path := PhPaths.rebase(PROVIDES_PATH)
	var parsed: Variant = null
	if FileAccess.file_exists(path):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var accepts: Variant = (parsed as Dictionary).get("accepts") if parsed is Dictionary else null
	var kinds: Variant = (accepts as Dictionary).get("map_kinds") if accepts is Dictionary else null
	if not (kinds is Array):
		kinds = ACCEPTED_MAP_KINDS_FALLBACK
	for kind: Variant in (kinds as Array):
		out.append(str(kind))
	return out


## Whether [param id] came from a subscribed pack.
func is_workshop(id: StringName) -> bool:
	return workshop.has(id)


## The name a menu shows: "Name [Pack]" for a pack's map, the plain name otherwise.
func label_of(id: StringName) -> String:
	var name := str((maps.get(id, {}) as Dictionary).get("name", id))
	var pack := str(workshop.get(id, ""))
	return "%s [%s]" % [name, pack] if pack != "" else name


## The pack ref of a subscribed map, "" for the game's own.
func content_ref(id: StringName) -> String:
	return str(_content_refs.get(id, ""))


## Whether maps.yml's active rotation plays [param id]; true with no rotation file.
func in_rotation(id: StringName) -> bool:
	return not in_rotation_fn.is_valid() or bool(in_rotation_fn.call(id))


## [method playable] less the maps outside the active rotation: what a draw may choose. When
## the rotation leaves nothing installed, every playable map: a rotation must never strand the
## server.
func drawable(allowed: PackedStringArray) -> Array[StringName]:
	var all := playable(allowed)
	var out: Array[StringName] = []

	for id in all:
		if in_rotation(id):
			out.append(id)

	if out.is_empty():
		return all

	if not rotation_order.is_empty():
		var ordered: Array[StringName] = []

		for id in rotation_order:
			if out.has(id):
				ordered.append(id)

		for id in out:
			if not ordered.has(id):
				ordered.append(id)

		return ordered

	return out


## The ids a server may draw from, after [param allowed] (empty is all). The built-in practice
## map drops out once there is anything else.
func playable(allowed: PackedStringArray) -> Array[StringName]:
	sync_content()
	var out: Array[StringName] = []

	for id in _order:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	if allowed.is_empty() and out.size() > 1:
		out.erase(PRACTICE)

	return out


## The next map: drawn from [param stream] when shuffling, in order otherwise, and never the
## same one twice running when there is a choice.
func next_map(allowed: PackedStringArray, shuffle: bool, stream: DotRandomStream,
		previous: StringName) -> Dictionary:
	var ids := drawable(allowed)

	if ids.is_empty():
		DotLog.warn(CHANNEL, "no map matches the allowed list; playing practice", {
			"allowed": ",".join(allowed),
		})
		return maps.get(PRACTICE, practice())

	var pick: StringName

	if shuffle and stream != null:
		pick = ids[stream.next_range_i(0, ids.size() - 1)]

		if pick == previous and ids.size() > 1:
			pick = ids[(ids.find(pick) + 1 + stream.next_range_i(0, ids.size() - 2)) % ids.size()]
	else:
		pick = ids[_next % ids.size()]
		_next += 1

	return maps[pick]


func describe_lines() -> PackedStringArray:
	sync_content()
	var lines := PackedStringArray(["maps (%d)" % maps.size()])

	for id in _order:
		var doc: Dictionary = maps[id]
		lines.append("  %-22s %-28s %4d props  %s%s" % [
			id, label_of(id), (doc["props"] as Array).size(), str(doc["author"]),
			"" if in_rotation(id) else "  (not in rotation)",
		])

	if not refused.is_empty():
		lines.append("refused (%d)" % refused.size())

		for file: String in refused:
			lines.append("  %-22s %s" % [file, refused[file]])

	return lines


# --- The one built in -------------------------------------------------------

## A two-room house with a garden: enough furniture to hide among and a door between the rooms.
##
## [b]Written here rather than shipped as a file,[/b] so a server with no map directory at all
## — a fresh clone, a suite — has something to play, and the suites have a map whose every
## number is in front of them. They lean on these: the floor is x -10..10, z -8..8 at y 0; the
## wall between the rooms is at x 0 with a 1.8 m door at z -1..0.8; the hunters start in the
## east room, the props in the west; the garden is x 10..22.
static func practice() -> Dictionary:
	var boxes: Array = []
	var height := 3.2

	# Floors and ceiling.
	boxes.append({"at": [-5.0, -0.1, 0.0], "size": [10.0, 0.2, 16.0], "mat": "wood_floor"})
	boxes.append({"at": [5.0, -0.1, 0.0], "size": [10.0, 0.2, 16.0], "mat": "carpet"})
	boxes.append({"at": [0.0, height + 0.1, 0.0], "size": [20.0, 0.2, 16.0], "mat": "ceiling"})
	# Outer walls: north, south, west, and the east wall with a door to the garden.
	boxes.append({"at": [0.0, height * 0.5, -8.1], "size": [20.4, height, 0.2], "mat": "paint"})
	boxes.append({"at": [0.0, height * 0.5, 8.1], "size": [20.4, height, 0.2], "mat": "paint"})
	boxes.append({"at": [-10.1, height * 0.5, 0.0], "size": [0.2, height, 16.0], "mat": "paint", "tint": [0.95, 0.9, 0.8]})
	boxes.append({"at": [10.1, height * 0.5, -4.6], "size": [0.2, height, 6.8], "mat": "brick"})
	boxes.append({"at": [10.1, height * 0.5, 4.6], "size": [0.2, height, 6.8], "mat": "brick"})
	boxes.append({"at": [10.1, 2.7, 0.0], "size": [0.2, 1.0, 2.4], "mat": "brick"})
	# The wall between the rooms, with its door at z -1..0.8.
	boxes.append({"at": [0.0, height * 0.5, -4.5], "size": [0.2, height, 7.0], "mat": "paint"})
	boxes.append({"at": [0.0, height * 0.5, 4.4], "size": [0.2, height, 7.2], "mat": "paint"})
	boxes.append({"at": [0.0, 2.7, -0.1], "size": [0.2, 1.0, 1.8], "mat": "paint"})
	# The garden: grass, a fence round it and a path.
	boxes.append({"at": [16.0, -0.1, 0.0], "size": [12.0, 0.2, 16.0], "mat": "grass"})
	boxes.append({"at": [13.0, 0.01, 0.0], "size": [6.0, 0.02, 1.6], "mat": "sidewalk", "solid": false})
	boxes.append({"at": [22.1, 1.0, 0.0], "size": [0.2, 2.0, 16.4], "mat": "wood"})
	boxes.append({"at": [16.0, 1.0, -8.1], "size": [12.0, 2.0, 0.2], "mat": "wood"})
	boxes.append({"at": [16.0, 1.0, 8.1], "size": [12.0, 2.0, 0.2], "mat": "wood"})

	var props: Array = [
		# West room: a living room.
		{"id": "furniture_lounge_sofa", "at": [-7.0, 0.0, -6.8], "yaw": 0.0},
		{"id": "furniture_table_coffee", "at": [-7.0, 0.0, -4.6]},
		{"id": "furniture_lounge_chair", "at": [-9.0, 0.0, -3.0], "yaw": 90.0},
		{"id": "furniture_television_modern", "at": [-7.0, 0.0, -1.0], "yaw": 180.0},
		{"id": "furniture_potted_plant", "at": [-9.3, 0.0, 7.2]},
		{"id": "furniture_bookcase_closed", "at": [-4.0, 0.0, 7.6], "yaw": 180.0},
		{"id": "furniture_lamp_round_floor", "at": [-9.3, 0.0, -7.3]},
		{"id": "furniture_cardboard_box_closed", "at": [-2.0, 0.0, 6.8]},
		{"id": "furniture_cardboard_box_closed", "at": [-2.6, 0.0, 6.2], "yaw": 20.0},
		{"id": "furniture_trashcan", "at": [-1.0, 0.0, -7.4]},
		{"id": "furniture_rug_rectangle", "at": [-7.0, 0.0, -4.2]},
		# East room: a kitchen.
		{"id": "furniture_kitchen_cabinet", "at": [3.0, 0.0, -7.4]},
		{"id": "furniture_kitchen_stove", "at": [4.0, 0.0, -7.4]},
		{"id": "furniture_kitchen_sink", "at": [5.0, 0.0, -7.4]},
		{"id": "furniture_kitchen_fridge", "at": [6.2, 0.0, -7.5]},
		{"id": "furniture_table", "at": [4.5, 0.0, 2.0]},
		{"id": "furniture_chair", "at": [3.6, 0.0, 1.2]},
		{"id": "furniture_chair", "at": [5.4, 0.0, 1.2]},
		{"id": "furniture_chair", "at": [3.6, 0.0, 2.8], "yaw": 180.0},
		{"id": "furniture_chair", "at": [5.4, 0.0, 2.8], "yaw": 180.0},
		{"id": "furniture_kitchen_microwave", "at": [3.0, 1.03, -7.4]},
		{"id": "furniture_washer", "at": [9.3, 0.0, 6.5], "yaw": -90.0},
		{"id": "furniture_dryer", "at": [9.3, 0.0, 5.4], "yaw": -90.0},
		# The garden.
		{"id": "nature_tree_oak", "at": [19.0, 0.0, -5.0]},
		{"id": "nature_plant_bush", "at": [20.5, 0.0, 3.0]},
		{"id": "nature_plant_bush_detailed", "at": [14.0, 0.0, 6.0]},
		{"id": "nature_rock_small_a", "at": [17.0, 0.0, 1.5]},
		{"id": "nature_stump_round", "at": [15.0, 0.0, -6.0]},
		{"id": "nature_crop_pumpkin", "at": [20.8, 0.0, 6.8]},
		{"id": "nature_flower_red_a", "at": [12.0, 0.0, -7.0]},
	]

	var source := {
		"format": PhMapDoc.FORMAT,
		"kind": PhMapDoc.KIND,
		"id": String(PRACTICE),
		"name": "Practice House",
		"author": "mg-prop-hunt",
		"blurb": "Two rooms and a garden.",
		"boxes": boxes,
		"props": props,
		# dot-props' toys, loose only, in the garden: the suites push the football, shoot the
		# beach ball, and watch a client see the kick.
		"toys": [
			{"toy": "football", "at": [14.0, 0.0, 3.0]},
			{"toy": "beach_ball", "at": [16.5, 0.0, -2.5]},
			{"toy": "tyre", "at": [18.5, 0.0, 4.5], "yaw": 30.0},
		],
		"lights": [
			{"at": [-5.0, 2.8, 0.0], "range": 9.0, "energy": 0.9},
			{"at": [5.0, 2.8, 0.0], "range": 9.0, "energy": 0.9},
		],
		"spawns": {
			"props": [
				{"at": [-5.0, 0.1, 0.0], "yaw": 90.0}, {"at": [-6.0, 0.1, 2.0], "yaw": 90.0},
				{"at": [-4.0, 0.1, -2.0], "yaw": 90.0}, {"at": [-6.0, 0.1, 4.0], "yaw": 90.0},
				{"at": [-4.0, 0.1, 2.0], "yaw": 90.0}, {"at": [-6.0, 0.1, -2.0], "yaw": 90.0},
			],
			"hunters": [
				{"at": [7.0, 0.1, 0.0], "yaw": 90.0}, {"at": [7.0, 0.1, -2.0], "yaw": 90.0},
				{"at": [7.0, 0.1, 2.0], "yaw": 90.0},
			],
		},
	}

	var normalised := PhMapDoc.validate(source)
	return normalised.value if normalised.ok else {}
