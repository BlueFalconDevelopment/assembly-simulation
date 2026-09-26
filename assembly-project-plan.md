# Learning Assembly: A RollerCoaster Tycoon-Inspired Scene Project

## Status (as of 2026-09-26, end of day) — read this first when picking the project back up

**Where things stand:** the sim is finished, and Stage 10 has turned it into a playable game. It has three phases so far:
- **Foundations** (10.01–10.04): modules, factions, fair homes, the endless war.
- **The player** (10.05–10.10): on foot, the bike, deliveries, shifts and saving, the police, the shop.
- **Tuning** (10.11–10.14): turf crews, weed and health, encounters in town, the Bikers.

**Progression content** is half done: 10.15 vehicles and 10.16 guns are in; abilities and price scaling are next.

**Latest build: `stage10/16_guns/`** (`main.asm` plus 33 modules, with the generated map in `stage10/maps/southside5.*`). Start the next step from a copy of that folder. **All code is committed and pushed through 10.16** (`b06ae95`). If `git status` shows this plan modified, that's this end-of-day update, left for the user to commit.

**The game:** "MY CITY IS A WARZONE BUT I NEED MONEY!!!1:4thwall break: Help I need to fix my van." It was named in 10.10. The typos are on purpose, a nod to "I MAED A GAM3 W1TH ZOMB1ES 1N IT!!!1". The van is a meta joke about the user's real life, **not a game goal: keep it out of the game.**
- **The setting:** you're a courier making deliveries through an endless Crips-vs-Bloods war, on a city's south side built from real OpenStreetMap streets (5120×2608).
- **The loop:** title → **shop** → a 3-minute **shift** → summary → shop, with **ENTER** moving on.
- **The shop's pages** (A/D to change, W/S to choose, E to buy):
  - **GEAR:** body armor, toughness, heavy frame.
  - **GUNS:** big mags, shotgun, pistol upgrade, SMG, rifle, bat, grenades.
  - **RIDES:** bicycle, moped, motorcycle, car, van. You keep what you buy and pick one each shift.
- **Deliveries:** a board of three jobs (**1 2 3**; **X** drops one). Pick up at a business, deliver to a house, on the clock. Pay depends on distance and danger.
- **Controls:**
  - **W A S D** point where you ride or walk. **E** gets on and off.
  - **Right-click** locks on, and **left-click** fires, or throws a grenade.
  - **Q** cycles weapons.
  - Walking over a gun on the ground takes its ammo.
- **Health:** a bar over you, and "HP 120/150 (8 HITS)" on the scoreboard. Prescription weed heals 60: five random dispensaries (a green cross on the roof) restock it, and gangsters drop it.
- **The city:**
  - Each gang's war front, plus 5 turf crews of 3 around the city.
  - Police patrolling the whole street grid (they ignore you and wait for you).
  - Dog walks in town.
  - Biker raids from a clubhouse about every 90 s.
- **Dying** ends the shift and costs 20% of your cash, never gear.
- **The save** is `~/.courier_save`: money, totals, gear levels, owned rides and your pick.

`MODE=watch` (the default headless) is still the old last-gang-standing sim, byte-identical from step to step. It's the test harness. Everything the player, crews, weed, the road police and the Bikers add is game mode only.

