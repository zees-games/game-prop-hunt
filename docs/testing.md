# Testing

`./game.sh test` runs the parse pass and every suite in `examples/` (headless_run, headless_workshop, headless_maps, headless_bots, headless_net, dedicated), each counting its sections and its checks.

## headless_bots has two lengths

The full run plays 96 rounds (twelve a map over the eight rotation maps) and takes about 13 minutes on dev02 (under 800 s measured 2026-10-22) and about 24 on the staging laptop (1443 s); that is the local default, and the one that holds each map to its own band. **It does not fit a CI runner**: dot-ci caps a suite at 900 s (`suite-timeout`) and a job at 30 minutes.

When the `CI` environment variable is `true` (GitHub Actions sets it) and `--rounds` is not given, the suite plays `CI_ROUNDS` (16: two a map) instead. Every section and every check still runs; what changes is the statistics:

- the mean close-game share is held to 20-70% (`CI_PROPS_WIN`) instead of 35-55%, because sixteen rounds spread about 25 points;
- the per-map bands need twelve rounds a map (`MAP_ROUNDS`), so they are reported and not held. Run `CI=` (empty) locally, or `-- --map <id>`, to hold them.

`-- --rounds N` always wins over the CI default. A change to the bots or a map's balance is judged on the full local run, never on the CI one.

## Why a place is "cut off": `tools/nav_islands`

`headless_bots` says a hiding place is cut off but not why. `godot --headless --path . res://tools/nav_islands.tscn -- --map <id> [--dir=<folder of map documents>] [--dump=<file.json>]` bakes the map's navigation mesh and lists its islands (sets of polygons joined by shared edges) with their bounds and how many hiding places each holds, the props' start island first. A big island with dozens of places is a level or room the mesh does not link to the start (a 0.9 m doorway the bots' radius cannot pass, a trim post in a door, a stair whose last step is a lip); `--dump` writes the polygons for plotting. The map importer's `--widen-thick-doors`, `--pocket-margin` and `--prune-levels` exist because of what this showed.
