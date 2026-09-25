; ============================================================
; Stage 10.06 — The bicycle
;
; 05_on_foot/, on a bike: the first rung of the vehicle ladder
; (vehicles.asm). You spawn riding it.
;
;   W A S D  point where you want to go, as when walking: the bike
;            turns toward it and pedals; no keys: it brakes
;   E        get off (beside it), or back on
;   the mouse, Q and the wheel work as on foot; riding, your aim is
;   worse (one hand on the bars)
;
; Up to 4 px a tick against walking's 3, with momentum: it speeds up,
; slows for a sharp turn, and turns in an arc. Walls stop you and you
; slide along them. Soldiers don't: riding into one bumps him aside and
; slows you, and at speed it hurts him (from your speed and the bike's
; mass: 16 at top speed), costs you a little health and wears the
; bike; worn out, it's a wreck until you
; respawn. You're fully exposed. The physics is one routine driven by
; a row of the vehicle table (vehicle_types), so the moped, the
; motorcycle, the car and the van will be rows and art, not code.
; The art comes from tools/gen_vehicles.py: shapes, rendered at 16
; headings (vehicle_art.asm, with the sine table the physics steers by).
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
;   player.asm      you: walking, aiming, shooting, dying (10.05)
;   vehicles.asm    your vehicle: the table, riding, ramming (10.06)
;   vehicle_art.asm its art and the sine table (tools/gen_vehicles.py)
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
%include "vehicles.asm"       ; your vehicle (10.06; before player.asm: its macro)
%include "player.asm"         ; you (10.05)
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/06_bicycle         # you, on a bike: W A S D ride, E off/on
;   python3 tools/gen_vehicles.py --write 06_bicycle/vehicle_art.asm
;   TIME=21 ./build/06_bicycle
;   HEADLESS=1 SEED=0x1234 ./build/06_bicycle    # watch mode
;   MODE=watch ./build/06_bicycle              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/06_bicycle    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside2.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/06_bicycle              # a given pair
;   python3 tools/gen_sprites.py --write 06_bicycle/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/06_bicycle
;
; Questions to answer by experimenting:
;   - Add a second row to vehicle_types (a faster, heavier "moped") and
;     set veh_type to it in vehicle_spawn. What else would you need?
;   - Turn rate is constant, so a fast bike turns in a wider circle.
;     How wide, at top speed? (4 px a tick, 10/256 of a turn a tick)
;   - Try 9.x's tank steering again: A and D turn, W pedals. Why is
;     pointing where you want to go easier on a keyboard?
; ------------------------------------------------------------
