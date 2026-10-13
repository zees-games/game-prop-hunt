extends CanvasLayer

const PhGame := preload("ph_game.gd")
const PhPlayer := preload("ph_player.gd")
const PhBindings := preload("ph_bindings.gd")
const ZeeIds := preload("res://addons/zee_weapons/content/zee_weapon_ids.gd")

## What a player needs on screen: the clock and who it is counting for, which side they are on
## and how much of them is left, what they are hiding as, and — while the props hide — a
## blindfold for the hunters.
##
## [b]The blindfold is a screen, and the HUD is drawn over it.[/b] The brief: hunters cannot see
## the map, the props or each other while the props hide, but they can still see their HUD and
## use the menus. So it is a black rect UNDER every widget here, with its own line saying how
## long is left; the world behind it is not drawn at all. It does not depend on the client
## being honest about drawing: a blindfolded hunter is also held still by a movement modifier
## the server owns (see [PhController]), and their gun is the server's to fire.
##
## [b]The glance pieces are dot-ui's.[/b] The clock is a [DotScoreStrip] with the props and
## hunters still up as its two side plates, in the sides' colours; health is a [DotVitals]
## whose fill is the player's side colour; "look at a prop and press E" is a [DotKeyPrompt]
## under the crosshair. Health used to be a number on a disc in the side's colour. The disc
## said which side you are on and nothing about how much of you is left: a prop's health is
## a share of a size-derived maximum (10 to 200), so 40 is nearly dead as a wardrobe and
## whole as a bottle. The bar says the share, its fill keeps the side's colour, and the side
## is also the plates' colours and the word beside it. Decided 2026-10-11 (hud-pieces).
##
## [b]The keys are read from the bindings, not written here.[/b] The hints in the corner say
## the key each action is on NOW, from the same table the menu's Controls page edits, so a
## rebound key is never a hint that lies.

const BLIND_FADE_SEC := 0.25
const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## The blindfold is not quite black: a hunter should be able to tell it from a client that
## stopped drawing.
const BLINDFOLD_COLOUR := Color(0.03, 0.025, 0.04)

## Seconds left at which the clock turns red.
const LOW_CLOCK_SEC := 10.0

## The map name's pale blue, which is also the glance pieces' highlight.
const MAP_COLOUR := Color(0.80, 0.88, 0.98)


## This game's accent over whichever theme the player picked in the menu (its highlight and
## the plates' edge). The plates, the words and their outline are the theme's, dark by default,
## so a light or high-contrast theme can change them. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate_edge", type, Color(MAP_COLOUR, 0.3))
	t.set_color(&"highlight", type, MAP_COLOUR)
	return t


## The Escape menu, whose theme this HUD follows (dot-menu's `follow_hud`): the menu sets the
## theme on the HUD's root now and at every theme change, and applies the player's HUD size.
## Christian's first play test (2026-10-11) asked for a darker HUD a player can restyle in
## the menu. Duck-typed and called by name, for a client shell older than dot-menu 7.
var _menu: Object = null


func follow_menu(menu: Object) -> void:
	_menu = menu
	_follow()


func _follow() -> void:
	if _root != null and _menu != null and _menu.has_method(&"follow_hud"):
		_menu.call(&"follow_hud", _root, piece_theme())


var game: PhGame = null
var player: PhPlayer = null

## `func(action: StringName) -> String`: the key an action is on, from the bindings.
var key_fn: Callable = Callable()
## Whether B opens a hunter's loadout here (the client has dot-menu's loadout menu): the
## blindfold and a hunter's hints then name its key.
var loadout_offered: bool = false

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null

## An administrator's `blind`, over the world and under the HUD.
var blind_overlay: ColorRect = null

## The hunters' blindfold while the props hide, under the HUD's widgets.
var blindfold: ColorRect = null

