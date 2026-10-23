extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
## See `tools/shot.sh` for the views. Any `--ph-*` is the game's own configuration.

const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhClient := preload("../game/ph_client.gd")
const PhGame := preload("../game/ph_game.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")
const PhPlayer := preload("../game/ph_player.gd")
const ShotOutline := preload("shot_outline.gd")

var _view := "hunter"
var _seconds := 3.0
var _board := false
var _lean := 0
var _out := "res://screenshots/shot.png"
var _at := Vector3.INF
var _look := Vector3.INF
var _as := &"furniture_chair"
## `--view=dead`: who is killed in front of the camera, `hunter` (a person) or `prop` (in `--as`).
var _victim := "hunter"
## `--fire=N`: the hunter holds the trigger for the last N frames before the picture, so a muzzle
## flash, tracers and impacts are in it (and the counter has moved).
var _fire_frames := 0
## `--aim-prop`: the hunter faces the nearest piece of furniture (`furniture_*`, a decoy to shoot).
var _aim_prop := false
var _client: Node = null
## --aim: the Aim key held for the frame (down the sights; a scope through a scoped gun).
var _aim := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg.begins_with("--lean="):
			_lean = arg.trim_prefix("--lean=").to_int()
		elif arg == "--board":
			_board = true
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--at="):
			_at = _v3(arg.trim_prefix("--at="))
		elif arg.begins_with("--look="):
			_look = _v3(arg.trim_prefix("--look="))
		elif arg == "--aim-prop":
			_aim_prop = true
		elif arg == "--aim":
			_aim = true
		elif arg.begins_with("--fire="):
			_fire_frames = arg.trim_prefix("--fire=").to_int()
		elif arg.begins_with("--victim="):
			_victim = arg.trim_prefix("--victim=")
		elif arg.begins_with("--as="):
			_as = StringName(arg.trim_prefix("--as="))

	if _view == "maps":
		_subscribe_fixture()

	_client = PhClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	_client.set("remember_loadout", false)
	add_child(_client)
	# --view=cover: the loading cover dot-game's DotGameClient puts up first, before it lifts.
	if _view == "cover":
		for _i in 2:
			await RenderingServer.frame_post_draw
		var platform: DotGameClient = _client.get("platform")
		print("cover %s" % ("lifted" if platform.is_shown() else "up"))
		var cover_path := ProjectSettings.globalize_path(_out)
		DirAccess.make_dir_recursive_absolute(cover_path.get_base_dir())
		print("saved %s: %s" % [_out, error_string(_client.get_viewport().get_texture().get_image().save_png(cover_path))])
		get_tree().quit(0)
		return
	_run.call_deferred()


## --view=maps: a fixture map pack in the shared [DotContentIndex], as the solo shell leaves
## one after a subscribed pack mounts, so the M menu shows what a player would see. The pack's
## map is the practice house under another name, written to user://.
func _subscribe_fixture() -> void:
	var dir := "user://ws_shot_ph/"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc := PhCatalogue.practice().duplicate(true)
	doc["id"] = "fixture_barn"
	doc["name"] = "Fixture Barn"
	doc["blurb"] = "From the Workshop."
	var file := FileAccess.open(dir + "barn.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(doc))
	file.close()
	var index := DotContentIndex.shared()
	index.set_session(DotContentIndex.SESSION_SOLO)
	var _added := index.add_pack({
		"content_id": "fixture/barns", "version": "1.0.0", "prefix": dir,
		"session": DotContentIndex.SESSION_SOLO, "source": &"subscription",
		"provides": {"schema": 1, "title": "Hilltop Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "fixture_barn", "name": "Fixture Barn", "scene": "barn.json", "map_kind": "prophunt"},
			{"kind": "map", "id": "fixture_run", "name": "Fixture Run", "scene": "barn.json", "map_kind": "surf"},
		]},
	})


static func _v3(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()) if parts.size() == 3 else Vector3.INF


