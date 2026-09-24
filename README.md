# Assembly Simulation

A 50-vs-50 battle simulation written by hand in x86-64 assembly, built
up from "never written assembly" one stage at a time.

![50 vs 50 battle: blue and red soldiers fighting through the gap in a wall, with yellow pistol tracers, orange shotgun fans, white knife thrusts and hit flashes](docs/demo.gif)

*Stage 7.06, about 6 seconds from the middle of a fight. Blue and red
soldiers crowd into the gap in the wall. Yellow lines are pistol
tracers, orange fans are shotgun blasts, short white lines are knife
thrusts, and a white square is a soldier being hit.*

The idea comes from Chris Sawyer, who wrote about 99% of RollerCoaster
Tycoon (1999) in hand-written assembly with a thin layer of C for
Windows. This project works in the same spirit, at a smaller scale.
Everything is NASM: the AI, combat, pathing, line of sight, line
drawing, the random number generator, even turning numbers into text.
SDL2 is called directly from assembly for the window, input and blitting
pixels. The final binary imports 15 SDL2 functions and libc's startup
routine, and nothing else.

## Highlights

- **Two teams of 50** fight with knives, pistols and shotguns until one
  side is wiped out. Everyone starts with a knife. Guns spawn as
  pickups, get fought over, and drop back onto the map when their owner
  dies.
- **Cover and line of sight:** a wall with a gap in the middle. Ranged
  weapons need a clear line, checked with the same Bresenham walk that
  draws lines on screen.
- **Collision, random mirrored spawns, friendly fire and hold fire:**
  soldiers can't overlap. Shots hit whoever is actually in the way, so
  soldiers side-step for a clear shot rather than fire through a
  teammate.
- **Hand-rolled RNG:** xorshift64, seeded from the CPU's cycle counter
  (`rdtsc`) through splitmix64, verified bit for bit against a Python
  reference in gdb.
