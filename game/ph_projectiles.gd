extends RefCounted

## A hunter's grenades in flight, and what happens where they go off.
##
## [b]Copied from game-arena's `ArenaProjectiles`, on purpose.[/b] dot-weapon spawns nothing: a
## thrown weapon's use returns a [DotWeaponSpawn] ("this should exist now") and somebody has to
## fly it. Until this file `PhGame._advance_weapons` resolved `outcome.shots` and dropped
## `outcome.spawns`, so a frag would have cost the slot and done nothing, which is why hunters had
## no grenade slot. The arena's flight (a swept segment per tick against dot-combat's own trace, a
## bounce that keeps more speed along a surface than into it, a sticky that stops dead on what it
## touches) has been played and rendered there; the parts that are this game's are marked.
##
## [b]Everything is a pure function of the tick.[/b] A server and a client fly the same spawn
## through the same code over the same map and reach the same place, so the wire carries one
## LAUNCH per grenade (`PhEvents.Kind.LAUNCH`) and nothing per tick. A client's copies decide
## nothing: its combat manager is not the authority, so [method _detonate] resolves no damage
## there and only says where it went off, which is what draws the burst.
##
## [b]A blast is resolved by dot-combat as a shot with a splash[/b], so the falloff, self damage
## and friendly fire are the same rules as every gun. What a blast COSTS is the game's
## ([signal blasted], `PhGame._on_blast`): see docs/design.md, "Grenades".

## One projectile, mid-air, rolling, or stuck to something.
class Flying extends RefCounted:
	## This game's: the server's number for it, so a client's copy and the server's are one.
	var id: int = 0
	var spawn: DotWeaponSpawn = null
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var age_ticks: int = 0
	## Bounces on a fuse, and stops on whatever it touches with `sticks`.
	var sticks: bool = false
	## Stopped: on the floor, or stuck. A stopped projectile is not swept.
	var resting: bool = false
	## What a sticky stuck to, if it was a body that moves, and where on it.
	var stuck_to: Node3D = null
	var stuck_offset: Vector3 = Vector3.ZERO
	var bounces: int = 0
	## Hitbox sets that held the launch point: team-mates the thrower stood inside (hunters do
	## not collide with each other). See [method _passes_at_launch].
	var passes: Array = []


## How much speed a fused grenade keeps off a bounce, into the surface and along it. Low into
## it, because a grenade that comes back off a wall at the speed it went in reads as rubber.
const RESTITUTION := 0.35
const SURFACE_KEEP := 0.7

## Below this it stops on a floor rather than hopping on the spot. Metres per second.
const REST_SPEED := 1.2

## Bounces before it simply stops: wedged in a corner it would otherwise bounce for its fuse.
const MAX_BOUNCES := 12

## Ticks a thrown grenade ignores its thrower, against one for something with no fuse: a grenade
## lobbed while running forward is overtaken by its thrower's own hull on the second tick.
const THROWER_GRACE_TICKS := 8

## Emitted where a projectile went off, everywhere (a client draws the burst from it).
signal detonated(at: Vector3, spawn: DotWeaponSpawn)

## This game's: emitted on the authority after dot-combat resolved the blast, with the shot it
## resolved (its `damages` are who it hurt), for what the blast costs and what it throws.
signal blasted(at: Vector3, spawn: DotWeaponSpawn, shot: DotShot)

## Emitted when one is launched, for whoever tells clients about it.
signal launched(flying: Flying)

## What the `sticks` param is read from: a spawn carries the weapon's id and the definition
## carries the rule. Null leaves every fused spawn a bouncer.
var catalogue: DotWeaponCatalogue = null

var _live: Array[Flying] = []
var _combat: DotCombatManager = null
var _gravity: float = 20.0
var _next_id: int = 1


func setup(combat: DotCombatManager, gravity: float = 20.0) -> void:
	_combat = combat
	_gravity = gravity


## Takes everything a tick of weapon use produced. Server side (and solo).
func accept(outcome: DotWeaponOutcome) -> void:
	for spawn in outcome.spawns:
		var _f := launch(spawn)


## Starts [param spawn] flying. [param id] is the server's number for it, on a client; 0 takes
## the next.
func launch(spawn: DotWeaponSpawn, id: int = 0) -> Flying:
	var f := Flying.new()
	if id > 0:
		f.id = id
	else:
		f.id = _next_id
		_next_id += 1
	f.spawn = spawn
	f.position = spawn.origin
	f.velocity = spawn.velocity
	f.sticks = _sticks(spawn)
	f.passes = _passes_at_launch(spawn)
	_live.append(f)
	launched.emit(f)
	return f


## The bodies a projectile launched at [param spawn]'s origin passes through: dot-combat's answer
## for a shot from the same muzzle, so the policy is written once. Called by name, because a
## delivered pack runs on the host's dot-combat and an older one must still load this.
func _passes_at_launch(spawn: DotWeaponSpawn) -> Array:
	if _combat == null or not _combat.has_method(&"pass_through_sets"):
		return []

	var shot := DotShot.make(spawn.id, spawn.owner_entity, spawn.tick, 0)
	shot.origin = spawn.origin
	return Array(_combat.call(&"pass_through_sets", shot))


func _sticks(spawn: DotWeaponSpawn) -> bool:
	if spawn.meta.has(&"sticks"):
		return bool(spawn.meta[&"sticks"])

	if catalogue == null:
		return false

	var def := catalogue.get_def(spawn.id)
	return def != null and bool(def.params.get(&"sticks", false))


func live_count() -> int:
	return _live.size()


## Everything in the air or on the ground, for a client to draw.
func flying() -> Array[Flying]:
	return _live


## Drops everything in flight: a round's start, a map change.
func clear() -> void:
	_live.clear()


## Advances every projectile one tick and detonates the ones that are due. Backwards, so a
## detonation can remove its own entry without the loop skipping the next one.
##
## A spawn with no fuse goes off on contact; one with a fuse (both of zee's grenades) goes off
## when it runs out, wherever it has got to: a frag bounces and rolls, a sticky stops dead on
## the first thing it touches.
func tick(delta: float) -> void:
	for i in range(_live.size() - 1, -1, -1):
		var f: Flying = _live[i]
		f.age_ticks += 1

		if _due(f):
			_detonate(f, f.position)
			_live.remove_at(i)
			continue

		if f.resting:
			_follow(f)
		else:
			if f.spawn.gravity_scale > 0.0:
				f.velocity.y -= _gravity * f.spawn.gravity_scale * delta

			var step := f.velocity * delta
			var hit := _sweep(f, step)

			if hit == null:
				f.position += step
			elif f.spawn.fuse_ticks <= 0:
				_detonate(f, hit.point)
				_live.remove_at(i)
				continue
			else:
				_touch(f, hit)

		if f.age_ticks >= f.spawn.life_ticks:
			_detonate(f, f.position)
			_live.remove_at(i)


## A fused spawn whose fuse has run out, and one with no fuse AND no speed: what dot-weapon
## gives for a grenade cooked past its fuse, at the thrower's own position, which means now.
func _due(f: Flying) -> bool:
	if f.spawn.fuse_ticks > 0:
		return f.age_ticks >= f.spawn.fuse_ticks

	return f.age_ticks <= 1 and f.velocity == Vector3.ZERO


