# mg-prop-hunt

Hide as the furniture. Most players are props, who look at something on the map and become it; the rest are hunters, blindfolded while the props hide and then given a few minutes to find them, paying in health for every piece of real furniture they shoot.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. This file is only about what this game decides. The maps are in `maps/`, a link to [mg-prop-hunt-maps](../mg-prop-hunt-maps), written by its `tools/build_maps.py`; `maps/README.md` is the format.

**Built 2026-10-09 from mg-deathrun's skeleton** (module, services, wire, client, HUD, spectate, progress, avatars, figure, vote, renamed `dr` → `ph` and then rewritten wherever they named a course, a trap or an activator). Where a comment says "mg-wipeout found…" or "mg-smash-copter found…", the finding is that game's and the line was kept because it is still true here.

## What this game is, versus the others

The third asymmetric one, after buses and deathrun, and the first where **one side's whole move is to stop moving**. A prop's skill is choosing what to be and where; a hunter's is reading a room for the thing that is slightly wrong, and the decoy charge is what makes that a skill rather than spraying every chair.

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
  ph_game.gd         the simulation: the draw, hide/seek, disguises, taunts, decoys, beacons, bots
  ph_rules.gd        a DotMatchRules whose outcome is whatever PhGame decided
  ph_hud.gd          the clock, hints, health, what you are, the taunt meter, the blindfold (dot-ui pieces)
  ph_audio.gd        the round's cues (made in code) and taunts played from a prop
  ph_client.gd       one local player, alone or against a server; third person as a prop
  ph_bindings.gd     every key, as dot-menu bindings; ph_settings.gd the Escape menu
  ph_module.gd       the DotGameModule: cvars, ph_status / ph_maps / ph_taunts / ph_map, stand-ins
  ph_services.gd     chat, voice and moderation over dot-game's base
  ph_progress.gd     stats and achievements; ph_vote.gd the map vote; ph_spectate.gd who watches whom
  net/               the codec (MAP, DISGUISE, TAUNT, DECOY…), the link, the player behaviour,
                     the bridge, and PhInterest (the blindfold on the wire)
