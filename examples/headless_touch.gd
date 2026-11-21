extends GSGameCheckSuite

const PhTouch := preload("../game/ph_touch.gd")

## The touch layout: the buttons fit a phone at three sizes without overlapping; dot-mobile's overlay drives the sampler and sits under menus; the crosshair calls only a living prop an enemy.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 46


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-prop-hunt: touch buttons")
	var sets: Dictionary = {"hunter": PhTouch.rows(true), "hunter+gear": PhTouch.rows(true, true), "prop": PhTouch.rows(false)}
	for label: String in sets:
		var layout: Array[Dictionary] = sets[label]
		var ids: Array[StringName] = []
		for b: Dictionary in layout:
			ids.append(b["id"])
		_check(ids.size() >= 4, "%s: the layout has its buttons" % label)
		for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
			var buttons := GSTouchButtons.new()
			buttons.size = size
			buttons.set_buttons(layout)
			add_child(buttons)
			_check(Rect2(Vector2.ZERO, size).encloses(buttons.footprint()), "%s: the cluster fits %dx%d" % [label, size.x, size.y], str(buttons.footprint()))
			var clash := ""
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
					if gap < 4.0:
						clash = "%s and %s" % [ids[i], ids[j]]
			_check(clash == "", "%s: no two buttons overlap at %dx%d" % [label, size.x, size.y], clash)
			buttons.free()
	var hunter := PhTouch.touch_layout(true, true)
	var prop := PhTouch.touch_layout(false)
	_check(hunter.validate().ok and prop.validate().ok, "both sets validate (no alias id, no button too small or touching)")
	_check(hunter.row(&"fire")["offset"] == Vector2(80, 84) and hunter.row(&"jump")["offset"] == prop.row(&"jump")["offset"], "fire and jump sit in the family's homes, jump unmoved between sides")
	_check(not prop.has(&"fire") and prop.has(&"disguise") and hunter.has(&"loadout") and not hunter.has(&"crouch"), "a prop swaps fire for swap; a hunter has gear and no duck")
	GSPlatform.touch_override = 0
	var off := GSTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	GSPlatform.touch_override = -1
	_overlay()
	_crosshair()
	_report(CHECKS)


## The client's end of the overlay: what [PhTouch] asks of its owner.
class FakeClient extends Node:
	var menu_rect := Rect2(760, 8, 76, 44)
	var live := true

	func touch_ignores(at: Vector2) -> bool:
		return menu_rect.has_point(at)

	func touch_live() -> bool:
		return live


func _tap(controls: GSMobileControls, at: Vector2, down: bool, index: int = 0) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = at
	e.pressed = down
	if at.x >= 0.0 and controls.buttons.contains_point(at):
		controls.buttons._input(e)
	else:
		controls._input(e)


