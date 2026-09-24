# Stage 7 — Modifying the sim

The roadmap ended at 6c. This stage builds on `stage6c/01_scale_up.asm`
with changes to how the battle plays.

## Build

```bash
make
make clean
./batch.sh 48        # 48 headless games of the newest binary in build/
```

`batch.sh` is the stage6c harness. The only change is that it now
defaults to the highest-numbered binary in `build/`.
Since 7.07 it also runs at most `JOBS` games at once (default 4)
at low priority. Launching a whole batch at once, or two side by side,
swamped the desktop.

## `01_collision.asm` — soldiers can't overlap

At 50v50, crowds at the gap collapsed into a few squares that were
really a dozen soldiers stacked on the same pixels. Now no two living
soldiers can overlap.

**`is_spot_blocked(self, x, y)`** is the new question every move asks:
could soldier `self` stand at `(x, y)`? No if `is_box_blocked` says so
(wall or screen edge). Also no if the box would overlap any *other*
living soldier. Two same-size boxes overlap exactly when both |dx| and
|dy| between their corners are under `SOLDIER_SIZE`. Dead soldiers are
skipped, so bodies never block anyone.

**`line_blocked` is unchanged and still walls-only.** It answers two
questions, "can I walk straight there?" and "can I see to shoot?", and
soldiers shouldn't affect either one. A teammate in the line would
block every shot, and the target itself sits at the end of the line.

**Movement (`.do_move`)**, in order:

1. If walls block the straight line to the goal, side-step (as before).
2. Otherwise take the usual step (up to `MOVE_SPEED` on each axis) if
   nobody is standing there.
3. If a soldier is, try the step along the **main axis only**
   (whichever of |dx|, |dy| is larger).
4. If that's blocked too, side-step: the same sticky perpendicular
   step that routes around walls, now checking soldiers as well.

Step 3 deliberately never tries the *minor* axis alone. Picture a
soldier heading right with a teammate directly in front. The side-step
moves it up 2px to get around. On the next tick a minor-axis slide
(dy toward the goal) would move it straight back down behind the
teammate, and it would repeat that forever. That's stage6b's bug #5,
the permanent 2-tick oscillation, rebuilt from different parts. Going
main axis → sticky side-step means a soldier commits to one way round
and keeps going until it's past.

**Knife range still works** with bodies in the way. Two boxes can get
as close as 16px corner to corner (side by side), inside
`CONTACT_RANGE` = 20. A pure diagonal approach can't close past 16,16
(22.6px), so the attacker has to shift sideways onto a line with its
target first. The main-axis and side-step fallbacks do that, but I
haven't traced it tick by tick. The evidence it works is that knife
fights resolve and no game has stalled (see below). It's the third
exercise in the file.

### Verification

- **No overlaps, ever:** a throwaway build ran `is_spot_blocked` on
  every living soldier after every tick and exited with code 99 on any
  hit. It ran 24 full games clean. The check covers soldier–soldier
  overlaps and also soldiers inside walls or off-screen.
- **Fairness:** two 48-game batches came out 19–29 and 26–22, **45–51
  combined**. 0 stuck, 0 crashed.
- **Game length roughly doubled**, median ~21s (range 17–28s) against
  6c's ~9s. Crowds at the gap now queue instead of passing through
  each other, so fewer soldiers reach the fight at once.

## `02_random_spawn.asm` — random, mirrored spawn points

Every game gets a new layout. Team 0's 50 soldiers are placed at random
in a rectangle on the left (corners in x 16–184, y 16–568). Team 1's
soldier k is the exact mirror of team 0's soldier k
(`x' = SCREEN_W - SOLDIER_SIZE - x`, same y). Each team stays on its own
side, and neither side gets a better half.

**Spacing.** A random spot is rejected, and another one drawn, if it's
within `SPAWN_GAP` = 24px of an already-placed team 0 soldier on both
axes. 16 would only prevent overlap (which the stage 7 collision code
needs as a starting condition). The extra 8 keeps soldiers from starting
glued together. Only team 0 needs checking: the mirror of a valid team 0
layout is a valid team 1 layout, and the two halves can't touch.

