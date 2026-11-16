# Visual QA

Every person, hunter weapon and catalogue prop gets its own test scene, recorded frame by frame at 60 fps and judged from the frames. The harness is dot-game's (`addons/dot_game/docs/visual-qa.md` in the dot-game repo); this game only supplies `tools/visual_qa.gd`, a subclass of `DotGameVisualQaCapture`, and a three-line `tools/visual_qa_shot.sh`. The outside cameras are the shared `DotGameVisualQaViews`.

## Items and clips

| item | clips | first person | outside |
| --- | --- | --- | --- |
| `person_<letter>` (a b c e f k) | idle walk run crouch jump | a hunter's eye 2.5 m in front | behind-right, opponent |
| `weapon_<id>` (every hunter weapon) | idle draw fire reload | the real `ZeeViewModel` with its arms | the person holding it (`PhFigure.hold`) |
| `prop_<id>` (every catalogue prop) | turntable | a hunter's eye looking at it | behind-right, opponent |

Person speeds are `PhConfig` (run 6.5 m/s, walk and crouch 0.45 of it). Reload is skipped for weapons with no magazine. Prop rows: `prop_floor_m` (lowest point against the floor) and `prop_height_ratio` (model height against the catalogue size).

## Running

```
bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh --fresh all
bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh --fresh weapon_smg -- --only weapon_smg --clips fire,reload
```

Run it as the user that holds the box key (gamedev), from the checkout or a `~/wt` worktree. Output is `screenshots/visual_qa/` (ignored by git): `report.md`, per-item sheets and `.mp4` clips. Open the sheets and look; the numbers (foot_slide, floor_contact, bone_pop) only catch some of it.

## Known

- `bone_pop` reads 92 to 100 degrees on the walk, run, crouch and jump cycles of the shared humanoid figure (dot-player-char), not this game; filed on the nightly board.
