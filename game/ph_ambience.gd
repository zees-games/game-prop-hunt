extends RefCounted

## What the hiding places sound like: the cvar defaults shared by the simulation (binds `ph_ambient*`) and the client's director (plays them).

const PREFIX := "ph"
## Hiding is listening: the layer is felt, not heard, and the one-shots are rare so a footstep still gives someone away.
const LEVEL := 0.3
const RATE := 0.5
const DEFAULT_MOOD := &"indoor_hall"

## By map id prefix; the rest are rooms.
const PREFIX_MOODS := {
	"ph_abandoned": &"interior_horror", "ph_wolfsmanor": &"interior_horror", "ph_bank": &"indoor_hall",
	"ph_hotel": &"indoor_hall", "ph_office": &"indoor_hall", "ph_school": &"indoor_hall",
	"ph_elementary": &"indoor_hall", "ph_apartment": &"indoor_hall", "ph_midwestapartment": &"indoor_hall",
	"ph_restaurant": &"indoor_hall", "ph_cyber": &"industrial", "ph_gas_station": &"industrial",
	"ph_autumn": &"outdoor_night", "ph_frontyard": &"outdoor_night", "ph_woods": &"outdoor_night",
	"ph_westerncity": &"city_ruins", "ph_volcano": &"cave_tunnel",
	"ph_bikinibottom": &"swamp", "ph_oceanwaves": &"swamp", "ph_islandhouse": &"swamp", "ph_swimmingpool": &"swamp",
}


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r


## The cvars a workbench set offers: name -> profile type.
static func cvar_types() -> Dictionary:
	var rules := make_rules()
	var out := {}
	for key: String in DotAmbienceRules.VARS:
		var row: Array = DotAmbienceRules.VARS[key]
		out[rules.cvar_of(row)] = "string" if row[2] == null else "float"
	return out
