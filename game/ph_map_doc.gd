extends RefCounted

const PhMaterials := preload("ph_materials.gd")

## What a map IS: a JSON document, checked here before anything is built (`maps/README.md` in mg-prop-hunt-maps is the mapper's copy).
## A document, not a scene: it is read off disk and SENT to each client, so the two ends cannot disagree. Boxes' `at` is the CENTRE, a prop's the middle of its footprint ON the floor; metres and degrees.
## Normalised into plain arrays, never vectors: float32 components come back from JSON as `0.300000011920929`, doubling the bytes and moving the digest. Rounded to the millimetre, once.


## The format this build reads. A document written for a later one is refused rather than
## half-built.
const FORMAT := 1

const KIND := "prophunt_map"

const CHANNEL := "ph.map"

## The most one MAP message carries, compressed. A WebSocket message past its 64 KB outbound buffer is never sent
## (mg-look-at-me's finding), so a larger map goes as MAP_PARTs of at most this many bytes each (the bridge's
## `_map_messages`). Not a limit on a map: a document of any size is sent.
const PART_BYTES := 60000

## How many of each thing a document may hold, 0 for no limit (the default for every one). Settings, not constants:
## `PhConfig.max_map_*` (`max_map_boxes` ... in config_maps/game.yml), applied by [method apply_limits] when the game
## starts. Over a set limit is refused with the count, never cut down: what a big map costs is its author's choice.
static var max_boxes: int = 0
static var max_props: int = 0
static var max_toys: int = 0
static var max_lights: int = 0
static var max_spawns: int = 0
## Past this many lights a document is still read, with a warning in the log: every light is
## drawn, and the Compatibility renderer lights a mesh with at most eight. 0 is no warning.
static var lights_warn: int = 128

## The ambience beds dot-audio ships (CC0, its stock/CREDITS.md), which a map may name.
const AMBIENCE_BEDS := ["amb_wind", "amb_outdoor", "amb_night", "amb_city", "amb_indoor", "amb_eerie", "amb_industrial", "amb_cave", "amb_rain"]

## Every top-level field, and what a missing one becomes.
const DEFAULT_ENV := {
	"sky_top": [0.32, 0.52, 0.82],
	"sky_horizon": [0.72, 0.82, 0.92],
	"ground": [0.35, 0.33, 0.30],
	"sun_pitch": -55.0,
	"sun_yaw": 30.0,
	"sun_energy": 1.1,
	"sun_colour": [1.0, 0.96, 0.88],
	"ambient": [0.62, 0.66, 0.72],
	"ambient_energy": 0.55,
	"fog": 0.0,
}


## Reads a document from JSON text, and checks it.
static func parse_json(text: String, origin: String = "") -> DotResult:
	var json := JSON.new()

	if json.parse(text) != OK:
		return DotResult.fail(
			DotError.CODE_PARSE, "The map is not JSON.",
			"%s line %d: %s" % [origin, json.get_error_line(), json.get_error_message()]
		)

	if typeof(json.data) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "The map is not a JSON object.", origin)

	return validate(json.data as Dictionary)


## Checks a document and returns a normalised copy of it: every optional field present, every
## position three numbers.
static func validate(source: Dictionary) -> DotResult:
	if int(source.get("format", 0)) != FORMAT:
		return _refuse("format is %s; this build reads %d" % [str(source.get("format")), FORMAT], source)

	if str(source.get("kind", "")) != KIND:
		return _refuse("kind is '%s', not '%s'" % [str(source.get("kind", "")), KIND], source)

	var id := str(source.get("id", ""))

	if not _is_id(id):
		return _refuse("id '%s' is not lower-case letters, digits and underscores" % id, source)

	var doc := {
		"format": FORMAT,
		"kind": KIND,
		"id": id,
		"name": str(source.get("name", id)),
		"author": str(source.get("author", "")),
		"blurb": str(source.get("blurb", "")),
		"round_seconds": maxf(float(source.get("round_seconds", 0.0)), 0.0),
		"hide_seconds": maxf(float(source.get("hide_seconds", 0.0)), 0.0),
		"players_per_hunter": maxf(float(source.get("players_per_hunter", 0.0)), 0.0),
		"kill_y": float(source.get("kill_y", -30.0)),
	}

	doc["environment"] = _environment(source)

	# The beds under the map: outdoors, and indoors under any ceiling. Only dot-audio's stock ones.
	for key: String in ["ambience", "ambience_indoor"]:
		if source.has(key):
			var bed := str(source[key])
			if not (bed in AMBIENCE_BEDS):
				return _refuse("%s '%s' is not one of %s" % [key, bed, ", ".join(AMBIENCE_BEDS)], source)
			doc[key] = bed

	var boxes: Array = []
	for raw: Variant in source.get("boxes", []):
		var box := _box(raw)
		if box.is_empty():
			return _refuse("box %d is not {at, size, mat}" % boxes.size(), source)
		boxes.append(box)

	if _over(boxes.size(), max_boxes):
		return _refuse("%d boxes; this server takes at most %d (max_map_boxes, 0 = no limit)" % [boxes.size(), max_boxes], source)

	doc["boxes"] = boxes

	var props: Array = []
	for raw: Variant in source.get("props", []):
		var prop := _prop(raw)
		if prop.is_empty():
			return _refuse("prop %d is not {id, at}" % props.size(), source)
		props.append(prop)

	if _over(props.size(), max_props):
		return _refuse("%d props; this server takes at most %d (max_map_props, 0 = no limit)" % [props.size(), max_props], source)

	doc["props"] = props

	var toys_res := _toys(source)
	if not toys_res.ok:
		return toys_res

	doc["toys"] = toys_res.value

	var lights_res := _lights(source)
	if not lights_res.ok:
		return lights_res

	doc["lights"] = lights_res.value

	var spawned := _spawns(source)
	if not spawned.ok:
		return spawned

	doc["spawns"] = spawned.value
	return DotResult.success(doc)


