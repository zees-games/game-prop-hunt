extends Node

## The cameras and bodies the first play test caught, in the real offline game:
##
## - the third-person and spectator chase cameras flown round the start and every
##   checkpoint of the course (dot-core's DotCameraCheck): never inside, armed by the
##   unprotected camera being in or behind the course on some frames;
## - `mp_forceview` through the view key's path (no `mp_solidplayers` here: a disguised
##   player is the shape of their prop);
## - with `--render`, that moment from the player's eyes before (pass-through, no fade) and
##   after, and both views.
##
##   tools/camera_check.sh            # headless; exit 1 on a failure
##   tools/camera_check.sh --render   # and the frames, in screenshots/cameras/

const PhClient := preload("../game/ph_client.gd")
const PhGame := preload("../game/ph_game.gd")
const PhPlayer := preload("../game/ph_player.gd")

var _client: Node = null
var _render := false
var _failed := false


func _ready() -> void:
	_render = OS.get_cmdline_user_args().has("--render")
	_client = PhClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	var game: PhGame = _client.get("game")
	await _seconds(1.5)
	# Drawn first, inside the warmup: once the round starts a hunter is blindfolded and the
	# frame is black.
	if _render:
		await _views(game)

	_fly(game)
	# The view rule through the key's own path.
	_client.third_person = false
	_client.toggle_view()
	_check(_client.third_person, "the view key goes to third person")
	game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	_check(not _client.third_person, "mp_forceview 1 puts the camera back on the eye")
	_client.toggle_view()
	_check(not _client.third_person, "and the key does nothing")
	game.view_rules.force_view = DotPlayerViewRules.ANY

	print("%s" % ("all passed" if not _failed else "FAILED"))
	get_tree().quit(1 if _failed else 0)


func _fly(game: PhGame) -> void:
	# Beside every wall, tree and piece of furniture of the house: found, not listed.
	var mask: int = _client.game.physics.layer_mask(&"world") | _client.game.physics.layer_mask(&"prop")
	var pivots := DotCameraCheck.pivots_near_walls(_client.get_viewport().world_3d, AABB(Vector3(-80, -10, -80), Vector3(160, 40, 160)), mask, 1.6, 2.5, 3.0, 50)
	var world := _client.get_viewport().world_3d
	var cases := {
		"third_person": Vector3(0.0, PhClient.CHASE_UP, PhClient.CHASE_BACK),
		"chase": Vector3(0.0, 1.2, 4.6),
	}
	for name in cases:
		var total := {}
		for pivot in pivots:
			total = DotCameraCheck.add(total, DotCameraCheck.fly(world, DotCameraCheck.orbit_path(pivot), cases[name], mask))
		_check(DotCameraCheck.passed(total), "%s round %d places in the house: %s" % [name, pivots.size(), DotCameraCheck.summary(total)])


func _views(game: PhGame) -> void:
	DirAccess.make_dir_recursive_absolute("screenshots/cameras")
	var me: PhPlayer = _client.get("player")
	var fade: DotCameraFade = _client.get("_fade")
	var camera: Camera3D = _client.get("camera")

	_client.third_person = false
	_client.call("_place_camera")
	await _seconds(0.15)
	await _shot("prophunt_view_first")
	_client.third_person = true
	_client.call("_place_camera")
	await _seconds(0.3)
	await _shot("prophunt_view_third")


	# The walk-in, in first person, inside the warmup (a hunter is blindfolded once the
	# round starts): somebody on the player's eye, before the fade and after it.
	_client.third_person = false
	_client.call("_place_camera")
	var bot: PhPlayer = null
	for id in game.players:
		var other: PhPlayer = game.players[id]
		if other != me and other.visible and other.figure != null and other.figure.visible:
			bot = other
			break
	if bot != null:
		var figures: Callable = fade.bodies_fn
		fade.bodies_fn = Callable()
		await _held_in_front(bot, me, camera, "prophunt_walk_in_before")
		fade.bodies_fn = figures
		await _held_in_front(bot, me, camera, "prophunt_walk_in_after")


func _held_in_front(bot: PhPlayer, me: PhPlayer, camera: Camera3D, file: String) -> void:
	var ahead := -camera.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized()
	for i in 6:
		bot.controller.teleport(me.controller.state.position + ahead * 0.35, rad_to_deg(atan2(ahead.x, ahead.z)))
		bot.global_position = bot.controller.state.position
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _shot(file: String) -> void:
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout
