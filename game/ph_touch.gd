extends CanvasLayer

## The on-screen buttons of a phone player: a hunter's fire, reload and aim, a prop's swap, lock and taunt, and jump for both, as dot-ui's [DotTouchButtons].
## Which set shows follows the side ([method show_for]); the client turns a press into what the key would have done. Walking and looking are the touch sampler's.

# No CHANNEL: buttons that emit signals; what they cause is logged where it happens.

signal pressed(id: StringName)
signal released(id: StringName)

var buttons: DotTouchButtons = null
## The DotGameClient that fits the buttons each time the set changes.
var client: Object = null
var _hunter: bool = false
var _loadout: bool = false


## Whether this device wants them.
static func wanted() -> bool:
	return DotPlatform.has_touch()


## dot-game's fps preset, cut to what the side uses. A hunter keeps fire and reload and adds aim (and gear on a host with a loadout menu); a prop swaps fire for swap, lock and taunt. Jump keeps its home for both.
static func touch_layout(hunter: bool, loadout: bool = false) -> DotGameTouchLayout:
	var cut := {&"alt": null, &"crouch": null, &"use": null, &"next": null, &"prev": null, &"board": null, &"chat": null}
	if hunter:
		cut[&"aim"] = {"slot": &"secondary", "label": "AIM"}
		if loadout:
			cut[&"loadout"] = {"slot": &"inner", "label": "GEAR"}
	else:
		cut[&"fire"] = null
		cut[&"reload"] = null
		cut[&"disguise"] = {"slot": &"primary", "label": "SWAP"}
		cut[&"lock"] = {"slot": &"secondary", "label": "LOCK"}
		cut[&"taunt"] = {"slot": &"inner", "label": "TAUNT"}
	var res := DotGameTouchLayout.build(DotGameTouchLayout.FPS, cut)
	if not res.ok:
		push_error("mg-prop-hunt touch layout refused: %s" % str(res.error))
		return DotGameTouchLayout.custom()
	return res.value


func _init() -> void:
	name = "Touch"
	layer = 6


func build() -> void:
	buttons = DotTouchButtons.new()
	buttons.name = "Buttons"
	buttons.only_on_touch = false
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layout(_hunter, _loadout).apply(buttons, client)
	buttons.button_down.connect(func(id: StringName) -> void: pressed.emit(id))
	buttons.button_up.connect(func(id: StringName) -> void: released.emit(id))
	add_child(buttons)


## Whether a screen position is on a button, so the sampler leaves that touch alone.
func contains_point(screen_pos: Vector2) -> bool:
	return buttons != null and buttons.contains_point(screen_pos)


## Adds the button that opens the loadout menu, on a host that has one.
func offer_loadout(on: bool) -> void:
	if on == _loadout:
		return
	_loadout = on
	if buttons != null:
		_apply()


## Swaps the set when the side changes; a held button is let go, so nothing stays down under another label.
func show_for(hunter: bool) -> void:
	if buttons == null or hunter == _hunter:
		return
	_hunter = hunter
	_apply()


func _apply() -> void:
	touch_layout(_hunter, _loadout).apply(buttons, client)