**The retry loop has no attempt cap, and doesn't need one at these
numbers.** A Python simulation of the same algorithm over 2000 layouts
averaged ~111 random draws for all 50 soldiers. The unluckiest single
soldier needed 32. It isn't unlimited headroom: at this spacing the
rectangle jams at roughly 100 per team, and past that the loop would spin
forever. (My first comment in the code said 50 blocked squares
"cover less than half" the rectangle. They don't: 50 × 47² > 169 × 537.
They overlap each other heavily, which is why it works anyway. The
simulation is the real evidence.)

**Pickups** keep stage6c's 8-entry table (positions and the pistol/shotgun
checkerboard), but each one is moved by a random offset of up to
`PICKUP_JITTER` = 30px on each axis, then mirrored. That keeps them
between the spawn area and the wall (x 200–350). Weapons dropped when
their holder dies still land where the holder fell.

**`srand` moved ahead of the spawns in `main`.** Until now spawning
never called `rand`, so it didn't matter that `srand` ran afterward.
With random spawns, that order would give every game the same layout
(from rand's default seed), whatever the clock said.

A small `rand_range(n)` helper (`rand() % n`) and an `INIT_SOLDIER`
macro (so both teams' soldiers are set up by the same lines) are the
only other new code. Nothing in `update_soldiers` changed.

### Verification

- **Layouts:** two launches dumped via gdb. Both were exact mirrors
  (soldiers and pickups, including pickup type), with minimum spacing
  exactly 24 and different positions each run. A rendered first frame
  showed two scattered, mirrored armies.
- **Fairness:** two 48-game batches came out 26–22 and 27–21, **53–43
  combined**. 0 stuck, 0 crashed.
- **No overlaps:** the same per-tick overlap check from `01`, rebuilt on
  this file, ran 24 games clean.
- Game length 15–32s (median ~22s), about the same as `01`.

## `03_xorshift.asm` — our own RNG instead of libc's

libc's `rand()`, `srand()` and `time()` are gone. The binary no longer
imports any of them (`nm` confirms it). In their place:

- **`rng_next`** is Marsaglia's xorshift64: `x ^= x << 13; x ^= x >> 7;
  x ^= x << 17`. Three shift-and-xor steps, no multiply or divide, and
  a period of 2^64 − 1. It returns the **high** 32 bits, because a
  plain xorshift's low bits are its weakest, and `update_soldiers` uses
  exactly one bit of every draw (`and eax, 1`) to pick the per-tick
  processing direction. That's the fairness fix from stage6a whose
  accidental removal was stage6b's bug #2, so it gets the best bit
  available.
- **`rng_seed`** reads the CPU's timestamp counter (`rdtsc`) and runs it
  through splitmix64's finalizer before storing it. xorshift is linear,
  so two raw seeds a few cycles apart would produce early outputs that
  differ in only a few bits; the mix spreads every input bit across the
  whole state. It also guards the one bad state (0, which maps to 0
  forever).

Every call site just changes `call rand` to `call rng_next`. The callers
only ever did `and eax, 1` or an unsigned `div`, so a full 32-bit
result, instead of `rand()`'s 0..RAND_MAX, needs no other changes.
`rng_next` clobbers only `rax` and `rdx`, less than `rand()` was
allowed to.

**Side effect: `batch.sh` doesn't need to stagger anymore.** `rdtsc`
changes billions of times a second, so games launched together get
different seeds. `STAGGER=0 ./batch.sh 48` launches everything at once.
Staggering is still the default, because `01` and `02` still seed from
`time()`.

### Verification

- **Matches a reference implementation:** in gdb, `rng_state` set to
  `0x0123456789abcdef`, then three calls to `rng_next`, gave
  `0x3f2800d6, 0x606f949a, 0xc69bba40` and final state
  `0xc69bba40dddccad6`. A Python xorshift64 gives exactly the same.
  `rng_seed` was checked the same way, by overwriting `rdtsc`'s output
  in gdb with a fixed value: the stored state matched Python's
  splitmix64 bit for bit.
- **Distribution** (same algorithm in Python, 1M draws): bit 0 set
  50.01% of the time, and every `% 100` hit-roll bucket between 9,752
  and 10,266 against an expected 10,000, normal spread for 100 buckets.
- **Distinct games with simultaneous launches:** 48 games started at
  once had durations from 25s to 39.5s, with 40 distinct values among
  46 readable result lines. Under the old `time()` seeding they would
  all have been the same game.
- **Fairness:** two simultaneous 48-game batches, 25–23 and 24–24,
  **49–47 combined**. 0 stuck, 0 crashed. (Wall-clock game lengths are
  longer in these batches, median ~29s, because 48 games shared 16 CPU
  threads at once.)

## `04_attack_fx.asm` — attack animations

Until now an attack was invisible. The only sign of combat was a
soldier disappearing when it died. Now:

- **Knife:** a 2px near-white blade slides from the attacker toward
  the target and pulls back (`KNIFE_LIFE` = 10 frames, fully extended
  at frame 5).
- **Pistol:** a yellow tracer flies from shooter to target in
  `BULLET_TRAVEL` = 8 frames.
- **Shotgun:** three orange pellet tracers in a fan, `PELLET_SPREAD`
  = 8px apart at the target.
- **Hit:** when the tracer or blade arrives, the target flashes white
  for 6 frames, and each tracer end gets a small spark that shrinks.
- **Miss:** the tracer aims `MISS_OFFSET` spreads to one side and 25%
  past the target, so you can see it fly by.

**It's drawing only.** `update_soldiers` still makes the same hit roll
at the same moment. It now also passes the result to `spawn_effect`,
which writes an entry in a 128-slot ring buffer. `draw_effects` runs
once per rendered frame, draws each entry, then ages it one frame.
Nothing in the effect code calls `rng_next` or writes to a soldier.
The miss side alternates with the ring-buffer slot number instead of
coming from a random draw, because one extra random draw would change
every game from then on.

**Dead soldiers stay on screen briefly.** Damage still lands on the
tick of the attack, so a killing bullet would reach an empty spot 8
frames later. `spawn_effect` sets `death_linger` for the target so
the body stays drawn through the tracer's arrival and the flash. Only
the renderer reads it. Collision, targeting and the win check all
still check `health`, so a lingering body can't block anyone or be
shot again.

**Two small pieces of plumbing:**
- `draw_line`, Stage 3's Bresenham, copied unchanged. It's the third
  use of the same line walk, after drawing in Stage 3 and
  `line_blocked` in 6b.
- `fill_rect` now clips at the left and top edges, not only the right
  and bottom. Nothing had drawn at a negative coordinate before. A
  spark at the end of an outer shotgun pellet can, and a negative `y`
  would have written before the start of `back_buffer`.

The perpendicular for the pellet fan is `(-dy, dx) * SPREAD /
max(|dx|, |dy|)`. Dividing by the larger axis instead of the true
length skips a square root. It comes out 1x to 1.41x too long
depending on the angle, which doesn't matter for a spread.

### Verification

- **Same game as 03, byte for byte.** In gdb, `rng_state` set to the
  same fixed value in both `03` and `04`, then run until `game_over`
  was written. For three seeds (`0x0123456789abcdef`,
  `0xdeadbeefcafef00d`, `0x5eed5eed12345678`), the whole `soldiers`
  and `pickups` arrays and the final `rng_state` were identical. So
  the effects don't use the RNG or change the fight, and fairness
  carries over from 03 without a new batch run.
- **Batch:** `STAGGER=0 ./batch.sh 48` gave 27–21, 0 stuck, 0 crashed.
- **Looked at it:** 10 consecutive frames dumped from `back_buffer`
  mid-fight showed tracers moving along their paths, the shotgun fan,
  sparks, white flashes on hit targets, and knife thrusts.
- One bug caught on review before running: `spawn_effect` read the
  target index from `edx` after `cdq`/`idiv` had overwritten it.

## `05_friendly_fire.asm` — shots hit whoever is in the way

Before, a pistol or shotgun shot could only hit the soldier it was
aimed at. It passed through anyone standing in between, teammates
included. Now **`first_in_line(shooter, target)`** walks the line of
fire from the shooter's centre to the target's centre. That's the
fourth use of the Stage 3 Bresenham walk. At each point it checks
every living soldier's box, skipping the shooter, and the first box
it enters takes the shot, from either team. The hit roll, damage and
weapon drop are unchanged; they just apply to that soldier. The
attack animation follows the shot too, so the tracer ends at whoever
actually got hit.

The box test uses an unsigned-compare trick: `0 <= x - box.x < SIZE`
is a single `cmp eax, SOLDIER_SIZE` / `jae`. A negative difference
compared as unsigned is huge, so it fails the same test.

The knife is unaffected. It's contact range, so the target is the
only soldier it can reach.

Soldiers **don't** check for teammates before firing. That's
deliberate for now, to measure how much friendly fire actually
happens (see below).

The win line now reports friendly fire, still in a single `write()`
so `batch.sh`'s "stop at the first output" check can't catch half a
line:

```
Team 0 (blue) wins! (friendly fire: 128 hits, 18 kills)
```

The number printing (`append_uint`) divides by 10 and writes the
digits backwards into the System V red zone, the 128 bytes below
`rsp` that a leaf function may use without adjusting the stack.

### Verification

- **Fairness:** three 48-game batches, 22–26, 30–18 and 20–28,
  **72–72 combined**. 0 stuck, 0 crashed.
- **How much friendly fire:** over 47 games with readable result
  lines, an average of **128 friendly hits and 15 friendly kills per
  game**, with a maximum of 152 hits and 22 kills. So roughly one death
  in seven now comes from a soldier's own team. Soldiers in back
  shoot through the ones in front, mostly around the gap in the wall.
  06 adds holding fire.
- Later fixed (found while verifying 06): `first_in_line` now works
  in half-pixel units so it's exactly mirror-symmetric. See 06. After
  the fix, 05 batched 66–78 over 144 games, about the same friendly
  fire (129 hits, 15.5 kills per game), 0 stuck, 0 crashed.

## `06_hold_fire.asm` — don't shoot through your own team

Once a pistol or shotgun's cooldown is up, the soldier calls
`first_in_line` *before* firing. If a teammate would take the shot,
it holds fire and jumps to `.side_step`, the same sticky
perpendicular step used to get around walls. `US_GOAL` is the target
here, so the step goes across the line of fire, and the soldier
checks again on the next tick. An enemy in the way is still fine:
that enemy takes the shot. The win line adds a count:

```
Team 1 (red) wins! (friendly fire: 0 hits, 0 kills; held fire 3036 times)
```

### A fairness bug: soldier "centres" weren't mirror images

The first ten 48-game batches came out **221–259**. Red was ahead in
7 of the 10, and a split that far from even happens by chance only
about 1 time in 12. Suspicious enough, given the project's history,
to look for a cause.

`first_in_line` walked from `x + 8` to `x + 8`. A 16px box covers
pixels `x .. x+15` and has no centre pixel: `x+8` is 8 pixels from
the left edge but 7 from the right. The mirror image of pixel `x+8`
is `W-9-x`, but the mirrored soldier (at `W-16-x`) puts its "centre"
at `W-8-x`. So every line of fire for team 1 was 1px off from the
mirror of team 0's, while the boxes it tests against mirror exactly.
05 asked the question once per shot. 06 asks it about 3,300 times a
game and acts on the answer by moving, which gives a 1px asymmetry
far more chances to add up.

**Fix:** walk the line in half-pixel units (double every coordinate).
The centre becomes exactly `2x + 15` and a box exactly `[2x, 2x+30]`.
Both mirror exactly, and neighbouring boxes (16px apart = 32 units)
can't share a point. The Bresenham walk itself needed nothing: its
step decisions depend only on |dx| and |dy|, so a mirrored line walks
the mirrored path. The same fix went into 05.

After the fix: **142–146** over six batches (288 games). The first
288 games before the fix were 131–157. The fix is justified by the
geometry either way. Before it, the lean was suggestive but never
conclusive (about 1 in 12).

### Verification

- **Fairness (after the fix):** 142–146 over 288 games. 0 stuck, 0
  crashed.
- **Friendly fire:** 0 hits, 0 kills in all 282 readable result lines.
- **Cost:** soldiers hold fire about 3,200 times a game. Median game
  length under a full 48-game batch rose from 28.6s (05) to 34.6s, as
  soldiers spend ticks side-stepping for a clear shot.

## `07_arenas.asm` — more arenas

The single split wall from stage6c is now one of five layouts. Each
game picks one at random, or `ARENA=n` picks one (handy for batching
a single arena):

```bash
./build/07_arenas               # random arena
ARENA=2 ./build/07_arenas       # Crossroads
ARENA=2 STAGGER=0 ./batch.sh 48
```

| n | Arena | Layout |
|---|---|---|
| 0 | Divide | the original: one centre wall with a gap |
| 1 | Pillars | three staggered columns of 36px pillars |
| 2 | Crossroads | four 70×150 blocks: a + of corridors, lanes top and bottom |
| 3 | Trenches | short staggered wall segments |
| 4 | Outposts | a post in front of each spawn, two short bars, a centre bunker |

The window title and the win line both name the arena:

```
Team 0 (blue) wins on Pillars! (friendly fire: 0 hits, 0 kills; held fire 1954 times)
```

**Walls are data, mirrored in code.** Each arena lists only its
left-half walls (`ARENA` / `WALL` / `END_ARENA` macros), and
`spawn_obstacles` adds each wall's mirror, `x' = SCREEN_W - x - w`,
unless the wall is its own mirror (it straddles the centre line).
So every arena is fair by construction, like spawns and pickups. The
macros also check each layout at build time: a wall that crosses the
centre without being its own mirror, a wall in the spawn strip
(x < 200), or more than `MAX_OBSTACLES` (16) walls after mirroring
is an assembler error, not a subtly broken game.

**Pickups slide out of walls.** The pickup table is unchanged, and
several arenas put walls on top of its spots. After the jitter,
`spawn_pickups` checks whether a soldier could stand on the pickup
(`is_box_blocked`). If not, it slides it toward its own team's side
(−x) one pixel at a time until it's clear. The mirrored pickup copies
the final x, so it slides +x, and the layout stays symmetric. Walls
never reach the spawn strip, so the slide always stops. It uses no
random numbers, so it doesn't change anything else about the game.

### What the movement AI can't handle: mazes

The first set had a fourth arena, **Zigzag**: three long walls, open
at alternate ends, so crossing meant going down, then up, then down.
It stalemated. A frame from a stuck game showed both teams milling
behind their own walls. Soldiers only know "walk straight at the
target, and side-step perpendicular when a wall is in the way". A
route that first leads *away* from the enemy is invisible to that
rule.

Opening the walls at both ends mostly fixed it, but 2 of 24 games
still ran past 240 seconds (normal games take 18–57s). Tracing one
game every 20 ticks from tick 6,000 showed it wasn't a freeze. The
last few soldiers were wandering: one slid the full height of the
left screen edge, reversed, and slid back, because the sticky
side-step keeps going the way it last went until something blocks
it. Long walls in series turn that into endgames of thousands of
ticks.

The same thing, less often, stalled the first Crossroads (90×200
blocks, 1 of 16) and the first Outposts (120px horizontal bars, 2 of
144: a horizontal wall is the long way round for a soldier heading
up or down). Zigzag became **Trenches** (short segments), Crossroads
got smaller blocks with 75px lanes, and Outposts' bars went to 80px. The rule of thumb for
this AI: **keep every wall short enough that a side-step clears it
quickly, and don't put long walls in series.** Real pathfinding (a
flow field on a grid) is what it would take to bring back mazes.

### Verification

- **Fairness:** 3 batches of 48 per arena, 720 games in all:

  | Arena | Blue–red | Stuck |
  |---|---|---|
  | Divide | 69–75 | 0 |
  | Pillars | 67–77 | 0 |
  | Crossroads | 79–65 | 0 |
  | Trenches | 77–67 | 0 |
  | Outposts (80px bars) | 79–65 | 0 |
  | **Total** | **371–349** | **0** |

  371–349 is well within chance (under 1 standard deviation from
  even). 0 crashed.
- **Recheck** after red won six watched games in a row on the new
  maps (a 1-in-64 streak): 2 more batches of 48 each on Pillars,
  Crossroads and Trenches came out **153–134 for blue**, so the streak
  was luck. One Pillars game stalled past 180s, the first in about
  210 Pillars games. The slow-endgame wandering described above
  still shows up now and then, even on open maps. Pathfinding should
  fix it.
- **Friendly fire:** still 0 hits, 0 kills in every readable result
  line.
- **Game length:** the longest of the 720 games took 73s, well short
  of the 180s timeout.

## `08_headless.asm` — headless mode

`HEADLESS=1` runs a game with no window: `main` never calls SDL, and
runs `update_soldiers` and `check_win` back to back with no drawing
and no 60 fps frame cap. It prints the win line and exits. The win
line now ends with the game's length in ticks (one tick = one frame
in a window):

