# Learning Assembly: A RollerCoaster Tycoon-Inspired Scene Project

## Status (as of 2026-09-23) — read this first when picking the project back up

**Done: every stage, 0 through 6c.** The capstone runs at 50 vs 50, verified fair over 96 headless games (46–50), with no stalls or crashes.

- **Repo:** https://github.com/BlueFalconDevelopment/assembly-simulation (public)
- **Local path:** `~/Claude/Assembly_Simulation/`, one subdirectory per stage (`stage1/`, `stage2/`, ... `stage6b/`, `stage6c/`), each with its own `Makefile` and `README.md`. `make` in any stage directory builds every `.asm` file in it into `build/`.
- **Each stage's README.md is the real changelog.** Read those before re-reading this file's roadmap. They document what each numbered file adds and, from Stage 6a on, the real bugs found during verification and how they were fixed. `stage6b/README.md` and `stage6c/README.md` together cover seven bugs in the capstone logic. Worth reading before touching `update_soldiers` again.
- **`stage6c/batch.sh N [binary]`** runs N headless games and tallies wins/stuck/crashed. It works on any stage's binary. Use it for any fairness check (see traps below).
- **Extensive session walkthrough** (Stages 0–6b) in `~/Claude/tech-blog/newPOSTS/` for a future blog post. 6c isn't written up there yet; `stage6c/README.md` has the whole story.

