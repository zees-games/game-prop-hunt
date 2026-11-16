#!/usr/bin/env bash
# Prop Hunt's on-box visual QA capture (docs/visual-qa.md): dot-game's shot tool runs tools/visual_qa.gd.
# Normally started by dot-game's driver:
#   bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh -- [--only person_a,weapon_smg,prop_food_apple] [--clips idle,fire]
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
