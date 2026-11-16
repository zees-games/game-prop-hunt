extends DotGameVisualQaCapture

## Prop Hunt's visual QA capture (docs/visual-qa.md; the loop is dot-game's docs/visual-qa.md). Three kinds of item, each recorded
## frame by frame at --fps in three views (f first person, t behind-right, o an opponent in front):
##   person_<letter>  one of the six people (PhFigure) walking, running, crouching, jumping; f is a hunter's eye a few metres in front.
##   weapon_<id>      a hunter's weapon: f is the real view model (ZeeViewModel with its arms) at the eye, t and o draw the person
##                    holding it (PhFigure.hold) through draw, fire and reload.
##   prop_<id>        a catalogue prop on a turntable, one full turn in two seconds; f is an eye scaled to the prop looking at it.
## The outside views and frame saving are dot-game's DotGameVisualQaViews, through DotGameVisualQaCapture.

const PhFigure := preload("../game/ph_figure.gd")
const PhProps := preload("../game/ph_props.gd")
const PhLoadout := preload("../game/ph_loadout.gd")

## Your own body draws only in the outside views; the view model (ZeeViewModel's view_layer 20) only in the first-person one.
const BODY_LAYER := 1 << 18
const ALL_LAYERS := 0xFFFFF
const BODY_HEIGHT := 1.8
const PERSON_CLIPS: PackedStringArray = ["idle", "walk", "run", "crouch", "jump"]
const WEAPON_CLIPS: PackedStringArray = ["idle", "draw", "fire", "reload"]
## Ground speed per person clip (metres a second): PhConfig: run_speed 6.5, walk and crouch 0.45 of it.
const PERSON_SPEED := {"idle": 0.0, "walk": 2.9, "run": 6.5, "crouch": 2.9, "jump": 2.9}
const SECONDS := {"idle": 2.0, "walk": 2.4, "run": 2.0, "crouch": 2.0, "jump": 1.6, "draw": 1.0, "fire": 2.0, "reload": 3.0, "turntable": 2.0}
## Seconds between shots in the fire clip when a weapon has no use interval; otherwise its own, as in a match.
## A faster cadence restarts a melee swing mid-follow-through, a jump no player can make.
const FIRE_EVERY := 0.5
const REAL_SIZES := "res://props/real_sizes.json"
## bone_pop limit in a fire clip whose arm swings or throws: a real strike turns the forearm about
## 1700 deg/s, so the slash moves ~111 deg in the 1/15 s window. A gun's fire clip keeps the 90 default.
const STRIKE_POP_DEG := 130.0

var _figure: PhFigure = null
var _props: PhProps = null
var _model: ZeeViewModel = null
var _prop: Node3D = null
var _prop_model: Node3D = null
var _holder := Node3D.new()
var _shown_kind := ""
var _shown_id := ""
var _shots_done := 0
var _weapon_defs := {}
var _prop_height := 1.0
var _prop_away := 2.5
var _real_sizes := {}
var _struck := false


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for letter in PhFigure.ATLASES:
		items.append("person_" + letter.get_file().get_basename().trim_prefix("texture-"))
	for id in _weapon_ids():
		items.append("weapon_" + id)
	_load_props()
	for id in _props.order:
		items.append("prop_" + String(id))
	return items


func _clips(item: String) -> PackedStringArray:
	if item.begins_with("person_"):
		return PERSON_CLIPS
	if item.begins_with("weapon_"):
		return WEAPON_CLIPS
	return PackedStringArray(["turntable"])


func _seconds(_item: String, clip: String) -> float:
	return float(SECONDS.get(clip, 2.0))


func _warmup_frames(_item: String, _clip: String) -> int:
	return 4


func _build() -> void:
	build_stage()
	first_person.cull_mask = ALL_LAYERS & ~BODY_LAYER
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	root.add_child(_holder)