**Stage 7 (post-roadmap changes) in progress, `stage7/`:** `01_collision` (soldiers can't overlap) and `02_random_spawn` (random, mirrored spawn points and jittered pickups) are done and batch-verified; see `stage7/README.md`.

### Where to go from here (optional, nothing required)

The roadmap is complete. Natural next steps, roughly in order of payoff:
1. Seed `srand` with something finer than `time(NULL)` (e.g. `SDL_GetPerformanceCounter`), so `batch.sh` can launch games all at once instead of one per second.
2. ~~Soldier-vs-soldier collision~~ Done in `stage7/01_collision`.
3. Swap libc `rand()` for a hand-rolled xorshift (the "later swap-in" the design section mentions).
4. Write up 6c for the blog post.

### Traps to avoid (hard-won this session)

- **A single test run proves nothing about fairness.** Two separate real bugs (a missing `call rand` that silently un-fixed an earlier turn-order bias, and a pickup-layout symmetry mismatch) each produced *deterministic-looking* one-sided win rates (24 of 24 games, in one case) that were invisible until running 10+ games in a row and counting. If you change spawn positions, pickup positions, or anything in `update_soldiers`'s processing order, re-run a batch of 10-20 games and check the win split before trusting it.
- **Sampling once a second can hide an infinite loop.** The nastiest bug this session (a soldier stuck oscillating between two positions forever, `y=0 -> y=2 -> y=0 -> ...`) looked like a plain freeze when sampled every 60 ticks, and only became obvious tracing every single tick. If something looks "stuck," trace every tick for a short window before concluding it's just slow.
- **A raw `syscall` clobbers `rcx` and `r11`.** Used more than once this session for quick debug `write()` prints stuffed into the middle of existing code — if `r11` (or `rcx`) is holding something you still need afterward, save/restore it around the syscall or you'll get a very confusing crash that looks unrelated to the actual change.
- **"Symmetric" has to mean symmetric under the mirror, in every rule, not just in the spawn data.** 6c's big bias (9–39) came from a movement rule (`.try_horizontal` always tried −x first), which is "the same for both teams" in code but means *toward the enemy* for one team and *away* for the other. Quick test: swap which side each team spawns on and batch again. If the bias follows the side rather than the team, look at map/movement rules, not processing order.
- **Batch runs need distinct seeds.** `srand(time(NULL))` has one-second resolution, so games launched in the same second play the *identical* game. `batch.sh`'s first version reported 16–0 twice from this. The giveaway was every game having the exact same duration.
- **`gcc -no-pie` is required** when linking anything that calls SDL2 (or any extern C function) from hand-written asm using plain `call func` — without it you get `relocation ... can not be used when making a PIE object`. Already baked into every stage's Makefile from stage2 onward; just don't drop it if writing a new one from scratch.

## Why

Chris Sawyer wrote 99% of RollerCoaster Tycoon (1999) in hand-coded x86 assembly using MASM, with just 1% C to glue it to Windows/DirectX. The goal here is the same spirit, scaled down: learn x86-64 assembly by building toward a capstone simulation, almost entirely by hand — a two-team deathmatch: soldiers armed with knives, pistols, and shotguns, fighting until one team has no one left standing.

## Setup

- **Environment:** Ubuntu desktop (Ryzen 7 3700X, RX 6600, 32GB RAM)
- **Experience level going in:** total beginner — never written assembly
- **Ambition:** go big — a large-scale two-team battle simulation, not just a static scene

## The stack

- **NASM** — the assembler
- **System V AMD64 ABI** — the calling convention (args passed in `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`) — this is the bridge to calling SDL2
- **gcc** — used *only* as the linker driver, to get a working entry point and dynamic linking without writing any C code
- **gdb** — debugger
- **SDL2** — window / input / pixel-blit layer, called directly from assembly (the modern equivalent of Sawyer's thin C-to-DirectX glue)

## Roadmap

### Stage 0 — Toolchain ✅ done
- [x] Install nasm, gdb, build-essential, libsdl2-dev

```bash
sudo apt update
sudo apt install -y nasm gdb build-essential libsdl2-dev
```

### Stage 1 — Fight the registers until they make sense ✅ done
- [x] Registers, `mov`, arithmetic, the stack, `cmp`/jumps
- [x] Linux syscalls directly — no libc (e.g. print a string)
- [x] System V calling convention basics
- Expect a couple of focused days, not weeks — unglamorous but short.

### Stage 2 — Open a literal window ✅ done
- [x] Link against SDL2
- [x] `SDL_Init` / `SDL_CreateWindow` / `SDL_CreateRenderer`
- [x] Clear the screen to a color, handle the quit event
- [x] Stable, frame-timed main loop (not spinning the CPU)

### Stage 3 — Draw a scene by hand ✅ done
- [x] Get a raw pixel buffer (an SDL texture written into directly)
- [x] Compute byte offsets yourself: `row * pitch + col * 4`
- [x] Write your own line/rectangle plotting
- [x] First real "scene" — backdrop, ground, whatever fits the idea
- (The line-stepping logic written here gets reused later for line-of-sight checks in Stage 6.) — **confirmed**: `draw_line`'s Bresenham walk from this stage became `line_blocked` in Stage 6b, unchanged in algorithm, just swapping `set_pixel` for an obstacle check.

### Stage 4 — Make something move ✅ done
- [x] Per-frame animation driven by state you update each tick
- [x] Proper frame timing + double buffering

### Stage 5 — Let the player touch it ✅ done
- [x] Read keyboard/mouse events via SDL
- [x] Let input change the scene — this is where "scene" becomes "sim"

### Stage 6 — Capstone: team deathmatch battle simulation

**The design:**
- Two teams of soldiers fight to the death; last team with anyone standing wins.
- Weapons: knife (melee), pistol (medium range), shotgun (short-to-medium range, damage/accuracy falls off with distance).
- Everyone starts with a knife only. Pistols and shotguns spawn on the map as pickups soldiers have to reach and fight over.
- When an armed soldier dies, their weapon drops back onto the map and stays in circulation (adjust if you'd rather pickups be one-time).
- Battlefield has obstacles/cover, not just an open field.
- Target scale: 50+ vs 50+, reached by scaling up once the core logic is solid (see build order below).

**Per-soldier data:**
- position (x, y)
- health
- team id
- current weapon (none / knife / pistol / shotgun)
- state (seek_weapon / seek_enemy / attack / dead)
- target (enemy index or pickup index)

**AI loop, per living soldier, per tick:**
- If unarmed (or knife-only) and a weapon pickup is closer than the nearest living enemy → move toward the pickup, pick it up on contact.
- Otherwise → find the nearest living enemy (compare squared distances, skip the square root), move toward them if out of range, attack if in range.
- Attack resolution depends on weapon: knife = contact range, pistol = medium range, shotgun = short-to-medium range with falloff.
- End of tick: count living members per team; stop when one team hits zero.

**Randomness needed:** hit rolls / damage variance. Start by calling libc's `rand()`/`srand()` via `extern` (same pattern as linking SDL2). A hand-rolled xorshift RNG in pure assembly is a nice later swap-in, not a blocker.

**Build order — three sub-steps, not one big leap:**

**6a. Core loop at small scale (start here)** ✅ done — `stage6a/` (4 files: `01_spawn_soldiers`, `02_seek_enemy`, `03_combat`, `04_weapons`)
- [x] Small team size (6–10 per side) — open field, no obstacles yet (8 per side)
- [x] Weapon pickups: knife start, pistol/shotgun spawns, drop-on-death
- [x] seek_weapon / seek_enemy / attack state machine
- [x] Combat resolution for all three weapons (pistol has range, shotgun has real distance-based falloff)
- [x] Win condition check
- Found and fixed a real fairness bug here: fixed iteration order gave team 0 a first-strike advantage in every mutual engagement (11/12 win rate). Fixed by randomizing per-tick processing direction with `rand()` instead of a naive alternation (a naive fixed-period alternation made it *worse* by resonating with the attack cooldown's period — see `stage6a/README.md`).

**6b. Add obstacles** ✅ done — `stage6b/` (2 files: `01_obstacles`, `02_line_of_sight`)
- [x] Simple rectangular cover placed on the map (one wall, two segments, a gap in the middle)
- [x] Movement: if the straight line to the target is blocked, step left/right (or up/down) and take the first clear direction (not full A* pathfinding) — with a "sticky" per-soldier direction preference (`Soldier.avoid_dir`) to avoid a nasty 2-tick oscillation bug found this session
- [x] Line of sight for ranged weapons: reuses the line-stepping logic from Stage 3 (`line_blocked`) — walks the line from shooter to target, checks for obstacle cells in the way
- Five real bugs found and fixed during verification, all documented in `stage6b/README.md` — worth reading in full before extending this code further.

**6c. Scale up** ✅ done — `stage6c/` (`01_scale_up`, plus `batch.sh`)
- [x] Bump the agent array size to 50+ vs 50+ (50 per team, 5×10 spawn grid per side, team 1 computed as the mirror of team 0)
- [x] Confirm the same logic (no algorithm changes, just loop bounds) still holds together. The loops held. One movement rule (horizontal side-step preference) had to become team-relative, see below.
- [x] Pickup count/placement reconsidered: 16 pickups (8 per side from a table, mirrored in code). `MAX_PICKUPS` = 16 exactly, because weapons are conserved and extra drop slots can never be used.
- [x] Re-verified fairness and crash-safety at scale: 96 headless games, 46–50, 0 stuck, 0 crashed, 7.7–13.6s per game
- Two real fairness bugs found by batching (`stage6c/README.md`): the horizontal side-step always preferred −x (toward the enemy for team 1, away for team 0), giving a 9–39 bias at 50v50 that 8v8 never exposed; and pickups mirrored by their own size rather than the soldier's, leaving team 1's corner-to-corner distances 6px shorter.

**Performance note:** even at 100 total soldiers, an O(n²) nearest-enemy scan is trivial for modern hardware in hand-written assembly — this scale is not a performance problem. The real risk is debugging complexity, which is why 6a comes before 6c rather than the other way around.

## Reference material

- [x86-64 Assembly Language Programming with Ubuntu](https://cs.lmu.edu/~ray/notes/nasmtutorial/) — free tutorial, built for Ubuntu, NASM basics through calling C functions
- [asteroids-asm](https://github.com/adaxiik/asteroids-asm) — a full Asteroids clone in NASM + SDL2 — movement, shooting, and collision, close in spirit to the combat loop above
- [assemblife](https://github.com/cocorigon/assemblife) — Conway's Game of Life written entirely in x86-64 NASM — a reference for many-agent simulation logic in pure assembly

## Expectations

- Stage 0–2: a weekend or two of steady effort
- Stage 3 onward: the real learning curve — a multi-week arc to the capstone, not a sprint
- It's normal for Stage 1 to take longer than it looks like it should
- 6c (the 50+ vs 50+ scale-up) was the stretch goal. Done 2026-09-23.
