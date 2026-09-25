; ============================================================
; Stage 10.07 — Deliveries
;
; 06_bicycle/, with the job (deliveries.asm): pick up a package at a
; business, deliver it to a house, get paid.
;
;   1 2 3    take a job from the board (the scoreboard's second row:
;            pay, distance, and a ! for each level of danger)
;   X        drop the job
;
; A yellow marker is the business, a green one the house, and a pip at
; the edge of the screen points to whichever is off it. The clock
; starts when you pick the package up: on time, the full pay; late,
; half. Dying loses the package. Pay grows with the distance and with
; the danger: gang members near the route when the offer was made.
; The map now lists the businesses' doors (the real buildings) and the
; houses' (the generated ones): maps/southside3.*, from
; tools/gen_southside.py. The scoreboard is two rows (HUD_H 40).
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
;   deliveries.asm  the job: the board, pick up, deliver, pay (10.07)
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
%include "deliveries.asm"     ; the job (10.07)
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/07_deliveries      # you, on a bike: W A S D ride, E off/on, 1 2 3 jobs, X drop
;   python3 tools/gen_vehicles.py --write 07_deliveries/vehicle_art.asm
;   TIME=21 ./build/07_deliveries
;   HEADLESS=1 SEED=0x1234 ./build/07_deliveries    # watch mode
;   MODE=watch ./build/07_deliveries              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/07_deliveries    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside3.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/07_deliveries              # a given pair
;   python3 tools/gen_sprites.py --write 07_deliveries/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/07_deliveries
;
; Questions to answer by experimenting:
;   - Danger is counted when the offer is made. How would you make a
;     job's pay change while you're doing it?
;   - The pay uses the straight-line distance. Which jobs does that
;     underpay? (Hint: the park, the airport)
;   - Give the van capacity 3 and let the board hold three jobs at once.
;     What in deliveries.asm assumes one?
; ------------------------------------------------------------