static func _environment(source: Dictionary) -> Dictionary:
	var env := DEFAULT_ENV.duplicate(true)
	var given: Variant = source.get("environment", {})

	if given is Dictionary:
		for key: String in DEFAULT_ENV:
			if (given as Dictionary).has(key):
				var value: Variant = (given as Dictionary)[key]
				env[key] = _floats(value, 3) if DEFAULT_ENV[key] is Array else float(value)

	# The map's own fog, in metres, when it has one: absent, the map gets the horizon haze every map has.
	if given is Dictionary and (given as Dictionary).has("fog_end"):
		var g := given as Dictionary
		env["fog_colour"] = _floats(g.get("fog_colour", env["sky_horizon"]), 3)
		env["fog_start"] = maxf(float(g.get("fog_start", 0.0)), 0.0)
		env["fog_end"] = maxf(float(g["fog_end"]), env["fog_start"] + 1.0)
		env["fog_max"] = clampf(float(g.get("fog_max", 1.0)), 0.0, 1.0)
	return env


static func _spawns(source: Dictionary) -> DotResult:
	var spawns: Variant = source.get("spawns", {})
	if not (spawns is Dictionary):
		return _refuse("'spawns' is not {props, hunters}", source)

	var out_spawns := {}
	for side in ["props", "hunters"]:
		var list: Array = []
		for raw: Variant in (spawns as Dictionary).get(side, []):
			if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
				return _refuse("a %s spawn has no 'at'" % side, source)
			list.append({"at": _floats((raw as Dictionary)["at"], 3), "yaw": _r(float((raw as Dictionary).get("yaw", 0.0)))})
		if list.is_empty():
			return _refuse("no spawns for the %s" % side, source)
		if _over(list.size(), max_spawns):
			return _refuse("%d %s spawns; this server takes at most %d (max_map_spawns, 0 = no limit)" % [list.size(), side, max_spawns], source)
		out_spawns[side] = list
	return DotResult.success(out_spawns)


static func _toys(source: Dictionary) -> DotResult:
	# Toys: dot-props' DotPropBodyBox placements, `{toy, at, yaw}`. Which ids exist is the
	# catalogue's to say when the map is built (an unknown one is left out and listed), so a map
	# with a toy a newer dot-props has still plays on an older server.
	var toys: Array = []
	for raw: Variant in source.get("toys", []):
		var toy := DotPropBodyBox.normal_placement(raw)
		if toy.is_empty():
			return _refuse("toy %d is not {toy, at}" % toys.size(), source)
		toys.append(toy)

	if _over(toys.size(), max_toys):
		return _refuse("%d toys; this server takes at most %d (max_map_toys, 0 = no limit)" % [toys.size(), max_toys], source)

	return DotResult.success(toys)


