extends Node

const PhEvent := preload("ph_event.gd")
const PhEvents := preload("ph_events.gd")
const PhNetCommand := preload("ph_net_command.gd")
const PhNetLink := preload("ph_net_link.gd")
const PhPlayerNet := preload("ph_player_net.gd")
const PhToyNet := preload("ph_toy_net.gd")
const PhInterest := preload("ph_interest.gd")
const PhRequest := preload("ph_request.gd")

const PhGame := preload("../ph_game.gd")
const PhMapDoc := preload("../ph_map_doc.gd")
const PhPlayer := preload("../ph_player.gd")

## Joins a [PhGame] to a [DotNetManager]: the netcode seam, and the only file that names both.
## Usage: attach(game, net), open_link(...), then server_tick / client_tick; see the dot-game netcode.
## The game's tick is whole-world while dot-net ticks per entity; [method ensure_game_ticked] reconciles them.

const CHANNEL := "ph.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands per input packet: this tick's and the four before it, so one lost ENet packet costs no tick.
## Measured in game-arena: 80% of ticks right at 20% loss with one copy, 99-100% with three, five closed the rest.
const INPUT_COPIES := 5

## How often the round clock and its numbers go out, in ticks (twice a second).
## They change only when somebody is found or a second passes; the client advances the clock between messages.
const CLOCK_EVERY := 32

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)

## Somebody joined, left or changed sides. Client side; the HUD and a scoreboard read it.
signal roster_changed(player_id: int)

## A round began or ended. [param why] is the server's sentence about who won.
signal round_changed(number: int, began: bool, winner: int, why: String)

## The round changed half. Client side.
signal phase_received(phase: int)

## Somebody died, and what did it.
signal death_received(player_id: int, by: int, why: StringName)

## Somebody was handed, or picked up, a weapon. The HUD names it.
signal armed_received(player_id: int, weapon_id: StringName)
## Your shot landed (see [signal PhGame.hit_landed]); only ever to the shooter.
signal hit_received(point: Vector3, killed: bool, headshot: bool)

signal notice_received(text: String)

## Client side: the server moved this client's own camera. [param mode] is
## [enum DotSpectatorView.Mode]; the view has already been adopted by the world's mirror.
signal spectate_received(viewer: int, mode: int, target: int)

## Client side: somebody else used their weapon [param times] times since the last
## snapshot. [param kind] is one of `ZeeWeaponNet.KIND_*`. Relayed from that player's own
## behaviour, because a client builds those one per JOIN and nothing else could find them.
signal weapon_used_by(session_id: int, times: int, kind: int)

## Client side: the map was rebuilt from what the server sent. The HUD names it.
signal map_received(map_id: StringName)

## Client side: somebody's disguise changed. [param revealed] says they took a prop off to
## show their face.
signal disguise_received(player_id: int, revealed: bool)

## Client side: somebody taunted.
signal taunt_received(player_id: int, taunt_id: StringName, forced: bool)

## Client side: this client's hunter shot the furniture and paid [param amount] for it.
signal decoy_received(amount: float)

## Somebody pressed Enter. Server side; the bridge carries chat and decides nothing about it.
## Who may say what is [DotChatRouter]'s, in the services layer.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker, from the peer id below.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## Client side: one routed line, and one voice frame.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)

var game: PhGame = null
var net: DotNetManager = null
var link: PhNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns the link's length in milliseconds ([method DotClientLink.ping_ms]).
## Fed nothing, the clock assumes an instant link and every command is stamped for a tick already simulated, then discarded as late.
var rtt_source: Callable = Callable()

## Where a voice frame goes on the server. Assigned by [DotGameModule] to the services
## layer's `relay_voice`, because the bridge is the only thing that names both ends.
var voice_relay_fn: Callable = Callable()

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked once as they are
## seated. Assigned by the module, which is what has the identity layer; unset, or answering
## null, is the stock person, which is what everybody was before there was one.
var avatar_fn: Callable = Callable()

var _entities: Node = null

## session id -> [PhPlayerNet].
var _behaviours: Dictionary = {}

## The next session id for somebody the world made itself, well above anything dot-server issues.
## A player id is `u<session>` and a name like `bot` parses back to session ZERO, so two bots would share an entry and dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Carries the game's profile runtime over this manager; null when the types would not register.
var profile_link: DotNetProfileLink = null
## Server: peers whose READY came before their seat ([method add_player]), admitted when seated.
## Over lossy ENet READY can overtake `loaded`, and dropping it left that client waiting for a world for ever.
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether [method DotNetManager.server_tick] is on the stack, and the net ids released during it.
## An entity released mid-tick would leak a lag-compensation track, because `server_tick` still holds the identity list it took earlier.
## The ids are forgotten again here once the manager lets go of that list.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The map the clients were last sent, so a late joiner is sent the same bytes.
var _map_body: PackedByteArray = PackedByteArray()



func _exit_tree() -> void:
	# The link and the runtime hold each other through broadcast; left, both outlive the process's exit.
	if profile_link != null:
		profile_link.release()
		profile_link = null