func _weapon_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for def in ZeeWeaponPack.weapons():
		_weapon_defs[String(def.id)] = def
		if def.slot in PhLoadout.SLOT_FOR or def.slot == ZeeWeaponIds.SLOT_MELEE:
			ids.append(String(def.id))
	return ids


func _load_props() -> void:
	if _props == null:
		_props = PhProps.new()
		if _props.load_file() == 0:
			printerr("visual_qa: the prop catalogue would not read")
			quit(2)


func _stage(item: String, clip: String) -> DotResult:
	_clear()
	if not item.begins_with("prop_"):
		views.behind_offset = Vector3(1.6, 1.6, 3.2)
		views.behind_look_height = 1.0
		views.opponent_offset = Vector3(0.4, 1.6, -4.0)
		views.opponent_look_height = 1.3
	if item.begins_with("weapon_"):
		# Straight ahead, a held gun points down the lens and draws as a thin stick; from the gun-hand side it reads in profile.
		views.behind_offset = Vector3(2.4, 1.5, 2.2)
		views.opponent_offset = Vector3(3.0, 1.3, -2.2)
		views.opponent_look_height = 1.0
	if item.begins_with("person_"):
		_shown_kind = "person"
		_stand_person(item.trim_prefix("person_"))
		_figure.build(BODY_HEIGHT, _atlas_of(item.trim_prefix("person_")), Color(0.3, 0.45, 0.9))
	elif item.begins_with("weapon_"):
		var id := StringName(item.trim_prefix("weapon_"))
		var art: Variant = ZeeWeaponArtTable.table().get(id)
		if not (art is ZeeWeaponArt):
			return DotResult.fail(DotError.CODE_INVALID, "no art for %s" % id)
		var def: DotWeaponDef = _weapon_defs.get(String(id))
		if clip == "reload" and (def == null or not def.uses_magazine()):
			return DotResult.fail(DotError.CODE_UNSUPPORTED, "%s has no magazine" % id)
		_shown_kind = "weapon"
		_stand_person("a")
		_figure.build(BODY_HEIGHT, _atlas_of("a"), Color(0.9, 0.35, 0.3))
		_figure.hold(id, false)
		_model = ZeeViewModel.new()
		_model.name = "ViewModel"
		first_person.add_child(_model)
		_model.set_process(false)
		var equipped := _model.equip(art as ZeeWeaponArt)
		if not equipped.ok:
			return equipped
		_model.on_deploy(1.0)
		_shots_done = 0
		_struck = false
	else:
		_load_props()
		var id := StringName(item.trim_prefix("prop_"))
		if not _props.has(id):
			return DotResult.fail(DotError.CODE_INVALID, "no prop %s" % id)
		_shown_kind = "prop"
		_prop = Node3D.new()
		_holder.add_child(_prop)
		_prop_model = _props.instance(id)
		_prop.add_child(_prop_model)
		_frame_prop(_props.size_of(id))
	_shown_id = item
	return DotResult.success(clip)


## Cameras that fit the prop: a shower is 2 m tall and a pea is not, so the distance and look height follow its size.
func _frame_prop(size: Vector3) -> void:
	var reach := maxf(size.y, maxf(size.x, size.z))
	# Every term scales with the prop: a fixed margin left an apple a few pixels across in a 2 m-wide frame.
	var away := reach * 1.6
	_prop_height = size.y
	_prop_away = away
	views.behind_offset = Vector3(away * 0.45, size.y * 0.7 + reach * 0.15, away)
	views.behind_look_height = size.y * 0.5
	views.opponent_offset = Vector3(away * 0.15, size.y * 0.6 + reach * 0.15, -away)
	views.opponent_look_height = size.y * 0.5


func _stand_person(_letter: String) -> void:
	_figure = PhFigure.new()
	_figure.name = "Figure"
	_holder.add_child(_figure)
	_figure.global_position = Vector3.ZERO


func _atlas_of(letter: String) -> String:
	for path in PhFigure.ATLASES:
		if path.ends_with("texture-%s.png" % letter):
			return path
	return PhFigure.ATLASES[0]


