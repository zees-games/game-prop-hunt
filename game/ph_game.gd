extends Node3D

const PhCatalogue := preload("ph_catalogue.gd")
const PhConfig := preload("ph_config.gd")
const PhMap := preload("ph_map.gd")
const PhMapDoc := preload("ph_map_doc.gd")
const PhPaths := preload("ph_paths.gd")
const PhPlayer := preload("ph_player.gd")
const PhProgress := preload("ph_progress.gd")
const PhProps := preload("ph_props.gd")
const PhRules := preload("ph_rules.gd")
const PhSpectate := preload("ph_spectate.gd")
const PhBots := preload("ph_bots.gd")
const PhDebris := preload("ph_debris.gd")
const PhController := preload("ph_controller.gd")
const PhLoadout := preload("ph_loadout.gd")
const PhProjectiles := preload("ph_projectiles.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is hiding and then seeking.[/b] At the top of each round some players are drawn
## as hunters and everybody else is a prop. For [member PhConfig.hide_seconds] the props run off
## and turn into furniture while the hunters stand blindfolded and held where they started.
## Then the hunters are let go, armed, to find them: every prop shot is out, and so is any
## hunter who shoots enough of the real furniture. Every prop found is the hunters' round; any
## prop still standing when the clock runs out is the props'.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's (decided through [PhRules]); who becomes a hunter is dot-team's
## [DotTeamRotation]; what a disguise is and what it costs is dot-props' [DotPropDisguise] and
## its taunts are [DotPropTaunts]; health and shots are dot-combat's; the weapons are
## zee-dot-weapons'. The map, the furniture and the rules of this game are its own.

const CHANNEL := "ph.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"ph_game"

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"dot_solo"

## Snapshots a second. What a hunter reads continuously is a prop moving across a room.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const PROPS := 1
const HUNTERS := 2

const TEAM_COLOURS: Array[Color] = [
	Color(0.30, 0.58, 0.96),
	Color(0.97, 0.56, 0.16),
]

const TEAM_NAMES: Array[String] = ["Props", "Hunters"]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people.
	IDLE,
	## The props hide; the hunters are blindfolded and held still.
	HIDE,
	## The hunters are let go.
	SEEK,
}

const DIED_SHOT := &"shot"
const DIED_DECOY := &"decoy"
const DIED_FELL := &"fell"

## The burst drawn where a grenade went off (dot-fx).
const BLAST_FX := &"blast"

## What a turn request asks of a disguise.
enum Turn { LOCK, TILT_FORWARD, TILT_BACK, TILT_LEFT, TILT_RIGHT, STRAIGHTEN }

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)
signal round_began(number: int, map_id: StringName)
signal world_clearing()
signal world_rebuilt()
signal round_over(number: int, winner: int, winner_name: String)
signal phase_changed(phase: int)
signal side_changed(player_id: StringName, side: int)
signal player_died(player_id: StringName, by: StringName, why: StringName)

## Somebody's disguise changed: a new prop, their own face, a turn, a lock.
signal disguise_changed(player_id: StringName)

## Somebody taunted: [param taunt_id] from the taunt list, forced or chosen.
signal taunted(player_id: StringName, taunt_id: StringName, forced: bool)

## Something a player asked for was refused, and why. Told to them alone.
signal refused(player_id: StringName, why: String)

## A hunter shot the furniture and paid for it.
signal decoy_hit(player_id: StringName, amount: float)

## A breakable piece of the map's furniture was shot to bits (index into [code]map.props[/code]),
## from [param direction]. Both ends; a client throws its debris.
signal prop_broken(index: int, direction: Vector3)

signal achievement_earned(player_id: StringName, title: String, points: int)
signal player_armed(player_id: StringName, weapon_id: StringName)

## A weapon's shot took health off somebody: to [param player_id], the shooter, for the hit
## marker and the hit drawn on the body. The server's word, never a client's prediction.
signal hit_landed(player_id: StringName, point: Vector3, killed: bool, headshot: bool)

## A hunter's grenade went off at [param at]: everywhere a world is drawn (a client flies its own
## copies, `PhProjectiles`), for the burst and the sound.
signal blast_drawn(at: Vector3, weapon_id: StringName)

@export var config: PhConfig = null
@export var authoritative: bool = true
@export_range(1, 240, 1) var tick_rate: int = 64
@export var external_tick: bool = false
@export var register_service: bool = true

## Whether the map is drawn. A client sets it.
@export var draw_world: bool = false

var map: PhMap = null
var catalogue: PhCatalogue = null
var props_catalogue: PhProps = null
var combat: DotCombatManager = null
## Whether a player may be hurt or eliminated now: `func(player_id: StringName) -> bool`, assigned
## by the module (dot-game's "still loading": a seat behind its client's cover cannot see and is
## frozen by its own client, so a shot, a decoy charge or a fall must not end it). Unset offline,
## and bots are never loading, so offline rounds are unchanged.
var harm_gate: Callable = Callable()
## The hunters' grenades in flight (`ph_projectiles.gd`): flown on the server and solo, and as
## copies on a client from the LAUNCH events (`PhNetBridge`), which decide nothing.
var projectiles: PhProjectiles = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null
var effects: DotFxManager = null
var spectate: PhSpectate = null
var progress: PhProgress = null
var taunts: DotPropTaunts = null
var rules: DotPropDisguiseRules = null

## A hunter's loadout (dot-loadout): primary and secondary from `ph_loadout.gd`'s schema, keyed
## by [method storage_key]. Null on a world that keeps none.
var loadouts: DotLoadoutManager = null

## The B menu's server half (dot-loadout's `DotLoadoutCommand`): the `/loadout` command, its
## `loadout_menu` notice and the owner's `mp_loadout_*` cvars, which the module binds. Solo the
## client asks it directly. Untyped and loaded by path because a host whose dot-loadout predates
## API 2 has no such class; null there, and B is not offered.
var loadout_command: Object = null

## player id -> PhPlayer.
var players: Dictionary = {}

## dot-player-controller's `mp_forceview`: whether a player may switch views (0), or is held
## in first (1) or third person (2); a prop and a hunter start in their side's view either
## way. Bound by the module (REPLICATED) and followed by a client through its link. (No
## `mp_solidplayers` here: a disguised player is the shape of their prop, and the rule's
## standing hull would be the wrong one.)
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. A person's body only: a disguised prop that dies
## is drawn as `PhConfig.prop_death` says (docs/design.md, "A death").
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## dot-props' `sv_toys*` (whether a map's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## player id -> side.
var sides: Dictionary = {}

## The map the next round plays, set by the players' vote or an operator, used once.
var next_map_id: StringName = &""

var round_number: int = 0

## Seconds into the current phase, and into the seeking. Simulated, never a wall clock.
var phase_elapsed: float = 0.0
var seek_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The map this round is played on.
var map_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_props: int = -1
var remote_hunters: int = -1
var remote_playable: bool = false

## Who has had the hunters' role, for [DotTeamRotation].
var hunter_history: Dictionary = {}

var _tick: int = 0
var _round_seed: int = 0
var _rounds_on_map: int = 0
var _map_unplayed: bool = false
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## Map prop index -> damage taken this round, for the breakable ones. Server side.
var _prop_damage: Dictionary = {}

## The stand-ins' brains and the map's survey for them (`ph_bots.gd`). Server side and solo.
var bots: PhBots = PhBots.new(self)

