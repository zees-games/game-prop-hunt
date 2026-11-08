extends "headless_run_base.gd"

const PhWeaponNet := preload("../game/net/ph_weapon_net.gd")

## Dropped hunter guns: the drop key, pickup with ammunition, a dead hunter's gun, floor clearing,
## the sv_weapon_drop* cvars, and the same floor on a client.
## Run: godot --headless --path . res://examples/headless_weapondrop.tscn

const SECTIONS := 3
const CHECKS := 14


class FakeBridge extends RefCounted:
	var wire: Array = []

	func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
		wire.append([peer_id, kind, body])

	func _broadcast(kind: int, body: PackedByteArray) -> void:
		wire.append([0, kind, body])

	func announce_armed(_id: StringName, _weapon: StringName) -> void:
		pass

	func session_of(_id: StringName) -> int:
		return 1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-prop-hunt: weapon drops")
	await _test_throw_and_pickup()
	await _test_death_and_clearing()
	await _test_wire()
	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


func _test_throw_and_pickup() -> void:
	_section("Throw and pickup")
	var game := await _seek_round()
	var layer = game.weapon_layer
	var hunter: PhPlayer = game.players[&"u300"]
	var rules: DotWeaponDropRules = game.drop_rules
	if not _check(layer != null and hunter.weapons != null, "the game builds a layer and the hunter is armed"):
		return
	_check(layer.drops.is_authority, "the server layer is authoritative")

	rules.key_enabled = false
	_check(layer.throw_for(&"u300") == 0, "sv_weapon_drop_key 0 throws nothing")
	rules.key_enabled = true
	_check(layer.throw_for(&"u301") == 0, "a prop throws nothing")

	var id: int = layer.throw_for(&"u300")
	_check(id > 0 and layer.drops.count() == 1, "the key throws the gun in hand")

	var entry: Dictionary = layer.drops.snapshot()[0]
	hunter.controller.state.position = (entry["at"] as Transform3D).origin - Vector3.UP * 0.5
	layer.drops.tick(5.0)
	layer.tick()
	_check(layer.drops.count() == 0, "a hunter in reach takes the gun back")
	_finished()


func _test_death_and_clearing() -> void:
	_section("Death and clearing")
	var game := await _seek_round()
	var layer = game.weapon_layer
	var hunter: PhPlayer = game.players[&"u300"]
	_fell(game, hunter)
	_check(layer.drops.count() == 1, "a dead hunter leaves the gun lying")
	layer.clear()
	_check(layer.drops.count() == 0, "clearing empties the floor")

	var g2 := await _seek_round()
	g2.drop_rules.on_death = false
	_fell(g2, g2.players[&"u300"])
	_check(g2.weapon_layer.drops.count() == 0, "sv_weapon_drop_death 0 leaves nothing")
	_finished()


func _test_wire() -> void:
	_section("Wire")
	var game := await _seek_round()
	var layer = game.weapon_layer
	var bridge := FakeBridge.new()
	var server_net := PhWeaponNet.new()
	var client_net := PhWeaponNet.new()
	var lost: Array = []
	client_net.lost_received.connect(func(session_id: int, weapon_id: StringName) -> void: lost.append([session_id, weapon_id]))
	server_net.attach(bridge)
	server_net.watch(layer)

	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["ph_practice"])
	var client := PhGame.new()
	client.name = "Client"
	client.config = config
	client.tick_rate = TICK_RATE
	client.authoritative = false
	client.register_service = false
	add_child(client)
	client.set_physics_process(false)
	_worlds.append(client)
	await _physics_frame()
	await _physics_frame()
	var mirror = client.weapon_layer
	_check(not client_net.apply(PhEvents.Kind.LAUNCH, DotNetReader.new(PackedByteArray()), mirror),
		"another game event is left to the bridge")
	var id: int = layer.throw_for(&"u300")
	_check(id > 0 and bridge.wire.size() >= 1, "a throw puts events on the wire", str(bridge.wire.size()))
	for item in bridge.wire:
		var _ok := client_net.apply(item[1], DotNetReader.new(item[2]), mirror)
	bridge.wire.clear()
	_check(mirror.drops.count() == 1 and mirror.drops.has_drop(id), "the client draws the same drop under the same id")
	_check(lost.size() == 1, "the thrower is told the gun left their hands")

	server_net.send_snapshot(7, layer)
	_check(bridge.wire.size() == layer.drops.count(), "a joiner is sent every gun lying")
	layer.clear()
	_finished()


## A hunter dies the way a fall kills: damage from nobody, stamped with the tick.
func _fell(game: PhGame, victim: PhPlayer) -> void:
	var fall := DotDamage.make(0, victim.entity_id, 10000.0, null)
	fall.tick = game._tick
	fall.context = {"why": PhGame.DIED_FELL}
	var _applied := game.combat.apply_damage(fall)
