; ============================================================
; Stage 10.15 — The vehicle ladder
;
; 15_rides/, and the first step of the progression content: the moped,
; the motorcycle, the car and the van, four more rows of the vehicle
; table (vehicles.asm) and their art (tools/gen_vehicles.py):
;
;               speed  health  body  ram   aim     price
;   bicycle     4      60      -     2     -15%    (yours)
;   moped       5      90      -     3     -15%    $300
;   motorcycle  6      130     -     5     -20%    $800
;   car         6      300     50%   12    -30%    $2000
;   van         5      400     60%   14    -35%    $3500
;
; (Speed in px a tick; walking is 3. The body: that share of what's
; shot at you comes off the vehicle instead, and inside it you aren't
; drawn. A ram does speed x mass / 8: the car's kills.) The user's
; calls: you keep every ride you buy and pick one before each shift;
; everything can shoot, the bigger the worse.
;
; Three new fields a row: the collision box (the car's 22 px square is
; tested as four soldier-sized boxes in its corners), the sprites' size
; (the car and the van are 40 px), and the body. The shop gets a second
; page, RIDES (A / D): buy a ride, or pick one you own; both saved, in
; the save's spare bytes 56 and 57. BIKE FRAME is HEAVY FRAME: +30
; health for whatever you ride.
;
; Watch mode has no player: the same game as 10.14.
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
;   roads.asm       the police and the dog on the road network (10.13)
;   ai.asm          targets, weapons, blockmap, line of sight,
;                   update_soldiers, first_in_line
;   crews.asm       turf crews (10.11)
;   meds.asm        weed, dispensaries, your health bar (10.12)
;   bikers.asm      the Bikers and their clubhouse (10.14)
;   player.asm      you: walking, aiming, shooting, dying (10.05)
;   vehicles.asm    your vehicle: the table, riding, ramming (10.06)
;   deliveries.asm  the job: the board, pick up, deliver, pay (10.07)
;   save.asm        the save file, through raw syscalls (10.08)
;   shifts.asm      the title, shifts, the summary (10.08)
;   shop.asm        the shop, the gear (10.10)
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
%include "roads.asm"          ; the police and the dog on the road network (10.13)
%include "ai.asm"
%include "crews.asm"          ; turf crews (10.11)
%include "vehicles.asm"       ; your vehicle (10.06; before player.asm: its macro)
%include "player.asm"         ; you (10.05)
%include "deliveries.asm"     ; the job (10.07)
%include "save.asm"           ; the save file (10.08)
%include "shifts.asm"         ; title, shifts, summary (10.08)
%include "shop.asm"           ; the shop (10.10; after shifts.asm: its macro)
%include "meds.asm"           ; weed, dispensaries, your health bar (10.12)
%include "bikers.asm"         ; the Bikers and their clubhouse (10.14)
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/15_rides            # the game: ENTER for the shop, ENTER again for a shift
;   SAVE=/tmp/test.sav ./build/15_rides      # a save file of your own
;   python3 tools/gen_vehicles.py --write 15_rides/vehicle_art.asm
;   TIME=21 ./build/15_rides
;   HEADLESS=1 SEED=0x1234 ./build/15_rides    # watch mode
;   MODE=watch ./build/15_rides              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/15_rides    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside5.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/15_rides              # a given pair
;   python3 tools/gen_sprites.py --write 15_rides/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/15_rides
;
; Questions to answer by experimenting:
;   - The car's collision box is a 22 px square, but the car is 34 px
;     long. Where does that show, and what would a rotated box cost?
;   - Give the moped a body of 30. What changes in how it plays, and
;     what doesn't (see draw loop: who gets drawn)?
;   - Each vehicle's capacity is in the table, but deliveries still take
;     one package. What would the job board need for the van's three?
; ------------------------------------------------------------
