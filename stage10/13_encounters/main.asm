; ============================================================
; Stage 10.13 — Encounters in town
;
; 13_encounters/, for the play tests' "relatively easy to avoid": the police
; drove only roads that cross the whole map (the edges and three
; streets), and the dog was walked along the top and bottom edges.
;
; The generator now exports the road network (maps/southside4.inc):
; 84 straight east-west or north-south stretches of road with both
; lanes clear, and the 210 places they cross. In game mode (roads.asm):
;
;   - a police car turns up on a random stretch, out of your sight
;     (700 px), and patrols: it turns at 35% of crossings, turns onto
;     the road it meets where its own ends, U-turns at a dead end, and
;     goes off duty after 90 s, out of your sight. A new car comes
;     after about 5 s (1 in 300 a tick; was 1 in 600)
;   - a dog walker walks the sidewalk of a random east-west stretch,
;     and turns back at its end if you'd see them vanish; walks come
;     sooner (1 in 450; was 900)
;   - an arrested gangster is replaced, as a killed one is: the war
;     never ends, and at ~20 arrests a war the gangs would dwindle
;   - in a shift the scoreboard keeps your line up rather than
;     announcing the police or the dog (they're out most of the time)
;
; A traced war: the car out 92% of the time, on 51 of the 84 runs,
; 106 turns and 11 U-turns, never overlapping a wall or a parked car.
; 48 wars: the Crips took 49.9% of the kills; arrests 5.8 -> 21.6 a
; war, police kills 10.8 -> 26.2, dog kills 7.5 -> 29.5.
;
; Watch mode keeps the old lanes and walks: the same game as 10.12.
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
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/13_encounters            # the game: ENTER for the shop, ENTER again for a shift
;   SAVE=/tmp/test.sav ./build/13_encounters      # a save file of your own
;   python3 tools/gen_vehicles.py --write 13_encounters/vehicle_art.asm
;   TIME=21 ./build/13_encounters
;   HEADLESS=1 SEED=0x1234 ./build/13_encounters    # watch mode
;   MODE=watch ./build/13_encounters              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/13_encounters    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside4.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/13_encounters              # a given pair
;   python3 tools/gen_sprites.py --write 13_encounters/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/13_encounters
;
; Questions to answer by experimenting:
;   - Set COP_TURN_PCT to 100. Where does the car end up spending its
;     time, and why? And at 0?
;   - road_net keeps a stretch only where both lanes are clear. Draw
;     road_runs over the map (the README shows how). Which streets are
;     missing, and what's in their way?
;   - The car crosses a junction when its centre passes it. What would
;     go wrong turning when its front passes it instead?
; ------------------------------------------------------------
