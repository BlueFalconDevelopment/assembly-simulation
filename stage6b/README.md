# Stage 6b — Add obstacles

Rectangular cover on the field, movement that routes around it
without real pathfinding, and line-of-sight for ranged weapons.

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
goal direction — one side, then the other, whichever this soldier's
own `.avoid_dir` prefers (see bug #5 below) — and take whichever is
clear. No A*, just "try to slide around it."

## `02_line_of_sight.asm`

One addition on top of `01`: before a ranged attack roll,
`.handle_enemy_goal` now calls `line_blocked` a second time (same
function, different question) between shooter and target. Blocked
means no shot — fall through to `.do_move` exactly as if the target
weren't in range yet, which already knows how to route around the
same obstacle. Knives skip the check entirely: they're contact-range
only, and anything that would block sight at that distance would
already have blocked the movement that got the soldier there.

## Five real bugs, found only by testing hard

This pair of files went through more debugging than anything else in
the project so far. All five are worth reading even if you never hit
them yourself — each is a different *class* of bug that "looks fine"
in a single test run, or even in `01` alone.

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
stage.

**3. A symmetry mismatch in the pickup layout, amplified by the
wall.** Even with `pass_reverse` fixed, `01_obstacles.asm` was
winning 24 of 24 test games for team 0. The cause: soldiers spawn
with LEFT-RIGHT MIRROR symmetry (both teams use the identical row
y-values), but the four weapon pickups were placed with 180-DEGREE
ROTATIONAL symmetry instead — pickup 0 (300,200,pistol) and pickup 3
(500,400,pistol) are rotational mirrors of each other, not left-right
ones. The result: team 0's top rows picked up pistols while team 1's
*matching* top rows (same y, same distance, the soldiers who actually
fight each other) picked up shotguns — a genuinely asymmetric
matchup, not a coincidence. Combined with the wall's north/south
processing delay (which slows down top-row soldiers near the wall
regardless of team), whichever side's delayed, exposed rows held the
longer-ranged pistol could snipe the other side's shotgun-wielders,
who couldn't shoot back from that distance. **Fix:** reassign pickup
types so weapon TYPE mirrors left-right too (both top pickups
pistols, both bottom pickups shotguns) — matching the spawn layout's
actual symmetry instead of a different, incompatible one. Verified
afterward at 10/11 (`01`) and 12/12 (`stage6a/04`, on a fresh larger
batch) — both consistent with an actually fair fight.

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

**5. A permanent 2-tick oscillation, exposed by adding line-of-sight.**
`01` alone always resolved fights within 10-20 seconds. Add `02`'s LOS
check and fights started taking 90+ seconds — some never finished.
Per-tick position tracing on a stuck soldier showed the cause exactly:
`y=0 → y=2 → y=0 → y=2 → ...`, forever, in perfect lockstep with the
branch trace flipping `up → down → up → down`. The side-step always
tried "up" first, unconditionally. At `y=0` (screen edge), "up" is
blocked, so it falls back to "down" and moves to `y=2`. At `y=2`, "up"
is no longer blocked (`y=0` is back on-screen) — so it takes "up"
again, immediately undoing the previous step. Forever. `01` mostly
dodged this because a soldier could often resolve combat (through the
wall) before ever getting trapped at exactly that boundary; `02`
forces every ranged soldier to actually complete the physical detour,
making the trap far more likely to be hit and impossible to escape
once caught. **Fix:** a new `Soldier.avoid_dir` field makes the
preference *sticky* — a soldier remembers which side worked last and
tries that one first, only switching if it stops working. Verified by
re-running the exact same per-tick trace after the fix (clean
monotonic movement, no oscillation) and confirming fight resolution
times dropped back to 9-14 seconds across repeated runs, with zero
crashes. The same bug — and the same fix — applied to `01`, since the
flawed logic originated there.

**The throughline:** every one of these was invisible in a single
run, or even a small batch, or in `01` considered alone. Running the
same simulation repeatedly and looking at the *distribution* of
outcomes caught #2 and #3. Watching closely and comparing what you
see against what the code claims to do caught #1 and #4. Tracing
exact state tick-by-tick, not just sampling every so often, caught
#5 — a coarser sample (once a second) made a perfect 2-tick
oscillation look like a plain freeze, not a cycle. None of these
techniques substitutes for the others.

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

For anything resolving over multiple seconds of simulated time (a
fight, a stuck soldier), breaking every frame under gdb is too slow to
page through interactively (60 breakpoint stops a second). Redirect
stdout to a file from a temporary debug print instead, and read the
file — the technique that actually found bug #5.

## What's deliberately not here yet

- The perpendicular side-step is a heuristic, not pathfinding — a
  fully enclosed pocket (no gap at all) leaves a soldier sliding along
  a wall forever, even with the sticky-direction fix (it just means
  every soldier commits to a direction instead of flip-flopping;
  a wall with no gap still has no direction that works). `01`'s
  closing exercises ask you to construct and observe this on purpose.
