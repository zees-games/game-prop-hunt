extends "headless_run_base.gd"
## The hunter's weapon checks of the headless run suite; headless_run.gd extends this.


## The drawn rig must show the gun the server fired: given the whole pack, each slot held whatever
## was given last; the default loadout put the SMG and shotgun in one slot; the HUD said nothing
## about what was in hand.
func _shots_and_walls(world: PhGame, me: PhPlayer, drawn: ZeeWeaponRig) -> void:
	var motor := me.controller.tunables.collision_mask
	_check(motor != 0 and me.weapons.wall_extra_mask == motor,
		"the server rig's wall_extra_mask is the player's motor mask", "%d vs %d" % [me.weapons.wall_extra_mask, motor])
	_check(drawn.wall_extra_mask == motor and drawn.role == ZeeWeaponRig.Role.LOCAL,
		"and the drawn rig's too", "%d vs %d" % [drawn.wall_extra_mask, motor])
	var view: Variant = drawn.get(&"_view")
	var fx: Variant = drawn.get(&"_fx")
	_check(view != null and fx != null and (int(view.get(&"wall_mask")) & motor) == motor
		and (int(view.get(&"wall_mask")) & int(fx.get(&"collision_mask"))) == int(fx.get(&"collision_mask")),
		"the drawn view's wall probe stops on the motor mask and the shot mask both",
		"wall_mask %s" % str(view.get(&"wall_mask")) if view != null else "no view")

	var from := Vector3(500.0, 50.0, 500.0)
	var to := from + Vector3(0.0, 0.0, -10.0)
	var trace := world.combat.trace
	_check(trace.line_of_sight(from, to), "a clear line is clear")
	var layers := {&"world": false, &"prop": false, &"player": true, &"toy": true, &"footprint": true}
	for id in layers:
		var body := StaticBody3D.new()
		body.collision_layer = world.physics.layer_mask(id)
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4.0, 4.0, 0.5)
		shape.shape = box
		body.add_child(shape)
		world.add_child(body)
		body.global_position = from + Vector3(0.0, 0.0, -5.0)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var clear := trace.line_of_sight(from, to)
		_check(clear == bool(layers[id]), "a %s-layer body %s the shot" % [id, "passes" if layers[id] else "blocks"],
			"line_of_sight %s" % str(clear))
		body.collision_layer = 0
		world.remove_child(body)
		body.free()


