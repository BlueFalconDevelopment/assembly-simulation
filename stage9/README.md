# Stage 9 — Scale

Stage 8 ended with a good-looking neighborhood, one screen big. Stage 9
is about scale: a bigger city, more soldiers, more gangs. It starts
with the city: a map four screens wide and four tall, which later
becomes a real street layout (from OpenStreetMap), compressed about
five times so the whole area fits.

## Build

```bash
make
./build/03_bfs               # the latest: wheel zooms (half size to 4x), W A S D pans
STAGGER=0 ./batch.sh 48      # headless, 4 games at a time
python3 tools/gen_southside.py  # rebuild the south side map in maps/ (15 s)
python3 tools/gen_standin.py    # rebuild 01's stand-in map
```

`batch.sh`, the Makefile, `tools/gen_neighborhood.py` and
`tools/gen_sprites.py` are copied from stage 8. The Makefile also
rebuilds when anything in `maps/` changes.

## `01_world.asm` — a map bigger than the window

From `stage8/06_camera.asm`. The map is 5120 × 2880, sixteen screens.

**The stand-in map.** The real map needs its own generator, so this
step uses a stand-in: stage 8's neighborhood tiled 4 × 4
(`tools/gen_standin.py`, which imports `gen_neighborhood.py` and
dresses each tile with it). The streets line up across tile edges, so
it's one street grid: four avenues, eight cross streets. Of the 32
apartment complexes, the gangs live in two, the west complex of tile
(1, 1) and the east one of tile (2, 2), about equally far from the
middle. The other 30 are plain buildings. The 64 pickups lie in the
middle four tiles. The police drive all 24 lanes, and the dog walker
uses all 8 avenue sidewalks, each from off the map. The generator
checks the whole map as before, on a 569 × 320 grid: every walkable
cell connected, the lobbies packable, pickups on open ground.

**The map moved out of the `.asm`.** Stage 8's background was about
12,000 lines of rectangles in the source. Sixteen screens make
200,000, too many for NASM text. The generator now writes two
files:

- `maps/standin.inc`: `MAP_W`/`MAP_H`, the map's name, walls, props,
  lobbies, pickups, lamps, doorways, police routes and dog walks, as
  NASM data, and the background's counts. `%include`d near the top
  of the `.asm`, so every size (the grid, the blockmap) follows it.
  The police routes and dog walks moved here from the hand-written
  data: they depend on the map.
- `maps/standin_bg.bin`: the three background layers (ground,
  shadows, objects) as raw little-endian dwords, pulled in with
  `incbin "maps/standin_bg.bin", offset, length`. It assembles in
  0.2 s.

The layers are laid down one at a time across the whole map (all
the ground, then all the shadows, then all the objects), so a shadow
that falls over a tile edge isn't painted over by the next tile's
grass.

**Drawing only what the camera sees.** The whole map is still drawn
once, into `bg_buffer` (5120 × 2880, 59 MB), and blood and casings
are still stamped into it, so they last. But each frame:

1. `camera_pan` moves the camera, then `view_begin` copies the part
   of `bg_buffer` under it into `back_buffer`, row by row.
2. Everything else draws into that copy: shadows, pickups, soldiers,
   the police car and dog, the lighting, the effects.
3. `SDL_UpdateTexture` sends only the drawn part to the texture,
   and `SDL_RenderCopy` scales it to the window.

So the drawing routines work in map coordinates, and the buffer
does the translating. `FrameBuffer` has an origin (`ox`, `oy`): the
map point at its top left. `set_pixel`, `fill_rect` and `shade_rect`
subtract it first, then clip to the buffer as before. `back_fb`'s
origin and size follow the camera every frame; `bg_fb`'s origin is
0, 0. `draw_sprite_ex`, which writes to `back_buffer` directly, does
the same with `back_fb`'s values. The light map covers the view, not
the map: `stamp_light` and `light_rect` subtract the origin too
(`light_rect` never had to clip before; the lobbies were always on
screen), and the pass through the light tables runs over the view's
pixels only.

