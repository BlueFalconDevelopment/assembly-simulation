; ============================================================
; Stage 10.03 — Fair homes
;
; 02_factions/, with the gangs' homes chosen at random each game from
; pairs that batches showed are fair. 9.02's two fixed homes gave the
; west one about 62% of the wins.
;
;   - the map (maps/southside2.inc, a new name: 01 and 02 keep 9.02's
;     southside.inc) has SITES apartment complexes, picked spread out
;     over the neighborhoods by tools/gen_southside.py, starting from
;     9.02's two, and the pairs of them that tools/score_pairs.py
;     found fair: each pair's first site won within 4.5% of half its
;     games, over 480
;   - choose_sides picks a pair (PAIR=n picks one), then flips a coin
;     for which gang lives where, as before
;   - each pair has its own pickups, mirrored between its two lobbies
;   - the other sites are closed: grey walls, a roof over the lobby,
;     and the doorways walled up (build_blockmap), so the pathfinding
;     never goes in; the lobby lights and door lights are the homes'
;   - the camera starts between the homes (camera_start)
;   - the win line says "; homes a-b; crips home s", which is how the
;     batches score a pair
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
%include "results.asm"
%include "effects.asm"
%include "win.asm"
%include "primitives.asm"

; ------------------------------------------------------------
; Build and run (from stage10/):
;   make                       # every step; rebuilds when its modules or maps/ change
;   ./build/03_fair_homes         # wheel: zoom (half size to 4x); W A S D: move
;   TIME=21 ./build/03_fair_homes
;   HEADLESS=1 SEED=0x1234 ./build/03_fair_homes
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside2.* (with the scores)
;   python3 tools/score_pairs.py build/03_fair_homes   # re-score the pairs
;   PAIR=0 ./build/03_fair_homes              # a given pair
;   python3 tools/gen_sprites.py --write 03_fair_homes/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/03_fair_homes
;
; Questions to answer by experimenting:
;   - maps/pair_scores.json has every candidate pair's score. Which
;     sites win more often, and what do they have in common?
;   - Set SITES to 8 in the generator. Do more pairs pass?
;   - A pair can be fair and still boring. Which pairs make the
;     longest games?
; ------------------------------------------------------------
