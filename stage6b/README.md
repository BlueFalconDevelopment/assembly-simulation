# Stage 6b — Add obstacles

Rectangular cover on the field, movement that routes around it
without real pathfinding, and (in `02`, next) line-of-sight for
ranged weapons.

## Build

```bash
make
make clean
```

## `01_obstacles.asm`

A `struc Obstacle` (x, y, w, h) — same pattern as `Soldier`/`Pickup`
— placed as one wall, split into two segments with a gap in the
middle, roughly bisecting the field. Two new functions:

- **`is_box_blocked(x, y)`** — does the soldier's `SOLDIER_SIZE` x
  `SOLDIER_SIZE` body, anchored at `(x, y)`, overlap any obstacle or
  the screen edge? A proper AABB-vs-AABB overlap test.
- **`line_blocked(x0, y0, x1, y1)`** — stage3's `draw_line`
  Bresenham walk, `set_pixel` swapped for a per-step `is_box_blocked`
  check, returning the instant any step is blocked. This is the
  exact reuse the roadmap flagged three stages ago: the same
  line-stepping idea, now answering "is anything in the way" instead
  of "color this pixel."

The movement rule: before stepping toward a goal, `do_move` checks
whether the straight line to it is blocked. If clear, take the
existing clamped step. If blocked, try stepping perpendicular to the
goal direction — one side, then the other — and take whichever is
clear. No A*, just "try to slide around it."

## Three real bugs, found only by testing hard

This file went through more debugging than any other in the project
so far. All three are worth reading even if you never hit them
yourself — each is a different *class* of bug that "looks fine" in a
single test run.

**1. A crash from an unclamped side-step.** The perpendicular
side-step applies a raw `add`/`sub` to `Soldier.x`/`y` with no bound
of its own — unlike the normal clamped-toward-goal move, which never
wanders off-screen because goals are always on-screen. With a wall
segment sitting right at the top edge (`y=0`), a soldier repeatedly
routed "up" around it walked into negative `y`, and `fill_rect`'s
`row * pitch + col * 4` write only clips the *far* edge, never checks
for a negative one — corrupting the write address into unmapped
memory. **Fix:** `is_box_blocked` also treats anything off the
`SCREEN_W` x `SCREEN_H` field as blocked, since every side-step
decision already funnels through it.

**2. A regression in the fair-turn-order fix.** `stage6a/04_weapons.asm`
was rewritten "fresh" at one point and silently dropped the `call
rand` / `and eax,1` / `mov [pass_reverse], eax` line that actually
*randomizes* per-tick processing direction (03_combat.asm's fix for
the iteration-order bias documented in stage6a's README). The
`pass_reverse` variable was still declared and still *read* — just
never *written* — so it stayed permanently 0, quietly reintroducing
team 0's original first-strike advantage. It had already been
committed and pushed. **Caught by:** running the game repeatedly and
tracking the win distribution, exactly the discipline that caught the
original bug in stage6a — a single test run (or even a 4-run batch)
wasn't enough to notice a mere 60-70% skew, only a much larger sample
made it unmistakable. Fixed in both `stage6a/04_weapons.asm` and this
file.

**3. A symmetry mismatch in the pickup layout, amplified by the
wall.** Even with `pass_reverse` fixed, `stage6b/01_obstacles.asm`
was winning 24 of 24 test games for team 0. The cause: soldiers spawn
with LEFT-RIGHT MIRROR symmetry (both teams use the identical row
y-values), but the four weapon pickups were placed with 180-DEGREE
ROTATIONAL symmetry instead — pickup 0 (300,200,pistol) and pickup 3
(500,400,pistol) are rotational mirrors of each other, not left-right
ones. The result: team 0's top rows picked up pistols while team 1's
*matching* top rows (same y, same distance, the soldiers who actually
fight each other) picked up shotguns — a genuinely asymmetric
matchup, not a coincidence. Combined with the wall's north/south
"try up first" tie-break (which delays top-row soldiers near the wall
regardless of team), whichever side's delayed, exposed rows held the
longer-ranged pistol could snipe the other side's shotgun-wielders,
who couldn't shoot back from that distance. **Fix:** reassign pickup
types so weapon TYPE mirrors left-right too (both top pickups
pistols, both bottom pickups shotguns) — matching the spawn layout's
actual symmetry instead of a different, incompatible one. Verified
afterward at 10/11 (this file) and 12/12 (stage6a/04, on a fresh
larger batch) — both consistent with an actually fair fight.

**4. A collision check that only tested a point, not a body.**
Visually, soldiers could walk partway *into* wall segments before
being stopped. The obstacle/screen-edge check (`is_point_in_obstacle`
at the time) only tested the soldier's tracked `(x, y)` corner, not
the `SOLDIER_SIZE` x `SOLDIER_SIZE` box `fill_rect` actually draws —
so up to `SOLDIER_SIZE - 1` pixels of the soldier's visible body could
overlap an obstacle before the tracked corner itself registered as
blocked. **Fix:** renamed to `is_box_blocked` and rewritten as a
proper box-vs-box (AABB) overlap test, verified against the exact
boundary (`x=350` clear, `x=355` blocked, for an obstacle starting at
`x=370` and a 16px soldier).

**The throughline:** every one of these was invisible in a single
run, or even a small batch. Running the same simulation repeatedly
and looking at the *distribution* of outcomes — not any one outcome —
is what caught #2 and #3. Watching closely and comparing what you see
against what the code claims to do is what caught #1 and #4. Neither
substitutes for the other.

## Running under gdb

Layout and unit-style checks are easiest done by temporarily calling
a function with known inputs right after `spawn_obstacles` in `main`
and printing the result via a raw `write` syscall (the technique used
throughout this debugging session) — gdb can't cleanly call our
hand-written functions like typed C functions without extra setup, so
this is more reliable than trying to invoke them from the debugger
directly.

```bash
gdb ./build/01_obstacles
(gdb) break spawn_obstacles
(gdb) run
(gdb) finish
(gdb) print *(int*)&obstacles          # obstacle[0].x
```

## What's deliberately not here yet

- Ranged weapons can still fire straight through the wall — no
  line-of-sight check on attacks yet. That's `02`.
- The perpendicular side-step is a heuristic, not pathfinding — a
  fully enclosed pocket (no gap at all) leaves a soldier sliding along
  a wall forever. `01`'s closing exercises ask you to construct and
  observe this on purpose.
