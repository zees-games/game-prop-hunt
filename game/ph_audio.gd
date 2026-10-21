extends Node

const PhPaths := preload("ph_paths.gd")

## What this game makes a noise about, and the noise, on the client.
##
## [b]In a hiding game the sounds ARE the game.[/b] A taunt is the only thing that says where a
## prop is, so it is heard where the prop is, as loud as the server allows and no further; a
## prop found has a noise of its own, so a hunter in the next room knows somebody else got one;
## the hunters' release is a horn every prop hears wherever they are hiding.
##
## [b]A catalogue of ids and a table of stand-ins, which is the family's shape.[/b] dot-audio
## decides what is audible, how many at once and how far; [method sound_catalogue] is those
## decisions, naming paths under `audio/`, and [method sound_recipes] says which synthesised
## voice stands in for each until a real `.ogg` is dropped in — [DotAudioSinkGodot] consults
## the file before the stand-in.
##
## [b]Taunts are files, and they are played from the prop.[/b] They are CC0 voice lines and
## jingles in `taunts/` (see its README), listed in `taunts/taunts.json`; a taunt is an
## [AudioStreamPlayer3D] parented to the player who made it, so it moves with a prop that
## runs, and dies with one that is found.
##
## [b]Never on a server, and never deciding anything.[/b]

const CHANNEL := "ph.audio"

static var SOUND_DIR := PhPaths.rebase("res://audio")

## A round begins and the props scatter.
const HIDE := &"hide"
## The hunters are let go.
const SEEK := &"seek"
## The last seconds of hiding.
const COUNTDOWN := &"countdown"
## A prop found, somewhere. Positional.
const PROP_FOUND := &"prop_found"
## A hunter beaten by the furniture. Positional.
const HUNTER_DOWN := &"hunter_down"
## You, out. Flat.
const YOU_ARE_OUT := &"you_are_out"
const ROUND_WON := &"round_won"
const ROUND_LOST := &"round_lost"
## Becoming something, and showing your face. Positional, quiet, short: a prop that changes
## shape in front of a hunter should be heard doing it.
const DISGUISE := &"disguise"
const REVEAL := &"reveal"
## The furniture biting back.
const DECOY := &"decoy"
const WEAPON_SHOT := &"weapon_shot"
const WEAPON_SWING := &"weapon_swing"
const WEAPON_LAUNCH := &"weapon_launch"
const WEAPON_BEAM := &"weapon_beam"
const WEAPON_THROW := &"weapon_throw"
## A grenade going off.
const BLAST := &"blast"
const UI_CLICK := &"ui_click"
const UI_DENY := &"ui_deny"

var manager: DotAudioManager = null

## Everybody's footsteps by what they stand on, and the bed under the whole game: dot-audio's
## stock (Kenney's footsteps, generated beds, all CC0; the addon's stock/CREDITS.md).
var steps: DotAudioFootsteps = null
var ambience: DotAudioAmbience = null

## path -> AudioStream, the taunts loaded so far.
var _taunts: Dictionary = {}


static func ids() -> Array[StringName]:
	var out: Array[StringName] = [
		HIDE, SEEK, COUNTDOWN, PROP_FOUND, HUNTER_DOWN, YOU_ARE_OUT, ROUND_WON, ROUND_LOST,
		DISGUISE, REVEAL, DECOY, WEAPON_SHOT, WEAPON_SWING, WEAPON_LAUNCH, WEAPON_BEAM,
		WEAPON_THROW, BLAST, UI_CLICK, UI_DENY,
	]
	# A typed array plus a typed array is an untyped one: appended, not added.
	out.append_array(DotAudioStock.ids())
	return out


