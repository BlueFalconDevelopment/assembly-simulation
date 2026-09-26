; ============================================================
; Stage 10.12 — Weed, dispensaries, and your health
;
; 12_meds/, after the play test: "our character should have some kind
; of health display so we know how many hits we can tank", and health
; pickups -- prescription marijuana, dropped by gangsters on death or
; arrest, and waiting in front of medical marijuana dispensaries.
; (meds.asm)
;
;   - a health bar over you (green; yellow under half; red under a
;     quarter), and "HP 120/150 (8 HITS)" on the scoreboard: gang
;     pistol hits you can take, after your body armor
;   - the bottle: orange, white cap, a green leaf on the label. Walk
;     over it: +60 health, up to your max (at full health you leave it)
;   - 5 dispensaries a game: businesses picked at random, 500 px apart,
;     with a green cross on the roof and a sign by the door. A bottle
;     waits at the door; 30 s after you take it there's another
;   - a gangster killed or arrested drops one 10% of the time; it lasts
;     45 s, blinking for the last 3. About 10-20 lie round the map
;
; All on your own RNG, and only in a shift in a window: watch mode, and
; a headless war in game mode, are the same games as 10.11.
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
;   crews.asm       turf crews (10.11)
;   meds.asm        weed, dispensaries, your health bar (10.12)
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
%include "ai.asm"
%include "crews.asm"          ; turf crews (10.11)
%include "vehicles.asm"       ; your vehicle (10.06; before player.asm: its macro)
%include "player.asm"         ; you (10.05)
%include "deliveries.asm"     ; the job (10.07)
%include "save.asm"           ; the save file (10.08)
%include "shifts.asm"         ; title, shifts, summary (10.08)
%include "shop.asm"           ; the shop (10.10; after shifts.asm: its macro)
%include "meds.asm"           ; weed, dispensaries, your health bar (10.12)
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/12_meds            # the game: ENTER for the shop, ENTER again for a shift
;   SAVE=/tmp/test.sav ./build/12_meds      # a save file of your own
;   python3 tools/gen_vehicles.py --write 12_meds/vehicle_art.asm
;   TIME=21 ./build/12_meds
;   HEADLESS=1 SEED=0x1234 ./build/12_meds    # watch mode
;   MODE=watch ./build/12_meds              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/12_meds    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside3.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/12_meds              # a given pair
;   python3 tools/gen_sprites.py --write 12_meds/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/12_meds
;
; Questions to answer by experimenting:
;   - med_drop uses player_rand, not rand_range. Switch it, and compare
;     a headless game-mode war's score (MODE=game HEADLESS=1 SEED=5)
;     before and after. Why does it change, when nobody picks one up?
;   - Set MED_DROP_PCT back to 20. How many bottles lie about now?
;   - Buy BODY ARMOR 3. What does the HITS count do, and why?
; ------------------------------------------------------------