func _clear() -> void:
	for child in _holder.get_children():
		_holder.remove_child(child)
		child.free()
	if _model != null and is_instance_valid(_model):
		first_person.remove_child(_model)
		_model.free()
	_model = null
	_figure = null
	_prop = null
	_prop_model = null


func _subject(_item: String) -> Node3D:
	return _prop if _shown_kind == "prop" else _figure


## A person stands at the origin facing -Z; the person clips move it along -Z from 4 m behind so the stage is walked, not skated on.
func _drive(item: String, clip: String, t: float, _frame: int) -> void:
	var step := 1.0 / float(fps)
	if _shown_kind == "prop":
		_prop_model.rotation.y = TAU * t / float(SECONDS["turntable"])
		return
	var speed := float(PERSON_SPEED.get(clip, 0.0))
	var airborne := false
	var vertical := 0.0
	if clip == "jump":
		# A 0.6 s hop at the start, again at 1.0 s.
		var phase := fmod(t, 1.0) / 0.6
		airborne = phase < 1.0
		vertical = 4.0 * (1.0 - 2.0 * phase) if airborne else 0.0
		_figure.global_position.y = 4.0 * 0.15 * 4.0 * phase * (1.0 - phase) if airborne else 0.0
	_figure.set_motion({"on_floor": not airborne, "vertical": vertical, "crouched": clip == "crouch",
		"sprinting": clip == "run", "aim": 0.0, "velocity": Vector3(0.0, 0.0, -speed)})
	_figure.global_position.z = -speed * t + (speed * float(SECONDS.get(clip, 2.0)) * 0.5)
	_figure.global_position.x = 0.0
	_figure.rotation = Vector3.ZERO
	_figure.person.animate(speed, step)
	if _shown_kind == "weapon":
		_drive_weapon(item, clip, t, step)


func _drive_weapon(_item: String, clip: String, t: float, step: float) -> void:
	var id := StringName(_shown_id.trim_prefix("weapon_"))
	var art := ZeeWeaponArtTable.table().get(id) as ZeeWeaponArt
	match clip:
		"draw":
			_model.on_deploy(clampf(t / 0.6, 0.0, 1.0))
			_figure.hold(id, t < 0.3)
		"fire":
			var def: DotWeaponDef = _weapon_defs.get(String(id))
			var every := _fire_interval(def)
			var due := int(floor((t - 0.2) / every)) + 1 if t >= 0.2 else 0
			while _shots_done < due:
				_shots_done += 1
				_fire(art)
		"reload":
			var def2: DotWeaponDef = _weapon_defs.get(String(id))
			if t < step:
				_model.on_reload_begin(0, def2.magazine)
			_model.on_reload(clampf(t / 2.6, 0.0, 1.0))
	_model.advance(step)


func _fire_interval(def: DotWeaponDef) -> float:
	if def == null or def.use_interval_ticks <= 0:
		return FIRE_EVERY
	var rate := def.authored_tick_rate if def.authored_tick_rate > 0 else ZeeWeaponPack.TICK_RATE
	return float(def.use_interval_ticks) / float(rate)


func _fire(art: ZeeWeaponArt) -> void:
	_struck = art.pose == ZeeWeaponArtTable.POSE_MELEE or art.pose == ZeeWeaponArtTable.POSE_THROWN
	if art.pose == ZeeWeaponArtTable.POSE_MELEE:
		_model.on_swing()
		_figure.fired(1, ZeeWeaponNet.KIND_SWING)
	elif art.pose == ZeeWeaponArtTable.POSE_THROWN:
		var outcome := DotWeaponOutcome.of(DotWeaponOutcome.KIND_THROW)
		outcome.used = true
		_model.on_used(outcome)
		_figure.fired(1, ZeeWeaponNet.KIND_THROW)
	else:
		_model.on_fired()
		_figure.fired(1, ZeeWeaponNet.KIND_SHOT)


