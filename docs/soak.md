# Bot soak

`./game.sh soak [map] [minutes]` runs `tools/soak.tscn`: six stand-ins in the real `PhGame` on one map (`ph_house` by default), driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts, ticked externally at 32 Hz. The hide is cut to 10 s and the round to 90 s so a run sees several rounds and teardowns. Only a live hunter in the seek counts as a mover with a goal: props stand still by design and hunters are held in the hide. Rounds run back to back. The report is `.godot/test-logs/soak-<map>.json` plus one `SOAK {...}` line (with `rounds`, `rounds_over` and `seek_sec`), and the exit code is 1 on failure. There is no navigation mesh in this harness, so off-nav and unreachable are off, and the harness does not see this game's combat, so its kill and damage counters stay 0.

**Needs the linked `addons/dot_spawn`** (gitignored like the other links, made by dot-bootstrap or `ln -s ../../dot-spawn/addons/dot_spawn addons/dot_spawn`; used by the tool only, never by the game), and an `--import` after adding it.

First run, 2026-10-22: `ph_house` 2 simulated minutes, `ph_school` and `ph_woods` 1.5 each. All pass: no stuck hunter, no fell-out, tick p95 1.4 to 3.2 ms, object growth under 0.2 percent, 2 to 3 rounds each.

- The worst tick is 47 ms (`ph_house`), 106 ms (`ph_woods`) and 180 ms (`ph_school`): the round change, where the map is built again. It is under the p95 gate by design, but a server that rebuilds a map in one tick of 180 ms stalls for six ticks. Filed on the nightly board.
