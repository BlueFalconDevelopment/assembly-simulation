# Stage 6a — Core loop at small scale

The capstone's first sub-step: prove the whole soldier/AI/combat loop
works at 8-vs-8 before scaling anything up (6c) or adding obstacles
(6b). Four programs, each adding one layer on top of the last. All
four run the full open-field knife/pistol/shotgun deathmatch the
roadmap describes for 6a.

## Build everything

```bash
make
make clean
```

## Suggested order

1. **`01_spawn_soldiers.asm`** — an array of `Soldier` structs (via
   `struc`), spawned into two still lines and rendered, team-colored.
   No AI yet — just proving the data layout and the "loop over N
   records, draw each" pattern before any behavior is built on it.
2. **`02_seek_enemy.asm`** — adds `find_nearest_enemy` (squared-
   distance comparison, no sqrt) and `update_soldiers`, which moves
   every living soldier toward its nearest living enemy, clamped so
   it can't overshoot. No combat yet — soldiers converge and stop at
   `CONTACT_RANGE`.
3. **`03_combat.asm`** — knife-only combat: `rand()`/`srand()` from
   libc (seeded from `time(NULL)`), an attack-cooldown field so
   fights don't resolve in a single frame, damage, death, and a win
   check that freezes the sim and prints the winner via a raw `write`
   syscall — the same technique from stage0/1, still the right tool
   for a one-off status line.
4. **`04_weapons.asm`** — adds a `Pickup` struct array (four fixed
   starting spawns: two pistols, two shotguns) and the full roadmap
   rule: a knife-only soldier compares its nearest active pickup's
   squared distance against its nearest living enemy's, and goes for
   whichever is closer. Combat stats now depend on the weapon —
   pistol trades knife's guaranteed damage for range, shotgun has
   real falloff (better odds and damage close up, worse at the edge
   of its range, decided by the actual distance at the moment of
   firing). An armed soldier that dies drops its weapon back onto the
   field at its death position, recycling a free `Pickup` slot, and
   it stays in circulation for anyone to grab.

## A real bug, found and fixed during verification

Running `03` many times in a row surfaced something a single test run
never would have: **team 0 won roughly 11 of 12 fights.** That's not
what a symmetric fight should produce. The cause, the failed first
fix, and the actual fix are all documented in detail in
`update_soldiers`'s header comment in `03_combat.asm` — short version:

- Soldiers were always processed in index order (team 0 first, every
  tick). When two soldiers were mutually in range, whoever got its
  turn first in the loop struck first — and if that killed its
  target, the target's own turn (later in the *same* tick) never
  happened, because the dead-check at the top of the loop skips it.
  Team 0 always went first, so team 0 always got the first strike, in
  every mutual engagement, for the whole fight.
- **First fix attempt:** alternate which end of the array gets
  processed first, once per tick. This made it *worse* — team 1 then
  won 9 of 10. Why: the attack cooldown is 30 ticks, an even number,
  so a soldier's attack always lands back on the same tick parity it
  started on, forever. A period-2 alternation *resonates* with any
  other even period in the simulation instead of averaging it out —
  it just swapped which fixed parity (and therefore which team) was
  permanently favored.
- **Actual fix:** pick the processing direction with `rand()` once
  per tick instead of a fixed alternation. A random choice has no
  period, so it can't resonate with the cooldown's period or any
  other fixed period a later stage might add. Verified afterward:
  4 of 12 vs 8 of 12 across a fresh batch of runs — well within
  normal variance for an actually-fair fight.

This is worth reading even if you never hit it yourself: **a
consistent, lopsided outcome from a "random" simulation is a signal
to go looking for deterministic structure (iteration order, fixed
periods) hiding behind the randomness — and a fix that just moves the
bias somewhere else isn't actually a fix.** Single test runs cannot
catch this class of bug; only running the same simulation repeatedly
and looking at the distribution of outcomes can.

## What's new here vs. Stages 0-5

- **An array of structs as the core data model**, not a handful of
  loose `.data` values or one moving object. Every stage from here on
  is "loop over records, read/write their fields."
- **`rand()`/`srand()`/`time()` from libc**, called via `extern`
  exactly like SDL's functions — same calling convention, no
  headers, just the real signatures.
- **Squared-distance comparisons** to find "nearest," never a real
  distance — `dx*dx + dy*dy` ranks candidates exactly as well as the
  true distance would, without ever needing a square root.
- **An attack-cooldown field**, because without rate-limiting, two
  soldiers in range would resolve a fight in a single 1/60-second
  frame — not because the math is wrong, but because nothing was
  pacing it.
- **A whole bug class**: order-dependent bias in a simulation that
  looks random from a single run, only visible by running it many
  times and looking at the *distribution*, not any one outcome.

## Running under gdb

Spawn/layout sanity checks (works even before SDL windows are
relevant):

```bash
gdb ./build/01_spawn_soldiers
(gdb) break spawn_soldiers.spawn_done
(gdb) run
(gdb) print *(int*)&soldiers                     # soldier[0].x
(gdb) print *(int*)((char*)&soldiers + 28*8)      # soldier[8].x -- team 1
```

Watching combat resolve is impractical to single-step under gdb (60
ticks/sec makes per-tick breakpoints extremely slow to page through
interactively) — instead, run it plainly and watch the console/window,
or redirect stdout to a file and poll it:

```bash
./build/03_combat > /tmp/out.txt 2>&1 &
# wait, then:
cat /tmp/out.txt
```

## What's deliberately not here yet

- No obstacles or line-of-sight — `6b`.
- Only 8v8 — `6c` is purely "bump `NUM_PER_TEAM`, confirm nothing
  else needs to change," already set up for by writing everything in
  terms of `TOTAL_SOLDIERS`/`NUM_PER_TEAM` instead of literals (and
  already spot-checked once, in `01`, by testing `NUM_PER_TEAM = 10`).
