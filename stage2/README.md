# Stage 2 — Open a literal window

Three programs, each building on the last: open a window, clear it
and handle quit, then pace the loop properly. This is the first
stage that calls into a real dynamic library (SDL2) instead of
making raw syscalls — see the big comment block at the top of `01`
for why the entry point (`main` instead of `_start`) and the linker
(`gcc` instead of `ld`) both change here.

## Build everything

```bash
make            # builds every .asm into build/, linking against SDL2
make clean
```

## Suggested order

1. **`01_open_window.asm`** — the minimum to prove the link works:
   `SDL_Init` → `SDL_CreateWindow` → `SDL_CreateRenderer`, hold for 3
   seconds, tear down. No event handling, no error checking — that's
   what `02` adds.
2. **`02_clear_and_quit.asm`** — a real (if inefficient) main loop:
   drains `SDL_PollEvent` every frame, quits cleanly on the window's
   close button, clears to a solid color each frame, and actually
   checks SDL's return codes. Spins the CPU on purpose — see the
   comment at the top for why that's left in deliberately.
3. **`03_frame_timed_loop.asm`** — the fix: measures elapsed time
   with `SDL_GetTicks` and sleeps the remainder of a ~16ms budget
   with `SDL_Delay`, targeting ~60 FPS instead of pegging a core.
   Also updates one piece of real per-frame state (a frame counter)
   and uses it to animate the clear color, so you can visually
   confirm frames are actually advancing.

## What's new here vs. Stage 1

- **Entry point:** `global main`, not `global _start`. `gcc` links in
  glibc's real startup code, which does setup work (TLS, etc.) SDL2
  needs before calling `main`.
- **Linking:** `gcc -no-pie build/x.o -o x $(pkg-config --libs sdl2)`
  instead of bare `ld`. `gcc` is still just acting as a linker driver
  here — there is no C source anywhere in this project. The
  `-no-pie` matters: modern Ubuntu's `gcc` defaults to building a
  Position-Independent Executable, which needs every external-symbol
  reference to go through the GOT/PLT with special relocation forms.
  Our `call SDL_Init`-style direct calls don't use those, so linking
  as PIE fails with `relocation ... can not be used when making a
  PIE object`. `-no-pie` builds an old-style fixed-address executable
  instead, matching the direct-call style used throughout Stage 2.
- **Calling external library functions:** every SDL function is
  declared `extern` and called with `call`, args placed in
  `rdi, rsi, rdx, rcx, r8, r9` exactly per stage1/04. No headers, no
  bindings — just knowing each function's real C signature.
- **Opaque pointers:** `SDL_Window*` and `SDL_Renderer*` are treated
  as pure opaque 8-byte handles — we never look inside them, just
  pass the pointers back to SDL. `SDL_Event` is the one struct we DO
  read from directly, and only its first 4 bytes (the `type` field,
  which is first in every variant of the union).

## Running under gdb

SDL2 doesn't fork or spawn extra processes for a single window, so
ordinary breakpoints work fine:

```bash
gdb ./build/01_open_window
(gdb) break SDL_CreateWindow
(gdb) run
(gdb) finish                 # runs to completion of SDL_CreateWindow
(gdb) print/x $rax           # the SDL_Window* it returned (libSDL2 has no
                              # debug symbols, so `finish` won't auto-print
                              # "Value returned" — read rax directly instead)
```

For NASM local labels (`.loop`, `.cleanup_all`, etc.) inside a
function, gdb usually wants the qualified form: `break main.cleanup_all`
rather than `break .cleanup_all`.

`watch <symbol>` is worth knowing for `03` — it's a data watchpoint,
not a breakpoint: gdb stops the instant the given memory location
changes, anywhere in the program, without needing to guess where to
break. Try `watch frame_count`.

## Checking CPU cost (the point of 02 vs 03)

```bash
./build/02_clear_and_quit &   # then: top   -> note the CPU%, then close the window
./build/03_frame_timed_loop & # then: top   -> note the CPU%, then close the window
```

Same visual result, very different cost. That gap is what "frame
timing" actually buys you, made concrete instead of taken on faith.
