; ============================================================
; Stage 10.09 — The police leave you alone
;
; 08_shifts/, after the play test: "the police shouldn't shoot you and
; they should avoid running you over". In update_police (events.asm):
;
;   - the police are a faction (FACTION_POLICE) with a row in the
;     hostility table: the two gangs, not you. The officers only aim
;     at, and the car only arrests, those it says (their shots hit
;     only the soldier they aim at, so none of theirs hits you)
;   - the car won't drive into you: if you (on the bike, the whole
;     bike; or your parked bike) are in the strip just ahead of its
;     bumper, it waits -- and after COP_WAIT_MAX ticks (2 s) turns
;     round and goes back the way it came. From behind or the side,
;     you don't stop it
;
; (A review of the first version found: the car waited for ever -- a
; safe zone with police turrets, and no other police car could come;
; a player touching it from behind or the side froze it; on the bike it
; stopped on top of you; and the comments promised stray police rounds
; that can't happen.)
;
; Watch mode has no player, so it's the same game as 10.08.
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
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/09_police          # the game: ENTER starts a shift
;   SAVE=/tmp/test.sav ./build/09_police      # a save file of your own
;   python3 tools/gen_vehicles.py --write 09_police/vehicle_art.asm
;   TIME=21 ./build/09_police
;   HEADLESS=1 SEED=0x1234 ./build/09_police    # watch mode
;   MODE=watch ./build/09_police              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/09_police    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside3.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/09_police              # a given pair
;   python3 tools/gen_sprites.py --write 09_police/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/09_police
;
; Questions to answer by experimenting:
;   - Stand in a police lane. The car waits. What would it take for it
;     to steer round you instead? (It drives a fixed lane: 10.13's road
;     graph is the start of that)
;   - Make the police a faction in the hostility table. Which of these
;     three changes would that do for free?
; ------------------------------------------------------------