func _test_hunter_weapons() -> void:
	_section("a hunter draws the guns the server armed, counted on the HUD and corrected from it")
	_check(PhGame.hunter_slot_clash(PhConfig.new().hunter_weapons) == "",
		"no two of the default hunter weapons share a slot", PhGame.hunter_slot_clash(PhConfig.new().hunter_weapons))
	_check(PhGame.hunter_slot_clash(PackedStringArray(["smg", "shotgun"])) == "smg/shotgun",
		"and two that do are named")

	var client: Node = (load("res://game/ph_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"remember_loadout", false)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	for i in 8:
		await get_tree().process_frame
	var world: PhGame = client.get("game")
	world.wish_side(&"local", PhGame.HUNTERS)
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().physics_frame

	var me: PhPlayer = client.get("player")
	var drawn: ZeeWeaponRig = client.get("weapons")
	var held: Array[String] = []
	var same := drawn != null and me.weapons != null and drawn != me.weapons
	for slot in range(1, 6):
		var mine := drawn.arsenal.slot_at(slot) if drawn != null else null
		var theirs := me.weapons.arsenal.slot_at(slot) if me.weapons != null else null
		var a := String(mine.def.id) if mine != null else "-"
		var b := String(theirs.def.id) if theirs != null else "-"
		held.append("%d:%s/%s" % [slot, a, b])
		same = same and a == b
	_check(same, "the drawn gun holds exactly the server's weapons, slot for slot", " ".join(held))
	_check(drawn != null and drawn.arsenal.current_slot() == me.weapons.arsenal.current_slot(),
		"and holds the same one")
	_check_wheel_step(client, drawn)
	await _shots_and_walls(world, me, drawn)

	# Blindfolded through the hide, the counter is under the cover with everything else; seeking.
	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	_check(counter != null and not counter.visible, "no counter under the blindfold")
	world._set_phase(PhGame.Phase.SEEK)
	hud.call("_process", 0.0)
	var def := drawn.current_def() if drawn != null else null
	var expected := "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] if def != null else "?"
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and counter.count_text() == expected,
		"a hunter's HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])

	_check_hunter_icons(hud, counter, def)

	_check_hunter_hints(hud, drawn)

	# Bottom right, clear of the chat box and the health plate bottom left, and of the ballot
	# top right: the anchors put it in the bottom-right quarter at any frame size.
	_check(counter.anchor_left == 1.0 and counter.anchor_top == 1.0 and counter.offset_left >= -480.0
		and counter.offset_top >= -120.0 and counter.get_theme_color(&"plate", DotHudPiece.THEME_TYPE).a > 0.0,
		"it sits bottom right, in the game's theme, clear of the chat, the health plate and the ballot")

	# A shot the server never heard: the drawn gun is five down. It holds while it could still be
	# in flight, and takes the world's count once quiet.
	var world_count := me.weapons.arsenal.current().magazine
	drawn.arsenal.current().magazine = maxi(world_count - 5, 0)
	client.set("_drawn_quiet", 0.0)
	for i in 10:
		await get_tree().physics_frame
	var early := drawn.arsenal.current().magazine
	for i in 60:
		await get_tree().physics_frame
	_check(early == maxi(world_count - 5, 0) and drawn.arsenal.current().magazine == world_count,
		"the drawn gun takes the server's count once quiet, and not before",
		"after 10 ticks %d, after 70 %d, server %d" % [early, drawn.arsenal.current().magazine, world_count])

	# The play test's "no damage shooting sinks and boxes" after he had walked into them: the
	# furniture is one static body, so nothing a hunter does moves a prop out of the box the
	# decoy check reads (`PhMap.prop_containing`, from the document).
	await _hunter_weapons_rest(client, world, hud, counter)


## The weapon wheel's "next" steps a hunter to the next carried slot.
func _check_wheel_step(client: Node, drawn: ZeeWeaponRig) -> void:
	var ring: Array = drawn.arsenal.slots()
	var step := InputEventAction.new()
	step.action = &"dot_menu_weapon_next"
	step.pressed = true
	# The pointer is never captured headless, so only that one clause of the block is lifted.
	client.call("_wheel_pressed", InputEventAction.new())
	var wheel: DotWeaponWheel = client.get(&"_wheel")
	wheel.blocked = func() -> bool: return false
	var slot_before: int = client.get(&"_slot")
	var took: bool = client.call("_wheel_pressed", step)
	var slot_after: int = client.get(&"_slot")
	client.set(&"_slot", slot_before)
	var want: int = ring[posmod(ring.find(drawn.arsenal.current_slot()) + 1, ring.size())] if ring.size() > 1 else 0
	_check(ring.size() < 2 or (took and slot_after == want),
		"the wheel steps a hunter to the next carried slot", "took %s, slot %s, want %d" % [took, slot_after, want])


func _hunter_weapons_rest(client: Node, world: PhGame, hud: Node, counter: DotAmmoCounter) -> void:
	_check(world.map.get("_furniture") is StaticBody3D, "furniture cannot be pushed out of the place a decoy is judged at")

	# A hit the world confirms (offline the world is the server): the marker flashes. Before
	# this nothing said a hunter's shot had landed at all.
	var marker: DotHitMarker = hud.get("hit_marker")
	world.hit_landed.emit(&"local", Vector3(0.0, 1.0, -4.0), false, true)
	_check(marker != null and marker.alpha() > 0.9 and marker.headshot, "a hit the world confirms flashes the hit marker")

	world._set_side(&"local", PhGame.PROPS)
	hud.call("_process", 0.0)
	_check(not counter.visible, "a prop has no counter")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## The HUD's weapon sprite: every mapped weapon has one, the style cvar hides it, it sits above the plate.
func _check_hunter_icons(hud: Node, counter: DotAmmoCounter, def: DotWeaponDef) -> void:
	var icon_script: Script = load("res://game/ph_weapon_icons.gd")
	var icons: DotWeaponIconStyle = icon_script.get("shared")
	var icon_rect: DotWeaponIconPlate = hud.get("weapon_icon")
	var unmapped := PackedStringArray()
	for weapon in icon_script.get("TAGS"):
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	_check(unmapped.is_empty() and icon_rect != null and icon_rect.texture != null and icon_rect.texture == icons.texture(def.id),
		"the HUD draws the held gun's sprite over the counter, and every mapped weapon has one", ", ".join(unmapped))
	var _silhouette := icons.set_style(&"silhouette")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.texture == null, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.texture != null and icon_rect.get_global_rect().end.y <= counter.get_global_rect().position.y + 4.0,
		"the sprite sits above the ammunition plate, not on it")


## The hints name the keys of what is carried (they once said "1-3 Weapons" after grenades went to slot five).
func _check_hunter_hints(hud: Node, drawn: ZeeWeaponRig) -> void:
	var hints: Label = hud.get("_hints")
	_check(hints.text.contains("1 2 3  Weapons") and not hints.text.contains("Grenade"),
		"a hunter's hints name keys 1 2 3 for the weapons and no grenade by default", hints.text)
	drawn.arsenal.give(&"frag")
	hud.call("_process", 0.0)
	var with_grenade := hints.text
	drawn.arsenal.take(ZeeIds.SLOT_THROWN)
	hud.call("_process", 0.0)
	_check(with_grenade.contains("1 2 3  Weapons   5  Grenade") and not hints.text.contains("Grenade"),
		"and key 5 for a grenade while one is carried", with_grenade)