static func _lights(source: Dictionary) -> DotResult:
	var lights: Array = []
	for raw: Variant in source.get("lights", []):
		if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
			return _refuse("light %d has no 'at'" % lights.size(), source)
		var light := raw as Dictionary
		lights.append({
			"at": _floats(light["at"], 3),
			"range": clampf(float(light.get("range", 8.0)), 0.5, 80.0),
			"energy": clampf(float(light.get("energy", 1.0)), 0.0, 16.0),
			"colour": _floats(light.get("colour", [1.0, 0.95, 0.85]), 3),
		})

	if _over(lights.size(), max_lights):
		return _refuse("%d lights; this server takes at most %d (max_map_lights, 0 = no limit)" % [lights.size(), max_lights], source)

	if _over(lights.size(), lights_warn):
		DotLog.warn(CHANNEL, "a map has more lights than the warning level; each one costs every frame", {
			"map": str(source.get("id", "?")), "lights": lights.size(), "warn_at": lights_warn,
		})

	return DotResult.success(lights)


static func _box(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var b := raw as Dictionary

	if not b.has("at") or not b.has("size"):
		return {}

	var size := _floats(b["size"], 3)

	if size[0] <= 0.0 or size[1] <= 0.0 or size[2] <= 0.0:
		return {}

	var mat := str(b.get("mat", "flat"))

	if not PhMaterials.has(mat):
		mat = "flat"

	var out := {"at": _floats(b["at"], 3), "size": size, "mat": mat}

	if float(b.get("yaw", 0.0)) != 0.0:
		out["yaw"] = _r(float(b["yaw"]))

	if b.has("tint"):
		out["tint"] = _floats(_colour_list(b["tint"]), 3)

	# Solid unless the map says not: water, a light's glow, a line painted on a floor.
	if b.has("solid") and not bool(b["solid"]):
		out["solid"] = false

	# Drawn unless the map says not: an invisible wall that keeps people in the map.
	if b.has("visible") and not bool(b["visible"]):
		out["visible"] = false

	return out


static func _prop(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var p := raw as Dictionary

	if not p.has("id") or not p.has("at"):
		return {}

	var out := {"id": str(p["id"]), "at": _floats(p["at"], 3)}

	for angle in ["yaw", "pitch", "roll"]:
		if float(p.get(angle, 0.0)) != 0.0:
			out[angle] = _r(float(p[angle]))

	return out


## A normalised document as bytes: JSON, deflated, behind both its lengths.
static func encode(doc: Dictionary) -> PackedByteArray:
	return DotWireDoc.encode(doc)


static func decode(bytes: PackedByteArray) -> DotResult:
	var text := DotWireDoc.decode_text(bytes, "map")
	if not text.ok:
		return text
	return parse_json(text.value, "wire")


## A short fingerprint of a document, for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return DotWireDoc.digest(doc)


static func v3(value: Variant) -> Vector3:
	if value is Vector3:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return Vector3.ZERO


static func colour(value: Variant, fallback: Color = Color.WHITE) -> Color:
	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))

	return fallback


static func _floats(value: Variant, count: int) -> Array:
	var out: Array = []

	if value is Vector3:
		value = [value.x, value.y, value.z]

	if typeof(value) == TYPE_ARRAY:
		for i in range(count):
			out.append(_r(float((value as Array)[i]) if i < (value as Array).size() else 0.0))
	else:
		for i in range(count):
			out.append(0.0)

	return out


static func _colour_list(value: Variant) -> Array:
	if typeof(value) == TYPE_STRING and Color.html_is_valid(str(value)):
		var c := Color.html(str(value))
		return [c.r, c.g, c.b]

	return value if typeof(value) == TYPE_ARRAY else [1.0, 1.0, 1.0]


## Millimetres, as a double JSON prints short.
static func _r(value: float) -> float:
	return snappedf(value, 0.001)


static func _is_id(id: String) -> bool:
	if id.is_empty() or id.length() > 48:
		return false

	for character in id:
		if not (character >= "a" and character <= "z") and not (character >= "0" and character <= "9") \
				and character != "_":
			return false

	return true


## Whether [param count] is past [param limit], where a limit of 0 or less is none.
static func _over(count: int, limit: int) -> bool:
	return limit > 0 and count > limit


## Sets the document limits from a config's `max_map_*` fields (0 = no limit). Static, so every
## document read in this process after it (catalogue, wire, tests) is held to the same.
static func apply_limits(config: Object) -> void:
	max_boxes = int(config.get("max_map_boxes"))
	max_props = int(config.get("max_map_props"))
	max_toys = int(config.get("max_map_toys"))
	max_lights = int(config.get("max_map_lights"))
	max_spawns = int(config.get("max_map_spawns"))
	lights_warn = int(config.get("map_lights_warn"))


static func _refuse(why: String, doc: Dictionary) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID, "The map is refused: %s." % why, str(doc.get("id", "?"))
	)