## [param p_game] and [param p_net], in the shape [DotGameNetcode] calls it.
func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as PhGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a world and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world=%s net.is_server=%s" % [world.authoritative, p_net.is_server]
		)

	game = world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	net.send_fn = _send

	var event := net.messages.register(
		PhEvent.NAME, PhEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		PhRequest.NAME, PhRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(PhEvent.NAME, _on_event)
	net.messages.on(PhRequest.NAME, _on_request)

	# Edited profiles reach every client, so a remote admin's panel shows what the server holds; edits themselves go through the remote workbench.
	profile_link = DotNetProfileLink.attach(net, world.ensure_runtime())

	# Both ends. The server's tick is `server_tick` and the client's is `client_tick`, which
	# simulates what it predicts and leaves the rest to interpolation. A world still running
	# its own `_physics_process` would move every player twice.
	game.external_tick = true

	# The map's toys: the server's leave the registry before their nodes go and the new ones are
	# named after MAP; a client's mirrors stay registered and are handed this end's toys when
	# its map is built.
	if net.is_server:
		game.world_clearing.connect(_release_toys)
	else:
		game.world_clearing.connect(_unpair_toys)
		game.world_rebuilt.connect(_pair_pending_toys)

	if net.is_server:
		# See [PhInterest]: no prop in a hunter's snapshot while the props hide.
		var interest := PhInterest.new()
		interest.game = game
		net.interest = interest

		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.world_rebuilt.connect(_on_world_rebuilt)
		game.round_began.connect(_on_round_began)
		game.round_over.connect(_on_round_over)
		game.phase_changed.connect(_on_phase_changed)
		game.player_died.connect(_on_player_died)
		game.side_changed.connect(func(id: StringName, side: int) -> void:
			_broadcast(PhEvents.Kind.TEAM, PhEvents.write_team(session_of(id), side))
		)
		game.disguise_changed.connect(_on_disguise_changed)
		game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
			_broadcast(PhEvents.Kind.TAUNT, PhEvents.write_taunt(session_of(id), taunt_id, forced)))
		# Here and not in the module: the net suite has no module, and mg-deathrun found a handout
		# wired there that reached nobody in it.
		game.player_armed.connect(announce_armed)
		# To the shooter alone: a hit marker is that player's business.
		game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
			var hit_peer := peer_for_player(session_of(id))
			if hit_peer > 0:
				_tell(hit_peer, PhEvents.Kind.HIT, PhEvents.write_hit(point, killed, headshot)))
		# To the one who asked or paid, never broadcast: a refusal is that person's business, and
		# what a decoy cost a hunter tells everybody else where they are standing.
		game.refused.connect(func(id: StringName, why: String) -> void:
			var peer_id := peer_for_player(session_of(id))
			if peer_id > 0:
				notice(peer_id, why))
		# Everybody: a bottle shot to bits is a bottle gone for everybody, and its debris is
		# what tells a hunter across the room that somebody is shooting there.
		game.prop_broken.connect(func(index: int, direction: Vector3) -> void:
			_broadcast(PhEvents.Kind.BROKEN, PhEvents.write_broken(index, direction, false)))
		game.decoy_hit.connect(func(id: StringName, amount: float) -> void:
			var peer_id := peer_for_player(session_of(id))
			if peer_id > 0:
				_tell(peer_id, PhEvents.Kind.DECOY, PhEvents.write_decoy(amount)))
		# Everybody: a grenade in the air is everybody's business, and the throw is all a client
		# needs to fly the same one. Hunters throw only in the seek, so nothing here crosses the
		# blindfold.
		if game.projectiles != null:
			game.projectiles.launched.connect(func(f: RefCounted) -> void:
				var spawn: DotWeaponSpawn = f.get(&"spawn")
				var thrower := session_of(game.entities.key_for_id(spawn.owner_entity))
				_broadcast(PhEvents.Kind.LAUNCH, PhEvents.write_launch(int(f.get(&"id")), spawn, thrower)))

		if game.spectate != null:
			game.spectate.view_changed.connect(_on_spectate_changed)

		_wire_lag_compensation()

	return DotResult.success(true)


## Hands dot-combat the rewind and restore callables that make lag compensation real.
## Unset, dot-combat resolves every shot against the present while the flag claims it is on; dot-net already records the history.
## The shooter is not excluded: `resolve_shot` fixes `shot.origin` before rewinding, and self damage is refused separately.
func _wire_lag_compensation() -> void:
	if game.combat == null or net == null:
		return

	if game.combat.config != null:
		game.combat.config.lag_compensation = true

	game.combat.rewind_fn = func(target_tick: float) -> void:
		var _rewound := net.history.rewind(
			net.registry.all(), int(target_tick), net.clock.tick
		)

	game.combat.restore_fn = func() -> int:
		return net.history.restore()

	DotLog.debug(CHANNEL, "lag compensation is wired to the netcode's history", {
		"max_rewind_ms": game.combat.config.max_rewind_ms if game.combat.config != null else 0.0,
	})


