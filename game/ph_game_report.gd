extends RefCounted

const PhPlayer := preload("ph_player.gd")

## What [PhGame] reports about itself and about a hit, kept out of the simulation file: the death a body gets, the hit confirmations, the describe text.


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick. A hunter's gun is a weapon def (a shotgun may launch); the
## furniture's cost and a fall carry no direction, and push nothing.
static func decide_death(
	player: PhPlayer, damage: DotDamage, shooter: PhPlayer, rules: DotPlayerRagdollRules, tick: int
) -> DotPlayerDeath:
	var weapon: Object = null
	if shooter != null and shooter.weapons != null and shooter.weapons.arsenal != null and damage.weapon_id != &"":
		weapon = shooter.weapons.arsenal.catalogue.get_def(damage.weapon_id)
	var direction := damage.direction
	if direction.length_squared() < 0.0001 and shooter != null and shooter != player:
		direction = (player.controller.state.position - shooter.controller.state.position) * Vector3(1, 0, 1)
	return DotPlayerDeath.decide(
		rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, tick), weapon
	)


## The damages of a shot that took health from somebody else, as the shooter's hit confirmations.
## A refused hit, a dead body or the shooter's own splash is no confirmation anybody wants a marker for.
static func confirmed_hits(shooter: PhPlayer, shot: DotShot) -> Array[DotDamage]:
	var out: Array[DotDamage] = []
	for damage: DotDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		out.append(damage)
	return out


## Whether nothing solid is between two points: the walls, and with [param furniture] the map's props as well.
static func clear_between(world: World3D, physics: Object, from: Vector3, to: Vector3, furniture: bool) -> bool:
	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1

	if furniture and physics != null:
		query.collision_mask |= physics.layer_mask(&"prop")

	return world.direct_space_state.intersect_ray(query).is_empty()


## The `describe_lines` of a [PhGame] (passed untyped: this file cannot name it without a cycle).
static func describe_lines(game: Variant) -> PackedStringArray:
	var lines := PackedStringArray(["prophunt, round %d" % game.round_number])
	var facts: Dictionary = game.describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	for id: StringName in game.players:
		var player: PhPlayer = game.players[id]
		lines.append("  %-8s %-18s %s%s" % [
			game.side_name(game.team_of(id)), player.display_name,
			game.props_catalogue.title_of(player.disguise.prop_id) if player.is_disguised() else "-",
			"" if player.is_alive() else " (out)",
		])

	if game.map != null:
		lines.append_array(game.map.describe_lines())

	return lines
