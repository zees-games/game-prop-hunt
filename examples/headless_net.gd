extends Node

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

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue, so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the two claims the game rests on over a wire.[/b] First, a
## disguise is a HULL as well as a look: a prop's own client predicts itself with the prop's
## capsule, so if the client and the server disagree about what somebody is wearing, the client
## walks through a doorway the server's chair does not fit through and is pulled back every
## tick. So this asserts the hull on both ends and the two ends agreeing after a run. Second,
## the blindfold is true on the wire: a hunter's snapshots carry no prop while the props hide
## (`PhInterest`), so a client that skipped drawing the black screen would still see nothing.
## Then everything else that crosses: the map document, the sides, turning, a taunt, a joiner
## told what everybody is wearing, a decoy's charge, the result.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 16
const CHECKS := 75

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

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

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


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	print("prophunt over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_map_arrives()
		await _test_the_blindfold_is_on_the_wire()
		await _test_the_local_player_is_predicted()
		await _test_a_disguise_is_a_hull_on_both_ends()
		await _test_turning_and_taunting()
		await _test_a_joiner_is_told_what_everybody_wears()
		await _test_a_decoy_is_charged()
		await _test_the_drawn_gun_takes_the_server_count()
		await _test_a_hit_is_the_shooters()
		await _test_a_grenade_reaches_the_client()
		await _test_the_round_ends()
		await _test_the_toys_reach_the_client()
		await _test_leaving()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: a toy pulled out of the tree after a
	# mid-tick rebuild (dot-net history #30) printed `!is_inside_tree()` on green runs elsewhere.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- The codec ------------------------------------------------------------------

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := PhEvents.read_hello(DotNetReader.new(PhEvents.write_hello(SESSION, 64, 1234, 30.0, 300.0, 2.0, 60.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION
		and absf(float(hello["round_seconds"]) - 300.0) < 0.1 and absf(float(hello["hide_seconds"]) - 30.0) < 0.05
		and absf(float(hello["beacon_period"]) - 2.0) < 0.02 and absf(float(hello["taunt_range"]) - 60.0) < 0.2,
		"HELLO", str(hello))

	var doc := PhCatalogue.practice()
	var sent := PhEvents.read_map(DotNetReader.new(PhEvents.write_map(PhMapDoc.encode(doc))))
	var decoded := PhMapDoc.decode(sent["encoded"]) if bool(sent["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no map")
	_check(decoded.ok and PhMapDoc.digest(decoded.value) == PhMapDoc.digest(doc), "MAP carries the document whole")

	var join := PhEvents.read_join(DotNetReader.new(PhEvents.write_join(SESSION, 9, "Ada", PhGame.HUNTERS, null)))
	_check(bool(join["ok"]) and int(join["team"]) == PhGame.HUNTERS, "JOIN carries the side", str(join.get("team")))

	var round_info := PhEvents.read_round(DotNetReader.new(PhEvents.write_round(3, false, PhGame.PROPS, "the props held out")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == PhGame.PROPS
		and str(round_info["why"]) == "the props held out", "ROUND carries the winning side and the sentence")

	var worn := DotPropDisguise.new()
	worn.prop_id = &"furniture_chair"
	worn.size = Vector3(0.9, 1.8, 0.95)
	worn.yaw = 135.0
	worn.pitch = 15.0
	worn.locked = true
	var disguise := PhEvents.read_disguise(DotNetReader.new(PhEvents.write_disguise(SESSION, worn.to_wire(), true)))
	var back := DotPropDisguise.from_wire(disguise.get("wire", {}))
	_check(bool(disguise["ok"]) and bool(disguise["revealed"]) and back != null and back.prop_id == worn.prop_id
		and back.locked and absf(back.yaw - 135.0) < 0.5 and absf(back.pitch - 15.0) < 0.5,
		"DISGUISE carries the prop, how it is turned, the lock and the face", str(disguise))

	var taunt := PhEvents.read_taunt(DotNetReader.new(PhEvents.write_taunt(SESSION, &"laugh", true)))
	_check(bool(taunt["ok"]) and taunt["taunt_id"] == &"laugh" and bool(taunt["forced"]), "TAUNT", str(taunt))

	var decoy := PhEvents.read_decoy(DotNetReader.new(PhEvents.write_decoy(4.5)))
	_check(bool(decoy["ok"]) and absf(float(decoy["amount"]) - 4.5) < 0.1, "DECOY", str(decoy))

	var broken := PhEvents.read_broken(DotNetReader.new(PhEvents.write_broken(451, Vector3(0.0, 0.0, -1.0), true)))
	_check(bool(broken["ok"]) and int(broken["index"]) == 451 and (broken["direction"] as Vector3).distance_to(Vector3(0.0, 0.0, -1.0)) < 0.02
		and bool(broken["quiet"]), "BROKEN", str(broken))

	var thrown := DotWeaponSpawn.make(&"sticky", Vector3(12.25, 1.6, -3.5), Vector3(4.0, 6.5, -17.25), 77)
	thrown.gravity_scale = 0.8
	thrown.radius = 0.12
	thrown.fuse_ticks = 141
	thrown.life_ticks = 768
	thrown.tick = 9001
	var launch := PhEvents.read_launch(DotNetReader.new(PhEvents.write_launch(5, thrown, SESSION)))
	var again := PhEvents.spawn_from_launch(launch, 77) if bool(launch["ok"]) else null
	_check(again != null and int(launch["id"]) == 5 and again.id == &"sticky" and int(launch["thrower"]) == SESSION
		and again.origin == thrown.origin and again.velocity == thrown.velocity and is_equal_approx(again.gravity_scale, 0.8)
		and again.fuse_ticks == 141 and again.life_ticks == 768 and again.tick == 9001,
		"LAUNCH carries the grenade exactly, so a client flies the same one", str(launch))

	var turned := PhEvents.read_turn(DotNetReader.new(PhEvents.write_turn(PhGame.Turn.TILT_LEFT)))
	var asked := PhEvents.read_ask_taunt(DotNetReader.new(PhEvents.write_ask_taunt(&"whistle")))
	_check(bool(turned["ok"]) and int(turned["how"]) == PhGame.Turn.TILT_LEFT and bool(asked["ok"]) and asked["taunt_id"] == &"whistle",
		"TURN and a taunt request")

	var clock := PhEvents.read_clock(DotNetReader.new(PhEvents.write_clock(2, 12.5, 40.25, PhGame.Phase.SEEK, 3, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == PhGame.Phase.SEEK
		and absf(float(clock["seek_elapsed"]) - 40.25) < 0.1 and int(clock["props"]) == 3
		and int(clock["hunters"]) == 1, "CLOCK", str(clock))

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	# The largest MAP a reader accepts survives the event's own body cap. At 4096 a 4100-byte map
	# went out whole and was read back as no bytes, silently (hs_park with its toys).
	var biggest := PackedByteArray()
	biggest.resize(PhEvents.MAP_BYTES)
	var outgoing := PhEvent.new(PhEvents.Kind.MAP, PhEvents.write_map(biggest))
	var wire := DotNetWriter.new()
	outgoing._write(wire)
	var incoming := PhEvent.new()
	incoming._read(DotNetReader.new(wire.to_bytes()))
	var carried := PhEvents.read_map(incoming.reader())
	_check(bool(carried["ok"]) and (carried["encoded"] as PackedByteArray).size() == PhEvents.MAP_BYTES,
		"a MAP as large as a reader accepts fits in an event", "%d of %d bytes" % [(carried["encoded"] as PackedByteArray).size(), PhEvents.MAP_BYTES])

	_check(PhEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [PhEvents.Kind.size(), PhEvent.KIND_BITS])
	_check(PhRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [PhEvents.Ask.size(), PhRequest.KIND_BITS])
	_check(PhEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), PhEvents.CHAT_KIND_BITS])

	_finished()


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a map is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.map_doc.is_empty() and _client_game.catalogue == null,
		"the client has no map and reads no map files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = PhNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = PhNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.map_received.connect(func(id: StringName) -> void:
		_heard["map"] = id)
	_client_bridge.disguise_received.connect(func(who: int, revealed: bool) -> void:
		_heard["disguises"] = int(_heard.get("disguises", 0)) + 1
		_heard["disguise"] = [who, revealed])
	_client_bridge.taunt_received.connect(func(who: int, taunt_id: StringName, forced: bool) -> void:
		_heard["taunt"] = [who, taunt_id, forced])
	_client_bridge.decoy_received.connect(func(amount: float) -> void:
		_heard["decoy"] = amount)
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_check(_stand_in != null and _stand_in.is_bot, "a stand-in is seated before anybody joins")
	# Seated as a stand-in, driven by the suite: a stand-in prop hides on its own, and this
	# suite wants it where it puts it.
	_stand_in.is_bot = false

	# Started AFTER the bridge exists, which is what the module does: a map laid out before
	# anything listened to `world_rebuilt` would be a map no client is ever sent.
	_server_game.start()
	_check(not _server_game.map_doc.is_empty(), "the server lays its map out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins, and is told its side")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE, "it adopts the server's tick rate", "%d" % _client_game.tick_rate)
	_check(Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps for %d Hz" % [Engine.max_physics_steps_per_frame, SERVER_TICK_RATE])
	_check(_client_game.players.size() == 2, "it has a body for itself and for the stand-in", "%d" % _client_game.players.size())

	await _hide_with(PhGame.HUNTERS)
	_check(_client_game.team_of(_me()) == PhGame.HUNTERS and _client_game.team_of(_stand_in.player_id) == PhGame.PROPS,
		"the client knows who is hunting and who is hiding")
	_check(_client_game.phase == PhGame.Phase.HIDE, "and that the props are hiding")
	_finished()


func _test_the_map_arrives() -> void:
	_section("the map arrives, as the document the server built")
	_check(not _client_game.map_doc.is_empty(), "the client built a map")
	_check(PhMapDoc.digest(_client_game.map_doc) == PhMapDoc.digest(_server_game.map_doc),
		"the same document, to the byte", PhMapDoc.digest(_client_game.map_doc))
	_check(_client_game.map.props.size() == _server_game.map.props.size() and _client_game.map.props.size() > 0,
		"every prop in it", "%d" % _client_game.map.props.size())
	_check(_heard.has("map"), "and the client said so")
	_finished()


## The black screen is the HUD's; this is the wire's half of it.
func _test_the_blindfold_is_on_the_wire() -> void:
	_section("a hunter is told nothing about the props while they hide")
	var copy: PhPlayer = _client_game.players[_stand_in.player_id]
	var was := copy.global_position
	_stand_in.place_at(Vector3(-3.0, 0.05, -2.0), 0.0)
	await _steps(20)
	_check(copy.global_position.distance_to(was) < 0.05 and copy.global_position.distance_to(_stand_in.global_position) > 1.0,
		"the prop moved on the server and the hunter's copy did not",
		"%.2f m from where it was" % copy.global_position.distance_to(was))

	# What it became is held back too, and told the moment the seek starts.
	var heard_before := int(_heard.get("disguises", 0))
	var _hid := _server_game.disguise_as(_stand_in.player_id, &"furniture_chair")
	await _steps(4)
	_check(_stand_in.is_disguised() and int(_heard.get("disguises", 0)) == heard_before and not copy.is_disguised(),
		"nor what it became", "%d events" % (int(_heard.get("disguises", 0)) - heard_before))

	_server_game._set_phase(PhGame.Phase.SEEK)
	await _steps(20)
	_check(copy.is_disguised() and copy.disguise.prop_id == &"furniture_chair", "and is told as the seek starts")
	_check(copy.global_position.distance_to(_stand_in.global_position) < 0.3,
		"the moment the hunters are let go, the prop is where it is",
		"%.2f m apart" % copy.global_position.distance_to(_stand_in.global_position))
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("a prop is predicted, and the server agrees")
	await _hide_with(PhGame.PROPS)
	var mine := _mine()
	var server_me := _server_me()
	server_me.place_at(Vector3(-2.0, 0.05, 0.0), 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(20, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


## The claim: what a prop wears is the capsule it is predicted with, on both ends.
func _test_a_disguise_is_a_hull_on_both_ends() -> void:
	_section("a disguise is the same hull on both ends, and the run still agrees")
	var server_me := _server_me()
	server_me.place_at(LOOK_FROM, 0.0)
	await _steps(24)
	var aim := _aim_at(_mine(), CHAIR_AT + Vector3(0.0, 0.6, 0.0))
	await _steps(6, aim)

	var heard_before := int(_heard.get("disguises", 0))
	_client_bridge.ask_disguise()
	await _steps(6, aim)
	_check(server_me.is_disguised() and server_me.disguise.prop_id == &"furniture_chair",
		"asking while looking at the chair makes the server's copy a chair",
		String(server_me.disguise.prop_id) if server_me.disguise != null else "nothing")
	_check(int(_heard.get("disguises", 0)) > heard_before, "and a DISGUISE event crossed")

	var mine := _mine()
	_check(mine.is_disguised() and mine.disguise.prop_id == &"furniture_chair", "the client's own player is the chair too")
	_check(is_equal_approx(mine.controller.tunables.radius, server_me.controller.tunables.radius)
		and is_equal_approx(mine.controller.tunables.stand_height, server_me.controller.tunables.stand_height),
		"with the chair's capsule, on both ends",
		"r %.2f / %.2f, h %.2f / %.2f" % [mine.controller.tunables.radius, server_me.controller.tunables.radius,
			mine.controller.tunables.stand_height, server_me.controller.tunables.stand_height])
	_check(absf(mine.health.max_health - server_me.health.max_health) < 0.1, "and the chair's health",
		"%.1f / %.1f" % [mine.health.max_health, server_me.health.max_health])

	var back := DotFpsCommand.new()
	back.move = Vector2(-1.0, 0.0)
	back.yaw = aim.yaw
	await _steps(20, back)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "a chair that runs is where the server has it", "%.3f m" % apart)
	_finished()


func _test_turning_and_taunting() -> void:
	_section("turning and taunting are asked for, and the server's answer comes back")
	var server_me := _server_me()
	_client_bridge.ask_turn(PhGame.Turn.LOCK)
	await _steps(4)
	_check(server_me.disguise.locked and _mine().disguise.locked, "the lock is the server's, and the client is told")

	_client_bridge.ask_turn(PhGame.Turn.TILT_LEFT)
	await _steps(4)
	_check(absf(server_me.disguise.roll) > 1.0 and is_equal_approx(_mine().disguise.roll, server_me.disguise.roll),
		"a tilt lands on both ends", "roll %.1f / %.1f" % [_mine().disguise.roll, server_me.disguise.roll])

	# Paid only while the hunters are looking: into the seek, and past the cooldown of any
	# taunt the hide's checks made.
	_server_game._set_phase(PhGame.Phase.SEEK)
	await _steps(int(_server_game.config.taunt_cooldown * SERVER_TICK_RATE) + 4)
	var points := server_me.points
	_client_bridge.ask_taunt()
	await _steps(4)
	_check(_heard.has("taunt") and int(_heard["taunt"][0]) == SESSION and not bool(_heard["taunt"][2]),
		"a taunt is played, and everybody is told who and which", str(_heard.get("taunt")))
	_check(server_me.points - points == _server_game.config.taunt_points, "and is paid for",
		"+%d" % (server_me.points - points))
	_finished()


## A client that asks to be told everything again is told what everybody is wearing.
func _test_a_joiner_is_told_what_everybody_wears() -> void:
	_section("a joiner is told what everybody is wearing")
	var mine := _mine()
	_client_game.apply_disguise_wire(mine.player_id, {})
	_check(not mine.is_disguised(), "the client forgets (as a joiner never knew)")
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(4)
	_check(mine.is_disguised() and mine.disguise.prop_id == &"furniture_chair" and mine.disguise.locked,
		"and READY is answered with the chair, locked")
	_finished()


func _test_a_decoy_is_charged() -> void:
	_section("a hunter who shoots the furniture is told what it cost")
	await _hide_with(PhGame.HUNTERS)
	# Armed as a round arms its hunters: the suite moved them to this side after it began.
	_server_game._arm_hunters()
	_server_game._set_phase(PhGame.Phase.SEEK)
	await _steps(4)
	var server_me := _server_me()
	server_me.place_at(LOOK_FROM, 0.0)
	await _steps(20)
	# At the seat. The chair is its pieces now (legs, seat, back), and at 0.5 m a single ray goes
	# between the seat and the back: the shotgun's pellets caught the chair there and the SMG,
	# the hunters' first gun since the loadout stopped putting both in slot 3, did not.
	var aim := _aim_at(_mine(), CHAIR_AT + Vector3(0.0, 0.35, 0.0))
	await _steps(6, aim)
	var health := server_me.health.health
	var fire := _aim_at(_mine(), CHAIR_AT + Vector3(0.0, 0.35, 0.0))
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(SERVER_TICK_RATE * 2, fire)
	await _steps(6, aim)
	_check(server_me.health.health < health, "the server charged them for shooting a chair",
		"%.1f -> %.1f, holding %s" % [health, server_me.health.health,
			String(server_me.weapons.arsenal.current_def().id) if server_me.weapons != null and server_me.weapons.arsenal.current_def() != null else "nothing"])
	_check(_heard.has("decoy") and float(_heard["decoy"]) > 0.0, "and the client was told, for its flash",
		str(_heard.get("decoy")))

	# A breakable piece the server breaks is broken on the client too.
	var index := -1
	for i in range(_server_game.map.props.size()):
		if _server_game.props_catalogue.breaks(_server_game.map.prop_id(i)) > 0.0:
			index = i
			break
	var piece: Dictionary = _server_game.map.props[index]
	var shot := DotShot.new()
	shot.damage = 10000.0
	shot.direction = Vector3(0.0, 0.0, -1.0)
	shot.impacts.append((piece["transform"] as Transform3D).origin + Vector3(0.0, (piece["size"] as Vector3).y * 0.5, 0.0))
	_server_game._break_furniture(shot)
	await _steps(6)
	_check(bool(_server_game.map.props[index]["broken"]) and bool(_client_game.map.props[index]["broken"]),
		"furniture the server breaks is broken on the client", String(_server_game.map.prop_id(index)))
	_finished()


## A connected hunter's drawn gun takes the server's ammunition count, read from the owner-only
## snapshot fields, once it has gone quiet.
##
## [b]The online half of `PhClient.correct_drawn`, which only the offline half had a check for[/b]
## (headless_run reads the world's rig). A real PhClient, not in the tree so it builds no netcode
## of its own, is handed this suite's client bridge and draws its gun the way `_on_armed` does.
## The server's count is set apart from the drawn one, as a refused shot or a refill leaves it.
## Armed: with the online branch of `_server_count` returning nothing, or `correct_drawn` not
## writing, the last checks fail.
func _test_the_drawn_gun_takes_the_server_count() -> void:
	_section("a connected hunter's drawn gun takes the server's ammunition count")
	var server_me := _server_me()
	var server_rig: ZeeWeaponRig = server_me.weapons
	var server_def := server_rig.current_def() if server_rig != null else null
	var armed := server_def != null and server_def.uses_magazine() and _mine() != null
	_check(armed, "the server's hunter holds a gun with a magazine (from the section before)")
	if not armed:
		_finished()
		return

	# The server's count, apart from anything a fresh drawn gun holds: a magazine part spent and
	# a reserve the client never saw. Snapshots carry it to the owner only.
	var magazine := maxi(server_def.magazine / 3, 1)
	var reserve := 41
	server_rig.arsenal.current().magazine = magazine
	server_rig.arsenal.ammo().set_count(server_def.ammo_type, reserve)
	await _steps(SNAPSHOT_RATE)

	var client: Node = PhClient.new()
	var camera := Camera3D.new()
	_client_game.get_parent().add_child(camera)
	client.set(&"_offline", false)
	client.set(&"bridge", _client_bridge)
	client.set(&"_watch_id", SESSION)
	client.set(&"game", _client_game)
	client.set(&"player", _mine())
	client.set(&"camera", camera)
	client.call(&"_arm_locally", server_def.id)
	var drawn: ZeeWeaponRig = client.get(&"weapons")
	# Drawn as `_net_physics` would: the slot the arming picked, until the switch is over.
	var command := DotWeaponCommand.new()
	command.slot = int(client.get(&"_slot"))
	for i in range(SERVER_TICK_RATE):
		if drawn == null or (drawn.arsenal.current_slot() == command.slot and not drawn.arsenal.is_switching()):
			break
		var _o := drawn.simulate_tick(command, _tick + i)

	var source: Dictionary = client.call(&"_server_count")
	_check(drawn != null and drawn.current_def() != null and drawn.current_def().id == server_def.id
		and drawn.arsenal.current().magazine == server_def.magazine,
		"the client draws the server's gun, full, as a fresh drawn gun is",
		"%s %d" % [String(drawn.current_def().id) if drawn != null and drawn.current_def() != null else "-",
			drawn.arsenal.current().magazine if drawn != null and drawn.arsenal.current() != null else -1])
	_check(_client_bridge._behaviours.get(SESSION) is PhPlayerNet and int(source.get("magazine", -1)) == magazine
		and int(source.get("reserve", -1)) == reserve and int(source.get("slot", -1)) == server_def.slot,
		"its server count is the owner-only snapshot fields", str(source))

	client.set(&"_drawn_quiet", 0.0)
	var early: bool = client.call(&"correct_drawn")
	_check(not early and drawn.arsenal.current().magazine == server_def.magazine,
		"not corrected while a shot could still be in flight")

	client.set(&"_drawn_quiet", PhClient.DRAWN_SETTLE_SEC)
	var corrected: bool = client.call(&"correct_drawn")
	_check(corrected and drawn.arsenal.current().magazine == magazine
		and drawn.arsenal.ammo().count(server_def.ammo_type) == reserve,
		"once quiet, the drawn gun takes the server's magazine and reserve",
		"drawn %d / %d, server %d / %d" % [drawn.arsenal.current().magazine,
			drawn.arsenal.ammo().count(server_def.ammo_type), magazine, reserve])

	client.call(&"_disarm_locally")
	camera.queue_free()
	client.free()
	await _steps(2)
	_finished()


## The hit marker's wire half (`PhGame.hit_landed` → HIT → `hit_received`); `headless_run` only
## proves the offline half, where the world's own signal flashes the marker. A hunter shoots the
## hiding stand-in point-blank. Armed: with the bridge's HIT send removed the first check fails;
## sent with `_broadcast` the second does.
func _test_a_hit_is_the_shooters() -> void:
	_section("a hunter's shot that lands is told to the hunter alone")
	var server_me := _server_me()
	var hits: Array = []
	var heard := func(point: Vector3, killed: bool, headshot: bool) -> void:
		hits.append([point, killed, headshot])
	_client_bridge.hit_received.connect(heard)

	# A second connected player, READY, so a HIT that went to everybody would reach somebody.
	var _seated := _server_bridge.add_player(BYSTANDER_PEER, BYSTANDER_SESSION, "Bo")
	_server_bridge._admit(BYSTANDER_PEER)

	# The prop two and a half metres in front of the hunter, in the open, and hit but never
	# killed: a kill would end the round this suite's next section ends itself.
	server_me.place_at(LOOK_FROM, 0.0)
	_stand_in.place_at(LOOK_FROM + Vector3(0.0, 0.0, -2.5), 0.0)
	var target_health := _server_game.combat.health_of(_stand_in.entity_id)
	target_health.cannot_die = true
	var aim := _aim_at(_mine(), _stand_in.global_position + Vector3(0.0, 0.4, 0.0))
	await _steps(SERVER_TICK_RATE, aim)
	_sent_events.clear()
	_listening = true

	var fire := _aim_at(_mine(), _stand_in.global_position + Vector3(0.0, 0.4, 0.0))
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(4, fire)
	await _steps(INPUT_LEAD + 6, aim)

	var to_shooter := _events_of(PhEvents.Kind.HIT, CLIENT_PEER)
	_check(not hits.is_empty() and to_shooter > 0, "the hunter's bridge is told the shot landed",
		"%d heard, %d sent to the hunter, holding %s" % [hits.size(), to_shooter,
			String(server_me.weapons.current_def().id) if server_me.weapons != null and server_me.weapons.current_def() != null else "nothing"])
	var elsewhere := _events_of(PhEvents.Kind.HIT, BYSTANDER_PEER) + _events_of(PhEvents.Kind.HIT, 0)
	_check(elsewhere == 0, "and nobody else is: no HIT to the other player, none broadcast", "%d" % elsewhere)
	_check(not hits.is_empty() and (hits[0][0] as Vector3).distance_to(_stand_in.global_position) < 2.5,
		"at the server's point, on the prop that was hit",
		"%s, body at %s" % [str(hits[0][0]) if not hits.is_empty() else "-", str(_stand_in.global_position)])

	# Hit back: the hunter the victim, and a victim is told nothing.
	hits.clear()
	_sent_events.clear()
	var shot_back := DotShot.new()
	shot_back.attacker = _stand_in.entity_id
	var wound := DotDamage.make(_stand_in.entity_id, server_me.entity_id, 1.0, null)
	wound.health_lost = 1.0
	wound.point = server_me.global_position + Vector3.UP
	shot_back.damages.append(wound)
	_server_game._note_hits(_stand_in, shot_back)
	await _steps(4, aim)
	_check(hits.is_empty() and _events_of(PhEvents.Kind.HIT, CLIENT_PEER) == 0,
		"a hit somebody else landed on this player is not this player's marker", "%d" % hits.size())

	_listening = false
	target_health.cannot_die = false
	_client_bridge.hit_received.disconnect(heard)
	_server_bridge.remove_peer(BYSTANDER_PEER)
	await _steps(2)
	_finished()


## A grenade over the wire: one LAUNCH to everybody, and the client's copy flies where the
## server's does and goes off where it does, which is what draws the burst there. Armed: with
## the bridge's LAUNCH send removed, or the client's copies never ticked, the checks fail.
func _test_a_grenade_reaches_the_client() -> void:
	_section("a hunter's grenade is told to everybody once, and flown on the client as on the server")
	var server_me := _server_me()
	var drawn: Array = []
	var heard := func(at: Vector3, _weapon: StringName) -> void: drawn.append(at)
	_client_game.blast_drawn.connect(heard)
	var server_blasts: Array = []
	var went := func(at: Vector3, _spawn: DotWeaponSpawn) -> void: server_blasts.append(at)
	_server_game.projectiles.detonated.connect(went)
	_sent_events.clear()
	_listening = true

	# Lobbed across the open garden, well clear of everybody, a second's fuse and a small blast.
	var spawn := DotWeaponSpawn.make(&"frag", Vector3(13.0, 1.5, -1.0), Vector3(3.0, 3.0, 0.5), server_me.entity_id)
	spawn.gravity_scale = 1.0
	spawn.radius = 0.12
	spawn.fuse_ticks = SERVER_TICK_RATE
	spawn.life_ticks = SERVER_TICK_RATE * 4
	spawn.splash_radius = 1.5
	spawn.splash_damage = 1.0
	var flying: RefCounted = _server_game.projectiles.launch(spawn)
	await _steps(12)
	var copies: Array = _client_game.projectiles.flying()
	var copy: RefCounted = copies[0] if not copies.is_empty() else null
	var owned := copy != null and (copy.get(&"spawn") as DotWeaponSpawn).owner_entity == _mine().entity_id
	_check(_events_of(PhEvents.Kind.LAUNCH, CLIENT_PEER) == 1 and copy != null and int(copy.get(&"id")) == int(flying.get(&"id")) and owned,
		"one LAUNCH to every ready player, and the client flies a copy of that grenade, owned by its own number for the thrower",
		"%d sent, %d copies" % [_events_of(PhEvents.Kind.LAUNCH, CLIENT_PEER), copies.size()])
	var apart := (copy.get(&"position") as Vector3).distance_to(flying.get(&"position") as Vector3) if copy != null else INF
	_check(apart < 0.01, "where the server's is, tick for tick", "%.4f m apart" % apart)

	await _steps(SERVER_TICK_RATE)
	_check(_server_game.projectiles.live_count() == 0 and _client_game.projectiles.live_count() == 0
		and server_blasts.size() == 1 and drawn.size() == 1 and (drawn[0] as Vector3).distance_to(server_blasts[0] as Vector3) < 0.05,
		"and it goes off where the server's did, which draws the burst there",
		"%d server blasts, %d drawn, %s / %s" % [server_blasts.size(), drawn.size(), str(server_blasts), str(drawn)])

	_listening = false
	_client_game.blast_drawn.disconnect(heard)
	_server_game.projectiles.detonated.disconnect(went)
	await _steps(2)
	_finished()


## How many events of [param kind] the server sent to [param peer_id] (0: broadcast).
func _events_of(kind: int, peer_id: int) -> int:
	var count := 0
	for sent: Array in _sent_events:
		if int(sent[0]) == peer_id and int(sent[1]) == kind:
			count += 1
	return count


func _test_the_round_ends() -> void:
	_section("the round ends, and the client is told who won and why")
	var damage := DotDamage.make(_server_me().entity_id, _stand_in.entity_id, 10000.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == PhGame.HUNTERS,
		"the hunters won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]) != "", "with the server's own sentence",
		str(_heard.get("round_over")))
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(_me()), "the server lets them go")
	_check(_server_bridge.describe()["ready_peers"] == 0, "and stops talking to them")
	_finished()


# --- Helpers --------------------------------------------------------------------

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


## The garden's toys over the wire: paired by index on both ends, frozen copies; a ball kicked
## during the hide is not sent to a hunter (a ball rolling off where a prop walked would be that
## prop), and once the seek starts the hunter sees where it went.
func _test_the_toys_reach_the_client() -> void:
	_section("the garden's toys reach the client, and not a hunter during the hide")
	await _hide_with(PhGame.HUNTERS)
	var count := _server_game.map.toys.count()
	_check(count > 0 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every toy is an entity on both ends, paired by index", "%d toys, %d and %d" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])
	var server_ball := _server_game.map.toys.toy(0)
	var client_ball := _client_game.map.toys.toy(0)
	_check(client_ball.body.freeze and not client_ball.authoritative, "the client's are frozen copies")
	var start := client_ball.body.global_position
	var _kicked := _server_game.map.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(-1, 0.2, 0), 2.0)
	await _steps(60)
	_check(client_ball.body.global_position.distance_to(start) < 0.05 and server_ball.body.global_position.distance_to(start) > 1.0,
		"during the hide a hunter's client is not told the ball moved",
		"client %.2f m, server %.2f m" % [client_ball.body.global_position.distance_to(start), server_ball.body.global_position.distance_to(start)])
	_server_game._set_phase(PhGame.Phase.SEEK)
	await _steps(40)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(apart < 0.6, "and in the seek it is where the server's is", "%.2f m apart" % apart)
	_finished()


## Into a fresh round's hide, with the client on [param side] and the stand-in on the other,
## everybody put back where the round puts them and wearing nothing.
func _hide_with(side: int) -> void:
	for _i in range(SERVER_TICK_RATE * 10):
		if _server_game.phase == PhGame.Phase.HIDE:
			break
		await _step()

	var other := PhGame.PROPS if side == PhGame.HUNTERS else PhGame.HUNTERS
	_server_game._set_side(_me(), side)
	_server_game._set_side(_stand_in.player_id, other)
	_server_game._set_phase(PhGame.Phase.HIDE)
	_server_game._place_everybody()
	await _steps(8)


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


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out
