# Design: the decisions this game rests on

What this game decides, and why the obvious alternative is wrong. The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## What this game is, versus the others

The third asymmetric one, after buses and deathrun, and the first where **one side's whole move is to stop moving**. A prop's skill is choosing what to be and where; a hunter's is reading a room for the thing that is slightly wrong, and the decoy charge is what makes that a skill rather than spraying every chair.

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

## Sides, points and stats

`DotTeamRotation` (dot-team) draws the hunters: RANDOM (never the same person twice running when there is anybody else), QUEUE (everybody an equal share over time) or SWAP (last round's props hunt). `!hunter` / `!prop` / `!any` are wishes the draw honours where it can. Points: winning side 10, a find 5, surviving 5, taunts, and a point a second for a prop that shows its face (Q, `reveal_points_per_second`, paid for at most `reveal_paid_seconds`, then a `reveal_cooldown`). `PhProgress` keeps fourteen stats and eight achievements through dot-stats and dot-achievements, keyed by the player's TMC profile, and reports them when `report_progress` is on.
