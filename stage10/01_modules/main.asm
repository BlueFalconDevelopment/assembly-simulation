; ============================================================
; Stage 10.01 — Modules
;
; 9.03 (stage9/03_bfs.asm), split into modules: the first step of
; stage 10, turning the simulation into a game (see the plan's
; "Stage 10+" section). The game is about to grow past 10,000 lines;
; one file per concern is easier to read, change and review.
;
; This file is the program's spine: the externs, then the modules,
; %included in exactly the order their code stood in 9.03. The order
; IS the program (NASM lays code and data down in the order it reads
; them), so 10.01 is the same machine code as 9.03, byte for byte:
; the .text and .data sections of the two builds compare equal, apart
; from the window title's "10.01".
;
; From here on, each step is a folder (NN_name/: main.asm and its
; modules), copied from the step before, so every step still builds
; on its own. The map (maps/) and the tools (tools/) are shared.
;
; Where things are:
;   constants.asm   constants, the map include, structs, colours
;   data.asm        settings, messages, counters, events, the font
;   sprites.asm     the pixel art (tools/gen_sprites.py --write)
;   tables.asm      palettes, camera, day/night keys, flow directions
;   bss.asm         grids, fields, buffers, soldiers, pickups
;   game.asm        main (the loop), the RNG, spawning, settings
;   pathfinding.asm the walkable grid, the flow fields
;   hud.asm         the font renderer, the scoreboard
;   respawn.asm     rules from the environment, respawns
;   background.asm  the pre-drawn map, shadows
;   camera.asm      the view: copy, zoom, pan
;   lighting.asm    day and night
;   ground.asm      blood, casings, pools
;   draw_sprites.asm sprites, soldiers, the walker
;   bosses.asm      the Big Homie
;   events.asm      the police, the dog
;   ai.asm          targets, weapons, blockmap, line of sight,
;                   update_soldiers, first_in_line
;   results.asm     the win line
;   effects.asm     attack effects
;   win.asm         check_win
;   primitives.asm  set_pixel, fill_rect, draw_line
; ============================================================
default rel
global main

extern SDL_Init
extern SDL_CreateWindow
extern SDL_CreateRenderer
extern SDL_CreateTexture
extern SDL_UpdateTexture
extern SDL_RenderCopy
extern SDL_RenderPresent
extern SDL_PollEvent
extern SDL_GetTicks
extern SDL_Delay
extern SDL_DestroyTexture
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit
extern SDL_GetKeyboardState
extern SDL_GetMouseState
extern getenv
extern atoi
extern strtoull

; ---- the modules, in order (10.01): the order is the program ----
%include "constants.asm"
%include "data.asm"
%include "sprites.asm"
%include "tables.asm"
%include "bss.asm"
%include "game.asm"
%include "pathfinding.asm"
%include "hud.asm"
%include "respawn.asm"
%include "background.asm"
%include "camera.asm"
%include "lighting.asm"
%include "ground.asm"
%include "draw_sprites.asm"
%include "bosses.asm"
%include "events.asm"
%include "ai.asm"
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/01_modules         # wheel: zoom (half size to 4x); W A S D: move
;   TIME=21 ./build/01_modules
;   HEADLESS=1 SEED=0x1234 ./build/01_modules
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside.*
;   python3 tools/gen_sprites.py --write 01_modules/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/01_modules
;
; Questions to answer by experimenting:
;   - Move one %include line (say, win.asm before effects.asm) and
;     rebuild. Does the game change? Does the binary?
;   - objdump -h build/01_modules: which module's code starts where?
;     (nm build/01_modules | sort | less)
; ------------------------------------------------------------
