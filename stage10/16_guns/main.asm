; ============================================================
; Stage 10.16 — Guns, a bat, and grenades
;
; 16_guns/, and the second step of the progression content: new
; weapons for you (weapons.asm), bought on the shop's new GUNS page. The
; gangs keep what they had.
;
;               fires every  damage   hit   range   a life, a level
;   pistol      14..10 ticks  50..100  85%   250     60 (+30 big mags)
;   shotgun     30            100/50   95/65 80/150  12 shells
;   SMG         5             22       70%   280     60 rounds ($400, $300)
;   rifle       45            120      90%   600     10 rounds ($600, $400)
;   bat         30            60       95%   30      no ammo ($100)
;   grenades    thrown        40..250 in 90 px       2 ($300 each level)
;
; A table, pgun, says how each fires; player_fire reads it, with the
; shotgun's close blast and the bat (no line of fire, nothing spent) as
; the special cases. Q takes the next weapon you have. A grenade flies
; to your lock or the cursor (260 px at most) in an arc, and blows up:
; everyone within 90 px takes 250 at the middle down to 40 at the edge
; -- you too, at half: the play test asked for "a little more
; devastating" than the first 70 px and 150 to 10 -- and the ground's
; scorched. The shop's items now each say which page they're on: GEAR,
; GUNS, RIDES.
;
; Watch mode has no player: the same game as 10.15.
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
;   weapons.asm     your guns, the bat, grenades (10.16)
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
%include "weapons.asm"        ; your guns, the bat, grenades (10.16; before player.asm: its macro)
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
;   ./build/16_guns            # the game: ENTER for the shop, ENTER again for a shift
;   SAVE=/tmp/test.sav ./build/16_guns      # a save file of your own
;   python3 tools/gen_vehicles.py --write 16_guns/vehicle_art.asm
;   TIME=21 ./build/16_guns
;   HEADLESS=1 SEED=0x1234 ./build/16_guns    # watch mode
;   MODE=watch ./build/16_guns              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/16_guns    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside5.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/16_guns              # a given pair
;   python3 tools/gen_sprites.py --write 16_guns/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/16_guns
;
; Questions to answer by experimenting:
;   - Throw a grenade at your own feet (aim at yourself). What stops it
;     killing you outright, and should anything?
;   - The rifle goes through first_in_line like the pistol. Put a Crip
;     between you and a Blood at 400 px, locked on the Blood: who gets
;     hit, and is that what a rifle should do?
;   - Add a row to pgun for a weapon of your own. Where else does a new
;     PW_ number have to go?
; ------------------------------------------------------------
