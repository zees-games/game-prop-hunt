# Bots

The stand-ins are `game/ph_bots.gd`, built on dot-bot: its settings (`bot_difficulty` and every `bot_*` cvar, solo at the console too), its view turning and trigger (`DotBotAim`), and its hiding helpers (`DotBotNav`, `DotBotHiding`, `DotBotSearch`). `PhGame._drive_bots` calls `bots.drive()` before the bodies move; `_bot_shoot` and `_bot_aim_of` are kept as thin wrappers for the suites.

## What the first play test saw

Christian, 2026-10-11: "The bots don't know how to play the game at all." In the video four stand-in props stood in the school's hallway as sinks and bins (the props start in the hallway, and a stand-in became the nearest thing it could, where it stood), hopping whenever it thought it was stuck, so the "furniture" slid and jumped about. The stand-in hunter walked from one random prop to the next. The board said "4 props left" for the whole hunt because nobody found anybody: the count was right, the hunt was not.

## The map is surveyed once

When a map is built (on the server, or solo), `DotBotNav` bakes where a body can walk from the walls and the furniture, and a place is put beside each piece of floor furniture a prop may become (one side of it, on the mesh). `DotBotHiding.survey` scores each place by the share of eighty watchers' sight lines that reach it. Each place remembers its piece: that piece is the disguise, its facing the lock. A quarter of a second of game time after the bake, always the same tick, so a seeded round replays the same.

## The map's annotations

After the first survey, `PhBots` runs dot-npc-ai's `DotNpcAiNavAnnotator` (`game/ph_nav_annotator.gd`, a subclass; no `class_name`) over the baked mesh, a fixed 48 slices a tick so a seeded round replays the same, and on every map whether or not the bots use it (the suite measures against it). The subclass overrides `_hide_score`: a spot only scores if a piece of floor furniture a prop may become stands within `ph_bot_beside` (1.3 m) of it, and then by sight (out of watchers' view), enclosure (tucked against a wall or a piece) and fit (others of the piece's kind within 6 m); each such spot is stamped with the piece (`prop`, `kind`, `yaw`, `kin`), so the disguise is chosen for where the prop goes, not the other way round.

With `ph_bot_nav` on (the default) the props' places are those spots, best first and 2.5 m apart (`DotBotHiding.choose` over exposure 0.3 sight + 0.3 misfit + 0.4 untucked), and the relocation (`ph_bot_relocate_*`) and fleeing use the same list. The hunters' search places are the same spots plus the chokepoints (later in the order), and a hunter knows at least `ph_bot_sweep` of them (0.7), which makes it sweep the best spots before the near ones. `ph_bot_nav 0` is the first way, kept so the suite can show what the annotations change (`headless_bots -- --nav 0`).

Measured over the suite's 48 medium rounds, `--nav 0` against the default: props won 20 and 19 of 48; a prop lasts 135 s and 144 s; a prop ends tucked in on 0.24 and 0.28 of its sides; hunters pass 90% and 92% of the 16 best places in 30 s. Placement beside same-size furniture barely moves (99% and 98% next to a piece, 80% and 74% among two or more, seen by 16% and 15% of watchers) because the first survey already hid beside furniture of the prop's size. The annotations add a better choice between those places, a small gain; the sweep (`ph_bot_sweep`, default 0.1) is kept small because every larger value made the hunters win a map outright (woods 2 of 12, school 0 of 12): the round outcomes swing by several rounds per map between runs of the same code, so judge a change on the totals, not a single map. The bands that separate the two ways are the tucked-in share (0.26) and the hunters' coverage of the best places (91%); the lasting-time and win bands are too noisy to separate them.

`tools/shot.sh --view=spots --ph-map-ids=ph_school` draws a map's annotations (dot-npc-ai's `DotNpcAiNavDebug`) from above.

## A prop hides as what belongs there