## Opens the link under [param parent], whose NAME is half the RPC routing.
## Godot routes an RPC by node path, so a link opened elsewhere sends every message nowhere, with no error.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = PhNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link has to sit under `Server` (RPCs route by path) but must
	# die with this bridge. A bare add_child left a second link after every module reload, and
	# Godot renamed the live one `@Node@n`, so RPCs to real clients were silently lost.
	DotGameLink.attach(link, parent, self, PhNetLink.NODE_NAME)


## How every dot-net message reaches a peer, routed by DELIVERY rather than kind.
## Snapshots are unreliable; everything else is reliable, as an event on the server or a request on the client.
## Sending all as events silently drops every client request.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)



static func player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))



## Puts a connected peer into the game. What [DotGameRoster] calls.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	if peer_id > 0:
		# FIRST, because `game.add_player` emits `player_added` and the handler has to be
		# able to find which peer this player belongs to.
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	var player := game.add_player(player_key(session_id), display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


## Somebody the world drives itself: a stand-in, or a test's player.
## The same entity a peer gets with peer id zero; replicated, scored and crushed like a person, minus a socket.
func add_bot(display_name: String, team: int = 0) -> PhPlayer:
	if net == null or not net.is_server or game == null:
		return null

	var session_id := _next_bot_session
	_next_bot_session += 1

	var player := game.add_player(player_key(session_id), display_name, team)

	if player == null:
		return null

	player.is_bot = true
	return player


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)

	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, and `_on_player_removed`
	# would then release and broadcast the LEAVE a second time. Releasing first empties `_behaviours`,
	# so that handler finds nothing and this stays the one place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)

		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(PhEvents.Kind.LEAVE, PhEvents.write_player(session_id))
	roster_changed.emit(session_id)


func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	# Every id on the wire is `u<session>` and anything else parses back to zero, which is also dot-net's broadcast address.
	# A second player called `bot` would silently replace the first in this table, so it is refused with a line.
	if player_key(session_id) != id:
		DotLog.warn(CHANNEL, "a player whose id is not a session key is not replicated", {
			"id": String(id), "hint": "use add_bot() or PhNetBridge.player_key()",
		})
		return

	var player: PhPlayer = game.players.get(id)

	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	# Before the JOIN, so the first thing anybody hears about this person is their face.
	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	_broadcast(PhEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)

	if _behaviours.has(session_id):
		# The game removed them itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(PhEvents.Kind.LEAVE, PhEvents.write_player(session_id))
		roster_changed.emit(session_id)


