# History

Bug stories worth keeping, newest first. The rule each one left is in `CLAUDE.md`.

## The school's toys were not the school's problem (2026-10-13)

Any loose toy outdoors on the school (a ball or a tyre on the field or the playground) took `headless_bots` from 7 to 8 props' rounds in 12 there, past the 25-65% band, and nothing the bots ask of the physics space could see a toy (shots, pushes, queries and collisions were each switched off and it held). So the school shipped with one ball, indoors. Played round by round, the toys changed exactly one round of 32 compared: the rotation's first, the school on seed 0, where the hunters found the last prop with 3 s left. A per-tick trace put the first difference at one hunter's height, 0.00015 m, 40 m from any toy; an invisible `StaticBody3D` with no collision layer and no mask, at the field or in the hall, flipped the same round, and one 500 m away changed it without flipping it. A body in the physics space reorders what the engine's motion queries meet, the last float bit of a controller's position moves, and a round already on a knife's edge goes the other way. The real fault was underneath: over 48 seeds the school gave the props 36 rounds (75%) with four hunters for eight, and the twelve the suite plays happened to give 7. With five hunters (`players_per_hunter` 1.6) it is 38% over 24 seeds, and the outdoor toys are back. The rule: a band on a map's twelve rounds is only a band if the map's share over many more seeds sits well inside it; re-measure on `--map <id>` (48 of that map's rounds) before believing a change moved a map, and a one-round difference is noise until a second seed agrees.

## The props won the school and lost the woods (2026-10-12)

`headless_bots` held the props to 35-55% of rounds over the four maps, and 11 in 24 passed, while the school gave them 11 rounds in 12 and the woods 1. A mean over maps is no band on any of them. The density of hiding places decided it (319 on the school, 68 in the woods), so the maps now set their own share of hunters (`players_per_hunter`) and the suite holds each map to its own band.

## The last half minute decided the rounds (2026-10-12)

With the bots playing properly the props still won 3 of 20 rounds at medium, 92 of 100 found, many of them in the last 30 s: the time beacon (`beacon_seconds_left` 30) showed every prop still in to every hunter, and a round the props had held was lost there. Off by default now (11 of 24); the last prop's beacon still ends a round nobody can find anybody in. game-hide-n-seek had found the same the same morning. The suite's band was a tenth to nine tenths of eight rounds, which 3 of 20 passed; it is 35-55% of twenty-four now.

## The bots did not know how to play, and the school was in the way (2026-10-12)

Christian's first play test: "The bots don't know how to play the game at all", "Random things in the middle of the hallway and a sink blocking a room?", sinks and boxes sliding and tumbling, and "4 props left" on the board for the whole hunt.

- **The hallway's sinks and bins were stand-ins.** The props start in the school's hallway; a stand-in walked to the nearest piece it could become (the bathroom's sinks, the bins) and became it where it stood, out in the hallway. When it thought it was stuck it hopped, so a disguised sink rose to shoulder height and slid: the furniture that "slides and tumbles" was never the map's (that is one static body). The new stand-ins (`ph_bots.gd`, [bots.md](bots.md)) hide beside a piece of their kind and never hop disguised.
- **"4 props left" was true.** The count is `alive_on`, which drops with every death; nobody died. `headless_bots` now checks the board against the props alive after every find.
- **The map had its own faults**, found by a doorway check added to mg-prop-hunt-maps' builder and by `headless_bots`' reachability count: a bathroom sink actually in the hallway; a toilet inside each bathroom's door (the stalls were on the door's wall); the two north classrooms' boards across their doors at chest height (78 of 319 hiding places on the school could not be walked to); a window run cutting into the front doors; on the house, the kitchen counter across the door to the kids' room, the television across the living room's opening, the bathtub at the back door and a fence 0.3 m outside the back wall across two doors; on the woods, the garden's gate opening onto a row of melons.
- **Nothing broke, and there was little to be.** Breakable furniture and 41 more props (Food and Survival kits) came with it; see [design](design.md#breakable-furniture).
- **Every stand-in prop "fled" at the seek's start**: it read the drop in health from a new disguise's maximum as a shot.

## The hunter's weapons were "completely broken" (2026-10-12)

Christian's first play test: the hunter's gun was a green sniper, a purple rifle, a hammer, a pistol, a frag, with no slot logic; no ammunition counter, only "R Reload 1-3 Weapons"; no impacts; and health stayed at 100 while he shot sinks and boxes.

- **The drawn rig was given the whole pack.** `PhClient._arm_locally` called `give_everything`, and dot-weapon keeps one weapon per slot, so each slot held whichever of the 27 was given last: slot 3 the marksman rifle, 4 the charge rifle, 5 the sticky grenade. None was the gun the server fired. It now gives each weapon `player_armed` names, and `headless_run` compares the two rigs slot for slot (it fails with `give_everything` put back).
- **The default loadout put two guns in one slot.** "smg", "shotgun", "hatchet": the SMG and the shotgun are both primaries (slot 3), so the shotgun replaced the SMG and keys 1-3 had an empty slot. The default is the SMG (3), the pistol (2) and the hatchet (1); `PhGame.hunter_slot_clash` warns when a server's list clashes.
- **No count.** A `DotAmmoCounter` bottom right counts the drawn gun, which predicts; `PhClient.correct_drawn` takes the server's count once the gun has been quiet 0.6 s (game-zombie-zone's rule), so a refused shot or a fresh round's refill does not leave the counter on the client's own sum.
- **No damage from furniture, no impacts** were mostly the offline trigger never reaching the world's gun (fixed the same day, `PhPlayer.command_stamp`), and partly the drawn rig holding a hammer or a pistol the server did not have. The furniture is one static body, so walking into it moves nothing the decoy check reads. The flash and tracers are there: a software renderer draws a few frames a second and a flash lasts a few hundredths, so `tools/shot.sh --fire` slows time while it holds the trigger.
- **The net suite's chair shot passed only with the shotgun.** At 0.5 m a single SMG ray passes between the chair's seat and back (it is its pieces now, not its box); the pellets caught it. The test aims at the seat.

## Offline, no hunter's shot ever landed (2026-10-12)

`PhClient._drive_offline` stamped fire, alt and reload onto `controller.current_command`, and `PhPlayer.simulate` then applied a fresh `sampler.sample()` over it, so the world's rig never saw a trigger (the play test's "shots that do not register", and part of why decoys never cost him). The buttons go onto the world's own sample through `PhPlayer.command_stamp`, set in `PhClient._adopt`; never stamp `current_command` for the world. `headless_run`'s "offline, the client's trigger" is armed. Found by game-zombie-zone's play test (its docs/history.md).

