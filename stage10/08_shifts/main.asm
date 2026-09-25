; ============================================================
; Stage 10.08 — Shifts and saving
;
; 07_deliveries/, with a title screen, shifts and a save file
; (shifts.asm, save.asm):
;
;   title    the war goes on behind a dimmed overlay: your money and
;            shifts from the save, the controls, ENTER to start
;   shift    you and your bike, the job board, and 3 minutes on the
;            clock (the scoreboard's second row, on the right)
;   summary  the clock ran out, or you died: deliveries, earnings,
;            kills, your total. ENTER for the next shift
;
; Dying ends the shift: the package is lost and so is 20% of your
; money; your gear stays. The save (~/.courier_save, or $SAVE) is 64
; bytes, written through raw syscalls at the end of every shift and
; when the window closes, to <path>.tmp and then renamed over the old
; one. A damaged save is treated as none, and the title says so.
; draw_text now draws wherever text_fb points: the scoreboard, or the
; view (the overlays).
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
;   ./build/08_shifts          # the game: ENTER starts a shift
;   SAVE=/tmp/test.sav ./build/08_shifts      # a save file of your own
;   python3 tools/gen_vehicles.py --write 08_shifts/vehicle_art.asm
;   TIME=21 ./build/08_shifts
;   HEADLESS=1 SEED=0x1234 ./build/08_shifts    # watch mode
;   MODE=watch ./build/08_shifts              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/08_shifts    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside3.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/08_shifts              # a given pair
;   python3 tools/gen_sprites.py --write 08_shifts/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/08_shifts
;
; Questions to answer by experimenting:
;   - od -A d -t x4 ~/.courier_save: find your money. Change a byte and
;     start the game. What does the title say, and why?
;   - write_save writes <path>.tmp and renames it. What could go wrong
;     writing the save in place instead?
;   - SHIFT_TICKS is 3 minutes. How many deliveries fit in a shift?
; ------------------------------------------------------------
