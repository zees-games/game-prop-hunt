# History

Bug stories worth keeping, newest first. The rule each one left is in `CLAUDE.md`.

## The hunter's weapons were "completely broken" (2026-10-12)

Christian's first play test: the hunter's gun was a green sniper, a purple rifle, a hammer, a pistol, a frag, with no slot logic; no ammunition counter, only "R Reload 1-3 Weapons"; no impacts; and health stayed at 100 while he shot sinks and boxes.

- **The drawn rig was given the whole pack.** `PhClient._arm_locally` called `give_everything`, and dot-weapon keeps one weapon per slot, so each slot held whichever of the 27 was given last: slot 3 the marksman rifle, 4 the charge rifle, 5 the sticky grenade. None was the gun the server fired. It now gives each weapon `player_armed` names, and `headless_run` compares the two rigs slot for slot (it fails with `give_everything` put back).
- **The default loadout put two guns in one slot.** "smg", "shotgun", "hatchet": the SMG and the shotgun are both primaries (slot 3), so the shotgun replaced the SMG and keys 1-3 had an empty slot. The default is the SMG (3), the pistol (2) and the hatchet (1); `PhGame.hunter_slot_clash` warns when a server's list clashes.
- **No count.** A `DotAmmoCounter` bottom right counts the drawn gun, which predicts; `PhClient.correct_drawn` takes the server's count once the gun has been quiet 0.6 s (game-zombie-zone's rule), so a refused shot or a fresh round's refill does not leave the counter on the client's own sum.
- **No damage from furniture, no impacts** were mostly the offline trigger never reaching the world's gun (fixed the same day, `PhPlayer.command_stamp`), and partly the drawn rig holding a hammer or a pistol the server did not have. The furniture is one static body, so walking into it moves nothing the decoy check reads. The flash and tracers are there: a software renderer draws a few frames a second and a flash lasts a few hundredths, so `tools/shot.sh --fire` slows time while it holds the trigger.
- **The net suite's chair shot passed only with the shotgun.** At 0.5 m a single SMG ray passes between the chair's seat and back (it is its pieces now, not its box); the pellets caught it. The test aims at the seat.