var _root: Control = null
## The clock, the props and hunters still up either side of it, and the caption and map
## name under it.
var strip: DotScoreStrip = null
## Health, as a share of this body's or disguise's maximum, in the side's colour.
var vitals: DotVitals = null
## "Look at a prop" with the disguise key drawn as a key, while a prop is undisguised.
var prompt: DotKeyPrompt = null
## Bottom right, a hunter's: the weapon in hand and `magazine | reserve`. See [method _draw_ammo].
var ammo: DotAmmoCounter = null
## The rig the counter reads: the gun the client draws (`PhClient.weapons`), which the server's
## count corrects (`PhClient._correct_drawn`). Unset, the player's own rig.
var weapons_fn: Callable = Callable()

## Four ticks round the crosshair for a hit the server confirmed. See [method confirm_hit].
var hit_marker: DotHitMarker = null
var _shout: Label = null
var _hints: Label = null
var _as: Label = null
var _lock: Label = null
var _meter_back: ColorRect = null
var _meter_fill: ColorRect = null
var _meter_label: Label = null
var _blindfold_label: Label = null
var _crosshair: ColorRect = null
## Through a scoped gun at full aim: zee's circle and reticle (the gun is not drawn then).
var scope: ZeeScopeOverlay = null
## 0 at the hip to 1 down the sights, from the client's view model ([method set_aim]).
var aim_fraction: float = 0.0
## Whether the host's dot-ui has `DotCrosshair.opacity_for_aim` (API 5).
var _fades: bool = DotAddonApi.build_level("dot_ui") >= 5
var _shout_for: float = 0.0


func bind(p_game: PhGame, p_player: PhPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# A full-rect Control between the CanvasLayer and the labels: a CanvasLayer does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Under everything, the blindfold included: the scope is the view, the HUD reads over it.
	scope = ZeeScopeOverlay.new()
	scope.name = "Scope"
	_root.add_child(scope)

	blindfold = _cover("Blindfold", BLINDFOLD_COLOUR)
	blind_overlay = _cover("Blind", BLIND_COLOUR)

	_blindfold_label = _label(30)
	_blindfold_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_blindfold_label.offset_left = -520.0
	_blindfold_label.offset_right = 520.0
	_blindfold_label.offset_top = -60.0
	_blindfold_label.offset_bottom = 60.0
	_blindfold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blindfold_label.add_theme_color_override("font_color", Color(0.98, 0.78, 0.45))

	# The glance pieces read their colours from the theme on the type DotHudPiece; set on
	# the root, every piece under it inherits them. See [method piece_theme].
	_root.theme = piece_theme()
	_follow()

	# Top centre, full width because the strip centres itself on its own middle. Its plates
	# span 388 pixels round the middle, clear of the key hints top left at 1280 x 720.
	strip = DotScoreStrip.new()
	strip.name = "Clock"
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.offset_top = 14.0
	strip.offset_bottom = 94.0
	_root.add_child(strip)

	# Under the crosshair: what the disguise key does right now.
	prompt = DotKeyPrompt.new()
	prompt.name = "Prompt"
	prompt.font_size = 19
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	prompt.offset_left = -300.0
	prompt.offset_right = 300.0
	prompt.offset_top = 26.0
	prompt.offset_bottom = 62.0
	prompt.visible = false
	_root.add_child(prompt)

	# Top left: the keys this side has, as the player has them bound.
	_hints = _label(15)
	_hints.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_hints.offset_left = 22.0
	_hints.offset_top = 18.0
	_hints.offset_right = 420.0
	_hints.offset_bottom = 260.0

	_shout = _label(40)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 170.0
	_shout.offset_bottom = 240.0
	_shout.offset_left = -600.0
	_shout.offset_right = 600.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# Bottom left: health on its plate, and over it what you are, the rotation lock and the
	# forced-taunt meter. The plate ends 214 pixels off the bottom, above the chat box's full
	# eight-row log, which reaches 202 (checked in headless_run).
	vitals = DotVitals.new()
	vitals.name = "Vitals"
	vitals.bar_end = 220.0
	vitals.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	vitals.offset_left = 22.0
	vitals.offset_right = 22.0 + 340.0
	vitals.offset_top = -270.0
	vitals.offset_bottom = -214.0
	vitals.visible = false
	_root.add_child(vitals)

	# Bottom right, a hunter's: what is in hand and how much is in it. The chat box and the
	# health plate are bottom left and the ballot top right, so nothing it shares a corner with;
	# a ballot that does reach it dims it (DotHudPiece's cover), and headless_run checks the
	# corners. "1-3 Weapons" on the hints said what to press and nothing said what you held.
	ammo = DotAmmoCounter.new()
	ammo.name = "Ammo"
	ammo.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo.offset_left = -420.0
	ammo.offset_right = -24.0
	ammo.offset_top = -100.0
	ammo.offset_bottom = -24.0
	ammo.visible = false
	_root.add_child(ammo)

	hit_marker = DotHitMarker.new()
	hit_marker.name = "HitMarker"
	hit_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(hit_marker)

	_as = _label(17)
	_as.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_as.offset_left = 24.0
	_as.offset_right = 600.0
	_as.offset_top = -356.0
	_as.offset_bottom = -328.0

	_lock = _label(15)
	_lock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_lock.offset_left = 24.0
	_lock.offset_right = 600.0
	_lock.offset_top = -328.0
	_lock.offset_bottom = -304.0
	_lock.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))

	# The forced-taunt meter, just over the health plate: how long a prop has before it gives
	# itself away for standing still.
	_meter_back = _bar(Color(0.0, 0.0, 0.0, 0.45))
	_meter_fill = _bar(Color(0.98, 0.62, 0.20, 0.95))
	_meter_label = _label(15)
	_meter_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_meter_label.offset_left = 232.0
	_meter_label.offset_right = 520.0
	_meter_label.offset_top = -294.0
	_meter_label.offset_bottom = -274.0

	watching_label = _label(20)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	_crosshair = ColorRect.new()
	_crosshair.name = "Crosshair"
	_crosshair.color = Color(1.0, 1.0, 1.0, 0.75)
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.offset_left = -3.0
	_crosshair.offset_top = -3.0
	_crosshair.offset_right = 3.0
	_crosshair.offset_bottom = 3.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_crosshair)


