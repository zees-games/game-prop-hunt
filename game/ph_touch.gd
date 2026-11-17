extends CanvasLayer

## The phone's controls: dot-mobile's stick, drag-look and buttons over the HUD, driving the client's own [DotFpsTouchSampler].
## The buttons are the side's: a hunter's fire, reload and aim, a prop's swap, lock and taunt, and jump for both
## ([method touch_layout]). Which set shows follows the side ([method show_for]); the client turns a press into what the
## key would have done. Auto-fire is the server's (`sv_autofire`, off here): a hunter pays in health for every piece of
## real furniture shot, so the crosshair only ever calls a living prop's hull an enemy ([method crosshair_kind]).

# No CHANNEL: buttons that emit signals; what they cause is logged where it happens.

signal pressed(id: StringName)
signal released(id: StringName)

const MAX_RANGE := 60.0

var controls: DotMobileControls = null
## The DotGameClient that fits the buttons each time the set changes.
var client: Object = null
## The PhClient: its player, game and camera, read by the crosshair and the live test.
var owner_client: Node = null
var _hunter: bool = false
var _loadout: bool = false

## dot-ui's buttons inside the overlay.
var buttons: DotTouchButtons:
	get:
		return controls.buttons if controls != null else null


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


## The set as dot-mobile rows: [method touch_layout]'s, with jump held on the sampler's jump bit.
static func rows(hunter: bool, loadout: bool = false) -> Array[Dictionary]:
	var out := touch_layout(hunter, loadout).buttons()
	for row in out:
		if row["id"] == &"jump":
			row["hold"] = DotFpsCommand.BUTTON_JUMP
	return out


func _init() -> void:
	name = "Touch"
	layer = 6


## Builds the overlay on [param sampler], following [param rules] (the server's; null keeps dot-mobile's defaults).
func build(sampler: DotFpsSampler, rules: DotMobileRules = null) -> void:
	controls = DotMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	if owner_client != null:
		controls.ignore_fn = func(at: Vector2) -> bool: return bool(owner_client.call(&"touch_ignores", at))
		controls.live_fn = func() -> bool: return bool(owner_client.call(&"touch_live"))
		controls.crosshair_fn = _crosshair
	controls.button_pressed.connect(func(id: StringName) -> void: pressed.emit(id))
	controls.button_released.connect(func(id: StringName) -> void: released.emit(id))
	controls.setup(sampler, rows(_hunter, _loadout))
	add_child(controls)
	_fit()


## Another sampler (offline play keeps one on the player): the overlay drives it from now on.
## A thumb on FIRE sets the client's `_firing`; auto-fire (`sv_autofire`, off by default) is read through [method is_held].
func bind_sampler(sampler: DotFpsSampler) -> void:
	if controls != null and sampler is DotFpsTouchSampler and sampler != controls.sampler:
		controls.setup(sampler, rows(_hunter, _loadout))
		_fit()


## True over the Menu button, which the overlay leaves to the button.
static func over_menu_button(settings: Object, at: Vector2) -> bool:
	var button: Control = settings.menu.menu_button if settings != null and settings.menu != null else null
	return button != null and button.is_visible_in_tree() and button.get_global_rect().has_point(at)


## A declared button held by a thumb, or Fire held by auto-fire.
func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


## True when the overlay is up and forwards [param event] itself, or [param event] is the mouse Godot emulates from a
## touch, which would turn the view and fire a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


func active() -> bool:
	return controls != null and controls.touch


## Called every frame by the client: the overlay is down while a menu, a line of chat, the console or the cover has the screen.
## A bool [param hunter] also swaps the button set to that side ([method show_for]).
func sync(busy: bool, hunter: Variant = null) -> void:
	if hunter is bool:
		show_for(hunter)
	if controls != null:
		controls.paused = busy


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


## Adds the button that opens the loadout menu, on a host that has one.
func offer_loadout(on: bool) -> void:
	if on != _loadout:
		_loadout = on
		_apply()


## Swaps the set when the side changes; a held button is let go, so nothing stays down under another label.
func show_for(hunter: bool) -> void:
	if controls != null and hunter != _hunter:
		_hunter = hunter
		_apply()


func _apply() -> void:
	if controls != null:
		controls.setup(controls.sampler, rows(_hunter, _loadout))
		_fit()


func _fit() -> void:
	if client != null and client.has_method(&"fit_touch_buttons") and controls.buttons != null:
		client.call(&"fit_touch_buttons", controls.buttons, rows(_hunter, _loadout))


func _crosshair() -> int:
	var host := owner_client
	if not is_instance_valid(host) or not host.is_inside_tree():
		return DotMobileAutoFire.TARGET_NONE
	var cam := host.get_viewport().get_camera_3d()
	var game: Object = host.get(&"game")
	var me: Object = host.get(&"player")
	if cam == null or game == null or me == null:
		return DotMobileAutoFire.TARGET_NONE
	var hulls: Array[Dictionary] = []
	for p: Object in game.players.values():
		if p == me or not is_instance_valid(p) or not p.is_alive():
			continue
		hulls.append({
			"feet": (p as Node3D).global_position,
			"height": float(p.hull_height()),
			"radius": float(p.controller.tunables.radius),
			"friend": game.team_of(p.player_id) == game.team_of(me.player_id),
		})
	var mask: int = game.physics.mask_of([&"world"]) if game.physics != null else 0
	return crosshair_kind(cam.global_position, -cam.global_basis.z, hulls, cam.get_world_3d().direct_space_state, mask)


## What the crosshair is on, from [param hulls] ({feet, height, radius, friend}, living players but the local one): the
## nearest hull the ray passes through. ENEMY for a living prop's (the only thing worth a shot), FRIEND for a fellow
## hunter, NONE when nothing is, a wall is in front or the prop is out of [constant MAX_RANGE]. Real furniture is never
## a target: a hunter pays health for it.
static func crosshair_kind(eye: Vector3, forward: Vector3, hulls: Array, space: PhysicsDirectSpaceState3D, mask: int) -> int:
	var best_t := INF
	var best: Dictionary = {}
	for h: Dictionary in hulls:
		var t := ray_hull_distance(eye, forward, h["feet"], float(h["height"]), float(h["radius"]))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = h
	if best.is_empty():
		return DotMobileAutoFire.TARGET_NONE
	if bool(best["friend"]):
		return DotMobileAutoFire.TARGET_FRIEND
	if best_t > MAX_RANGE:
		return DotMobileAutoFire.TARGET_NONE
	if space != null and mask != 0:
		var at: Vector3 = (best["feet"] as Vector3) + Vector3(0.0, float(best["height"]) * 0.5, 0.0)
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, at, mask)).is_empty():
			return DotMobileAutoFire.TARGET_NONE
	return DotMobileAutoFire.TARGET_ENEMY


## Distance along [param dir] (unit) to the closest approach of the vertical segment feet..feet+height when it passes
## within [param radius]; -1 when it misses or is behind the eye.
static func ray_hull_distance(from: Vector3, dir: Vector3, feet: Vector3, height: float, radius: float) -> float:
	var w := from - feet
	var denom := height * (dir.y * dir.y - 1.0)
	var s := 0.5 if absf(denom) < 0.0001 else (dir.y * dir.dot(w) - w.y) / denom
	s = clampf(s, 0.0, 1.0)
	var on_segment := feet + Vector3(0.0, height * s, 0.0)
	var t := dir.dot(on_segment - from)
	if t <= 0.0 or (from + dir * t).distance_to(on_segment) > radius:
		return -1.0
	return t
