extends RefCounted

## A client's map while it arrives: whole in one MAP, or in MAP_PARTs joined in order.
## Owned by [code]ph_net_bridge.gd[/code], which builds the document [method whole] or [method part] hands back.
## Refused with a line, never half built: a client a format behind gets no map and a WARN, not a map with holes.

const PhMapDoc := preload("../ph_map_doc.gd")

const CHANNEL := "ph.net"

## The next piece expected, how many, the whole size, and the bytes joined so far.
var _next: int = 0
var _count: int = 0
var _total: int = 0
var _joined: PackedByteArray = PackedByteArray()


## A map in one message (a read MAP), decoded, or null; any half-joined map is forgotten.
func whole(told: Dictionary) -> Variant:
	_next = 0
	return _decode(told["encoded"])


## One piece of a large map (a read MAP_PART): the whole map decoded once the last piece is in,
## null until then. Index 0 starts it over; a piece out of order, or a whole that does not add
## up, drops the map with a line rather than building half of one.
func part(told: Dictionary) -> Variant:
	var index := int(told["index"])

	if index == 0:
		_next = 0
		_count = int(told["count"])
		_total = int(told["total"])
		_joined = PackedByteArray()

	if index != _next or int(told["count"]) != _count or int(told["total"]) != _total:
		GSLog.warn(CHANNEL, "a map piece arrived out of order; the map is dropped", {
			"index": index, "expected": _next, "count": told["count"],
		})
		_next = -1
		return null

	_joined.append_array(told["chunk"])
	_next += 1

	if _next < _count:
		return null

	_next = 0

	if _joined.size() != _total:
		GSLog.warn(CHANNEL, "a map's pieces do not add up; the map is dropped", {
			"bytes": _joined.size(), "expected": _total,
		})
		return null

	var joined := _joined
	_joined = PackedByteArray()
	return _decode(joined)


## A whole map's bytes as its document, or null with a line.
func _decode(encoded: PackedByteArray) -> Variant:
	var decoded := PhMapDoc.decode(encoded)

	if not decoded.ok:
		GSLog.warn(CHANNEL, "the server sent a map this build cannot build", {
			"why": decoded.error.message, "detail": decoded.error.detail,
		})
		return null

	return decoded.value
