# Stage 8 — Graphics

Stage 7 ended with a playable neighborhood: two gangs, respawns,
police, a pitbull and a miniboss, all drawn as solid squares on a
pre-drawn map. Stage 8 is about the look, one drawing-only step at a
time, each proven not to change the game (same seed → byte-identical
`soldiers`, `pickups`, `rng_state` and `ticks` as the step before).

Planned: soldier sprites, ground effects (blood, casings, a death
animation), vehicles and props, then day and night. Stage 9 is
scale: more soldiers, more gangs, a bigger or scrolling city.

## Build

```bash
make
./build/01_sprites
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