## What the stand-ins are called, solo and on a server; past the end dot-bot numbers them.
const BOT_NAMES := ["Lamp", "Ottoman", "Houseplant", "Toaster", "Bookcase", "Teddy", "Fridge", "Stool"]


func _ready() -> void:
	if config == null:
		config = PhConfig.new()

	var valid := config.validate()

	if not valid.ok:
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value
	rules = config.disguise_rules()

	_build_physics()
	_apply_gravity()
	_build_random()
	_build_props()
	_build_map()
	_build_combat()
	_build_loadouts()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()
	_build_taunts()
	taunted.connect(_on_taunted_for_bots)
	prop_broken.connect(_on_prop_broken_debris)

	if authoritative:
		catalogue = PhCatalogue.new()
		var _loaded := catalogue.load_from(config.map_directory)
		# Solo in the client shell: the map packs it mounted for this game, which a server
		# would have named. See [method solo_map_dirs].
		for root in solo_map_dirs("maps"):
			var _added := catalogue.add_directory(root)
		# The Workshop's maps, solo only by the index's own session (an online session lists none).
		catalogue.follow_content(DotContentIndex.shared(), PhCatalogue.accepted_map_kinds())
		# Laid out now, not on the first round: a warmup on an empty world is
		# indistinguishable from a map that failed to load.
		_lay_out_map()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server
## has mounted for it: the client shell's Solo play, which fetches the packs a server owner
## would name (dot-server-deploy's `client/solo.json`) because a tab has no server to name
## them. Read the way the module reads its server's ([DotGameContent]). Empty everywhere else:
## a server, a suite, a run from the repository. Looked up by name and duck-typed, because a
## delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## Three layers: the building, the people, and the furniture.
##
## [b]People do not collide with people.[/b] Two players shoving is a race decided by who
## walked into whom, drawn in the past on every client; a hunter walks through a prop who is
## another player, which is a tell the genre has always had in one form or another, and a far
## smaller one than a hunter stuck against an invisible sofa they cannot see is a person.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"prophunt", [&"world", &"player", &"prop", &"toy", &"footprint"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				layer.collides_with = [&"world", &"prop"]
			# A map's loose toy (dot-props'): the world, the furniture and the other toys, never a
			# person, who walks through it and pushes it (`_advance_toys`).
			&"toy":
				layer.collides_with = [&"world", &"prop", &"toy"]
			# A toy's footprint, for a walkable mesh's bake only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the movement is tuned against, on this world's own physics SPACE: a project
## setting does not travel with a delivered pack.
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_props() -> void:
	props_catalogue = PhProps.new()
	var count := props_catalogue.load_file()

	if count == 0:
		DotLog.error(CHANNEL, "no props: nobody can hide as anything", {})


func _build_map() -> void:
	map = PhMap.new()
	map.name = "Map"
	map.physics = physics
	map.catalogue = props_catalogue
	map.draw_world = draw_world
	map.authoritative = authoritative
	map.toy_rules = toy_rules
	map.gravity = config.gravity
	add_child(map)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var damage_rules := DotDamageRules.new()
	damage_rules.friendly_fire = false
	damage_rules.self_damage = true
	damage_rules.hit_groups = true
	combat.rules = damage_rules

	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# A shot stops on a wall AND on a piece of furniture: the furniture is what a hunter is
	# shooting at, and a shot through a sofa would be a shot that cannot cost anybody anything.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop")

	combat.trace = trace
	combat.resolver = DotDamageResolver.with_rules(damage_rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))
	# The one place every hurt passes (a hunter's shot, a blast, a decoy's charge on the hunter,
	# the fall): a round counts the living from health, so refusing here keeps a covered seat
	# alive in the count as well.
	combat.resolver.adjust = func(damage: DotDamage) -> void:
		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")

	add_child(combat)

	projectiles = PhProjectiles.new()
	projectiles.setup(combat, config.gravity)
	projectiles.catalogue = ZeeWeaponPack.catalogue()
	projectiles.blasted.connect(_on_blast)
	projectiles.detonated.connect(func(at: Vector3, spawn: DotWeaponSpawn) -> void:
		blast_drawn.emit(at, spawn.id if spawn != null else &""))


func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var fx := DotFxCatalogue.new()

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.18
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	fx.add(go)

	var hurt := DotFxDef.new()
	hurt.id = &"hurt"
	hurt.kind = DotFxDef.Kind.SCREEN
	hurt.flash_peak = 0.3
	hurt.flash_colour = Color(0.9, 0.1, 0.1, 1.0)
	hurt.flash_decay_ms = 260
	fx.add(hurt)

	# A grenade going off: a fireball, smoke, sparks and a light (game-arena's scene, copied). At
	# every quality: where something went off is information, not decoration.
	var blast := DotFxDef.new()
	blast.id = BLAST_FX
	blast.scene_path = PhPaths.rebase("res://scenes/fx/explosion.tscn")
	blast.lifetime_ms = 1400
	blast.cost = 10
	blast.priority = 85
	blast.max_distance = 140.0
	fx.add(blast)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)
	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the sides are this game's to draw (see [method _draw_sides]).
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var match_rules: DotMatchRules = PhRules.make()
	apply_intermission(match_rules)
	match_rules.warmup_sec = config.warmup_seconds
	match_rules.countdown_sec = 0.0
	match_rules.team_based = true
	match_rules.min_players = 2
	match_rules.set(&"decision_fn", _decision)
	match_rules.time_limit_sec = config.hide_seconds + config.round_seconds + 60.0
	match_node.rules = match_rules

	# Scoped to the match node, which finds nothing: this game places its own players.
	match_node.spawns_ref = DotNodeRef.of_path(^".")
	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = [
		DotTeam.make(PROPS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		DotTeam.make(HUNTERS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]
	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = PhSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	add_child(spectate)

	var ready_now := spectate.setup(authoritative, tick_rate, config.spectate_camera)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = PhProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


## The taunt list, on both ends: the server decides when a taunt plays, every client plays it.
func _build_taunts() -> void:
	taunts = DotPropTaunts.new()
	taunts.auto_after = config.auto_taunt_seconds
	taunts.auto_radius = config.auto_taunt_radius
	taunts.cooldown = config.taunt_cooldown
	taunts.points_voluntary = config.taunt_points
	taunts.points_forced = config.forced_taunt_points

	var text := FileAccess.get_file_as_string(PhPaths.rebase("res://" + config.taunt_file.trim_prefix("res://")))
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	var list: Variant = (parsed as Dictionary).get("taunts", []) if parsed is Dictionary else parsed

	if list is Array:
		var _added := taunts.add_all(list)

	if taunts.order.is_empty():
		DotLog.warn(CHANNEL, "no taunts; a prop can only be found by shooting", {"file": config.taunt_file})


func taunt_ids() -> Array[StringName]:
	return taunts.order if taunts != null else ([] as Array[StringName])


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_side] is a side, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> PhPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := HUNTERS if wanted_side == HUNTERS else PROPS

	var player := PhPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.catalogue = props_catalogue
	player.rules = rules
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {"why": applied.error.message})

		player.controller.set_collision_mask(physics.collision_mask(&"player"))

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)
	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.prop_body_health
	health.health = health.max_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		player.build_hitboxes(combat)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {"id": String(player_id), "why": seated.error.message})

	place_one(player)
	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})
	player_added.emit(player_id)
	return player


