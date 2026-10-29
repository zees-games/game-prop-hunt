extends DotNetInput

const PhNetCommand := preload("ph_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and a weapon slot.
## The three game buttons ride in [member DotFpsCommand.buttons] like a jump: per-tick, held, and ordered against the movement they were aimed with,
## where a reliable request would arrive a round trip later against a position already left. The slot is its own field ([DotFpsCommand] has eight buttons; see [member PhPlayer.wanted_slot]).

## Fire. `BUTTON_USER_0`, which dot-player-controller reserves.
const BUTTON_FIRE := DotFpsCommand.BUTTON_USER_0

## The alt-fire, which on every blaster in the pack is a bash.
const BUTTON_ALT := DotFpsCommand.BUTTON_USER_1

const BUTTON_RELOAD := DotFpsCommand.BUTTON_USER_2

## How many bits the slot takes. Eight slots is one more than the pack uses.
const SLOT_BITS := 3

var move: DotFpsCommand = DotFpsCommand.new()

## Which weapon the player has asked for, or zero for "leave it alone".
var slot: int = 0

func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	writer.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)
	slot = reader.read_uint(SLOT_BITS)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — a prop that crosses
## a room before a hunter can turn round.
func _sanitise() -> void:
	move.sanitise()
	slot = clampi(slot, 0, (1 << SLOT_BITS) - 1)


func _equals(other: DotNetInput) -> bool:
	var them := other as PhNetCommand
	return them != null and slot == them.slot and move.equals(them.move)
