# Stage 3 — Draw a scene by hand

Three programs, each building on the last: a raw pixel buffer with
byte offsets computed by hand, reusable `set_pixel`/`fill_rect`
functions built around a `struc`-defined `FrameBuffer`, and a
`draw_line` (Bresenham) that composes with the rest into the first
real scene.

## Build everything

```bash
make            # builds every .asm into build/, linking against SDL2
make clean
```

## Suggested order

1. **`01_pixel_buffer.asm`** — locks a streaming `SDL_Texture`,
   writes every pixel's 4 bytes (R,G,B,A) by hand using
   `row * pitch + col * 4`, unlocks it, and copies it to the screen.
   No functions yet, no struct — just the raw formula, proven with a
   gradient that visibly rotates if row/col ever got swapped.
2. **`02_rect_plot.asm`** — introduces a `FrameBuffer` struct (via
   NASM's `struc`/`endstruc`) to bundle the buffer pointer, pitch,
   and bounds into one pointer argument, then builds `set_pixel`
   (bounds-checked single write) and `fill_rect` (clipped rectangle
   fill) as real reusable functions. Draws a sky + ground scene.
3. **`03_line_and_scene.asm`** — adds `draw_line` (Bresenham's
   algorithm, integer-only), which calls `set_pixel` once per step —
   this exact line-stepping approach is what Stage 6 reuses for
   line-of-sight checks. Composes sky + ground + a jagged horizon +
   two obstacle rects into the stage's actual deliverable: a real
   static scene.

## What's new here vs. Stage 2

- **Raw pixel buffers:** `SDL_CreateTexture` with
  `SDL_TEXTUREACCESS_STREAMING`, then `SDL_LockTexture` /
  `SDL_UnlockTexture` each frame to get direct read/write access to
  the pixel memory — no more `SDL_SetRenderDrawColor` /
  `SDL_RenderClear` doing the work for you.
- **The offset formula:** `address = base + row * pitch + col * 4`.
  `pitch` is NOT always `width * 4` — always use the value SDL
  reports, never assume it.
- **`struc`/`endstruc`:** NASM's way of naming byte offsets into a
  block of memory. There's no real struct type at the machine level
  — just a pointer and the promise that you'll interpret the bytes
  at those offsets consistently. This is exactly the pattern Stage
  6's per-soldier records will use.
- **Bounds checking as memory safety, not just correctness:** writing
  past a locked texture's buffer is real corruption (see `01`'s
  "write past the buffer on purpose" exercise), which is why both
  `set_pixel` and `fill_rect` clip/reject out-of-range writes.
- **A function with its own stack frame full of named locals:**
  `draw_line` needs ~9 values to survive repeated calls to
  `set_pixel`. Rather than fight for callee-saved registers, it puts
  each value in a named stack slot (`L_X0 equ -16`, etc.) — memory
  survives a `call` for free, which stage1/04's `print_uint` already
  showed you in miniature.

## Colors: the AABBGGRR hex trick

Every color is packed as a single little-endian `Uint32` such that
the bytes in memory come out `R, G, B, A` (required by
`SDL_PIXELFORMAT_RGBA32`). Since a little-endian 32-bit store writes
its low byte to the lowest address:

```
value = R | (G << 8) | (B << 16) | (A << 24)
```

Written as a hex literal `0xAABBGGRR`, the digit *pairs* read left to
right as A, B, G, R — which is why the constants in `02`/`03` look
"backwards" from RGBA order at a glance. Full worked example is in
`02`'s comments next to `COLOR_SKY`.

## Running under gdb

Same tools as before (`break`, `run`, `continue`, `print`, `next`,
`watch`), applied to new things worth checking:

```bash
gdb ./build/01_pixel_buffer
(gdb) break main.col_loop
(gdb) continue                    # runs past setup, hits inside the fill loop
(gdb) print $ecx                  # current column
(gdb) print $edx                  # current row
(gdb) next 3                      # step past the offset calc
(gdb) print $r8d                  # should equal row*pitch + col*4 exactly
```

For `draw_line`'s stack locals, read them as typed pointers, not with
a bulk `x/Ndw` dump — each local is an 8-byte-aligned slot but only
its low 4 bytes are ever written, so a raw word dump interleaves real
values with untouched garbage:

```bash
(gdb) break draw_line.plot_loop
(gdb) run
(gdb) print *(int*)($rbp-16)      # x0
(gdb) print *(int*)($rbp-24)      # y0
```

## What's deliberately not here yet

- Nothing moves — this is a static scene. Stage 4 is where per-frame
  state actually changes something on screen.
- `fill_rect`'s clipping assumes `x >= 0` and `y >= 0` (only the
  far/bottom edges are clipped) — documented as a precondition in its
  header comment, not a general-purpose rect clipper.
- The horizon and obstacles are hardcoded call-by-call, not
  data-driven from an array of points — reasonable for "the first
  real scene," not yet needed for anything this stage asks for.