func _build_entity(player: PhPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: [DotNetIdentity] collects behaviours in
	# `_ready` by walking the subtree, and one added afterwards would never be found.
	var behaviour := PhPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys, and a prop dashing for a cupboard would arrive a
	# round trip after the hunter turned the corner.
	identity.authority = DotNetIdentity.Authority.SHARED
	# [b]Relevant to everybody, except a prop to a hunter while the props hide[/b] — see
	# [PhInterest]. Not `always_relevant`, which bypasses the rule; and nothing lingers, or the
	# first second of the hide would still be sent.
	identity.always_relevant = false
	identity.interest_linger_sec = 0.0
	player.add_child(identity)

	var session_id := session_of(player.player_id)
	_behaviours[session_id] = behaviour

	# Only ever emitted on a mirror, where the snapshot is what says a weapon was used.
	behaviour.weapon_used.connect(func(times: int, kind: int) -> void:
		weapon_used_by.emit(session_id, times, kind)
	)
	return identity


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


func _release_entity(session_id: int) -> void:
	var behaviour: PhPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	_unregister(behaviour.identity.net_id)



## A new map: the whole document, to everybody, before anything that stands on it.
func _on_world_rebuilt() -> void:
	if net == null or not net.is_server or game.map == null or game.map.doc.is_empty():
		return

	var encoded := PhMapDoc.encode(game.map.doc)

	if encoded.size() > PhMapDoc.WIRE_LIMIT:
		# Sent anyway: a client on a native transport will take it, and the line says why a
		# browser does not. A WebSocket message past its outbound buffer is never delivered.
		DotLog.warn(CHANNEL, "a map is larger than a browser can be sent in one message", {
			"map": String(game.map.id()), "bytes": encoded.size(), "limit": PhMapDoc.WIRE_LIMIT,
		})

	_map_body = PhEvents.write_map(encoded)
	_broadcast(PhEvents.Kind.MAP, _map_body)
	_register_toys()


## What somebody is hiding as, for the wire.
func _disguise_body(id: StringName) -> PackedByteArray:
	var player: PhPlayer = game.players.get(id)

	if player == null:
		return PackedByteArray()

	return PhEvents.write_disguise(
		session_of(id),
		player.disguise.to_wire() if player.is_disguised() else {},
		player.set_aside != null and not player.is_disguised()
	)



func _on_round_began(number: int, _layout_id: StringName) -> void:
	_broadcast(PhEvents.Kind.ROUND, PhEvents.write_round(number, true, 0))


func _on_round_over(number: int, winner: int, why: String) -> void:
	_broadcast(PhEvents.Kind.ROUND, PhEvents.write_round(number, false, winner, why))


func _on_phase_changed(phase: int) -> void:
	_broadcast(PhEvents.Kind.PHASE, PhEvents.write_phase(phase))

	# The hunters were told nothing about what anybody became while they were blindfolded;
	# they are told everything now, after the PHASE, so their client is seeking when it hears.
	if phase == PhGame.Phase.SEEK:
		for peer_id in _ready_peers.keys():
			if _is_hunter_peer(int(peer_id)):
				_tell_every_disguise(int(peer_id))


## What somebody became, to everybody who may know it, and not to a hunter while the props hide.
## [PhInterest] hides where props are then; a DISGUISE would still tell the hunter WHAT everybody is.
## Held back until the seek starts and sent by [method _on_phase_changed].
func _on_disguise_changed(id: StringName) -> void:
	var body := _disguise_body(id)

	for peer_id in _ready_peers.keys():
		if not (game.phase == PhGame.Phase.HIDE and _is_hunter_peer(int(peer_id))):
			_tell(int(peer_id), PhEvents.Kind.DISGUISE, body)


func _is_hunter_peer(peer_id: int) -> bool:
	return game.team_of(player_key(player_for_peer(peer_id))) == PhGame.HUNTERS


## Every disguise there is, to one peer: a joiner, or a hunter whose blindfold just came off.
func _tell_every_disguise(peer_id: int) -> void:
	for other in _behaviours.keys():
		var id := player_key(int(other))
		var player: PhPlayer = game.players.get(id)
		if player != null and (player.is_disguised() or player.set_aside != null):
			_tell(peer_id, PhEvents.Kind.DISGUISE, _disguise_body(id))


func _on_player_died(player_id: StringName, by: StringName, why: StringName) -> void:
	var who: PhPlayer = game.players.get(player_id) if game != null else null
	_broadcast(PhEvents.Kind.DEATH, PhEvents.write_death(
		session_of(player_id), session_of(by) if by != &"" else 0, why,
		who.death if who != null else null
	))


## A view changed on the server, told to its owner and nobody else.
## Who somebody watches is private; a stand-in (peer zero) is told nothing, which `_tell` guarantees.
func _on_spectate_changed(player_id: StringName) -> void:
	if game == null or game.spectate == null or game.spectate.manager == null:
		return

	var session_id := session_of(player_id)
	var peer_id := peer_for_player(session_id)

	if peer_id <= 0 or not _ready_peers.has(peer_id):
		return

	var view := game.spectate.manager.view(String(player_id))
	var target := session_of(StringName(view.target)) if view.target != "" else 0
	var killer := session_of(StringName(view.killer)) if view.killer != "" else 0

	_tell(peer_id, PhEvents.Kind.SPECTATE, PhEvents.write_spectate(
		session_id, int(view.mode), target, killer, view.death_position
	))


## Says what somebody was handed.
func announce_armed(player_id: StringName, weapon_id: StringName) -> void:
	_broadcast(PhEvents.Kind.ARMED, PhEvents.write_armed(session_of(player_id), weapon_id))



func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		_in_server_tick = true
		net.server_tick(tick)
		_in_server_tick = false

		for net_id in _unregistered_in_tick:
			if not net.registry.has(net_id):
				net.history.forget(net_id)

		_unregistered_in_tick.clear()

	# Belt and braces: `net.server_tick` drives the entities and the first player behaviour calls `ensure_game_ticked`.
	# With nobody connected there are no behaviours, and a world that only ticked with players would stop the round clock between them.
	ensure_game_ticked(tick)

	if tick % CLOCK_EVERY == 0:
		_broadcast(PhEvents.Kind.CLOCK, _clock_body())


func _clock_body() -> PackedByteArray:
	return PhEvents.write_clock(
		game.round_number,
		game.phase_elapsed,
		game.seek_elapsed,
		game.phase,
		game.alive_on(PhGame.PROPS),
		game.alive_on(PhGame.HUNTERS),
		game.sides_are_playable()
	)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: PhPlayerNet = _behaviours[session_id]

		# Only what a peer sent. A bot has no peer and is driven by the game itself, and an
		# empty command applied over the top of that would stand it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())
			behaviour.player.wanted_slot = behaviour.last_slot

	game.tick_once(tick)

	# The toys where the physics left them, before the snapshot.
	for behaviour: PhToyNet in _toy_nets:
		behaviour.pull()


func client_tick(tick: int, command: DotFpsCommand, slot: int = 0) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := PhNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	packet.slot = slot

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from `last_move` on a fresh tick and on a replayed one alike —
	# the predictor's replay sets it through `_net_apply_input`, and this is the fresh tick's
	# equivalent.
	var mine: PhPlayerNet = _behaviours.get(local_player_id)

	if mine != null:
		mine.last_move = packet.move
		mine.last_slot = slot

		if mine.player != null:
			mine.player.wanted_slot = slot

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# One predicted player, and nothing else: everybody else is drawn from snapshots.
	if _client_ticked_for != tick:
		_client_ticked_for = tick

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())

		# The grenades the server announced, flown here as copies (they decide nothing).
		if game.projectiles != null:
			game.projectiles.tick(net.clock.tick_duration())

		# The clock a client shows, advanced between the twice-a-second messages that
		# correct it. Without this the round timer ticks in half-second steps.
		game.phase_elapsed += net.clock.tick_duration()

		if game.phase == PhGame.Phase.SEEK:
			game.seek_elapsed += net.clock.tick_duration()