## A fused projectile met something: stick to it or bounce off it.
func _touch(f: Flying, hit: DotHitbox.Hit) -> void:
	var normal := hit.normal

	if normal.length_squared() < 0.0001:
		normal = -f.velocity.normalized()

	# Just off the surface, so the next sweep does not start inside it.
	f.position = hit.point + normal * maxf(f.spawn.radius, 0.02)

	if f.sticks:
		f.velocity = Vector3.ZERO
		f.resting = true

		# Thrown at a person (a prop, here), it is on the person.
		var body := _body_of(hit)
		if body != null:
			f.stuck_to = body
			f.stuck_offset = f.position - body.global_position
		return

	var into := f.velocity.dot(normal)
	var along := f.velocity - normal * into
	f.velocity = along * SURFACE_KEEP - normal * into * RESTITUTION
	f.bounces += 1

	if (normal.y > 0.7 and f.velocity.length() < REST_SPEED) or f.bounces >= MAX_BOUNCES:
		f.velocity = Vector3.ZERO
		f.resting = true


## Keeps a stuck projectile on the body it stuck to.
func _follow(f: Flying) -> void:
	if f.stuck_to == null:
		return

	if not is_instance_valid(f.stuck_to) or not f.stuck_to.is_inside_tree():
		f.stuck_to = null
		return

	f.position = f.stuck_to.global_position + f.stuck_offset


func _body_of(hit: DotHitbox.Hit) -> Node3D:
	if hit.blocked or hit.hitbox == null:
		return null

	var set_node := hit.hitbox.get_parent()
	return set_node as Node3D if set_node is Node3D else null


## Traces one tick of flight. A swept segment rather than a point test: a wall is thinner than
## a fast grenade's step, and testing only the end point lets it through one time in three.
## The trace is dot-combat's (`PhGame._build_combat`: the world and the furniture), so a
## grenade bounces off a sofa as a shot stops on it.
func _sweep(f: Flying, step: Vector3) -> DotHitbox.Hit:
	if _combat == null or _combat.trace == null:
		return null

	var distance := step.length()

	if distance <= 0.0:
		return null

	var shooter := _combat.hitboxes_of(f.spawn.owner_entity)
	var grace := 1 if f.spawn.fuse_ticks <= 0 else THROWER_GRACE_TICKS
	var excluded: Array = [shooter] if shooter != null and f.age_ticks <= grace else []

	for i in range(f.passes.size() - 1, -1, -1):
		var set_node = f.passes[i]
		if not is_instance_valid(set_node):
			f.passes.remove_at(i)
		elif f.age_ticks <= grace or set_node.contains_point(f.position):
			excluded.append(set_node)
		else:
			f.passes.remove_at(i)

	_combat.trace.exclude = excluded

	var hit := _combat.trace.ray(f.position, step / distance, distance, _combat.hitbox_sets())

	_combat.trace.exclude = []

	return hit if hit.ok() else null


## Turns an arrival into an ordinary [DotShot] with a splash and lets dot-combat do the rest.
## The impact is set by hand (the trace already happened) and `max_range` is 0, so nothing
## re-traces it; this game never pins a believed origin (`set_authoritative_origin`), so
## dot-combat does not move the blast back to the thrower as it once did in the arena.
func _detonate(f: Flying, at: Vector3) -> void:
	if _combat != null and _combat.is_authority:
		var shot := DotShot.make(f.spawn.id, f.spawn.owner_entity, f.spawn.tick, 0)
		shot.origin = at
		shot.direction = f.velocity.normalized() if f.velocity != Vector3.ZERO else Vector3.DOWN
		shot.damage = 0.0
		shot.damage_type = f.spawn.damage_type
		shot.splash_type = f.spawn.damage_type
		shot.splash_radius = f.spawn.splash_radius
		shot.splash_damage = f.spawn.splash_damage
		shot.splash_hurts_owner = true
		shot.max_range = 0.0
		shot.impacts = [at]
		shot.pellets = [shot.direction]
		_combat.resolve_shot(shot)
		blasted.emit(at, f.spawn, shot)

	detonated.emit(at, f.spawn)


func describe() -> Dictionary:
	var resting := 0
	for f in _live:
		if f.resting:
			resting += 1
	return {"live": _live.size(), "resting": resting}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray(["projectiles  %d in flight, %d resting" % [int(d["live"]) - int(d["resting"]), int(d["resting"])]])
