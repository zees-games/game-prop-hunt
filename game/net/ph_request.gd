extends DotNetMessage

const PhEvents := preload("ph_events.gd")

## Anything a client asks the authority for. Reliable, rare, to the server only.
## None is a per-tick intent (firing is a BUTTON, ordered against its movement); these happen once and must not be lost.
## A disguise carries no prop: the server casts the ray from where it has the player's eyes.

const NAME := &"ph.request"
const KIND_BITS := 4
const MAX_BODY := 256

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## Built with [code]new(kind, body)[/code]; this file does not preload itself.
## A script that extends DotNetMessage and preloads ITSELF, loaded from a module a running [DotServer] loads, leaks the whole script graph at exit on Godot 4.7.2.
## The registry decodes with a bare `new()`, which is why both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= PhEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)

	return DotResult.success(true)


## Whether every [enum PhEvents.Ask] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(PhEvents.Ask.values().max()) < (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "PhRequest(%s, %d bytes)" % [PhEvents.ask_name(kind), body.size()]
