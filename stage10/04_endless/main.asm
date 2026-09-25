; ============================================================
; Stage 10.04 — The endless war
;
; 03_fair_homes/, with two modes (MODE=, read_mode in respawn.asm):
;
;   - watch: last gang standing, exactly as before (byte for byte:
;     same seed, same end as 10.03). The default when HEADLESS, so
;     batches, replays and the fairness checks carry on as they were
;   - game: the endless war the game will be played in. The default in
;     a window. Unlimited lives and respawns, no score limit, nobody
;     wins (check_win); closing the window prints how the war went.
;     HEADLESS=1 MODE=game runs to MAX_TICKS and prints the same
;     "Endless war" line, for batches of wars
;
; Two things the war needed:
;   - the Big Homie comes back: once a gang's is dead, it can bring
;     him out again when it falls BOSS_KILL_GAP kills further behind
;     than when he died (boss_base). The win line counts his outings
;   - guns move on: in the endless war the guns of the dead piled up
;     between the two crowds, where nobody lived to pick one up (69 of
;     80 on the ground, 3,000 ticks in, and the war down to knives).
;     A gun left PICKUP_STALE ticks turns up at one of the pair's
;     pickup spots (refresh_pickups). The kill rate stays up all war
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
extern strcmp

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
;   ./build/04_endless         # wheel: zoom (half size to 4x); W A S D: move
;   TIME=21 ./build/04_endless
;   HEADLESS=1 SEED=0x1234 ./build/04_endless    # watch mode
;   MODE=watch ./build/04_endless              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/04_endless    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside2.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/04_endless              # a given pair
;   python3 tools/gen_sprites.py --write 04_endless/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/04_endless
;
; Questions to answer by experimenting:
;   - Set PICKUP_STALE to 99999 and run HEADLESS=1 MODE=game with a
;     gdb script that prints the score every 1,000 ticks. When does
;     the war slow down, and why?
;   - In game mode, which of the three pairs makes the busiest war?
;   - The Big Homie comes back 1-2 times a war. What would make the
;     losing gang's comeback more (or less) likely?
; ------------------------------------------------------------