func _run() -> void:
	var game: PhGame = _client.get("game")
	await _until_a_round(game)
	var local = _client.get("player")
	var hunter := _view in ["hunter", "blind", "round", "loadout", "grenade", "killcam"]

	# The person at this keyboard on the side the view is about; one stand-in on the other.
	var other_side_drawn := false
	for id: StringName in game.players:
		var side := PhGame.PROPS
		if game.players[id] == local:
			side = PhGame.HUNTERS if hunter else PhGame.PROPS
		elif hunter == false and not other_side_drawn:
			side = PhGame.HUNTERS
			other_side_drawn = true
		game._set_side(id, side)

	if _view == "round":
		# Everybody else hides, as stand-ins do: the round plays on its own clock.
		for id: StringName in game.players:
			if game.players[id] != local:
				game._set_side(id, PhGame.PROPS)
	game._place_everybody()
	game._arm_hunters()
	game._set_phase(PhGame.Phase.HIDE)
	_client.call("_follow_side")

	match _view:
		"overview":
			await _frames(6)
			var box: AABB = game.map.bounds()
			var centre := box.get_center()
			var reach := maxf(box.size.length() * 0.42, 14.0)
			_free_camera().look_at_from_position(centre + Vector3(reach * 0.45, reach * 0.6, reach * 0.55), centre)
		"spots":
			# The map's annotations the stand-ins and hunters use, drawn over it from above.
			for _i in range(900):
				if game.bots.annotations != null:
					break
				await _frames(1)
			if game.bots.annotations == null:
				print("the bots made no annotations (ph_bot_nav 0, or no stand-in to drive)")
			else:
				var debug := DotNpcAiNavDebug.new()
				game.map.add_child(debug)
				debug.show_annotations(game.bots.annotations)
			await _frames(6)
			var sbox: AABB = game.map.bounds()
			var sreach := maxf(sbox.size.length() * 0.42, 14.0)
			_free_camera().look_at_from_position(sbox.get_center() + Vector3(sreach * 0.1, sreach * 0.9, sreach * 0.1), sbox.get_center())
		"room":
			await _seconds_of(_seconds)
			_free_camera().look_at_from_position(_at, _look)
		"prop":
			# Hidden as something, among others of its kind, seen as its own player sees it.
			var _worn := game.disguise_as(local.player_id, _as)
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			# Leant forward this many steps (6 is on its side, 12 on its nose at 15 degrees a step).
			for _i in range(_lean):
				var _turned := game.turn(local.player_id, PhGame.Turn.TILT_FORWARD)
			await _seconds_of(_seconds)
		"killcam":
			# The last hider found, then the round decided; --seconds is how long after: ~2 is
			# the replay, ~9 the winner reveal.
			game._set_phase(PhGame.Phase.SEEK)
			var prey: PhPlayer = null
			for id: StringName in game.players:
				if game.players[id] != local:
					prey = game.players[id]
					break
			var ahead: Vector3 = local.controller.state.position + Vector3(0.0, 0.0, -3.0)
			prey.place_at(ahead, 180.0)
			var _dressed := game.disguise_as(prey.player_id, _as)
			await _seconds_of(4.0)
			var found := DotDamage.make(local.entity_id, prey.entity_id, prey.health.max_health * 10.0, null)
			found.tick = game._tick
			var _hit: Variant = game.combat.apply_damage(found)
			game._decide(PhGame.HUNTERS, "the hunters found every prop")
			await _seconds_of(_seconds)
		"dead":
			# Somebody killed in front of a free camera and [member _seconds] of what follows: a
			# hunter falls as a ragdoll, a disguised prop (`--victim=prop --as=<id>`) bursts, or
			# topples under `--ph-prop-death=1`.
			game._set_phase(PhGame.Phase.SEEK)
			var victim: PhPlayer = null
			for id: StringName in game.players:
				var p: PhPlayer = game.players[id]
				if p != local and (game.team_of(id) == PhGame.HUNTERS) == (_victim == "hunter"):
					victim = p
					break
			if victim == null:
				print("nobody on that side to kill")
				get_tree().quit(1)
				return
			var feet: Vector3 = local.controller.state.position + Vector3(0.0, 0.0, -3.0)
			if _at != Vector3.INF:
				feet = _at
			victim.place_at(feet, 180.0)
			if _victim == "prop":
				var _worn := game.disguise_as(victim.player_id, _as)
			# You out of the frame, behind the camera.
			local.place_at(feet + Vector3(0.0, 0.0, 8.0), 0.0)
			await _seconds_of(0.4)
			feet = victim.controller.state.position
			var camera := _free_camera()
			camera.look_at_from_position(feet + Vector3(1.9, 1.3, 1.7), feet + Vector3(0.0, 0.4, 0.0))
			var slay := DotDamage.make(0, victim.entity_id, victim.health.max_health * 10.0, null)
			slay.tick = game._tick
			slay.direction = (feet - camera.global_position) * Vector3(1, 0, 1)
			var _applied: Variant = game.combat.apply_damage(slay)
			print("killed %s (%s) at %s: %s" % [victim.display_name, _victim, feet.snapped(Vector3.ONE * 0.1),
				victim.death.describe() if victim.death != null else "no fall"])
			await _seconds_of(_seconds)
			var yard: DotPlayerRagdolls = _client.get("ragdolls")
			for body: DotPlayerRagdoll in yard.live():
				print("body: %s, centre %s" % [body.describe(), body.centre().snapped(Vector3.ONE * 0.01)])
		"person":
			# Somebody else as everybody else sees them: a hunter stand-in three metres in front
			# of a free camera, with the movement capsule (green) and the hitboxes (red) drawn
			# over the body, to compare the hull against what is drawn.
			game._set_phase(PhGame.Phase.SEEK)
			var other: PhPlayer = null
			for id: StringName in game.players:
				if game.players[id] != local:
					other = game.players[id]
					game._set_side(id, PhGame.HUNTERS)
					break
			var feet: Vector3 = local.controller.state.position + Vector3(0.0, 0.0, -3.0)
			if _at != Vector3.INF:
				feet = _at
			other.place_at(feet, 150.0)
			local.place_at(feet + Vector3(0.0, 0.0, 8.0), 0.0)
			await _seconds_of(maxf(_seconds, 0.6))
			feet = other.controller.state.position
			_free_camera().look_at_from_position(feet + Vector3(1.6, 1.2, 2.4), feet + Vector3(0.0, 0.9, 0.0))
			# A stand-in keeps playing, so the shapes follow it every frame up to the picture.
			var drawn: Array[Node] = []
			var follow := func() -> void:
				for shape in drawn:
					shape.queue_free()
				drawn.clear()
				drawn.append(ShotOutline.hull(self, other.controller.state.position,
					other.controller.tunables.radius, other.hull_height()))
				for box: DotHitbox in other.hitboxes.get_children():
					if box.enabled:
						drawn.append(ShotOutline.hitbox(self, box))
			follow.call()
			get_tree().process_frame.connect(follow)
			print("person: %s; hull r=%.2f h=%.2f" % [other.figure.describe() if other.figure != null else "no figure",
				other.controller.tunables.radius, other.hull_height()])
		"blind":
			await _seconds_of(1.0)
		"grenade":
			# A frag from the hunter's hand, in slot five: in flight after [member _seconds] of game
			# time, or just after its burst if the fuse runs out first (the fuse is a second here).
			# Slowed, because a software renderer draws a few frames a second.
			game._set_phase(PhGame.Phase.SEEK)
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			_face(local, _look)
			var _armed := game.arm(local, &"frag")
			local.wanted_slot = ZeeWeaponIds.SLOT_THROWN
			_client.set("_slot", ZeeWeaponIds.SLOT_THROWN)
			await _seconds_of(1.0)
			Engine.time_scale = 0.2
			var tuning := ZeeWeaponPack.catalogue().get_def(&"frag").tuning as DotWeaponBallistics
			var forward: Vector3 = local.aim_direction()
			var spawn := DotWeaponSpawn.make(&"frag", local.eye_position() + forward * 0.6,
				forward * tuning.speed * 0.55 + Vector3.UP * 2.5, local.entity_id)
			spawn.gravity_scale = tuning.gravity_scale
			spawn.radius = tuning.radius
			spawn.fuse_ticks = game.tick_rate
			spawn.life_ticks = game.tick_rate * 4
			spawn.splash_radius = tuning.splash_radius
			spawn.splash_damage = tuning.splash_damage
			spawn.damage_type = tuning.damage_type
			var went: Array = []
			game.blast_drawn.connect(func(at: Vector3, _weapon: StringName) -> void: went.append(at))
			var thrown: RefCounted = game.projectiles.launch(spawn)
			while went.is_empty() and int(thrown.get(&"age_ticks")) < int(_seconds * game.tick_rate):
				await _frames(1)
			if not went.is_empty():
				await _frames(3)
			print("grenade: %s" % ("went off at %s" % str((went[0] as Vector3).snapped(Vector3.ONE * 0.1)) if not went.is_empty()
				else "in flight at %s, %d ticks" % [str((thrown.get(&"position") as Vector3).snapped(Vector3.ONE * 0.1)), int(thrown.get(&"age_ticks"))]))
		"maps":
			# M: the solo map list, with the Workshop's map among the game's own.
			await _seconds_of(0.5)
			var settings: Object = _client.get("settings")
			var menu: Variant = settings.get("menu")
			menu.call(&"open_maps")
			var picker: Variant = menu.get("picker")
			if picker != null:
				# Past the last row and back one: the fixture sorts after the shipped maps' ids.
				var rows := game.map_rows()
				for i in range(rows.size()):
					if str(rows[i]["id"]) == "fixture_barn":
						picker.call(&"turn", 99)
						picker.call(&"turn", i - rows.size() + 1)
			await _seconds_of(_seconds)
		"loadout":
			# B in the hide, blindfolded, when a choice goes straight into the hands.
			await _seconds_of(0.5)
			var menu: Variant = _client.get("loadout_menu")
			if menu == null:
				print("no loadout menu on this host")
			else:
				await menu.call(&"open")
				await _seconds_of(_seconds)
		"round":
			# A round in progress: the stand-ins hide on the round's own clock, then the seek
			# runs [code]--seconds[/code]; from the hunter's eyes, or from [code]--at[/code].
			while game.phase != PhGame.Phase.SEEK:
				await _frames(1)
			await _seconds_of(_seconds)
			for id: StringName in game.players:
				var who: PhPlayer = game.players[id]
				print("  %s %s at %s as %s" % [id, "hunter" if game.team_of(id) == PhGame.HUNTERS else "prop",
					who.controller.state.position.snapped(Vector3.ONE * 0.1), who.disguise.prop_id if who.is_disguised() else "-"])
			if _at != Vector3.INF:
				_free_camera().look_at_from_position(_at, _look)
		"hunter":
			game._set_phase(PhGame.Phase.SEEK)
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			if _aim_prop and game.map != null:
				var eye: Vector3 = local.eye_position()
				var best := INF
				for prop: Dictionary in game.map.props:
					var frame: Transform3D = prop["transform"]
					var middle := frame.origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
					var far := middle.distance_to(eye)
					if far > 2.5 and far < best and String(prop["id"]).begins_with("furniture"):
						best = far
						_look = middle
			_face(local, _look)
			await _seconds_of(_seconds)
			if _aim:
				# The pointer is never captured under xvfb; the client aims only while it is.
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_client.set("_aiming", true)
				await _seconds_of(0.8)
				var hud: Node = _client.get("hud")
				var camera: Camera3D = _client.get("camera")
				print("aimed: crosshair %.2f scope %.2f fov %.1f" % [(hud.get("_crosshair") as Control).modulate.a,
					float((hud.get("scope") as Control).get("fraction")), camera.fov])
			# Still held when the picture is taken: a flash lasts a few frames.
			# Slowed, because a software renderer draws a few frames a second and a flash lasts a
			# few hundredths of one: at full speed every flash was over before a frame was drawn.
			if _fire_frames > 0:
				Engine.time_scale = 0.08
				_client.set("_firing", true)
				await _frames(_fire_frames)
		_:
			await _seconds_of(_seconds)

	if _board:
		var menu: Variant = _client.get("settings").menu
		var tab := InputEventKey.new()
		tab.physical_keycode = KEY_TAB
		tab.pressed = true
		menu.handle_event(tab)

	await _frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := image.save_png(path)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


## Turns [param local] to look at [param look] (nothing when it is unset).
func _face(local: PhPlayer, look: Vector3) -> void:
	if look == Vector3.INF:
		return
	var to: Vector3 = look - local.eye_position()
	local.controller.state.yaw = rad_to_deg(atan2(-to.x, -to.z))
	local.controller.state.pitch = rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
	# The sampler writes its own look onto every command, so it is turned too.
	if local.sampler != null:
		local.sampler.yaw = local.controller.state.yaw
		local.sampler.pitch = local.controller.state.pitch


func _until_a_round(game: PhGame) -> void:
	for _i in range(900):
		if game.phase != PhGame.Phase.IDLE and _client.get("player") != null:
			return
		await get_tree().process_frame


func _free_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 75.0
	add_child(camera)
	camera.current = true
	# The HUD is the round's; a free camera is looking at the map.
	var hud: CanvasLayer = _client.get("hud")
	if hud != null:
		hud.visible = false
	return camera


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds_of(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