func _overlay() -> void:
	var rules := GSMobileRules.new()
	var prefs := GSMobilePrefs.new()
	_check(prefs.autofire and not rules.resolve(prefs, true).autofire, "auto-fire is off for a touch player by default, even when they ask (shooting furniture costs health)")
	_check(not rules.resolve(prefs, true).aim_assist, "and aim assist is off")
	var bound := {}
	var record := func(cvar_name: String, _value: String, _help: String, _flags: int) -> Variant:
		bound[cvar_name] = true
		return null
	rules.bind_cvars(record, 0)
	_check(bound.has("sv_autofire") and bound.has("sv_mobile_touch"), "the server binds dot-mobile's cvars", str(bound.keys()))
	_check(FileAccess.get_file_as_string("res://game/ph_game.gd").contains("mobile_rules: GSMobileRules"), "PhGame carries the rules the module binds")
	GSPlatform.touch_override = 1
	var host := Control.new()
	host.size = Vector2(844, 390)
	add_child(host)
	var owner_client := FakeClient.new()
	host.add_child(owner_client)
	var sampler := GSFpsTouchSampler.new(GSFpsTunables.new())
	var touch := PhTouch.new()
	touch.owner_client = owner_client
	touch.build(sampler, rules)
	host.add_child(touch)
	var controls := touch.controls
	controls.size = host.size
	controls.refresh()
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.describe()))
	var ids: Array = []
	for b in PhTouch.rows(false):
		ids.append(b["id"])
	_check(&"disguise" in ids and &"lock" in ids and &"taunt" in ids and &"jump" in ids and not &"fire" in ids, "a prop's set: swap, lock, taunt and jump, no fire")
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseButton.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	var real := InputEventMouseButton.new()
	_check(touch.takes(tap) and touch.takes(fake) and not touch.takes(real), "it takes touches and the mouse emulated from them, not a real mouse")
	touch.show_for(true)
	var got: Array = []
	touch.pressed.connect(func(id: StringName) -> void: got.append(id))
	controls.buttons.size = host.size
	_tap(controls, controls.buttons.centre_of(&"fire"), true)
	_check(touch.is_held(&"fire") and got == [&"fire"], "a thumb on FIRE holds it and tells the client", str(got))
	_tap(controls, controls.buttons.centre_of(&"fire"), false)
	_check(not touch.is_held(&"fire"), "and lifting it lets go")
	_tap(controls, controls.buttons.centre_of(&"jump"), true, 1)
	_check(touch.is_held(&"jump") and (sampler.sample(1.0 / 60.0).buttons & GSFpsCommand.BUTTON_JUMP) != 0, "JUMP is held on the sampler's jump bit")
	_tap(controls, controls.buttons.centre_of(&"jump"), false, 1)
	var look := InputEventScreenTouch.new()
	look.index = 2
	look.position = Vector2(1000, 120)
	look.pressed = true
	controls._input(look)
	var drag := InputEventScreenDrag.new()
	drag.index = 2
	drag.position = Vector2(1030, 120)
	drag.relative = Vector2(20, 0)
	controls._input(drag)
	var turned := sampler.sample(1.0 / 60.0)
	_check(not is_zero_approx(sampler.yaw), "a drag on the look side turns the view", str(turned.yaw))
	touch.show_for(false)
	_check(not touch.is_held(&"fire") and controls.buttons.centre_of(&"disguise") != Vector2.ZERO, "changing side swaps the set and lets go")
	touch.sync(true)
	_check(not controls.visible and not touch.active(), "a menu pauses it")
	touch.sync(false)
	_check(touch.active(), "and closing the menu brings it back")
	_check(owner_client.touch_ignores(Vector2(780, 20)) and not owner_client.touch_ignores(Vector2(400, 200)), "the Menu button's corner is left to the menu")
	host.free()
	GSPlatform.touch_override = -1


func _hull(feet: Vector3, friend: bool, height: float = 1.0, radius: float = 0.3) -> Dictionary:
	return {"feet": feet, "height": height, "radius": radius, "friend": friend}


func _crosshair() -> void:
	var eye := Vector3(0, 0.6, 0)
	var ahead := Vector3(0, 0, -1)
	var none := GSMobileAutoFire.TARGET_NONE
	var foe := GSMobileAutoFire.TARGET_ENEMY
	var friend := GSMobileAutoFire.TARGET_FRIEND
	var prop := _hull(Vector3(0, 0, -10), false)
	_check(PhTouch.crosshair_kind(eye, ahead, [prop], null, 0) == foe, "the crosshair on a living prop is an enemy")
	_check(PhTouch.crosshair_kind(eye, Vector3(1, 0, 0), [prop], null, 0) == none, "looking away is nothing")
	_check(PhTouch.crosshair_kind(eye, ahead, [], null, 0) == none, "real furniture (no hull) is never a target")
	_check(PhTouch.crosshair_kind(eye, ahead, [prop, _hull(Vector3(0, 0, -5), true)], null, 0) == friend, "a fellow hunter in front holds fire")
	_check(PhTouch.crosshair_kind(eye, ahead, [_hull(Vector3(0, 0, -PhTouch.MAX_RANGE - 5.0), false)], null, 0) == none, "a prop beyond the range is nothing")
	var crowd: Array = []
	for i in 31:
		crowd.append(_hull(Vector3(float(i % 8) - 4.0, 0, -6.0 - float(i)), false))
	var t := Time.get_ticks_usec()
	for _r in 200:
		var _k := PhTouch.crosshair_kind(eye, ahead, crowd, null, 0)
	var each_ms := float(Time.get_ticks_usec() - t) / 200.0 / 1000.0
	_check(each_ms < 0.1, "the crosshair query over 32 players is under 0.1 ms", "%.4f ms" % each_ms)
