#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh --view=overview --ph-map-ids=ph_school         # a map, from above
#   tools/shot.sh --view=room --at=0,1.7,-6 --look=0,1,-14 --ph-map-ids=ph_school
#   tools/shot.sh --view=hunter                                   # a hunter's eyes, seeking
#   tools/shot.sh --view=prop --as=furniture_chair                # a prop in third person, hidden
#   tools/shot.sh --view=prop --as=survival_bottle --lean=6       # leant: 6 steps is on its side, 12 on its nose
#   tools/shot.sh --view=dead --seconds=1.5                      # a hunter killed: their ragdoll (--victim=prop --as=<id>: a found prop bursts)
#   tools/shot.sh --view=killcam --seconds=2                      # the last hider found, replayed (--seconds=9: the winner reveal)
#   tools/shot.sh --view=person --seconds=1                      # somebody else, with their hull (green) and hitboxes (red)
#   tools/shot.sh --view=blind                                    # a hunter while the props hide
#   tools/shot.sh --view=round --seconds=5 --ph-minimum-players=7 # a round in progress: stand-ins hid on the clock, a hunter seeking
#   tools/shot.sh --view=hunter --board                           # with the Tab scoreboard open
#   tools/shot.sh --view=hunter --fire=12 --aim-prop              # trigger held (slowed) at the nearest furniture: flash, tracers, impacts, the counter, a decoy's cost
#   tools/shot.sh --view=hunter --aim --name=hunter_aimed        # down the sights (compare --view=hunter)
#   tools/shot.sh --view=loadout                                  # B open in the hide: a hunter's loadout
#   tools/shot.sh --view=maps --seconds=0.5                       # M: the solo map list with a Workshop fixture map (Name [Pack])
#   tools/shot.sh --view=cover                                    # the loading cover, before it lifts
#   tools/shot.sh --view=grenade --seconds=0.4                    # a frag thrown from slot five, in flight (--seconds=2: its burst)
#   tools/shot.sh --view=overview --out=res://screenshots/x.png   # any --ph-* is the game's config
#
# xvfb-run because this needs a rendering context: `--headless` gives a null renderer and saves
# a frame of nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="hunter"
seconds="3"
out=""
config=("--ph-warmup-seconds=0" "--ph-hide-seconds=3")
extra=()

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --ph-*)      config+=("$arg") ;;
        --at=*|--look=*|--as=*|--lean=*|--board|--name=*|--fire=*|--aim-prop|--aim|--victim=*) extra+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

name="$view"
for e in "${extra[@]}"; do
    case "$e" in --name=*) name="${e#*=}" ;; esac
done
[ -n "$out" ] || out="res://screenshots/${name}.png"

exec xvfb-run -a -s "-screen 0 1280x720x24" "${GODOT:-godot}" --path . --resolution 1280x720 \
    res://tools/shot.tscn -- "--seconds=$seconds" "--view=$view" "--out=$out" "${extra[@]}" "${config[@]}"
