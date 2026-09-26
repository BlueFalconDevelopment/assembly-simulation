# Assembly Simulation

### MY CITY IS A WARZONE BUT I NEED MONEY!!!1:4thwall break: Help I need to fix my van.

*(The typos are on purpose: a nod to "I MAED A GAM3 W1TH ZOMB1ES 1N
IT!!!1".)*

A game written by hand in x86-64 assembly. You're a courier on a
bicycle, making deliveries through an endless gang war on a city's
south side. It started as "never written assembly" and was built one
small, tested step at a time.

![Crips in blue and Bloods in red fight down a residential street between rows of houses, with pistol tracers, shotgun blasts, blood and shell casings on the road](docs/south_side.gif)

*The war you ride through (Stage 9.03, camera zoomed in 2×). The
Bloods (red) hold the corner while the Crips (blue) push up the
street. Yellow lines are pistol tracers, orange fans are shotgun
blasts, and the blood and brass stay where they fall.*

The idea comes from Chris Sawyer, who wrote about 99% of RollerCoaster
Tycoon (1999) in hand-written assembly, with a thin layer of C for
Windows. This project works in the same spirit, at a smaller scale.
Everything is NASM:
- the AI, pathfinding, combat and line of sight
- the vehicle physics, deliveries, menus and the save file
- line drawing, lighting, the random number generator, and even
  turning numbers into text

SDL2 is called directly from assembly for the window, input and
putting pixels on screen. The latest build imports 16 SDL2 functions
and five from libc (the startup routine, plus `getenv`, `atoi`,
`strtoull` and `strcmp` to read its settings), and nothing else. The
save file is written with raw Linux syscalls.

## The game

**The job.** A shift lasts 3 minutes.
1. A board offers three jobs. Each one is a package to pick up at a
   business on the main road and deliver to a house on the clock.
2. Pay depends on the distance, plus a bonus for danger: how many
   gangsters sit near the route. Late deliveries pay half.
3. When the shift ends, a summary shows your deliveries, earnings and
   kills.
4. Then comes the shop: body armor, toughness, bigger mags, the
   shotgun and a sturdier bike frame, all kept for good.
5. Money, gear and totals are saved between runs.

**The war.** Fifty Crips and fifty Bloods fight over the south side
and never stop:
- They respawn from their apartment complexes, fight over guns on the
  street, and route around houses with flow-field pathfinding.
- When a gang falls behind, it sends out its Big Homie.
- A police car patrols and arrests gangsters.
- A walker's pitbull slips its leash now and then.

**You.** Gangsters come after you if you get close. You can fight
(lock on, shoot, grab ammo off the street), but you're a courier, and
the smart move is usually to ride around them. The police leave you
alone. If you die, the shift ends and you lose a fifth of your cash.

| Key | Does |
|---|---|
| W A S D | Point where to ride (or walk) |
| E | Get on or off the bike |
| Right-click / left-click | Lock on / shoot |
| Q | Swap between the pistol and the shotgun |
| 1 2 3 | Take a job from the board |
| X | Drop the job |
| Mouse wheel | Zoom |
| ENTER | Go to the shop, or start a shift from it |
| W S, E (in the shop) | Choose, buy |

Coming next: a vehicle ladder (bicycle, moped, motorcycle, car, van),
more guns and abilities. After that,
new trouble: Biker packs, cartel hit teams, and the good ole boys in a
pickup truck.

## How it got here

The project didn't start as a game. It started as a way to learn
assembly, and each stage only went as far as the one before it
allowed:

1. **Learning the machine (Stages 0–5).** A hello world with raw
   syscalls. Registers, the stack and the calling convention. Opening
   an SDL2 window from assembly. Then a hand-drawn scene of pixels,
   rectangles and Bresenham lines, animated with double buffering and
   driven by the keyboard and mouse.
2. **A battle sim (Stages 6–7).**
   - 8 against 8, then 50 against 50, with knives, pistols and
     shotguns.
   - Then the long part: collision, a hand-rolled RNG, friendly fire,
     flow-field pathfinding, respawns and a scoreboard.
   - Then a city neighborhood with Crips and Bloods, a police car, a
     loose pitbull, and a Big Homie for the gang that's losing.
   - A headless batch harness played thousands of games to prove
     every change was fair.
3. **Graphics (Stage 8).** Hand-made pixel art, shadows, props, blood
   and brass that stay on the ground, day and night with streetlights,
   and a zoomable camera. Every step was drawing only, and proven not
   to change a single game.
4. **Scale (Stage 9).**
   - A map sixteen screens big, drawn only where the camera looks.
   - Then real streets from OpenStreetMap: a city's south side,
     compressed about 5×, with generated houses, a park, an airport
     and wrecker lots.
   - Then a profiler built from gdb, and a 5× speedup that plays the
     same games byte for byte.
5. **The game (Stage 10).** The source was split into modules, and two
   teams became factions with a table of who fights whom. Home sites
   are now picked from pairs that batches proved fair, and the war
   became endless. Then came the player, on foot and then on a
   bicycle, followed by deliveries, shifts, a save file, police who
   leave you alone, and a shop. Along the way the game got its name.
   - Every playable step was play-tested and reworked on feel. Aiming
     got a lock-on. The bike's tank steering became
     point-where-you-go. Police that ran you over now wait.
   - The old sim still runs underneath as `MODE=watch`. Every step is
     checked against the one before it, byte for byte.

The stage tables below list every step. Each stage's README is the
changelog, bugs included.

## Highlights

- **A real city's streets.** The map generator reads an OpenStreetMap
  snapshot and places houses along the real streets. It also plugs
  every gap narrow enough to trap a soldier or jam a crowd.
- **One vehicle engine for every tier.** Position in 1/16 px, a
  0..255 heading with a sine table, sliding off walls, and bumping
  through soldiers. It's driven by rows in a vehicle table, so a
  moped or a van will be data plus art, not new code.
- **Factions and a hostility table.** Who shoots whom, who counts as
  friendly fire, and whose flow field leads where are all one table
  in `.data`.
- **Fair by measurement.** Each game picks home sites from pairs that
  batches of hundreds of games showed are close to 50/50.
- **Hand-rolled RNG:** xorshift64, seeded from the CPU's cycle
  counter (`rdtsc`) through splitmix64, verified bit for bit against a
  Python reference in gdb. Drawing never touches it, so replays hold.
- **Tested, not just run.** Headless batches count wins and have
  caught several biases, one of them exactly one pixel wide. Every
  refactor is proven byte-identical in gdb, and every player feature
  has a scripted gdb bot test. See [Verification](#verification).

## Progression

The same project at each stage, from the first hand-plotted pixels to
a city's south side. Every image is a real frame from that stage's
program, read back from the renderer in gdb.

| | |
|:---:|:---:|
| ![A sky, hills drawn as lines, a strip of grass and some rectangles](docs/progress/01_stage3_scene.png) | ![The same sky, hills and grass, with an orange square bouncing across](docs/progress/02_stage4_double_buffer.png) |
| **Stage 3.** The first picture: a pixel buffer, `fill_rect`, and Bresenham lines for the hills, all computed by hand | **Stage 4.** Animation: a bouncing square, double buffered |
| ![A few blue and red squares facing each other on a green field](docs/progress/03_stage6a_8v8.png) | ![A field split by a wall with a gap, a few blue and red soldiers near it](docs/progress/04_stage6b_cover.png) |
| **Stage 6a.** The battle sim at 8 vs 8: soldiers, seeking, knives, pistols, shotguns | **Stage 6b.** A wall with a gap: movement around it, and line of sight for guns |
| ![Fifty blue and fifty red squares crowded at the gap in the wall](docs/progress/05_stage6c_50v50.png) | ![Soldiers fighting at the gap, with yellow tracers and white hit flashes](docs/progress/06_stage7_attack_fx.png) |
| **Stage 6c.** 50 vs 50, all piling into the gap | **Stage 7.04.** Attack animations: tracers, shotgun fans, knife thrusts, hit flashes |
| ![An arena of four wall blocks with gaps, soldiers fighting in the crossings](docs/progress/07_stage7_arenas.png) | ![A grid of pillars with a scoreboard under the field reading BLUE 31, PILLARS, 0:05, RED 26](docs/progress/08_stage7_scoreboard.png) |
| **Stage 7.07.** Five mirrored arenas (this is Crossroads) | **Stage 7.11.** A scoreboard in a hand-made 5×7 font |
| ![A city block with roads, buildings, a parking lot and two apartment complexes, one blue and one red](docs/progress/09_stage7_neighborhood.png) | ![The same neighborhood with pixel-art soldiers, cars and buildings](docs/progress/10_stage8_sprites.png) |
| **Stage 7.13.** The neighborhood: Crips and Bloods out of their apartment complexes, cars as cover | **Stage 8.01.** Hand-made pixel-art soldiers: 8 facings, a walk cycle, gang colours |
| ![The neighborhood with trees, shadows, fences and rooftop details](docs/progress/11_stage8_props.png) | ![The neighborhood at night, lit by streetlights and the lobbies](docs/progress/12_stage8_night.png) |
| **Stage 8.03.** Props and shadows: trees, fences, dumpsters, rooftop units | **Stage 8.05.** Day and night, with streetlights and lit lobbies |
| ![A close-up of a fight on the street beside the parking lot, blood on the road](docs/progress/13_stage8_camera.png) | ![A zoomed-out view of the neighborhood repeated in a 4 by 4 grid](docs/progress/14_stage9_world.png) |
| **Stage 8.06.** A camera: zoom in toward the cursor, pan with W A S D | **Stage 9.01.** A map 16 screens big, drawn only where the camera looks (a stand-in, zoomed out) |
| ![Blocks of houses with gable roofs, hedges and trees, and a fight in the streets](docs/progress/15_stage9_south_side.png) | ![A zoomed-out view of dozens of blocks of houses and the two gang complexes](docs/progress/16_stage9_zoomed_out.png) |
| **Stage 9.02.** Real streets from OpenStreetMap, compressed about 5×: generated houses along them | **Stage 9.02**, zoomed all the way out: a quarter of the map, with both homes |
| ![The same zoomed-out view at night, streetlights along every street](docs/progress/17_stage9_night.png) | ![The whole south side map: street grid, park, airport with a runway, wrecker lots and the expressway](docs/progress/18_stage9_map.png) |
| **Stage 9.02** at night | **The whole south side map** (from its generator): neighborhoods, a park in the south-west, an airport in the middle south, wrecker lots in the south-east |

And stage 7.06, the demo this README used to open with:

![50 vs 50 battle: blue and red soldiers fighting through the gap in a wall, with yellow pistol tracers, orange shotgun fans, white knife thrusts and hit flashes](docs/demo.gif)

## Quick start

Linux x86-64 (developed on Ubuntu):

```bash
sudo apt install nasm gdb build-essential libsdl2-dev
git clone https://github.com/BlueFalconDevelopment/assembly-simulation.git
cd assembly-simulation/stage10
make
./build/10_shop              # the game: ENTER for the shop, ENTER again to ride
MODE=watch ./build/10_shop   # just watch the war, last gang standing
```

The save goes to `~/.courier_save` (or `$SAVE`). `TIME=21` starts at
night. The watch mode prints the winner to the terminal, and the
window stays open on the last frame until you close it.

Every stage directory works the same way: `make` builds each program
in it into `build/`. Stage 10's programs are folders (`main.asm` plus
its modules). Stage 0 is the one exception, a single syscall-only
`hello.asm` built without gcc or libc:
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
| [`stage8`](stage8) | Graphics, one drawing-only step at a time: hand-made pixel art for soldiers, pickups, cars and the dog, then props, shadows, ground effects, day and night, and a zoomable camera |
| [`stage9`](stage9) | Scale: a map sixteen screens big, drawn only where the camera looks, then real streets from OpenStreetMap, and five times faster headless |
| [`stage10`](stage10) | The game: a courier on a bicycle making deliveries through an endless gang war, with shifts, a save file and a job board |

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
| `04_ground` | Blood splats, shell casings and a death animation that stay on the street |
| `05_night` | Day and night: time passes, streetlights, lit lobbies, headlights and muzzle flashes light the dark |
| `06_camera` | Mouse-wheel zoom toward the cursor, and W A S D to move the camera |

In `stage9`:

| File | Change |
|---|---|
| `01_world` | A 5120×2880 map (a stand-in: stage 8's neighborhood tiled 4×4), with the map data in its own files; each frame draws only the camera's view, which can now zoom out to a quarter of the map |
| `02_southside` | A real city's south side from OpenStreetMap, compressed about 5× to 5120×2608: real streets, generated houses, a park, an airport, wrecker lots, a fenced expressway; the generator plugs every gap a soldier could get stuck or jammed in |
| `03_bfs` | Five times faster headless, the same games byte for byte: the flow-field searches skip a divide per cell and only run as far as a soldier asking for directions needs |

In `stage10`, each step is a folder (`main.asm` plus its modules):

| Step | Change |
|---|---|
| `01_modules` | The source split into 21 modules, one per concern; the same machine code as 9.03, byte for byte |
| `02_factions` | Two teams become factions, with a table of who fights whom and a flow field per faction; the same game, byte for byte |
| `03_fair_homes` | Six possible home sites; each game picks one of the pairs that batches showed are fair (9.02's 62% home lean is gone) |
| `04_endless` | Two modes: `watch` (last gang standing, for tests) and `game`, an endless war where the Big Homie keeps coming back and dropped guns move on |
| `05_on_foot` | You: a courier on foot in the endless war. W A S D to walk, right-click to lock on, left-click to shoot, Q to swap guns, walk over guns for ammo; the gangs come after you when you get close |
| `06_bicycle` | Your bike: W A S D point where to ride, E gets on and off; momentum, sliding off walls, bumping through soldiers. The first row of a vehicle table |
| `07_deliveries` | The job: a board of three offers (1, 2, 3), a package to pick up at a business and deliver to a house on the clock, pay by distance and danger |
| `08_shifts` | A title screen, 3-minute shifts ending in a summary, dying ends the shift and costs 20% of your cash, and a save file written with raw syscalls |
| `09_police` | The police leave you alone: they don't shoot you, and their car waits instead of running you over |
| `10_shop` | The shop between shifts: armor, toughness, bigger mags, the shotgun, a sturdier bike frame, kept and saved. And the game gets its name |
| `11_crews` | Turf crews: each gang posts five crews of three round the city, which guard their corner (and shoot at you). Most houses are now within reach of a gangster. Your guns hit harder, and the shop sells a pistol upgrade |
| `12_meds` | A health bar and a hits-you-can-take count. Prescription weed heals you: gangsters drop it, and medical marijuana dispensaries (a green cross on the roof) restock it |
| `13_encounters` | The police patrol the whole street grid (a road network from the map generator) and the dog is walked through town, both more often |
| `14_bikers` | The Bikers: a clubhouse in town, and a pack of five armored riders on motorcycles who raid a gang's turf now and then, shooting everyone, you included |

[`assembly-project-plan.md`](assembly-project-plan.md) is the working
plan: the current status, the roadmap for the game, and a list of
hard-won traps to avoid.

## Verification

A single game of a random simulation proves almost nothing about
whether it's fair, so every gameplay change here is checked by playing
many games and counting wins:

```bash
cd stage10
STAGGER=0 ./batch.sh 48 build/10_shop     # 48 headless games, 4 at a time
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
the refactors and now the whole player side of the game, gdb gives a
stronger check. Fix `rng_state` to the same seed in two
builds, run each to the end, and compare the whole game state byte for
byte.

## Write-ups

The journey so far, bugs included, is written up as a blog series
(Stages 0–7.08 so far; more parts are on the way):

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