- **Tested for fairness, not just "it runs":** a headless batch harness
  plays dozens of games at once and counts wins. It has caught several
  real biases that were invisible in any single game, including one
  exactly one pixel wide. See [Verification](#verification).

## Quick start

Linux x86-64 (developed on Ubuntu):

```bash
sudo apt install nasm gdb build-essential libsdl2-dev
git clone https://github.com/BlueFalconDevelopment/assembly-simulation.git
cd assembly-simulation/stage8
make
./build/03_props             # Crips vs Bloods, with sprites (stage7 has the rest)
```

The winner is printed to the terminal when one team is wiped out, for
example `Team 0 (blue) wins on Pillars! (friendly fire: 0 hits, 0 kills;
held fire 1954 times)`. The window stays open on the last frame until you close
it.

Every stage directory works the same way: `make` builds each `.asm`
file in it into `build/`. Stage 0 is the one exception, a single
syscall-only `hello.asm` built without gcc or libc:
`nasm -f elf64 hello.asm -o hello.o && ld hello.o -o hello`.

## How the project is organized

Each stage is a directory of small numbered programs, and each one
builds on the one before it. Every stage has its own README, which is
the real changelog: what each file adds and, from 6a on, the real bugs
found while checking it and how they were fixed. The source is heavily
commented. Most files end with "try this in gdb" exercises and
questions meant to be answered by experimenting.

| Stage | What it adds |
|---|---|
| [`stage0_smoketest`](stage0_smoketest) | Toolchain check: nasm, ld and gdb on a hello world |
| [`stage1`](stage1) | Registers, arithmetic, the stack, `cmp`/jumps, the System V calling convention. Raw Linux syscalls, no libc |
| [`stage2`](stage2) | Linking SDL2 from assembly: open a window, clear it, handle quit, a frame-timed loop |
| [`stage3`](stage3) | A raw pixel buffer with byte offsets computed by hand, `set_pixel`/`fill_rect`, and Bresenham `draw_line` |
| [`stage4`](stage4) | State-driven animation, then real double buffering |
| [`stage5`](stage5) | Keyboard and mouse input: the point where the "scene" becomes a "sim" |
| [`stage6a`](stage6a) | The battle sim at 8v8: soldier structs, seek AI, knife/pistol/shotgun combat, pickups, win condition |
| [`stage6b`](stage6b) | Obstacles, movement that routes around them, line of sight for ranged fire |
| [`stage6c`](stage6c) | Scale to 50v50, plus the headless `batch.sh` harness |
| [`stage7`](stage7) | Past the roadmap: collision, random mirrored spawns, xorshift RNG, attack animations, friendly fire, hold fire, arenas, pathfinding, respawns, the neighborhood, random encounters, the Big Homie |
| [`stage8`](stage8) | Graphics, one drawing-only step at a time: hand-made pixel art for soldiers, pickups, cars and the dog, then props and shadows so far |

In `stage7`, each numbered file is the previous one plus one change:

| File | Change |
|---|---|
| `01_collision` | Soldiers can't overlap |
| `02_random_spawn` | Random spawn points, mirrored between teams so every map is fair |
| `03_xorshift` | libc's `rand()`/`srand()`/`time()` replaced with a hand-rolled xorshift64 seeded from `rdtsc` |
| `04_attack_fx` | Knife thrusts, tracers, shotgun fans, sparks and hit flashes. Drawing only: proven not to change the fight |
| `05_friendly_fire` | Shots hit the first soldier in the line of fire, on either team |
| `06_hold_fire` | Soldiers side-step instead of shooting through a teammate |
| `07_arenas` | Five mirrored wall layouts, picked at random or with `ARENA=n` |
| `08_headless` | `HEADLESS=1` runs a whole game in about 0.16s with no window, for fast batches |
| `09_pathfinding` | Flow-field pathfinding around walls; `SEED=n` replays a game; Zigzag maze arena |
| `10_traffic` | Pathfinding also steers around other soldiers: 0 stalemates in 6,240 games |
| `11_scoreboard` | A scoreboard under the field in a hand-made 5×7 pixel font |
| `12_respawn` | Respawns in a safe zone, first to 200 kills wins; `RESPAWNS=n`, `LIVES=n`, `SCORE_LIMIT=n` |
| `13_neighborhood` | A 1280×720 city neighborhood: Crips vs Bloods out of their apartment complexes, cars as low cover |
| `14_events` | Random encounters: a police car that shoots and arrests, and a pitbull that slips its leash |
| `15_bighomie` | A miniboss, the Big Homie, for the gang that's losing (`BOSS_AT=n`) |
| `16_tuning` | Soldiers flee off the road from the police; the Big Homie comes out earlier |

In `stage8`:

| File | Change |
|---|---|
| `01_sprites` | Hand-made 16×16 pixel-art soldiers: 8 facings, a walk cycle, gang colours, the weapon in hand |
| `02_details` | Pixel-art weapon pickups, police car, dog and parked cars |
| `03_props` | Shadows, trees, bushes, dumpsters, fences, rooftop AC units, streetlights, textured ground |

[`assembly-project-plan.md`](assembly-project-plan.md) is the original
roadmap, with its status and a list of hard-won traps to avoid.

## Verification

A single game of a random simulation proves almost nothing about
whether it's fair, so every gameplay change here is checked by playing
many games and counting wins:

```bash
cd stage7
STAGGER=0 ./batch.sh 48     # 48 headless games of the newest binary at once
```

`batch.sh` runs the unmodified binary with no window (SDL's `dummy`
video driver plus the software renderer). It stops each game when its
win line appears and tallies wins, `STUCK` games (no winner before the
timeout) and `CRASH`es. A few of the problems that counting wins
caught, all documented in the stage READMEs:

- a turn-order advantage that gave team 0 11 of 12 games, counted by
  hand before the harness existed (6a)
- a side-step rule that was "the same for both teams" but meant
  *toward* the enemy for one and *away* for the other: 9–39 (6c)
- a first batch that reported 16–0 because every game got the same
  `time()` seed, making it one game played sixteen times (6c)
- a 1px asymmetry, because a 16px box has no centre pixel, that tilted
  hold fire toward one team. Fixed by walking lines of fire in
  half-pixel units (7.06)

For changes that should *not* alter the fight, like the animations,
gdb gives a stronger check. Fix `rng_state` to the same seed in two
builds, run each to the end, and compare the whole game state byte for
byte.

## Write-ups

The whole journey, bugs included, is written up as a four-part blog
series:

1. [Bare Metal Deathmatch: Teaching Myself x86-64 Assembly From Scratch](https://tech-blog-bluefalcon.netlify.app/blog/bare-metal-deathmatch/) (Stages 0–6b)
2. [Bare Metal Deathmatch II: Fifty a Side, and a Coin That Kept Landing Heads](https://tech-blog-bluefalcon.netlify.app/blog/bare-metal-deathmatch-2/) (6c, 7.01–7.02)
3. [Bare Metal Deathmatch III: Tracers, Friendly Fire, and a Box With No Middle](https://tech-blog-bluefalcon.netlify.app/blog/bare-metal-deathmatch-3/) (7.03–7.06)
4. [Bare Metal Deathmatch IV: Walls as Data, and a Game With No Window](https://tech-blog-bluefalcon.netlify.app/blog/bare-metal-deathmatch-4/) (7.07–7.08)

## The stack

- **[NASM](https://nasm.us)**, the assembler (Intel syntax)
- **System V AMD64 ABI**, the calling convention that makes calling SDL2
  from assembly possible
- **gcc**, used only as the linker driver (`-no-pie` is required to call
  C functions from hand-written asm with a plain `call`)
- **gdb** for debugging, and for most of the verification above
- **[SDL2](https://www.libsdl.org)** for the window, input and pixel
  blitting

## License

[MIT](LICENSE)
