extends Node

## Splinters, shards and chips where furniture breaks, drawn by dot-fx's DotFxBreak and following fx_quality.

## Catalogue ids containing one of these break as that material; anything else is wood.
const MATERIAL_WORDS := {
	"glass": ["mirror", "bottle", "wine", "window", "lamp_bulb", "vase"],
	"metal": ["pan", "pot", "knife", "can", "toilet_stand", "radiator", "fan", "kettle"],
	"stone": ["mug", "plate", "bowl", "sink", "bathtub", "toilet", "cup"],
	"plastic": ["bear", "toy", "keyboard", "computer", "ball", "football", "bin"],
}

var break_fx: DotFxBreak = null


func _init() -> void:
	name = "BreakFx"
	break_fx = DotFxBreak.new()
	break_fx.name = "Break"
	add_child(break_fx)


func follow(store: Object) -> void:
	break_fx.follow(store)


static func material_of(prop_id: StringName) -> String:
	var id := String(prop_id)
	for material: String in MATERIAL_WORDS:
		for word: String in MATERIAL_WORDS[material]:
			if id.contains(word):
				return material
	return "wood"


## A burst at [param at] for prop [param prop_id], thrown back along the shot that broke it.
func shatter(prop_id: StringName, at: Vector3, size: Vector3, direction: Vector3) -> void:
	var normal := -direction.normalized() if direction.length_squared() > 0.0001 else Vector3.UP
	var _b := break_fx.burst(material_of(prop_id), at, normal, clampf(maxf(size.x, size.z), 0.3, 3.0))
