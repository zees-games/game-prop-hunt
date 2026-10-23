extends DotConfig

## Every number this game has, layered like every other [DotConfig] in the family:
## [code]exported defaults < JSON file < environment < command line[/code].
##
## [b]Metres and seconds.[/b] The maps are documents in the same units (see [PhMapDoc]), so a
## length a mapper writes and a length this file tunes against are the same number.
##
## [b]Every rule the brief named is here, and its default is the brief's.[/b] Which side a
## player is on and how hunters are chosen, how long the props get to hide, what showing your
## face pays, when a taunt is forced, when the last props are given away, what shooting the
## furniture costs a hunter: a server owner changes any of them in `user://cfg/prophunt.json`,
## an environment variable (`PH_HIDE_SECONDS`) or a flag (`--ph-hide-seconds`), and the
## commonly turned ones are cvars as well (see `PhModule._add_tunables`).

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds the props have to hide while the hunters are blindfolded and held still.
@export_range(0.0, 180.0, 1.0) var hide_seconds: float = 30.0

## Seconds the hunters have to find everybody once they are let go. A map may ask for less.
@export_range(30.0, 1800.0, 5.0) var round_seconds: float = 300.0

## Seconds between rounds.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds of the round's final killcam, added to the intermission (`mp_killcam_time`); 0 is off. Not added when the intermission is 0.
@export_range(0.0, 30.0, 0.5) var killcam_seconds: float = 7.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 8.0

## Who wins a round the clock ends: 1 the props, 2 the hunters, 0 nobody.
##
## [b]The props, because surviving the clock is their whole objective.[/b]
@export_enum("draw", "props", "hunters") var timeout_winner: int = 1

# --- The sides -------------------------------------------------------------

@export_group("The sides")

## One hunter for every this many players, rounded up, at least [member min_hunters] and at
## most [member max_hunters] — and never everybody.
@export_range(1.0, 32.0, 0.5) var players_per_hunter: float = 3.0
@export_range(1, 16, 1) var min_hunters: int = 1
@export_range(1, 32, 1) var max_hunters: int = 8

## How hunters are chosen each round: 0 a random draw that skips last round's hunters, 1 a queue
## so everybody gets an equal share of turns, 2 the sides swap over every round. See
## [DotTeamRotation].
@export_enum("random", "queue", "swap") var hunter_pick: int = 0

## Whether a player's own wish (`!hunter`, `!prop`, `!any`) counts: those who asked are picked
## first, and those who asked to stay a prop only to fill the round.
@export var allow_side_choice: bool = true

# --- Hiding ----------------------------------------------------------------

@export_group("Hiding")

## How far from the eye a prop may be copied, in metres.
@export_range(0.5, 10.0, 0.1) var disguise_reach: float = 3.0

## A disguise's health at one cubic metre, and how fast it rises with size. See
## [DotPropDisguiseRules]: a cabinet is about nine bottles, not a hundred and fifty.
@export_range(1.0, 1000.0, 1.0) var prop_health_scale: float = 190.0
@export_range(0.0, 1.0, 0.01) var prop_health_exponent: float = 0.45
@export_range(1.0, 1000.0, 1.0) var prop_min_health: float = 10.0
@export_range(1.0, 1000.0, 1.0) var prop_max_health: float = 200.0

## The smallest dimension and the largest volume a player may hide as.
@export_range(0.0, 2.0, 0.01) var prop_min_dimension: float = 0.1
@export_range(0.0, 100.0, 0.1) var prop_max_volume: float = 8.0

## Seconds a prop must wait after putting a disguise back on before taking it off again.
@export_range(0.0, 600.0, 0.5) var reveal_cooldown: float = 10.0

## Points a second for showing your own face, and the most seconds of it that pay per reveal.
@export_range(0.0, 100.0, 0.1) var reveal_points_per_second: float = 1.0
@export_range(0.0, 600.0, 1.0) var reveal_paid_seconds: float = 20.0