A place counts for more the more of its kind stand round it within 6 m (a chair among thirty is lost, a sink in a corridor is not), and less the more it is seen; the two are halved into what `DotBotHiding.choose` reads as exposure. Places near other props' places and near the hunters' start are scored down, and only places it can walk to before the hunters are let go count; `bot_map_knowledge` is how far down the list it looks. It puts the piece on early (`ph_bot_disguise_delay`, 1.5 s into the hide) and walks the rest of the way as it, so it is never a person in the open; a refusal (no room for the hull there) is tried again on arriving. It walks the mesh as a person (sidestepping when stuck, hopping only as a person: a sink in mid-air was the play test's sliding furniture), turns to the piece's own facing, becomes it, locks it, and keeps still. Late, it becomes the thing at once and keeps going: a moving chair is a risk, a person is certain death.

During the seek it watches for hunters. Shot (health lost under the same disguise; a new disguise changes the maximum and carries the share, which is not a shot), it runs to a place out of that hunter's sight. Before the standing-still clock forces a taunt (60 s) it moves to another place of its kind within `ph_bot_relocate_range` (12 m), or any place there, when no hunter has been in sight for 3 s; with none seen for 8 s it does the same of its own accord about once in `ph_bot_relocate_seconds` (150; 0 never); with one watching, it keeps still and takes the taunt. About once in four minutes it taunts of its own accord, never with a hunter seen in the last half minute.

## A hunter searches and tests what looks wrong

It searches with a `DotBotSearch` over the same places: likely ones first as far as `bot_map_knowledge` goes, near first, never where another hunter is going. A taunt it hears (within `taunt_range`) puts the places round it first and sends it there.

Everything in view within 12 m gathers suspicion (looked at every fourth tick), faster the closer and the more aggressive (`bot_aggression`):

- a base for nothing (`ph_bot_suspicion`, 12 hundredths);
- +0.35 for a piece alone of its kind within 3.5 m;
- for a piece it remembers (a draw per hunter and piece, `bot_map_knowledge` divided by 1 + 0.6 × others of its kind near): real furniture it remembers drops to 15%, a prop it remembers was not there gains 1.2. A third sink is noticed; a thirty-first chair is not;
- +0.5 tilted, +1.4 within 5 m of a taunt heard in the last 10 s.

Past 1.0 it tests the thing: fires at it for 1.1 s. A prop that bleeds is found and hunted until it dies or is lost (then the places round where it went first); real furniture costs the decoy penalty and is crossed off for the round; a prop that did not bleed (a miss) is believed for 20 s. One test at a time, four seconds apart, and below 40% health only what it is nearly sure of. A prop seen moving, showing a face, or beaconed is shot on sight (`bot_fov`, `bot_sight` capped at 25 m, line of sight clear of furniture).

## Measured

`examples/headless_bots` (in `./game.sh test`, ninety-six rounds by default, twelve a map over the eight rotation maps, about 13 minutes on dev02 and 24 on the staging laptop; `-- --rounds N --first N --difficulty D`, `PH_BOTS_TRACE=1` prints positions, each death and why): eight stand-ins, the game's own draw (three hunters, five props), 32 ticks a second, deterministic, the four delivered maps in turn.

| 24 rounds | easy | medium | hard |
| --- | --- | --- | --- |
| a prop lasts, mean | 207 s | 156 s | 119 s |
| props found | 71 of 120 | 89 of 120 | 99 of 120 |
| rounds the props win | 16 of 24 | 11 of 24 | 7 of 24 |
| tests on props / on furniture | 84 / 53 | 77 / 61 | 71 / 36 |
| hunters killed by decoys | 0 of 72 | 0 of 72 | 1 of 72 |

Medium on the next 24 seeds (`--first 24`): 10 of 24. At medium every prop is disguised when the seek starts, fit 0.84 (others of the kind round it), 15 m apart on average, 1.2 s moving per prop-minute (moves before a forced taunt). Measured 2026-10-12 with the time beacon off (`beacon_seconds_left` 0, the default now). With it at 30 s the same rounds gave the props 4 of 20 and 94 of 100 found, many of them in the last half minute, because every hunter then walks to every prop still in; that is what decided the balance, as it did in game-hide-n-seek. Before the maps were dressed (lunch on the tables, crates, a camp) the props won 6 of 20; the stand-ins before the first bots pass lost every prop inside 70 s.

**Each map is a close game on its own.** The mean once hid it: of 24 medium rounds plus the next 24 the props won 11 of 12 on the school, 7 of 12 on the office, 2 of 12 in the house and 1 of 12 in the woods. Hiding-place density decides it: the school has 319 places, each among others of its kind (fit 1.0), so a hunter's memory of the map is spread thin and three hunters cannot cover it; the woods have 68 and the house 101 (fit about 0.7), and a lone piece is noticed. A map now sets its own share of hunters (`players_per_hunter` in its document, `PhConfig.hunters_for`) as well as its round and hide: the school four hunters for eight and a 20 s hide, the house and the woods two, the woods a 240 s round. Over 48 medium rounds (2026-10-12): school 7 of 12, house 5, office 7, woods 5; 24 of 48 overall. The school's 7 was a lucky twelve: over its own 48 seeds (`-- --map ph_school`) it was 36 of 48, so it has five hunters for eight now (`players_per_hunter` 1.6): 9 of 24 over its own seeds, and its toys outdoors again ([history](history.md#the-schools-toys-were-not-the-schools-problem-2026-10-13)). A one-round change on a map is noise: any body added to the physics space, even one nothing collides with, re-rolls a knife-edge round.

The suite plays 96 rounds by default (twelve a map over eight maps, 13 minutes on dev02, 24 on the staging laptop; `-- --map ph_house` plays one map's rounds of the rotation) and holds medium to bands: each map on its own 25-65% for the props once it has twelve rounds, all disguised, fit at least 0.5, at most 3 s moving per prop-minute, **the props win 35-55% of rounds**, a find in at least half, furniture tests at most three times the prop tests, at most one hunter in five killed by decoys, the board's "props left" equal to the props alive after every death, and at most one hiding place in fifty cut off from the props' start (78 of 319 on the school were, until its north classrooms' boards stopped running across their doors). `--difficulty easy` wants the props winning at least half the rounds, `hard` at most two in five.

## Looking at it

`tools/shot.sh --view=round --seconds=4 --ph-minimum-players=7 --ph-map-ids=ph_school --ph-hide-seconds=14` plays a round offline on its own clock (you a hunter, the stand-ins props), prints where every prop hid and as what, and saves the hunter's view; `--at=x,y,z --look=x,y,z` looks at a hiding place instead.
