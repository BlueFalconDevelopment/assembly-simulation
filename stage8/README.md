# Stage 8 — Graphics

Stage 7 ended with a playable neighborhood: two gangs, respawns,
police, a pitbull and a miniboss, all drawn as solid squares on a
pre-drawn map. Stage 8 is about the look, one drawing-only step at a
time, each proven not to change the game (same seed → byte-identical
`soldiers`, `pickups`, `rng_state` and `ticks` as the step before).

Done: soldier sprites (8.01), detailed objects (8.02), props and
shadows (8.03), ground effects (8.04), day and night (8.05), and a
camera you can zoom and move (8.06). Stage 9 is
scale: more soldiers, more gangs, a bigger or scrolling city.

## Build

```bash
make
./build/06_camera           # the latest: wheel zooms, W A S D pans
STAGGER=0 ./batch.sh 48      # headless, 4 games at a time
```

`batch.sh`, `tools/gen_neighborhood.py` and the Makefile are copied
from stage 7.

## `01_sprites.asm` — soldier sprites

Soldiers are hand-made pixel art instead of squares, from
`stage7/16_tuning.asm`.

**The art** is text in `tools/gen_sprites.py`, one character per
pixel:

```
......BBBB......     B bandana (gang colour)   H hair
.....BBBBBB.....     S skin                    T shirt (gang colour)
.....HHHHHH.....     D shirt shadow            P pants   F shoes
.....HSSSSH.....     G chain (gold on the Big Homie, shirt otherwise)
......SSSS......     a gun   b shotgun barrel   k knife
....DTTGGTTD....
```

The generator checks every sprite is 16×16 and uses only known
letters, renders a preview sheet (`--preview`), and writes the
`SPRITE DATA` block into the `.asm` (`--write`). The letters become
palette indices, and the game picks the colours per soldier.

- **16×16, exactly the hitbox,** so what you see is what can be hit.
- **8 facing directions from 5 drawn poses** (N, NE, E, SE, S). W, NW
  and SW are E, NE and SE mirrored (`facing_pose` table). Two walk
  frames each: 10 sprites, 2,560 bytes.
- **Per-soldier colours:** shirt, shadow and bandana from the gang,
  one of three skin tones by soldier number, neutral pants and shoes.
- **The weapon in hand:** the palette gives colour only to the
  pixels of what the soldier carries. `k` for a knife, `a` for a
  pistol, `a` plus `b` for a shotgun. The others get colour 0, which
  `draw_sprite` skips.
- **Hit flash:** every pixel white, a silhouette.
- **The Big Homie:** a gold bandana and chain, keeping his health
  bar. The square gold border is gone.
- **The dog walker** uses the same sprites: purple shirt, no bandana,
  no weapon.

**Facing and the walk cycle** are drawing-only state
(`sprite_last_x/y`, `sprite_facing`, `sprite_walk`). Each frame,
`draw_soldier` compares a soldier's position with where it was last
drawn. The octant of the move is the facing (mostly sideways, mostly
up and down, or diagonal), and the pixels walked pick the frame (a
new one every 8 px). A move of more than `TELEPORT` (8) px in one
frame is a respawn, not a step, so the soldier doesn't turn to face
it. A soldier standing still keeps its facing. First sight faces the
enemy's home. Headless runs never draw, so they never touch any of
this.

**`draw_sprite`** copies 16×16 palette indices into `back_buffer`,
mirrored or not, skipping index 0 and colour 0, clipped to the field
(one unsigned compare per axis catches both edges).

**Verification:**

- For seeds 4242 and 77 (windowed, the dummy video driver), 8.01 and
  `stage7/16_tuning` ended byte-identical.
- A frame from gdb, and a 3× close-up of the fight on the avenue:
  figures facing every way, knives and pistols in hand, three skin
  tones, a white hit silhouette.

## `02_details.asm` — detailed objects

Everything else that moves, and the parked cars, as hand-made pixel
art too. The art is in `tools/gen_sprites.py`, with a preview sheet
(`--preview-objects`):

- **Weapon pickups:** a pistol, and a shotgun with a wooden stock,
  16×16, outlined in the pickups' old colours (pistol yellow, shotgun
  magenta) so they still stand out on the asphalt.
- **The police car:** 40×20, black and white: hood, trunk, windshield,
  rear window, side windows, headlights, tail lights, tyres, a white
  roof and a light bar. The red and blue swap every 8 frames by
  switching between two palettes (`cop_pal_a`/`_b`). It's drawn facing
  east; west is mirrored. The generator turns the art to face south
  (`cop_sprite_v`, 20×40), and north is that flipped upside down.
