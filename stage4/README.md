# Stage 4 — Make something move

Two programs: state-driven animation, then a proper double-buffered
architecture for it.

## Build everything

```bash
make
make clean
```

## Suggested order

1. **`01_bouncing_ball.asm`** — a bouncing square whose position and
   velocity (`ball_x`, `ball_y`, `ball_vx`, `ball_vy`) live in `.data`
   and persist across every frame. Each tick: update the state, then
   draw whatever it currently says — the state IS the simulation, the
   render is just a reflection of it. Still draws straight into the
   locked texture, same as stage3.
2. **`02_double_buffer.asm`** — the same ball and scene, but drawing
   now targets a persistent CPU-owned back buffer (`.bss`, fixed
   stride) instead of the texture directly. Once a frame, after the
   scene is fully drawn, the back buffer is blitted into the locked
   texture row by row (`rep movsb`) and the texture is immediately
   unlocked. Visually identical to `01` — the payoff is architectural,
   not visual.

## What's new here vs. Stage 3

- **Persistent, mutable state driving what's drawn:** `.data` values
  that change every tick, read by the drawing code rather than
  computed fresh from nothing each frame.
- **A real back buffer:** your own memory, fixed stride, always
  valid — decouples drawing logic entirely from SDL's lock/unlock
  timing and from whatever pitch the driver happens to report.
- **`rep movsb`:** an x86 string instruction — copies `rcx` bytes from
  `[rsi]` to `[rdi]`, advancing both pointers itself. `cld` first
  ensures it copies forward (low to high address); `std` would do the
  reverse, which is why you can't assume the direction flag is
  already what you want.
- **`istruc` / `at` / `iend`:** NASM's syntax for filling in a
  `struc`'s fields as compile-time-initialized static data — see
  `back_fb` in `02`. No runtime setup needed for state that never
  changes.

## Running under gdb

```bash
gdb ./build/01_bouncing_ball
(gdb) break main.update
(gdb) run
(gdb) print (int)ball_x
(gdb) print (int)ball_vx
(gdb) continue
(gdb) print (int)ball_x          # should differ from before by exactly vx
```

For `02`'s blit loop, the breakpoint sits at the loop's own top, so
`finish` just re-hits it instead of "finishing" anything useful — use
`continue` to step one full row-copy at a time:

```bash
gdb ./build/02_double_buffer
(gdb) break main.blit_row_loop
(gdb) run
(gdb) print $r11d                # the texture's real pitch (compare to OUR_PITCH)
(gdb) x/4xb &back_buffer         # note the & -- the symbol has no debug type
(gdb) x/4xb $r10                 # texture's row 0, before the copy
(gdb) continue
(gdb) x/4xb $r10                 # should now match back_buffer's first 4 bytes
```

## What's deliberately not here yet

- No input — the ball moves on its own, nothing reacts to the player.
  That's Stage 5.
- The bounce logic allows a small overshoot past each edge before
  reversing direction (documented in `01`'s comments) — fine for a
  demo at this velocity, not something a real physics step would
  leave in.
- Only one moving object. Stage 6 is where "per-tick state update,
  then draw" scales from one ball to fifty-plus soldiers per side —
  same structure, just looped over an array of records instead of
  four bare `.data` values.