```
Team 0 (blue) wins on Pillars! (friendly fire: 0 hits, 0 kills; held fire 1673 times; 952 ticks)
```

A headless game that reaches `MAX_TICKS` (30,000, over 8 minutes at
60 fps) stops with a `Stalemate on <arena>! (...)` line instead.
`batch.sh` counts that as stuck, so it no longer has to guess from
wall-clock time. The windowed game has no tick limit.

**Why:** batches used to run every game at 60 fps on SDL's dummy
driver, still drawing and copying all 800×600 pixels every frame.
Running a whole batch at once, or two side by side, swamped the
desktop. A headless game takes about **0.16s** of one core instead of
20–50s. A 48-game batch (4 at a time) takes **2.7s** instead of
about 6 minutes.

**Same game:** rendering was always a pure function of the game
state (04 proved the effects don't change the fight). Checked
anyway, with the fixed-seed gdb recipe stopping at `print_result`:
for three seeds on Divide, Crossroads and Outposts, headless and
windowed runs ended with byte-identical `soldiers`, `pickups`,
`rng_state` and `ticks`.

**`batch.sh` changes:**
- It sets `HEADLESS=1` for every game. Binaries before 08 ignore it
  and run as before.
- It runs at most `JOBS` games at once (default 4, under `nice`).
- **Bug fix:** it copied each game's line to stderr with
  `tee /dev/stderr`. When stderr is a file, `tee` reopens it and
  truncates it, so appending several batches to one log
  (`2>>log`) kept only the last batch. It now writes to stderr
  directly.

### What the extra speed showed: rare stalemates

480 games per arena (10 batches of 48, 2,400 games, about 2 minutes):

| Arena | Blue–red | Stalemates | Median ticks | 99th pct |
|---|---|---|---|---|
| Divide | 241–239 | 0 | 1,483 | 2,077 |
| Pillars | 243–232 | 5 | 991 | 4,853 |
| Crossroads | 254–222 | 4 | 1,042 | 4,703 |
| Trenches | 236–244 | 0 | 1,096 | 1,724 |
| Outposts | 251–225 | 4 | 934 | 9,732 |
| **Total** | **1,225–1,162** | **13** | | |

Fair (1,225–1,162 is about 1.3 standard deviations from even), 0
crashed. But 13 games in 2,400 (0.5%) on Pillars, Crossroads and
Outposts ran all 30,000 ticks. 07's 48-game batches with a 180s
(about 10,800-tick) timeout saw only a couple of these and reported
the rest as clean. This is the slow endgame wandering described in
07. Pathfinding is the fix, and headless batches are now fast
enough to measure it properly.

## `09_pathfinding.asm` — flow-field pathfinding

Until now a soldier whose straight line to its goal hit a wall
side-stepped perpendicular and hoped. 07 and 08 showed where that
fails: mazes like Zigzag, and about 0.5% of games on open maps where
the last few soldiers wander along walls forever. Now a blocked
soldier follows a **flow field**.

**The grid.** Cells are 9px square, over soldier *corner* positions.
Once per game, `build_walkable` marks each cell where a soldier could
stand *anywhere* inside it without touching a wall: one rectangle
test, the cell's corner range grown by `SOLDIER_SIZE`. Being that
strict means a soldier moving between walkable cells can't clip a
wall whatever pixel it's on.

**The fields.** Every tick, before anyone moves, `build_fields` runs
three breadth-first searches over the walkable cells:
`field_to0` / `field_to1` (distance to the nearest living soldier of
each team) and `field_pk` (distance to the nearest pickup). When
`line_blocked` says a soldier can't walk straight to its goal,
`flow_waypoint` picks the closest of the 8 cells around its own
(diagonals only if both cells they cut past are walkable), and the
soldier walks to that cell's centre using the normal step code. The
old sticky side-step is now just the fallback for when no neighbour
is closer.

**Mirror fairness**, the thing every earlier stage tripped over:

- **Cells are 9px, not 8.** Corners run x = 0..784, which is 785
  positions, an odd number. With cell k covering `[9k-8, 9k]`, cell k
  mirrors exactly onto cell 88−k because 784 + 8 is a multiple of 9.
  An even cell width can't have a cell centred on the mirror line, so
  no even width works. An assembler check enforces it.
- **BFS distances don't depend on visiting order,** only on the grid,
  and the grid is symmetric (checked in Python for every arena).
- **Ties between equally close neighbours go "forward"** (toward the
  enemy) first, like the side-step since 6c.

**Checked against Python.** A gdb dump right after `build_fields`, at
two different ticks: the walkable grid and all three fields matched
a Python BFS cell for cell.

**Cost:** a headless game went from ~0.16s to ~0.18s. Three BFS
passes over 5,874 cells per tick is cheap next to `first_in_line`.

### A 1-in-250 lean that wasn't real

The first 480-game run had Crossroads at **271–208** for blue, about
2.9 standard deviations and roughly a 1-in-250 chance if fair.
Crossroads had leaned blue before, too (79–65 in 07, 254–222 in 08).
A code review of the new code found nothing asymmetric. A side-swap
test through gdb came out 243–237, but it wasn't a clean test: the
forward tie-break belongs to the team, not the side, so swapping
sides broke the mirror. It proved nothing either way. A fresh
sample, fixed in advance at 2,400 games, settled it: **1,195–1,198**.
With 5 arenas tested, one 1-in-250 result isn't that surprising.

### Replaying stalemates: `SEED=n`

Pathfinding cut stalemates from 13 to 4 in 2,400 games, but hunting
the rest with fixed seeds in gdb found none in 800 tries. So the game
now takes `SEED=n` (decimal or `0x` hex, via `strtoull`) to replay a
game exactly, and a stalemate line ends with the seed it started
from:

```
Stalemate on Crossroads! (friendly fire: 0 hits, 0 kills; held fire 5327 times; 30000 ticks; seed 0xe05f207784eec9a0)
```

`append_hex64` prints it: rotate the next nibble into the bottom 4
bits, look it up in `"0123456789abcdef"`.

### Bug: a pickup nobody could reach

Replaying the first two stalemate seeds showed the same deadlock, on
both teams at once. A soldier holding a shotgun stood exactly on a
pistol pickup. Soldiers with a gun never pick anything up, and his
knife-wielding teammates, all closer to that pickup than to any enemy,
packed in around him trying to reach it. `PICKUP_RADIUS` was 15px,
less than one body width (16px), so nobody else could ever get close
enough. They shuffled 2px back and forth for 29,000 ticks.

This could have happened in any version since pickups existed; it
was just rarer than the wall wandering. **Fix:**
`PICKUP_RADIUS = SOLDIER_SIZE + 8` (24), so anyone touching the soldier
on the spot can grab it.

### Zigzag is back

07's first Zigzag (three long walls open at alternate ends, the one
that stalemated almost every game) is arena 5, unchanged.