## Puts one player somewhere they can be, for the phase it is.
##
## [b]A joiner while the hunters are seeking watches the round out.[/b] A prop dropped into
## a round that is half over has had no time to hide, and a hunter dropped in arrives armed
## among props who planned around how many there were.
func place_one(player: PhPlayer) -> void:
	if map == null or map.doc.is_empty():
		return

	var side := "hunters" if team_of(player.player_id) == HUNTERS else "props"
	var spot := map.spawn(side, players.size() - 1)
	player.place_at(spot[0], spot[1])

	if authoritative and phase == Phase.SEEK:
		_bench(player)
	elif spectate != null:
		spectate.on_spawned(player.player_id)


func _bench(player: PhPlayer) -> void:
	player.watching = true

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			map.kill_height() + 8.0, _tick)


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: PhPlayer = players[player_id]

	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	bots.forget(player_id)

	if taunts != null:
		taunts.forget(player_id)

	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


func side_name(side: int) -> String:
	if side == PROPS or side == HUNTERS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == PROPS or side == HUNTERS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


func players_on(side: int) -> Array[PhPlayer]:
	var out: Array[PhPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## Whether [param player_id] may be damaged or eliminated now: false while their client is
## behind its loading cover. True for anybody the gate does not know.
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


## How many of a side are up and in the round.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == PROPS and remote_props >= 0:
			return remote_props
		if side == HUNTERS and remote_hunters >= 0:
			return remote_hunters

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here: on a server nothing was listening when the world opened (the module
	# builds the bridge after), and a map built before it is a map no client is ever sent.
	var id := StringName(str(map_doc.get("id", "")))

	if not map_doc.is_empty() and catalogue != null and catalogue.playable(config.map_ids).has(id):
		var _rebuilt := build_map(map_doc)
		_place_everybody()
	else:
		_lay_out_map()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# A new map once this one has had its rounds, or as soon as the players voted for one.
	if next_map_id != &"" or (_rounds_on_map >= config.rounds_per_map and not _map_unplayed):
		_lay_out_map()

	_map_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	seek_elapsed = 0.0
	bots.reset()
	bots.prepare_ahead()

	# Every broken piece whole again. A client does the same on the ROUND event.
	_prop_damage.clear()
	if map != null:
		map.restore_all()

	# And every toy home: a ball rolled into last round's hiding place points at it.
	if map != null and map.toys != null:
		map.toys.reset()

	# Nothing thrown last round goes off in this one.
	if projectiles != null:
		projectiles.clear()

	if taunts != null:
		taunts.reset()

	_draw_sides()
	_place_everybody()
	_arm_hunters()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.HIDE)
	round_began.emit(number, map.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "map": String(map.id()), "seed": _round_seed,
		"players": players.size(), "hunters": ", ".join(_names(players_on(HUNTERS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_rounds_on_map += 1

	if not _decided:
		_winner_name = "the round ran out"

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## Who hunts this round: [DotTeamRotation], with the server's mode and the players' wishes.
func _draw_sides() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var wishes := {}

	if config.allow_side_choice:
		for id in keys:
			match (players[id] as PhPlayer).side_wish:
				HUNTERS:
					wishes[id] = 1
				PROPS:
					wishes[id] = -1

	# A map may ask for its own share of hunters: a big school with a hiding place every few
	# metres wants more of them than a cottage (`ph-bots-map-spread-1`).
	var want := config.hunters_for(keys.size(), float(map_doc.get("players_per_hunter", 0.0)))
	var picked: Dictionary = DotTeamRotation.pick(
		keys, want, config.hunter_pick as DotTeamRotation.Mode, hunter_history, _round_seed, wishes
	)
	DotTeamRotation.note(hunter_history, keys, picked["picked"], round_number)

	for id in keys:
		_set_side(id, HUNTERS if (picked["picked"] as Array).has(id) else PROPS)

	if not keys.is_empty():
		DotLog.debug(CHANNEL, "hunters drawn", {"why": str(picked["why"])})


## A player's wish, from chat. Server side. Takes effect at the next draw.
func wish_side(id: StringName, side: int) -> void:
	var player: PhPlayer = players.get(id)
	if player != null:
		player.side_wish = side if side == PROPS or side == HUNTERS else 0


func _set_side(id: StringName, side: int) -> void:
	var player: PhPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


static func _names(of: Array[PhPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for player in of:
		out.append(player.display_name)
	return out


## The next map, built.
## Every map this server plays, as the map menu (M) lists them: `{id, name, detail, current}`,
## the blurb under the name. Solo the client's list, online the server's (the module hands it
## to dot-vote's map menu), so both say the same.
func map_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(map_doc.get("id", "")))
	for id in catalogue.playable(config.map_ids):
		var doc: Dictionary = catalogue.maps.get(id, {})
		var detail := str(doc.get("blurb", ""))
		if not catalogue.in_rotation(id):
			detail = ("%s (not in rotation)" % detail).strip_edges()
		var row := {"id": String(id), "name": catalogue.label_of(id), "current": id == now,
			"detail": detail}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


## The map menu's change: [param id] now, not after this map's rounds. The next map is set and
## a fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running it is simply built. Authority only.
func change_map_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the map.")
	if catalogue == null or not catalogue.playable(config.map_ids).has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s' here." % id)
	next_map_id = id
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_map()
	DotLog.info(CHANNEL, "map changed from the map menu", {"map": String(id)})
	return DotResult.success(id)


## The server's maps.yml, or null when there is none (every map rotates, as it always did).
var rotation_file: DotMapRotationFile = null

# dot-map's rotation file marks and orders [DotMapDef]s in a [DotMapCatalogue]; this game keeps
# its maps as documents, so a def per map id is mirrored here and the file applied to those.
var _rot_catalogue: DotMapCatalogue = null
var _rot: DotMapRotation = null


## Reads maps.yml (the game's shipped `res://maps.yml` under the server's
## [member PhConfig.map_rotation_file], looked for in the `--config` directory too) and applies
## it. A file that is present and unreadable is an ERROR and changes nothing: rotating every map
## is a better failure than rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != PhConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "mg-prop-hunt")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every catalogue map in or out of rotation from the file. With no file, or one with no
## rotations, every map is in: what this game did before maps.yml.
func apply_rotation() -> void:
	if catalogue == null:
		return

	catalogue.in_rotation_fn = Callable()
	catalogue.rotation_order = []

	if rotation_file == null or not rotation_file.has_rotations():
		_rot = null
		_rot_catalogue = null
		return

	_rot_catalogue = DotMapCatalogue.new()

	for id in catalogue.playable(PackedStringArray()):
		var def := DotMapDef.new()
		def.id = id
		def.display_name = str(catalogue.maps[id].get("name", id))
		def.scene_path = "doc:%s" % id
		def.content_id = StringName(catalogue.content_ref(id))
		var _added := _rot_catalogue.add(def)

	_rot = DotMapRotation.of(_rot_catalogue)
	# An empty rotation plays every installed map: the same set as having no file.
	rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
	var _applied := rotation_file.apply(_rot)
	var marks := {}

	for def in _rot_catalogue.maps:
		marks[def.id] = def.in_rotation

	# Ids the mirror has not seen (a pack map subscribed since) are out of a file's rotation
	# unless it matches them, which needs a re-apply; the next apply_rotation does that.
	catalogue.in_rotation_fn = func(id: StringName) -> bool: return bool(marks.get(id, true))
	catalogue.rotation_order = _rot.order.duplicate()


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func in_rotation(id: StringName) -> bool:
	return catalogue != null and catalogue.maps.has(id) and catalogue.in_rotation(id)


## Whether the next map is drawn at random: the rotation's mode when a file is in force,
## [member PhConfig.shuffle_maps] otherwise.
func shuffles_maps() -> bool:
	if _rot != null:
		return _rot.mode == DotMapRotation.Mode.RANDOM

	return config.shuffle_maps


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## The name a game-specific command answers to: maps.yml's `commands: names:` role (and prefix)
## over [param default]. The first name is the one registered; see [method command_aliases].
func command_name(role: String, default: String) -> String:
	return command_aliases(role, default)[0]


## Every name [param role] answers to, primary first.
func command_aliases(role: String, default: String) -> PackedStringArray:
	var target := DotCommandNamesHolder.new()
	DotCommandNames.apply(target, rotation_commands())
	return DotCommandNames.all_of(target.prefix, target.names, {role: default}, role)


class DotCommandNamesHolder extends RefCounted:
	var prefix: String = ""
	var names: Dictionary = {}


func _lay_out_map() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	if next_map_id != &"" and catalogue.playable(config.map_ids).has(next_map_id):
		doc = catalogue.maps[next_map_id]

	next_map_id = &""

	if doc.is_empty():
		doc = catalogue.next_map(
			config.map_ids, shuffles_maps(), random.stream(&"map"),
			StringName(str(map_doc.get("id", "")))
		)

	var _built := build_map(doc)
	_rounds_on_map = 0
	_map_unplayed = true
	_place_everybody()


## Builds [param doc] as the map. What the server does between rounds, and what a client does
## when it is sent one.
func build_map(doc: Dictionary) -> DotResult:
	world_clearing.emit()

	# Everybody back into their own body before the furniture they were wearing goes.
	for id: StringName in players:
		(players[id] as PhPlayer).reset_round()

	var built := map.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a map would not build", {"id": str(doc.get("id", "?")), "why": built.error.message})
		return built

	map_doc = map.doc

	if spectate != null:
		spectate.set_overviews(map.overview(), map.overview())

	world_rebuilt.emit()
	bots.prepare_ahead()
	return built


## Everybody to where their side starts, in their own body, at full health, holding nothing.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var seats := {PROPS: 0, HUNTERS: 0}

	for id: StringName in ids:
		var player: PhPlayer = players[id]
		var side := team_of(id)
		player.reset_round()
		_disarm(player)
		player.controller.remove_modifier(PhController.BLINDFOLD)

		if player.health != null:
			player.health.max_health = config.hunter_health if side == HUNTERS else config.prop_body_health
			player.health.health = player.health.max_health
			player.health.alive = true
			player.health.invulnerable = false

		var spot := map.spawn("hunters" if side == HUNTERS else "props", int(seats.get(side, 0)))
		seats[side] = int(seats.get(side, 0)) + 1
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(player.player_id)

		disguise_changed.emit(player.player_id)


func _arm_hunters() -> void:
	var clash := hunter_slot_clash(config.hunter_weapons)
	if clash != "" and clash != _warned_clash:
		_warned_clash = clash
		DotLog.warn(CHANNEL, "two hunter weapons share a slot, so only the last is carried", {"weapons": clash})

	for player in players_on(HUNTERS):
		# Not awaited: the round goes on into the hide, when a hunter is blindfolded and fires
		# nothing, so a store that answers a frame late arms them before anything could tell.
		# The memory store answers at once.
		arm_hunter(player)


## Hands [param player] the config's melee and their loadout's primary and secondary (the
## config's own when there is no loadout manager or nothing is saved), and draws the primary.
func arm_hunter(player: PhPlayer) -> void:
	var kit := config.hunter_weapons
	if loadouts != null:
		var res: DotResult = await loadouts.active_for(storage_key(player.player_id))
		if res.ok:
			kit = PhLoadout.hunter_kit(config.hunter_weapons, loadouts.resolve(res.value))
	if not is_instance_valid(player) or team_of(player.player_id) != HUNTERS:
		return

	for weapon_id in kit:
		var _armed := arm(player, StringName(weapon_id))

	# The first of the kit in hand: the loadout's primary, or the config's first without one.
	var first := StringName(kit[0]) if not kit.is_empty() else &""

	if first != &"" and player.weapons != null:
		var def := player.weapons.arsenal.catalogue.get_def(first)
		if def != null:
			var _selected := player.weapons.arsenal.select(def.slot, _tick)
			player.wanted_slot = def.slot


# --- The loadout (B) ----------------------------------------------------------

const LOADOUT_COMMAND_SCRIPT := "res://addons/dot_loadout/integrations/dot_loadout_command.gd"


## The hunters' loadouts: dot-loadout's manager on a memory store (a server forgets them on a
## restart; the client remembers its own choice and sends it again on join), and the B menu's
## server half where the host's dot-loadout has it (API 2).
func _build_loadouts() -> void:
	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.schema = PhLoadout.schema(config.hunter_weapons, config.hunter_choices)
	loadouts.register_service = false
	var lc := DotLoadoutConfig.new()
	lc.backend = "memory"
	lc.allow_default_loadout = true
	lc.conform_on_load = true
	loadouts.config = lc
	loadouts.config_file = ""
	loadouts.load_layered_config = false
	loadouts.store = DotLoadoutStoreMemory.new()
	add_child(loadouts)

	if DotAddonApi.build_level("dot_loadout") < 2 or not ResourceLoader.exists(LOADOUT_COMMAND_SCRIPT):
		return
	loadout_command = (load(LOADOUT_COMMAND_SCRIPT) as GDScript).new()
	loadout_command.set(&"manager", loadouts)
	# The player a command came from: the session's userid, which names this game's player.
	loadout_command.set(&"key_fn", func(ctx: Object) -> String:
		var session: Variant = ctx.get(&"session") if ctx != null else null
		return storage_key(StringName("u%d" % int((session as Object).get(&"userid")))) if session is Object else "")
	loadout_command.set(&"applied_fn", func(_ctx: Object, key: String) -> bool:
		return await rearm_if_allowed(player_id_of_key(key)))


## The loadout key of [param player_id]: `ph-hunter-<id>`, with anything a key may not hold made
## an underscore (dot-loadout keys are letters, digits and `-_.:`, at least eight long).
static func storage_key(player_id: StringName) -> String:
	var out := "ph-hunter-"
	for c in String(player_id):
		out += c if (c.is_valid_identifier() or c.is_valid_int() or c == "-") else "_"
	return out


## The player id a loadout key names, or &"".
static func player_id_of_key(key: String) -> StringName:
	return StringName(key.trim_prefix("ph-hunter-")) if key.begins_with("ph-hunter-") else &""


## Whether a new loadout goes into [param id]'s hands now rather than next round: a hunter during
## the hide, blindfolded, before anything has been fired. Later it would be a free reload in the
## middle of the seek. A prop's choice waits for the round they hunt.
func loadout_now_allowed(id: StringName) -> bool:
	var player: PhPlayer = players.get(id)
	return player != null and player.is_alive() and team_of(id) == HUNTERS and phase == Phase.HIDE


## Arms [param id] with their saved loadout when [method loadout_now_allowed]. True when it did.
func rearm_if_allowed(id: StringName) -> bool:
	if not authoritative or not loadout_now_allowed(id):
		return false
	await arm_hunter(players[id])
	DotLog.debug(CHANNEL, "loadout handed over at once", {"player": String(id)})
	return true


## The hunter weapons in [param ids] that share a slot with an earlier one, as "a/b" pairs, or
## an empty string. A second weapon in a slot replaces the first, silently, in dot-weapon.
static func hunter_slot_clash(ids: PackedStringArray) -> String:
	var by_slot := {}
	var pairs := PackedStringArray()
	for id in ids:
		for def in ZeeWeaponPack.weapons():
			if def.id == StringName(id):
				if by_slot.has(def.slot):
					pairs.append("%s/%s" % [by_slot[def.slot], id])
				by_slot[def.slot] = id
	return ", ".join(pairs)


var _warned_clash := ""


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	# The blindfold is a modifier, so a predicting client holds its own hunter still on exactly
	# the ticks the server does. See [PhController].
	for player in players_on(HUNTERS):
		if to == Phase.HIDE:
			var _held := player.controller.add_modifier(PhController.BLINDFOLD)
		else:
			var _let_go := player.controller.remove_modifier(PhController.BLINDFOLD)

	if to == Phase.SEEK and taunts != null:
		# The standing-still clock starts with the seeking: a prop standing still while it
		# hides is doing what hiding is.
		taunts.reset()

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.HIDE:
			if phase_elapsed >= hide_limit():
				seek_elapsed = 0.0
				_set_phase(Phase.SEEK)
			else:
				_check_round(false)
		Phase.SEEK:
			seek_elapsed += delta
			_check_round(true)


## Rounds still to play on this map, this one included. 1 is the last.
func rounds_left_on_map() -> int:
	return maxi(config.rounds_per_map - _rounds_on_map, 1)


## How long the props get to hide: the map's, under the server's.
func hide_limit() -> float:
	var asked := float(map_doc.get("hide_seconds", 0.0))
	return minf(asked, config.hide_seconds) if asked > 0.0 else config.hide_seconds


## How long the hunters get to seek: the map's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(map_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


## Last side standing, or the clock. [param seeking] is whether the clock counts yet.
func _check_round(seeking: bool) -> void:
	var props_left := alive_on(PROPS)
	var hunters_left := alive_on(HUNTERS)

	if props_left == 0 and hunters_left == 0:
		_decide(0, "nobody is left")
	elif props_left == 0:
		_decide(HUNTERS, "the hunters found every prop")
	elif hunters_left == 0:
		_decide(PROPS, "the hunters are gone" if players_on(HUNTERS).size() > 0 else "nobody was hunting")
	elif seeking and seek_elapsed >= round_limit():
		match config.timeout_winner:
			PROPS:
				_decide(PROPS, "time: the props stayed hidden")
			HUNTERS:
				_decide(HUNTERS, "time: the hunters hold the house")
			_:
				_decide(0, "time")


## The intermission is the pause plus the killcam the clients play inside it, so the server never waits on one.
func apply_intermission(rules: DotMatchRules = null) -> void:
	var target: DotMatchRules = rules if rules != null else (match_node.rules if match_node != null else null)
	if target == null:
		return
	var pause := config.intermission_seconds
	target.intermission_sec = pause + (config.killcam_seconds if pause > 0.0 else 0.0)


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why

	if authoritative:
		for id: StringName in players:
			var player: PhPlayer = players[id]

			if winner != 0 and team_of(id) == winner:
				player.points += config.winner_points

			if team_of(id) == PROPS and player.is_alive() and not player.watching:
				player.points += config.survive_points

				if progress != null:
					progress.on_survived(id)

	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


# --- Hiding -------------------------------------------------------------------

## A prop asks to become what they are looking at. Server side.
##
## [b]The server looks, not the client.[/b] What is in front of somebody is a ray from where
## the server has their eyes along the way the server has them looking, through the server's
## copy of the map; a client that named a prop could name one across the map.
func request_disguise(id: StringName) -> bool:
	var player: PhPlayer = players.get(id)

	if not _may_hide(player, id):
		return false

	var hit := _look(player, rules.reach)

	if hit < 0:
		refused.emit(id, "Look at a prop to become it.")
		return false

	return disguise_as(id, map.prop_id(hit))


## Makes [param id] a [param prop_id], if the rules allow it. What a look decides, and what a
## suite and an admin do directly.
func disguise_as(id: StringName, prop_id: StringName) -> bool:
	var player: PhPlayer = players.get(id)

	if not _may_hide(player, id):
		return false

	if not props_catalogue.may_disguise(prop_id):
		refused.emit(id, "You cannot hide as a %s." % props_catalogue.title_of(prop_id).to_lower())
		return false

	var size := props_catalogue.size_of(prop_id)
	var allowed := DotPropDisguise.may_take(size, rules)

	if not allowed.ok:
		refused.emit(id, allowed.error.message)
		return false

	if player.is_disguised() and player.disguise.prop_id == prop_id:
		return false

	var next := DotPropDisguise.of(prop_id, size)
	next.yaw = player.controller.state.yaw

	if not _make_room(player, next):
		refused.emit(id, "There is no room to be a %s here." % props_catalogue.title_of(prop_id).to_lower())
		return false

	_wear(player, next)
	return true


## Makes sure [param player] has room for [param next]'s hull, moving them a little if they
## need it. False when there is nowhere near enough.
##
## [b]A hull changes size in place.[/b] A bottle beside a wall that becomes a bookcase, or a
## small prop under a table that shows its face, has a capsule half inside the wall or the
## table, and the motor resolves that by shoving them out a different way on each machine, or
## not at all. So the server looks first: where they stand, then a step to each side, never
## through a wall to get there, never off the floor. A move is a teleport, which the owner's
## client takes from the next snapshot like any other correction.
func _make_room(player: PhPlayer, next: DotPropDisguise) -> bool:
	var world := get_world_3d()

	if world == null or physics == null or player.controller == null:
		return true

	var hull := next.standing_hull(rules) if next.is_disguised() \
		else Vector2(PhPlayer.BODY_RADIUS, PhPlayer.BODY_HEIGHT)
	var at := player.controller.state.position
	var space := world.direct_space_state
	var mask := physics.layer_mask(&"world") | physics.layer_mask(&"prop")

	var capsule := CapsuleShape3D.new()
	# A hair under the real size, or a hull resting on the floor and touching a wall counts
	# as being inside both.
	capsule.radius = maxf(hull.x - 0.03, 0.05)
	capsule.height = maxf(hull.y - 0.06, capsule.radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = mask

	var spots: Array[Vector3] = [at]

	for ring in [0.3, 0.6]:
		for k in range(8):
			var a := TAU * float(k) / 8.0
			spots.append(at + Vector3(cos(a), 0.0, sin(a)) * ring)

	for spot in spots:
		query.transform = Transform3D(Basis.IDENTITY, spot + Vector3(0.0, hull.y * 0.5 + 0.02, 0.0))

		if not space.intersect_shape(query, 1).is_empty():
			continue

		if spot != at:
			var middle := Vector3(0.0, minf(hull.y, player.hull_height()) * 0.5, 0.0)
			var through := PhysicsRayQueryParameters3D.create(at + middle, spot + middle, mask)
			var down := PhysicsRayQueryParameters3D.create(spot + Vector3(0.0, 0.3, 0.0), spot + Vector3(0.0, -0.5, 0.0), mask)

			if not space.intersect_ray(through).is_empty() or space.intersect_ray(down).is_empty():
				continue

			player.place_at(spot, player.controller.state.yaw)

		return true

	return false


func _may_hide(player: PhPlayer, id: StringName) -> bool:
	if player == null or not player.is_alive() or player.watching:
		return false

	if team_of(id) != PROPS:
		refused.emit(id, "Only the props hide.")
		return false

	if phase == Phase.IDLE:
		refused.emit(id, "Wait for the round to start.")
		return false

	return true


## Puts [param next] on [param player] — a new prop, or their own body — and carries the
## health across as a fraction, so a hurt prop cannot heal by finding a bigger one.
func _wear(player: PhPlayer, next: DotPropDisguise) -> void:
	var old_max := player.health.max_health if player.health != null else 1.0
	var new_max := DotPropDisguise.health(next.size, rules) if next.is_disguised() else config.prop_body_health

	player.apply_disguise(next)

	if player.health != null:
		var current := player.health.health
		player.health.max_health = new_max
		player.health.health = DotPropDisguise.health_after(current, old_max, new_max, rules)

	# Wearing anything again ends a reveal.
	if next.is_disguised() and player.set_aside != null:
		player.set_aside = null
		player.reveal_ready_at = _now() + rules.reveal_cooldown

	if progress != null and next.is_disguised():
		progress.on_disguised(player.player_id)

	disguise_changed.emit(player.player_id)


## A prop shows their own face, or puts the prop they took off back on. Server side.
func reveal(id: StringName) -> bool:
	var player: PhPlayer = players.get(id)

	if not _may_hide(player, id):
		return false

	if player.is_disguised():
		var wait := player.reveal_ready_at - _now()

		if wait > 0.0:
			refused.emit(id, "You can show yourself again in %d s." % int(ceilf(wait)))
			return false

		var body := DotPropDisguise.new()

		if not _make_room(player, body):
			refused.emit(id, "There is no room to stand up here.")
			return false

		var kept := player.disguise.duplicate_value()
		_wear(player, body)
		player.set_aside = kept
		player.revealed_at = _now()
		player.reveal_paid = 0.0
		return true

	if player.set_aside != null:
		if not _make_room(player, player.set_aside):
			refused.emit(id, "There is no room to be that here.")
			return false

		_wear(player, player.set_aside)
		return true

	refused.emit(id, "Look at a prop and press the disguise key first.")
	return false


## Turns a prop: [enum Turn]. Server side.
func turn(id: StringName, how: int) -> bool:
	var player: PhPlayer = players.get(id)

	if player == null or not player.is_disguised() or not player.is_alive():
		return false

	# Turned on a copy: a lean changes the hull (a bookcase laid down is long and low, stood on
	# its end tall), and a hull that does not fit where the prop is gets room made or is refused,
	# as a new disguise does. Never into a wall, never under the floor.
	var d := player.disguise.duplicate_value()
	var changed := true

	match how:
		Turn.LOCK:
			d.set_locked(not d.locked, player.controller.state.yaw)
		Turn.TILT_FORWARD:
			changed = d.tilt(1, true, rules)
		Turn.TILT_BACK:
			changed = d.tilt(-1, true, rules)
		Turn.TILT_LEFT:
			changed = d.tilt(1, false, rules)
		Turn.TILT_RIGHT:
			changed = d.tilt(-1, false, rules)
		Turn.STRAIGHTEN:
			d.straighten()
		_:
			changed = false

	if not changed:
		return false

	if how != Turn.LOCK and not d.standing_hull(rules).is_equal_approx(player.disguise.standing_hull(rules)) \
			and not _make_room(player, d):
		refused.emit(id, "There is no room to turn it that way here.")
		return false

	player.apply_disguise(d)
	disguise_changed.emit(id)
	return true


## A prop taunts, by choice. [param taunt_id] empty picks one. Server side.
func taunt(id: StringName, taunt_id: StringName = &"") -> bool:
	var player: PhPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching or team_of(id) != PROPS:
		return false

	# Taunts start with the seek. A hunter cannot move yet, so a taunt during the hide is no
	# risk; and the hunter's client is told nothing about where the props are then, so it
	# would play the sound from wherever it last saw them, which is the wrong place.
	if phase != Phase.SEEK:
		refused.emit(id, "Taunts start when the hunters are let go.")
		return false

	var may := taunts.may_taunt(id, _now())

	if not may.ok:
		refused.emit(id, may.error.message)
		return false

	var played := taunts.taunt(id, _now(), taunt_id, false, _tick)

	if played.is_empty():
		return false

	player.points += int(played["points"])
	player.taunting_id = played["id"]

	if progress != null:
		progress.on_taunted(id, false)

	taunted.emit(id, played["id"], false)
	return true


## Every prop standing still too long, made to taunt; and the meter on the way there.
func _advance_taunts() -> void:
	if taunts == null or phase != Phase.SEEK:
		return

	var now := _now()

	for player in players_on(PROPS):
		if not player.is_alive() or player.watching:
			continue

		taunts.observe(player.player_id, player.controller.state.position, now)
		player.taunt_meter = taunts.meter(player.player_id, now) if config.show_taunt_meter else 0.0

		if taunts.due(player.player_id, now):
			var played := taunts.taunt(player.player_id, now, &"", true, _tick + int(player.entity_id % 997))

			if played.is_empty():
				continue

			player.points += int(played["points"])
			player.taunting_id = played["id"]

			if progress != null:
				progress.on_taunted(player.player_id, true)

			taunted.emit(player.player_id, played["id"], true)


## The points a prop earns while showing their own face.
func _advance_reveals(delta: float) -> void:
	for player in players_on(PROPS):
		player.reveal_wait = maxf(player.reveal_ready_at - _now(), 0.0) if player.is_disguised() else 0.0

		if player.set_aside == null or player.is_disguised() or not player.is_alive():
			continue

		var cap := rules.reveal_paid_seconds
		var before := player.reveal_paid
		player.reveal_paid = before + delta if cap <= 0.0 else minf(before + delta, cap)
		var whole := int(floor(player.reveal_paid)) - int(floor(before))

		if whole > 0:
			player.points += int(round(float(whole) * rules.reveal_points_per_second))


## The last props given away: everybody still hidden is marked once few enough are left or
## little enough time is.
func _advance_beacons() -> void:
	var props_left := alive_on(PROPS)
	var on := phase == Phase.SEEK and props_left > 0 and (
		(config.beacon_props_left > 0 and props_left <= config.beacon_props_left)
		or (config.beacon_seconds_left > 0.0 and round_limit() - seek_elapsed <= config.beacon_seconds_left)
	)

	for player in players_on(PROPS):
		player.marked = on and player.is_alive() and not player.watching


## A ray from [param player]'s eyes along their aim: the prop it reaches within [param reach],
## or -1. Walls stop it.
func _look(player: PhPlayer, reach: float) -> int:
	var world := get_world_3d()

	if world == null or map == null:
		return -1

	var eye := player.eye_position()
	var query := PhysicsRayQueryParameters3D.create(eye, eye + player.aim_direction() * reach)
	query.collision_mask = (physics.layer_mask(&"world") | physics.layer_mask(&"prop")) if physics != null else 0xFFFFFFFF
	var hit := world.direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return -1

	return map.prop_from_hit(hit.get("collider"), int(hit.get("shape", -1)))


# --- Weapons ---------------------------------------------------------------

## Hands [param player] a weapon, building their rig the first time.
func arm(player: PhPlayer, weapon_id: StringName) -> bool:
	if player.weapons == null:
		var rig := ZeeWeaponRig.new()
		rig.name = "Weapons"
		rig.role = ZeeWeaponRig.Role.SERVER
		rig.authority = authoritative
		rig.tick_rate = tick_rate
		rig.player_ref = DotNodeRef.of_path(player.get_path())
		player.add_child(rig)

		var ready_now := rig.setup()

		if not ready_now.ok:
			DotLog.warn(CHANNEL, "a weapon rig would not set up", {"player": String(player.player_id), "why": ready_now.error.message})
			player.remove_child(rig)
			rig.queue_free()
			return false

		player.weapons = rig

	if not player.weapons.give(weapon_id).ok:
		return false

	player_armed.emit(player.player_id, weapon_id)
	return true


func _disarm(player: PhPlayer) -> void:
	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


## The hunters' guns, while they seek. A blindfolded hunter fires nothing.
func _advance_weapons() -> void:
	if combat == null or phase != Phase.SEEK:
		return

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if player.weapons == null or not player.is_alive() or player.watching:
			continue

		var outcome := player.weapons.simulate_tick(weapon_command_for(player), _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			_shoot_toys(shot)
			var resolved := combat.resolve_shot(shot)
			_note_hits(player, resolved)
			_charge_for_decoys(player, shot)
			_break_furniture(shot)

		# A thrown grenade: flown from here (`PhProjectiles`), its blast resolved where it goes
		# off and charged in `_on_blast`. A client's copy comes from LAUNCH, never from here.
		# Its owner is this player, as a shot's attacker is: the rig's context does not carry this
		# game's entity id, and a grenade owned by nobody hit its thrower's own head as it left
		# the hand (the flight leaves the owner's hitboxes out only by that id).
		if authoritative and projectiles != null:
			for spawn in outcome.spawns:
				spawn.owner_entity = player.entity_id
				spawn.tick = _tick
			projectiles.accept(outcome)


## What shooting the furniture costs: a share of the damage the shot would have done, off the
## hunter's own health.
##
## [b]Every pellet that stopped on a real prop, and none that hit a player.[/b] A shot's
## impacts include the pellets that struck somebody, and a prop player standing beside the
## chair they copied would otherwise cost the hunter who found them.
func _charge_for_decoys(player: PhPlayer, shot: DotShot) -> void:
	if config.decoy_penalty <= 0.0 or map == null:
		return

	var struck: Array[Vector3] = []

	for damage in shot.damages:
		if damage != null:
			struck.append(damage.point)

	var decoys := 0

	for point in shot.impacts:
		var on_somebody := false

		for hit in struck:
			if hit.distance_to(point) < 0.02:
				on_somebody = true
				break

		if not on_somebody and map.prop_containing(point) >= 0:
			decoys += 1

	if decoys == 0:
		return

	_charge(player, maxf(shot.damage * float(decoys) * config.decoy_penalty, config.decoy_penalty_min))


## Takes [param amount] off [param player] as the furniture's answer (a decoy), and tells them.
func _charge(player: PhPlayer, amount: float) -> void:
	var cost := DotDamage.make(0, player.entity_id, amount, null)
	cost.point = player.controller.state.position
	cost.direction = player.aim_direction()
	cost.tick = _tick
	cost.weapon_id = &"decoy"
	cost.context = {"why": DIED_DECOY}
	var _applied := combat.apply_damage(cost)

	if progress != null:
		progress.on_decoy(player.player_id)

	decoy_hit.emit(player.player_id, amount)


## Shooting breakable furniture breaks it. Server side.
##
## [b]Breaking is not a free guess.[/b] The decoy penalty is charged for every pellet first
## ([method _charge_for_decoys]); a bottle shot to bits cost the hunter as much as a sofa. What
## breaks is the catalogue's (`props/kits.json` "breaks": glass, food, lamps, screens, plants,
## boxes), and only once the shots that landed on it add up to its number.
func _break_furniture(shot: DotShot) -> void:
	if map == null or props_catalogue == null:
		return

	var struck: Array[Vector3] = []

	for damage in shot.damages:
		if damage != null:
			struck.append(damage.point)

	for point in shot.impacts:
		var on_somebody := false

		for hit in struck:
			if hit.distance_to(point) < 0.02:
				on_somebody = true
				break

		if on_somebody:
			continue

		var index := map.prop_containing(point)

		if index < 0:
			continue

		var limit := props_catalogue.breaks(map.prop_id(index))

		if limit <= 0.0:
			continue

		var taken := float(_prop_damage.get(index, 0.0)) + shot.damage
		_prop_damage[index] = taken

		if taken >= limit and map.break_prop(index):
			prop_broken.emit(index, shot.direction)
			DotLog.debug(CHANNEL, "furniture broke", {"prop": String(map.prop_id(index)), "index": index})


## A client: the server broke prop [param index]. [param quiet] for one told on joining, which
## broke before it came and throws no debris.
func apply_broken(index: int, direction: Vector3, quiet: bool) -> void:
	if map == null or not map.break_prop(index):
		return

	if not quiet:
		prop_broken.emit(index, direction)


## Throws a broken prop's pieces, where anything is drawn.
func _on_prop_broken_debris(index: int, direction: Vector3) -> void:
	if not draw_world or map == null or index < 0 or index >= map.props.size():
		return

	var prop: Dictionary = map.props[index]
	var size: Vector3 = prop["size"]
	var centre: Vector3 = (prop["transform"] as Transform3D) * Vector3(0.0, size.y * 0.5, 0.0)
	var debris := PhDebris.new()
	debris.name = "Debris_%d" % index
	add_child(debris)
	debris.burst(map.drawn_parts(index), centre, size, direction,
		physics.layer_mask(&"world") if physics != null else 1, _round_seed + index)


func weapon_command_for(player: PhPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0))
	command.set_button(DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1))
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2))
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func _step(delta: float) -> void:
	_advance_phase(delta)
	_drive_bots()

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if player.is_alive() and not player.watching:
			player.simulate(_tick, delta)
			player.refit()

	_advance_weapons()

	if authoritative:
		if projectiles != null:
			projectiles.tick(delta)
		_advance_toys(delta)

	_watch_world()
	_advance_reveals(delta)
	_advance_taunts()
	_advance_beacons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


## Somebody below the map is out. A height test, not a trigger volume: something falling fast
## crosses a thin trigger between two ticks without ever being inside it.
func _watch_world() -> void:
	if map == null or map.doc.is_empty() or phase == Phase.IDLE:
		return

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if phase == Phase.IDLE:
			return

		if not player.is_alive() or player.watching:
			continue

		if player.controller.state.position.y < map.kill_height():
			var fall := DotDamage.make(0, player.entity_id, player.health.max_health * 10.0, null)
			fall.tick = _tick
			fall.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(fall)


# --- Toys ----------------------------------------------------------------------

## Everybody against the map's toys, after they moved: a walk into a barrel or a ball
## sends it on; then the box's own tick (the awake cap, the lost sent home). Server side.
func _advance_toys(delta: float) -> void:
	if map == null or map.toys == null or map.toys.count() == 0:
		return
	for id: StringName in players:
		var player: PhPlayer = players[id]
		if not player.is_alive() or player.watching:
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := map.toys.push_from(state.position, state.velocity, radius, height)
	map.toys.advance(delta)


## A hunter's shot against the toys: the first one on its ray, nearer than a wall, is pushed
## (dot-props' `shot_along`). The shot goes on to the combat, whose trace never sees a toy, so
## a ball is never cover, and a hunter pays nothing for hitting one: it is no prop anybody could
## be. Server side.
func _shoot_toys(shot: DotShot) -> void:
	if not authoritative or map == null or map.toys == null or map.toys.count() == 0:
		return
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for raw: Variant in directions:
		var _pushed := map.toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, physics.layer_mask(&"world") | physics.layer_mask(&"prop"))


# --- Grenades ------------------------------------------------------------------

## How fast a blast throws a toy at its centre (nothing at its edge), whatever the toy weighs:
## game-arena's number, so a ball goes as far from a frag in both games.
const BLAST_TOY_SPEED := 12.0


## A hunter's grenade went off and dot-combat resolved it ([param shot]'s damages are who it
## hurt). Server side and solo: the hit marker for a prop it found, the toys it throws, and what
## it costs when it found nobody (docs/design.md, "Grenades").
func _on_blast(at: Vector3, spawn: DotWeaponSpawn, shot: DotShot) -> void:
	if not authoritative or spawn == null:
		return

	var thrower: PhPlayer = players.get(entities.key_for_id(spawn.owner_entity)) if spawn.owner_entity != 0 else null

	if map != null and map.toys != null:
		var _thrown := map.toys.blast(at, maxf(spawn.splash_radius, 2.0), BLAST_TOY_SPEED)

	if thrower == null or not is_instance_valid(thrower):
		return

	_note_hits(thrower, shot)

	var cost := blast_cost(at, spawn.splash_radius, spawn.splash_damage, shot)

	if cost > 0.0 and thrower.is_alive():
		_charge(thrower, cost)


## What a blast at [param at] costs its thrower: nothing when it hurt a prop (it found
## somebody), nothing when no furniture was within [param radius] in clear sight of it (a
## grenade into an empty yard is a shot into a wall), and otherwise one decoy at the blast's
## full [param damage]: `decoy_penalty` of it, at least `decoy_penalty_min`. One, however many
## pieces it reached: a blast is one guess about one place, and a charge per piece would make a
## grenade in a classroom of thirty chairs a death sentence for testing anything.
func blast_cost(at: Vector3, radius: float, damage: float, shot: DotShot) -> float:
	if config.decoy_penalty <= 0.0 or map == null:
		return 0.0

	if shot != null:
		for hurt: DotDamage in shot.damages:
			if hurt != null and not hurt.refused and hurt.health_lost > 0.0 \
					and team_of(entities.key_for_id(hurt.victim)) == PROPS:
				return 0.0

	var lifted := at + Vector3(0.0, 0.05, 0.0)
	for index in map.props_near(at, radius):
		var nearest := map.nearest_on_prop(index, at)
		# Up to the piece's own skin: the ray stops short so it does not end inside the wall the
		# piece stands against.
		var short := nearest + (lifted - nearest).normalized() * 0.05 if lifted.distance_to(nearest) > 0.06 else lifted
		if _clear_between(lifted, short):
			return maxf(damage * config.decoy_penalty, config.decoy_penalty_min)

	return 0.0


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as PhPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


# --- Applying what the server said (client side) -----------------------------

## A disguise the server decided, on this client's copy of the player.
func apply_disguise_wire(id: StringName, wire: Dictionary) -> void:
	var player: PhPlayer = players.get(id)

	if player == null:
		return

	player.apply_disguise(DotPropDisguise.from_wire(wire))
	disguise_changed.emit(id)


# --- Bots ------------------------------------------------------------------

## What the stand-ins press this tick: [code]ph_bots.gd[/code] (hide as what belongs where you
## stand, search the rooms, test what looks wrong).
func _drive_bots() -> void:
	bots.drive()


## A taunt is a shout every stand-in hunter in earshot hears.
func _on_taunted_for_bots(id: StringName, _taunt_id: StringName, _forced: bool) -> void:
	bots.on_taunted(id)


func _bot_aim_of(player: PhPlayer) -> DotBotAim:
	return bots.aim_of(player)


## The game clock in seconds, for the bots' aim.
func _bot_now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


## Aims a stand-in hunter at [param at] (target [param id]) and says whether it fires this tick.
## See [code]PhBots.shoot[/code].
func _bot_shoot(player: PhPlayer, command: DotFpsCommand, id: int, at: Vector3, velocity: Vector3) -> bool:
	return bots.shoot(player, command, id, at, velocity)


## Whether nothing solid is between two points: the walls, and with [param furniture] the
## map's props as well.
func _clear_between(from: Vector3, to: Vector3, furniture: bool = false) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1

	if furniture and physics != null:
		query.collision_mask |= physics.layer_mask(&"prop")

	return world.direct_space_state.intersect_ray(query).is_empty()


# --- Reacting ---------------------------------------------------------------

func _on_player_died(player: PhPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			map.kill_height() + 8.0, _tick
		)

	if authoritative and by != &"" and players.has(by) and team_of(by) == HUNTERS and team_of(player.player_id) == PROPS:
		(players[by] as PhPlayer).points += config.find_points

	if progress != null:
		progress.on_died(player.player_id, by, why)

	player.marked = false

	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(String(by), String(player.player_id), why, _tick)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {"id": String(player.player_id), "by": String(by), "why": String(why)})


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick. A hunter's gun is a weapon def (a shotgun may launch); the
## furniture's cost and a fall carry no direction, and push nothing.
func decide_death(player: PhPlayer, damage: DotDamage) -> DotPlayerDeath:
	var weapon: Object = null
	var shooter: PhPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if shooter != null and shooter.weapons != null and shooter.weapons.arsenal != null and damage.weapon_id != &"":
		weapon = shooter.weapons.arsenal.catalogue.get_def(damage.weapon_id)
	var direction := damage.direction
	if direction.length_squared() < 0.0001 and shooter != null and shooter != player:
		direction = (player.controller.state.position - shooter.controller.state.position) * Vector3(1, 0, 1)
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick), weapon
	)


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.HIDE:
			return maxf(hide_limit() - phase_elapsed, 0.0)
		Phase.SEEK:
			return maxf(round_limit() - seek_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"map": str(map_doc.get("id", "-")),
		"players": players.size(),
		"props": alive_on(PROPS),
		"hunters": alive_on(HUNTERS),
		"decided": _winner_name if _decided else "-",
		"maps": catalogue.maps.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["prophunt, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	for id: StringName in players:
		var player: PhPlayer = players[id]
		lines.append("  %-8s %-18s %s%s" % [
			side_name(team_of(id)), player.display_name,
			props_catalogue.title_of(player.disguise.prop_id) if player.is_disguised() else "-",
			"" if player.is_alive() else " (out)",
		])

	if map != null:
		lines.append_array(map.describe_lines())

	return lines


## Every damage a weapon's shot did to somebody else, as [signal hit_landed] for the shooter.
## Only what took health and only on the authority: a refused hit, a dead body or the
## shooter's own splash is no confirmation anybody wants a marker for.
func _note_hits(shooter: PhPlayer, shot: DotShot) -> void:
	if not authoritative or shot == null or shooter == null:
		return
	for damage: DotDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		hit_landed.emit(shooter.player_id, damage.point, damage.lethal, damage.hit_group == DotHitGroup.HEAD)