## Degrees one press of a tilt key turns a prop, and the most it may lean.
@export_range(1.0, 90.0, 1.0) var tilt_step: float = 15.0
## 180 so a prop goes every way up: on either side, on its back, on its nose (Christian's water
## bottle). The hull is the leant box's, so it never goes under the floor.
@export_range(0.0, 180.0, 1.0) var max_tilt: float = 180.0

# --- Taunts ----------------------------------------------------------------

@export_group("Taunts")

## Where the taunt list is read from, relative to this game's root. A list of
## `{"id", "title", "seconds", "sound"}`; see `taunts/taunts.json`.
@export var taunt_file: String = "taunts/taunts.json"

## Seconds a prop may stand within [member auto_taunt_radius] before a taunt is forced. 0 never.
## 60, as game-hide-n-seek: Christian's first play test found 45 forced taunts too soon. The
## owner's `ph_auto_taunt_seconds`.
@export_range(0.0, 600.0, 1.0) var auto_taunt_seconds: float = 60.0
@export_range(0.1, 20.0, 0.1) var auto_taunt_radius: float = 1.5

## Whether a prop sees the meter filling toward a forced taunt.
@export var show_taunt_meter: bool = true

## Seconds between taunts, on top of the last one's length.
@export_range(0.0, 60.0, 0.5) var taunt_cooldown: float = 2.0

## Points for a taunt a prop chose, and for one forced on them.
@export_range(0, 100, 1) var taunt_points: int = 2
@export_range(0, 100, 1) var forced_taunt_points: int = 0

## Metres a taunt carries.
@export_range(5.0, 300.0, 1.0) var taunt_range: float = 60.0

# --- Giving the last props away ---------------------------------------------

@export_group("The beacon")

## Every prop still alive is beaconed once this few are left. 0 never.
@export_range(0, 32, 1) var beacon_props_left: int = 1

## Every prop still alive is beaconed once this few seconds are left. 0 never, the default:
## with it at 30 the stand-in props won 4 rounds in 20 at medium (94 of 100 found), and with it
## off 11 in 24, because every hunter there is by then walks to every prop still in, and a
## round the props had held for four and a half minutes was lost in the last half minute (as
## game-hide-n-seek found). The last prop's beacon ([member beacon_props_left]) is what ends a
## round nobody can find anybody in.
@export_range(0.0, 600.0, 1.0) var beacon_seconds_left: float = 0.0

## Seconds between a beacon's pings.
@export_range(0.25, 10.0, 0.25) var beacon_period: float = 2.0

# --- Hunters ---------------------------------------------------------------

@export_group("Hunters")

## The weapons a hunter is handed, by id from zee-dot-weapons; the first is drawn first.
##
## [b]One per slot.[/b] A weapon takes the slot its document names and a second one in that slot
## replaces the first: the old default ("smg", "shotgun", "hatchet") put the SMG and the shotgun
## both in slot 3, so a hunter carried a shotgun and a hatchet and keys 1-3 had one empty. The
## defaults are the hatchet (1), the pistol (2) and the SMG (3), the keys' order; the shotgun is
## a primary, so it replaces the SMG, not joins it. `PhGame._arm_hunters` warns of a clash.
@export var hunter_weapons: PackedStringArray = PackedStringArray(["smg", "pistol", "hatchet"])

## What else a hunter may pick on B (dot-menu's loadout), by id: primaries, sidearms and the
## grenades (`ph_loadout.gd`: the grenade slot is optional and empty by default);
## [member hunter_weapons]' primary and sidearm are the defaults and are always offered. An owner
## narrows or locks it with dot-loadout's `mp_loadout_*` cvars.
@export var hunter_choices: PackedStringArray = PackedStringArray([
	"smg", "shotgun", "carbine", "pistol", "revolver", "machine_pistol", "frag", "sticky",
])