func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return PhNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


## Text for one player: a refusal, a rate limit, a command's reply.
## Sent to the one person who asked; a broadcast refusal would be a punishment announced to everybody.
func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, PhEvents.Kind.NOTICE, PhEvents.write_notice(text))


## One routed line to one peer. What [DotGameServices] sends through, via the link.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, PhEvents.Kind.CHAT, PhEvents.write_chat(wire))


## A voice frame, in whichever direction. Not a [PhEvent].
## Voice is fifty packets a second and every event is reliable, so a talk spurt would queue ahead of a taunt.
## It also bypasses [DotNetManager], whose sealed message set gains nothing from an opaque blob; [DotVoicePacket] has its own header.
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody puts
			# a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		# One path or the other, never both: [DotGameModule] assigns `voice_relay_fn` to the services layer's `relay_voice`.
		# Also connecting `voice_requested` to the same router would relay every frame twice, doubling the rate limit and
		# sending the jitter buffer's sequence number backwards.
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
		else:
			voice_requested.emit(peer_id, payload)

		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)



func _on_request(message: DotNetMessage) -> void:
	var ask := message as PhRequest

	if ask == null or net == null or not net.is_server:
		return

	# [b]From the message, which dot-net stamped from the TRANSPORT.[/b] A peer id inside a
	# body is a claim; `sender_peer_id` is what the socket said, which is the only version
	# of it a server may act on.
	var peer_id := ask.sender_peer_id

	match ask.kind:
		PhEvents.Ask.READY:
			_admit(peer_id)
		PhEvents.Ask.SAY:
			var said := PhEvents.read_say(ask.reader())

			if bool(said["ok"]):
				# Emitted rather than acted on: everything about what a line means is
				# [DotChatRouter]'s, and the router is the module's.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		PhEvents.Ask.SPECTATE:
			var step := PhEvents.read_ask_spectate(ask.reader())

			if bool(step["ok"]):
				_spectate_step(peer_id, int(step["direction"]), bool(step["roam"]))
		PhEvents.Ask.DISGUISE:
			var _became := game.request_disguise(player_key(player_for_peer(peer_id)))
		PhEvents.Ask.REVEAL:
			var _shown := game.reveal(player_key(player_for_peer(peer_id)))
		PhEvents.Ask.TURN:
			var turned := PhEvents.read_turn(ask.reader())
			if bool(turned["ok"]):
				var _did := game.turn(player_key(player_for_peer(peer_id)), int(turned["how"]))
		PhEvents.Ask.TAUNT:
			var asked := PhEvents.read_ask_taunt(ask.reader())
			if bool(asked["ok"]):
				var _said := game.taunt(player_key(player_for_peer(peer_id)), asked["taunt_id"])


## Somebody who is out asked to look at somebody else. The server's list, the server's rule.
## A refusal goes back as a notice, because a key that silently does nothing is reported as broken.
func _spectate_step(peer_id: int, direction: int, roam: bool = false) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var moved: DotResult = game.spectate.toggle_roam(player_key(session_id)) if roam \
		else game.spectate.step(player_key(session_id), direction)

	if not moved.ok:
		notice(peer_id, moved.error.message)


## Everything in the world, to one peer, once its own copy exists.
## Sent on READY, not on connect: the client builds its scene after signon, so earlier JOIN and MAP messages land on a missing node.
func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	if profile_link != null:
		profile_link.peer_joined(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, PhEvents.Kind.HELLO, PhEvents.write_hello(
		session_id,
		game.tick_rate,
		net.clock.tick,
		game.hide_limit(),
		game.round_limit(),
		game.config.beacon_period,
		game.config.taunt_range,
		game.config.movement_floats(),
		game.config.auto_bunny_hop
	))

	# The map, before anything that stands on it, and what of it is already broken.
	if not _map_body.is_empty():
		_tell(peer_id, PhEvents.Kind.MAP, _map_body)
		# The map's toys by net id in toy order, which the joiner's own copies are paired with.
		if not _toys_body.is_empty():
			_tell(peer_id, PhEvents.Kind.TOYS, _toys_body)
		if game.map != null:
			for index in game.map.broken_indices():
				_tell(peer_id, PhEvents.Kind.BROKEN, PhEvents.write_broken(index, Vector3.ZERO, true))

	for other in _behaviours.keys():
		_tell(peer_id, PhEvents.Kind.JOIN, _join_body(int(other)))

	# Everybody already hiding: a joiner who was not told would see a hunter shooting at a
	# person standing in the open, and could not sweep its own prop's hull either. A hunter
	# joining during the hide is told when the seek starts, like every other hunter.
	if not (game.phase == PhGame.Phase.HIDE and _is_hunter_peer(peer_id)):
		_tell_every_disguise(peer_id)

	_tell(peer_id, PhEvents.Kind.PHASE, PhEvents.write_phase(game.phase))
	_tell(peer_id, PhEvents.Kind.CLOCK, _clock_body())


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: PhPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	return PhEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		behaviour.player.display_name,
		game.team_of(behaviour.player.player_id),
		behaviour.player.avatar
	)


