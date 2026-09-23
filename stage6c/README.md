# Stage 6c — Scale up to 50 vs 50

The capstone at full size: 100 soldiers, 16 weapon pickups, the same
wall and line-of-sight rules as stage6b.

## Build

```bash
make
make clean
```

## `01_scale_up.asm`

A copy of `stage6b/02_line_of_sight.asm` with `NUM_PER_TEAM` raised
from 8 to 50. As the roadmap predicted, the AI's loops didn't need
touching. Every one already ran to `TOTAL_SOLDIERS` or `MAX_PICKUPS`,
and at 100 soldiers the O(n²) nearest-enemy scan is nowhere near the
frame budget. The work was in the data layout, and in one fairness bug
that 8v8 had been hiding.

- **Spawn grid.** stage6b put each team in one column, 50px apart.
  At 50 per team that column would run to y=2530. Now each team is a
  5-wide × 10-tall grid (`SPAWN_ROWS`, `SPAWN_DX`/`DY`, ...), with an
  assemble-time `%error` if `NUM_PER_TEAM` isn't a multiple of
  `SPAWN_ROWS`. Team 1's x is *computed* as the mirror of team 0's
  (`SCREEN_W - SOLDIER_SIZE - x`) rather than typed in separately.
- **Pickups from a table.** 16 pickups written as blocks of `mov`s
  would invite exactly stage6b's bug #3 (a layout that looked
  symmetric but wasn't). Now only the left 8 are written down, in
  `left_pickups` (x, y, type), and `spawn_pickups` places each one
  plus its mirror. The two halves can't disagree, because only one
  half exists. Types are checkerboarded pistol/shotgun, 4 of each per
  side.
- **No spare drop slots.** `MAX_PICKUPS` is exactly the number of
  starting pickups (16). Weapons are conserved: each one is either on
  the ground in one slot or held by one living soldier, and it only
  drops when its holder dies. So the number on the ground can never
  exceed the number spawned. stage6b's "4 fixed + 4 drop slots" was
  more than it needed.

## `batch.sh` — counting wins without watching

```bash
./batch.sh 48                                   # 48 games of build/01_scale_up
./batch.sh 20 ../stage6b/build/02_line_of_sight # any stage's binary works
```

Runs N games headless (SDL's `dummy` video driver + software
renderer, so the unmodified binary needs no window), stops each one
as soon as it prints its win line, and prints the tally. A game
with no winner inside the timeout (default 120s) is `STUCK`; one
that exits without a winner is `CRASH`.

**Harness bug found on its first run:** it launched every game at once
and reported 16–0, twice. Every game had taken exactly 12.2s. The
game seeds with `srand(time(NULL))`, which only changes once a second,
so all 16 games had the same seed and were the same game. The script
now starts each game in its own second. A batch run that way against
stage6b came out 10–6, as expected for a fair game.

## Two fairness bugs, found only by batching

**1. The horizontal side-step always tried "left" first.** The first
honest 50v50 batches came out 8–16, then 9–39 for team 1. To tell
whether the bias came from processing order or from the map, I swapped
which side each team spawns on: the team on the **right** still won,
30–10. So the bias belonged to the right side of the map, not to
either team.

Instrumenting `.do_move` pinned it down. Team 0 took the horizontal
side-step 800–1200 times per game, team 1 about 90. stage6b's
`.try_horizontal` always tries −x first (`avoid_dir = 0`). For team 1,
spawned on the right, −x is toward the enemy and the gap, so the path
clears quickly. For team 0 it's straight back toward its own spawn, so
it stays blocked and side-steps again. At 8v8 almost nobody reached
that branch. At 50v50, with soldiers packed along the wall, a large
share of team 0 did.

**Fix:** "first choice" for the horizontal side-step now means
*forward*, toward the enemy's side: +x for team 0, −x for team 1
(`US_FWD_STEP`). A soldier's mirror image now makes the mirror image
of its choice. The vertical side-step (up/down) needed no change,
because up means the same thing for both teams.

**2. Mirroring pickups by the wrong size.** The first version mirrored
each pickup's drawn box, `SCREEN_W - PICKUP_SIZE - x`. That looks
right on screen. But the AI measures every soldier-to-pickup distance
from top-left corner to top-left corner. A 16px soldier and a 10px
pickup mirrored by their own sizes end up 6px closer for team 1:
front-column distance to the nearest pickup was 184 for team 1 and 190
for team 0. **Fix:** mirror the pickup's corner by the same rule as a
soldier's (`SCREEN_W - SOLDIER_SIZE - x`), so every corner-to-corner
distance is equal for both teams. The drawn squares end up 6px off a
visual mirror, which you can't see.

To be clear about the evidence: this fix did **not** remove the 9–39
bias. That was bug #1. With #1 fixed, putting the 10px mirror back
gave 18–30 in one 48-game batch, leaning the direction the offset
predicts but not decisive. It's kept because the asymmetry is real
and costs nothing to remove, not because a batch proved it mattered.
(stage6b's hand-typed x=100/700 soldiers and 300/500 pickups happened
to give equal distances, 200 each. Treating the 700 as a slightly-off
mirror and "cleaning it up" is how this one got in.)

## Verification

Final build, 96 headless games via `./batch.sh 96`:

- **Team 0: 46, team 1: 50** — consistent with a fair fight
- **0 stuck, 0 crashed**
- Game length 7.7–13.6s (median 9.4s), about the same as stage6b's
  8v8 (more soldiers, but also more guns in play much sooner)
- Side-swapped build (same code, teams on opposite sides): 16–24,
  within normal variance

A frame dumped from the back buffer at tick 1 shows the two grids and
all 16 pickups mirrored exactly. At tick ~150 every weapon has been
picked up and about 30 soldiers are left, mostly stacked along the
edges of the gap.

## What's deliberately not here

- **No soldier-vs-soldier collision.** Soldiers can occupy the same
  spot, so the crowds at the gap edges look like a few squares when
  they're really a dozen. Barely noticeable at 8v8, obvious at 50v50.
  Adding it would mean `is_box_blocked` checking all 99 other
  soldiers, and that interacts with the side-step logic, which is
  exactly where both of this stage's bugs lived.
- **Seeding is still `time(NULL)`.** Fine for playing. It's the
  reason `batch.sh` has to stagger launches. Seeding from
  `SDL_GetPerformanceCounter()`, or `time ^ getpid`, would let batches
  run all at once.
- The redundant second `line_blocked` walk when a ranged shot is
  blocked (stage6b/02's closing exercise) is still there. At 100
  soldiers it still doesn't matter.
