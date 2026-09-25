; ============================================================
; Stage 10.05 — On foot
;
; 04_endless/, and you're in it: in game mode, in a window, a courier
; on foot in the middle of the war (player.asm). Everyone is hostile.
;
;   W A S D      walk (sliding along walls); the camera follows you
;   right-click  lock onto the enemy nearest the cursor; yellow brackets
;   left button  fire: at the lock (in range and sight, or it holds
;                fire), else at the enemy nearest the cursor, else a miss
;   Q            swap pistol and shotgun
;   wheel        zoom (game mode starts at 2x)
;   walk over a gun on the ground to take its ammo
;
; 150 health (and it comes back when you're left alone), 60 pistol
; rounds a life, and a better shot than any gang member. The gangs only
; come after you within PLAYER_AGGRO. Dying shows YOU DIED, and 3
; seconds later you're back somewhere safe. The scoreboard's middle
; shows your health, gun, ammo and kills. You're a soldier in the slot
; after the Big Homies, in your own faction, so the gangs target you
; and shoot you with their usual code (see player.asm).
; Watch mode (and HEADLESS) has no player: byte for byte, the same
; game as 10.04.
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
%include "player.asm"         ; you (10.05)
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/05_on_foot         # you: W A S D walk, the mouse aims and fires, wheel zooms
;   TIME=21 ./build/05_on_foot
;   HEADLESS=1 SEED=0x1234 ./build/05_on_foot    # watch mode
;   MODE=watch ./build/05_on_foot              # last gang standing, in a window
;   HEADLESS=1 MODE=game ./build/05_on_foot    # an 8-minute endless war
;   MODE=game STAGGER=0 ./batch.sh 48          # 48 wars (all 'stuck': no winner)
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside2.* (with the scores)
;   python3 tools/score_pairs.py build/04_endless   # re-score the pairs (watch mode)
;   PAIR=0 ./build/05_on_foot              # a given pair
;   python3 tools/gen_sprites.py --write 05_on_foot/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/05_on_foot
;
; Questions to answer by experimenting:
;   - Make the hostility table's player row all zeros (the gangs still
;     hunt you, you just can't hurt them). Now the other way round.
;   - PLAYER_SPEED 3 against the soldiers' 2: can you outrun a gang?
;     What about PLAYER_SPEED 2?
;   - Shoot from behind a parked car (low cover: bullets fly over it).
;     Then from behind a hedge.
; ------------------------------------------------------------
