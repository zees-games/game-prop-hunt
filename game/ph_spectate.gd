extends DotSpectatorHost

const PhPlayer := preload("ph_player.gd")

## Where somebody who is out looks, and what the server lets them see: [DotSpectatorHost] with this game's numbers.
## No delay: every client already receives every player's live position, so one would hide nothing. No `class_name`; reached by preload from [PhGame], which hands it two dictionaries so there is no cycle.

const CHANNEL := "ph.spectate"

## How far above the floor a faller's death camera hangs, looking straight down the drop.
## A fall is recorded at the kill height, where nothing is worth seeing, so the camera goes back up over the point they left.
const DROP_CAM_RISE := 6.0

## player id -> PhPlayer. The world's own dictionary, shared rather than copied, so a join is visible here the moment the world has it.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}

## [member PhConfig.spectate_camera], applied when the rules are built.
var force_camera: int = 0


func _init() -> void:
	death_cam_seconds = 1.5
	freeze_cam_seconds = 1.5
	chase_distance = 4.6
	chase_height = 1.2
	history_seconds = 0.0
	eye_height = 0.0
	prefer_own_side = true
	guard_roam = true
	fixed_index_fn = func(_key: String) -> int: return 0


func _channel() -> String:
	return CHANNEL


func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	r.force_camera = clampi(force_camera, 0, 2)
	# Dead players stay dead until the next round, so a list including them would be bodies at the kill height.
	r.cycle_includes_dead = false
	r.delay_ticks = 0
	return r


## Somebody is out. Starts the death camera; the server's tick hands it over.
## [param at] is where they died; a fall is recorded at the kill height, so the camera is moved back up ([constant DROP_CAM_RISE]).
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	death(String(player_id), where, String(by), tick)


## The HUD line, with the free-camera key named only while the server offers one.
func line_for(key: String) -> String:
	if not is_spectating(key):
		return ""

	var view := manager.view(key)
	var roam_hint := ("   %s: free camera" % roam_key) if roam_key != "" and can_roam(key) else ""

	match view.mode:
		DotSpectatorView.Mode.ROAMING:
			return "free camera   WASD move   Space / Ctrl up and down   Shift fast   Alt slow   %s: back to the players" % (
				roam_key if roam_key != "" else "click"
			)
		DotSpectatorView.Mode.DEATH_CAM:
			return "you are out"
		DotSpectatorView.Mode.FREEZE_CAM:
			return "shot by %s" % _name_of(view.target)
		DotSpectatorView.Mode.FIXED:
			return "nobody left to watch"
		DotSpectatorView.Mode.CHASE:
			return "watching %s  (behind)   click: next   F5: their eyes%s" % [_name_of(view.target), roam_hint]
		_:
			return "watching %s   click: next   F5: behind them%s" % [_name_of(view.target), roam_hint]


func _name_of(key: String) -> String:
	var body: PhPlayer = players.get(StringName(key))
	return body.display_name if body != null else key


func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _team_of(key: String) -> int:
	return int(sides.get(StringName(key), 0))


func _is_alive(key: String) -> bool:
	var body: PhPlayer = players.get(StringName(key))
	# Somebody in the gallery is up and is not in the fight; a camera on them is a camera on a wall of other spectators.
	return body != null and is_instance_valid(body) and body.is_alive() and not body.watching


## Where somebody's eyes are, from where this process DRAWS them.
## The drawn position, not the node, on a world that simulates: a node moves once a tick, so a camera hung on it jitters. A mirror's remote players are written every frame by the interpolator, so there the node is right, and a rider's controller is not simulated.
func _pose_of(key: String) -> Transform3D:
	var body: PhPlayer = players.get(StringName(key))

	if body == null or not is_instance_valid(body) or body.controller == null:
		return Transform3D.IDENTITY

	var at := body.global_position

	if authoritative:
		at = body.controller.render_state().position

	var state := body.controller.state
	# A prop's eyes are near the top of what it is, not a person's height above the floor.
	var eye := body.eye_position() - state.position
	return eye_pose(at + eye, state.pitch, state.yaw)
