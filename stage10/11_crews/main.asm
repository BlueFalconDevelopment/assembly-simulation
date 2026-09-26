; ============================================================
; Stage 10.11 — Turf crews
;
; 11_crews/, after the play tests: the city was "relatively easy to
; avoid". Measured: every gang member went for the nearest enemy, so all
; of them fought in one strip between the homes; only 20-50% of houses
; had a gangster within 450 px, and the west third and the south never
; had one.
;
; Now (game mode only) each gang posts 5 crews of 3 round the city
; (crews.asm): spots in front of houses, picked at random each game,
; 700 px from both homes and from each other, on the gang's own side
; if there's room. A crew stands at its post with pistols, fights
; anyone hostile within 400 px of it (you too), walks back on a flow
; field of its own, and is replaced 30 s after a death or an arrest --
; never while you're within 500 px. The other 35 of each gang fight the
; war as before.
;
; Houses within 450 px of a gangster: 76-87% (was 21-47%); businesses
; 64-77% (18-53%). 48 wars: the Crips took 50.0% of the kills.
;
; After the play test ("a lot better. More making decisions on the
; fly", but the guns should hit harder with this many gangsters about,
; and the shop should sell a pistol upgrade):
;
;   pistol     34 -> 50 damage: two hits drop a gangster (was three)
;   shotgun    60 -> 100 up close (one blast), 30 -> 50 further out
;   PISTOL UPGRADE, a new shop item, 3 levels ($200, $400, $800):
;              damage 66 / 83 / 100, ticks between shots 12 / 11 / 10
;              (from 14). Level 3: one shot drops a gangster
;
; Watch mode has no crews and no player, so it's the same game as 10.10.
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
%include "vehicle_art.asm"    ; the vehicles' pixel art (tools/gen_vehicles.py)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/11_crews            # the game: ENTER for the shop, ENTER again for a shift
;   SAVE=/tmp/test.sav ./build/11_crews      # a save file of your own
;   python3 tools/gen_vehicles.py --write 11_crews/vehicle_art.asm
;   TIME=21 ./build/11_crews
;   HEADLESS=1 SEED=0x1234 ./build/11_crews    # watch mode
;   MODE=watch ./build/11_crews              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/11_crews    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside3.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/11_crews              # a given pair
;   python3 tools/gen_sprites.py --write 11_crews/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/11_crews
;
; Questions to answer by experimenting:
;   - Set CREWS_PER_GANG to 8. How many crews does crew_count say you
;     got, and which rule ran out first?
;   - Put the crews back as flow-field sources (build_fields). Time a
;     headless war (MODE=game HEADLESS=1) before and after. Why is it
;     slower, when the crews hardly move?
;   - Stand 450 px from a post. Who comes for you, and who doesn't?
; ------------------------------------------------------------