**Zooming out.** Because only the view is drawn, the view can be
bigger than the window: two new zoom steps out, to 1920 and 2560
pixels wide (a quarter of the map), which SDL shrinks to fit. The
game starts at 1x, looking at the middle of the map. `back_buffer`
is sized for the biggest view (2560 × 1440). The zoomed-out view is
four times the drawing of 1x, and still ran at 60 fps at night, on
SDL's software renderer.

**The scoreboard** has its own buffer (`hud_buffer`, 1280 × 24),
`hud_fb` and texture, since it no longer sits under the field in one
buffer. `draw_text` and `draw_hud` draw there, at y 0.

**What the game noticed.** Only its edges: every "off the field"
test is against the map's size now (soldier movement clamps, the
walkable grid, the blockmap, the police car leaving, the dog). The
pathfinding grid is 569 × 320, 16 times 06's, and `build_fields`
still builds three full flow fields every tick. A headless game
takes 7–9 s instead of 0.85 s, and runs longer (the gangs start
2,000 px apart instead of 900).

**The recipe for a frame changed.** There's no `SDL_LockTexture`
now. Break on `SDL_UpdateTexture` (it's called twice a frame: the
view, then the scoreboard), and dump `back_buffer` as 2560 × 1440
RGBA; the view is its top-left `w` × `h`. gdb can't set `cam_src` by
name (no type information), so use
`set {int[4]}&cam_src = {x, y, w, h}` and `set {int}&zoom_step = n`.

## `02_southside.asm` — the south side

`01_world.asm` on the real map. The only code change: the camera
starts where the map says (`MAP_CAM_X`, `MAP_CAM_Y`, between the
homes). Everything else is the map, from `tools/gen_southside.py`.

**The data.** `maps/southside_osm.json` is a one-time OpenStreetMap
snapshot of the play area, a rectangle bounded by four roads (SW Lee
Blvd, SW Sheridan Rd, SW Bishop Rd, S Railroad St), about 3.2 × 1.6
km. It's stripped to what the generator uses: road types and street
names, building outlines, land use, parks, pitches, playgrounds,
school grounds, parking, streams. Coordinates are metres east and
south of the corner of Lee and Sheridan, not latitude and longitude.
OpenStreetMap data is © OpenStreetMap contributors, under the ODbL
(https://www.openstreetmap.org/copyright); the snapshot and the map
files carry that line.

**Compression.** The map is 5120 × 2608: about 1.56 px a metre,
where the game's own scale is about 9. So distances shrink and
things don't. Every street stays where it really is, but at the
game's widths (60 px main roads, 36 px residential streets, 8 px
sidewalks), and a block holds four to six houses instead of a
dozen. The four boundary roads sit 48 px in from the map's edges, so
they're whole. Alleys and driveways are left out: at this scale an
alley leaves strips too thin for a house on either side.

**What's real and what's made up.**

- *Real:* the streets, the diagonal road, the expressway, the
  buildings the data has (mostly the commercial strip along Lee:
  each one's box, trimmed back where our wider roads now run over
  it; 76 of the 162 survive, the rest fall in the made-up areas
  below or are too small once trimmed), parks, playgrounds, school
  grounds, parking lots, streams.
- *Generated along the real streets:* 595 houses, two rows back
  to back in each block, facing their streets, with gable roofs and
  chimneys. Parked cars at the kerb, trees and bushes in the yards,
  streetlights on the sidewalks.
- *Made up, where the data is empty but the area isn't:* the big park
  in the south-west (ball fields, paths, a pond, a shelter, a
  parking lot, lots of trees), the airport in the middle south
  (fenced, on both sides of the diagonal road: a terminal and parking
  in the triangle north-west of it; a runway, taxiway, apron, five
  hangars and five small planes south-east of it), and wrecker lots
  in the south-east (fenced gravel yards of rusty junk cars, some
  without wheels, with a lane from the gate straight through).