- **The dog:** a side view with ears, a nose, a red collar, a tail
  and a two-frame run (every 8 px on the leash, every 4 frames when
  loose). Brown on the leash, tan when loose. It faces the walker's
  way on the leash, and the way it moved when loose (`dog_last_x`,
  `dog_face`: drawing-only state).
- **Parked cars:** the same car art (`CAR_ART`) in each car's own
  colour, with a darker edge. `gen_neighborhood.py` imports it from
  `gen_sprites.py`, turns it for the upright cars, and emits it as
  runs of same-coloured pixels. That takes the background from 319
  rectangles to 1,869, still drawn once per game.

**`draw_sprite_ex`** replaces the fixed 16×16 `draw_sprite` (which is
now a two-instruction wrapper around it): any width (`r9d`) and height
(`spr_h`), with flags `SPR_MIRROR` (read each row right to left) and
`SPR_FLIP` (read the rows bottom to top). Flipping by reading
backwards means one copy of the art serves all four directions.

**Verification:** seeds 4242 and 77 ended byte-identical to 8.01.
Frames from gdb show the police car driving east through the fight
past a shotgun pickup, and the loose tan dog chasing a Crip across
the grass.

## `03_props.asm` — props and shadows

The neighborhood gets depth and clutter. Light comes from the top left,
so everything casts a shadow down and to the right.

**The background is three generated layers now,** drawn once by
`render_background`:

1. **Ground:** grass with 2,600 speckles (on grass only), sidewalks
   with joints every 20 px, asphalt with 1,400 grains, lot stall
   lines, lane dashes, crosswalks, lobby floors.
2. **Shadows:** rectangles that *darken* what's already there
   (`shade_rect`). Buildings (7 px), complex walls (4), cars and
   dumpsters (3), fences (2), and the exact shapes of trees (5),
   bushes (3) and lamp heads (4). They come between ground and
   objects, so nothing darkens itself.
3. **Objects:** roofs with grain and AC units (fan grilles), row
   houses with chimneys, the cars, dumpsters (lids, hinge, handles,
   wheels, rust), a chain-link fence round the parking lot and
   wooden rails elsewhere, 15 trees with leafy canopies, 8 bushes,
   and 21 streetlights along the sidewalks.

That's about 11,700 rectangles, still drawn once per game. The
streetlight positions are written out as `street_lamps` for the
night lighting in 8.05. The prop art (tree, bush, dumpster, AC unit,
lamp) is in `gen_sprites.py`. The layout, and a new check that every
tree and bush is on open ground and every lamp is on a sidewalk and
off the road, are in `gen_neighborhood.py`. The check caught a bush
on the avenue's sidewalk. The speckles come from a fixed seed, so
every build is the same.

**`shade_rect`** darkens a rectangle to 5/8 brightness, all three
channels at once: `(p >> 1) & 0x7F7F7F` is half of each, and
`(p >> 3) & 0x1F1F1F` an eighth. The masks drop the bits that slide in
from the channel above. Alpha is put back to 0xFF.

**Moving shadows:** `draw_moving_shadows` runs before any sprite is
drawn, so a shadow never darkens a neighbour. Each visible soldier
gets a small oval at its feet (7, 11, 11, 7 px wide rows), and there
are shadows for the walker, the dog, and the police car (its whole
shape, offset 3). The first version drew a plain 11×4 box, which
looked boxy. It also drew a shadow in the "off" half of a
respawning soldier's protection blink, which left brown dashes on
the lobby floor with no soldier above them. Now the shadow blinks
with the soldier.

**Verification:** seeds 4242 and 77 ended byte-identical to 8.02, on
the final binary. Frames from gdb show the fight on the avenue, each
figure with its shadow, with streetlights, a bush and the parking lot
behind.

## `04_ground.asm` — ground effects

The street remembers the fight:

- **Blood:** a splat where a bullet or blade lands on a hit (four
  hand-drawn 12×12 shapes).
- **Shell casings:** by the shooter's feet for every pistol shot
  (two brass pixels) and shotgun shot (a red shell with a brass
  base). The police car leaves them too.
- **A death animation:** a killed soldier shows the white hit flash,
  then lies on the ground (`dead_sprite`, in gang colours, half of them
  falling the other way) for `DEATH_LIE` (36) frames, then is gone,
  leaving a blood pool (two 16×16 shapes). `spawn_effect`'s
  `death_linger` grew by `DEATH_LIE` to make room for the fall.
  Arrested soldiers just vanish: the police took them.

**Stamped into the background.** The splats, casings and pools are
written straight into `bg_buffer`, which is copied to the screen
every frame, so they stay for the rest of the game at no cost per
frame. `stamp_blend` mixes blood 50/50 with what's there (half of
each channel of both, masked and added), so the ground's texture
shows through. Casings are solid.

