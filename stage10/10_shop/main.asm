; ============================================================
; Stage 10.10 — The shop, and a new name
;
; 10_shop/, plus the shop between shifts (shop.asm): title -> shop
; -> shift -> summary -> shop. W / S choose, E buys, ENTER starts the
; shift. The first list is upgrades you keep (a level each, saved in
; the save file's spare bytes, so 10.08 saves still load):
;
;   BODY ARMOR   3 levels   15% less damage each (every hit: gunfire,
;                           the dog, your own rams; armor_damage)
;   TOUGHNESS    3 levels   +25 max health each
;   BIG MAGS     3 levels   +30 pistol rounds a life each
;   SHOTGUN      2 levels   +12 shells a life each
;   BIKE FRAME   2 levels   +30 bike health each
;
; apply_gear turns the levels into numbers (player_max_hp, player_armor,
; player_rounds, player_shells, bike_bonus) at the start of each shift.
; The prices are placeholders: they get tuned after the gangsters and
; the random encounters (the user's order).
;
; And the game has a name: "MY CITY IS A WARZONE BUT I NEED
; MONEY!!!1:4thwall break: Help I need to fix my van." -- the typos
; are on purpose, a nod to "I MAED A GAM3 W1TH ZOMB1ES 1N IT!!!1". It's
; the window's title in game mode, and the title screen's two top lines
; (in capitals: the font has no others).
;
; A code review found (all fixed): the watch-mode window title had the
; game's name in it (a string put between title_prefix and its length);
; an E held from the shop threw you off the bike; zoomed in past 2x the
; overlays' text ran off the view (now they zoom out to 2x and the
; wheel stops there); nothing stopped a 4th level with no 4th price;
; the armor sum was written out twice; two comments were wrong.
;
; Don't point an older step's build at your real save: 10.08 and 10.09
; load it, then write it back without the shop's bytes, so the gear is
; gone. Give them SAVE=/tmp/old.sav.
;
; Watch mode has no player and no shop, so it's the same game as 10.09.
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
%include "vehicles.asm"       ; your vehicle (10.06; before player.asm: its macro)
%include "player.asm"         ; you (10.05)
%include "deliveries.asm"     ; the job (10.07)
%include "save.asm"           ; the save file (10.08)
%include "shifts.asm"         ; title, shifts, summary (10.08)
%include "shop.asm"           ; the shop (10.10; after shifts.asm: its macro)
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/10_shop            # the game: ENTER for the shop, ENTER again for a shift
;   SAVE=/tmp/test.sav ./build/10_shop      # a save file of your own
;   python3 tools/gen_vehicles.py --write 10_shop/vehicle_art.asm
;   TIME=21 ./build/10_shop
;   HEADLESS=1 SEED=0x1234 ./build/10_shop    # watch mode
;   MODE=watch ./build/10_shop              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/10_shop    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside3.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/10_shop              # a given pair
;   python3 tools/gen_sprites.py --write 10_shop/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/10_shop
;
; Questions to answer by experimenting:
;   - Add a row to shop_items. What else has to change before the new
;     item does anything? (Try it: the build checks the save still fits)
;   - Buy BODY ARMOR 3 and let a gangster shoot you: 20 damage becomes
;     11, not 11.0. Where does the fraction go, and who does it favour?
;   - Edit your save's shop bytes with a hex editor. What does the
;     game say, and why?
; ------------------------------------------------------------