## What shooting the furniture costs a hunter: this fraction of the damage the shot would have
## done comes off their own health. 0 turns it off.
@export_range(0.0, 5.0, 0.05) var decoy_penalty: float = 0.2

## The least a decoy shot costs, so a shotgun's pellets are not each worth nothing.
@export_range(0.0, 50.0, 0.5) var decoy_penalty_min: float = 1.0

## What happens to a hunter who dies to the furniture: 0 nothing drawn, 1 they fall apart, 2
## they burst. See [DotPlayerBreakRules].
@export_enum("none", "limbs", "explode") var hunter_break: int = 2

## What a disguised prop does when it is found: 0 bursts into its own pieces, as shot furniture
## does; 1 topples over as the prop (dot-player-char's one-piece body, under `sv_ragdoll*`); 2
## vanishes. A person's body (a hunter, a prop out of disguise) is a ragdoll either way.
@export_enum("burst", "topple", "vanish") var prop_death: int = 0

# --- Points ----------------------------------------------------------------

@export_group("Points")

## Points to everybody on the winning side.
@export_range(0, 100, 1) var winner_points: int = 10

## Points to a hunter for each prop they find.
@export_range(0, 100, 1) var find_points: int = 5

## Points to every prop still alive when the round ends.
@export_range(0, 100, 1) var survive_points: int = 5

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var hunter_health: float = 100.0

## A prop's health before they are disguised: their own body.
@export_range(1.0, 400.0, 1.0) var prop_body_health: float = 100.0

@export_range(1.0, 20.0, 0.1) var run_speed: float = 6.5
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.45
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.15
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0
@export var auto_bunny_hop: bool = false
@export_range(0.0, 200.0, 1.0) var air_accelerate: float = 20.0

# --- The maps --------------------------------------------------------------

@export_group("The maps")

## Which maps this server may play, by id. Empty means every one it has.
@export var map_ids: PackedStringArray = PackedStringArray()

## Whether the next map is drawn at random (seeded) rather than taken in order.
@export var shuffle_maps: bool = true

## Rounds played on a map before the next one, unless the players vote first.
@export_range(1, 50, 1) var rounds_per_map: int = 4

## Where map documents are read from, relative to this game's root.
@export var map_directory: String = "maps"

## The file that says which maps a server ROTATES: `cfg/maps.yml`, layered over the game's own
## shipped `res://maps.yml` (dot-map's `DotMapRotationFile`: named rotations, `random` or
## `cycle`, wildcards, command names). Empty, or no such file, rotates every map. A map the
## active rotation leaves out stays installed (`ph_map <id>` queues it); it is only never drawn
## or balloted. `sv_map_rotation_file`.
@export var map_rotation_file: String = "cfg/maps.yml"

## Seed every random choice is drawn from: the map, the hunters, the bots.
@export var seed_value: int = 20261009

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
@export_range(0, 24, 1) var minimum_players: int = 4

# How a stand-in hunter turns, aims and how quickly it fires are dot-bot's `bot_*` settings,
# shared by every game (`bot_difficulty`, `bot_reaction`, `bot_aim_error`, ...).

## How much a stand-in hunter doubts a piece of furniture it has no other reason to doubt, in
## hundredths: the base its suspicion grows from (a piece alone of its kind, one it remembers
## was not there, one tilted, one near a taunt add to it). 0 tests nothing without a reason;
## more tests more furniture and pays more decoy penalty. See `ph_bots.gd`.
@export_range(0.0, 100.0, 1.0) var bot_suspicion: float = 12.0

## Seconds into the hide before a stand-in prop puts its disguise on (the piece it is walking to
## be beside), so it is never a person in the open for long. 0 is at once; more than the hide is
## the old way (becomes it on arriving). See `ph_bots.gd`.
@export_range(0.0, 60.0, 0.1) var bot_disguise_delay: float = 1.5

## About how many seconds a hidden stand-in prop stays before moving to another place of its
## kind (only with no hunter in sight lately). 0 never moves unless shot or forced to taunt.
@export_range(0.0, 3600.0, 1.0) var bot_relocate_seconds: float = 150.0

