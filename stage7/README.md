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