## Tells everybody who somebody is now: a late profile, a wardrobe change, an operator's rename. Server only.
## Through JOIN, which a client applies idempotently to a player it has, so no second "changed" message is needed.
## An empty [param display_name] keeps the current one.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var player: PhPlayer = game.players.get(player_key(session_id))

	if player == null or not _behaviours.has(session_id):
		return false

	if display_name != "":
		player.display_name = display_name

	player.avatar = avatar
	_broadcast(PhEvents.Kind.JOIN, _join_body(session_id))
	return true


## To every peer that has said it is ready, and to nobody else.
## An empty body is dropped rather than sent: a zero-length event decodes as a valid message about nothing,
## which is the truncation bug this family has already paid for.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, body)


## One peer, and never zero: `net.send(msg, 0)` is a BROADCAST in dot-net.
## Passing a missing peer id straight through would send one player's private message to everybody.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if peer_id <= 0 or net == null or body.is_empty():
		return

	net.send(PhEvent.new(kind, body), peer_id)



func ask_ready() -> void:
	_ask(PhEvents.Ask.READY, PackedByteArray([0]))


## Says something. The server decides what it means and who hears it.
func ask_say(channel_id: StringName, text: String) -> void:
	if text.strip_edges() == "":
		return

	_ask(PhEvents.Ask.SAY, PhEvents.write_say(channel_id, text))


## Out, and asking to watch somebody else: +1 next, -1 previous, 0 the other camera.
func ask_spectate(direction: int) -> void:
	_ask(PhEvents.Ask.SPECTATE, PhEvents.write_ask_spectate(direction))


## The free-camera key.
func ask_spectate_roam() -> void:
	_ask(PhEvents.Ask.SPECTATE, PhEvents.write_ask_spectate_roam())


## Become what I am looking at. The server looks, from where it has this player's eyes.
func ask_disguise() -> void:
	_ask(PhEvents.Ask.DISGUISE, PackedByteArray([0]))


## Show my face, or put the prop back on.
func ask_reveal() -> void:
	_ask(PhEvents.Ask.REVEAL, PackedByteArray([0]))


## Lock, tilt or straighten my prop: [enum PhGame.Turn].
func ask_turn(how: int) -> void:
	_ask(PhEvents.Ask.TURN, PhEvents.write_turn(how))


## Taunt: [param taunt_id] from the list, or empty for any.
func ask_taunt(taunt_id: StringName = &"") -> void:
	_ask(PhEvents.Ask.TAUNT, PhEvents.write_ask_taunt(taunt_id))


## Sends one encoded voice packet to the server. Client side.
func send_voice(payload: PackedByteArray) -> void:
	if link != null and net != null and not net.is_server:
		link.send_voice(1, payload)


func _ask(kind: int, body: PackedByteArray) -> void:
	if net == null or net.is_server:
		return

	net.send(PhRequest.new(kind, body), 1)