func _grounded(_item: String, clip: String, t: float) -> bool:
	return not (clip == "jump" and fmod(t, 1.0) < 0.6)


func _before_draw(_item: String, _clip: String, _frame: int) -> void:
	if _figure != null:
		var _tagged := DotGameVisualQaViews.tag_layers(_figure, BODY_LAYER)


## Weapons: the real view model's camera at the person's eye. People and props: a hunter's eye 2.5 m in front, looking at the subject.
func _place_first_person(_item: String) -> void:
	if _shown_kind == "weapon":
		first_person.global_position = _figure.global_position + Vector3(0.0, 1.6, 0.0)
		first_person.rotation = Vector3.ZERO
		return
	var subject := _subject("")
	var height := BODY_HEIGHT if _shown_kind == "person" else _prop_height
	var away := 2.5 if _shown_kind == "person" else _prop_away
	var eye := 1.6 if _shown_kind == "person" else clampf(height * 1.4, 0.1, 1.6)
	first_person.global_position = subject.global_position + Vector3(0.0, eye, -away)
	first_person.look_at(subject.global_position + Vector3(0.0, height * 0.5, 0.0))


## Prop rows: where the model's lowest point sits against the floor, and its drawn size against the
## real-world size in props/real_sizes.json. The catalogue size is measured from the model itself, so
## comparing against it can never fail; a 0.7 m radio can only be caught by what a radio really is.
func _checks(item: String, clip: String, rows: Array[Dictionary]) -> Array[Dictionary]:
	if _shown_kind == "weapon" and clip == "fire" and _struck:
		for row: Dictionary in rows:
			if row["check"] == "bone_pop" and not row.get("skip", false):
				row["pass"] = float(row["value"]) <= STRIKE_POP_DEG
				row["limit"] = STRIKE_POP_DEG
				row["note"] = "%s (a strike or throw)" % row.get("note", "")
	if _shown_kind != "prop":
		return rows
	var box := _bounds(_prop_model)
	var floor_gap := absf(box.position.y)
	rows.append({"check": "prop_floor_m", "pass": floor_gap <= 0.03, "value": snappedf(floor_gap, 0.001), "limit": 0.03,
		"note": "lowest point above (+) or under (-) the floor: %s" % snappedf(box.position.y, 0.001)})
	var id := item.trim_prefix("prop_")
	var largest := maxf(box.size.y, maxf(box.size.x, box.size.z))
	var band := _real_band(id)
	var fits := band != Vector2.ZERO and largest >= band.x and largest <= band.y
	rows.append({"check": "prop_real_size", "pass": fits, "value": snappedf(largest, 0.01),
		"limit": "%s-%s" % [snappedf(band.x, 0.01), snappedf(band.y, 0.01)] if band != Vector2.ZERO else "none",
		"note": "largest dimension in metres against %s" % (REAL_SIZES if band != Vector2.ZERO else "no pattern in " + REAL_SIZES)})
	return rows


## The [min, max] real-world band for a prop id, from the first matching pattern; empty when none matches.
func _real_band(id: String) -> Vector2:
	if _real_sizes.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REAL_SIZES))
		if not (parsed is Dictionary) or not (parsed.get("sizes") is Dictionary):
			printerr("visual_qa: %s would not read" % REAL_SIZES)
			quit(2)
			return Vector2.ZERO
		_real_sizes = parsed
	var tolerance: Array = _real_sizes.get("tolerance", [1.0, 1.0])
	var sizes: Dictionary = _real_sizes["sizes"]
	for pattern: String in sizes:
		if not id.match(pattern):
			continue
		var real: Variant = sizes[pattern]
		if real is Array:
			return Vector2(float(real[0]), float(real[1]))
		return Vector2(float(real) * float(tolerance[0]), float(real) * float(tolerance[1]))
	return Vector2.ZERO


func _bounds(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		var m := mesh as MeshInstance3D
		var local := m.global_transform * m.get_aabb()
		box = local if first else box.merge(local)
		first = false
	return box