- *The homes* are made up too: two apartment complexes at street
  corners (`HOMES` in the generator), SW 20th St & Monroe Ave in
  the west and SW 9th St & Jefferson Ave in the east, about 2,400
  px apart. A single block is too small for 50 soldiers' lobby, so
  each complex is two blocks joined across the second street (that
  piece of street goes), with the sidewalks round them. Six doors.
- *The expressway* is fenced on both sides, open where a road
  crosses it.

**Low cover.** Parked cars, junk cars, every fence and the planes'
fuselages are props: they block walking, not bullets. Soldiers can
walk under a plane's wing.

**Police and the dog.** A police route is a lane on a road that
runs straight across the whole map (real roads drift, so up to 40 px
of drift is allowed and the lane follows the median). Seven roads
qualify: Lee and Bishop east-west, Sheridan, 16th, 15th, 11th and
Railroad north-south, 14 routes. The dog walker uses the sidewalks
of Lee and Bishop.

**How the generator builds it.** The ground is drawn as an image
(PIL: roads as thick polylines, areas as polygons, zones as masks),
then turned into rectangles: runs of one colour in each row, merged
downward while the rows below repeat them (188,000 rectangles).
Everything that stands on the ground is placed against an occupancy
mask, so houses, lots, trees and lamps don't overlap each other or
the roads. Fences are 4 × 4 blocks along a line, merged into runs.

**Checks.** The same as before on the 569 × 289 grid, with one
change: small pockets of walkable ground nobody can reach are
allowed (the map has one, 4 cells, a corner nobody can get to), but
every pickup is placed in the main connected area and both lobbies
must be in it. Both lobbies pack 50 soldiers 300 times. And, since
the first batch, no cracks (below).

**What the batches found.** Four rounds of 144 games, each fixing
what the last one showed:

1. *A stalemate: cracks.* Replaying its seed (it's in the stalemate
   line) showed two Crips with knives standing in a 19 px gap between
   two houses, and nobody able to reach them. A soldier (16 px) fits
   in a gap that narrow, but the pathfinding grid can't see into it:
   a cell is walkable only if a 24 × 24 window on its 9 px lattice is
   clear, which a gap is only sure to hold from 32 px. When a
   soldier's own cell has no distance, `flow_waypoint` steps to any
   neighbouring cell that has one, which is why stage 8's parking lot
   (cars 20 px apart, but only 20 px long) never trapped anyone. A gap
   as long as a house has no such neighbour anywhere near, and the
   side step can't get out.
2. *The west home won 86%, then (pickups mirrored, below) 78%.*
   Sampling a game every 400 ticks showed most of the east gang
   standing in a line for thousands of ticks, with knives: a 40 px
   passage between two houses holds one lane of cells, and an armed
   teammate going the other way (to the fight) blocked it for good.
