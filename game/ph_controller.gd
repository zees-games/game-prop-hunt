extends DotFpsController

## The first-person controller, with the one modifier this game adds: a hunter held still while the props hide.
## A modifier is part of the movement state, so it travels in the snapshot and a predicting client applies it on exactly the ticks the server does;
## a rule applied around the controller would be skipped by replayed ticks. Registered in [method _register_extensions] on every player in the same order, because the id travels.

## Held still and unable to jump or crouch, as a hunter is while the props hide.
const BLINDFOLD := &"ph_blindfold"


func _register_extensions() -> void:
	var held := DotFpsModifier.make(BLINDFOLD)
	held.deny_move = true
	held.deny_jump = true
	held.deny_crouch = true
	held.max_speed_scale = 0.0
	var _id := motor.register_modifier(held)
