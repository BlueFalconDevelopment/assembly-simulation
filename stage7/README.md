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
