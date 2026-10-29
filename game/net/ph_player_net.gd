extends DotNetBehaviour

const PhNetCommand := preload("ph_net_command.gd")
const PhPlayer := preload("../ph_player.gd")

## What a networked player replicates: the movement state, health, weapons, and the numbers a hiding prop needs about itself.
## The movement half is dot-player-controller's [DotFpsNetSync.state_specs], not copied here; its type names are strings so the addon can describe a layout without naming dot-net.
## Disguise and side are NOT per-tick fields: they change a few times a round and travel as reliable `DISGUISE`, JOIN and TEAM events (a lost snapshot would leave a client sweeping the old capsule).

## Somebody this client is watching used their weapon, [param times] times since the last
## snapshot. What a game draws a muzzle flash from.
signal weapon_used(times: int, kind: int)

var player: PhPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Hit points, and the one field with a hard cap on the wire.
## Sent against 0..1000 rather than the player's own maximum: raising `player_health` mid-round would otherwise change what every earlier number MEANT.
var net_health: float = 100.0

## What full health is: a person's, or the prop they are. For the HUD, which shows how much a
## prop has left of what it could have.
var net_max_health: float = 100.0

## Points this match and the server's ping for the player, for everybody's Tab board.
var net_points: int = 0
var net_ping: int = 0

## How full a hiding prop's forced-taunt meter is, 0..1. Owner only: a hunter who could read
## it would know who is about to make a noise.
var net_taunt_meter: float = 0.0

## Seconds before a prop may show its face again. Owner only, for the HUD.
var net_reveal_wait: int = 0

## Sitting this round out, having joined after it started.
var net_watching: bool = false

#
# Seven fields, and the call a game should make is the pack's `ZeeWeaponNet.all_specs()`; concatenating by hand and forgetting the pack's half
# presents as weapons silent for everybody but the holder. Magazine and reserve are `owner_only`: exact ammunition is information an opponent should not have.

var net_slot: int = 0
var net_magazine: int = 0
var net_reserve: int = 0
var net_fire_seq: int = 0
var net_fire_kind: int = 0
var net_reloading: bool = false
var net_switching: bool = false


## `PhPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `PhPlayer.beacon`, or the rule's mark on the last props. Everybody's.
var net_beacon: bool = false

## Which of the two the beacon is: true for the rule's mark, false for an admin's.
var net_marked: bool = false

## `PhPlayer.warps`, four bits of it: how many times the server has put this player
## somewhere rather than moved them there. See [method _forget_the_path].
var net_warp: int = 0

## The last [member net_warp] this mirror acted on.
var _seen_warp: int = -1

## What this watcher last saw of that counter, so a wrap is read as uses rather than as a
## negative. One integer per watched player, which is what lets `ZeeWeaponNet` keep none.
var _seen_fire_seq: int = 0

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()

## And the slot they last asked for, which is simulation state for a hunter: the arsenal is
## edge-triggered against it.
var last_slot: int = 0

