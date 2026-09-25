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
./build/03_fair_homes         # the latest: wheel zooms, W A S D pans
STAGGER=0 ./batch.sh 48       # headless, 4 games at a time
python3 tools/gen_southside.py                      # rebuild maps/southside2.* (15 s)
python3 tools/score_pairs.py build/03_fair_homes    # re-score the home pairs (~40 min)
PAIR=0 ./build/03_fair_homes                        # a given pair of homes
python3 tools/gen_sprites.py --write 03_fair_homes/sprites.asm
HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/03_fair_homes
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

## `02_factions/` — factions instead of two teams

`01_modules/` with the two teams generalized into factions: the
groundwork for everyone who joins the fight later (Bikers, the cartel,
the good ole boys, the police, the player). The same game, byte for
byte.

**Factions.** `Soldier.team` is a faction now: 0 the Crips, 1 the
Bloods, and `NUM_GANGS` = 2 of them are gangs. `MAX_FACTIONS` = 8
slots in all. `score`, `tickets`, `boss_state`, `home` and `fwd_sign`
are sized for every faction (`times MAX_FACTIONS`).

**Who fights whom is a table.** `hostility` in `data.asm` is an
8 × 8 byte table: row a, column b is 1 if faction a attacks faction b.
The `HOSTILE dst, a, b` macro (`constants.asm`) reads it: one `lea`
(the row times 8, plus the column), an `add` of the table's address
and a `movzx`, with the flags set for a `jz`/`jnz` straight after.
Every place that used to ask "a different team?" now asks the table:

- `find_nearest_enemy`: only factions we fight are targets
- hold fire: someone we don't fight first in the line of fire
- friendly fire: a hit on someone we don't fight
- scoring: only kills of an enemy count
- a respawn spot's safety: distance to the nearest enemy
- the flow fields' sources (below)

**One flow field per faction.** `field_for` holds a field per
faction, each meaning "toward everyone this faction fights", and
`bfs_states` a lazy search for each (9.03). `build_fields` seeds
faction f's field with every living soldier that f is hostile to. With
two gangs at war, the Crips' field is exactly 9.03's "toward the
Bloods", so every value read is the same. A soldier follows its own
faction's field; `bfs_ensure` works out which faction a field
belongs to from where it lies in `field_for`.

**Still between two gangs:** the Big Homie ("the other gang" is gang
xor 1), the scoreboard, the win lines and `batch.sh`'s tally. They
change when a third gang (or the player's own scoreboard) needs them
to. `check_win` is general already: the last gang standing among any
number of gangs, reporting the highest-numbered gang when the last
ones all go out at once, as 9.03 reported the Bloods.

**Proof.**
- The end state is identical to 10.01's for 12 seeds headless and
  one windowed.
- A copy with `MAX_FACTIONS` = 4 (and a 4 × 4 table) plays
  identically: the indexing follows the constant.
- A copy with an all-zero table plays a war where nobody fights:
  score 0–0, a stalemate at 30,000 ticks. The only deaths are the
  police's and the dog's, which don't use the table yet.

About 4% slower (1.71 s a game): six empty fields get seeded each
tick.

## `03_fair_homes/` — fair homes, chosen at random

`02_factions/`, with the gangs' homes picked at random each game from
pairs of sites that batches showed are fair. 9.02's two fixed homes
gave the west one about 62% of the wins.

**Six sites.** `tools/gen_southside.py` now places `SITES` = 6
apartment complexes. The first two are 9.02's homes (SW 20th &
Monroe, and SW 9th & Jefferson). The rest are chosen one at a time: of
every street-and-avenue corner outside the park, airport and wrecker
lots whose two-block complex fits 50 soldiers and covers no real
building, the one farthest from those already picked. They came out
in the south-middle neighbourhood (2), by the loop road in the
north-east (3), the middle west (4) and the middle east (5). Houses
keep clear of all six.

**Candidate pairs.** Any two sites 1,500–3,600 px apart: nine of
them. For each, the generator closes the other four (their doorways
count as walls), checks the map is connected and both lobbies are in
the main part, and lays 80 pickups mirrored between the two lobbies.
A pair's pickups are seeded by its two sites, so they're the same
whichever other pairs are in the map.

**Scoring.** `tools/score_pairs.py` plays each pair headless
(`PAIR=n`, through `batch.sh`, 4 games at a time) and counts how often
the gang in the pair's first site wins. The side swap is still random,
so the gangs stay even; what's measured is the sites. 96 games each,
then 480 for any pair within 15% of even. Results, in
`maps/pair_scores.json`:

| Pair | Sites | First site won | Kept |
|---|---|---|---|
| 0–1 | 20th & Monroe, 9th & Jefferson (9.02's) | 48.8% of 480 | yes |
| 1–3 | 9th & Jefferson, the north-east | 53.9% of 960 | yes |
| 4–5 | middle west, middle east | 53.3% of 480 | yes |
| 2–3 | | 58.7% of 479 | no |
| 2–5 | | 42.3% of 480 | no |
| 0–2, 0–5, 1–2, 3–4 | | 71%, 85%, 82%, 29% of 96 | no |

The generator keeps the pairs within 4.5% of even over at least 480
games (about 2 standard deviations), and writes only those into the
map. Pair 0–1 is even now: with more sites and each pair's own
mirrored pickups, 9.02's 62% lean is gone.

**A lean that came back.** The final batches (144 games, random pairs)
had pair 1–3 at 30 of 42 for site 1, where scoring had found 50.4%.
A fresh sample of 480, decided on before looking further, gave 57.3%.
Its map was checked to be identical (the same pickups, the same
closed sites), so it's sampling: pooled, 517 of 960, 53.9%, a small
lean that the first 480 happened to hide. It stays in (within 4.5%),
and the scores file records the pooled numbers. 480 games only
resolves a pair to about ±4.5%; a stricter cut would need 2,400 each.
The gangs are even regardless: the coin flip gives each gang the
better site half the time.

**In the game.**
- `choose_sides` picks a pair (`PAIR=n` names one), then flips a coin
  for which gang gets which site, as before; `fwd_sign` comes from the
  two lobbies' positions.
- Spawns, respawns, pickups (`pair_pickups`), the lobby and door
  lights, and the starting camera (`camera_start`, halfway between the
  homes) all follow the pair.
- The four closed sites: `build_blockmap` marks their doorways as walls,
  so the pathfinding grid never goes in; `render_background` draws
  their walls and doorways grey, and a flat roof over the lobby.
- The win line says `; homes a-b; crips home s`: how the batches score
  a pair.

**Versioned map files.** The map's format changed, and `maps/` is
shared by every step, so the new map is `maps/southside2.inc` and
`maps/southside2_bg.bin`. 10.01 and 10.02 keep including 9.02's
`southside.inc`, unchanged, which `stage9/tools/gen_southside.py` can
still regenerate. From now on, a format change gets a new name.

**Checks.** 144 games with random pairs: no stalemates or crashes,
Crips 67 – Bloods 77, the pairs' first sites 80 of 144 (z 1.3). One
game of the dropped pair 2–3 didn't finish during scoring (1 in about
2,900); the kept pairs had none in 2,064 games.
