# Stage 10 — The game

Stage 9 ended with a fast, well-tested simulation on a real city's
streets. Stage 10 turns it into a game: you're a delivery rider
(a bicycle to start, a van one day) making timed runs through the
gang war for money, and spending it on guns, armor, vehicles and
abilities. Biker packs, a cartel hit team and the good ole boys join
the chaos later. The full roadmap is the "Stage 10+" section of
[`assembly-project-plan.md`](../assembly-project-plan.md).

The simulation stays as the test harness: `HEADLESS=1` runs it with
no player, so batches and the fixed-seed checks keep working.

## Build

```bash
make                          # every step
./build/01_modules            # the latest: wheel zooms, W A S D pans
STAGGER=0 ./batch.sh 48       # headless, 4 games at a time
python3 tools/gen_southside.py                      # rebuild the map in maps/
python3 tools/gen_sprites.py --write 01_modules/sprites.asm
HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/01_modules
```

**Steps are folders now.** Each step is `NN_name/`: a `main.asm` and
the modules it `%include`s, copied from the step before, so every step
still builds on its own and the history stays readable. The map
(`maps/`) and the tools (`tools/`, `batch.sh`) are shared, copied from
stage 9. The Makefile builds `NN_name/main.asm` to `build/NN_name`,
with the folder on NASM's include path (`-i`), and rebuilds a step
when any of its modules or anything in `maps/` changes.

## `01_modules/` — the source, split into modules

`stage9/03_bfs.asm`, cut into 22 files: `main.asm` (the header, the
externs, and the list of modules) and 21 modules, one per concern:

| Module | What's in it |
|---|---|
| `constants.asm` | constants, the map include, structs, colours |
| `data.asm` | settings, messages, counters, event state, framebuffers, the font |
| `sprites.asm` | the pixel art (written by `tools/gen_sprites.py --write`) |
| `tables.asm` | palettes, camera, day-and-night keys, gang colours, flow directions |
| `bss.asm` | grids, fields, buffers, soldiers, pickups |
| `game.asm` | `main` (the loop), the RNG, spawning, reading settings |
| `pathfinding.asm` | the walkable grid and the flow fields (BFS, `flow_waypoint`) |
| `hud.asm` | the font renderer and the scoreboard |
| `respawn.asm` | rules from the environment, respawns |
| `background.asm` | the pre-drawn map, shadows |
| `camera.asm` | the view: copying it, zoom, pan |
| `lighting.asm` | day and night |
| `ground.asm` | blood, casings, pools |
| `draw_sprites.asm` | sprites, soldiers, the dog walker |
| `bosses.asm` | the Big Homie |
| `events.asm` | the police and the dog |
| `ai.asm` | targets, weapons, the blockmap, line of sight, `update_soldiers`, `first_in_line` |
| `results.asm` | the win line |
| `effects.asm` | attack effects |
| `win.asm` | `check_win` |
| `primitives.asm` | `set_pixel`, `fill_rect`, `draw_line` |

**The order is the program.** NASM lays code and data down in the
order it reads them, so the modules are `%include`d in exactly the
order their code stood in 9.03, cut at the banner comments (or the
comment block above a function). Only comments moved: the "Build and
run" footer is at the end of `main.asm` now. The code modules each
open with `section .text`, which changes nothing, since they were all
in `.text` already.

**Proof.** Built with 9.03's window title, the two binaries' `.text`
and `.data` sections are identical, byte for byte, at the same
addresses (`objcopy -O binary -j .text`, then `cmp`): the same
program. With the title changed to "Stage 10.01", the usual
fixed-seed check: the end state (`soldiers`, `pickups`, `rng_state`,
`ticks`) is identical to 9.03's for 12 seeds headless and one
windowed. And `gen_sprites.py --write` on a copy of `sprites.asm`
writes it back unchanged.