var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(12)
	# 14 bits, not 12: a disguise's health is a fraction, and at 12 the client drew a chair's
	# 98 as 97.9 (headless_net, "and the chair's health").
	replicate(&"net_max_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(14)
	replicate(&"net_points", DotNetVar.Type.UINT).bits(16)
	replicate(&"net_ping", DotNetVar.Type.UINT).bits(10)
	replicate(&"net_watching", DotNetVar.Type.BOOL)
	var _meter := replicate(&"net_taunt_meter", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1.0).bits(7).to_owner_only()
	var _wait := replicate(&"net_reveal_wait", DotNetVar.Type.UINT).bits(10).to_owner_only()

	for spec in ZeeWeaponNet.all_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if bool(spec["owner_only"]):
			var _owner := declaration.to_owner_only()

		# Per-player state rather than an event, so a late joiner, a lost snapshot or a re-laid field is corrected by the next snapshot where an event is missed.
		# The blind goes to its owner alone: an opponent who received it would know the moment somebody could not see.
		# No relevance change for a beacon: every player is already always relevant (`PhNetBridge`), and turning `always_relevant` off would drop the player from snapshots.
	var _blind := replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_marked", DotNetVar.Type.BOOL)
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as PhNetCommand

	if command != null:
		last_move = command.move
		last_slot = command.slot

		if player != null:
			player.wanted_slot = command.slot


## On the authority the whole game ticks as one, so the first behaviour through drives the world and the rest find it done.
## On a predicting client only the one predicted player is simulated, which is all a client may compute.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		# The prediction: the controller's own tick, with the same hull the server sweeps —
		# the disguise's, written into the tunables when the DISGUISE event arrived — and the
		# same blindfold modifier, which travels in the movement state.
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


## Authority only: what the simulation left this player as.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)

	if player.health != null:
		net_health = player.health.health
		net_max_health = player.health.max_health

	net_points = clampi(player.points, 0, 65535)
	net_ping = clampi(player.ping_ms, 0, 1023)
	net_watching = player.watching
	net_taunt_meter = player.taunt_meter
	net_reveal_wait = clampi(int(ceilf(player.reveal_wait)), 0, 1023)
	net_blind = player.blinded
	net_beacon = player.beacon or player.marked
	net_marked = player.marked and not player.beacon
	net_warp = player.warps & 0xF

	# [b]After the arsenal has simulated, which on this end it has: the whole world ticks
	# before anything is pulled.[/b] A prop has no rig and leaves these at zero, and zero is a
	# carrier holding nothing, which is true.
	if player.weapons != null:
		ZeeWeaponNet.pull(player.weapons, self)


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick
	_forget_the_path()
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

		# NOT the node, on a predicted entity: `receive_snapshot` runs BEFORE the predictor reconciles, which reads the node as "what the client is showing".
		# Moving it here makes the measured error the whole replay distance, so every snapshot reads as a snap.
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


## A teleport is not a movement, so the interpolator must not draw one.
## The server counts the times it PUT this player somewhere (`PhPlayer.place_at`); a mirror seeing it change drops the interpolator's track before the new snapshot is added,
## or a round start would show a body sweeping across the map. Not on the predicted entity: nothing interpolates that.
func _forget_the_path() -> void:
	if identity == null or identity.is_authoritative or identity.is_predicted():
		_seen_warp = net_warp
		return

	if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
		var manager: Variant = bridge.get(&"net")
		if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
			(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp


## Every frame on a remote player. Without this the interpolator's work sits in a property
## nothing reads and a remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The game half of a snapshot, on a mirror: what the server decided about this player.
func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	if player.health != null:
		player.health.max_health = maxf(net_max_health, 1.0)
		player.health.health = net_health
		player.health.alive = net_health > 0.0

	player.points = net_points
	player.ping_ms = net_ping
	player.watching = net_watching
	player.taunt_meter = net_taunt_meter
	player.reveal_wait = float(net_reveal_wait)

	player.blinded = net_blind
	# One flag on the wire for both marks, and which it is beside it: an admin's beacon and the
	# rule's are drawn in different colours.
	player.beacon = net_beacon and not net_marked
	player.marked = net_marked

	_apply_weapons()


## What a watcher does with somebody else's weapon state.
## A four-bit counter in the snapshot, never an event per shot: an RPC per shot costs a packet each and desynchronises from the state it belongs with, and a missed snapshot plays one flash instead of two.
## No world model goes to `ZeeWeaponNet.apply` (the figure is built lazily and absent on a server); the answer is written onto the player and `PhPlayer.present_body` hands it over.
func _apply_weapons() -> void:
	var answer := ZeeWeaponNet.apply(self, null, _seen_fire_seq)
	_seen_fire_seq = int(answer["seq"])

	player.mirrored = true
	player.mirror_slot = net_slot
	player.mirror_switching = net_switching
	player.mirror_fired += int(answer["fired"])
	if int(answer["fired"]) > 0:
		player.mirror_fire_kind = int(answer["kind"])

	if int(answer["fired"]) > 0:
		weapon_used.emit(int(answer["fired"]), int(answer["kind"]))
