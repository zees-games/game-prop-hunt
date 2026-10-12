extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
## See `tools/shot.sh` for the views. Any `--ph-*` is the game's own configuration.

const PhClient := preload("../game/ph_client.gd")
const PhGame := preload("../game/ph_game.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")

var _view := "hunter"
var _seconds := 3.0
var _board := false
var _out := "res://screenshots/shot.png"
var _at := Vector3.INF
var _look := Vector3.INF
var _as := &"furniture_chair"
## `--fire=N`: the hunter holds the trigger for the last N frames before the picture, so a muzzle
## flash, tracers and impacts are in it (and the counter has moved).
var _fire_frames := 0
## `--aim-prop`: the hunter faces the nearest piece of furniture (`furniture_*`, a decoy to shoot).
var _aim_prop := false
var _client: Node = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
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
		elif arg.begins_with("--fire="):
			_fire_frames = arg.trim_prefix("--fire=").to_int()
		elif arg.begins_with("--as="):
			_as = StringName(arg.trim_prefix("--as="))

	_client = PhClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	add_child(_client)
	_run.call_deferred()


static func _v3(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()) if parts.size() == 3 else Vector3.INF


func _run() -> void:
	var game: PhGame = _client.get("game")
	await _until_a_round(game)
	var local = _client.get("player")
	var hunter := _view in ["hunter", "blind"]

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
		"room":
			await _seconds_of(_seconds)
			_free_camera().look_at_from_position(_at, _look)
		"prop":
			# Hidden as something, among others of its kind, seen as its own player sees it.
			var _worn := game.disguise_as(local.player_id, _as)
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			await _seconds_of(_seconds)
		"blind":
			await _seconds_of(1.0)
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
			if _look != Vector3.INF:
				var to: Vector3 = _look - (local.eye_position() as Vector3)
				local.controller.state.yaw = rad_to_deg(atan2(-to.x, -to.z))
				local.controller.state.pitch = rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
				# The sampler writes its own look onto every command, so it is turned too.
				if local.sampler != null:
					local.sampler.yaw = local.controller.state.yaw
					local.sampler.pitch = local.controller.state.pitch
			await _seconds_of(_seconds)
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
		_client.call("_show_board", true)

	await _frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := image.save_png(path)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


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
