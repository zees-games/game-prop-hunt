extends "headless_net_base.gd"
## The wire codec checks of the headless net suite; headless_net.gd extends this.


## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	_test_the_command_codec()

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

	_test_the_codec_rest()


## The command's wire form: the aim bit rides after the slot, alone and in a batch with commands that do not carry it.
func _test_the_command_codec() -> void:
	var sent_commands: Array = []
	for i in range(3):
		var sent := PhNetCommand.new()
		sent.tick = 40 + i
		sent.delta = 1.0 / 64.0
		sent.slot = 2 + i
		sent.aim = i != 1
		sent.move.yaw = 10.0 * float(i)
		sent.move.move = Vector2(0.0, 1.0)
		sent.move.set_button(PhNetCommand.BUTTON_FIRE, i == 2)
		sent_commands.append(sent)
	var writer := DotNetWriter.new()
	DotNetInput.write_batch(writer, sent_commands)
	var got := DotNetInput.read_batch(writer.to_reader(), func() -> DotNetInput: return PhNetCommand.new())
	var round_trip := got.size() == 3
	for i in range(mini(got.size(), 3)):
		var back_cmd := got[i] as PhNetCommand
		round_trip = round_trip and back_cmd != null and back_cmd.aim == (i != 1) and back_cmd.slot == 2 + i \
			and back_cmd.move.is_pressed(PhNetCommand.BUTTON_FIRE) == (i == 2) and absf(back_cmd.move.yaw - 10.0 * float(i)) < 1.0
	_check(round_trip, "a batch of commands keeps each one's aim bit, slot and buttons", "%d back" % got.size())
	var plain := PhNetCommand.new()
	var bits_plain := DotNetWriter.new()
	plain._write(bits_plain)
	plain.aim = true
	var bits_aim := DotNetWriter.new()
	plain._write(bits_aim)
	_check(bits_plain.to_bytes().size() == bits_aim.to_bytes().size() and plain._equals(plain) and not plain._equals(PhNetCommand.new()),
		"the bit costs no byte, and a command with it is not equal to one without", "%d bytes" % bits_aim.to_bytes().size())


## The codec checks from TURN on: the clock, the size limits and the kind fields.
func _test_the_codec_rest() -> void:
	var turned := PhEvents.read_turn(DotNetReader.new(PhEvents.write_turn(PhGame.Turn.TILT_LEFT)))
	var asked := PhEvents.read_ask_taunt(DotNetReader.new(PhEvents.write_ask_taunt(&"whistle")))
	_check(bool(turned["ok"]) and int(turned["how"]) == PhGame.Turn.TILT_LEFT and bool(asked["ok"]) and asked["taunt_id"] == &"whistle",
		"TURN and a taunt request")

	var clock := PhEvents.read_clock(DotNetReader.new(PhEvents.write_clock(2, 12.5, 40.25, PhGame.Phase.SEEK, 3, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == PhGame.Phase.SEEK
		and absf(float(clock["seek_elapsed"]) - 40.25) < 0.1 and int(clock["props"]) == 3
		and int(clock["hunters"]) == 1, "CLOCK", str(clock))

		# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a smaller kind.
		# The largest MAP a reader accepts must survive the event's own body cap, or it is read back as no bytes, silently.
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

	# A map has no size limit: past one message it goes in MAP_PARTs, each one an event, joined whole.
	var large := PackedByteArray()
	large.resize(PhMapDoc.PART_BYTES * 3 + 5)
	for i in large.size():
		large[i] = (i * 31 + 7) & 0xff
	var parts := PhEvents.write_map_parts(large, PhMapDoc.PART_BYTES)
	var joined := PackedByteArray()
	var parts_ok := parts.size() == 4
	for part: Array in parts:
		var sent_part := PhEvent.new(part[0], part[1])
		var part_wire := DotNetWriter.new()
		sent_part._write(part_wire)
		var got_part := PhEvent.new()
		got_part._read(DotNetReader.new(part_wire.to_bytes()))
		var piece := PhEvents.read_map_part(got_part.reader())
		parts_ok = parts_ok and got_part.kind == PhEvents.Kind.MAP_PART and bool(piece["ok"]) and int(piece["total"]) == large.size()
		joined.append_array(piece["chunk"])
	_check(parts_ok and joined == large and PhEvents.write_map_parts(PackedByteArray([1, 2]), PhMapDoc.PART_BYTES)[0][0] == PhEvents.Kind.MAP,
		"a map past one message goes in MAP_PARTs that join whole; a small one is one MAP", "%d parts, %d of %d bytes" % [parts.size(), joined.size(), large.size()])

	_check(PhEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [PhEvents.Kind.size(), PhEvent.KIND_BITS])
	_check(PhRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [PhEvents.Ask.size(), PhRequest.KIND_BITS])
	_check(PhEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), PhEvents.CHAT_KIND_BITS])

	_finished()
