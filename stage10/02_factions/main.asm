; ============================================================
; Stage 10.02 — Factions
;
; 01_modules/, with two teams generalized to factions: the groundwork
; for the Bikers, the cartel, the good ole boys, the police and the
; player joining the fight. The same game, byte for byte.
;
;   - a soldier's Soldier.team is its faction: 0 the Crips, 1 the
;     Bloods (NUM_GANGS = 2); MAX_FACTIONS = 8 slots in all
;   - who fights whom is a table (hostility, in data.asm), read with
;     the HOSTILE macro (constants.asm), instead of "a different team".
;     It decides who a soldier targets, whose flow field it follows,
;     whom it holds fire for, what counts as friendly fire, which
;     kills score, and which enemies make a respawn spot unsafe
;   - one flow field per faction (field_for, bfs_states), toward
;     everyone that faction fights. With two gangs at war, the Crips'
;     field is 9.03's "toward the Bloods" exactly
;   - score, tickets, boss_state, home and fwd_sign are sized for
;     every faction; the Big Homie, the scoreboard and the win lines
;     are still between the two gangs
;   - check_win: the last gang standing, among any number of gangs
;
; Proof: the end state is identical to 10.01's for 12 seeds headless
; and one windowed; a copy with MAX_FACTIONS = 4 plays identically
; too; and a copy with an all-zero table plays a war where nobody
; fights (score 0-0, a stalemate). About 4% slower (1.71 s a game):
; six empty fields get seeded each tick.
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
;   ./build/02_factions         # wheel: zoom (half size to 4x); W A S D: move
;   TIME=21 ./build/02_factions
;   HEADLESS=1 SEED=0x1234 ./build/02_factions
;   STAGGER=0 ./batch.sh 48    # headless, 4 at a time
;   python3 tools/gen_southside.py            # rebuild maps/southside.*
;   python3 tools/gen_sprites.py --write 02_factions/sprites.asm
;   HEADLESS=1 SEED=21 gdb -batch -x tools/profile.py ./build/02_factions
;
; Questions to answer by experimenting:
;   - Clear the hostility table (all zeros) and run HEADLESS=1. Who
;     still dies, and why?
;   - Make the Crips hostile to the Bloods but not the other way round.
;     What happens to the Bloods' flow field, and to the war?
;   - build_fields seeds all 8 factions' fields every tick. Skip the
;     ones with nobody hostile to them: how much faster?
; ------------------------------------------------------------