## Metres a stand-in prop's move to another place may reach.
@export_range(2.0, 60.0, 0.5) var bot_relocate_range: float = 12.0

## Whether stand-ins read the map's annotations (dot-npc-ai's hiding spots and chokepoints):
## props hide beside furniture of their size where it is tucked in and out of sight, hunters
## sweep the best spots and the chokepoints. Off is the first way: a place beside each piece of
## furniture, scored by sight lines alone. See `ph_bots.gd`.
@export var bot_nav: bool = true

## With `bot_nav`: how much of the annotated map a stand-in hunter knows, 0..1 (at least its own
## `bot_map_knowledge`). It sweeps the best hiding spots and the chokepoints first, as far as it
## knows, instead of the nearest place.
@export_range(0.0, 1.0, 0.05) var bot_sweep: float = 0.1

## Metres from a piece of furniture a spot may be and still be "beside" it, for a stand-in prop.
@export_range(0.3, 4.0, 0.1) var bot_beside: float = 1.3

# --- Watching --------------------------------------------------------------

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

@export var keep_progress: bool = true
@export var progress_directory: String = ""
@export var report_progress: bool = false


func env_prefix() -> String:
	return "PH_"


func cli_prefix() -> String:
	return "--ph-"


## How many hunters a round with [param players] in it has. [param per] is a map's own
## players per hunter (0: the server's); the server's least and most hunters hold either way.
func hunters_for(players: int, per: float = 0.0) -> int:
	return DotTeamRotation.count_for(players, per if per > 0.0 else players_per_hunter, min_hunters, max_hunters)


## The disguise rules, from this configuration.
func disguise_rules() -> DotPropDisguiseRules:
	var r := DotPropDisguiseRules.new()
	r.health_scale = prop_health_scale
	r.health_exponent = prop_health_exponent
	r.min_health = prop_min_health
	r.max_health = prop_max_health
	r.min_dimension = prop_min_dimension
	r.max_volume = prop_max_volume
	r.reach = disguise_reach
	r.tilt_step = tilt_step
	r.max_tilt = max_tilt
	r.reveal_cooldown = reveal_cooldown
	r.reveal_points_per_second = reveal_points_per_second
	r.reveal_paid_seconds = reveal_paid_seconds
	return r


func validate() -> DotResult:
	if round_seconds <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A round has to last some time.")

	if min_hunters > max_hunters:
		return DotResult.fail(DotError.CODE_INVALID, "min_hunters is over max_hunters.")

	if timeout_winner < 0 or timeout_winner > 2:
		return DotResult.fail(DotError.CODE_INVALID,
			"timeout_winner is %d; it is 0 (draw), 1 (props) or 2 (hunters)." % timeout_winner)

	if hunter_pick < 0 or hunter_pick > 2:
		return DotResult.fail(DotError.CODE_INVALID,
			"hunter_pick is %d; it is 0 (random), 1 (queue) or 2 (swap)." % hunter_pick)

	var rules := disguise_rules().validate()

	if not rules.ok:
		return rules

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"round": "%.0f s hide, %.0f s seek" % [hide_seconds, round_seconds],
		"hunters": "1 per %.1f, %d..%d, %s" % [players_per_hunter, min_hunters, max_hunters,
			["random", "queue", "swap"][hunter_pick]],
		"timeout": ["draw", "props", "hunters"][timeout_winner],
		"taunts": "forced after %.0f s within %.1f m" % [auto_taunt_seconds, auto_taunt_radius]
			if auto_taunt_seconds > 0.0 else "never forced",
		"beacon": "%d left or %.0f s" % [beacon_props_left, beacon_seconds_left],
		"decoys": "%.0f%% back" % (decoy_penalty * 100.0),
		"maps": "all" if map_ids.is_empty() else ",".join(map_ids),
		"bots": minimum_players,
	}


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("prophunt configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])
	return lines