### Verification (after the radius fix)

| Arena | Games | Blue–red | Stalemates | Median ticks | Max ticks |
|---|---|---|---|---|---|
| Divide | 480 | 246–234 | 0 | 1,000 | 1,657 |
| Pillars | 480 | 241–239 | 0 | 712 | 1,526 |
| Crossroads | 480 | 234–246 | 0 | 833 | 1,468 |
| Trenches | 480 | 245–235 | 0 | 836 | 1,451 |
| Outposts | 480 | 249–231 | 0 | 717 | 1,334 |
| Zigzag | 1,440 | 735–704 | 1 | 2,100 | 30,000 |
| **Total** | **3,840** | **1,950–1,889** | **1** | | |

About 1 standard deviation from even. 0 crashed, 0 friendly fire.
Compared with 08, the five original arenas went from 13 stalemates in
2,400 to 0. The longest game dropped from 30,000 ticks (and a 99th
percentile as high as 9,732) to 1,657, and median games are 20–35%
shorter.

**Known limit: traffic jams.** The one Zigzag stalemate replayed as a
jam at the end of the first wall. Every soldier got a sensible
waypoint, but two teammates wanted to cross each other's paths 15px
apart, each blocking the other's step, and the knife soldiers behind
them were funnelled into the same corner. The flow field routes
around walls, not around other soldiers. It's 1 game in 1,440 on the
hardest map, so it stays documented for now.
