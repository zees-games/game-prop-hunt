# mg-prop-hunt

Hide as the furniture. Most players are props, who look at something on the map and become it; the rest are hunters, blindfolded while the props hide and then given a few minutes to find them, paying in health for every piece of real furniture they shoot.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. This file is only about what this game decides. The maps are in `maps/`, a link to [mg-prop-hunt-maps](../mg-prop-hunt-maps), written by its `tools/build_maps.py`; `maps/README.md` is the format.

Built from mg-deathrun's skeleton; a comment naming another game's finding is that game's, kept because it still holds ([history](docs/history.md#the-first-days-2026-10-09-to-10-11)).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | disguises and hulls, the blindfold on the wire, decoys, taunts, beacons, sides and points |
| [docs/hud.md](docs/hud.md) | the HUD pieces, the ammunition counter, help (H) and the map list (M) |
| [docs/drawing.md](docs/drawing.md) | how a map is batched, coloured and lit |
| [docs/delivery.md](docs/delivery.md) | the maps pack, the map vote, publishing, `project.godot` |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening"; what running this game found |

## Layout

```
game/
  ph_config.gd       every rule a round is played under (maps are documents)
  ph_map_doc.gd      what a map IS: boxes, props by catalogue id, lights, spawns; validated
  ph_map.gd          a document built: solid boxes, furniture shapes, drawn batches, spawns
  ph_props.gd        the prop catalogue (props/catalogue.json): sizes, models, recolour, parts
  ph_materials.gd    the surfaces a box is drawn with: Kenney's grid under pastels, the rest made in code
  ph_catalogue.gd    every map the server has, the built-in practice house, which is next
  ph_controller.gd   DotFpsController with the blindfold modifier
  ph_player.gd       one person: a body or a disguise, its hull, hitboxes, health, reveal, beacon
  ph_game.gd         the simulation: the draw, hide/seek, disguises, taunts, decoys, beacons
  ph_bots.gd         the stand-ins: hide as what belongs there, search, test what looks wrong
  ph_rules.gd        a DotMatchRules whose outcome is whatever PhGame decided
  ph_loadout.gd      a hunter's loadout as dot-loadout data (B)
  ph_projectiles.gd  grenades in flight and where they go off; ph_projectile_view.gd draws them
  ph_killcam.gd      the round's last moment: every drawn frame into dot-replay's DotKillcamBuffer, replayed from the finder's eyes (or a hidden prop's on a time-out)
  ph_hud.gd          the clock, hints, health, what you are, the taunt meter, the blindfold (dot-ui pieces)
  ph_audio.gd        the round's cues (made in code) and taunts played from a prop
  ph_client.gd       one local player, alone or against a server; third person as a prop; its platform wiring (loading cover, settings, console, Tab, M, pointer, input block) is dot-game's `DotGameClient` (`platform`)
  ph_bindings.gd     every key, as dot-menu bindings; ph_settings.gd the Escape menu
  ph_module.gd       the DotGameModule: cvars, ph_status / ph_maps / ph_taunts / ph_map, stand-ins
  ph_services.gd     chat, voice and moderation over dot-game's base
  ph_progress.gd     stats and achievements; ph_vote.gd the map vote; ph_spectate.gd who watches whom (free roam is on by default: G, `mp_freeroam`, `mp_forcecamera`; the camera is the client's `DotSpectatorFreeCam`, the server holds only the mode)
  net/               the codec (MAP, DISGUISE, TAUNT, DECOY…), the link, the player behaviour,
                     the bridge, and PhInterest (the blindfold on the wire)
props/               kits.json (which Kenney models, at what scale), catalogue.json (measured)
assets/props/        the vendored models (Kenney, CC0): furniture, nature, food, survival (a chosen few each); ten of them (chair, books, cardboardBoxClosed, lampRoundTable, sideTable, bottle, bucket, box, barrel, soda-can) are rebuilt by art-src/build_props.py with their own palette and refitted to the stock bounds (stock copies in art-src/base/, .gdignored; `blender -b -P art-src/build_props.py`). props/pieces.json is deliberately the stock one, so the collision hulls are exactly as before and measure_props -- --check reports it stale
taunts/              the taunt sounds and taunts.json (Kenney, CC0); edit freely
maps/                link to ../mg-prop-hunt-maps/maps
examples/            headless_run, headless_maps, headless_workshop, headless_bots, headless_net, dedicated (each counts its sections and checks)
tools/               shot.sh/.gd (render a view, or a round in progress), measure_props.gd, audio_probe (xvfb only), `soak.tscn` (`./game.sh soak [map] [min]`, [soak](docs/soak.md))
```