## The first days (2026-10-09 to 10-11)

Built 2026-10-09 from mg-deathrun's skeleton (module, services, wire, client, HUD, spectate, progress, avatars, figure, vote), renamed `dr` → `ph` and rewritten wherever they named a course, a trap or an activator; where a comment says another game found something, the finding is that game's and the line was kept because it is still true here. `headless_run`'s and `headless_net`'s totals were wrong when first written and both fired; `headless_maps` was armed with a spawn put inside the practice kitchen's chair.

Found by running, each with the rule it left (in `CLAUDE.md` where it still bites).

- **Spawns inside sofas**: six, on three maps, because a spawn is written before a room is furnished. Found by `headless_maps`; mg-prop-hunt-maps' builder now moves them itself.
- **A pool of grass, a dark band round the gym, and washed-out daylight**: all three found by rendering, none by a check. The maps repo's CLAUDE.md has each.
- **A chair's 98 health was 97.9 on the client**: 12 bits over 0..1000 for `net_max_health`. 14 now.
- **`var rotation` on PhGame** shadowed `Node3D.rotation` and broke every transform; it is `hunter_history`.
- **dot-server-deploy had no `addons/dot_menu`** and a stale class cache, so the delivered game's client failed to parse; found by `prophunt_client` there, fixed locally.
- **A READY that overtook the seat was dropped (2026-10-12).** A client sends READY when its link says PLAYING, which the link decides itself after sending `loaded` on another ENet channel. Through a lossy link the READY can reach the server first; `_admit` found no player for the peer and returned, and nothing asked again, so that client never got a world. Loopback and WebSocket order the two, so no suite could see it until `headless_net` sent the READY before the seat.
