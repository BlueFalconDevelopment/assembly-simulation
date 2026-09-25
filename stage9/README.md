# Stage 9 — Scale

Stage 8 ended with a good-looking neighborhood, one screen big. Stage 9
is about scale: a bigger city, more soldiers, more gangs. It starts
with the city: a map four screens wide and four tall, which later
becomes a real street layout (from OpenStreetMap), compressed about
five times so the whole area fits.

## Build

```bash
make
./build/01_world             # the latest: wheel zooms (half size to 4x), W A S D pans
STAGGER=0 ./batch.sh 48      # headless, 4 games at a time
python3 tools/gen_standin.py # rebuild the stand-in map in maps/
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