| Step | File | Result |
|---|---|---|
| 7.01 | `01_collision` | soldiers can't overlap |
| 7.02 | `02_random_spawn` | random spawns, mirrored so each map is fair |
| 7.03 | `03_xorshift` | own RNG (xorshift64, `rdtsc` + splitmix64 seed), no libc RNG |
| 7.04 | `04_attack_fx` | knife/tracer/shotgun/spark/flash animations, drawing only (same seed = byte-identical game to 03) |
| 7.05 | `05_friendly_fire` | shots hit the first soldier on the line of fire (`first_in_line`), ~15 friendly kills/game |
| 7.06 | `06_hold_fire` | a soldier side-steps instead of firing through a teammate: 0 friendly fire, 142–146 over 288 games |
| 7.07 | `07_arenas` | 5 mirrored wall layouts (Divide, Pillars, Crossroads, Trenches, Outposts), random or `ARENA=n`: 371–349 over 720 games |
| 7.08 | `08_headless` | `HEADLESS=1`: no window, no frame cap, 0.16s per game (48-game batch in 2.7s). Tick count in the win line, stalemate at 30,000 ticks. 2,400 games: 1,225–1,162, 13 stalemates on Pillars/Crossroads/Outposts |
| 7.09 | `09_pathfinding` | flow-field BFS on a 9px mirror-exact grid, `SEED=n` replay, pickup radius 15→24 (fixed a deadlock), Zigzag back as arena 5: 1,950–1,889 over 3,840 games, 1 stalemate |
| 7.10 | `10_traffic` | `flow_waypoint` tries every closer cell, closest first, skipping steps another soldier blocks: 0 stalemates in 6,240 games, 1,927–1,913 over 3,840 |
| 7.11 | `11_scoreboard` | 24px strip under the field in a hand-made 5×7 font: team counts, arena, clock, winner. Drawing only (byte-identical to 10 for fixed seeds) |
| 7.12 | `12_respawn` | respawns in the spawn strip (safest of 8 spots, 1.5 s protection), first to `SCORE_LIMIT` (200) wins, `RESPAWNS=n` per team, `LIVES=n` per soldier; `RESPAWNS=0` byte-identical to 11. 7,120 games, 0 stalemates, games ~40–50 s (Zigzag ~93 s) |
| 7.13 | `13_neighborhood` | 1280×720 city neighborhood, Crips (blue) vs Bloods (red) from apartment complexes with doors; random side swap instead of mirroring; low cover (cars, dumpsters, fences block walking, not bullets) via a per-pixel blockmap; pre-drawn background; 3 lives default. 960 games: Crips 475 – Bloods 485, but the east complex wins 59% |
| 7.14 | `14_events` | random encounters: a police car (one at a time) that shoots, scares soldiers off and arrests anyone it touches (no respawn); a walker whose pitbull slips its leash and bites the nearest soldier. 960 games: 21.7 arrests, 1.2 police kills, 2.7 dog kills per game; Crips 461 – Bloods 499; west complex now wins 54% |
| 7.15 | `15_bighomie` | the Big Homie: when a gang's strength falls below `BOSS_AT`% (default 40) of the other's, and the other's Big Homie isn't alive, a 400-health armed miniboss (double damage, fearless) leaves the complex. 15% comebacks (2% at the first default of 60), margin 20 → 15 |
| 7.16 | `16_tuning` | fleeing soldiers run off the road (across the car's path), `FEAR_RADIUS` 280: arrests 24 → 11.7 a game. `BOSS_AT` 60: the Big Homie comes out ~72% through a game instead of ~80%. Win line records when |
| 8.01 | `stage8/01_sprites` | hand-made 16×16 pixel-art soldiers: 8 facings from 5 poses, 2 walk frames, gang shirt and bandana, 3 skin tones, weapon in hand; Big Homie in gold. Drawing only (byte-identical to 16) |
| 8.02 | `stage8/02_details` | pixel-art pickups (pistol, shotgun), police car (4 directions, flashing light bar), dog (run cycle, faces its way), detailed parked cars; `draw_sprite_ex` (any size, mirror, flip). Drawing only |
| 8.03 | `stage8/03_props` | shadows (baked in for buildings, cars, trees; oval ones under moving soldiers, dog, walker, police car), trees, bushes, detailed dumpsters, chain-link and wooden fences, AC units, chimneys, streetlights, ground texture. Background in 3 layers. Drawing only |
| 8.04 | `stage8/04_ground` | blood splats on hits, shell casings, a death animation (the fallen lie there, then leave a pool), all stamped into the background so they persist. Drawing-only randomness (`deco_hash`). Byte-identical to 8.03 |
| 8.05 | `stage8/05_night` | day and night: a day passes in 4 minutes; dusk and night tints; streetlights, lit lobbies, police headlights and muzzle flashes light the dark (half-res light map + per-channel tables); time on the scoreboard; `TIME=h`. Drawing only |
| 8.06 | `stage8/06_camera` | mouse-wheel zoom (1×–4×, toward the cursor) and W A S D panning: the camera is a source rectangle for `SDL_RenderCopy`; the frame is drawn exactly as before |
| 9.01 | `stage9/01_world` | a 5120×2880 map (stand-in: the neighborhood tiled 4×4, `tools/gen_standin.py`); map data in `maps/standin.inc` + `maps/standin_bg.bin` (incbin); each frame copies and draws only the camera's view (`FrameBuffer` origin `ox`/`oy`), zoom out to 0.5×; scoreboard in its own buffer. Headless games 7–9 s |
| 9.02 | `stage9/02_southside` | the real map (`tools/gen_southside.py` from the stripped OSM snapshot `maps/southside_osm.json`): 5120×2608, 1.56 px/m; real streets and buildings, generated houses, park, airport, wrecker lots, fenced expressway; homes at SW 20th & Monroe and SW 9th & Jefferson (`HOMES`). Generator plugs 16–47 px gaps (hedges, or drops a car); pickups in 40 mirrored pairs between the homes. 144 games: 0 stalemates, gangs even, **west home wins ~62%** (open question). Headless ~9 s a game |
| 9.03 | `stage9/03_bfs` | 5× faster headless (8.3 s → 1.6 s a game, 48-game batch 22 s), byte-identical to 02 (12 seeds headless, 1 windowed): `bfs_nbrs` neighbour bits (no `div`), and lazy resumable searches (`BfsState` per field; `flow_waypoint` → `bfs_ensure` → `bfs_until`). Profiler without perf: `stage9/tools/profile.py` |
| 10.01 | `stage10/01_modules/` | the source split into `main.asm` + 21 modules in 9.03's order; step folders from now on (shared `maps/`, `tools/`); `.text`/`.data` byte-identical to 9.03 (before the title change), end states identical for 12 seeds + 1 windowed |
| 10.02 | `stage10/02_factions/` | factions: `Soldier.team` = faction, `MAX_FACTIONS` 8, `NUM_GANGS` 2, `hostility` table + `HOSTILE` macro (targets, hold fire, friendly fire, scoring, respawn safety, field sources), a field per faction (`field_for`/`bfs_states`), `check_win` for N gangs. Byte-identical to 10.01 (12 seeds + windowed); MAX_FACTIONS=4 copy identical; all-zero table = no fighting. +4% time |
| 10.03 | `stage10/03_fair_homes/` | 6 sites (`SITES`, farthest-point from 9.02's two), 9 candidate pairs, `tools/score_pairs.py` → `maps/pair_scores.json`; kept pairs 0–1 (48.8%), 1–3 (53.9% of 960), 4–5 (53.3%); `PAIR=n`; closed sites walled up and roofed; map files versioned (`southside2.*`). 144 games: 0 stalemates, gangs even |
| 10.04 | `stage10/04_endless/` | `MODE=watch` (default headless, byte-identical to 10.03) / `MODE=game` (default windowed: unlimited lives/respawns, no winner, repeatable Big Homie via `boss_base`, stale guns relocate after `PICKUP_STALE` 900 ticks). 48 wars: even kills, no crashes |
| 10.05 | `stage10/05_on_foot/` | the player (`player.asm`): soldier slot `PLAYER`, `FACTION_PLAYER` 2. WASD + follow cam, right-click lock-on (brackets), left fires at the lock or nearest the cursor, Q swaps pistol/shotgun, walking over guns takes ammo (gun relocates), 150 HP + regen, 85% / 34 dmg, gangs chase only within `PLAYER_AGGRO` 450 and not via flow fields. Watch mode byte-identical to 10.04; tested with a gdb bot (30 kills / 7 deaths) |
| 10.06 | `stage10/06_bicycle/` | `vehicles.asm`: one physics routine driven by `vehicle_types` rows (bicycle row 0: top 4 px/tick, mass 2, health 60, aim −15%); 1/16 px position, 0..255 heading, sine table; WASD point the way (`key_heading`, turn toward it), no keys brakes; wall slide; soldiers bumped aside (`vehicle_bump`: shove 12 px, ram at ≥ 2 px/tick). Speed ladder ~1 px a rung. Art from `tools/gen_vehicles.py`. Watch byte-identical to 10.05. Reworked after play test (tank steering too hard) |
| 10.07 | `stage10/07_deliveries/` | `deliveries.asm`: 3 offers (business → house, ≥ 600 px), keys 1/2/3, X drops; markers + edge pip; clock from pickup, late = half pay; pay $10 + 1/60 px + $6 × danger (gangsters near the route); money. Map `southside3` adds `biz_points` (76) / `house_points` (572). Scoreboard two rows (`HUD_H` 40). Fixed `msg_buf` overflow (160 → 512). Watch byte-identical to 10.06 |
| 10.08 | `stage10/08_shifts/` | `shifts.asm`: title → shift (`SHIFT_TICKS` 10800) → summary, ENTER; death ends the shift, −20% cash. `save.asm`: 64-byte save (`~/.courier_save` / `$SAVE`) via raw syscalls, tmp + rename, checksum, damaged → new. `draw_text` via `text_fb` for overlays. Watch byte-identical to 10.07; save round-trip, damaged and death tested |
| 10.09 | `stage10/09_police/` | the police leave the player alone (play-test request): `FACTION_POLICE` 3 with a hostility row (gangs, not you) for aiming and arrests; `cop_blocked` = strip ahead of the bumper (bike-sized when riding, parked bike too), wait up to `COP_WAIT_MAX` 2 s then U-turn; `rect_hit`. Reworked after `/code-review high` (8 findings: endless wait, rear/side freeze, bike overlap, stale comments, slot special-casing, duplicated overlap). Watch byte-identical to 10.08 |
| 10.10 | `stage10/10_shop/` | the shop (`shop.asm`): title → shop → shift → summary → shop; W/S choose, E buys. `shop_items` table (`SHOP_ITEM` name, desc, max, 3 prices): armor (−15%/lvl), toughness (+25 HP), big mags (+30 rounds), shotgun (+12 shells), bike frame (+30). Levels a byte each at save offset 28 (old saves load as zeros), `apply_gear` at shift start. The game's name: "MY CITY IS A WARZONE BUT I NEED MONEY!!!1:4thwall break: Help I need to fix my van." Watch byte-identical to 10.09 |
| 10.11 | `stage10/11_crews/` | turf crews (`crews.asm`, game mode): 5 crews of 3 per gang at random house spots (700 px from homes and each other, own side first), stand at the post with pistols, fight hostiles within 400 px of it, walk back on a per-crew flow field (searched whole once; `bfs_ensure` skips them), replaced 30 s after death or arrest unless you're within 500 px; crews aren't flow-field sources (they'd slow every search 55%). Houses near a gangster 76–87% (was 21–47%); 48 wars 50.0% Crips; 16.5 s a headless war. After the play test: pistol 34→50, shotgun 60/30→100/50, a PISTOL UPGRADE shop item (3 levels: 66/83/100 dmg, 12/11/10 ticks; $200/400/800). Watch byte-identical to 10.10 |
| 10.12 | `stage10/12_meds/` | `meds.asm`: your health bar (green/yellow/red) and "HP h/max (N HITS)" (gang pistol hits after armor); prescription weed (orange Rx bottle, +60 HP, not at full health); 5 random dispensaries (green cross painted on the roof + door sign, restock 30 s); gangsters killed or arrested drop one 10% (45 s; 10–20 about). All on `player_rand`, in a shift only: watch mode and headless game-mode wars identical to 10.11 |
| 10.13 | `stage10/13_encounters/` | road network in the generator (`road_net`: 84 straight runs with both lanes clear, 210 joins; map `southside4`, bg identical to 3); `roads.asm` (game mode): the police car appears ≥700 px from you on a random run, turns at 35% of crossings, turns at T-ends, U-turns at dead ends, off duty after 90 s out of sight, 1 in 300 a tick; dog walks along east-west runs' sidewalks, 1 in 450; arrests replaced in game mode; the HUD keeps your line in a shift. Car out 92%, never in a wall; 48 wars 49.9% Crips; arrests 5.8→21.6, police kills 10.8→26.2, dog kills 7.5→29.5. Watch byte-identical to 10.12 |
| 10.14 | `stage10/14_bikers/` | `bikers.asm`: `FACTION_BIKERS` 4 (fights gangs and you), 5 slots after yours (`FIRST_BIKER`); clubhouse at a random crossing ≥1400 px from homes (biggest building nearby painted black with an orange winged wheel; bikes parked); raids ~90 s: target a random gang member, BFS over crossings (`road_join_nbrs`, map `southside5`) for next hops, a virtual leader rides crossing to crossing, riders follow its trail 45 px apart; 25 s raid then home; 250 HP, 40% of hits through. Motorcycle art in `gen_vehicles.py`. Fixed a crash (macro clobbered the leader's position). 48 wars 50.1% Crips. Watch byte-identical to 10.13 |
| 10.15 | `stage10/15_rides/` | vehicle ladder: moped/motorcycle/car/van rows (`VEH_ROW`: + `.box` collision square as 4 soldier boxes, `.size` sprite 24/40, `.body` % of hits taken by the vehicle, `.label`); art in `gen_vehicles.py`; shop page RIDES (A/D; buy or pick; owned bits + pick at save bytes 56/57); HEAVY FRAME for any ride; you're hidden inside cars; everything shoots (aim −15..−35%). Prices $300/800/2000/3500 placeholders. Capacity not used yet. Watch byte-identical to 10.14 |
| 10.16 | `stage10/16_guns/` | `weapons.asm`: `PW_*` player weapons (pistol, shotgun, SMG, rifle, grenades, bat) and a `pgun` table (range, hit, dmg, cd, looks) read by `player_fire`; Q cycles; bat melee (nearest within 30, no ammo); grenades thrown ≤260 px in an arc, blast 90 px (250→40; you at half; after the play test, was 70 px 150→10), scorch stamped, drawn flash/fireball/smoke. Shop items get a `.page` (GEAR/GUNS/RIDES; `page_rows`, `page_item`); new items appended (save order). Watch byte-identical to 10.15 |
| 10.17 | `stage10/17_pause/` | `pause.asm`: ESC/P pauses a shift; everything freezes (main loop skips updates; render skips effect ageing, flash/linger countdowns, stamps); menu RESUME / CONTROLS / OPTIONS (placeholder) / QUIT TO TITLE (keep pay, lose package, no penalty); `overlay_zoom`; font `<`. Watch byte-identical to 10.16 |

**Where everything lives:**
- **Code repo:** https://github.com/BlueFalconDevelopment/assembly-simulation (public, MIT).
  - The top-level `README.md` covers:
    - the game and its controls
    - the path from Stage 0 here
    - a progression gallery (`docs/progress/`)
    - per-stage tables
  - `docs/` also has step pictures: `road_network.png`, `bikers.png`, `rides.png`, `guns.png`.
  - **Each `stageN/README.md` is the real changelog.** `stage10/README.md` has a section per step, including play-test reworks and code-review findings.
- **Stage 10 layout:**
  - `stage10/NN_name/`: `main.asm` plus modules, in include order: constants, data, sprites, tables, bss, game, pathfinding, hud, respawn, background, camera, lighting, ground, draw_sprites, bosses, events, roads, ai, crews, vehicles, weapons, player, deliveries, save, shifts, shop, meds, bikers, vehicle_art, results, effects, win, primitives.
    - Macros must be defined before they're used. `vehicles` and `weapons` come before `player`. Where a module earlier in the order needs a later macro (`VEH_TYPE` in hud/events), it's written out by hand.
  - `stage10/Makefile` builds every folder into `build/NN_name`, using `.SECONDEXPANSION` and `-i $*/`.
  - `batch.sh` runs batches; `MODE=game` plays 8-minute endless wars.
- **Maps** (`stage10/maps/`, shared, **versioned by name**):
  - `southside.*`: 10.01–10.02
  - `southside2.*`: 10.03–10.06, adding the six home sites and pairs
  - `southside3.*`: 10.07–10.12, adding `biz_points` and `house_points`
  - `southside4.*`: 10.13, adding the road network (`road_runs`, `road_joins`)
  - `southside5.*`: 10.14 on, adding each crossing's neighbours (`road_join_nbrs`)
  - The generator is deterministic, and every `_bg.bin` since `southside3` is byte-identical, so git stores one copy.
  - `pair_scores.json`: the fair-pair batch results
  - `southside_osm.json`: the stripped OpenStreetMap snapshot
- **Tools** (`stage10/tools/`):
  - `gen_southside.py`: the map generator. It handles streets, houses, crack plugging, home sites, delivery points and the road network (`road_net`, `join_nbrs`).
  - `gen_sprites.py`: pixel art as text grids.
  - `gen_vehicles.py`: vehicles drawn once and rendered at 16 headings (bicycle, moped, motorcycle at 24 px; car, van at 40 px), plus the sine table.
  - `score_pairs.py`: batches each home pair.
  - `profile.py`: a SIGINT sampler under gdb, because perf is blocked.
- **Blog:** `~/Claude/tech-blog` (Astro; auto-deploys to Netlify on a push to `main`; live at https://tech-blog-bluefalcon.netlify.app).
  - **Published:** Parts 1–6 (`src/content/blog/bare-metal-deathmatch{,-2..-6}.mdx`, covering Stages 0–8.06).
  - **Draft:** Part 7, `newPOSTS/Learning x86-64 Assembly Part 7 - From Battle Sim to Game.md` (2026-09-26), covering Stage 9 and 10.01–10.16.
    - It's not committed or pushed.
    - Its video line is a `TODO`, for the user to pick.
    - Its two images point at the GitHub repo's `docs/` (raw URLs), because the blog has no images folder.
  - Publishing means turning a draft into `.mdx` in the house style:
    - `--[ BANNER ]--` text blocks, 74 chars wide
    - bold lead-ins instead of `###`
    - prose wrapped at 72 columns
    - a "PREVIOUSLY" intro
    - a "WHAT'S LEFT" checklist
    - `<YouTubeEmbed id="..." title="Song - Artist" />` at the top
    - check it with `npm run build`
  - Don't push the blog repo unless asked.
- **Never write the city's real name** anywhere: code, docs, commits, blog, tools, file names or memory. Say "the south side" or use street names; the blog avoids street names too. Run `git grep -ci` for it before each commit.

**How we work (keep doing this):**
- **One change = one step folder.**
  - Copy the previous folder to `stage10/NN_name/`.
  - Update `title_prefix` in `data.asm` and the header comments in `main.asm` (what the step does, and the questions).
  - Add a section to `stage10/README.md`, a row to the table above, and a row to the top-level README.
- **Watch mode must stay byte-identical** unless a step means to change the sim: the fixed-seed end-state check below, 12 seeds headless plus 1 windowed, against the previous step.
- **Game-mode changes to the war get a game-mode batch:** `MODE=game STAGGER=0 ./batch.sh 48 build/NN 300`. Check the Crips' share of kills (about 50%), crashes, and time per war.
- **Player features get a scripted gdb test.** A Python bot under the dummy driver presses keys by writing SDL's key state, calls routines with `call (int)fn(args)`, and checks memory. Resolve symbols with `nm`, because gdb confuses `player_ammo` with `PLAYER_AMMO`. Use `handle SIGILL stop nopass`.
- **Look at the frames:** capture with `SDL_RenderReadPixels` at `SDL_RenderPresent`, and read the PNGs. `TIME=12` gives daylight. Setting `courier` to 0 hides the overlays, and `cam_src` moves the camera when you're not in a shift.
- **The play-test loop:**
  1. Build, prove, test.
  2. Open games for the user.
  3. Wait for their feel feedback.
  4. Rework **the same step** until they're happy.

  Their words have reshaped many steps: lock-on (10.05), steering (10.06), police (10.09), the van item out (10.10), stronger guns (10.11), health and weed (10.12), bigger grenades (10.16).
  - **For shop content,** play-test on a separate save: `SAVE=<scratchpad>/playtest.sav`, a valid 64-byte save written by a small Python script with $10,000, never the real one. Top it up the same way; the checksum is the sum of the first 15 dwords, xor `0xC0DE5A1E`.
- **Suggest `/code-review high stage10/NN_name` before committing the bigger steps.** It found 8 real problems in 10.09, and 7 in 10.10.
- **Commit and push only when asked.** Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - When two steps are committed together, commit them as two commits. Commit the earlier one with the shared docs trimmed back to that step (and the generator, if it changed), then restore the full versions for the second.
- **Never more than about 4 game processes at once** (`JOBS=4`). The desktop nearly froze at 96.

**Environment variables (10.16):**
- **The game:**
  - `MODE=game|watch`: game is the default windowed, watch the default headless.
  - `SAVE=path`: the save file.
  - `PAIR=n`: pick a home pair.
  - `TIME=h`: the starting hour.
- **The sim:**
  - `HEADLESS=1`
  - `SEED=n`: replay a game.
  - `LIVES=n`
  - `RESPAWNS=n`
  - `SCORE_LIMIT=n`
  - `BOSS_AT=n`: the Big Homie trigger in %; 0 turns it off.
- **`batch.sh`:** `JOBS=n` (default 4) and `STAGGER=0`.

**Reusable recipes:**
- **Fixed seed plus end state (gdb), for byte-identical checks** (scratchpad `endstate.sh BIN SEED OUT [w]`):
  ```
  SEED=4242 HEADLESS=1 gdb -batch -ex 'break print_result' -ex run \
    -ex "dump binary memory a.bin (char*)&soldiers (char*)&soldiers+3672" \
    -ex "append binary memory a.bin (char*)&pickups (char*)&pickups+1312" \
    -ex "append binary memory a.bin (char*)&rng_state (char*)&rng_state+8" \
    -ex "append binary memory a.bin (char*)&ticks (char*)&ticks+4" \
    -ex kill ./build/NN
  ```
  Do the same for the other build, then `cmp`. That's 102 soldiers × 36 bytes (the gangs and the Big Homies; your slot and the Bikers' come after) and 82 pickups × 16. For the windowed run, add `SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software` and `MODE=watch`.
- **Sampling a war:** break on `update_soldiers`, and **re-issue `ignore 1 N` before every `continue`**, because `ignore` only counts once. Headless game mode stops at 28,800 ticks.
- **A frame:** see "Look at the frames" above. Conditional breakpoints catch an event, for example `if *(int*)&cop_active != 0`.
- **Profiling:** `MODE=game HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/NN`.

### Next steps (the user picks)

**Decided with the user (2026-09-26).** New build order: 10.17 pause and menu, 10.18 inventory, 10.19 abilities, 10.20 the economy, then lore, then the garage, the cartel and the good ole boys.

1. **10.17 pause and menu:**
   - **ESC** (and **P**) pauses during a shift. **Everything freezes**: the war, the shift clock, job timers, Biker raids.
   - The menu has Resume, Controls (a key list), Options (a placeholder until music), and Quit to title.
   - **Quit to title keeps this shift's earnings**, drops any package with no pay, and has no death penalty.
   - It's a new game state beside title/shift/summary/shop (`shifts.asm`). Use `draw_overlay` and `TEXT_LINE`. Watch mode must stay byte-identical.
2. **10.18 inventory:** **TAB** toggles an overlay that **pauses** the game. It shows weapons and ammo, grenades, gear levels, your ride and its health, and the package. **W/S and E equip a weapon** (like the shop); Q still cycles in the field. Leave room for the abilities. First, pull a shared menu helper out of `update_shop` and `update_pause` (key bits with held keys ignored, and the row wrap), and use it for the inventory too (from the 10.17 code review).
3. **10.19 abilities:** nitro (a speed boost on a cooldown), a smoke bomb (gangsters lose sight of you for a few seconds), and adrenaline (when you're low on health, briefly take less damage and fire faster). Each is a shop item, and they'll need keys and an inventory row.
4. **10.20 the economy:**
   1. Price scaling for everything the shop sells. Today's prices are placeholders: vehicles $300–3,500, guns $100–800. Jobs pay $30–70, so a shift makes $100–200.
   2. Package capacity on the job board, which is in the vehicle table but unused (the van carries 3).
   3. Then delivery pay, tuned against the prices. That's the user's balance order.
5. **Lore (after the systems):**
   - The courier is **a named character**, with a backstory revealed across shifts. The name and backstory are still to be decided with the user. The van joke stays real-life only.
   - It's told four ways: **shift intro cards**, **flavored job text**, **milestone story beats** (unlocked by shift counts or money), and **scoreboard radio chatter** mid-shift.
   - Keep the tone: the name is a joke, the war is played straight.
6. **A refactor to fit in somewhere (10.17 review):** the render pass changes game state: effect ages, the flash and linger countdowns, casing, blood and pool stamps. Moving that into an update step would let the pause's single `jne .render` freeze it all, instead of the `paused` checks in `effects.asm` and `game.asm`'s draw loop. Watch mode must stay byte-identical (effects are cosmetic, but check the stamps' timing).
7. **Then:** the garage (mid-shift repairs and ammo), the cartel (4 hitmen hunt one gang), and the good ole boys (a pickup-truck mini-boss that leaves beer cans).
8. **After that:**
   - **Box art.** It'll probably be made outside the assembly, from a big render of the map and sprites. The title screen could show it.
   - **Music, written by the user.** The game has no sound code yet. SDL2's core audio (`SDL_OpenAudioDevice`, `SDL_LoadWAV`, `SDL_QueueAudio`) keeps to "SDL2 and nothing else". Plan the format and the looping.
9. **Blog:** Part 7's draft is waiting; the user picks its video.

### Traps to avoid (hard-won)

- **gdb's `ignore N` only counts once (10.11).** After it's used up, the breakpoint stops every time. A sampler that set it once took all its "every 300 ticks" samples from the first few seconds (the police "never" came out). Re-issue it before each `continue`.
- **A macro can reuse your register (10.14).** `JOIN_AT` does `lea rax, [road_joins]`, and the Bikers' leader position was still in `eax`. So "are we there yet?" compared an address, the leader rode off the map, and a flow field was seeded outside the grid (a segfault in `bfs_seed`). Know what each macro touches (`VEH_TYPE`: rax, rcx; `RUN_AT`/`JOIN_AT`: rax).
- **`equ $ - label` measures everything in between (10.10).** A string put between `title_prefix` and its `_len` made the length cover both. And `$` can't go in a preprocessor `%if`: use a `times -(cond) db 0` build check.
- **A new field source costs every search (10.11).** Flow fields search from all sources at once, so 30 scattered, stationary crew members made headless wars 55% slower. Things that don't need chasing across the map shouldn't be sources.
- **Something new in the world can crash old code that trusted it (10.14).** Anything alive becomes a flow-field source and a target; a position off the grid crashes . Keep positions on the map.
- **Side-stepping can't get round a long barrier (10.11).** A crew member who fled to the far side of the expressway fence paced along it for good. Anyone who has to get somewhere specific needs a flow field to it.
- **The shop list's order is the save file's (10.10, 10.16).** Items are saved by position, so a new item goes at the end. Moving one to another page is a `.page` field, never a new place in the list.
- **Frames can lie about timing.** A screenshot "of the blast" caught the smoke, and one "of the clubhouse" caught the summary overlay at night. Capture by state (wait until `boom` is set), not by a tick count, and use .

- **A single test run proves nothing about fairness.** Two separate real bugs (a missing `call rand` that silently un-fixed an earlier turn-order bias, and a pickup-layout symmetry mismatch) each produced *deterministic-looking* one-sided win rates (24 of 24 games, in one case) that were invisible until running 10+ games in a row and counting. If you change spawn positions, pickup positions, or anything in `update_soldiers`'s processing order, re-run a batch of 10-20 games and check the win split before trusting it.
- **Sampling once a second can hide an infinite loop.** The nastiest bug this session (a soldier stuck oscillating between two positions forever, `y=0 -> y=2 -> y=0 -> ...`) looked like a plain freeze when sampled every 60 ticks, and only became obvious tracing every single tick. If something looks "stuck," trace every tick for a short window before concluding it's just slow.
- **A raw `syscall` clobbers `rcx` and `r11`.** Used more than once this session for quick debug `write()` prints stuffed into the middle of existing code — if `r11` (or `rcx`) is holding something you still need afterward, save/restore it around the syscall or you'll get a very confusing crash that looks unrelated to the actual change.
- **"Symmetric" has to mean symmetric under the mirror, in every rule, not just in the spawn data.** 6c's big bias (9–39) came from a movement rule (`.try_horizontal` always tried −x first), which is "the same for both teams" in code but means *toward the enemy* for one team and *away* for the other. Quick test: swap which side each team spawns on and batch again. If the bias follows the side rather than the team, look at map/movement rules, not processing order.
- **Box "centres" aren't mirror-symmetric in whole pixels.** A 16px box at `x` has no centre pixel; `x+8` mirrors to 1px off the mirrored box's `x+8`. Anything that draws lines between soldier centres and acts on the result (e.g. `first_in_line` in 7.06) should work in half-pixel units (`2x + 15`).
- **Batch runs need distinct seeds.** `srand(time(NULL))` has one-second resolution, so games launched in the same second play the *identical* game. `batch.sh`'s first version reported 16–0 twice from this. The giveaway was every game having the exact same duration.
- **`cdq`/`idiv` (and `div`) overwrite `edx`.** 7.04's `spawn_effect` read a soldier index from `edx` after a division. Reload anything that was in `rdx`, or keep it in memory.
- **Latent bugs wait for new callers.** `fill_rect` didn't clip negative x/y for five stages, until impact sparks landed off-screen (fixed in 7.04 onward). When new code calls an old helper with new kinds of inputs, check the helper's edge cases.
- **`gcc -no-pie` is required** when linking anything that calls SDL2 (or any extern C function) from hand-written asm using plain `call func` — without it you get `relocation ... can not be used when making a PIE object`. Already baked into every stage's Makefile from stage2 onward; just don't drop it if writing a new one from scratch.
- **Caller-saved registers don't survive a libc call.** `read_rules` put a default in `ecx`, then called `getenv`, which left 69 there: "unlimited" lives became 68 respawns per soldier (12–13). Set values *after* the call, or keep them in callee-saved registers or memory.
- **Drawing may never touch the game's RNG.** One extra `rng_next` shifts every later random number and changes the whole game. Anything cosmetic that needs randomness (splat shapes, casing scatter, the starting time of day) uses `deco_hash` of positions, frame counts or the seed.
- **The bg_buffer trick:** anything stamped into `bg_buffer` persists for the rest of the game at no cost per frame (blood, casings), because the whole buffer is copied to the screen each frame.
- **Fleeing "straight away" isn't always away.** Soldiers ahead of the police car in its lane ran down the road in front of it. Fleeing across its path halved arrests (16). When a rule looks right but the numbers don't move, trace a case.
- **gdb dumps must match the code's moment.** Comparing BFS fields to Python "failed" because they were dumped mid-tick, after soldiers had moved. Dump right after the function that builds the thing (`finish`).
- **A test can break the symmetry it's testing.** The side-swap test for Crossroads flipped positions but not the team-based "forward" tie-break, so it proved nothing. Make sure the control really is a mirror.
- **`pkill -f pattern` matches the shell running it** if the pattern is in its own command line, and kills that too (exit 144). Use `pgrep -x name` / `kill PID`.
- **`tee /dev/stderr` truncates a redirected stderr file** on every batch, because it reopens it. `batch.sh` writes each line to stderr directly now.
- **High-byte registers (`ah`, `dh`...) can't be used in an instruction with a REX prefix** (any of `r8`–`r15`, or `sil`/`dil`): `movzx r13d, dh` is an assembler error. Shift and mask instead.
- **Profiling here: perf is blocked (perf_event_paranoid 4), and gdb can't attach (ptrace_scope 1).** Use `stage9/tools/profile.py`: gdb starts the game, a shell loop sends SIGINT every 20 ms. `handle SIGINT stop noprint` silently means *nostop*; and gdb's Python can't tick from a thread (it holds the lock while the game runs).
- **NASM assembles `imul r32, r32, r32` into garbage (10.05).** The three-operand form wants an immediate third; with a register it builds bytes the CPU rejects (SIGILL). Use `mov` then two-operand `imul`. A gdb bot saw it only as a MemoryError until `handle SIGILL stop nopass`.
- **Run `/code-review` on each step folder (10.09).** A high-effort review of 10.09 found an endless-wait safe zone, a rear-freeze and stale comments that the scripted tests (which only tested the intended case) missed.
- **Never point an older step's build at the real save (10.10).** 10.08 and 10.09 accept `~/.courier_save` and write it back with the shop's bytes zeroed. Run old steps with `SAVE=/tmp/old.sav`.
- **An `equ $ - label` measures everything between them (10.10).** A string inserted between `title_prefix` and its length line made the length cover both. Put new data after the `_len` line.
- **Check buffer sizes when a line grows (10.07).** `msg_buf` (160) had silently overflowed since 10.03 as the summary line grew to 233 characters; `nm -n` showed what sat after it.
- **A spot 2 px from a wall is invisible to the 9 px grid (10.07).** Door spots need ~10 px of clearance to land in a walkable cell.
- **Shared map files break older steps (10.03).** `stage10/maps/` serves every step folder, so rewriting `southside.inc` in a new format broke 10.01 and 10.02. A format change gets a new file name (`southside2.*`); old ones stay frozen.
- **480 games resolves a pair only to about ±4.5% (10.03).** Pair 1–3 scored 50.4%, then 57.3% in a fresh 480: pooled 53.9%. Tighter claims need ~2,400.
- **Generated maps need gaps checked (9.02).** A 16–31 px gap between two solids lets a soldier in where the 9 px grid can't see (walkable needs a clear 24 × 24 window on the lattice): a long one traps him for good. A 32–47 px gap is one lane of cells: soldiers going opposite ways jam in it for thousands of ticks, which showed up only as a lopsided home split. `gen_southside.py`'s `cracks()` finds both; the check asserts none.
- **A gun behind a home pulls that gang backward (9.02).** Knife carriers go for the nearest gun: the last one left behind a home drew a crowd of 30 that jammed round it. Keep pickups between the homes, and mirrored when the map isn't.
- **To find what a lopsided batch is doing, sample the game.** A gdb Python script that breaks on `check_win` and reads `soldiers` every 400 ticks (count, mean x, armed, who hasn't moved) found both 9.02 jams in minutes. The scripts: break, `ignore 1 399`, `continue`, read memory with `struct`.
- **An even grid cell width can't be mirror-symmetric over an odd number of positions** (corner x 0..784 is 785 positions). That's why the pathfinding grid uses 9px cells (09).


## Stage 10+: the game (approved 2026-09-25)

The roadmap from simulation to playable game. Everything here is subject to change.

### Context

The sim is finished as a sim: 50 Crips vs 50 Bloods on a real-streets map (stage9/03_bfs, 5120×2608), with police, a dog, the Big Homie, day and night, and a camera. It's fast (1.6 s per headless game) and heavily verified: fixed-seed byte-identical checks for refactors, and 144–480-game batches for fairness.

The goal now is a **playable game**. The player is a delivery driver making runs through the gang war for money, spending it on guns, armor, better vehicles (a bicycle first, working up) and abilities. New factions add chaos: Biker packs, cartel hit teams, and the good ole boys. Everything is subject to change, so the roadmap is a series of small steps. Each step must leave a working, tested build, as every stage so far has.

### Design decisions (from the Q&A)

| Topic | Decision |
|---|---|
| Hostility | **Everyone but civilians is hostile to the player**: gangs, Bikers, cartel, good ole boys; police arrest/shoot anyone in the way; the loose pitbull bites anyone |
| Session | **Shifts with saved progress.** A shift is a timed run of deliveries; money, gear and upgrades save to a file. Death ends the shift early: you lose the cargo and some cash, and keep your gear |
| Combat | **Full combat**: WASD, mouse aim, click to shoot. Starts weak; the shop makes fighting viable |
| Movement | **A vehicle from the start, upgraded over time**: bicycle → moped → motorcycle → car → van (the ladder can change). Park, get off, and walk the package to the door (E to get on/off). Each tier is faster, carries more, and protects more: on a bicycle or moped you're fully exposed; a car's body blocks some shots. Vehicles are bought in the shop |
| Ramming | **Yes, but it damages the vehicle** and slows it. Damage scales with the vehicle's weight: a bicycle barely knocks someone over, a car kills |
| Deliveries | **Job board**: pick from a few offers (pickup at a business, drop at a house), timed, paying more for longer or more dangerous routes. One package at first; more capacity is an upgrade |
| The war | **Never ends in a shift**: unlimited respawns, ebbing and flowing. "Last gang standing" stays as a watch/test mode |
| Bikers | **Packs as an event**: heavily armored riders roll out of a (made-up) clubhouse now and then, hit and run against gangs, and go home |
| Cartel | Event: picks a random gang at a random time and sends **4 hitmen** (less health, more damage) to kill N of that gang, then they leave |
| Good ole boys | Event: **a pickup truck, mini-boss tough**, hostile to all gangs (and you); leaves a trail of beer cans stamped into the ground |
| Fair homes | **Pre-checked pairs, early**: the generator proposes home pairs, batches keep only near-50/50 ones, and each game picks one at random. This also fixes today's 62% west lean |
| Shop | **Both**: big purchases on a shop screen between shifts; repairs and ammo at a garage on the map mid-shift |

### Ground rules (how we avoid breaking the system)

1. **One change = one numbered step**, as now. With the game code growing past 10k lines, stage 10 splits the source into modules. Each step is a folder `stage10/NN_name/` (main.asm plus `%include`d modules), copied from the previous step's folder, so every step still builds on its own and history stays intact. The map files stay shared in `stage10/maps/`.
2. **The sim stays alive as a test harness.** `HEADLESS=1` (and a `MODE=watch` window mode) runs no player: the old last-gang-standing sim. `batch.sh` keeps working on every step.
3. **Refactors are proven byte-identical.** Same seed, same `soldiers`/`pickups`/`rng_state`/`ticks` as the step before (the existing gdb recipe), headless and windowed.
4. **Gameplay changes are batch-tested:** no stalemates or crashes, and the gangs stay even. The home split is judged against the fair-pairs list.
5. **Player code never touches the sim's RNG in watch mode.** Anything the player does gets its own RNG, so sim replays and fairness tests stay valid.
6. **Data-driven tables** (factions, hostility, weapons, items, vehicles) live in `.data`, or are generated when they depend on the map, so balance changes are edits to data, not code.
7. **The city's name never appears** (see memory).

### Architecture changes the game needs (from the current code)

- **N factions instead of two teams.** These all assume two teams: `score[2]`, `home[2]`, `fwd_sign[2]`, `tickets[2]`, `boss_state[2]`, the `BOSS0/1` slots, `field_to0/1`, `check_win`, `choose_sides`, `print_winner`, the HUD, the win line, and `batch.sh`'s tally. The plan: a faction index per soldier, a hostility matrix, and a flow field per faction meaning "toward anyone hostile to me". The lazy BFS from 9.03 (`bfs_ensure`/`bfs_until` in `stage9/03_bfs.asm`) keeps extra fields cheap. Soldier slots become pools: gangs, event units (Bikers, hitmen, good ole boys) and the player.
- **The player as an entity** in the same world: a hostile target for everyone (a BFS source for every faction's field; considered by `find_nearest_enemy`), hit by `first_in_line` shots, and blocked by `is_spot_blocked`/the blockmap.
- **Vehicles.** Today only the police car exists, driving straight lanes from `cop_routes`. The game needs:
  - free-riding physics for the player's vehicle, one engine for every tier from bicycle to van, driven by a vehicle table (heading, speed, turning, 16-facing sprites, collision by sampling the blockmap)
  - a **road graph** exported by `tools/gen_southside.py` (intersections as nodes, streets as edges), so AI vehicles (Bikers' bikes, the good ole boys' truck, later the police) can drive anywhere
- **Game state machine:** title → shift → shift summary → shop → shift…, plus pause. Screens are drawn with the existing 5×7 font (`draw_text`, `hud_fb`).
- **A save file** via raw `open`/`read`/`write` syscalls, in keeping with the project's spirit.
- **Fair homes:** the map must hold several candidate complex sites. The ones unused this game are drawn as neutral, closed buildings: their doors become walls in the blockmap at start.

### Roadmap

Each line is one step and one build. The order puts safe refactors first, then the core loop (drive, deliver, get paid, shop), then factions.

#### Phase A: foundations (sim only, provable)
- **10.01 Modules.** Split `03_bfs.asm` into `%include` modules: core, map, AI, pathfinding, draw, HUD, events. Binary behavior byte-identical.
- **10.02 N factions.** Generalize teams to factions with a hostility table: arrays sized `MAX_FACTIONS`, per-faction fields, homes and scores. With 2 factions it must be byte-identical to 10.01.
- **10.03 Fair home pairs.** Generator: candidate complex sites, and pairs filtered by walking distance and mirrored pickups. A batch script scores each pair; the map include gets the list of pairs that pass. `choose_sides` picks a pair; unused sites are closed. Batch-proven near 50/50.
- **10.04 Endless war.** `MODE=game` default: unlimited respawns, no winner; `MODE=watch` keeps last gang standing. Batches still run watch mode.

#### Phase B: the player (the core loop)
- **10.05 On foot.** Spawn at a depot; WASD plus mouse aim; the camera follows (with zoom kept); a starting pistol with ammo; health; death. Everyone hostile. The player's own RNG.
- **10.06 The bicycle.** Get on/off with E; riding physics (heading, speed, turning, 16-facing sprite, blockmap collision); fully exposed rider; light ramming (knocks soldiers down, hurts the rider too). The physics is written once, driven by a **vehicle table** (top speed, acceleration, turn rate, mass, health, armor, capacity, sprite, whether the rider can shoot), so later tiers are new rows plus art, not new code.
- **10.07 Deliveries.** Pickups at real businesses (the OSM buildings on Lee) and drop-offs at generated houses (both exported by the generator). A job board of 3 offers in the HUD, picked with number keys; on-map markers plus an edge-of-screen arrow; a timer; pay by distance and danger (danger = walking distance through gang-held cells, from the BFS fields); money.
- **10.08 Shifts and saving.** Title screen, shift clock (tied to the day/night clock), shift-end summary, the death penalty (cargo and some cash), a save file (money, gear) via syscalls.
- **10.09 The police leave you alone** (added after the 10.08 play test). The officers never target you; the car waits rather than drive into you, and doesn't arrest you.
- **10.10 The shop screen.** Between shifts: an item table (price, stats), buy and equip, saved.
- **10.11 Progression content.** The vehicle ladder (moped, motorcycle, car with a body that blocks shots, van; each a row in the vehicle table plus sprites), guns (pistol → SMG, shotgun, rifle; the existing weapon code extended), armor (damage reduction), vehicle upgrades (armor, speed, package capacity), abilities (sprint/dash, and ideas like a nitro burst or smoke), bonuses and status effects (bleeding, stun, adrenaline). All data-driven.
- **10.12 The garage.** A made-up site on the map for repairs and ammo mid-shift, costing money and time.

#### Phase C: new factions and encounters
- **10.13 Road graph and AI drivers.** The generator exports the street graph; a vehicle AI follows it with A*/BFS on nodes. The police move onto it (optional, batch-tested).
- **10.14 The Bikers.** A made-up clubhouse. Pack events: 4–6 armored riders on motorcycles pick a gang, drive-by fire, peel off, circle back, and go home. Hostile to all. Batch-tested so they don't favor a gang.
- **10.15 The cartel.** An event that picks a random gang at a random time: an SUV drops 4 hitmen (low health, high damage) who hunt that gang until N kills, then get picked up. Hostile to the player.
- **10.16 The good ole boys.** A pickup-truck encounter with a mini-boss crew; hostile to all gangs and the player; beer cans stamped into `bg_buffer` along its path (the 8.04 casing/blood mechanism: `stamp_casing`/`stamp_blend`).

#### Phase D: polish (to be planned when we get there)
Balance passes with batches (and a scripted delivery bot to test job pay against risk), menus, possibly sound (SDL audio), civilians, the blog.

### Critical files and reuse

- `stage9/03_bfs.asm` is the base for 10.01. Reuse: `bfs_ensure`/`bfs_until` (per-faction fields), `flow_waypoint`, `find_nearest_enemy`, `first_in_line`, `is_spot_blocked`, `update_police` (event pattern), `update_bosses` (spawn-an-elite pattern), `stamp_casing`/`stamp_blend` (beer cans), `draw_sprite_ex` (vehicles, 16 facings), `draw_text`/`hud_fb` (menus, job board), `camera_clamp`/`view_begin` (follow cam), the `deco_hash` rule (drawing never touches the RNG).
- `stage9/tools/gen_southside.py`: add candidate home sites, fair-pair export, business and house lists for deliveries, depot/garage/clubhouse sites, and the road graph. Keep `cracks()` and the connectivity checks.
- `stage9/tools/gen_sprites.py`: player sprite, the player's vehicles (bicycle, moped, motorcycle, car, van; 16 facings each), Biker motorcycles, SUV, pickup truck, hitmen, good ole boys, beer can.
- `batch.sh`: faction-aware tally (10.02), and a pair-scoring mode (10.03).
- `stage9/tools/profile.py` for checking performance after each phase.

### Verification (every step)

- `make` builds; `HEADLESS=1` runs; 3 windowed games for you to watch.
- Refactor steps (10.01, 10.02): the fixed-seed gdb end-state `cmp` against the previous step, 12 seeds headless plus 1 windowed.
- Sim-affecting steps: 3 batches of 48 (more if a lean shows up), with no stalemates or crashes and even gangs. 10.03 must bring the home split near 50%.
- Player steps: a playable build to try, a gdb frame check of new visuals, and headless watch mode still byte-identical to the previous step (the player code doesn't touch the sim).
- Save file: write, quit, reload round trip; a corrupt or missing file falls back to a new save.

### Balance note (from the 10.07 play test)

**Job pay can't be tuned yet.** It depends on what things cost, and prices depend on how dangerous the city is. The user's order: first tune the gangsters and the random encounters (numbers, strength: Phase C and after), then build the item list and its price scaling (10.10–10.11), and only then tune delivery pay (`JOB_BASE`, `JOB_PER_PX`, `JOB_DANGER`, `JOB_TIME*` in `deliveries.asm`) against it. Until then, pay stays at 10.07's values ($30–70 a job).

### Notes from the 10.08 play test

- **More random encounters.** The war is "relatively easy to avoid": the city needs more that finds *you* (more frequent or more varied encounters, not just the gangs' fight). Phase C's Bikers, cartel and good ole boys are part of it; revisit the police and dog frequencies too.
- **The police shouldn't shoot you, and should avoid running you over** (done as 10.09).

### Open questions for later (not blocking Phase A)
Shift length (one game day, currently 4 minutes, or more?); how many hitmen kills before the cartel leaves; the good ole boys' crew size and weapons; which abilities make the first shop list; the vehicle ladder's exact tiers and prices, and whether you can shoot while riding a two-wheeler (one-handed, less accurate?); whether civilians are added (they'd give "everyone but civilians" something to mean); sound.

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
