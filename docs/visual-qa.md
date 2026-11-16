# Visual QA

Every person, hunter weapon and catalogue prop gets its own test scene, recorded frame by frame at 60 fps and judged from the frames. The harness is dot-game's (`addons/dot_game/docs/visual-qa.md` in the dot-game repo); this game only supplies `tools/visual_qa.gd`, a subclass of `DotGameVisualQaCapture`, and a three-line `tools/visual_qa_shot.sh`. The outside cameras are the shared `DotGameVisualQaViews`.

## Items and clips

| item | clips | first person | outside |
| --- | --- | --- | --- |
| `person_<letter>` (a b c e f k) | idle walk run crouch jump | a hunter's eye 2.5 m in front | behind-right, opponent |
| `weapon_<id>` (every hunter weapon) | idle draw fire reload | the real `ZeeViewModel` with its arms | the person holding it (`PhFigure.hold`), from the gun-hand side so a held gun reads in profile |
| `prop_<id>` (every catalogue prop) | turntable | a hunter's eye looking at it | behind-right, opponent |

Person speeds are `PhConfig` (run 6.5 m/s, walk and crouch 0.45 of it). Reload is skipped for weapons with no magazine. The fire clip fires at the weapon's own use interval, as in a match, or every 0.5 s for one without; a faster cadence restarts a melee swing mid-follow-through. A melee or thrown weapon's fire clip judges `bone_pop` at 130 degrees, not 90: a real strike turns the forearm about 111 degrees in the 1/15 s window.

Prop rows: `prop_floor_m` (lowest point against the floor) and `prop_real_size` (the drawn prop's largest dimension against a real object's, from `props/real_sizes.json`). That file maps prop-id patterns to a real size in metres, passed within its `tolerance` times it, or to a `[min, max]` band for things that come in many sizes; the first match wins and a prop no pattern matches fails, so a new prop needs an entry. A prop that is the wrong size gets a per-model `scales` entry in `props/kits.json`, then `tools/measure_props.gd` again.

## Running

```
bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh --fresh all
bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh --fresh weapon_smg -- --only weapon_smg --clips fire,reload
```

Run it as the user that holds the box key (gamedev), from the checkout or a `~/wt` worktree. Output is `screenshots/visual_qa/` (ignored by git): `report.md`, per-item sheets and `.mp4` clips. Open the sheets and look; the numbers (foot_slide, floor_contact, bone_pop) only catch some of it.

## Known

- `bone_pop` reads 92 to 111 degrees on the walk, run, crouch and jump cycles of the shared humanoid figure (dot-player-char), not this game; filed on the nightly board.
- `prop_real_size` fails for a few oversized props that converted maps stack other props on (keyboard, screen, laptop, coffee tables, toaster, melon): mg-prop-hunt-maps bakes their heights, so rescaling them alone floats what stands on them. They change together with a maps `--sync-sizes` rebuild (nightly `ph-props-real-size-restack-1`).
- The prop cameras stand off by the prop's own size, so an apple fills the frame as a sofa does; compare props by `prop_real_size`, not by how big they look in the sheets.
