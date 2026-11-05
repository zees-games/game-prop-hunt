extends CanvasLayer

## The on-screen buttons of a phone player: a hunter's fire, reload and aim, a prop's swap, lock and taunt, and jump for both, as dot-ui's [DotTouchButtons].
## Which set shows follows the side ([method show_for]); the client turns a press into what the key would have done. Walking and looking are the touch sampler's.

# No CHANNEL: buttons that emit signals; what they cause is logged where it happens.

signal pressed(id: StringName)
signal released(id: StringName)

const EDGE_MARGIN := 20.0

var buttons: DotTouchButtons = null
## Called with the layout each time the set changes (the client's screen fit sizes the buttons for it).
var fit_fn: Callable = Callable()
var _hunter: bool = false
var _loadout: bool = false


## Whether this device wants them.
static func wanted() -> bool:
	return DotPlatform.has_touch()


## Offsets are from the bottom-right corner, towards the middle. The set is small and packed to the corner: at 390 px tall a phone has little to spare.
static func layout(hunter: bool, loadout: bool = false) -> Array[Dictionary]:
	if hunter:
		var set: Array[Dictionary] = [
			{"id": &"fire", "label": "FIRE", "offset": Vector2(66, 76), "radius": 46.0},
			{"id": &"jump", "label": "JUMP", "offset": Vector2(160, 40), "radius": 32.0},
			{"id": &"reload", "label": "R", "offset": Vector2(40, 160), "radius": 26.0},
			{"id": &"aim", "label": "AIM", "offset": Vector2(132, 130), "radius": 28.0},
		]
		if loadout:
			set.append({"id": &"loadout", "label": "GEAR", "offset": Vector2(216, 96), "radius": 26.0})
		return set
	return [
		{"id": &"disguise", "label": "SWAP", "offset": Vector2(66, 76), "radius": 46.0},
		{"id": &"jump", "label": "JUMP", "offset": Vector2(160, 40), "radius": 32.0},
		{"id": &"lock", "label": "LOCK", "offset": Vector2(40, 160), "radius": 26.0},
		{"id": &"taunt", "label": "TAUNT", "offset": Vector2(132, 130), "radius": 28.0},
	]


func _init() -> void:
	name = "Touch"
	layer = 6


func build() -> void:
	buttons = DotTouchButtons.new()
	buttons.name = "Buttons"
	buttons.only_on_touch = false
	buttons.margin = EDGE_MARGIN
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(layout(_hunter, _loadout))
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
	var set := layout(_hunter, _loadout)
	buttons.set_buttons(set)
	if fit_fn.is_valid():
		fit_fn.call(set)