func _on_event(message: DotNetMessage) -> void:
	var event := message as PhEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		PhEvents.Kind.HELLO:
			_apply_hello(reader)
		PhEvents.Kind.MAP:
			_apply_map(reader)
		PhEvents.Kind.TOYS:
			var told := PhEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		PhEvents.Kind.JOIN:
			_apply_join(reader)
		PhEvents.Kind.LEAVE:
			var session_id := PhEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(player_key(session_id))
			roster_changed.emit(session_id)
		PhEvents.Kind.TEAM:
			var side := PhEvents.read_team(reader)

			if bool(side["ok"]):
				var id := player_key(int(side["player_id"]))
				game.sides[id] = int(side["team"])

				if game.players.has(id):
					(game.players[id] as PhPlayer).team = int(side["team"])

				roster_changed.emit(int(side["player_id"]))
		PhEvents.Kind.CLOCK:
			_apply_clock(reader)
		PhEvents.Kind.ROUND:
			var round_info := PhEvents.read_round(reader)

			if bool(round_info["ok"]):
				game.round_number = int(round_info["round"])

				if bool(round_info["began"]):
					game.phase_elapsed = 0.0
					game.seek_elapsed = 0.0
					# The server put every broken piece back.
					if game.map != null:
						game.map.restore_all()

				round_changed.emit(
					int(round_info["round"]),
					bool(round_info["began"]),
					int(round_info["winner"]),
					str(round_info["why"])
				)
		PhEvents.Kind.PHASE:
			var moved := PhEvents.read_phase(reader)

			if bool(moved["ok"]):
				game.phase = int(moved["phase"])
				game.phase_elapsed = 0.0

				phase_received.emit(int(moved["phase"]))
		PhEvents.Kind.DEATH:
			var death := PhEvents.read_death(reader)

			if bool(death["ok"]):
				# The fall goes on the player before anybody hears of the death, so the client
				# that draws it reads the server's pick.
				var fell: PhPlayer = game.players.get(player_key(int(death["player_id"]))) \
					if game != null else null
				if fell != null and death.has("death"):
					fell.death = death["death"]
				death_received.emit(
					int(death["player_id"]), int(death["by"]), death["why"]
				)
		PhEvents.Kind.LAUNCH:
			var launch := PhEvents.read_launch(reader)

			if bool(launch["ok"]) and game.projectiles != null:
				var thrower: PhPlayer = game.players.get(player_key(int(launch["thrower"])))
				var owner := thrower.entity_id if thrower != null else 0
				var _copy: RefCounted = game.projectiles.launch(PhEvents.spawn_from_launch(launch, owner), int(launch["id"]))
		PhEvents.Kind.HIT:
			var hit := PhEvents.read_hit(reader)

			if bool(hit["ok"]):
				hit_received.emit(hit["point"], bool(hit["killed"]), bool(hit["headshot"]))
		PhEvents.Kind.ARMED:
			var armed := PhEvents.read_armed(reader)

			if bool(armed["ok"]):
				# Noted on the player here rather than by whoever listens, so every client
				# draws the gun in a watched player's hand: see `PhPlayer.dealt`.
				var dealt_to: PhPlayer = game.players.get(player_key(int(armed["player_id"]))) \
					if game != null else null
				if dealt_to != null:
					dealt_to.note_dealt(armed["weapon_id"], game.round_number)
				armed_received.emit(int(armed["player_id"]), armed["weapon_id"])
		PhEvents.Kind.CHAT:
			var wire := PhEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		PhEvents.Kind.NOTICE:
			var text := PhEvents.read_notice(reader)

			if bool(text["ok"]):
				notice_received.emit(str(text["text"]))
		PhEvents.Kind.SPECTATE:
			var view := PhEvents.read_spectate(reader)

			if bool(view["ok"]) and game.spectate != null:
				game.spectate.apply_view(
					player_key(int(view["viewer"])),
					int(view["mode"]),
					player_key(int(view["target"])) if int(view["target"]) != 0 else &"",
					player_key(int(view["killer"])) if int(view["killer"]) != 0 else &"",
					view["death_at"]
				)
				spectate_received.emit(
					int(view["viewer"]), int(view["mode"]), int(view["target"])
				)
		PhEvents.Kind.DISGUISE:
			var worn := PhEvents.read_disguise(reader)

			if bool(worn["ok"]):
				var id := player_key(int(worn["player_id"]))
				var wearer: PhPlayer = game.players.get(id)
				game.apply_disguise_wire(id, worn["wire"])
				if wearer != null:
					# What the HUD reads to say "press Q to hide again".
					wearer.set_aside = DotPropDisguise.new() if bool(worn["revealed"]) else null
				disguise_received.emit(int(worn["player_id"]), bool(worn["revealed"]))
		PhEvents.Kind.TAUNT:
			var heard := PhEvents.read_taunt(reader)

			if bool(heard["ok"]):
				taunt_received.emit(int(heard["player_id"]), heard["taunt_id"], bool(heard["forced"]))
		PhEvents.Kind.DECOY:
			var cost := PhEvents.read_decoy(reader)

			if bool(cost["ok"]):
				decoy_received.emit(float(cost["amount"]))
		PhEvents.Kind.BROKEN:
			var broke := PhEvents.read_broken(reader)

			if bool(broke["ok"]):
				game.apply_broken(int(broke["index"]), broke["direction"], bool(broke["quiet"]))


func _apply_hello(reader: DotNetReader) -> void:
	var hello := PhEvents.read_hello(reader)

	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# The server's tick rate, applied before anything is derived from it and before `sync_from_server`.
	# The clock converts its error and lead through `tick_rate`; an unread HELLO rate left a browser client
	# at 60 against a server on 128, with every replicated time out by 128/60.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	game.config.hide_seconds = float(hello["hide_seconds"])
	game.config.round_seconds = float(hello["round_seconds"])
	game.config.beacon_period = float(hello["beacon_period"])
	game.config.taunt_range = float(hello["taunt_range"])
	game.adopt_movement(hello["move"], bool(hello["auto_hop"]))

	_claim_local_player()

	hello_received.emit(local_player_id)


## Puts the whole client, the world, every controller and the ENGINE, on the server's rate.
## At 60 against 128 the simulation ran in bursts of two and three ticks per frame and the camera lurched.
## A server never calls this: its rate is `sv_tickrate`.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	# The LIVE one, which is built from the config back at `setup()` and is therefore not
	# updated by writing the config alone.
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap to
	# a quarter second of ticks, so a slow-frame client keeps up with the server. A shell built
	# before it gets the same rule here; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## The map, which on a client is a document it builds exactly as the server did.