3. So the generator plugs every gap between two solid things (or one
   and the map's edge), side by side or one above the other, that's
   16 to 47 px wide with nothing else in it: 48 px is two lanes of
   cells. Deliberate openings aren't gaps: a complex's doors, fence
   gates. A gap next to a car loses the car (a hedge there could
   close a street); any other gap gets a hedge, low cover like a
   fence. It repeats until there are none, and the checks assert
   that. The hedges read as what they'd be anyway: hedges between
   yards, filling the back gardens. The wrecker lots are laid out to
   the same rule: cars 8 px from the fences and 4 px apart, aisles
   48 px, and one empty car slot as the lane from the gate.
4. *Still 62%: a crowd.* About 30 of the east gang's knife carriers
   round the last gun on their side of the map, which lay *behind*
   their home, with a teammate who'd just picked one up stuck in the
   crowd going the other way.

**Pickups.** The last two findings shaped where the guns go: 80 of
them in 40 pairs, each pair mirrored through the point halfway
between the two lobbies, and only in the box between the homes. So
whatever lies near one home lies as near the other (39 of the 80 are
nearer the west home by walking distance, and the two homes' total
walking distances to them are within 2%), and a knife carrier going
for a gun always goes toward the fight.

**Where it stands.** No stalemates since the first round, and the
two gangs even (Crips 74 of 144). But the west home still wins about
62% (89 and 91 of 144 in the last two rounds, z ≈ 3 each). The walk
between the lobbies is 244 cells, and the point where the walking
distance from each is equal is x ≈ 1,710; the fighting settles a
little west of it, around x 1,500–1,750, near the west home. Nothing
there is jammed any more: it looks like the lie of the land. It's
the first map that isn't symmetric, and the homes are the obvious
thing to move.

## `03_bfs.asm` — five times faster headless

`02_southside.asm` with the same games, byte for byte: for 12 seeds
headless (including the old stalemate seed) and one windowed, the end
state (`soldiers`, `pickups`, `rng_state`, `ticks`) is identical to
02's. A headless game takes 1.6 s instead of 8.3 s, and a 48-game
batch 22 s instead of about 2 minutes.

**Profiling without perf.** `perf` needs `perf_event_paranoid`
lowered (it's 4 here), and gdb can't attach to a running game
(`ptrace_scope` 1). But gdb can stop a game it started itself.
`tools/profile.py` runs the game under gdb, has a shell loop send it
SIGINT every 20 ms, and counts which function each stop lands in:

```bash
HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/03_bfs
```

Two things that got in the way: `handle SIGINT stop noprint` means *no
stop* in gdb (`noprint` implies `nostop`), and a Python thread can't
do the ticking, because gdb's Python holds its lock while the game
runs. On 02 it said: 92% in `bfs_run`. Three flow fields a tick, each
searched over the whole map, 120,000 walkable cells.

**No divide.** For every cell it took off the queue, `bfs_run`
divided the index by `GRID_W` for the column and row (to keep the
neighbours inside the grid), then read `walkable[]` once per
neighbour. `walkable[]` never changes during a game, so that's
worked out once now: `build_nbrs` gives each cell a byte in
`bfs_nbrs` with a bit for each neighbour (right, left, down, up)
that's inside the grid and walkable. The search reads one byte per
cell. That alone was only 17%: at about 4 ns a cell, it's memory it
waits on, not arithmetic.

**Search only as far as needed.** The real cost was searching the
whole map when nobody needs most of it. The only reader of a field is
`flow_waypoint`, called only when a wall is in the way of a soldier's
direct route, and it only uses the neighbours of the soldier's cell
that are *strictly closer* than the cell itself. A breadth-first
search gives every cell at distance *d* its distance before any cell
at *d* + 1. So once the soldier's own cell has its distance, every
cell `flow_waypoint` could use has its own.

So each field's search can stop and carry on. `build_fields` only
seeds the three searches (each field has a `BfsState`: its own queue,
where it got to, and how far it's queued), and `flow_waypoint` calls
`bfs_ensure` first, which carries that field's search on until the
soldier's cell has its distance. A soldier standing in a cell that
isn't walkable never gets one (the search only enters walkable cells),
and `flow_waypoint` then uses every walkable neighbour that has a
distance, so for that soldier it carries on until all of those have
theirs. Carrying on reaches the cells in the same order, with the same
distances, as one search run to the end, so whatever is read is the
same.

A search that stops early has to be done this way, on demand, rather
than by working out beforehand who'll need what: the Big Homie is
placed by `update_bosses`, after `build_fields`, and then walks in the
same tick. Asking when he walks gets it right without knowing.

Since most searches now stop early, `bfs_begin` clears only the cells
the last search reached (all of them are in its queue) instead of all
three fields, 1 MB a tick. The first time, it clears the whole field.

The search is still the biggest cost (about 60%): early in a game the
gangs are 244 cells apart, so their searches go a long way.