**Drawing only, and it had to be designed that way.** The splat
shape and the casing scatter need randomness, and the obvious source
(`rng_next`) would change the game: one extra draw shifts every
random number after it. So `deco_hash` scrambles a position and the
frame count instead. The splat is stamped the frame a hit's tracer
arrives (`.start_flash`), the casing on a shot's first frame, and the
pool when a dead soldier's `death_linger` runs out. All three
happen in rendering, which headless runs never do. Fallen soldiers
don't get the standing soldiers' foot shadow.

**Verification:** seeds 4242 and 77 ended byte-identical to 8.03.
Frames from gdb at 0:25 and at the end of a game. By the end, the main
battle zone is densely marked with blood: a lot, but it stays where
the fighting actually was.

## `05_night.asm` — day and night

Time passes during a game. A whole day takes `DAY_TICKS` (14,400
ticks, 4 minutes), so a one-minute game covers about six hours. Some
games start in sunshine and end in the dark, some go from night into
dawn. The scoreboard shows the time: `NEIGHBORHOOD 0:15 10:30 PM`.

- **Ambient light** comes from keyframes (night until 5:00, dawn at
  6:30, day 8:00 to 5:30 PM, dusk at 7:00 PM, night from 8:30 PM),
  interpolated per channel. Day is untouched, dusk turns orange, and
  night is dark blue.
- **At night the light comes from:** the 21 streetlights (they switch
  on when ambient drops below about three-quarters of daylight), the
  gangs' lit lobbies with light spilling out of their doors (the
  generator now writes out `door_lights`), the police car's light bar
  and two pools of headlight ahead of it, and muzzle flashes (the
  first two frames of every shot).
- **Tracers and sparks are drawn after the lighting,** so gunfire is
  bright in the dark.
- **Starting time:** scrambled from the game's seed (`deco_hash` of
  `game_seed`), or `TIME=h` (0–23) to pick one: `TIME=21 ./build/05_night`.

**How it's drawn** (`light_scene`, once a frame, windowed only):

1. **The light map:** one byte per 2×2 pixels (640×360), cleared to 0.
   Each light adds a round falloff kernel, `peak × (1 − d²/r²)` (no
   square root), saturating at 255. Three kernels are built once:
   lamp, mid and small. A lit lobby is `light_rect`, a flat add over
   its floor.
2. **The tables:** for each light level L (0–255) and channel, the
   scale is ambient + (lamp colour − ambient) × L / 255, but never
   darker than ambient, so a lamp at noon does nothing. That's 768
   numbers, rebuilt each frame from the time of day.
3. **The pass:** every field pixel is split into R, G and B, each
   multiplied by its table entry for the pixel's light level, and
   put back together. At full daylight the whole pass is skipped.

**Cost:** a night game and a noon game (same seed, 4,452 ticks each)
took 71.7 s of wall time each, so the pass fits inside the 16 ms
frame.

**Verification:** seed 4242 at night and seed 77 at dusk ended
byte-identical to 8.04. Frames from gdb at 10:30 PM (pools of
lamplight on the sidewalks, the lobbies glowing, dark blue everywhere
else) and at 7:30 PM (dusk orange, the lamps just coming on).

## `06_camera.asm` — zoom and pan

- **The mouse wheel** zooms in and out over six steps (1×, 1.25×,
  1.5×, 2×, 2.7×, 4×) toward whatever is under the cursor: the
  field point under the mouse stays under the mouse.
- **W A S D** move the camera while zoomed in: `PAN_SPEED` (8)
  screen pixels a frame at any zoom, clamped to the map's edges.
- **The scoreboard strip** stays put, full size.

**How:** the frame is still drawn whole, 1280×744, exactly as before.
The camera is only an `SDL_Rect` (`cam_src`): which part of the field
`SDL_RenderCopy` scales up to fill the window. The scoreboard is a
second `SDL_RenderCopy`, 1:1. SDL's default scaling is nearest
neighbour, which keeps the pixel art crisp. Zooming around the
cursor works out the field point under the mouse
(`cam + mouse × view / screen`), changes the view size from the
`zoom_view_w` table (height is 9/16 of it), and moves `cam` so that
point is back under the mouse. W A S D come from
`SDL_GetKeyboardState`, an array SDL keeps up to date. The wheel is
the `SDL_MOUSEWHEEL` event's `y`.

Nothing about the game or the drawing changes, and headless runs
never see it.

**Verification:** in gdb, on a windowed game on the dummy driver:
three wheel clicks in gave a 640×360 view (2×), ten out clamped
back to 1280×720, five in gave 320×180 (4×), and faking the D key
held in SDL's keyboard array moved the view 2 field pixels a frame
at 4× (8 screen pixels). Seed 77 ended byte-identical to 8.05. What
the zoomed window looks like can only be checked by using it.