func _cover(cover_name: String, colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = cover_name
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.modulate.a = 0.0
	rect.visible = false
	_root.add_child(rect)
	return rect


func _bar(colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	rect.offset_left = 24.0
	rect.offset_right = 224.0
	rect.offset_top = -288.0
	rect.offset_bottom = -280.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	_root.add_child(rect)
	return rect


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var side := game.team_of(player.player_id) if player != null else 0
	var left := game.seconds_left()

	var caption := ""
	match game.phase:
		PhGame.Phase.HIDE:
			caption = "Hunters released in"
		PhGame.Phase.SEEK:
			caption = "Props win in" if game.config.timeout_winner == PhGame.PROPS else "Time left"
		_:
			caption = "waiting for players" if not game.sides_are_playable() else "between rounds"

	# The caption under the clock rather than over it, as the strip draws every game's: it
	# reads "Props win in · Maple Grove School".
	var running := game.phase != PhGame.Phase.IDLE
	strip.show_clock(
		DotScoreStrip.clock_text(left) if running else "", running and left <= LOW_CLOCK_SEC,
		caption, str(game.map_doc.get("name", ""))
	)
	if running:
		strip.show_scores(
			game.alive_on(PhGame.PROPS), game.alive_on(PhGame.HUNTERS), "PROPS LEFT", "HUNTERS",
			game.side_colour(PhGame.PROPS), game.side_colour(PhGame.HUNTERS)
		)
	else:
		strip.hide_scores()

	_draw_vitals(side)
	_draw_ammo(side)
	_draw_hints(side)
	_draw_meter(side)
	_crosshair.visible = side == PhGame.HUNTERS and player != null and player.is_alive() and not is_blindfolded()

	if _shout_for > 0.0:
		_shout_for -= delta
		if _shout_for <= 0.0:
			_shout.text = ""


func _draw_vitals(side: int) -> void:
	var shown := player != null and player.is_alive() and not player.watching and side != 0 \
		and player.health != null
	vitals.visible = shown
	_as.text = ""
	_lock.text = ""
	var words := ""

	if shown:
		# The side's colour as the fill, which is what the disc said; a cross only on a body,
		# because a chair's health is not a person's.
		vitals.fill_colour = game.side_colour(side)
		vitals.show_cross = side == PhGame.HUNTERS or not player.is_disguised()
		vitals.show_vitals(player.health.health, player.health.max_health)
		_as.add_theme_color_override("font_color", game.side_colour(side).lightened(0.45))

		if side != PhGame.PROPS:
			_as.text = "HUNTER"
		elif player.is_disguised():
			_as.text = "You are: %s" % game.props_catalogue.title_of(player.disguise.prop_id)
			_lock.text = "ROTATION LOCKED" if player.disguise.locked else "rotation free  (%s locks)" % _key(PhBindings.LOCK)
		elif player.set_aside != null:
			_as.text = "Showing yourself  (+points)"
			_lock.text = "%s to hide again" % _key(PhBindings.REVEAL)
		else:
			_as.text = "PROP"
			words = "Look at a prop and become it"

	if words == "" or is_blind():
		prompt.clear()
	else:
		prompt.show_prompt(words, _key(PhBindings.DISGUISE))


## The counter, from the rig the hunter draws: the magazine and the reserve, low at a quarter of
## a magazine (when a reload is worth starting); a melee weapon by its name alone.
func _draw_ammo(side: int) -> void:
	var rig := _rig()
	var def := rig.current_def() if rig != null and is_instance_valid(rig) and rig.arsenal != null else null
	var shown := def != null and side == PhGame.HUNTERS and player != null and player.is_alive() \
		and not player.watching and not is_blindfolded()
	ammo.visible = shown

	if not shown:
		ammo.clear()
		return

	var title := def.display_name if def.display_name != "" else String(def.id)

	if def.ammo_type == &"" or rig.arsenal.current() == null:
		ammo.show_ammo(title, -1, -1)
		return

	var held := rig.arsenal.current()
	var reserve := rig.arsenal.ammo().count(def.ammo_type)

	if def.magazine > 0:
		ammo.show_ammo(title, held.magazine, reserve,
			float(held.magazine) <= float(def.magazine) * 0.25, def.infinite_reserve)
	else:
		ammo.show_ammo(title, reserve, -1, reserve <= 0, false)


func _draw_hints(side: int) -> void:
	if player == null or not player.is_alive() or player.watching or side == 0 or is_blindfolded():
		_hints.text = ""
		return

	var lines := PackedStringArray()

	if side == PhGame.PROPS:
		lines.append("%s  Become what you look at" % _key(PhBindings.DISGUISE))
		lines.append("%s  Show yourself / hide again" % _key(PhBindings.REVEAL))
		lines.append("%s  Lock rotation" % _key(PhBindings.LOCK))
		lines.append("%s / %s  Taunt / pick one" % [_key(PhBindings.TAUNT), _key(PhBindings.TAUNT_MENU)])
		lines.append("%s %s %s %s  Tilt   %s  Upright" % [
			_key(PhBindings.TILT_FORWARD), _key(PhBindings.TILT_BACK),
			_key(PhBindings.TILT_LEFT), _key(PhBindings.TILT_RIGHT), _key(PhBindings.STRAIGHTEN)])

		if player.reveal_wait > 0.0 and player.is_disguised():
			lines.append("show yourself again in %d s" % int(ceilf(player.reveal_wait)))
	else:
		lines.append("Shoot the props. Shooting furniture hurts you.")
		lines.append(_weapon_hint())
		lines.append("%s  Aim   %s  Quick melee" % [_key(PhBindings.AIM), _key(PhBindings.BASH)])
		if loadout_offered:
			lines.append("%s  Loadout (next round)" % _key(&"dot_menu_loadout"))

	_hints.text = "\n".join(lines)


func _draw_meter(side: int) -> void:
	var shown := side == PhGame.PROPS and player != null and player.is_alive() \
		and game.phase == PhGame.Phase.SEEK and game.config.show_taunt_meter and player.taunt_meter > 0.02
	_meter_back.visible = shown
	_meter_fill.visible = shown
	_meter_label.text = ""

	if not shown:
		return

	_meter_fill.offset_right = 24.0 + 200.0 * clampf(player.taunt_meter, 0.0, 1.0)
	var until := (1.0 - player.taunt_meter) * game.config.auto_taunt_seconds
	_meter_label.text = "Move, or you taunt in %d s" % int(ceilf(until))


## The rig the hunter draws (the client's, corrected from the server's), else the player's own.
func _rig() -> ZeeWeaponRig:
	if weapons_fn.is_valid():
		return weapons_fn.call() as ZeeWeaponRig
	if player != null and is_instance_valid(player):
		return player.weapons
	return null


## "R  Reload   1 2 3  Weapons   5  Grenade", from the slots the hunter carries and the keys they
## are bound to. It said "1-3 Weapons" whatever was carried and however the keys were bound, so a
## grenade taken on B (slot five) was on a key the hints never named.
func _weapon_hint() -> String:
	var rig := _rig()
	var carried: Array[int] = [1, 2, 3]
	if rig != null and is_instance_valid(rig) and rig.arsenal != null:
		carried = rig.arsenal.slots()
	var weapons := PackedStringArray()
	var grenade := ""
	for slot in carried:
		if slot < 1 or slot > PhBindings.SLOTS.size():
			continue
		var key := _key(PhBindings.SLOTS[slot - 1])
		if slot == ZeeIds.SLOT_THROWN:
			grenade = key
		else:
			weapons.append(key)
	var line := "%s  Reload" % _key(PhBindings.RELOAD)
	if not weapons.is_empty():
		line += "   %s  Weapons" % " ".join(weapons)
	if grenade != "":
		line += "   %s  Grenade" % grenade
	return line


func _key(action: StringName) -> String:
	return str(key_fn.call(action)) if key_fn.is_valid() else String(action)


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var step := maxf(delta, 0.0) / BLIND_FADE_SEC
	blind_overlay.modulate.a = move_toward(blind_overlay.modulate.a, 1.0 if is_blind() else 0.0, step)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	var folded := is_blindfolded()
	blindfold.modulate.a = move_toward(blindfold.modulate.a, 1.0 if folded else 0.0, step)
	blindfold.visible = blindfold.modulate.a > 0.0

	if _blindfold_label != null:
		_blindfold_label.visible = folded

		if folded and game != null:
			var left := game.seconds_left()
			# The strip's own words, so the two clocks on a hunter's screen never disagree by
			# the second one rounds down and the other up.
			_blindfold_label.text = "Blindfolded while the props hide\n%s" % DotScoreStrip.clock_text(left)
			# The hide is when a new loadout goes straight into the hands (PhGame.rearm_if_allowed).
			if loadout_offered:
				_blindfold_label.text += "\n%s  Choose your loadout" % _key(&"dot_menu_loadout")


## The aim this frame, from the client: the dot fades out as the gun comes up (dot-ui's
## `DotCrosshair.opacity_for_aim`, the arena's curve) and a scope hides it for its own reticle.
func set_aim(fraction: float, scoped: bool) -> void:
	aim_fraction = clampf(fraction, 0.0, 1.0) if is_finite(fraction) else 0.0
	if scope != null:
		scope.fraction = aim_fraction if scoped else 0.0
	if _crosshair != null:
		_crosshair.modulate.a = 0.0 if scoped else crosshair_opacity(aim_fraction)


## How much of the dot [param fraction] leaves: dot-ui's curve where the host has it, else the
## dot stays (an older shell had no aim to fade for).
func crosshair_opacity(fraction: float) -> float:
	if not _fades:
		return 1.0
	# Through a Variant: named directly, an older dot-ui without it fails to compile this script.
	var crosshair: Variant = DotCrosshair
	return float((crosshair as Script).call(&"opacity_for_aim", fraction))


func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


## Whether this player is a hunter while the props hide.
func is_blindfolded() -> bool:
	return player != null and is_instance_valid(player) and game != null \
		and game.phase == PhGame.Phase.HIDE and game.team_of(player.player_id) == PhGame.HUNTERS \
		and player.is_alive()


## A hit the server confirmed for this hunter's shot: the marker, larger and red on a kill.
func confirm_hit(killed: bool, headshot: bool) -> void:
	if hit_marker != null:
		hit_marker.flash(killed, headshot)