## Rules that bite

Short forms; the reasoning is in the linked file.

**Disguises and the wire**

- A disguise is a hull: `PhPlayer.apply_disguise` writes the hull into the controller's tunables **in place** (the motor holds that object by reference). [design](docs/design.md#decision-1-a-disguise-is-a-hull-not-a-look)
- Both ends compute the hull from `props/catalogue.json` (measured offline by `tools/measure_props.gd`); a DISGUISE event carries the prop, turn and lock, never a size. `headless_net` asserts both ends agree. [design](docs/design.md#decision-1-a-disguise-is-a-hull-not-a-look)
- A bigger hull needs room: `PhGame._make_room` tries in place, then 0.3/0.6 m steps, else refuses; never skip it. [design](docs/design.md#decision-1-a-disguise-is-a-hull-not-a-look)
- A lock or a tilt is the server's, asked for and announced; a tilt is made on a copy and a changed hull goes through `_make_room`. [design](docs/design.md#decision-1-a-disguise-is-a-hull-not-a-look)
- A leant prop turns about its box's middle and rests on the floor: hull `standing_hull`, model `model_transform`, hitbox `box_transform` (dot-props 4); never `Transform3D(prop_basis(), feet)`. `headless_run` turns every prop six ways. [design](docs/design.md#decision-1-a-disguise-is-a-hull-not-a-look)
- The blindfold is true on the wire: `PhInterest` sends a hunter no prop during the hide (every snapshot, no linger), and DISGUISE events reach a hunter only when the seek starts (`PhNetBridge._on_disguise_changed`, `_on_phase_changed`). [design](docs/design.md#decision-2-the-blindfold-is-true-on-the-wire)
- Map toys are loose only (dot-props): pushed by a walk, shot along the ray without stopping the shot or costing a decoy, home each round, sent to no hunter during the hide; a client registers every toy mirror on TOYS before its map is built. [design](docs/design.md#toys-loose-ones-only-never-a-hiding-place)
- **A READY before the player is seated is kept** (`_ready_unseated`) and answered by `add_player`; `headless_net` sends it first (armed). [history](docs/history.md)
- `net_max_health` is 14 bits: 12 made a chair's 98 health 97.9 on the client. [history](docs/history.md#the-first-days-2026-10-09-to-10-11)

**Hunters, decoys and stand-ins**

- A shot landing in a map prop's box and not on a player is a decoy, charged per pellet (`PhGame._charge_for_decoys`, `decoy_penalty`, `decoy_penalty_min`). [design](docs/design.md#decision-3-a-wrong-guess-costs-and-the-furniture-decides-what-is-wrong)
- A map may set its own share of hunters (`players_per_hunter`, `PhConfig.hunters_for(players, per)`; the server's least and most still hold), as it sets its round and hide; `headless_bots` holds each map to its own band, not only the mean; a one-round shift is noise (any body in the physics space re-rolls a knife-edge round), so judge a map on its own 48 (`--map`). [history](docs/history.md#the-schools-toys-were-not-the-schools-problem-2026-10-13)
- Stand-ins are `ph_bots.gd` on dot-bot (`DotBotNav`, `DotBotHiding`, `DotBotSearch`, `DotBotAim`): a prop hides beside a piece of its kind and becomes it; a hunter searches and tests by suspicion, never by knowing; the map's spots come from dot-npc-ai's annotator (`ph_nav_annotator.gd`, `ph_bot_nav`). Never set `command.yaw` straight onto a target. A change to them is not done until `headless_bots` passes its bands. [bots](docs/bots.md)
- A stand-in prop never hops while disguised (a sink in mid-air), and "hurt" is health lost under the same disguise (a new disguise's maximum is no shot). [bots](docs/bots.md#a-prop-hides-as-what-belongs-there)
- The drawn gun holds only what the server armed (`PhClient._arm_locally` gives each `player_armed` weapon; never `give_everything`); one hunter weapon per slot (`PhGame.hunter_slot_clash` warns). [history](docs/history.md#the-hunters-weapons-were-completely-broken-2026-10-12)
- B is a hunter's loadout (dot-loadout's `DotLoadoutCommand`, `ph_loadout.gd`, owner's `mp_loadout_*`); a choice is in the hands at once only in the hide (`PhGame.rearm_if_allowed`), else next round. The grenade slot (5) is optional and empty by default. [design](docs/design.md#a-hunters-loadout-and-aiming)
- Grenades fly in `ph_projectiles.gd` (the arena's), server and solo; one LAUNCH per throw and a client flies a copy that decides nothing; a blast that hurts no prop by furniture is one decoy (`PhGame.blast_cost`). [design](docs/design.md#grenades)
- Right mouse aims down the sights (`PhBindings.AIM`; quick melee F), presentation only; the lens zooms from `PhClient.base_fov`, where the menu's field of view binds, never the camera. [design](docs/design.md#a-hunters-loadout-and-aiming)
- `PhClient.correct_drawn` brings the drawn gun to the server's count once quiet 0.6 s (offline the world's rig, online the owner-only `net_magazine`/`net_reserve`). [hud](docs/hud.md)
- **A hit is the server's word** (`PhGame.hit_landed`, HIT to the shooter alone): the hit marker and zee's red burst on the body; `headless_run` the marker, `headless_net` the routing (armed). [hud](docs/hud.md#a-hit)
- Offline, the client's buttons go onto the world's own sample through `PhPlayer.command_stamp` (set in `PhClient._adopt`); never stamp `controller.current_command` for the world. [history](docs/history.md#offline-no-hunters-shot-ever-landed-2026-10-12)
- The furniture is one static body, so nothing a hunter does moves a prop out of the box the decoy check reads. [history](docs/history.md#the-hunters-weapons-were-completely-broken-2026-10-12)
- Breakable furniture (`props/kits.json` "breaks") breaks once the shots add up (`PhMap.break_prop`), still charged as a decoy; BROKEN tells every client, a round restores it; debris is the client's own (`ph_debris.gd`, world layer only). [design](docs/design.md#breakable-furniture)

- A death's fall is the server's (`PhGame.decide_death`, last and optional on DEATH); the client draws it (`PhClient._fall`): a person as a ragdoll under `sv_ragdoll*`, a disguised prop pops (`prop_death`), a hunter the furniture finished breaks (`hunter_break`). [design](docs/design.md#a-death)

**Taunts, beacons, sides**

- Taunts start with the seek, play from where the prop stands to `taunt_range`; standing still `auto_taunt_seconds` (60, as game-hide-n-seek) taunts for you. The list is `taunts/taunts.json`. [design](docs/design.md#decision-4-taunts-are-a-choice-with-a-price-and-standing-still-is-not-free)
- The last prop pings (`beacon_props_left` 1); the time beacon (`beacon_seconds_left`) is off by default because it decided rounds the props had held (`DotFxBeacon`). [design](docs/design.md#decision-5-the-end-of-a-round-finds-the-last-props)
- Sides are `DotTeamRotation` (RANDOM, QUEUE, SWAP); `!hunter`/`!prop`/`!any` are wishes. Stats are `PhProgress` over dot-stats and dot-achievements. [design](docs/design.md#sides-points-and-stats)
- `PhGame` has no `var rotation` (it shadowed `Node3D.rotation`); the draw's memory is `hunter_history`. [history](docs/history.md#the-first-days-2026-10-09-to-10-11)

**HUD and menus**

- The HUD is dot-ui's pieces in the menu's theme and HUD size (`PhHud.follow_menu`); `PhHud.piece_theme()` is the accent only, Labels set no colour of their own but accent lines, the health plate ends above a full chat log; needs dot-ui 4. [hud](docs/hud.md)
- **Sound follows the map document** (box `mat` → footsteps by surface, `ceiling`/`roof` boxes → indoor zones, `PhAudio.MAP_SOUND` beds); levels by dot-audio's `loudness.sh`, −17 LUFS. [hud](docs/hud.md#sound)
- **H is help and M is the map list** (dot-menu's stock keys): nothing in `PhBindings` may default to either; `headless_run` and `dedicated` check it. A map choice never reaches `_on_taunt_picked`. [hud](docs/hud.md)

- **A round ends on its last moment** (`PhKillcam`): the last hider found (the hunter's eyes) or the clock running out (a prop still hidden) is replayed, then dot-ui's `DotWinnerReveal` names the winning side and its best three, then the Tab board. `mp_killcam_time` (REPLICATED, 7, 0 off) is added to the intermission on the server (`PhGame.apply_intermission`, not when the intermission is 0); `reduce_motion` (General, Comfort) shows the reveal's last frame at once. No `requires.floor.json`: nothing here guards an older addon, so a floor would fail `floor_audit`. `tools/shot.sh --view=killcam --seconds=2|9.5` renders both. Needs dot-replay (2) and dot-ui (9).

**Maps and drawing**

- Boxes are batched by material, tint and 12 m chunk (Compatibility lights a mesh with at most eight omni lights); props are one `MultiMeshInstance3D` per model part; opaque boxes also get dot-lighting's `DotContactShade` (by path, API 4), and unbreakable block furniture too (`PhMap._shades_floor`). [drawing](docs/drawing.md#contact-shade)
- Rooms are pastel over Kenney's grid (`PhMaterials.PASTELS`), furniture keeps Kenney's colours except where `props/kits.json` recolours a kit; check both renderers. [drawing](docs/drawing.md)
- A spawn is written before a room is furnished: `headless_maps` catches one inside furniture, and mg-prop-hunt-maps' builder moves them. [history](docs/history.md#the-first-days-2026-10-09-to-10-11)
- Nothing stands in a doorway or out in a hallway: mg-prop-hunt-maps' builder refuses it; `headless_bots` holds every hiding place reachable from the props' start. [history](docs/history.md#the-bots-did-not-know-how-to-play-and-the-school-was-in-the-way-2026-10-12)
- Rendering finds what no check does (grass pools, dark bands, washed-out light): look with `tools/shot.sh`. [history](docs/history.md#the-first-days-2026-10-09-to-10-11)

**Delivery**

- **Workshop maps** (`provides.json` `accepts`: kinds `["map"]`, `map_kinds` `["prophunt"]`; no props, because a disguise is a measured hull, see [not-yet](docs/not-yet.md)): a pack `map` entry's `scene` is a prop-hunt map DOCUMENT whose `id` equals the entry's. `PhCatalogue.follow_content` reads `DotContentIndex.shared()` on every `playable()`, so solo (M, vote, change-map) lists it as "Name [Pack]" and an online session sees none; the game's own ids win and a bad document is refused cleanly. `PhVote` follows the index through dot-vote's `follow_content`, so `maps_fn` returns only the game's own maps. `headless_workshop` holds it; `tools/shot.sh --view=maps` renders it. [delivery](docs/delivery.md#the-workshop-solo-only)
- No `class_name` anywhere in `game/`: a mounted pack cannot register one. [delivery](docs/delivery.md)
- `game.yml` does not name the maps pack; the owner names it in dot-server-deploy's `cfg/content.yml`, and `PhModule._add_delivered_maps` mounts it at load and after `ph_reload`. [delivery](docs/delivery.md)
- Under MANUAL `PhVote` opens a passed rock-the-vote itself, and `_game_load` refreshes the map list after `_add_delivered_maps`; `dedicated` arms both. [delivery](docs/delivery.md)
- dot-props (4), dot-bot (2), dot-npc-ai (2, with dot-npc), dot-team (2), dot-fx (2), dot-game (8), dot-ui (4), dot-loadout (2, B) and dot-menu (6, B) must be tagged and in the client shell before publishing. [delivery](docs/delivery.md)
- `project.godot` carries no comments; `PhConfig.gravity` goes onto the world's own space (a project setting does not travel in a pack); the renderer is `gl_compatibility`. [delivery](docs/delivery.md#project-settings)
- A shell that lacks an addon, or a stale class cache, fails the delivered client's parse: dot-server-deploy's `prophunt_client` finds it. [history](docs/history.md#the-first-days-2026-10-09-to-10-11)

## Validating

```bash
./game.sh test                                         # parse, then all five suites
timeout 1800 godot --headless --path . res://examples/headless_bots.tscn -- --difficulty hard   # the bots' numbers at another preset (96 rounds, ~13 min; `--rounds 24` for ~4)
python3 ../mg-prop-hunt-maps/tools/build_maps.py --check
xvfb-run -a godot --path . res://tools/audio_probe.tscn
tools/shot.sh --view=overview --ph-map-ids=ph_school
tools/camera_check.sh --render     # cameras round the house (armed), mp_forceview, both views
tools/shot.sh --view=room --ph-map-ids=ph_school --at=-38,1.7,3.5 --look=-26,0.8,14
tools/shot.sh --view=dead --ph-map-ids=ph_woods --seconds=3   # a hunter's ragdoll; --victim=prop --as=<id> a found prop pops
tools/shot.sh --view=hunter --aim --name=hunter_aimed     # down the sights
tools/shot.sh --view=loadout                             # B open in the hide (every view: tools/shot.sh's header)
tools/shot.sh --view=grenade --seconds=0.4               # a frag in flight; --seconds=2 its burst
tools/shot.sh --view=round --seconds=4 --ph-minimum-players=7 --ph-map-ids=ph_school --ph-hide-seconds=14
godot --headless --path . --script tools/measure_props.gd -- --check   # catalogue matches the models
```

Without `maps/` linked in (CI clones this repository alone) `headless_maps` checks the practice house only, and says so.

## Still to do

1. **Put it live.** Tag the addons above, rebuild the shell, publish the maps pack before the game.
2. **Try it in a browser**, with people: how long a hide should be and how much a decoy should cost are numbers only play settles.
