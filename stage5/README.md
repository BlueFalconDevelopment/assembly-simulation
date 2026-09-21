# Stage 5 — Let the player touch it

Two programs: continuous keyboard-driven movement, then mouse clicks
that permanently add to the scene — the point where "scene" starts
becoming "sim."

## Build everything

```bash
make
make clean
```

## Suggested order

1. **`01_keyboard_move.asm`** — a player-controlled square, moved
   with the arrow keys via `SDL_GetKeyboardState`, clamped (not
   bounced) at the screen edges. Same scene, same back-buffer
   architecture as stage4/02 — only the thing driving the state
   changed, from a fixed velocity to live input.
2. **`02_mouse_click.asm`** — adds left-click-to-place: each click
   appends a permanent obstacle at that position to a growing list in
   `.bss`, drawn every frame from then on. This is the actual "input
   changes the sim" milestone — a direct rehearsal for Stage 6's
   weapon pickups spawning onto the map the same way.

## What's new here vs. Stage 4

- **Two different ways to read input, on purpose:**
  `SDL_GetKeyboardState(NULL)` returns a *stable, live-updating*
  snapshot pointer — call it once, keep reading through it forever.
  `SDL_PollEvent` is a *queue you drain* — one discrete event at a
  time, needed every frame, and the only way to see one-off things
  like a click or the window close button. Mixing these up (polling
  for held-key state, or snapshotting for a one-off click) is a real
  category of bug, not just a style choice.
- **Reading a specific event's payload:** once `event.type` says
  `SDL_MOUSEBUTTONDOWN`, the SAME buffer's bytes at fixed offsets
  (looked up via a C probe against the real header, not guessed) are
  the button number and the click's x/y — the same "trust the
  offsets, not your memory" discipline as stage3's pixel format.
- **Input that mutates persistent state, not just reads it:** the
  obstacle list only grows, and once something is added it's real —
  every future frame draws it. That's a different thing from moving a
  value that was already there.

## Running under gdb

Simulating a held key without a real keyboard, by poking
`SDL_GetKeyboardState`'s array directly:

```bash
gdb ./build/01_keyboard_move
(gdb) break main.update
(gdb) run
(gdb) print (int)player_x
(gdb) set *(char*)($r15 + 79) = 1     # 79 = SDL_SCANCODE_RIGHT
(gdb) continue
(gdb) print (int)player_x             # should have advanced by MOVE_SPEED
```

Watching a real click land, by breaking where it's handled and
clicking in the actual window while gdb is running:

```bash
gdb ./build/02_mouse_click
(gdb) break main.handle_click
(gdb) run
# click somewhere in the window
(gdb) next 16
(gdb) print *(int*)&obstacle_count
(gdb) print *(int*)&obstacles              # x of slot 0
(gdb) print *(int*)((char*)&obstacles+4)   # y of slot 0
```

## What's deliberately not here yet

- No collision between the player and the obstacles the player just
  placed — they're purely visual right now. Stage 6 is where contact
  between things actually matters (pickups, weapon range, hits).
- The obstacle list only grows (capped at `MAX_OBSTACLES = 32`,
  silently ignoring clicks past that) — no removal. `02`'s closing
  exercise asks you to sketch, not implement, what removing an
  element without leaving a gap would take — that's a real problem
  Stage 6 has to solve when a soldier dies mid-iteration.
- Left-click only. Right-click, scroll, and mouse *motion* (as
  opposed to clicks) all use the same event-struct-offset technique,
  just with different offsets — not needed for anything this stage
  asks for.
