extends RefCounted

## A hunter's loadout, as dot-loadout data: what B offers and what `PhGame._arm_hunters` hands out. Data only; the manager and command live on [code]PhGame[/code].
## Three slots: primary and secondary from the config's `hunter_weapons` (defaults) and `hunter_choices`, and an optional grenade (`thrown`, empty by default).
## Melee is not a choice: every hunter carries the hatchet, their quiet way to test a chair. No points budget; the choice is how a hunter likes to search. A blast that finds nobody costs as a decoy (`PhGame.blast_cost`).

const ZeeIds := preload("res://addons/zee_weapons/content/zee_weapon_ids.gd")

## The loadout slot each of the pack's arsenal slots goes in; nothing else is offered.
const SLOT_FOR := {
	ZeeIds.SLOT_PRIMARY: &"primary",
	ZeeIds.SLOT_SIDEARM: &"secondary",
	ZeeIds.SLOT_THROWN: &"thrown",
}

const SCHEMA_ID := &"prophunt_hunter"


## The pack's weapons named by [param ids], as items in their loadout slot. An id the pack does
## not have, or whose slot is not primary, sidearm or thrown, is skipped.
static func catalogue(ids: PackedStringArray) -> DotItemCatalogue:
	var items: Array[DotItem] = []
	var seen := {}
	for def in ZeeWeaponPack.weapons():
		if not ids.has(String(def.id)) or seen.has(def.id) or not SLOT_FOR.has(def.slot):
			continue
		seen[def.id] = true
		var item := DotItem.make(def.id, DotItem.KIND_WEAPON, true)
		item.display_name = def.display_name
		item.slots = [SLOT_FOR[def.slot]]
		item.tags = def.tags.duplicate()
		items.append(item)
	return DotItemCatalogue.of(items)


## The schema: a required primary and a required secondary, defaulting to the first primary and
## the first sidearm in [param defaults] (the config's `hunter_weapons`), and an optional grenade
## with no default, offered from [param defaults] and [param choices] together.
static func schema(defaults: PackedStringArray, choices: PackedStringArray) -> DotLoadoutSchema:
	var pool := PackedStringArray(defaults)
	for id in choices:
		if not pool.has(id):
			pool.append(id)
	var items := catalogue(pool)

	var primary := DotLoadoutSlot.make(&"primary", true, _first_in(defaults, items, &"primary"))
	primary.display_name = "Primary"
	primary.kinds = [DotItem.KIND_WEAPON]
	primary.arsenal_slot = ZeeIds.SLOT_PRIMARY
	primary.order = 10

	var secondary := DotLoadoutSlot.make(&"secondary", true, _first_in(defaults, items, &"secondary"))
	secondary.display_name = "Secondary"
	secondary.kinds = [DotItem.KIND_WEAPON]
	secondary.arsenal_slot = ZeeIds.SLOT_SIDEARM
	secondary.order = 20

	# Optional, and empty unless [param defaults] names a grenade: nobody carries one they did
	# not choose.
	var thrown := DotLoadoutSlot.make(&"thrown", false, _named_in(defaults, items, &"thrown"))
	thrown.display_name = "Grenade"
	thrown.kinds = [DotItem.KIND_WEAPON]
	thrown.arsenal_slot = ZeeIds.SLOT_THROWN
	thrown.order = 30

	return DotLoadoutSchema.of(SCHEMA_ID, [primary, secondary, thrown], items)


## The first of [param ids] that goes in [param slot], or nothing: no fallback to the catalogue.
static func _named_in(ids: PackedStringArray, items: DotItemCatalogue, slot: StringName) -> StringName:
	for id in ids:
		var item := items.find(StringName(id))
		if item != null and item.slots.has(slot):
			return item.id
	return &""


## The first of [param ids] that goes in [param slot], else the first item that does.
static func _first_in(ids: PackedStringArray, items: DotItemCatalogue, slot: StringName) -> StringName:
	for id in ids:
		var item := items.find(StringName(id))
		if item != null and item.slots.has(slot):
			return item.id
	for id in items.ids():
		if items.find(id).slots.has(slot):
			return id
	return &""


## The weapons a hunter carries: the loadout's primary, secondary and grenade, then the config's
## melee (and anything else it names outside the slots the loadout filled).
static func hunter_kit(defaults: PackedStringArray, picked: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	var slots_taken := {}
	for e in picked:
		var item: DotItem = e.get("item")
		if item != null:
			slots_taken[int(e.get("arsenal_slot", 0))] = String(item.id)
	# The primary first: the first weapon armed is the one a client draws (`PhClient._select_locally`).
	for slot in [ZeeIds.SLOT_PRIMARY, ZeeIds.SLOT_SIDEARM, ZeeIds.SLOT_THROWN]:
		if slots_taken.has(slot):
			out.append(slots_taken[slot])
	for id in defaults:
		var def := _def(StringName(id))
		if def != null and not slots_taken.has(def.slot):
			out.append(id)
	return out


static func _def(id: StringName) -> DotWeaponDef:
	for def in ZeeWeaponPack.weapons():
		if def.id == id:
			return def
	return null