static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	# Footsteps and ambience beds, the family's stock.
	DotAudioStock.add_to(c)

	c.add(_flat(HIDE, &"UI", 1, 85))
	c.add(_flat(SEEK, &"UI", 1, 90))
	var beep := _flat(COUNTDOWN, &"UI", 1, 70)
	beep.cooldown_ms = 400
	c.add(beep)
	c.add(_placed(PROP_FOUND, 60.0, 10.0, 3, 70, 0.95, 1.05))
	c.add(_placed(HUNTER_DOWN, 60.0, 10.0, 3, 70, 0.95, 1.05))
	c.add(_flat(YOU_ARE_OUT, &"SFX", 1, 100))
	c.add(_flat(ROUND_WON, &"UI", 1, 80))
	c.add(_flat(ROUND_LOST, &"UI", 1, 80))
	c.add(_placed(DISGUISE, 18.0, 4.0, 3, 50, 0.9, 1.1))
	c.add(_placed(REVEAL, 18.0, 4.0, 3, 50, 0.9, 1.1))
	var decoy := _flat(DECOY, &"SFX", 1, 75)
	decoy.cooldown_ms = 120
	c.add(decoy)

	var shot := _placed(WEAPON_SHOT, 110.0, 14.0, 3, 80, 0.94, 1.06)
	shot.tags = [&"weapon"]
	c.add(shot)
	var swing := _placed(WEAPON_SWING, 30.0, 6.0, 2, 55, 0.9, 1.1)
	swing.tags = [&"weapon"]
	c.add(swing)
	var launch := _placed(WEAPON_LAUNCH, 140.0, 16.0, 2, 82, 0.95, 1.05)
	launch.tags = [&"weapon"]
	c.add(launch)
	var beam := _placed(WEAPON_BEAM, 90.0, 12.0, 1, 75, 1.0, 1.0)
	beam.cooldown_ms = 180
	beam.tags = [&"weapon"]
	c.add(beam)
	var throw := _placed(WEAPON_THROW, 40.0, 8.0, 2, 55, 0.95, 1.05)
	throw.tags = [&"weapon"]
	c.add(throw)
	# The heavy shot pitched right down (as game-arena's): the lowest thing the synthesiser makes
	# is what reads as a blast rather than a gun.
	var blast := _placed(BLAST, 140.0, 22.0, 3, 85, 0.42, 0.5)
	blast.tags = [&"weapon"]
	c.add(blast)

	var click := _flat(UI_CLICK, &"UI", 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	var deny := _flat(UI_DENY, &"UI", 1, 60)
	deny.cooldown_ms = 250
	c.add(deny)

	# A body landing: dot-player-char's stock death sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPlayerDeathSounds.rows():
		var fall := _placed(row["id"], 45.0, 8.0, 3, 50, float(row["pitch_min"]), float(row["pitch_max"]))
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.gain_db = float(row["gain_db"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		c.add(fall)

	# The map's toys: dot-props' stock toy sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPropToySounds.rows():
		var toy := _placed(row["id"], float(row["distance"]), 6.0, 3, 30, float(row["pitch_min"]), float(row["pitch_max"]))
		toy.path = row["path"]
		toy.variants = row["variants"]
		toy.gain_db = float(row["gain_db"])
		toy.cooldown_ms = int(row["cooldown_ms"])
		c.add(toy)
	return c


static func sound_recipes() -> Dictionary:
	return {
		HIDE: DotAudioSynth.Voice.SPAWN,
		SEEK: DotAudioSynth.Voice.SHOT_HEAVY,
		COUNTDOWN: DotAudioSynth.Voice.BLIP,
		PROP_FOUND: DotAudioSynth.Voice.HURT,
		HUNTER_DOWN: DotAudioSynth.Voice.HURT,
		YOU_ARE_OUT: DotAudioSynth.Voice.DIE,
		ROUND_WON: DotAudioSynth.Voice.PICKUP,
		ROUND_LOST: DotAudioSynth.Voice.DENY,
		# Becoming something is arriving as it: an upward sweep. A click (the first choice) is
		# 30 ms long, which tools/audio_probe refuses as too short to be heard as a cue.
		DISGUISE: DotAudioSynth.Voice.SPAWN,
		REVEAL: DotAudioSynth.Voice.PICKUP,
		DECOY: DotAudioSynth.Voice.HURT,
		WEAPON_SHOT: DotAudioSynth.Voice.SHOT,
		WEAPON_SWING: DotAudioSynth.Voice.STEP,
		WEAPON_LAUNCH: DotAudioSynth.Voice.SHOT_HEAVY,
		WEAPON_BEAM: DotAudioSynth.Voice.SHOT_TIGHT,
		WEAPON_THROW: DotAudioSynth.Voice.CLICK,
		BLAST: DotAudioSynth.Voice.SHOT_HEAVY,
		UI_CLICK: DotAudioSynth.Voice.CLICK,
		UI_DENY: DotAudioSynth.Voice.DENY,
		# Stand-ins only for a build without dot-props' toy files.
		DotPropToySounds.BOUNCE: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.THUMP: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.KNOCK: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PIN: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WOOD: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.RUBBER: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PUNCH: DotAudioSynth.Voice.HURT,
		DotPropToySounds.METAL: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.BELL: DotAudioSynth.Voice.PICKUP,
		DotPropToySounds.CLICK: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WATER: DotAudioSynth.Voice.STEP,
		DotPropToySounds.BOING: DotAudioSynth.Voice.SPAWN,
		DotPropToySounds.HORN: DotAudioSynth.Voice.BLIP,
		# Stand-ins only for a build without dot-player-char's files.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}


static func weapon_sound(kind: int) -> StringName:
	match kind:
		ZeeWeaponNet.KIND_SHOT:
			return WEAPON_SHOT
		ZeeWeaponNet.KIND_SWING:
			return WEAPON_SWING
		ZeeWeaponNet.KIND_SPAWN:
			return WEAPON_LAUNCH
		ZeeWeaponNet.KIND_BEAM:
			return WEAPON_BEAM
		ZeeWeaponNet.KIND_THROW:
			return WEAPON_THROW
		_:
			return &""


static func _placed(
	id: StringName, max_distance: float, unit_size: float, concurrent: int, priority: int,
	pitch_min: float, pitch_max: float
) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.kind = DotAudioDef.Kind.POSITIONAL_3D
	def.bus = &"SFX"
	def.max_distance = max_distance
	def.unit_size = unit_size
	def.max_concurrent = concurrent
	def.priority = priority
	def.pitch_min = pitch_min
	def.pitch_max = pitch_max
	return def


static func _flat(id: StringName, bus: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.bus = bus
	def.max_concurrent = concurrent
	def.priority = priority
	return def


func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	manager.register_as_service = false
	manager.voices = 24
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md): a 40 s stand-in round
	# read -20.1 LUFS integrated with the beds and the steps in. Once the stand-in turned off
	# walls (2026-10-12): -19.8 and -20.5 at +3, -18.2 twice at +6, -17.5 and -17.3 at +7.
	manager.loudness_trim_db = 7.0
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("prophunt audio")

	steps = DotAudioFootsteps.new()
	steps.name = "Footsteps"
	steps.manager = manager
	steps.default_surface = &"concrete"
	add_child(steps)
	ambience = DotAudioAmbience.new()
	ambience.name = "Ambience"
	ambience.manager = manager
	ambience.fallback_bed = &"amb_outdoor"
	add_child(ambience)
	ambience.set_map_bed(&"amb_outdoor")

	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


## Each map's bed outdoors and the ground nobody named, for a document that says neither
## (`"ambience"` and `"surface"` in a map document win). Indoors is found, not listed: see
## [method on_map_doc].
const MAP_SOUND := {
	&"ph_house": [&"amb_outdoor", &"wood"],
	&"ph_office": [&"amb_city", &"carpet"],
	&"ph_school": [&"amb_outdoor", &"concrete"],
	&"ph_woods": [&"amb_outdoor", &"grass"],
}


## A map arrived. Its bed and ground, and an indoor zone under every ceiling or roof box: the
## room tone plays where there is something over your head, which is what indoors means, and
## no map has to list its rooms twice.
func on_map_doc(id: StringName, doc: Dictionary) -> void:
	var row: Array = MAP_SOUND.get(id, [&"amb_outdoor", &"concrete"])
	on_map(StringName(str(doc.get("ambience", row[0]))), StringName(str(doc.get("surface", row[1]))))
	if ambience == null:
		return
	ambience.clear_zones()
	var indoor := StringName(str(doc.get("ambience_indoor", "amb_indoor")))
	for box: Variant in doc.get("boxes", []):
		if not (box is Dictionary) or not (str(box.get("mat", "")) in ["ceiling", "roof"]):
			continue
		var at: Array = box.get("at", [0, 0, 0])
		var size: Array = box.get("size", [0, 0, 0])
		var top := float(at[1]) + float(size[1]) * 0.5
		var low := top - 6.0
		ambience.add_zone(AABB(Vector3(float(at[0]) - float(size[0]) * 0.5, low, float(at[2]) - float(size[2]) * 0.5),
			Vector3(float(size[0]), top - low, float(size[2]))), indoor)


## Everybody this client knows steps, once a frame: players and bots alike.
func keep_walkers(bodies: Array) -> void:
	if steps != null:
		steps.keep(bodies)


## A map arrived: its bed and its ground. Empty keeps what is playing.
func on_map(bed: StringName, surface: StringName = &"") -> void:
	if ambience != null and bed != &"":
		ambience.set_map_bed(bed)
	if steps != null and surface != &"":
		steps.default_surface = surface


func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


## A taunt from [param from], which it follows. [param sound] is the path in the taunt list,
## relative to this game's root; [param range_metres] is how far it carries. Returns the player
## made, or null when there was nothing to play.
func taunt(from: Node3D, sound: String, range_metres: float) -> AudioStreamPlayer3D:
	if from == null or sound == "":
		return null

	var stream := _taunt_stream(sound)

	if stream == null:
		return null

	var voice := AudioStreamPlayer3D.new()
	voice.name = "Taunt"
	voice.stream = stream
	voice.bus = &"SFX"
	voice.max_distance = range_metres
	voice.unit_size = range_metres * 0.18
	voice.position = Vector3(0.0, 0.6, 0.0)
	from.add_child(voice)
	voice.finished.connect(voice.queue_free)

	if voice.is_inside_tree():
		voice.play()

	return voice


func _taunt_stream(sound: String) -> AudioStream:
	if _taunts.has(sound):
		return _taunts[sound]

	var path := PhPaths.rebase("res://" + sound.trim_prefix("res://"))
	var stream: AudioStream = load(path) as AudioStream if ResourceLoader.exists(path) else null

	if stream == null:
		DotLog.warn(CHANNEL, "a taunt's sound is missing", {"path": path})

	_taunts[sound] = stream
	return stream


func on_hide() -> bool:
	return _flat_play(HIDE)


func on_seek() -> bool:
	return _flat_play(SEEK)


func on_countdown() -> bool:
	return _flat_play(COUNTDOWN)


func on_death(at: Vector3, mine: bool, was_hunter: bool) -> bool:
	if mine:
		return _flat_play(YOU_ARE_OUT)

	return _at(HUNTER_DOWN if was_hunter else PROP_FOUND, at)


func on_round_end(won: bool) -> bool:
	return _flat_play(ROUND_WON if won else ROUND_LOST)


func on_disguise(at: Vector3, revealed: bool) -> bool:
	return _at(REVEAL if revealed else DISGUISE, at)


func on_decoy() -> bool:
	return _flat_play(DECOY)


func on_weapon(at: Vector3, kind: int) -> bool:
	var id := weapon_sound(kind)
	return _at(id, at) if id != &"" else false


## A grenade went off at [param at].
func on_blast(at: Vector3) -> bool:
	return _at(BLAST, at)


func click() -> bool:
	return _flat_play(UI_CLICK)


func deny() -> bool:
	return _flat_play(UI_DENY)


## A dead body's sound (dot-player-char's ragdolls), where it landed.
## A toy's sound (dot-props' toys): a bounce, a knock, where it happened.
func on_toy(id: StringName, at: Vector3, strength: float) -> bool:
	return _at(id, at, clampf(strength, 0.25, 1.0))


func on_body(id: StringName, at: Vector3, volume: float) -> bool:
	return _at(id, at, clampf(volume, 0.3, 1.0))


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


func describe() -> Dictionary:
	return {
		"ids": ids().size(),
		"taunts_loaded": _taunts.size(),
		"device": manager != null and manager.sink is DotAudioSinkGodot,
	}