props/               kits.json (which Kenney models, at what scale), catalogue.json (measured)
assets/props/        the vendored furniture and nature models (Kenney, CC0)
taunts/              the taunt sounds and taunts.json (Kenney, CC0); edit freely
maps/                link to ../mg-prop-hunt-maps/maps
examples/            headless_run (84), headless_maps (41), headless_net (49), dedicated (50)
tools/               shot.sh/.gd (render a view), measure_props.gd, audio_probe (xvfb only)
```

## Decision 1: a disguise is a hull, not a look

Becoming a chair changes what the controller sweeps, what the hitbox is and how much health there is, all as functions of the chair's measured size (`DotPropDisguise` in dot-props, under `DotPropDisguiseRules`): a footprint half as wide as the prop so a disguised player still fits through a door, a height clamped between 0.3 and 2.2 m, health `190 × volume^0.45` between 10 and 200, and a hurt prop that changes shape keeps its share of health. `PhPlayer.apply_disguise` writes the hull **into the controller's tunables in place**, because the motor holds that object by reference and a new one would never reach it.

**Both ends must agree, so both ends compute it from the same number.** A client predicting itself as a chair with a different capsule from the server's walks through a doorway the server's chair does not fit and is pulled back every tick. The size comes from `props/catalogue.json`, measured once offline by `tools/measure_props.gd`, because a headless server has the meshes but no business loading 163 of them to read their bounds. A DISGUISE event carries the prop, its turn and its lock; the receiving end rebuilds the hull from the catalogue. `headless_net` asserts the capsule and health equal on both ends and a running chair within 2 mm of the server's.

**A hull changes size where the player stands, so the server looks for room first** (`PhGame._make_room`): the new capsule where they are, then a step of 0.3 or 0.6 m in eight directions, never through a wall and never off a floor, and otherwise a refusal ("There is no room…"). Without it a bottle by a wall that became a bookcase, or a small prop under a table that showed its face, was a capsule inside the wall or the table, which the motor resolves differently on each machine. Found in review (2026-10-09); `headless_run`'s "a bigger hull needs room" (armed by turning the check off: three fail).

**Turning** is yaw (free, or locked with C so looking around does not turn you), tilt and lean in 15° steps up to 90°, and upright again. A lock or a tilt is the server's, asked for and announced.

## Decision 2: the blindfold is true on the wire

The HUD paints a hunter's screen black during the hide, and a modifier (`PhController.BLINDFOLD`) holds them still on exactly the ticks the server does. Neither stops a client that skips the paint. So `net/ph_interest.gd` sends a hunter's snapshots **no prop at all** during the hide, evaluated every snapshot with no linger: a prop that kept being sent for a second after the hide began would be a second of where everybody ran. `headless_net` moves a prop on the server during the hide and asserts the hunter's copy did not move, then that it is right the tick seeking starts. **What the props became is held back the same way**: a DISGUISE event goes to every peer except a hunter during the hide, and each hunter is sent all of them when the seek starts (`PhNetBridge._on_disguise_changed`, `_on_phase_changed`). Without that a blindfolded client knew "two chairs and a plant", which is half of finding them; found in review, armed (`headless_net`'s "nor what it became").

## Decision 3: a wrong guess costs, and the furniture decides what is wrong

A shot whose impacts land inside a map prop's box, and not on a player, is a decoy: the hunter takes `decoy_penalty` (20%) of the shot's damage, at least `decoy_penalty_min` (1), per pellet that hit furniture (`PhGame._charge_for_decoys`). Death by decoy blows the hunter apart (`hunter_break`, dot-player-char's `DotPlayerBodyBreak`). The client flashes on a DECOY event. **The first stand-in hunter killed itself this way in its first round**: it fired at a prop it could see through a sofa, every pellet hit the sofa, and `dedicated` reported "the hunters are gone" two seconds into the seek. A stand-in now needs a line of sight clear of furniture too, and stops guessing below 40% health. **How a stand-in turns, aims and when it fires is dot-bot's `DotBotAim`** (`PhGame._bot_shoot`, `_bot_look`, one per stand-in on `DotBotSettings.of(game)`): never set `command.yaw` straight onto a target; a hunter sees a prop only inside `bot_fov` and `bot_sight` (capped at 25 m), and a suspicion is followed through for a second (turn, then fire) rather than shot on the tick it comes.

## Decision 4: taunts are a choice with a price, and standing still is not free

`DotPropTaunts` (dot-props): **taunts start with the seek** (a taunt during the hide was no risk to the prop, and a hunter's client, told nothing about where the props are, played it from where it last saw them). A taunt plays from where the prop stands, to everybody within `taunt_range`, and pays `taunt_points`. A prop that has not moved `auto_taunt_radius` in `auto_taunt_seconds` is taunted for, at `forced_taunt_points`; the meter on the HUD fills toward it, and a voluntary taunt resets it. The list is `taunts/taunts.json`, which an owner edits.

## Decision 5: the end of a round finds the last props

With `beacon_props_left` props left or `beacon_seconds_left` seconds to go, every live prop pings: a sound and an expanding ring everybody sees (`DotFxBeacon`, dot-fx), every `beacon_period`.

## The HUD is dot-ui's glance pieces

The clock is a `DotScoreStrip` with the props and hunters still up as its two side plates in the sides' colours, and "Hunters released in · <map>" under it (the blindfold's own clock uses `DotScoreStrip.clock_text` too, so the two never disagree by a second). "Look at a prop and become it" is a `DotKeyPrompt` under the crosshair with the disguise key as bound. **Health is a `DotVitals`, not the old number on a disc**: a prop's health is a share of a size-derived maximum (10 to 200), so a bare number said nothing about how much of you is left; the bar says the share, its fill keeps the side's colour the disc carried, and the cross is drawn only on a body. The plate ends 214 pixels off the bottom, above the chat box's full eight-row log (202). Colours from `PhHud.piece_theme()`. `headless_run` checks the pieces, the plate against the chat log and that the derived `requires.json` asks for dot-ui 4.

**H is help** (dot-menu's stock key and its top-right "H Help" plate; `PhSettings._fill_help` writes the goal and each side's rules), so nothing in `PhBindings` may default to H, and the Escape menu has dot-menu's stock Help and Leave. `headless_run` checks both.

**M is the map list** (dot-menu's map menu): `PhGame.map_rows()` and `change_map_now()` (the next map plus dot-match's `begin_round_now`) serve both solo and the server, where dot-vote's map menu lets the owner's `sv_map_menu_flag` change it now and gives anybody else a vote. It shares the taunt list's picker; a map choice never reaches `_on_taunt_picked`. Nothing in `PhBindings` may default to M; `headless_run` and `dedicated` check it.

## Sides, points and stats

`DotTeamRotation` (dot-team) draws the hunters: RANDOM (never the same person twice running when there is anybody else), QUEUE (everybody an equal share over time) or SWAP (last round's props hunt). `!hunter` / `!prop` / `!any` are wishes the draw honours where it can. Points: winning side 10, a find 5, surviving 5, taunts, and a point a second for a prop that shows its face (Q, `reveal_points_per_second`, paid for at most `reveal_paid_seconds`, then a `reveal_cooldown`). `PhProgress` keeps fourteen stats and eight achievements through dot-stats and dot-achievements, keyed by the player's TMC profile, and reports them when `report_progress` is on.

## Drawing a map

A map is hundreds of boxes and props. Boxes are batched by material, tint and 12 m chunk into one mesh each, because the Compatibility renderer lights a mesh with at most eight omni lights and a school as one mesh would be lit by eight of its fifty-two. Props are one `MultiMeshInstance3D` per model part. Generated textures are 128 px images made in code, laid in world space (as is the grid) so boxes of a material meet without a seam.

**Colour and light: rooms are pastel, furniture is Kenney's.** Every building surface (floor, wall, ceiling, roof, ground) is Kenney's prototype grid, or his tiles on a floor, under a pastel per surface (`PhMaterials.PASTELS`), the map's tint paled halfway to white on top; glass, boards, lockers, lines, metal and lamps keep their generated look, and furniture keeps its own colours. The light is a dot-lighting document from the map's `environment` (`PhMap.light_document`: its sun angle and colour, sky, horizon as fog from 120 m) with a near-neutral fill at the map's `ambient_energy` and glow only above white, turned down under Compatibility (`PhMap.light_profile`); a cool fill or arena's flat 1.0 fill turned rooms into a lavender haze. Check both renderers (`GODOT=<wrapper adding --rendering-method forward_plus> tools/shot.sh`).

**Kenney's Nature Kit is teal and coral by design**, and beside realistic rooms it read as a cartoon (the first school render had cyan trees with pink trunks). `props/kits.json` gives a kit a `recolour` table, material name to colour, which `PhProps` applies to a copy of each mesh as it loads. Furniture keeps its own colours except the plant.

## What running it found

- **Offline, no hunter's shot ever landed** (2026-10-12): `PhClient._drive_offline` stamped fire, alt and reload onto `controller.current_command`, and `PhPlayer.simulate` then applied a fresh `sampler.sample()` over it, so the world's rig never saw a trigger (the play test's "shots that do not register", and part of why decoys never cost him). The buttons go onto the world's own sample through `PhPlayer.command_stamp`, set in `PhClient._adopt`; never stamp `current_command` for the world. `headless_run`'s "offline, the client's trigger" is armed. Found by game-zombie-zone's play test (its docs/history.md).
- **Spawns inside sofas**: six, on three maps, because a spawn is written before a room is furnished. Found by `headless_maps`; mg-prop-hunt-maps' builder now moves them itself.
- **A pool of grass, a dark band round the gym, and washed-out daylight**: all three found by rendering, none by a check. The maps repo's CLAUDE.md has each.
- **A chair's 98 health was 97.9 on the client**: 12 bits over 0..1000 for `net_max_health`. 14 now.
- **`var rotation` on PhGame** shadowed `Node3D.rotation` and broke every transform; it is `hunter_history`.
- **dot-server-deploy had no `addons/dot_menu`** and a stale class cache, so the delivered game's client failed to parse; found by `prophunt_client` there, fixed locally.

## Validating

```bash
./game.sh test                                         # parse, then all four suites
python3 ../mg-prop-hunt-maps/tools/build_maps.py --check
xvfb-run -a godot --path . res://tools/audio_probe.tscn
tools/shot.sh --view=overview --ph-map-ids=ph_school
tools/shot.sh --view=room --ph-map-ids=ph_school --at=-38,1.7,3.5 --look=-26,0.8,14
tools/shot.sh --view=prop --as=furniture_chair_cushion --ph-map-ids=ph_house
tools/shot.sh --view=blind
tools/shot.sh --view=hunter --board --name=board
godot --headless --path . --script tools/measure_props.gd -- --check   # catalogue matches the models
```

`headless_run`'s and `headless_net`'s totals were wrong when first written and both fired; `headless_maps` was armed with a spawn put inside the practice kitchen's chair. Without `maps/` linked in (CI clones this repository alone) `headless_maps` checks the practice house only, as mg-deathrun's headless_courses does, and says so.

`project.godot` carries no comments: the editor drops them, and any key left at its default, the first time it saves the file, so the reasons for its settings live here. Gravity stays the engine default and nothing reads it: `PhConfig.gravity` is written onto the world's own physics space, because a project setting does not travel inside a delivered pack. The renderer is `gl_compatibility`, what the delivered client runs, and lighting is tuned under it. The canvas texture filter is Nearest so the prototype grid reads as discrete squares at distance. Texture imports keep `detect_3d/compress_to=0` (`[importer_defaults]` starts new ones that way) so the editor never re-imports one VRAM-compressed on a first open.

## Delivery

The maps are their own repository and pack, [mg-prop-hunt-maps](../mg-prop-hunt-maps): `maps/` here is a dot-bootstrap link (`.gitignore` names it), and `game.yml` does not name the pack: the server owner names `gamemann/mg-prop-hunt-maps` (or their own) in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills `DotGameDescriptor.maps`). `PhModule._add_delivered_maps` asks dot-game's `DotGameContent.map_dirs(server, "maps")` for every pack the server names, fetched through dot-cloud, and adds each mount's `maps/` to the catalogue at load and after every `ph_reload`. The game's own pack carries only `ph_practice`. A client is sent the one document being played. dot-server-deploy has `content/prophunt/`, `content/prophunt_maps/` and `examples/prophunt_client` (22 checks): the delivered pack boots, a real client joins over a real socket, the maps, prop catalogue and taunts are read from their mounts, and the client builds the server's map with every prop. No `class_name` anywhere in `game/`, because a mounted pack cannot register one.

**The map vote** (`game/ph_vote.gd`, MANUAL, applied at a round's end): under MANUAL `PhVote` opens a passed rock-the-vote itself (dot-vote does not; `rtv_delay_sec` 0), and `_game_load` refreshes the map list after `_add_delivered_maps`. Without either, `!rtv` answers "Rocked. 1 of 1." and nothing opens, or a delivered server's ballot holds only the practice map and never opens. `examples/dedicated` arms both. The match answers dot-vote's `round_in_progress_fn` (`world.match_node.is_live()`, set by name because an older shell's dot-vote lacks it), so a `time_up: finish_round` limit that runs out in warmup or between rounds changes at once instead of holding for `finish_round_max_sec`; `dedicated` checks both halves.

**Before publishing**: dot-props (API level 2), dot-team (2), dot-fx (2), dot-game (3), dot-ui (4) and dot-menu must be tagged and in the client shell, or the pack fails to parse in it.

## Still to do

1. **Put it live.** Tag the addons above, rebuild the shell, publish the maps pack before the game.
2. **Try it in a browser**, with people: how long a hide should be and how much a decoy should cost are numbers only play settles.
3. Better stand-ins: a bot prop picks something near, not something clever.
