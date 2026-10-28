extends DotGameCheckSuite

## Shared constants, state and the two-world wiring for headless_net.gd.

const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhEvents := preload("../game/net/ph_events.gd")
const PhGame := preload("../game/ph_game.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")
const PhNetBridge := preload("../game/net/ph_net_bridge.gd")
const PhPlayer := preload("../game/ph_player.gd")
const PhEvent := preload("../game/net/ph_event.gd")
const PhRequest := preload("../game/net/ph_request.gd")
const PhClient := preload("../game/ph_client.gd")
const PhPlayerNet := preload("../game/net/ph_player_net.gd")

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3
## A connected player who must hear nothing of somebody else's hit.
const BYSTANDER_PEER := 8
const BYSTANDER_SESSION := 43

## The practice house's kitchen chair, and a spot west of it to stand and look at it from.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)
const LOOK_FROM := Vector3(1.6, 0.05, 1.2)

var _sections_entered := 0
var _sections_finished := 0

var _server_game: PhGame = null
var _client_game: PhGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: PhNetBridge = null
var _client_bridge: PhNetBridge = null
var _stand_in: PhPlayer = null

var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0
## Every event the server sent while a section listens: `[peer_id, kind]`.
var _sent_events: Array = []
var _listening := false

## What the client was told, by kind, so a section can ask whether an event arrived.
var _heard: Dictionary = {}

func _me() -> StringName:
	return PhNetBridge.player_key(SESSION)


func _mine() -> PhPlayer:
	return _client_game.players.get(_me())


func _server_me() -> PhPlayer:
	return _server_game.players[_me()]


## A command that looks from [param player]'s eye at [param target].
func _aim_at(player: PhPlayer, target: Vector3) -> DotFpsCommand:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	return command


func _make_game(server: bool, parent: Node) -> PhGame:
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.hide_seconds = 60.0
	config.minimum_players = 0
	config.keep_progress = false
	config.auto_taunt_seconds = 0.0
	config.map_ids = PackedStringArray(["ph_practice"])

	var game := PhGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = PhGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	# Only while a section listens: a decode on the client's registry counts what it skips.
	if method == &"event" and _listening:
		var decoded := _client_net.messages.decode(DotNetReader.new(payload), 1, false)
		if decoded.ok and decoded.value is PhEvent:
			_sent_events.append([peer_id, (decoded.value as PhEvent).kind])

	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1
