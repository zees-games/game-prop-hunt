extends DotNpcAiNavAnnotator

## dot-npc-ai's map annotator, told what a prop-hunt hiding place is: a place beside a piece of
## floor furniture a prop may become, among others of its kind, out of sight and tucked in.
##
## [b]Why override the score, not filter afterwards.[/b] The base score (out of sight first,
## then tucked in) puts a prop in an empty corner: nothing to be, so a person in the open, which
## is the one thing a hunter is glad of. The annotator picks its hiding places as the better
## third by this score and keeps them apart, so a score that does not know about furniture picks
## the wrong third and the right places never reach the list. Each spot is stamped here with the
## piece a prop would copy there (`prop`, `kind`, `yaw`, `kin`), which is also how the bots
## read it afterwards.
##
## No `class_name`: a mounted pack cannot register one.

## Metres from a piece's box a spot may be and still count as beside it ([code]ph_bot_beside[/code]).
var beside: float = 1.3
## Metres within which others of a kind make a place plausible, and how many make it perfect.
var kin_radius: float = 6.0
var kin_full: int = 4

## `[{i, frame, size, kind, kin, yaw}]`, one per piece of floor furniture a prop may become.
var pieces: Array[Dictionary] = []

var _grid: Dictionary = {}
const CELL := 3.0


## Call once [member pieces] is filled.
func index_pieces() -> void:
	_grid.clear()
	for n in range(pieces.size()):
		var at: Vector3 = (pieces[n]["frame"] as Transform3D).origin
		var c := Vector2i(floori(at.x / CELL), floori(at.z / CELL))
		if not _grid.has(c):
			_grid[c] = []
		(_grid[c] as Array).append(n)


## How much of the way to "perfect" a place is, 0..1, from how many of its kind stand near.
func fit_of(kin: int) -> float:
	return clampf(float(kin - 1) / float(kin_full - 1), 0.0, 1.0)


func _hide_score(spot: Dictionary) -> float:
	var at: Vector3 = spot["at"]
	var best := -1
	var best_kin := -1
	var best_d := INF
	var span := int(ceil((beside + 1.5) / CELL))
	var cx := floori(at.x / CELL)
	var cz := floori(at.z / CELL)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var bucket: Variant = _grid.get(Vector2i(cx + dx, cz + dz))
			if bucket == null:
				continue
			for n: int in bucket:
				var piece: Dictionary = pieces[n]
				var frame: Transform3D = piece["frame"]
				var size: Vector3 = piece["size"]
				var local := frame.affine_inverse() * at
				if absf(at.y - frame.origin.y) > 0.8:
					continue
				var d := Vector2(maxf(absf(local.x) - size.x * 0.5, 0.0), maxf(absf(local.z) - size.z * 0.5, 0.0)).length()
				if d > beside:
					continue
				var kin: int = piece["kin"]
				# The piece with the most of its kind round it, the nearer on a tie: a chair
				# among thirty, not the odd lamp beside it.
				if kin > best_kin or (kin == best_kin and d < best_d):
					best = n
					best_kin = kin
					best_d = d
	if best < 0:
		spot["prop"] = -1
		return -5.0
	var piece: Dictionary = pieces[best]
	spot["prop"] = int(piece["i"])
	spot["kind"] = piece["kind"]
	spot["yaw"] = piece["yaw"]
	spot["kin"] = best_kin
	var score := (1.0 - float(spot["exposure"])) * 2.0 + float(spot["enclosure"]) * 1.5 + fit_of(best_kin) * 2.0
	spot["score"] = score
	return score
