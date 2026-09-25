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
./build/05_on_foot            # the latest: you, on foot in the endless war
MODE=watch ./build/05_on_foot # last gang standing, no player (the default headless)
STAGGER=0 ./batch.sh 48       # headless, 4 games at a time
python3 tools/gen_southside.py                      # rebuild maps/southside2.* (15 s)
python3 tools/score_pairs.py build/05_on_foot       # re-score the home pairs (~40 min)
PAIR=0 ./build/05_on_foot                           # a given pair of homes
MODE=game STAGGER=0 ./batch.sh 48                   # 48 endless wars, headless
python3 tools/gen_sprites.py --write 05_on_foot/sprites.asm
HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/05_on_foot
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

## `04_endless/` — the endless war

`03_fair_homes/` with two modes, set with `MODE=` (`read_mode`):

- **watch**: last gang standing, exactly as before. The default when
  `HEADLESS`, so batches, replays and the fairness checks carry on
  unchanged. Byte for byte: the same seed ends the same as 10.03, for
  12 seeds headless and one windowed (`MODE=watch`).
- **game**: the endless war the game will be played in. The default
  in a window. Unlimited lives and respawns and no score limit,
  whatever `LIVES`, `RESPAWNS` and `SCORE_LIMIT` say; `check_win` never
  ends it. Closing the window prints how the war went ("Endless war
  on South Side! ..."), and `HEADLESS=1 MODE=game` plays one to
  `MAX_TICKS` (30,000, about 8 minutes of game time) and prints the
  same line, so wars can be batched (`batch.sh` counts them as
  "stuck": there's no winner).

**The Big Homie comes back.** He came out once per gang per game. In
an endless war, once a gang's Big Homie is dead it can bring him out
again, when it has fallen `BOSS_KILL_GAP` kills further behind than it
was when he died (`boss_base`, 0 in watch mode). The win line now
counts his outings (`boss_count`), which in watch mode is the same 0
or 1 as before.

**The guns piled up.** The first 48 wars were balanced (959 kills a
war to 962) but some were quiet: 1,306 kills in one, 2,567 in another.
Sampling the quietest every 1,000 ticks showed the kill rate falling
from about 50 to about 15 after 3,000 ticks, and armed soldiers from
15–20 a side to 4–6. At tick 10,000, 69 of the 80 guns were on the
ground: all in a heap in one street, between the two crowds, where
the dead had dropped them and nobody lived long enough to pick one
up. The respawned knife carriers queued behind the front for them.
Watch-mode games end at about 4,700 ticks, so it had never shown.

So in game mode a gun that has lain on the ground `PICKUP_STALE`
ticks (900, 15 s) is "picked up by someone else": `refresh_pickups`
moves it to one of the pair's pickup spots, at random. It's the same
gun, so every weapon is still in exactly one place. (`pickup_age`
counts; `drop_weapon` resets it.) The same war afterwards: 70–100
kills per 1,000 ticks from start to end, 10–30 guns a side, and real
swings of momentum.

**48 wars** (random pairs): 1,877–2,836 kills each, Crips 1,107 and
Bloods 1,086 a war on average, the Crips ahead in 30 of 48 (z 1.7),
no crashes. The Big Homie came out 0.8 and 1.4 times a war, up to 4.

## `05_on_foot/` — you, on foot

`04_endless/`, and you're in it: in game mode, in a window, a courier
on foot in the middle of the war. Everyone is hostile.

| Control | What it does |
|---|---|
| W A S D | walk (3 px a tick, the soldiers' 2), sliding along walls; the camera follows you |
| right-click | lock onto the enemy nearest the cursor (within 120 px); yellow brackets mark him. Right-click nobody to unlock; the lock breaks when he dies or gets 450 px away |
| left button | fire: at the lock, when he's in range and in sight (otherwise it holds fire: no ammo wasted); with no lock, at the enemy nearest the cursor (within 40 px); with nobody there, a miss with a tracer toward the cursor. Whoever is first in the line of fire takes the shot |
| Q | swap pistol and shotgun (an empty gun swaps itself for a loaded one) |
| walk over a gun | take its ammo: +20 pistol rounds or +8 shotgun shells. The gun turns up again at one of the pair's pickup spots, so the gangs' supply doesn't shrink |
| wheel | zoom; game mode starts at 2× (at 1× you're 16 px on a 1,280 px screen) |

**Tougher than a gang member:** 150 health against their 100, and it
comes back (a point every 20 ticks once you've gone 4 seconds
unhurt); an 85% pistol hit chance against their 60%, 34 damage against
their 20 (three hits kill), and faster fire (14 ticks against 20).
The shotgun: 95% and 60 damage inside 80 px, 65% and 30 out to 180.
60 pistol rounds a life, no shells. Dying shows YOU DIED on the
scoreboard, and 3 seconds later you're back somewhere safe: a walkable
spot outside every site, at least 700 px from both homes, 300 px from
anyone alive and 100 px in from the edges. The scoreboard's middle
shows your health, gun, ammo and kills; the summary line (when the
window closes) adds "; you: kills K, deaths D".

**The gangs only come after you up close.** A gang member considers
you a target only within 450 px, about three blocks
(`find_nearest_enemy`); beyond that it gets back to the rival gang.
And you're not a source of the gangs' flow fields, so gangs across
the map don't converge on you. Stray bullets still hit you.

(That's the second version. The first, from the plan, had 100 health,
the soldiers' own odds, no pickups, a 28 px aiming radius and every
gang member on the map after you. The first play test: "aiming feels
hard", "you feel incredibly underpowered", "can't pick up the guns",
"the gangsters should ignore you after so many blocks".)

**You're a soldier.** The player is the slot after the two Big Homies
(`PLAYER`), in a faction of its own (`FACTION_PLAYER` = 2), which the
hostility table sets at war with both gangs, both ways. So the rest of
the game handles you with the code it already had: the gangs pick you
as a target, their shots hit you when you're first in the line of
fire, you collide like a soldier, you're drawn and shadowed like one
(a courier's yellow shirt and a brown cap), the police arrest you and
the loose dog bites you. What's different, in `player.asm`:

- `update_soldiers` skips your slot: `update_player` moves you, from
  the keyboard and the mouse, once a tick before the soldiers.
- Your `lives_left` is 0, so the generic respawn never books you, and
  neither kill path drops your pistol: `update_player` brings you back.
- Your shots go through `event_damage` (spawn protection counts; a
  kill drops the victim's gun and books its respawn, as usual) and a
  kill of an enemy scores for your faction.
- Your own RNG, `player_rng`, seeded from the game's seed: nothing you
  do moves the soldiers' random numbers.
- A missed shot's tracer aims at a point: `spawn_effect` takes target
  −1 to mean `fx_dst`, as shooter −1 already meant `fx_src`.

**Only in game mode, in a window** (`player_on`). Watch mode and
`HEADLESS` have no player: the end state is identical to 10.04's for
12 seeds headless and one windowed.

**Tested with a bot.** The dummy video driver has no keyboard or
mouse, so a gdb script plays: every tick it aims at the nearest enemy
and walks toward it (writing SDL's keyboard state array) until it's
within 190 px, then holds the button, right-clicking every 2 seconds
to lock on. It has no pathfinding, so when a building stops it for a
second it hops to a clear spot near its target (checked with the
game's own `is_box_blocked`). Over 4,859 ticks: 30 kills, 7 deaths (the
first version's player: 2 kills, 6 deaths in 4,000). A second script
stood the player on a pistol and a shotgun: 60 → 80 rounds, 0 → 8
shells, and both guns turned up elsewhere.

**A bug the bot found: `imul r8d, edx, edx`.** The three-operand
`imul` takes an immediate as its third operand, not a register, but
NASM assembled it anyway, into bytes the CPU refuses: SIGILL, the
moment `enemy_near` first ran (the first right-click). The bot saw it
as a gdb MemoryError (it was reading a dead process) until gdb was
told to stop on SIGILL. Now it's `mov r8d, edx` then `imul r8d, edx`.