## Refused with a line, never half built: a client a format behind gets no map and a WARN, not a map with holes.

## The map's toys on the wire, one behaviour per toy in toy order, and the TOYS event that names
## their net ids (kept for a joiner).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: which map the last TOYS was for. Its mirrors are registered at once and handed their
## toys when this end's toys for that map exist ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: a client registers them the
## moment TOYS arrives, before its own map may be built, and keeps them through a map change.
var _toy_holder: Node3D = null


## Server: an entity for each of the map's toys, and TOYS naming them.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.map != null and game.map.toys != null:
		for toy in game.map.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = PhEvents.write_toys(game.map.id() if game.map != null else &"", ids)
	_broadcast(PhEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0
## allocates: the server); null when the registry refused it. The behaviour before the
## identity, which collects behaviours in its `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> PhToyNet:
	var behaviour := PhToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	# Under [PhInterest]: no toy to a hunter while the props hide.
	identity.always_relevant = false
	identity.interest_linger_sec = 0.0
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		at.remove_child(behaviour)
		at.remove_child(identity)
		behaviour.queue_free()
		identity.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry and out of the tree at once: a new identity on the same
## toy collects every behaviour under it in its `_ready`, and a freed one found there broke the
## next snapshot. The server's, on a map change or a new set.
func _release_toys() -> void:
	for behaviour: PhToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				_unregister(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and at.get_parent() == _toy_holder and _toy_holder != null:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client, on TOYS: a mirror for every id at once, whether this end's toys for that map exist yet or not.
## A client must know every entity a snapshot carries: dot-net stops reading at the first unknown one,
## freezing every player after it. Paired with its toy by index as soon as both are here.
func _apply_toys(told: Dictionary) -> void:
	if net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's toys are for the map
## TOYS named; none while they are not (a map change on the way, or another map).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	var box := game.map.toys if game.map != null and game.map.toys != null and game.map.id() == _toys_map else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: PhToyNet = _toy_nets[i]
		behaviour.toy = box.toy(i) if box != null else null


## Client: the old map's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: PhToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toys this end replicates (a client: mirrors paired with a toy). For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: PhToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n


func _apply_map(reader: DotNetReader) -> void:
	var told := PhEvents.read_map(reader)

	if not bool(told["ok"]) or game == null:
		return

	var decoded := PhMapDoc.decode(told["encoded"])

	if not decoded.ok:
		DotLog.warn(CHANNEL, "the server sent a map this build cannot build", {
			"why": decoded.error.message, "detail": decoded.error.detail,
		})
		return

	var built := game.build_map(decoded.value)

	if built.ok:
		map_received.emit(game.map.id())


func _apply_join(reader: DotNetReader) -> void:
	var join := PhEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := player_key(session_id)
	var player: PhPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), int(join["team"]))

		if player == null:
			return

		# A client never samples: the client loop hands it commands, and the local player is
		# the only one whose commands exist at all.
		player.sampler = null
		player.samples_input = false

		# This client's own player is owned by this client, and nobody else's is: otherwise `is_owner` is false locally,
		# `registry.predicted()` is empty and the player moves only when a snapshot returns. Keyed by session, not a wire peer id,
		# because JOIN carries none and `is_owner` compares against this registry's local peer. HELLO precedes every JOIN in `_admit`.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)

		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			return
	else:
		player.display_name = str(join["name"])

	# Both branches: a JOIN for somebody this client already has is the server saying who
	# they are NOW — see [method refresh_player].
	player.avatar = join["avatar"]
	game.sides[id] = int(join["team"])
	player.team = int(join["team"])
	roster_changed.emit(session_id)


## Who owns a mirrored player on this client: this client for its own player, the server's 0 otherwise.
## Never the local peer for anybody else, or this client would predict a person whose keys it never had.
## A local peer of 0 claims nothing: dot-net's `is_owner` is already true of every owner-0 mirror there.
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
## Belt and braces: `_admit` sends HELLO first, but a JOIN ahead of it would leave the player unpredicted all session
## with every check passing, which is the bug [method _apply_join] documents.
func _claim_local_player() -> void:
	var mine: PhPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


func _apply_clock(reader: DotNetReader) -> void:
	var clock := PhEvents.read_clock(reader)

	if not bool(clock["ok"]):
		return

	game.round_number = int(clock["round"])
	game.phase_elapsed = float(clock["elapsed"])
	game.seek_elapsed = float(clock["seek_elapsed"])
	game.phase = int(clock["phase"])
	game.remote_props = int(clock["props"])
	game.remote_hunters = int(clock["hunters"])
	game.remote_playable = bool(clock["playable"])



func describe() -> Dictionary:
	var out := {
		"server": net != null and net.is_server,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"tick": _tick,
	}

	if not (net != null and net.is_server):
		out["local_player"] = local_player_id

	if link != null:
		out["link"] = link.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"bridge     %s" % ("server" if net != null and net.is_server else "client"),
		"players    %d" % _behaviours.size(),
		"peers      %d ready" % _ready_peers.size(),
		"tick       %d" % _tick,
	])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
