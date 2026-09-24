; ============================================================
; Stage 8.01 — Soldier sprites
;
; stage7/16_tuning.asm, but soldiers are drawn as hand-made pixel art
; instead of solid squares. Drawing only: the game is unchanged.
;
;   - 16x16, exactly the hitbox, so what you see is what can be hit
;   - 8 facing directions from 5 drawn poses (N, NE, E, SE, S); W, NW
;     and SW are E, NE and SE mirrored. Two walk frames each
;   - shirt and bandana in the gang's colour, three skin tones (by
;     soldier number), the weapon in hand: knife, pistol, or the
;     pistol plus a longer barrel for a shotgun
;   - the Big Homie wears a gold bandana and chain (and keeps his
;     health bar); the dog walker is a sprite too
;
; The art is text in tools/gen_sprites.py, which checks it, renders a
; preview, and writes the SPRITE DATA block below.
;
; Facing and the walk cycle are drawing-only state (sprite_last_x/y,
; sprite_facing, sprite_walk), worked out from how far each soldier
; moved since the frame before. Headless runs never touch them.
; ============================================================
default rel
global main

extern SDL_Init
extern SDL_CreateWindow
extern SDL_CreateRenderer
extern SDL_CreateTexture
extern SDL_LockTexture
extern SDL_UnlockTexture
extern SDL_RenderCopy
extern SDL_RenderPresent
extern SDL_PollEvent
extern SDL_GetTicks
extern SDL_Delay
extern SDL_DestroyTexture
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit
extern getenv
extern atoi
extern strtoull

SDL_INIT_VIDEO              equ 0x00000020
SDL_WINDOWPOS_UNDEFINED     equ 0x1FFF0000
SDL_WINDOW_SHOWN            equ 0x00000004
SDL_RENDERER_ACCELERATED    equ 0x00000002
SDL_QUIT_EVENT               equ 0x100
FRAME_BUDGET_MS              equ 16
SDL_PIXELFORMAT_RGBA32       equ 0x16762004
SDL_TEXTUREACCESS_STREAMING  equ 1

SCREEN_W equ 1280
SCREEN_H equ 720              ; the battlefield
HUD_H    equ 24               ; scoreboard strip under it
WINDOW_H equ SCREEN_H + HUD_H

; ---- scoreboard font (see `font` in .data) ----
FONT_FIRST  equ 32            ; ' '
FONT_LAST   equ 90            ; 'Z'
FONT_ROWS   equ 7
FONT_COLS   equ 5
FONT_SCALE  equ 2             ; each font pixel is a 2x2 block
CHAR_ADV    equ (FONT_COLS + 1) * FONT_SCALE     ; one column of spacing
HUD_TEXT_Y  equ SCREEN_H + (HUD_H - FONT_ROWS * FONT_SCALE) / 2
HUD_MARGIN  equ 8
OUR_PITCH equ SCREEN_W * 4

NUM_PER_TEAM   equ 50
; Minimum corner-to-corner spacing between two spawns on each axis,
; inside a lobby. SOLDIER_SIZE would only prevent overlap. 20 (not the
; arenas' 24) because a lobby is smaller than the old spawn strip: the
; generator packs 50 soldiers into each lobby 300 times to check it
; never jams.
SPAWN_GAP      equ SOLDIER_SIZE + 4
LOBBY_MARGIN   equ 2            ; spawn this far in from the lobby walls
SQUAD          equ NUM_PER_TEAM * 2   ; the two gangs' regular soldiers
BOSS0          equ SQUAD               ; the Crips' Big Homie's slot
BOSS1          equ SQUAD + 1           ; the Bloods'
TOTAL_SOLDIERS equ SQUAD + 2
SOLDIER_SIZE   equ 16
MOVE_SPEED     equ 2
CONTACT_RANGE  equ 20

KNIFE_DAMAGE          equ 34
KNIFE_HIT_CHANCE      equ 70
KNIFE_COOLDOWN_TICKS  equ 30

PISTOL_RANGE          equ 250
PISTOL_DAMAGE         equ 20
PISTOL_HIT_CHANCE     equ 60
PISTOL_COOLDOWN_TICKS equ 20

SHOTGUN_RANGE         equ 180
SHOTGUN_CLOSE_RANGE   equ 80
SHOTGUN_CLOSE_DAMAGE  equ 50
SHOTGUN_CLOSE_HIT     equ 85
SHOTGUN_FAR_DAMAGE    equ 25
SHOTGUN_FAR_HIT       equ 40
SHOTGUN_COOLDOWN_TICKS equ 40

WEAPON_KNIFE   equ 0
WEAPON_PISTOL  equ 1
WEAPON_SHOTGUN equ 2

STATE_SEEK_ENEMY equ 1

PICKUP_JITTER    equ 12      ; each pickup lands up to this far from its
                             ; table spot, on each axis (or exactly on
                             ; it, if the jitter lands it in something)
; Weapons are conserved: every weapon is either lying in exactly one
; active pickup slot or held by exactly one living soldier, and a drop
; only happens when its holder dies. So the number of weapons on the
; ground can never exceed the number spawned at the start -- one slot
; per starting pickup is enough, with no spare "drop slots" needed.
MAX_PICKUPS   equ map_pickups_count + 2   ; + the Big Homies' guns
PICKUP_SIZE   equ 10
; A soldier grabs a pickup when its corner is within this of the
; pickup's. It was 15, under one body width, so the grabber had to
; stand almost ON the spot. A soldier holding a gun (who never picks
; anything up) standing there, boxed in by knife-wielding teammates who
; all wanted it, was a permanent stalemate (09's README). At
; SOLDIER_SIZE + 8, anyone touching that soldier can reach it.
PICKUP_RADIUS equ SOLDIER_SIZE + 8

; ---- pathfinding grid (see header) ----
CELL        equ 9
GRID_W      equ (SCREEN_W - SOLDIER_SIZE + CELL - 1) / CELL + 1   ; 142
GRID_H      equ (SCREEN_H - SOLDIER_SIZE + CELL - 1) / CELL + 1   ; 80
GRID_CELLS  equ GRID_W * GRID_H
UNREACHED   equ 0xFFFF
; (09-12 needed 9px cells so the grid mirrored exactly. The
; neighborhood isn't mirrored, but 9 still works fine.)

; ---- blockmap: one byte per soldier corner position ----
BM_W         equ SCREEN_W - SOLDIER_SIZE + 1
BM_H         equ SCREEN_H - SOLDIER_SIZE + 1
BLOCK_WALK   equ 1              ; a soldier here would overlap a wall or a prop
BLOCK_SIGHT  equ 2              ; ... a wall (props are low cover: no effect)

; ---- respawns (see header) ----
RESPAWN_TICKS       equ 120  ; dead this long before coming back
PROTECT_TICKS       equ 90   ; then this long without taking damage
RESPAWN_TRIES       equ 8    ; random spots tried; the safest one wins
DEFAULT_SCORE_LIMIT equ 0    ; last gang standing
DEFAULT_LIVES       equ 3

; ---- random encounters (see header) ----
COP_FIRST_DELAY  equ 300     ; no police before this tick
COP_CHANCE       equ 600     ; then 1 in this per tick (about 10 s)
COP_SPEED        equ 3
COP_FIRE_TICKS   equ 25
COP_RANGE        equ 350
COP_HIT_CHANCE   equ 50
COP_DAMAGE       equ 34
FEAR_RADIUS      equ 280    ; 15: 220
FLEE_DIST        equ 200    ; how far off the road a fleeing soldier aims
DOG_FIRST_DELAY  equ 600
DOG_CHANCE       equ 900     ; a walk starts 1 in this per tick (~15 s)
DOG_BREAK_CHANCE equ 420     ; leash slips 1 in this per tick (~7 s)
DOG_SPEED        equ 3
DOG_BITE_TICKS   equ 30
DOG_BITE_CHANCE  equ 75
DOG_DAMAGE       equ 30
DOG_RAGE_TICKS   equ 900     ; loose this long, then animal control
DOG_W            equ 12
DOG_H            equ 8
WALKER_SIZE      equ 10
DOG_NONE         equ 0
DOG_LEASHED      equ 1
DOG_LOOSE        equ 2
DOG_GONE         equ 3       ; collected; the walker finishes the walk

; ---- the Big Homie (see header) ----
BOSS_TRIGGER_PCT equ 60      ; default for BOSS_AT. 15: 40, which brought
                             ; him out ~80% of the way through a game;
                             ; 60 is ~71%, with more comebacks (README)
BOSS_KILL_GAP    equ 40      ; unlimited lives: this many kills behind
BOSS_HEALTH      equ 400
BOSS_HIT_BONUS   equ 20      ; percentage points, capped at BOSS_HIT_CAP
BOSS_HIT_CAP     equ 95
BOSS_ALERT_TICKS equ 180     ; scoreboard announcement, 3 s
COLOR_GOLD       equ 0xFF28C8F0
COLOR_BAR_BACK   equ 0xFF202020
COLOR_BAR        equ 0xFF3CC83C

MAX_TICKS equ 30000          ; headless only: 8+ minutes at 60 fps, vs
                             ; ~2,000-4,000 for a normal game

; ---- attack effects (drawing only, see header) ----
MAX_EFFECTS    equ 128      ; ring buffer; must be a power of two. One
                            ; attack per soldier per cooldown (>= 20
                            ; ticks) and effects live < 20 frames, so
                            ; at most 100 are ever alive at once
FX_KNIFE       equ WEAPON_KNIFE + 1     ; Effect.type = weapon + 1,
FX_PISTOL      equ WEAPON_PISTOL + 1    ; 0 = free slot
FX_SHOTGUN     equ WEAPON_SHOTGUN + 1
BULLET_TRAVEL  equ 8        ; frames for a tracer to reach its target
TRACER_TAIL    equ 2        ; tracer length, in 1/BULLET_TRAVEL of the path
IMPACT_FRAMES  equ 6        ; spark after arrival
BULLET_LIFE    equ BULLET_TRAVEL + IMPACT_FRAMES
KNIFE_PEAK     equ 5        ; frames to full extension, then same back
KNIFE_LIFE     equ KNIFE_PEAK * 2
KNIFE_BLADE    equ 3        ; blade length, in 1/KNIFE_PEAK of the distance
FLASH_FRAMES   equ 6        ; target drawn white this long on a hit
PELLET_SPREAD  equ 8        ; px between shotgun pellets at the target
MISS_OFFSET    equ 3        ; a miss lands this many PELLET_SPREADs sideways

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

struc Soldier
    .x:        resd 1
    .y:        resd 1
    .health:   resd 1
    .team:     resd 1
    .weapon:   resd 1
    .state:    resd 1
    .target:   resd 1
    .cooldown: resd 1
    .avoid_dir: resd 1   ; 0 = prefer up (vertical side-step) or
                            ; forward/toward the enemy (horizontal) first
                            ; when blocked, 1 = prefer down / back --
                            ; sticky per-soldier,
                            ; set to whichever direction last actually
                            ; worked, so a soldier does not flip-flop back
                            ; and forth every single tick between "blocked"
                            ; and "just barely clear" at a boundary
endstruc

struc Pickup
    .x:      resd 1
    .y:      resd 1
    .type:   resd 1
    .active: resd 1
endstruc

struc Effect
    .type:   resd 1      ; 0 = free, else FX_*
    .age:    resd 1      ; frames since the attack
    .target: resd 1      ; soldier index, for the hit flash
    .hit:    resd 1      ; 1 = the attack hit
    .x0:     resd 1      ; attacker centre
    .y0:     resd 1
    .x1:     resd 1      ; aim point: target centre, pushed aside on a miss
    .y1:     resd 1
    .px:     resd 1      ; perpendicular to the shot, PELLET_SPREAD long
    .py:     resd 1      ; (roughly -- see spawn_effect)
endstruc

struc Obstacle
    .x: resd 1
    .y: resd 1
    .w: resd 1
    .h: resd 1
endstruc

COLOR_TEAM0  equ 0xFFDC783C
COLOR_TEAM1  equ 0xFF3C3CDC
COLOR_PICKUP_PISTOL  equ 0xFF28D2E6
COLOR_PICKUP_SHOTGUN equ 0xFFC83CAA
COLOR_BLADE    equ 0xFFF0F0F0   ; near-white
COLOR_TRACER   equ 0xFF50E6FF   ; R=255 G=230 B=80 -- yellow
COLOR_PELLET   equ 0xFF3CA0FF   ; R=255 G=160 B=60 -- orange
COLOR_SPARK    equ 0xFF28DCFF   ; R=255 G=220 B=40
COLOR_FLASH    equ 0xFFFFFFFF
COLOR_HUD      equ 0xFF282828   ; dark grey strip
; ---- sprite palette colours (0xAABBGGRR) ----
COLOR_HAIR     equ 0xFF191E28
COLOR_PANTS    equ 0xFF503C3C
COLOR_SHOES    equ 0xFF141414
COLOR_GUN      equ 0xFF373232
COLOR_BARREL   equ 0xFF5F5A5A
COLOR_KNIFE    equ 0xFFE6DCDC
COLOR_WALKER_SHADE equ 0xFF6E3C5A
; palette slots, in tools/gen_sprites.py's LETTERS order
PAL_HAIR   equ 1
PAL_BAND   equ 2
PAL_SKIN   equ 3
PAL_SHIRT  equ 4
PAL_SHADE  equ 5
PAL_PANTS  equ 6
PAL_SHOES  equ 7
PAL_CHAIN  equ 8
PAL_GUN    equ 9
PAL_BARREL equ 10
PAL_KNIFE  equ 11
PAL_SIZE   equ 12
SPRITE_SIZE equ 16            ; = SOLDIER_SIZE: the art is the hitbox
TELEPORT   equ 8              ; moved more than this in a frame: a respawn,
                              ; not a step -- don't turn to face it
COLOR_COP_BODY equ 0xFF202020
COLOR_COP_DOOR equ 0xFFF0F0F0
COLOR_COP_GLASS equ 0xFF503C32
COLOR_SIREN_R  equ 0xFF2020FF
COLOR_SIREN_B  equ 0xFFFF4020
COLOR_WALKER   equ 0xFF9C5A7A   ; purple jacket
COLOR_HEAD     equ 0xFF8CB4E6   ; skin
COLOR_LEASH    equ 0xFFC8C8C8
COLOR_DOG      equ 0xFF3C64A0   ; brown, on the leash
COLOR_DOG_MAD  equ 0xFF5AB4E6   ; loose: tan, so it doesn't look like a Blood
COLOR_HUD_TEXT equ 0xFFDCDCDC   ; light grey

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title_prefix db "Stage 8.01 - "
    title_prefix_len equ $ - title_prefix
    map_name db "Neighborhood"
    map_name_len equ $ - map_name
    home_msg db "; crips home "
    home_msg_len equ $ - home_msg
    side_names db "westeast"    ; 4 letters each
    headless_env db "HEADLESS", 0
    seed_env db "SEED", 0
    respawns_env db "RESPAWNS", 0
    lives_env db "LIVES", 0
    score_env db "SCORE_LIMIT", 0
    score_msg db "; score "
    score_msg_len equ $ - score_msg
    tickets     dd -1, -1     ; respawns left per team, -1 = unlimited
    score       dd 0, 0       ; kills per team
    score_limit dd DEFAULT_SCORE_LIMIT
    score_winner dd 0         ; 1 or 2 once a team reaches score_limit
    hex_digits db "0123456789abcdef"
    seed_msg db "; seed "
    seed_msg_len equ $ - seed_msg
    show_seed dd 0            ; 1 = print_result adds the seed
    game_seed dq 0            ; rng_state right after seeding
    stalemate_msg db "Stalemate"
    stalemate_msg_len equ $ - stalemate_msg
    win_msg0 db "Team 0 (Crips) wins"
    win_msg0_len equ $ - win_msg0
    win_msg1 db "Team 1 (Bloods) wins"
    win_msg1_len equ $ - win_msg1
    on_msg db " on "
    on_msg_len equ $ - on_msg
    ff_msg1 db "! (friendly fire: "
    ff_msg1_len equ $ - ff_msg1
    ff_msg2 db " hits, "
    ff_msg2_len equ $ - ff_msg2
    ff_msg3 db " kills; held fire "
    ff_msg3_len equ $ - ff_msg3
    ff_msg4 db " times; "
    ff_msg4_len equ $ - ff_msg4
    ff_msg5 db " ticks"
    ff_msg5_len equ $ - ff_msg5
    ff_msg6 db ")", 10
    ff_msg6_len equ $ - ff_msg6
    ticks    dd 0             ; updates run so far
    ff_held  dd 0
    ff_hits  dd 0
    ff_kills dd 0
    game_over dd 0
    pass_reverse dd 0
    ; ---- random encounters ----
    cop_active   dd 0
    cop_rect     dd 0, 0, 0, 0    ; x, y, w, h
    cop_vel      dd 0, 0          ; dx, dy per tick
    cop_fire     dd 0             ; ticks until the officers fire again
    ; routes: x, y, w, h, dx, dy -- the proper lane of the avenue and
    ; both cross streets, each way
    cop_routes:
        dd  -40, 363, 40, 20,  COP_SPEED, 0          ; avenue, eastbound
        dd 1280, 337, 40, 20, -COP_SPEED, 0          ; avenue, westbound
        dd  303, -40, 20, 40,  0,  COP_SPEED         ; west street, south
        dd  327, 720, 20, 40,  0, -COP_SPEED         ; west street, north
        dd  903, -40, 20, 40,  0,  COP_SPEED         ; east street, south
        dd  927, 720, 20, 40,  0, -COP_SPEED         ; east street, north
    COP_ROUTES equ ($ - cop_routes) / 24
    dog_state    dd DOG_NONE
    walker_x     dd 0
    walker_y     dd 0
    walker_dx    dd 0
    dog_x        dd 0
    dog_y        dd 0
    dog_timer    dd 0             ; loose: ticks left
    dog_bite     dd 0             ; ticks until it can bite again
    ; walks: start x, y, dx -- the avenue's two sidewalks
    dog_walks:
        dd  -40, 320,  1
        dd 1300, 390, -1
    DOG_WALKS equ ($ - dog_walks) / 12
    fx_src       dd 0, 0          ; a stand-in "shooter" for spawn_effect
    arrests      dd 0
    cop_kills    dd 0
    dog_kills    dd 0
    ev_msg1 db "; arrests "
    ev_msg1_len equ $ - ev_msg1
    ev_msg2 db "; police kills "
    ev_msg2_len equ $ - ev_msg2
    ev_msg3 db "; dog kills "
    ev_msg3_len equ $ - ev_msg3
    hud_police db "POLICE!"
    hud_police_len equ $ - hud_police
    hud_dog db "DOG LOOSE!"
    hud_dog_len equ $ - hud_dog
    us_flee      dd 0             ; this soldier is running from the police
    boss_env     db "BOSS_AT", 0
    boss_at      dd BOSS_TRIGGER_PCT
    boss_state   dd 0, 0          ; per gang: 0 waiting, 1 due, 2 out
    boss_alert   dd 0             ; scoreboard announcement ticks left
    boss_alert_team dd 0
    boss_tick    dd 0             ; when the first Big Homie came out
    boss_tick_msg db "; big homie at "
    boss_tick_msg_len equ $ - boss_tick_msg
    hud_boss db "BIG HOMIE!"
    hud_boss_len equ $ - hud_boss
    boss_msg db "; big homies "
    boss_msg_len equ $ - boss_msg

    home      dd 0, 1         ; complex per team: 0 = west, 1 = east
    fwd_sign  dd 1, -1        ; +1: the enemy's complex is to the east
    rng_state    dq 0         ; xorshift64 state -- must never be 0

;; ---- MAP DATA (generated by tools/gen_neighborhood.py; don't edit by hand) ----
    ; walls: x, y, w, h (buildings, then both complexes' walls)
    map_walls:
        dd 40, 40, 110, 110
        dd 170, 60, 100, 90
        dd 40, 200, 90, 100
        dd 160, 200, 110, 90
        dd 400, 40, 200, 140
        dd 650, 40, 220, 100
        dd 380, 420, 150, 150
        dd 560, 420, 120, 90
        dd 720, 420, 150, 150
        dd 370, 665, 100, 45
        dd 500, 665, 120, 45
        dd 650, 665, 100, 45
        dd 780, 665, 100, 45
        dd 990, 430, 120, 110
        dd 1140, 430, 110, 160
        dd 990, 590, 120, 100
        dd 30, 410, 90, 10
        dd 160, 410, 120, 10
        dd 30, 690, 250, 10
        dd 30, 410, 10, 290
        dd 270, 410, 10, 110
        dd 270, 560, 10, 140
        dd 970, 30, 270, 10
        dd 970, 290, 110, 10
        dd 1120, 290, 120, 10
        dd 970, 30, 10, 100
        dd 970, 170, 10, 130
        dd 1230, 30, 10, 270
    map_walls_count equ ($ - map_walls) / 16
    ; low cover: x, y, w, h (cars, dumpsters, fences)
    map_props:
        dd 420, 215, 40, 20
        dd 480, 215, 40, 20
        dd 600, 215, 40, 20
        dd 720, 215, 40, 20
        dd 780, 215, 40, 20
        dd 420, 275, 40, 20
        dd 540, 275, 40, 20
        dd 660, 275, 40, 20
        dd 820, 275, 40, 20
        dd 640, 607, 40, 20
        dd 540, 540, 26, 16
        dd 690, 540, 26, 16
        dd 1115, 610, 16, 26
        dd 180, 300, 26, 16
        dd 880, 150, 16, 26
        dd 390, 195, 480, 4
        dd 390, 315, 4, 15
        dd 866, 199, 4, 116
        dd 150, 160, 4, 40
        dd 1120, 560, 4, 30
    map_props_count equ ($ - map_props) / 16
    ; the west complex's walls, drawn in its gang's colour
    cwalls_west:
        dd 30, 410, 90, 10
        dd 160, 410, 120, 10
        dd 30, 690, 250, 10
        dd 30, 410, 10, 290
        dd 270, 410, 10, 110
        dd 270, 560, 10, 140
    cwalls_west_count equ ($ - cwalls_west) / 16
    ; the east complex's walls, drawn in its gang's colour
    cwalls_east:
        dd 970, 30, 270, 10
        dd 970, 290, 110, 10
        dd 1120, 290, 120, 10
        dd 970, 30, 10, 100
        dd 970, 170, 10, 130
        dd 1230, 30, 10, 270
    cwalls_east_count equ ($ - cwalls_east) / 16
    ; lobby interiors: x, y, w, h (spawn and respawn areas), west then east
    lobbies:
        dd 40, 420, 230, 270
        dd 980, 40, 250, 250
    ; weapon pickups: x, y, type
    map_pickups:
        dd 320, 300, 1
        dd 330, 410, 2
        dd 200, 360, 1
        dd 90, 340, 2
        dd 560, 350, 1
        dd 700, 360, 2
        dd 470, 580, 1
        dd 620, 620, 2
        dd 930, 410, 1
        dd 1000, 360, 2
        dd 1100, 320, 1
        dd 1200, 400, 2
        dd 760, 300, 2
        dd 520, 300, 1
        dd 310, 560, 2
        dd 925, 150, 1
    map_pickups_count equ ($ - map_pickups) / 12
    ; the look: x, y, w, h, colour, drawn in order
    bg_rects:
        dd 0, 0, 1280, 720, 0xFF4E8C60
        dd 200, 20, 14, 14, 0xFF326932
        dd 60, 170, 14, 14, 0xFF326932
        dd 260, 300, 14, 14, 0xFF326932
        dd 620, 150, 14, 14, 0xFF326932
        dd 970, 300, 14, 14, 0xFF326932
        dd 1255, 320, 14, 14, 0xFF326932
        dd 360, 400, 14, 14, 0xFF326932
        dd 540, 575, 14, 14, 0xFF326932
        dd 700, 590, 14, 14, 0xFF326932
        dd 880, 560, 14, 14, 0xFF326932
        dd 1255, 420, 14, 14, 0xFF326932
        dd 1130, 700, 14, 14, 0xFF326932
        dd 15, 395, 14, 14, 0xFF326932
        dd 0, 320, 1300, 80, 0xFFA5AAAA
        dd 290, 0, 70, 740, 0xFFA5AAAA
        dd 890, 0, 70, 740, 0xFFA5AAAA
        dd 340, 590, 570, 60, 0xFFA5AAAA
        dd 0, 330, 1280, 60, 0xFF403C3C
        dd 300, 0, 50, 720, 0xFF403C3C
        dd 900, 0, 50, 720, 0xFF403C3C
        dd 350, 600, 550, 40, 0xFF403C3C
        dd 395, 200, 470, 115, 0xFF545050
        dd 410, 205, 2, 30, 0xFFDCDCDC
        dd 410, 280, 2, 30, 0xFFDCDCDC
        dd 470, 205, 2, 30, 0xFFDCDCDC
        dd 470, 280, 2, 30, 0xFFDCDCDC
        dd 530, 205, 2, 30, 0xFFDCDCDC
        dd 530, 280, 2, 30, 0xFFDCDCDC
        dd 590, 205, 2, 30, 0xFFDCDCDC
        dd 590, 280, 2, 30, 0xFFDCDCDC
        dd 650, 205, 2, 30, 0xFFDCDCDC
        dd 650, 280, 2, 30, 0xFFDCDCDC
        dd 710, 205, 2, 30, 0xFFDCDCDC
        dd 710, 280, 2, 30, 0xFFDCDCDC
        dd 770, 205, 2, 30, 0xFFDCDCDC
        dd 770, 280, 2, 30, 0xFFDCDCDC
        dd 830, 205, 2, 30, 0xFFDCDCDC
        dd 830, 280, 2, 30, 0xFFDCDCDC
        dd 10, 358, 20, 3, 0xFF3CC8E6
        dd 50, 358, 20, 3, 0xFF3CC8E6
        dd 90, 358, 20, 3, 0xFF3CC8E6
        dd 130, 358, 20, 3, 0xFF3CC8E6
        dd 170, 358, 20, 3, 0xFF3CC8E6
        dd 210, 358, 20, 3, 0xFF3CC8E6
        dd 250, 358, 20, 3, 0xFF3CC8E6
        dd 370, 358, 20, 3, 0xFF3CC8E6
        dd 410, 358, 20, 3, 0xFF3CC8E6
        dd 450, 358, 20, 3, 0xFF3CC8E6
        dd 490, 358, 20, 3, 0xFF3CC8E6
        dd 530, 358, 20, 3, 0xFF3CC8E6
        dd 570, 358, 20, 3, 0xFF3CC8E6
        dd 610, 358, 20, 3, 0xFF3CC8E6
        dd 650, 358, 20, 3, 0xFF3CC8E6
        dd 690, 358, 20, 3, 0xFF3CC8E6
        dd 730, 358, 20, 3, 0xFF3CC8E6
        dd 770, 358, 20, 3, 0xFF3CC8E6
        dd 810, 358, 20, 3, 0xFF3CC8E6
        dd 850, 358, 20, 3, 0xFF3CC8E6
        dd 970, 358, 20, 3, 0xFF3CC8E6
        dd 1010, 358, 20, 3, 0xFF3CC8E6
        dd 1050, 358, 20, 3, 0xFF3CC8E6
        dd 1090, 358, 20, 3, 0xFF3CC8E6
        dd 1130, 358, 20, 3, 0xFF3CC8E6
        dd 1170, 358, 20, 3, 0xFF3CC8E6
        dd 1210, 358, 20, 3, 0xFF3CC8E6
        dd 1250, 358, 20, 3, 0xFF3CC8E6
        dd 324, 10, 3, 20, 0xFF3CC8E6
        dd 324, 50, 3, 20, 0xFF3CC8E6
        dd 324, 90, 3, 20, 0xFF3CC8E6
        dd 324, 130, 3, 20, 0xFF3CC8E6
        dd 324, 170, 3, 20, 0xFF3CC8E6
        dd 324, 210, 3, 20, 0xFF3CC8E6
        dd 324, 250, 3, 20, 0xFF3CC8E6
        dd 324, 290, 3, 20, 0xFF3CC8E6
        dd 324, 410, 3, 20, 0xFF3CC8E6
        dd 324, 450, 3, 20, 0xFF3CC8E6
        dd 324, 490, 3, 20, 0xFF3CC8E6
        dd 324, 530, 3, 20, 0xFF3CC8E6
        dd 324, 570, 3, 20, 0xFF3CC8E6
        dd 324, 610, 3, 20, 0xFF3CC8E6
        dd 324, 650, 3, 20, 0xFF3CC8E6
        dd 324, 690, 3, 20, 0xFF3CC8E6
        dd 924, 10, 3, 20, 0xFF3CC8E6
        dd 924, 50, 3, 20, 0xFF3CC8E6
        dd 924, 90, 3, 20, 0xFF3CC8E6
        dd 924, 130, 3, 20, 0xFF3CC8E6
        dd 924, 170, 3, 20, 0xFF3CC8E6
        dd 924, 210, 3, 20, 0xFF3CC8E6
        dd 924, 250, 3, 20, 0xFF3CC8E6
        dd 924, 290, 3, 20, 0xFF3CC8E6
        dd 924, 410, 3, 20, 0xFF3CC8E6
        dd 924, 450, 3, 20, 0xFF3CC8E6
        dd 924, 490, 3, 20, 0xFF3CC8E6
        dd 924, 530, 3, 20, 0xFF3CC8E6
        dd 924, 570, 3, 20, 0xFF3CC8E6
        dd 924, 610, 3, 20, 0xFF3CC8E6
        dd 924, 650, 3, 20, 0xFF3CC8E6
        dd 924, 690, 3, 20, 0xFF3CC8E6
        dd 302, 318, 4, 10, 0xFFDCDCDC
        dd 310, 318, 4, 10, 0xFFDCDCDC
        dd 318, 318, 4, 10, 0xFFDCDCDC
        dd 326, 318, 4, 10, 0xFFDCDCDC
        dd 334, 318, 4, 10, 0xFFDCDCDC
        dd 342, 318, 4, 10, 0xFFDCDCDC
        dd 350, 318, 4, 10, 0xFFDCDCDC
        dd 302, 392, 4, 10, 0xFFDCDCDC
        dd 310, 392, 4, 10, 0xFFDCDCDC
        dd 318, 392, 4, 10, 0xFFDCDCDC
        dd 326, 392, 4, 10, 0xFFDCDCDC
        dd 334, 392, 4, 10, 0xFFDCDCDC
        dd 342, 392, 4, 10, 0xFFDCDCDC
        dd 350, 392, 4, 10, 0xFFDCDCDC
        dd 902, 318, 4, 10, 0xFFDCDCDC
        dd 910, 318, 4, 10, 0xFFDCDCDC
        dd 918, 318, 4, 10, 0xFFDCDCDC
        dd 926, 318, 4, 10, 0xFFDCDCDC
        dd 934, 318, 4, 10, 0xFFDCDCDC
        dd 942, 318, 4, 10, 0xFFDCDCDC
        dd 950, 318, 4, 10, 0xFFDCDCDC
        dd 902, 392, 4, 10, 0xFFDCDCDC
        dd 910, 392, 4, 10, 0xFFDCDCDC
        dd 918, 392, 4, 10, 0xFFDCDCDC
        dd 926, 392, 4, 10, 0xFFDCDCDC
        dd 934, 392, 4, 10, 0xFFDCDCDC
        dd 942, 392, 4, 10, 0xFFDCDCDC
        dd 950, 392, 4, 10, 0xFFDCDCDC
        dd 40, 40, 110, 110, 0xFF303237
        dd 43, 43, 104, 104, 0xFF5F6978
        dd 67, 67, 12, 10, 0xFFA5A0A0
        dd 114, 114, 10, 12, 0xFFA5A0A0
        dd 170, 60, 100, 90, 0xFF303237
        dd 173, 63, 94, 84, 0xFF545C69
        dd 195, 82, 12, 10, 0xFFA5A0A0
        dd 237, 120, 10, 12, 0xFFA5A0A0
        dd 40, 200, 90, 100, 0xFF303237
        dd 43, 203, 84, 94, 0xFF5F6978
        dd 62, 225, 12, 10, 0xFFA5A0A0
        dd 100, 267, 10, 12, 0xFFA5A0A0
        dd 160, 200, 110, 90, 0xFF303237
        dd 163, 203, 104, 84, 0xFF545C69
        dd 187, 222, 12, 10, 0xFFA5A0A0
        dd 234, 260, 10, 12, 0xFFA5A0A0
        dd 400, 40, 200, 140, 0xFF303237
        dd 403, 43, 194, 134, 0xFF5F6978
        dd 450, 75, 12, 10, 0xFFA5A0A0
        dd 534, 134, 10, 12, 0xFFA5A0A0
        dd 650, 40, 220, 100, 0xFF303237
        dd 653, 43, 214, 94, 0xFF545C69
        dd 705, 65, 12, 10, 0xFFA5A0A0
        dd 797, 107, 10, 12, 0xFFA5A0A0
        dd 380, 420, 150, 150, 0xFF303237
        dd 383, 423, 144, 144, 0xFF5F6978
        dd 417, 457, 12, 10, 0xFFA5A0A0
        dd 480, 520, 10, 12, 0xFFA5A0A0
        dd 560, 420, 120, 90, 0xFF303237
        dd 563, 423, 114, 84, 0xFF545C69
        dd 590, 442, 12, 10, 0xFFA5A0A0
        dd 640, 480, 10, 12, 0xFFA5A0A0
        dd 720, 420, 150, 150, 0xFF303237
        dd 723, 423, 144, 144, 0xFF5F6978
        dd 757, 457, 12, 10, 0xFFA5A0A0
        dd 820, 520, 10, 12, 0xFFA5A0A0
        dd 370, 665, 100, 45, 0xFF303237
        dd 373, 668, 94, 39, 0xFF545C69
        dd 373, 686, 94, 2, 0xFF464E5A
        dd 500, 665, 120, 45, 0xFF303237
        dd 503, 668, 114, 39, 0xFF5F6978
        dd 503, 686, 114, 2, 0xFF464E5A
        dd 650, 665, 100, 45, 0xFF303237
        dd 653, 668, 94, 39, 0xFF545C69
        dd 653, 686, 94, 2, 0xFF464E5A
        dd 780, 665, 100, 45, 0xFF303237
        dd 783, 668, 94, 39, 0xFF5F6978
        dd 783, 686, 94, 2, 0xFF464E5A
        dd 990, 430, 120, 110, 0xFF303237
        dd 993, 433, 114, 104, 0xFF545C69
        dd 1020, 457, 12, 10, 0xFFA5A0A0
        dd 1070, 504, 10, 12, 0xFFA5A0A0
        dd 1140, 430, 110, 160, 0xFF303237
        dd 1143, 433, 104, 154, 0xFF5F6978
        dd 1167, 470, 12, 10, 0xFFA5A0A0
        dd 1214, 537, 10, 12, 0xFFA5A0A0
        dd 990, 590, 120, 100, 0xFF303237
        dd 993, 593, 114, 94, 0xFF545C69
        dd 1020, 615, 12, 10, 0xFFA5A0A0
        dd 1070, 657, 10, 12, 0xFFA5A0A0
        dd 40, 420, 230, 270, 0xFFAABEC8
        dd 65, 420, 1, 270, 0xFF9BAFB9
        dd 90, 420, 1, 270, 0xFF9BAFB9
        dd 115, 420, 1, 270, 0xFF9BAFB9
        dd 140, 420, 1, 270, 0xFF9BAFB9
        dd 165, 420, 1, 270, 0xFF9BAFB9
        dd 190, 420, 1, 270, 0xFF9BAFB9
        dd 215, 420, 1, 270, 0xFF9BAFB9
        dd 240, 420, 1, 270, 0xFF9BAFB9
        dd 265, 420, 1, 270, 0xFF9BAFB9
        dd 40, 445, 230, 1, 0xFF9BAFB9
        dd 40, 470, 230, 1, 0xFF9BAFB9
        dd 40, 495, 230, 1, 0xFF9BAFB9
        dd 40, 520, 230, 1, 0xFF9BAFB9
        dd 40, 545, 230, 1, 0xFF9BAFB9
        dd 40, 570, 230, 1, 0xFF9BAFB9
        dd 40, 595, 230, 1, 0xFF9BAFB9
        dd 40, 620, 230, 1, 0xFF9BAFB9
        dd 40, 645, 230, 1, 0xFF9BAFB9
        dd 40, 670, 230, 1, 0xFF9BAFB9
        dd 120, 410, 40, 10, 0xFF5A7896
        dd 270, 520, 10, 40, 0xFF5A7896
        dd 980, 40, 250, 250, 0xFFAABEC8
        dd 1005, 40, 1, 250, 0xFF9BAFB9
        dd 1030, 40, 1, 250, 0xFF9BAFB9
        dd 1055, 40, 1, 250, 0xFF9BAFB9
        dd 1080, 40, 1, 250, 0xFF9BAFB9
        dd 1105, 40, 1, 250, 0xFF9BAFB9
        dd 1130, 40, 1, 250, 0xFF9BAFB9
        dd 1155, 40, 1, 250, 0xFF9BAFB9
        dd 1180, 40, 1, 250, 0xFF9BAFB9
        dd 1205, 40, 1, 250, 0xFF9BAFB9
        dd 980, 65, 250, 1, 0xFF9BAFB9
        dd 980, 90, 250, 1, 0xFF9BAFB9
        dd 980, 115, 250, 1, 0xFF9BAFB9
        dd 980, 140, 250, 1, 0xFF9BAFB9
        dd 980, 165, 250, 1, 0xFF9BAFB9
        dd 980, 190, 250, 1, 0xFF9BAFB9
        dd 980, 215, 250, 1, 0xFF9BAFB9
        dd 980, 240, 250, 1, 0xFF9BAFB9
        dd 980, 265, 250, 1, 0xFF9BAFB9
        dd 1080, 290, 40, 10, 0xFF5A7896
        dd 970, 130, 10, 40, 0xFF5A7896
        dd 420, 215, 40, 20, 0xFFD2C8C8
        dd 428, 218, 6, 14, 0xFF503C32
        dd 448, 218, 5, 14, 0xFF503C32
        dd 480, 215, 40, 20, 0xFF2828AA
        dd 488, 218, 6, 14, 0xFF503C32
        dd 508, 218, 5, 14, 0xFF503C32
        dd 600, 215, 40, 20, 0xFF964628
        dd 608, 218, 6, 14, 0xFF503C32
        dd 628, 218, 5, 14, 0xFF503C32
        dd 720, 215, 40, 20, 0xFF46C8DC
        dd 728, 218, 6, 14, 0xFF503C32
        dd 748, 218, 5, 14, 0xFF503C32
        dd 780, 215, 40, 20, 0xFF8C3278
        dd 788, 218, 6, 14, 0xFF503C32
        dd 808, 218, 5, 14, 0xFF503C32
        dd 420, 275, 40, 20, 0xFFE6E6E6
        dd 428, 278, 6, 14, 0xFF503C32
        dd 448, 278, 5, 14, 0xFF503C32
        dd 540, 275, 40, 20, 0xFF5A8C5A
        dd 548, 278, 6, 14, 0xFF503C32
        dd 568, 278, 5, 14, 0xFF503C32
        dd 660, 275, 40, 20, 0xFF285A96
        dd 668, 278, 6, 14, 0xFF503C32
        dd 688, 278, 5, 14, 0xFF503C32
        dd 820, 275, 40, 20, 0xFFD2C8C8
        dd 828, 278, 6, 14, 0xFF503C32
        dd 848, 278, 5, 14, 0xFF503C32
        dd 640, 607, 40, 20, 0xFF2828AA
        dd 648, 610, 6, 14, 0xFF503C32
        dd 668, 610, 5, 14, 0xFF503C32
        dd 540, 540, 26, 16, 0xFF325A28
        dd 540, 547, 26, 2, 0xFF26411E
        dd 690, 540, 26, 16, 0xFF325A28
        dd 690, 547, 26, 2, 0xFF26411E
        dd 1115, 610, 16, 26, 0xFF325A28
        dd 1122, 610, 2, 26, 0xFF26411E
        dd 180, 300, 26, 16, 0xFF325A28
        dd 180, 307, 26, 2, 0xFF26411E
        dd 880, 150, 16, 26, 0xFF325A28
        dd 887, 150, 2, 26, 0xFF26411E
        dd 390, 195, 480, 4, 0xFF3C648C
        dd 390, 194, 3, 6, 0xFF284664
        dd 406, 194, 3, 6, 0xFF284664
        dd 422, 194, 3, 6, 0xFF284664
        dd 438, 194, 3, 6, 0xFF284664
        dd 454, 194, 3, 6, 0xFF284664
        dd 470, 194, 3, 6, 0xFF284664
        dd 486, 194, 3, 6, 0xFF284664
        dd 502, 194, 3, 6, 0xFF284664
        dd 518, 194, 3, 6, 0xFF284664
        dd 534, 194, 3, 6, 0xFF284664
        dd 550, 194, 3, 6, 0xFF284664
        dd 566, 194, 3, 6, 0xFF284664
        dd 582, 194, 3, 6, 0xFF284664
        dd 598, 194, 3, 6, 0xFF284664
        dd 614, 194, 3, 6, 0xFF284664
        dd 630, 194, 3, 6, 0xFF284664
        dd 646, 194, 3, 6, 0xFF284664
        dd 662, 194, 3, 6, 0xFF284664
        dd 678, 194, 3, 6, 0xFF284664
        dd 694, 194, 3, 6, 0xFF284664
        dd 710, 194, 3, 6, 0xFF284664
        dd 726, 194, 3, 6, 0xFF284664
        dd 742, 194, 3, 6, 0xFF284664
        dd 758, 194, 3, 6, 0xFF284664
        dd 774, 194, 3, 6, 0xFF284664
        dd 790, 194, 3, 6, 0xFF284664
        dd 806, 194, 3, 6, 0xFF284664
        dd 822, 194, 3, 6, 0xFF284664
        dd 838, 194, 3, 6, 0xFF284664
        dd 854, 194, 3, 6, 0xFF284664
        dd 390, 315, 4, 15, 0xFF3C648C
        dd 389, 315, 6, 3, 0xFF284664
        dd 866, 199, 4, 116, 0xFF3C648C
        dd 865, 199, 6, 3, 0xFF284664
        dd 865, 215, 6, 3, 0xFF284664
        dd 865, 231, 6, 3, 0xFF284664
        dd 865, 247, 6, 3, 0xFF284664
        dd 865, 263, 6, 3, 0xFF284664
        dd 865, 279, 6, 3, 0xFF284664
        dd 865, 295, 6, 3, 0xFF284664
        dd 865, 311, 6, 3, 0xFF284664
        dd 150, 160, 4, 40, 0xFF3C648C
        dd 149, 160, 6, 3, 0xFF284664
        dd 149, 176, 6, 3, 0xFF284664
        dd 149, 192, 6, 3, 0xFF284664
        dd 1120, 560, 4, 30, 0xFF3C648C
        dd 1119, 560, 6, 3, 0xFF284664
        dd 1119, 576, 6, 3, 0xFF284664
    bg_rects_count equ ($ - bg_rects) / 20
;; ---- END MAP DATA ----

    back_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq back_buffer
        at FrameBuffer.pitch,  dd OUR_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd WINDOW_H
    iend

    ; the neighborhood's look, drawn once (render_background)
    bg_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq bg_buffer
        at FrameBuffer.pitch,  dd OUR_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd SCREEN_H
    iend

    ; ---- the scoreboard font: 5x7, hand-made ----
    ; One glyph per ASCII code from ' ' (32) to 'Z' (90), 7 bytes each,
    ; one per row, top first. Bit 4 is the leftmost pixel, so each row
    ; reads like the picture it draws. Codes with no glyph are blank.
    ; GLYPH checks at build time that the table stays in ASCII order.
%macro GLYPH 8
    %if %1 != font_next
        %error "font glyphs out of order"
    %endif
    db %2, %3, %4, %5, %6, %7, %8
    %assign font_next font_next + 1
%endmacro
%macro GLYPH_BLANK 1
    %if %1 != font_next
        %error "font glyphs out of order"
    %endif
    times FONT_ROWS db 0
    %assign font_next font_next + 1
%endmacro
    %assign font_next FONT_FIRST
    font:
    GLYPH_BLANK 32        ; ' '
    GLYPH '!', 00100b, 00100b, 00100b, 00100b, 00100b, 00000b, 00100b
    GLYPH_BLANK 34
    GLYPH_BLANK 35
    GLYPH_BLANK 36
    GLYPH_BLANK 37
    GLYPH_BLANK 38
    GLYPH_BLANK 39
    GLYPH_BLANK 40
    GLYPH_BLANK 41
    GLYPH_BLANK 42
    GLYPH_BLANK 43
    GLYPH_BLANK 44
    GLYPH '-', 00000b, 00000b, 00000b, 11111b, 00000b, 00000b, 00000b
    GLYPH '.', 00000b, 00000b, 00000b, 00000b, 00000b, 01100b, 01100b
    GLYPH '/', 00001b, 00010b, 00010b, 00100b, 01000b, 01000b, 10000b
    GLYPH '0', 01110b, 10001b, 10011b, 10101b, 11001b, 10001b, 01110b
    GLYPH '1', 00100b, 01100b, 00100b, 00100b, 00100b, 00100b, 01110b
    GLYPH '2', 01110b, 10001b, 00001b, 00010b, 00100b, 01000b, 11111b
    GLYPH '3', 11111b, 00010b, 00100b, 00010b, 00001b, 10001b, 01110b
    GLYPH '4', 00010b, 00110b, 01010b, 10010b, 11111b, 00010b, 00010b
    GLYPH '5', 11111b, 10000b, 11110b, 00001b, 00001b, 10001b, 01110b
    GLYPH '6', 00110b, 01000b, 10000b, 11110b, 10001b, 10001b, 01110b
    GLYPH '7', 11111b, 00001b, 00010b, 00100b, 01000b, 01000b, 01000b
    GLYPH '8', 01110b, 10001b, 10001b, 01110b, 10001b, 10001b, 01110b
    GLYPH '9', 01110b, 10001b, 10001b, 01111b, 00001b, 00010b, 01100b
    GLYPH ':', 00000b, 01100b, 01100b, 00000b, 01100b, 01100b, 00000b
    GLYPH_BLANK 59
    GLYPH_BLANK 60
    GLYPH_BLANK 61
    GLYPH_BLANK 62
    GLYPH_BLANK 63
    GLYPH_BLANK 64
    GLYPH 'A', 01110b, 10001b, 10001b, 11111b, 10001b, 10001b, 10001b
    GLYPH 'B', 11110b, 10001b, 10001b, 11110b, 10001b, 10001b, 11110b
    GLYPH 'C', 01110b, 10001b, 10000b, 10000b, 10000b, 10001b, 01110b
    GLYPH 'D', 11100b, 10010b, 10001b, 10001b, 10001b, 10010b, 11100b
    GLYPH 'E', 11111b, 10000b, 10000b, 11110b, 10000b, 10000b, 11111b
    GLYPH 'F', 11111b, 10000b, 10000b, 11110b, 10000b, 10000b, 10000b
    GLYPH 'G', 01110b, 10001b, 10000b, 10111b, 10001b, 10001b, 01111b
    GLYPH 'H', 10001b, 10001b, 10001b, 11111b, 10001b, 10001b, 10001b
    GLYPH 'I', 01110b, 00100b, 00100b, 00100b, 00100b, 00100b, 01110b
    GLYPH 'J', 00111b, 00010b, 00010b, 00010b, 00010b, 10010b, 01100b
    GLYPH 'K', 10001b, 10010b, 10100b, 11000b, 10100b, 10010b, 10001b
    GLYPH 'L', 10000b, 10000b, 10000b, 10000b, 10000b, 10000b, 11111b
    GLYPH 'M', 10001b, 11011b, 10101b, 10101b, 10001b, 10001b, 10001b
    GLYPH 'N', 10001b, 10001b, 11001b, 10101b, 10011b, 10001b, 10001b
    GLYPH 'O', 01110b, 10001b, 10001b, 10001b, 10001b, 10001b, 01110b
    GLYPH 'P', 11110b, 10001b, 10001b, 11110b, 10000b, 10000b, 10000b
    GLYPH 'Q', 01110b, 10001b, 10001b, 10001b, 10101b, 10010b, 01101b
    GLYPH 'R', 11110b, 10001b, 10001b, 11110b, 10100b, 10010b, 10001b
    GLYPH 'S', 01111b, 10000b, 10000b, 01110b, 00001b, 00001b, 11110b
    GLYPH 'T', 11111b, 00100b, 00100b, 00100b, 00100b, 00100b, 00100b
    GLYPH 'U', 10001b, 10001b, 10001b, 10001b, 10001b, 10001b, 01110b
    GLYPH 'V', 10001b, 10001b, 10001b, 10001b, 10001b, 01010b, 00100b
    GLYPH 'W', 10001b, 10001b, 10001b, 10101b, 10101b, 10101b, 01010b
    GLYPH 'X', 10001b, 10001b, 01010b, 00100b, 01010b, 10001b, 10001b
    GLYPH 'Y', 10001b, 10001b, 10001b, 01010b, 00100b, 00100b, 00100b
    GLYPH 'Z', 11111b, 00001b, 00010b, 00100b, 01000b, 10000b, 11111b
    %if font_next != FONT_LAST + 1
        %error "font table doesn't end at FONT_LAST"
    %endif
    hud_blue db "CRIPS "
    hud_blue_len equ $ - hud_blue
    hud_red db "BLOODS "
    hud_red_len equ $ - hud_red
    hud_wins db " WIN"
    hud_wins_len equ $ - hud_wins
    hud_gap db "   "
    hud_gap_len equ $ - hud_gap

;; ---- SPRITE DATA (generated by tools/gen_sprites.py; don't edit by hand) ----
    ; 16x16 palette indices, one byte per pixel; sprite = pose * 2 + walk frame,
    ; poses N, NE, E, SE, S (W, NW, SW are E, NE, SE mirrored)
    soldier_sprites:
        ; N frame 0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,1,1,2,2,1,1,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,0,5,4,4,4,4,4,4,5,0,0,10,0
        db 0,0,0,5,4,4,4,4,4,4,4,4,5,9,10,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,9,11,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,0,11,0
        db 0,0,0,3,0,4,4,4,4,4,4,0,3,0,0,0
        db 0,0,0,0,0,6,6,6,6,6,6,0,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,0,0,0,7,7,0,0,7,7,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; N frame 1
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,1,1,2,2,1,1,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,0,5,4,4,4,4,4,4,5,0,0,10,0
        db 0,0,0,5,4,4,4,4,4,4,4,4,5,9,10,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,9,11,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,0,11,0
        db 0,0,0,3,0,4,4,4,4,4,4,0,3,0,0,0
        db 0,0,0,0,0,6,6,6,6,6,6,0,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,0,0,0,7,7,0,0,6,6,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,7,7,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; NE frame 0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10
        db 0,0,0,0,0,0,0,1,1,1,1,0,0,0,9,0
        db 0,0,0,0,0,0,1,1,1,1,1,1,0,9,11,0
        db 0,0,0,0,0,0,1,2,2,1,1,1,9,11,0,0
        db 0,0,0,0,0,0,1,1,1,1,1,3,0,0,0,0
        db 0,0,0,0,0,0,0,1,1,1,3,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,0,5,4,4,4,4,4,4,4,3,3,0,0
        db 0,0,0,0,4,4,4,4,4,4,4,4,0,0,0,0
        db 0,0,0,0,3,4,4,4,4,4,4,4,0,0,0,0
        db 0,0,0,0,0,4,4,4,4,4,4,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,6,6,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,0,0,6,6,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,0,0,6,6,0,0,0
        db 0,0,0,0,0,7,7,0,0,0,0,0,7,7,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; NE frame 1
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,10
        db 0,0,0,0,0,0,0,1,1,1,1,0,0,0,9,0
        db 0,0,0,0,0,0,1,1,1,1,1,1,0,9,11,0
        db 0,0,0,0,0,0,1,2,2,1,1,1,9,11,0,0
        db 0,0,0,0,0,0,1,1,1,1,1,3,0,0,0,0
        db 0,0,0,0,0,0,0,1,1,1,3,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,0,5,4,4,4,4,4,4,4,3,3,0,0
        db 0,0,0,0,4,4,4,4,4,4,4,4,0,0,0,0
        db 0,0,0,0,3,4,4,4,4,4,4,4,0,0,0,0
        db 0,0,0,0,0,4,4,4,4,4,4,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,6,6,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,6,6,0,0,0,0,0
        db 0,0,0,0,0,0,0,6,6,6,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,7,7,7,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; E frame 0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,2,2,2,2,0,0,0,0,0,0
        db 0,0,0,0,0,2,2,2,2,2,1,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,3,3,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,3,3,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,3,3,0,0,0,0,0,0
        db 0,0,0,0,0,0,4,4,8,4,0,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,4,4,4,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,4,4,4,3,3,9,11,10
        db 0,0,0,0,0,5,4,4,4,4,4,0,0,11,0,0
        db 0,0,0,0,0,0,4,4,4,4,0,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,6,0,0,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,0,6,6,0,0,0,0
        db 0,0,0,0,0,7,7,0,0,0,7,7,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; E frame 1
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,2,2,2,2,0,0,0,0,0,0
        db 0,0,0,0,0,2,2,2,2,2,1,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,3,3,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,3,3,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,3,3,0,0,0,0,0,0
        db 0,0,0,0,0,0,4,4,8,4,0,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,4,4,4,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,4,4,4,3,3,9,11,10
        db 0,0,0,0,0,5,4,4,4,4,4,0,0,11,0,0
        db 0,0,0,0,0,0,4,4,4,4,0,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,6,0,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,6,6,6,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,7,7,7,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; SE frame 0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,2,2,2,2,0,0,0,0,0
        db 0,0,0,0,0,0,2,2,2,2,2,2,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,3,1,0,0,0,0
        db 0,0,0,0,0,0,1,3,3,3,3,3,0,0,0,0
        db 0,0,0,0,0,0,0,3,3,3,3,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,8,8,4,4,0,0,0,0
        db 0,0,0,0,5,4,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,0,4,4,4,4,4,4,4,4,3,3,0,0
        db 0,0,0,0,3,4,4,4,4,4,4,4,0,9,11,0
        db 0,0,0,0,0,4,4,4,4,4,4,0,0,0,9,11
        db 0,0,0,0,0,0,6,6,6,6,6,0,0,0,0,10
        db 0,0,0,0,0,0,6,6,0,0,6,6,0,0,0,0
        db 0,0,0,0,0,6,6,0,0,0,0,6,6,0,0,0
        db 0,0,0,0,0,7,7,0,0,0,0,0,7,7,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; SE frame 1
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,2,2,2,2,0,0,0,0,0
        db 0,0,0,0,0,0,2,2,2,2,2,2,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,3,1,0,0,0,0
        db 0,0,0,0,0,0,1,3,3,3,3,3,0,0,0,0
        db 0,0,0,0,0,0,0,3,3,3,3,0,0,0,0,0
        db 0,0,0,0,0,5,4,4,8,8,4,4,0,0,0,0
        db 0,0,0,0,5,4,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,0,4,4,4,4,4,4,4,4,3,3,0,0
        db 0,0,0,0,3,4,4,4,4,4,4,4,0,9,11,0
        db 0,0,0,0,0,4,4,4,4,4,4,0,0,0,9,11
        db 0,0,0,0,0,0,6,6,6,6,6,0,0,0,0,10
        db 0,0,0,0,0,0,6,6,6,6,6,0,0,0,0,0
        db 0,0,0,0,0,0,0,6,6,6,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,7,7,7,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; S frame 0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,2,2,2,2,0,0,0,0,0,0
        db 0,0,0,0,0,2,2,2,2,2,2,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,1,3,3,3,3,1,0,0,0,0,0
        db 0,0,0,0,0,0,3,3,3,3,0,0,0,0,0,0
        db 0,0,0,0,5,4,4,8,8,4,4,5,0,0,0,0
        db 0,0,0,5,4,4,4,4,4,4,4,4,5,0,0,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,3,0,4,4,4,4,4,4,0,3,0,0,0
        db 0,0,9,11,0,6,6,6,6,6,6,0,0,0,0,0
        db 0,0,9,11,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,10,0,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,10,0,0,7,7,0,0,7,7,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        ; S frame 1
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,2,2,2,2,0,0,0,0,0,0
        db 0,0,0,0,0,2,2,2,2,2,2,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,1,3,3,3,3,1,0,0,0,0,0
        db 0,0,0,0,0,0,3,3,3,3,0,0,0,0,0,0
        db 0,0,0,0,5,4,4,8,8,4,4,5,0,0,0,0
        db 0,0,0,5,4,4,4,4,4,4,4,4,5,0,0,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,3,4,4,4,4,4,4,4,4,3,0,0,0
        db 0,0,0,3,0,4,4,4,4,4,4,0,3,0,0,0
        db 0,0,9,11,0,6,6,6,6,6,6,0,0,0,0,0
        db 0,0,9,11,0,6,6,0,0,6,6,0,0,0,0,0
        db 0,0,10,0,0,6,6,0,0,7,7,0,0,0,0,0
        db 0,0,10,0,0,7,7,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    SPRITE_COUNT equ ($ - soldier_sprites) / 256
;; ---- END SPRITE DATA ----

    ; per gang: shirt, shirt shadow, bandana
    gang_colours:
        dd 0xFFDC783C, 0xFF963C1E, 0xFFFF965A     ; Crips: blues
        dd 0xFF3C3CDC, 0xFF1E1E96, 0xFF5050FF     ; Bloods: reds
    skin_tones:
        dd 0xFFA0C3EB, 0xFF648CBE, 0xFF375078
    ; facing (0 N, 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W, 7 NW) -> pose, mirrored
    facing_pose:
        db 0, 0,  1, 0,  2, 0,  3, 0,  4, 0,  3, 1,  2, 1,  1, 1

    ; flow_waypoint's neighbour order: dx (times the team's forward
    ; sign), dy. Orthogonal first, so on a tie a straight step wins
    flow_dirs:
        db  1,  0,   0, -1,   0,  1,  -1,  0
        db  1, -1,   1,  1,  -1, -1,  -1,  1

section .bss
    walkable    resb GRID_CELLS         ; 1 = a soldier fits anywhere in the cell
    field_to0   resw GRID_CELLS         ; BFS distances, UNREACHED = none
    field_to1   resw GRID_CELLS
    field_pk    resw GRID_CELLS
    bfs_queue   resd GRID_CELLS         ; each cell is queued at most once
    bfs_field   resq 1                  ; the field bfs_seed/bfs_run work on
    bfs_tail    resd 1
    flow_wx     resd 1                  ; flow_waypoint's answer
    flow_wy     resd 1
    back_buffer resb SCREEN_W * WINDOW_H * 4
    hud_buf     resb 64                 ; one scoreboard string at a time
    ; ---- sprite drawing state (drawing only) ----
    sprite_seen   resd TOTAL_SOLDIERS   ; 1 once drawn: last_x/y are valid
    sprite_last_x resd TOTAL_SOLDIERS
    sprite_last_y resd TOTAL_SOLDIERS
    sprite_facing resd TOTAL_SOLDIERS   ; 0 N .. 7 NW, clockwise
    sprite_walk   resd TOTAL_SOLDIERS   ; pixels walked: picks the frame
    pal_buf       resd PAL_SIZE         ; this sprite's colours
    respawn_timer resd TOTAL_SOLDIERS   ; >0: dead, back when it counts
                                        ; down (stays at 1 until a spot
                                        ; is free)
    protect_timer resd TOTAL_SOLDIERS   ; >0: hits do no damage
    lives_left    resd TOTAL_SOLDIERS   ; respawns this soldier has
                                        ; left, -1 = unlimited
    soldiers    resb TOTAL_SOLDIERS * Soldier_size
    pickups     resb MAX_PICKUPS * Pickup_size
    bg_buffer   resb SCREEN_W * SCREEN_H * 4
    blockmap    resb BM_W * BM_H        ; BLOCK_* bits per corner position
    lb_mask     resd 1                  ; which blockmap bit line_blocked tests
    effects     resb MAX_EFFECTS * Effect_size
    fx_next     resd 1                  ; next ring-buffer slot to fill
    hit_flash    resd TOTAL_SOLDIERS    ; frames left drawn white
    death_linger resd TOTAL_SOLDIERS    ; frames a dead soldier stays drawn
    msg_buf      resb 160               ; the win line, built by print_result
    title_buf    resb 64                ; window title, built by build_title

section .text
main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    sub rsp, STACK_LOCALS_SIZE

    ; seed FIRST -- the spawn functions below draw random numbers
    call rng_seed
    call seed_from_env
    mov rax, [rng_state]
    mov [game_seed], rax

    call read_rules
    call choose_sides
    call build_blockmap
    call build_walkable
    call spawn_soldiers
    call spawn_pickups

    call is_headless
    test eax, eax
    jz .windowed

    ; ---- headless: update until someone wins or MAX_TICKS ----
.hl_loop:
    call update_soldiers
    inc dword [ticks]
    call check_win
    test eax, eax
    jnz .hl_won
    cmp dword [ticks], MAX_TICKS
    jb .hl_loop
    mov dword [show_seed], 1       ; so the stalemate can be replayed
    lea rsi, [stalemate_msg]
    mov edx, stalemate_msg_len
    call print_result
    jmp .cleanup_none
.hl_won:
    call print_winner
    jmp .cleanup_none

.windowed:
    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    test eax, eax
    js .cleanup_none

    call build_title
    lea rdi, [title_buf]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, SCREEN_W
    mov r8d, WINDOW_H
    mov r9d, SDL_WINDOW_SHOWN
    call SDL_CreateWindow
    mov r12, rax
    test r12, r12
    jz .cleanup_sdl

    mov rdi, r12
    mov esi, -1
    mov edx, SDL_RENDERER_ACCELERATED
    call SDL_CreateRenderer
    mov r13, rax
    test r13, r13
    jz .cleanup_window

    mov rdi, r13
    mov esi, SDL_PIXELFORMAT_RGBA32
    mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, SCREEN_W
    mov r8d, WINDOW_H
    call SDL_CreateTexture
    mov r14, rax
    test r14, r14
    jz .cleanup_renderer

    call render_background         ; once: the whole neighborhood

.loop:
    call SDL_GetTicks
    mov ebx, eax

.poll_events:
    lea rdi, [rsp + EVENT_OFF]
    call SDL_PollEvent
    test eax, eax
    jz .update
    mov eax, [rsp + EVENT_OFF]
    cmp eax, SDL_QUIT_EVENT
    je .cleanup_all
    jmp .poll_events

.update:
    cmp dword [game_over], 0
    jne .render

    call update_soldiers
    inc dword [ticks]
    call check_win
    test eax, eax
    jz .render
    mov [game_over], eax
    call print_winner

.render:
    ; ---- the neighborhood: one copy of the pre-drawn background ----
    lea rsi, [bg_buffer]
    lea rdi, [back_buffer]
    mov ecx, SCREEN_W * SCREEN_H / 2    ; 8 bytes (2 pixels) per movsq
    cld
    rep movsq

    ; ---- active weapon pickups ----
    mov dword [rsp + LOOP_I_OFF], 0
.pickup_draw_loop:
    mov eax, [rsp + LOOP_I_OFF]
    cmp eax, MAX_PICKUPS
    jge .pickup_draw_done

    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax

    cmp dword [r10 + Pickup.active], 0
    je .pickup_draw_next

    mov eax, [r10 + Pickup.type]
    cmp eax, WEAPON_PISTOL
    jne .pickup_shotgun_color
    mov r9d, COLOR_PICKUP_PISTOL
    jmp .pickup_have_color
.pickup_shotgun_color:
    mov r9d, COLOR_PICKUP_SHOTGUN
.pickup_have_color:
    lea rdi, [back_fb]
    mov esi, [r10 + Pickup.x]
    mov edx, [r10 + Pickup.y]
    mov ecx, PICKUP_SIZE
    mov r8d, PICKUP_SIZE
    call fill_rect

.pickup_draw_next:
    mov eax, [rsp + LOOP_I_OFF]
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .pickup_draw_loop
.pickup_draw_done:

    ; ---- soldiers ----
    mov dword [rsp + LOOP_I_OFF], 0
.draw_loop:
    mov eax, [rsp + LOOP_I_OFF]
    cmp eax, TOTAL_SOLDIERS
    jge .draw_done

    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    ; dead soldiers stay drawn while death_linger runs, so the shot
    ; that killed them has something to land on
    mov eax, [rsp + LOOP_I_OFF]
    cmp dword [r10 + Soldier.health], 0
    jg .draw_visible
    lea rcx, [death_linger]
    cmp dword [rcx + rax*4], 0
    jle .draw_next
.draw_visible:

    ; spawn protection: blink, 4 frames on, 4 off
    lea rcx, [protect_timer]
    cmp dword [rcx + rax*4], 0
    jle .no_blink
    test dword [ticks], 4
    jnz .draw_next
.no_blink:

    mov edi, eax
    call draw_soldier

.draw_next:
    ; count down this soldier's flash and linger timers, once per frame
    mov eax, [rsp + LOOP_I_OFF]
    lea rcx, [hit_flash]
    cmp dword [rcx + rax*4], 0
    jle .flash_done
    dec dword [rcx + rax*4]
.flash_done:
    lea rcx, [death_linger]
    cmp dword [rcx + rax*4], 0
    jle .linger_done
    dec dword [rcx + rax*4]
.linger_done:
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .draw_loop
.draw_done:

    call draw_bosses               ; the Big Homies' health bars
    call draw_events               ; police car, walker, dog

    ; ---- attack effects, on top of everything ----
    call draw_effects

    ; ---- scoreboard, last: it also covers any spark that strayed
    ; below the field ----
    call draw_hud

    mov rdi, r14
    xor esi, esi
    lea rdx, [rsp + LOCK_PIXELS_OFF]
    lea rcx, [rsp + LOCK_PITCH_OFF]
    call SDL_LockTexture
    test eax, eax
    js .cleanup_all

    mov r10, [rsp + LOCK_PIXELS_OFF]
    mov r11d, [rsp + LOCK_PITCH_OFF]

    xor r15d, r15d
.blit_row_loop:
    cmp r15d, WINDOW_H
    jge .blit_done

    lea rsi, [back_buffer]
    mov eax, r15d
    imul eax, OUR_PITCH
    add rsi, rax

    mov rdi, r10
    mov eax, r15d
    imul eax, r11d
    add rdi, rax

    mov ecx, SCREEN_W * 4
    cld
    rep movsb

    inc r15d
    jmp .blit_row_loop
.blit_done:

    mov rdi, r14
    call SDL_UnlockTexture

    mov rdi, r13
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call SDL_RenderCopy

    mov rdi, r13
    call SDL_RenderPresent

    call SDL_GetTicks
    sub eax, ebx
    cmp eax, FRAME_BUDGET_MS
    jge .loop
    mov ecx, FRAME_BUDGET_MS
    sub ecx, eax
    mov edi, ecx
    call SDL_Delay
    jmp .loop

.cleanup_all:
    mov rdi, r14
    call SDL_DestroyTexture
.cleanup_renderer:
    mov rdi, r13
    call SDL_DestroyRenderer
.cleanup_window:
    mov rdi, r12
    call SDL_DestroyWindow
.cleanup_sdl:
    call SDL_Quit
.cleanup_none:
    add rsp, STACK_LOCALS_SIZE
    add rsp, 8
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; void rng_seed(void)
;
; rdtsc puts the CPU's cycle counter in edx:eax. Using it raw would
; work, but xorshift is linear: two seeds that differ in a few low bits
; (two launches close together) produce early outputs that also differ
; in only a few bits. splitmix64's finalizer -- add a constant, then
; xor-shift/multiply three times -- scrambles every input bit across
; the whole 64-bit state first. It's the standard way to seed the
; xorshift family.
;
; xorshift has exactly one bad state: 0, which maps to 0 forever. The
; mix makes that astronomically unlikely, but it costs two instructions
; to rule it out entirely.
rng_seed:
    rdtsc
    shl rdx, 32
    or rax, rdx                          ; rax = full 64-bit timestamp

    mov rdx, 0x9E3779B97F4A7C15
    add rax, rdx
    mov rdx, rax
    shr rdx, 30
    xor rax, rdx
    mov rdx, 0xBF58476D1CE4E5B9
    imul rax, rdx
    mov rdx, rax
    shr rdx, 27
    xor rax, rdx
    mov rdx, 0x94D049BB133111EB
    imul rax, rdx
    mov rdx, rax
    shr rdx, 31
    xor rax, rdx

    test rax, rax
    jnz .seed_ok
    mov rax, 0x9E3779B97F4A7C15          ; any nonzero constant
.seed_ok:
    mov [rng_state], rax
    ret


; uint32 rng_next(void) -> eax
;
; Marsaglia's xorshift64: x ^= x << 13; x ^= x >> 7; x ^= x << 17.
; Three shift-and-xor steps, no multiply, no divide. Period 2^64 - 1:
; it visits every nonzero 64-bit value exactly once before repeating.
;
; Returns the HIGH 32 bits. The low bits of a plain xorshift are its
; weakest (they fail some statistical tests the high bits pass), and
; update_soldiers uses exactly one bit of every draw (`and eax, 1`)
; to pick the processing direction -- the same fairness fix whose
; accidental removal was stage6b's bug #2. Handing it the best bit we
; have costs one `shr`.
;
; Clobbers only rax and rdx (rand() was free to clobber every
; caller-saved register, so every call site already assumes worse).
rng_next:
    mov rax, [rng_state]
    mov rdx, rax
    shl rdx, 13
    xor rax, rdx
    mov rdx, rax
    shr rdx, 7
    xor rax, rdx
    mov rdx, rax
    shl rdx, 17
    xor rax, rdx
    mov [rng_state], rax
    shr rax, 32
    ret


; int rand_range(int n: edi) -> eax in [0, n)
; rng_next() % n. The modulo is very slightly biased toward small
; values (2^32 isn't a multiple of n), by at most n / 2^32 -- about
; one part in 8 million for the largest n used here (537).
rand_range:
    push rbx
    mov ebx, edi
    call rng_next
    xor edx, edx
    div ebx
    mov eax, edx
    pop rbx
    ret


; INIT_SOLDIER: set every field of one soldier. A macro rather than a
; function, just so both teams' soldiers are set up by literally the
; same lines.
%macro INIT_SOLDIER 4   ; %1 = soldier index reg, %2 = x reg, %3 = y reg, %4 = team
    mov eax, %1
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov [r10 + Soldier.x], %2
    mov [r10 + Soldier.y], %3
    mov [r10 + Soldier.team], %4
    mov dword [r10 + Soldier.health], 100
    mov dword [r10 + Soldier.weapon], WEAPON_KNIFE
    mov dword [r10 + Soldier.state], STATE_SEEK_ENEMY
    mov dword [r10 + Soldier.target], -1
    mov dword [r10 + Soldier.cooldown], 0
    mov dword [r10 + Soldier.avoid_dir], 0
%endmacro

; void spawn_soldiers(void)
; Each team starts inside its own complex's lobby (home[team]): for
; each soldier, a random spot in the lobby, tried again if it's within
; SPAWN_GAP (on both axes) of a teammate already placed. The teams
; can't touch, so only teammates need checking.
;
; The retry loop has no attempt limit. gen_neighborhood.py runs this
; same packing 300 times per lobby and fails the build of the map if
; it ever jams; the worst single soldier needed 76 tries.
;   r15d team   r12d soldier index   r13d/r14d x/y   ebx check index
;   stack: lobby x0, x range, y0, y range
SS_X0 equ 0
SS_XR equ 4
SS_Y0 equ 8
SS_YR equ 12
spawn_soldiers:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                   ; 5 pushes + 16: 16-byte aligned
    xor r15d, r15d
.ss_team:
    ; this team's lobby, shrunk by LOBBY_MARGIN, as corner ranges
    mov eax, [home + r15*4]
    shl eax, 4                    ; 16 bytes per lobby
    lea rcx, [lobbies]
    add rcx, rax
    mov eax, [rcx]
    add eax, LOBBY_MARGIN
    mov [rsp + SS_X0], eax
    mov eax, [rcx + 8]
    sub eax, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    mov [rsp + SS_XR], eax
    mov eax, [rcx + 4]
    add eax, LOBBY_MARGIN
    mov [rsp + SS_Y0], eax
    mov eax, [rcx + 12]
    sub eax, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    mov [rsp + SS_YR], eax

    imul r12d, r15d, NUM_PER_TEAM ; first index of this team
.ss_next:
    imul eax, r15d, NUM_PER_TEAM
    add eax, NUM_PER_TEAM
    cmp r12d, eax
    jge .ss_team_done
.ss_retry:
    mov edi, [rsp + SS_XR]
    call rand_range
    add eax, [rsp + SS_X0]
    mov r13d, eax
    mov edi, [rsp + SS_YR]
    call rand_range
    add eax, [rsp + SS_Y0]
    mov r14d, eax

    ; too close to a teammate already placed?
    imul ebx, r15d, NUM_PER_TEAM
.ss_check:
    cmp ebx, r12d
    jge .ss_place
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    sub eax, r13d
    jns .ss_dx_ok
    neg eax
.ss_dx_ok:
    cmp eax, SPAWN_GAP
    jge .ss_check_next
    mov eax, [r10 + Soldier.y]
    sub eax, r14d
    jns .ss_dy_ok
    neg eax
.ss_dy_ok:
    cmp eax, SPAWN_GAP
    jl .ss_retry                  ; too close on both axes
.ss_check_next:
    inc ebx
    jmp .ss_check
.ss_place:
    INIT_SOLDIER r12d, r13d, r14d, r15d
    inc r12d
    jmp .ss_next
.ss_team_done:
    inc r15d
    cmp r15d, 2
    jb .ss_team
    ; the Big Homies' slots: out of play (health 0, nothing booked)
    ; until update_bosses sends one out; one life each
    lea r10, [soldiers + BOSS0 * Soldier_size]
    mov dword [r10 + Soldier.team], 0
    mov dword [r10 + Soldier.health], 0
    lea r10, [soldiers + BOSS1 * Soldier_size]
    mov dword [r10 + Soldier.team], 1
    mov dword [r10 + Soldier.health], 0
    lea r10, [lives_left]
    mov dword [r10 + BOSS0 * 4], 0
    mov dword [r10 + BOSS1 * 4], 0
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void choose_sides(void)
; One random bit: which gang gets which complex. home[team] is the
; complex (0 west, 1 east), and fwd_sign[team] is +1 when the enemy's
; complex is to the east. fwd_sign replaces 06-12's "team 0 goes +x":
; the side-step and flow_waypoint's tie-break still go "forward",
; toward the enemy's home.
choose_sides:
    call rng_next
    and eax, 1
    mov [home], eax               ; Crips: west (0) or east (1)
    xor eax, 1
    mov [home + 4], eax
    mov dword [fwd_sign], 1
    mov dword [fwd_sign + 4], -1
    cmp dword [home], 0
    je .cs_done
    mov dword [fwd_sign], -1
    mov dword [fwd_sign + 4], 1
.cs_done:
    ret


; void spawn_pickups(void)
; map_pickups[i], moved by a random offset in [-PICKUP_JITTER,
; +PICKUP_JITTER] on each axis. If that lands it where a soldier
; couldn't stand, it goes exactly on its table spot instead, which the
; generator checked is clear. No mirroring: the side swap is what
; keeps the map fair (choose_sides).
spawn_pickups:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r12, [pickups]
    lea r13, [map_pickups]
    xor r14d, r14d
.sp_loop:
    cmp r14d, map_pickups_count
    jge .sp_done
    mov edi, 2 * PICKUP_JITTER + 1
    call rand_range
    mov ebx, [r13]
    add ebx, eax
    sub ebx, PICKUP_JITTER                ; x
    mov edi, 2 * PICKUP_JITTER + 1
    call rand_range
    mov r15d, [r13 + 4]
    add r15d, eax
    sub r15d, PICKUP_JITTER               ; y
    mov edi, ebx
    mov esi, r15d
    call is_box_blocked
    test eax, eax
    jz .sp_place
    mov ebx, [r13]                        ; blocked: the table spot
    mov r15d, [r13 + 4]
.sp_place:
    mov [r12 + Pickup.x], ebx
    mov [r12 + Pickup.y], r15d
    mov eax, [r13 + 8]
    mov [r12 + Pickup.type], eax
    mov dword [r12 + Pickup.active], 1
    add r12, Pickup_size
    add r13, 12
    inc r14d
    jmp .sp_loop
.sp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void seed_from_env(void)
; SEED=n (decimal, or 0x... hex) replaces the rdtsc seed, to replay a
; game exactly. A stalemate prints the seed it started from. SEED=0
; is ignored: xorshift can't use a zero state.
seed_from_env:
    sub rsp, 8                    ; align the stack for the libc calls
    lea rdi, [seed_env]
    call getenv
    test rax, rax
    jz .sfe_done
    mov rdi, rax
    xor esi, esi                  ; no end pointer
    xor edx, edx                  ; base 0: decimal, or 0x for hex
    call strtoull
    test rax, rax
    jz .sfe_done
    mov [rng_state], rax
.sfe_done:
    add rsp, 8
    ret


; int is_headless(void) -> eax: 1 if $HEADLESS is set and doesn't
; start with '0' (so HEADLESS=0 means windowed), else 0.
is_headless:
    sub rsp, 8                    ; align the stack for getenv
    lea rdi, [headless_env]
    call getenv
    add rsp, 8
    test rax, rax
    jz .ih_no
    cmp byte [rax], '0'
    je .ih_no
    cmp byte [rax], 0             ; HEADLESS= (empty) counts as no
    je .ih_no
    mov eax, 1
    ret
.ih_no:
    xor eax, eax
    ret


; void print_winner(int winner: eax) -- check_win's 1 = team 0, 2 = team 1
print_winner:
    lea rsi, [win_msg0]
    mov edx, win_msg0_len
    cmp eax, 1
    je .pw_have
    lea rsi, [win_msg1]
    mov edx, win_msg1_len
.pw_have:
    jmp print_result


; ============================================================
; Pathfinding (see the header). Cell k on either axis covers corner
; coordinates [CELL*k - (CELL-1), CELL*k], clipped to the field, so a
; coordinate v is in cell (v + CELL-1) / CELL.
; ============================================================

; CELL_OF reg: reg = (reg + CELL-1) / CELL. Clobbers eax, ecx, edx.
%macro CELL_OF 1
    lea eax, [%1 + CELL - 1]
    xor edx, edx
    mov ecx, CELL
    div ecx
    mov %1, eax
%endmacro

; int range_blocked(int x0: edi, int y0: esi, int x1: edx, int y1: ecx) -> eax
; Is any corner position in [x0, x1] x [y0, y1] walk-blocked in the
; blockmap? (All four are already inside the blockmap.)
range_blocked:
    lea r8, [blockmap]
    mov r9d, esi
.rb_row:
    cmp r9d, ecx
    jg .rb_clear
    imul r10d, r9d, BM_W
    add r10d, edi                 ; this row's first byte
    mov r11d, edx
    sub r11d, edi                 ; bytes to check after it
.rb_col:
    test byte [r8 + r10], BLOCK_WALK
    jnz .rb_blocked
    inc r10d
    dec r11d
    jns .rb_col
    inc r9d
    jmp .rb_row
.rb_blocked:
    mov eax, 1
    ret
.rb_clear:
    xor eax, eax
    ret


; CLAMP_TO reg, hi: reg = min(max(reg, 0), hi)
%macro CLAMP_TO 2
    test %1, %1
    jns %%lo_ok
    xor %1, %1
%%lo_ok:
    cmp %1, %2
    jle %%hi_ok
    mov %1, %2
%%hi_ok:
%endmacro

; void build_walkable(void)
; walkable[cell] = 1 if a soldier with its corner ANYWHERE in the cell
; would miss every wall and prop. With the blockmap that's just "no
; blocked byte in the cell's corner range". Being this strict means a
; soldier moving between walkable cells can never clip anything,
; whatever pixel it's on.
build_walkable:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [walkable]
    xor r12d, r12d                ; cy
.bw_row:
    cmp r12d, GRID_H
    jge .bw_done
    imul r14d, r12d, CELL         ; y_hi = min(CELL*cy, SCREEN_H - SIZE)
    mov r15d, r14d
    sub r15d, CELL - 1            ; y_lo = max(CELL*cy - (CELL-1), 0)
    jns .bw_ylo_ok
    xor r15d, r15d
.bw_ylo_ok:
    cmp r14d, SCREEN_H - SOLDIER_SIZE
    jle .bw_yhi_ok
    mov r14d, SCREEN_H - SOLDIER_SIZE
.bw_yhi_ok:
    xor r13d, r13d                ; cx
.bw_col:
    cmp r13d, GRID_W
    jge .bw_row_next
    imul r8d, r13d, CELL          ; x_hi
    mov edi, r8d
    sub edi, CELL - 1             ; x_lo
    jns .bw_xlo_ok
    xor edi, edi
.bw_xlo_ok:
    cmp r8d, SCREEN_W - SOLDIER_SIZE
    jle .bw_xhi_ok
    mov r8d, SCREEN_W - SOLDIER_SIZE
.bw_xhi_ok:
    mov edx, r8d                  ; x_hi
    mov esi, r15d                 ; y_lo
    mov ecx, r14d                 ; y_hi
    call range_blocked
    xor eax, 1
    mov [rbx], al
    inc rbx
    inc r13d
    jmp .bw_col
.bw_row_next:
    inc r12d
    jmp .bw_row
.bw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void bfs_begin(uint16 *field: rdi) -- all cells UNREACHED, queue empty
bfs_begin:
    mov [bfs_field], rdi
    mov dword [bfs_tail], 0
    mov ecx, GRID_CELLS
    mov ax, UNREACHED
    cld
    rep stosw
    ret


; void bfs_seed(int x: edi, int y: esi) -- the cell holding corner
; (x, y) is a source: distance 0. A source cell doesn't have to be
; walkable (a soldier can stand in a cell that isn't fully clear).
bfs_seed:
    CELL_OF esi
    CELL_OF edi
    imul esi, esi, GRID_W
    add esi, edi                  ; cell index
    mov r8, [bfs_field]
    cmp word [r8 + rsi*2], 0
    je .bs_done                   ; already a source
    mov word [r8 + rsi*2], 0
    mov eax, [bfs_tail]
    lea r9, [bfs_queue]
    mov [r9 + rax*4], esi
    inc dword [bfs_tail]
.bs_done:
    ret


; BFS_VISIT offset: visit neighbour n = cell + offset, if it is
; walkable and unvisited (the caller has done the bounds check).
; Registers as in bfs_run.
%macro BFS_VISIT 1
    lea eax, [ebx + %1]
    cmp byte [r10 + rax], 0
    je %%skip
    cmp word [r8 + rax*2], UNREACHED
    jne %%skip
    mov [r8 + rax*2], r12w
    mov [r9 + r11*4], eax
    inc r11d
%%skip:
%endmacro

; void bfs_run(void) -- breadth-first from the seeded sources, over
; 4-connected walkable cells. Each cell is queued at most once, so the
; queue never needs to wrap.
;   r8 field   r9 queue   r10 walkable   r11d tail   esi head
;   ebx cell   r12w its distance + 1   r13d cx   r14d cy
bfs_run:
    push rbx
    push r12
    push r13
    push r14
    mov r8, [bfs_field]
    lea r9, [bfs_queue]
    lea r10, [walkable]
    mov r11d, [bfs_tail]
    xor esi, esi
.br_loop:
    cmp esi, r11d
    jge .br_done
    mov ebx, [r9 + rsi*4]
    inc esi
    movzx r12d, word [r8 + rbx*2]
    inc r12d
    mov eax, ebx
    xor edx, edx
    mov ecx, GRID_W
    div ecx
    mov r13d, edx                 ; cx
    mov r14d, eax                 ; cy

    cmp r13d, GRID_W - 1
    jge .br_no_right
    BFS_VISIT 1
.br_no_right:
    test r13d, r13d
    jz .br_no_left
    BFS_VISIT -1
.br_no_left:
    cmp r14d, GRID_H - 1
    jge .br_no_down
    BFS_VISIT GRID_W
.br_no_down:
    test r14d, r14d
    jz .br_loop
    BFS_VISIT -GRID_W
    jmp .br_loop
.br_done:
    mov [bfs_tail], r11d
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void build_fields(void) -- the three distance fields for this tick
build_fields:
    push rbx
    push r12
    push r13
    lea r13, [field_to0]
    xor r12d, r12d                ; team
.bf_team:
    mov rdi, r13
    call bfs_begin
    lea rbx, [soldiers]
.bf_soldier:
    cmp dword [rbx + Soldier.health], 0
    jle .bf_soldier_next
    cmp [rbx + Soldier.team], r12d
    jne .bf_soldier_next
    mov edi, [rbx + Soldier.x]
    mov esi, [rbx + Soldier.y]
    call bfs_seed
.bf_soldier_next:
    add rbx, Soldier_size
    lea rax, [soldiers + TOTAL_SOLDIERS * Soldier_size]
    cmp rbx, rax
    jb .bf_soldier
    call bfs_run
    lea r13, [field_to1]
    inc r12d
    cmp r12d, 2
    jb .bf_team

    lea rdi, [field_pk]
    call bfs_begin
    lea rbx, [pickups]
.bf_pickup:
    cmp dword [rbx + Pickup.active], 0
    je .bf_pickup_next
    mov edi, [rbx + Pickup.x]
    mov esi, [rbx + Pickup.y]
    call bfs_seed
.bf_pickup_next:
    add rbx, Pickup_size
    lea rax, [pickups + MAX_PICKUPS * Pickup_size]
    cmp rbx, rax
    jb .bf_pickup
    call bfs_run
    pop r13
    pop r12
    pop rbx
    ret


; int flow_waypoint(int self: edi, uint16 *field: rsi) -> eax (1 or 0)
; Where to walk next on the field. Returns a cell centre in
; flow_wx/flow_wy, or 0 if no neighbour is closer to the goal.
;
; Pass 1 collects every neighbour (of the 8 around the soldier's own
; cell) that is walkable and strictly closer than the soldier's own
; cell. A diagonal only counts if both cells it cuts past are walkable
; too, so the step can't clip a wall's corner.
;
; Pass 2 tries them closest first, and takes the first one whose next
; step (the same MOVE_SPEED-clamped step .clear_step will take) isn't
; blocked by another soldier. 09 only ever returned the single best
; cell, so two teammates whose best steps crossed blocked each other
; forever, even when one had an equally good way round (10's README).
; If every candidate is blocked, it returns the best one anyway, and
; .clear_step's usual fallbacks take over.
;
; Ties (in both passes) go to the first in flow_dirs, with dx flipped
; for team 1: "forward" first, for both teams.
FW_CAND   equ 0          ; 8 x (dword distance, dword cell)
FW_SELF   equ 64
FW_X      equ 68
FW_Y      equ 72
FW_FIRST  equ 76         ; the closest candidate's cell, for the fallback
FW_LOCALS equ 80         ; 5 pushes + 80 keeps rsp 16-byte aligned

; FW_CENTRE cell_reg: flow_wx/flow_wy = that cell's centre. Clobbers
; eax, ecx, edx.
%macro FW_CENTRE 1
    mov eax, %1
    xor edx, edx
    mov ecx, GRID_W
    div ecx                       ; eax = cy, edx = cx
    imul edx, edx, CELL
    sub edx, CELL / 2             ; centre of [CELL*k - (CELL-1), CELL*k]
    imul eax, eax, CELL
    sub eax, CELL / 2
    CLAMP_TO edx, SCREEN_W - SOLDIER_SIZE
    CLAMP_TO eax, SCREEN_H - SOLDIER_SIZE
    mov [flow_wx], edx
    mov [flow_wy], eax
%endmacro

; CLAMP_STEP reg: reg = min(max(reg, -MOVE_SPEED), MOVE_SPEED)
%macro CLAMP_STEP 1
    cmp %1, MOVE_SPEED
    jle %%hi_ok
    mov %1, MOVE_SPEED
%%hi_ok:
    cmp %1, -MOVE_SPEED
    jge %%lo_ok
    mov %1, -MOVE_SPEED
%%lo_ok:
%endmacro

flow_waypoint:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FW_LOCALS
    mov [rsp + FW_SELF], edi
    imul eax, edi, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.team]
    mov r14d, [fwd_sign + rax*4]  ; "forward": toward the enemy's home
    mov eax, [r10 + Soldier.x]
    mov [rsp + FW_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rsp + FW_Y], eax
    mov r12d, [r10 + Soldier.x]
    CELL_OF r12d
    mov r13d, [r10 + Soldier.y]
    CELL_OF r13d
    imul eax, r13d, GRID_W
    add eax, r12d
    movzx r15d, word [rsi + rax*2]   ; own cell's distance
    xor ebx, ebx                  ; candidates found

    ; ---- pass 1: collect the closer neighbours ----
    ;   r12d cx   r13d cy   r14d forward sign   r15d own distance
    ;   ebx count   rdi dir index   rsi field
    lea r10, [walkable]
    lea r11, [flow_dirs]
    xor edi, edi
.fw_dir:
    cmp edi, 8
    jge .fw_collected
    movsx r8d, byte [r11 + rdi*2]
    imul r8d, r14d                ; dx, forward-adjusted
    movsx r9d, byte [r11 + rdi*2 + 1]
    add r8d, r12d                 ; nx
    add r9d, r13d                 ; ny
    cmp r8d, GRID_W
    jae .fw_next                  ; unsigned: catches -1 too
    cmp r9d, GRID_H
    jae .fw_next
    imul eax, r9d, GRID_W
    add eax, r8d                  ; n
    cmp byte [r10 + rax], 0
    je .fw_next
    cmp r8d, r12d
    je .fw_straight
    cmp r9d, r13d
    je .fw_straight
    imul ecx, r13d, GRID_W        ; diagonal: (nx, cy) and (cx, ny) too
    add ecx, r8d
    cmp byte [r10 + rcx], 0
    je .fw_next
    imul ecx, r9d, GRID_W
    add ecx, r12d
    cmp byte [r10 + rcx], 0
    je .fw_next
.fw_straight:
    movzx ecx, word [rsi + rax*2]
    cmp ecx, r15d
    jae .fw_next                  ; not closer than where we are
    mov [rsp + FW_CAND + rbx*8], ecx
    mov [rsp + FW_CAND + rbx*8 + 4], eax
    inc ebx
.fw_next:
    inc edi
    jmp .fw_dir

.fw_collected:
    xor eax, eax
    test ebx, ebx
    jz .fw_ret                    ; nothing closer: caller side-steps
    mov dword [rsp + FW_FIRST], -1

    ; ---- pass 2: closest first, skipping steps another soldier blocks ----
    ;   ebx count   r12d best index this round   r13d its distance
.fw_pick:
    mov r12d, -1
    mov r13d, 0xFFFFFFFF
    xor ecx, ecx
.fw_scan:
    cmp ecx, ebx
    jge .fw_scanned
    mov eax, [rsp + FW_CAND + rcx*8]
    cmp eax, r13d
    jae .fw_scan_next             ; strictly closer: ties keep dir order
    mov r13d, eax
    mov r12d, ecx
.fw_scan_next:
    inc ecx
    jmp .fw_scan
.fw_scanned:
    cmp r12d, -1
    je .fw_all_blocked
    mov dword [rsp + FW_CAND + r12*8], 0xFFFFFFFF   ; used up
    mov r15d, [rsp + FW_CAND + r12*8 + 4]           ; its cell
    cmp dword [rsp + FW_FIRST], -1
    jne .fw_have_first
    mov [rsp + FW_FIRST], r15d
.fw_have_first:
    FW_CENTRE r15d
    mov esi, [flow_wx]
    sub esi, [rsp + FW_X]
    CLAMP_STEP esi
    add esi, [rsp + FW_X]
    mov edx, [flow_wy]
    sub edx, [rsp + FW_Y]
    CLAMP_STEP edx
    add edx, [rsp + FW_Y]
    mov edi, [rsp + FW_SELF]
    call is_spot_blocked
    test eax, eax
    jnz .fw_pick                  ; someone's there: try the next closest
    mov eax, 1
    jmp .fw_ret

.fw_all_blocked:
    mov r15d, [rsp + FW_FIRST]
    FW_CENTRE r15d
    mov eax, 1
.fw_ret:
    add rsp, FW_LOCALS
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; Scoreboard (drawing only: reads the game state, never writes it,
; never draws a random number)
; ============================================================

; void draw_text(char *s: rdi, int len: esi, int x: edx, int y: ecx,
;                uint32 color: r8d)
; Each font pixel that's set becomes a FONT_SCALE square, via
; fill_rect. Lowercase is drawn as uppercase; anything outside
; ' '..'Z' as a blank.
;   rbx string   r12d chars left   r13d x   r14d y   r15d color
;   stack: glyph pointer, row, col, row bits
DT_GLYPH equ 0
DT_ROW   equ 8
DT_COL   equ 12
DT_BITS  equ 16
draw_text:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                   ; 5 pushes + 32: rsp stays 16-aligned
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
.dt_char:
    test r12d, r12d
    jz .dt_done
    movzx eax, byte [rbx]
    cmp eax, 'a'
    jb .dt_upper
    cmp eax, 'z'
    ja .dt_upper
    sub eax, 'a' - 'A'
.dt_upper:
    sub eax, FONT_FIRST
    cmp eax, FONT_LAST - FONT_FIRST
    ja .dt_next_char              ; unsigned: below ' ' wraps round too
    imul eax, eax, FONT_ROWS
    lea rcx, [font]
    add rax, rcx
    mov [rsp + DT_GLYPH], rax
    mov dword [rsp + DT_ROW], 0
.dt_row:
    mov eax, [rsp + DT_ROW]
    cmp eax, FONT_ROWS
    jge .dt_next_char
    mov rcx, [rsp + DT_GLYPH]
    movzx ecx, byte [rcx + rax]
    mov [rsp + DT_BITS], ecx
    mov dword [rsp + DT_COL], 0
.dt_col:
    mov ecx, [rsp + DT_COL]
    cmp ecx, FONT_COLS
    jge .dt_next_row
    mov eax, 1 << (FONT_COLS - 1)
    shr eax, cl                   ; this column's bit
    test [rsp + DT_BITS], eax
    jz .dt_next_col
    lea rdi, [back_fb]
    imul esi, ecx, FONT_SCALE
    add esi, r13d
    imul edx, [rsp + DT_ROW], FONT_SCALE
    add edx, r14d
    mov ecx, FONT_SCALE
    mov r8d, FONT_SCALE
    mov r9d, r15d
    call fill_rect
.dt_next_col:
    inc dword [rsp + DT_COL]
    jmp .dt_col
.dt_next_row:
    inc dword [rsp + DT_ROW]
    jmp .dt_row
.dt_next_char:
    inc rbx
    dec r12d
    add r13d, CHAR_ADV
    jmp .dt_char
.dt_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; DRAW_HUD_BUF align, color: draw hud_buf[0 .. rdi) at y HUD_TEXT_Y,
; aligned HUD_LEFT, HUD_RIGHT or HUD_CENTRE.
HUD_LEFT   equ 0
HUD_RIGHT  equ 1
HUD_CENTRE equ 2
%macro DRAW_HUD_BUF 2
    mov rsi, rdi
    lea rdi, [hud_buf]
    sub rsi, rdi                  ; length
    imul eax, esi, CHAR_ADV
    sub eax, FONT_SCALE           ; width: no spacing after the last char
    %if %1 == HUD_LEFT
        mov edx, HUD_MARGIN
    %elif %1 == HUD_RIGHT
        mov edx, SCREEN_W - HUD_MARGIN
        sub edx, eax
    %else
        mov edx, SCREEN_W
        sub edx, eax
        shr edx, 1
    %endif
    mov ecx, HUD_TEXT_Y
    mov r8d, %2
    call draw_text
%endmacro

; void draw_hud(void)
;   BLUE 120/200      PILLARS   0:12      RED 97/200
; (kills, and the score limit if there is one)
; The middle shows the winner once the game is over.
draw_hud:
    push rbx
    push r12
    sub rsp, 8                    ; keep the stack 16-byte aligned

    lea rdi, [back_fb]
    xor esi, esi
    mov edx, SCREEN_H
    mov ecx, SCREEN_W
    mov r8d, HUD_H
    mov r9d, COLOR_HUD
    call fill_rect

    ; living soldiers per team -> ebx (team 0), r12d (team 1)
    xor ebx, ebx
    xor r12d, r12d
    lea r10, [soldiers]
    xor ecx, ecx
.dh_count:
    cmp dword [r10 + Soldier.health], 0
    jle .dh_count_next
    cmp dword [r10 + Soldier.team], 0
    jne .dh_count_t1
    inc ebx
    jmp .dh_count_next
.dh_count_t1:
    inc r12d
.dh_count_next:
    add r10, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .dh_count

    ; ---- left: BLUE n ----
    lea rdi, [hud_buf]
    lea rsi, [hud_blue]
    mov edx, hud_blue_len
    call append_bytes
    mov esi, [score]
    call append_score
    DRAW_HUD_BUF HUD_LEFT, COLOR_TEAM0

    ; ---- right: RED n, right-aligned ----
    lea rdi, [hud_buf]
    lea rsi, [hud_red]
    mov edx, hud_red_len
    call append_bytes
    mov esi, [score + 4]
    call append_score
    DRAW_HUD_BUF HUD_RIGHT, COLOR_TEAM1

    ; ---- middle ----
    lea rdi, [hud_buf]
    mov eax, [game_over]
    test eax, eax
    jz .dh_playing
    mov r12d, COLOR_TEAM0
    lea rsi, [hud_blue]
    mov edx, hud_blue_len - 1     ; no trailing space
    cmp eax, 1
    je .dh_winner
    mov r12d, COLOR_TEAM1
    lea rsi, [hud_red]
    mov edx, hud_red_len - 1
.dh_winner:
    call append_bytes
    lea rsi, [hud_wins]
    mov edx, hud_wins_len
    call append_bytes
    jmp .dh_middle

.dh_playing:
    cmp dword [boss_alert], 0
    je .dh_no_boss
    mov r12d, COLOR_TEAM0
    lea rsi, [hud_blue]
    mov edx, hud_blue_len
    cmp dword [boss_alert_team], 0
    je .dh_boss_gang
    mov r12d, COLOR_TEAM1
    lea rsi, [hud_red]
    mov edx, hud_red_len
.dh_boss_gang:
    call append_bytes
    lea rsi, [hud_boss]
    mov edx, hud_boss_len
    call append_bytes
    jmp .dh_middle
.dh_no_boss:
    cmp dword [cop_active], 0
    je .dh_no_police
    mov r12d, COLOR_SIREN_B
    test dword [ticks], 16
    jz .dh_siren
    mov r12d, COLOR_SIREN_R
.dh_siren:
    lea rsi, [hud_police]
    mov edx, hud_police_len
    call append_bytes
    jmp .dh_middle
.dh_no_police:
    cmp dword [dog_state], DOG_LOOSE
    jne .dh_normal
    mov r12d, COLOR_DOG_MAD
    lea rsi, [hud_dog]
    mov edx, hud_dog_len
    call append_bytes
    jmp .dh_middle
.dh_normal:
    mov r12d, COLOR_HUD_TEXT
    call append_arena_name
    lea rsi, [hud_gap]
    mov edx, hud_gap_len
    call append_bytes
    ; m:ss from ticks, 60 per second
    mov eax, [ticks]
    xor edx, edx
    mov ecx, 60
    div ecx                       ; eax = seconds
    xor edx, edx
    div ecx                       ; eax = minutes, edx = seconds
    mov ebx, edx
    mov esi, eax
    call append_uint
    mov byte [rdi], ':'
    inc rdi
    cmp ebx, 10
    jae .dh_two_digits
    mov byte [rdi], '0'
    inc rdi
.dh_two_digits:
    mov esi, ebx
    call append_uint
.dh_middle:
    DRAW_HUD_BUF HUD_CENTRE, r12d

    add rsp, 8
    pop r12
    pop rbx
    ret


; ============================================================
; Respawns (see the header)
; ============================================================

; void read_rules(void) -- RESPAWNS, LIVES and SCORE_LIMIT from the
; environment
read_rules:
    sub rsp, 8                    ; align the stack for the libc calls
    ; LIVES=n: every soldier gets n-1 respawns. Unset: DEFAULT_LIVES.
    ; LIVES=0 (or less): no limit. The default goes in AFTER getenv:
    ; ecx is caller-saved, and getenv is free to change it (it did:
    ; the first version of this set ecx first, and every soldier got
    ; 68 respawns instead of the default)
    lea rdi, [lives_env]
    call getenv
    mov ecx, DEFAULT_LIVES - 1
    test rax, rax
    jz .rr_fill
    mov rdi, rax
    call atoi
    mov ecx, -1
    test eax, eax
    jle .rr_fill                  ; LIVES=0: unlimited
    lea ecx, [eax - 1]            ; lives -> respawns
.rr_fill:
    lea rdx, [lives_left]
    xor eax, eax
.rr_fill_loop:
    mov [rdx + rax*4], ecx
    inc eax
    cmp eax, TOTAL_SOLDIERS
    jl .rr_fill_loop

    lea rdi, [respawns_env]
    call getenv
    test rax, rax
    jz .rr_score                  ; unset: unlimited (tickets stay -1)
    mov rdi, rax
    call atoi
    mov [tickets], eax            ; negative also means unlimited
    mov [tickets + 4], eax
.rr_score:
    lea rdi, [boss_env]
    call getenv
    test rax, rax
    jz .rr_score2
    mov rdi, rax
    call atoi
    mov [boss_at], eax
.rr_score2:
    lea rdi, [score_env]
    call getenv
    test rax, rax
    jz .rr_done
    mov rdi, rax
    call atoi
    mov [score_limit], eax        ; 0 or less: no limit
.rr_done:
    add rsp, 8
    ret


; append_score(dst: rdi, n: esi) -> rdi: "n", or "n/limit" if there is one
append_score:
    call append_uint
    mov esi, [score_limit]
    test esi, esi
    jle .as_done
    mov byte [rdi], '/'
    inc rdi
    call append_uint
.as_done:
    ret


; void process_respawns(void) -- once per tick, after everyone moved.
; Counts down spawn protection, and respawn timers; a timer that
; reaches 1 tries to respawn its soldier every tick until it works.
; Same processing direction as this tick's update_soldiers
; (pass_reverse), so neither team always gets first pick.
process_respawns:
    push rbx
    push r12
    sub rsp, 8
    xor ebx, ebx
.pr_loop:
    cmp ebx, TOTAL_SOLDIERS
    jge .pr_done
    mov r12d, ebx
    cmp dword [pass_reverse], 0
    je .pr_have
    mov r12d, TOTAL_SOLDIERS - 1
    sub r12d, ebx
.pr_have:
    lea rcx, [protect_timer]
    cmp dword [rcx + r12*4], 0
    jle .pr_no_protect
    dec dword [rcx + r12*4]
.pr_no_protect:
    lea rcx, [respawn_timer]
    mov eax, [rcx + r12*4]
    test eax, eax
    jle .pr_next                  ; alive, or dead for good
    cmp eax, 1
    je .pr_try
    dec dword [rcx + r12*4]
    jmp .pr_next
.pr_try:
    mov edi, r12d
    call respawn_soldier
    test eax, eax
    jz .pr_next                   ; no free spot: try again next tick
    lea rcx, [respawn_timer]
    mov dword [rcx + r12*4], 0
.pr_next:
    inc ebx
    jmp .pr_loop
.pr_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; int respawn_soldier(int i: edi) -> eax (1 = done, 0 = no free spot)
; RESPAWN_TRIES random spots in the soldier's home lobby. Skips spots another soldier
; blocks; of the rest, takes the one whose nearest living enemy is
; farthest away. Then resets the soldier as if new, with spawn
; protection.
;   ebx soldier   r12d tries left   r13d/r14d candidate x/y
;   r15d its nearest-enemy distance^2   stack: best x, y, distance
RS_BEST_X equ 0
RS_BEST_Y equ 4
RS_BEST_D equ 8
respawn_soldier:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                   ; 5 pushes + 16: 16-byte aligned
    mov ebx, edi
    mov dword [rsp + RS_BEST_D], -1
    mov r12d, RESPAWN_TRIES
.rs_try:
    ; a random spot in this soldier's home lobby (r15 is free until
    ; the distance below)
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    mov eax, [rcx + rax + Soldier.team]
    mov eax, [home + rax*4]
    shl eax, 4
    lea r15, [lobbies]
    add r15, rax
    mov edi, [r15 + 8]
    sub edi, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    call rand_range
    add eax, [r15]
    lea r13d, [eax + LOBBY_MARGIN]
    mov edi, [r15 + 12]
    sub edi, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    call rand_range
    add eax, [r15 + 4]
    lea r14d, [eax + LOBBY_MARGIN]
    mov edi, ebx
    mov esi, r13d
    mov edx, r14d
    call is_spot_blocked
    test eax, eax
    jnz .rs_next_try

    ; distance^2 to the nearest living enemy
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    mov r8d, [rcx + rax + Soldier.team]
    mov r15d, 0x7FFFFFFF
    xor edx, edx
.rs_enemy:
    cmp dword [rcx + Soldier.health], 0
    jle .rs_enemy_next
    cmp [rcx + Soldier.team], r8d
    je .rs_enemy_next
    mov eax, [rcx + Soldier.x]
    sub eax, r13d
    imul eax, eax
    mov r9d, [rcx + Soldier.y]
    sub r9d, r14d
    imul r9d, r9d
    add eax, r9d
    cmp eax, r15d
    jae .rs_enemy_next
    mov r15d, eax
.rs_enemy_next:
    add rcx, Soldier_size
    inc edx
    cmp edx, TOTAL_SOLDIERS
    jl .rs_enemy

    cmp r15d, [rsp + RS_BEST_D]   ; best starts at -1, so compare signed:
    jle .rs_next_try              ; any real distance beats "none yet"
    mov [rsp + RS_BEST_D], r15d
    mov [rsp + RS_BEST_X], r13d
    mov [rsp + RS_BEST_Y], r14d
.rs_next_try:
    dec r12d
    jnz .rs_try

    xor eax, eax
    cmp dword [rsp + RS_BEST_D], -1
    je .rs_ret                    ; every spot was blocked

    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [rsp + RS_BEST_X]
    mov [r10 + Soldier.x], eax
    mov eax, [rsp + RS_BEST_Y]
    mov [r10 + Soldier.y], eax
    mov dword [r10 + Soldier.health], 100
    mov dword [r10 + Soldier.weapon], WEAPON_KNIFE
    mov dword [r10 + Soldier.state], STATE_SEEK_ENEMY
    mov dword [r10 + Soldier.target], -1
    mov dword [r10 + Soldier.cooldown], 0
    mov dword [r10 + Soldier.avoid_dir], 0
    lea rcx, [protect_timer]
    mov dword [rcx + rbx*4], PROTECT_TICKS
    lea rcx, [death_linger]       ; drawing state: don't draw the old body
    mov dword [rcx + rbx*4], 0
    lea rcx, [hit_flash]
    mov dword [rcx + rbx*4], 0
    mov eax, 1
.rs_ret:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; The neighborhood's look (drawing only)
; ============================================================

; void render_background(void)
; Draws bg_rects (generated: grass, streets, lane markings, roofs,
; cars...) into bg_buffer in order, then each complex's walls in the
; colour of the gang that lives there this game. Once per game; every
; frame after that starts with a copy of bg_buffer.
render_background:
    push rbx
    push r12
    push r13
    lea rbx, [bg_rects]
    mov r12d, bg_rects_count
.rbg_rect:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, [rbx + 16]
    call fill_rect
    add rbx, 20
    dec r12d
    jnz .rbg_rect
    ; complex walls: west, then east, in their owners' colours
    xor r13d, r13d                ; complex
.rbg_complex:
    lea rbx, [cwalls_west]
    mov r12d, cwalls_west_count
    test r13d, r13d
    jz .rbg_have_list
    lea rbx, [cwalls_east]
    mov r12d, cwalls_east_count
.rbg_have_list:
.rbg_wall:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, COLOR_TEAM0
    cmp [home], r13d              ; do the Crips live here?
    je .rbg_colour
    mov r9d, COLOR_TEAM1
.rbg_colour:
    call fill_rect
    add rbx, 16
    dec r12d
    jnz .rbg_wall
    inc r13d
    cmp r13d, 2
    jb .rbg_complex
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; Sprites (drawing only)
; ============================================================

; void draw_sprite(int x: edi, int y: esi, u8 *sprite: rdx,
;                  u32 *palette: rcx, int mirrored: r8d)
; 16x16 palette indices -> back_buffer, skipping index 0 and any
; colour that's 0 (a hidden weapon), clipped to the field.
;   r9 sprite pointer   r10d row   r11d col   ebx pixel x   r12d y
draw_sprite:
    push rbx
    push r12
    push r13
    mov r9, rdx
    xor r10d, r10d
.ds_row:
    cmp r10d, SPRITE_SIZE
    jge .ds_done
    lea r12d, [esi + r10d]
    cmp r12d, SCREEN_H
    jae .ds_next_row              ; unsigned: above the top too
    xor r11d, r11d
.ds_col:
    cmp r11d, SPRITE_SIZE
    jge .ds_next_row
    movzx eax, byte [r9 + r11]
    test eax, eax
    jz .ds_next_col
    mov eax, [rcx + rax*4]
    test eax, eax
    jz .ds_next_col
    mov ebx, r11d
    test r8d, r8d
    jz .ds_x
    mov ebx, SPRITE_SIZE - 1
    sub ebx, r11d
.ds_x:
    add ebx, edi
    cmp ebx, SCREEN_W
    jae .ds_next_col
    imul r13d, r12d, SCREEN_W
    add r13d, ebx
    lea rdx, [back_buffer]
    mov [rdx + r13*4], eax
.ds_next_col:
    inc r11d
    jmp .ds_col
.ds_next_row:
    add r9, SPRITE_SIZE
    inc r10d
    jmp .ds_row
.ds_done:
    pop r13
    pop r12
    pop rbx
    ret


; void draw_soldier(int i: edi)
; Turn to face the way this soldier moved since the last frame, count
; the pixels walked (they pick the walk frame), build its palette,
; and draw it.
draw_soldier:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    imul eax, ebx, Soldier_size
    lea r12, [soldiers]
    add r12, rax

    ; ---- facing and walk ----
    lea r8, [sprite_seen]
    cmp dword [r8 + rbx*4], 0
    jne .dsol_seen
    mov dword [r8 + rbx*4], 1
    mov eax, [r12 + Soldier.team] ; first sight: face the enemy's home
    mov eax, [fwd_sign + rax*4]
    mov ecx, 2                    ; E
    test eax, eax
    jg .dsol_face0
    mov ecx, 6                    ; W
.dsol_face0:
    lea r8, [sprite_facing]
    mov [r8 + rbx*4], ecx
    jmp .dsol_store
.dsol_seen:
    lea r8, [sprite_last_x]
    mov r13d, [r12 + Soldier.x]
    sub r13d, [r8 + rbx*4]        ; dx
    lea r8, [sprite_last_y]
    mov r14d, [r12 + Soldier.y]
    sub r14d, [r8 + rbx*4]        ; dy
    mov eax, r13d
    neg eax
    cmovs eax, r13d               ; |dx|
    mov r15d, r14d
    neg r15d
    cmovs r15d, r14d              ; |dy|
    cmp eax, TELEPORT
    jg .dsol_store                ; respawned: no step to face
    cmp r15d, TELEPORT
    jg .dsol_store
    mov ecx, eax
    add ecx, r15d
    jz .dsol_store                ; didn't move: keep facing, frame
    lea r8, [sprite_walk]
    add [r8 + rbx*4], ecx
    ; octant: mostly sideways, mostly up/down, or diagonal
    lea ecx, [r15d * 2]
    cmp eax, ecx
    jle .dsol_not_x
    mov ecx, 2                    ; E
    test r13d, r13d
    jg .dsol_set
    mov ecx, 6                    ; W
    jmp .dsol_set
.dsol_not_x:
    lea ecx, [eax * 2]
    cmp r15d, ecx
    jle .dsol_diag
    mov ecx, 4                    ; S
    test r14d, r14d
    jg .dsol_set
    xor ecx, ecx                  ; N
    jmp .dsol_set
.dsol_diag:
    test r13d, r13d
    jle .dsol_diag_w
    mov ecx, 3                    ; SE
    test r14d, r14d
    jg .dsol_set
    mov ecx, 1                    ; NE
    jmp .dsol_set
.dsol_diag_w:
    mov ecx, 5                    ; SW
    test r14d, r14d
    jg .dsol_set
    mov ecx, 7                    ; NW
.dsol_set:
    lea r8, [sprite_facing]
    mov [r8 + rbx*4], ecx
.dsol_store:
    lea r8, [sprite_last_x]
    mov eax, [r12 + Soldier.x]
    mov [r8 + rbx*4], eax
    lea r8, [sprite_last_y]
    mov eax, [r12 + Soldier.y]
    mov [r8 + rbx*4], eax

    ; ---- palette ----
    lea rdi, [pal_buf]
    lea rcx, [hit_flash]
    cmp dword [rcx + rbx*4], 0
    jle .dsol_colours
    ; hit: a white silhouette
    mov dword [rdi], 0
    mov eax, COLOR_FLASH
    mov ecx, 1
.dsol_white:
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, PAL_SIZE
    jb .dsol_white
    jmp .dsol_draw
.dsol_colours:
    mov dword [rdi], 0
    mov dword [rdi + PAL_HAIR*4], COLOR_HAIR
    mov eax, [r12 + Soldier.team]
    imul eax, eax, 12
    lea rcx, [gang_colours]
    add rcx, rax
    mov eax, [rcx]
    mov [rdi + PAL_SHIRT*4], eax
    mov [rdi + PAL_CHAIN*4], eax  ; no chain: it's just shirt
    mov eax, [rcx + 4]
    mov [rdi + PAL_SHADE*4], eax
    mov eax, [rcx + 8]
    mov [rdi + PAL_BAND*4], eax
    cmp ebx, SQUAD
    jb .dsol_regular
    mov dword [rdi + PAL_BAND*4], COLOR_GOLD    ; the Big Homie
    mov dword [rdi + PAL_CHAIN*4], COLOR_GOLD
.dsol_regular:
    mov eax, ebx
    xor edx, edx
    mov ecx, 3
    div ecx
    lea rcx, [skin_tones]
    mov eax, [rcx + rdx*4]
    mov [rdi + PAL_SKIN*4], eax
    mov dword [rdi + PAL_PANTS*4], COLOR_PANTS
    mov dword [rdi + PAL_SHOES*4], COLOR_SHOES
    ; the weapon in hand: only its pixels get a colour
    mov dword [rdi + PAL_GUN*4], 0
    mov dword [rdi + PAL_BARREL*4], 0
    mov dword [rdi + PAL_KNIFE*4], 0
    mov eax, [r12 + Soldier.weapon]
    cmp eax, WEAPON_KNIFE
    jne .dsol_gun
    mov dword [rdi + PAL_KNIFE*4], COLOR_KNIFE
    jmp .dsol_draw
.dsol_gun:
    mov dword [rdi + PAL_GUN*4], COLOR_GUN
    cmp eax, WEAPON_SHOTGUN
    jne .dsol_draw
    mov dword [rdi + PAL_BARREL*4], COLOR_BARREL

.dsol_draw:
    lea r8, [sprite_facing]
    mov eax, [r8 + rbx*4]
    lea r8, [facing_pose]
    movzx ecx, byte [r8 + rax*2]      ; pose
    movzx r13d, byte [r8 + rax*2 + 1] ; mirrored?
    lea r8, [sprite_walk]
    mov eax, [r8 + rbx*4]
    shr eax, 3                    ; a new walk frame every 8 px
    and eax, 1
    lea eax, [rcx*2 + rax]        ; sprite number
    shl eax, 8                    ; x 256 bytes
    lea rdx, [soldier_sprites]
    add rdx, rax
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    lea rcx, [pal_buf]
    mov r8d, r13d
    call draw_sprite
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_walker(void) -- the dog walker, as a sprite: facing the
; way they walk, a walk frame every 8 px, no bandana, no weapon
draw_walker:
    lea rdi, [pal_buf]
    mov dword [rdi], 0
    mov dword [rdi + PAL_HAIR*4], COLOR_HAIR
    mov dword [rdi + PAL_BAND*4], COLOR_HAIR
    mov dword [rdi + PAL_SKIN*4], 0xFFA0C3EB
    mov dword [rdi + PAL_SHIRT*4], COLOR_WALKER
    mov dword [rdi + PAL_CHAIN*4], COLOR_WALKER
    mov dword [rdi + PAL_SHADE*4], COLOR_WALKER_SHADE
    mov dword [rdi + PAL_PANTS*4], COLOR_PANTS
    mov dword [rdi + PAL_SHOES*4], COLOR_SHOES
    mov dword [rdi + PAL_GUN*4], 0
    mov dword [rdi + PAL_BARREL*4], 0
    mov dword [rdi + PAL_KNIFE*4], 0
    mov eax, [walker_x]
    shr eax, 3
    and eax, 1
    add eax, 2 * 2                ; pose E (2), walk frame
    shl eax, 8
    lea rdx, [soldier_sprites]
    add rdx, rax
    xor r8d, r8d
    cmp dword [walker_dx], 0
    jg .dw_dir
    mov r8d, 1                    ; walking west: mirrored
.dw_dir:
    mov edi, [walker_x]
    sub edi, (SPRITE_SIZE - WALKER_SIZE) / 2
    mov esi, [walker_y]
    sub esi, SPRITE_SIZE - WALKER_SIZE
    lea rcx, [pal_buf]
    sub rsp, 8
    call draw_sprite
    add rsp, 8
    ret


; ============================================================
; The Big Homie (see the header)
; ============================================================

; int team_strength(int team: edi) -> eax
; Everything a gang has left: each soldier alive or waiting to
; respawn counts 1, plus every life it still has in reserve. -1 if
; any of them has unlimited lives (then there's nothing to count).
team_strength:
    xor eax, eax
    lea r8, [soldiers]
    lea r9, [respawn_timer]
    lea r10, [lives_left]
    xor ecx, ecx
.ts_loop:
    cmp [r8 + Soldier.team], edi
    jne .ts_next
    cmp dword [r8 + Soldier.health], 0
    jg .ts_in_play
    cmp dword [r9 + rcx*4], 0
    jle .ts_next                  ; out for good (lives are 0 too)
.ts_in_play:
    inc eax
    mov edx, [r10 + rcx*4]
    test edx, edx
    js .ts_unlimited
    add eax, edx
.ts_next:
    add r8, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .ts_loop
    ret
.ts_unlimited:
    mov eax, -1
    ret


; void update_bosses(void) -- once per tick. Decides when each gang's
; Big Homie is due, and sends him out of the lobby once there's room.
update_bosses:
    push rbx
    push r12
    push r13
    cmp dword [boss_alert], 0
    jle .ub_alert_done
    dec dword [boss_alert]
.ub_alert_done:
    xor ebx, ebx                  ; gang
.ub_team:
    cmp dword [boss_state + rbx*4], 0
    jne .ub_due
    cmp dword [boss_at], 0
    jle .ub_next                  ; BOSS_AT=0: no Big Homies
    ; not while the other gang's Big Homie is out and alive: otherwise
    ; the side he's beating just gets its own and cancels him out
    mov eax, ebx
    xor eax, 1
    imul eax, eax, Soldier_size
    lea r10, [soldiers + BOSS0 * Soldier_size]
    cmp dword [r10 + rax + Soldier.health], 0
    jg .ub_next
    mov edi, ebx
    call team_strength
    mov r12d, eax                 ; ours
    mov edi, ebx
    xor edi, 1
    call team_strength
    mov r13d, eax                 ; theirs
    test r12d, r12d
    jz .ub_next                   ; already beaten
    js .ub_by_kills
    test r13d, r13d
    js .ub_by_kills
    ; ours * 100 < BOSS_AT * theirs ?
    imul r12d, r12d, 100
    imul r13d, [boss_at]
    cmp r12d, r13d
    jge .ub_next
    jmp .ub_trigger
.ub_by_kills:
    ; unlimited lives: BOSS_KILL_GAP kills behind
    mov eax, ebx
    xor eax, 1
    mov eax, [score + rax*4]
    sub eax, [score + rbx*4]
    cmp eax, BOSS_KILL_GAP
    jl .ub_next
.ub_trigger:
    mov dword [boss_state + rbx*4], 1
.ub_due:
    cmp dword [boss_state + rbx*4], 1
    jne .ub_next
    lea edi, [ebx + BOSS0]
    call respawn_soldier          ; a safe spot in the lobby, protection
    test eax, eax
    jz .ub_next                   ; lobby full: try again next tick
    imul eax, ebx, Soldier_size
    lea r10, [soldiers + BOSS0 * Soldier_size]
    add r10, rax
    mov dword [r10 + Soldier.health], BOSS_HEALTH
    mov dword [r10 + Soldier.weapon], WEAPON_PISTOL
    mov dword [boss_state + rbx*4], 2
    cmp dword [boss_tick], 0
    jne .ub_tick_kept
    mov eax, [ticks]
    mov [boss_tick], eax
.ub_tick_kept:
    mov dword [boss_alert], BOSS_ALERT_TICKS
    mov [boss_alert_team], ebx
.ub_next:
    inc ebx
    cmp ebx, 2
    jb .ub_team
    pop r13
    pop r12
    pop rbx
    ret


; void draw_bosses(void) -- a health bar over each Big Homie who's out
; (drawing only; his gold bandana and chain are in draw_soldier)
draw_bosses:
    push rbx
    push r12
    push r13
    xor ebx, ebx
.db_loop:
    lea r12, [soldiers + BOSS0 * Soldier_size]
    imul eax, ebx, Soldier_size
    add r12, rax
    cmp dword [r12 + Soldier.health], 0
    jle .db_next
    ; health bar above him: SOLDIER_SIZE + 4 wide at full health
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    sub esi, 2
    mov edx, [r12 + Soldier.y]
    sub edx, 7
    mov ecx, SOLDIER_SIZE + 4
    mov r8d, 3
    mov r9d, COLOR_BAR_BACK
    call fill_rect
    mov eax, [r12 + Soldier.health]
    imul eax, SOLDIER_SIZE + 4
    xor edx, edx
    mov ecx, BOSS_HEALTH
    div ecx
    mov r13d, eax
    test r13d, r13d
    jz .db_next
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    sub esi, 2
    mov edx, [r12 + Soldier.y]
    sub edx, 7
    mov ecx, r13d
    mov r8d, 3
    mov r9d, COLOR_BAR
    call fill_rect
.db_next:
    inc ebx
    cmp ebx, 2
    jb .db_loop
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; Random encounters: the police and the pitbull (see the header)
; ============================================================

; int chance(int n: edi) -> eax: 1 with probability 1/n
chance:
    call rand_range
    cmp eax, 1
    setb al
    movzx eax, al
    ret


; int event_damage(int victim: edi, int damage: esi) -> eax (1 = killed)
; Damage from the police or the dog. Spawn protection still holds.
; A kill scores for nobody, but otherwise goes like any other: the
; weapon drops, and a respawn is booked if lives and the team's pool
; allow.
event_damage:
    push rbx
    mov ebx, edi
    lea rcx, [protect_timer]
    cmp dword [rcx + rbx*4], 0
    jg .ed_alive
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .ed_alive                 ; already down this tick
    sub [r10 + Soldier.health], esi
    cmp dword [r10 + Soldier.health], 0
    jg .ed_alive
    mov dword [r10 + Soldier.health], 0
    mov edi, ebx
    call drop_and_book
    mov eax, 1
    pop rbx
    ret
.ed_alive:
    xor eax, eax
    pop rbx
    ret

; drop_and_book(int i: edi): a soldier just died -- drop its gun and
; book a respawn, exactly as the kill code in update_soldiers does
drop_and_book:
    push rbx
    mov ebx, edi
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov edx, [r10 + Soldier.weapon]
    cmp edx, WEAPON_KNIFE
    je .db_book
    mov edi, [r10 + Soldier.x]
    mov esi, [r10 + Soldier.y]
    call drop_weapon
.db_book:
    lea rcx, [lives_left]
    cmp dword [rcx + rbx*4], 0
    je .db_done
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    mov edx, [r10 + rax + Soldier.team]
    cmp dword [tickets + rdx*4], 0
    je .db_done
    jl .db_pool_ok
    dec dword [tickets + rdx*4]
.db_pool_ok:
    cmp dword [rcx + rbx*4], 0
    jl .db_timer
    dec dword [rcx + rbx*4]
.db_timer:
    lea rcx, [respawn_timer]
    mov dword [rcx + rbx*4], RESPAWN_TICKS
.db_done:
    pop rbx
    ret


; CLAMP_DOG reg: reg = min(max(reg, -DOG_SPEED), DOG_SPEED)
%macro CLAMP_DOG 1
    cmp %1, DOG_SPEED
    jle %%hi_ok
    mov %1, DOG_SPEED
%%hi_ok:
    cmp %1, -DOG_SPEED
    jge %%lo_ok
    mov %1, -DOG_SPEED
%%lo_ok:
%endmacro

; void update_events(void) -- once per tick, before the soldiers move
update_events:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call update_bosses
    call update_police
    call update_dog
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ---- the police ----
update_police:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [cop_active], 0
    jne .up_drive
    cmp dword [ticks], COP_FIRST_DELAY
    jb .up_done
    mov edi, COP_CHANCE
    call chance
    test eax, eax
    jz .up_done
    ; a car arrives on a random route
    mov edi, COP_ROUTES
    call rand_range
    imul eax, eax, 24
    lea rsi, [cop_routes]
    add rsi, rax
    lea rdi, [cop_rect]
    mov ecx, 6                    ; rect + velocity, which follows it
    cld
    rep movsd
    mov dword [cop_fire], COP_FIRE_TICKS
    mov dword [cop_active], 1

.up_drive:
    mov eax, [cop_vel]
    add [cop_rect], eax
    mov eax, [cop_vel + 4]
    add [cop_rect + 4], eax
    ; gone off the far edge?
    mov eax, [cop_rect]
    cmp eax, SCREEN_W
    jg .up_leave
    add eax, [cop_rect + 8]
    cmp eax, 0
    jl .up_leave
    mov eax, [cop_rect + 4]
    cmp eax, SCREEN_H
    jg .up_leave
    add eax, [cop_rect + 12]
    cmp eax, 0
    jl .up_leave

    ; ---- anyone the car touches is arrested ----
    lea r12, [soldiers]
    xor ebx, ebx
.up_touch:
    cmp dword [r12 + Soldier.health], 0
    jle .up_touch_next
    mov eax, [r12 + Soldier.x]
    lea ecx, [eax + SOLDIER_SIZE]
    cmp ecx, [cop_rect]
    jle .up_touch_next
    mov ecx, [cop_rect]
    add ecx, [cop_rect + 8]
    cmp eax, ecx
    jge .up_touch_next
    mov eax, [r12 + Soldier.y]
    lea ecx, [eax + SOLDIER_SIZE]
    cmp ecx, [cop_rect + 4]
    jle .up_touch_next
    mov ecx, [cop_rect + 4]
    add ecx, [cop_rect + 12]
    cmp eax, ecx
    jge .up_touch_next
    ; arrested: out of the game for good
    mov dword [r12 + Soldier.health], 0
    mov edx, [r12 + Soldier.weapon]
    cmp edx, WEAPON_KNIFE
    je .up_no_drop
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    call drop_weapon
.up_no_drop:
    lea rcx, [respawn_timer]
    mov dword [rcx + rbx*4], 0
    lea rcx, [lives_left]
    mov dword [rcx + rbx*4], 0
    inc dword [arrests]
.up_touch_next:
    add r12, Soldier_size
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .up_touch

    ; ---- the officers shoot ----
    dec dword [cop_fire]
    jg .up_done
    mov dword [cop_fire], COP_FIRE_TICKS
    ; from the car's centre, as a soldier corner
    mov r13d, [cop_rect + 8]
    shr r13d, 1
    add r13d, [cop_rect]
    sub r13d, SOLDIER_SIZE / 2
    mov r14d, [cop_rect + 12]
    shr r14d, 1
    add r14d, [cop_rect + 4]
    sub r14d, SOLDIER_SIZE / 2
    ; nearest living soldier in range with a clear line
    mov r15d, -1                  ; best index
    mov r12d, COP_RANGE * COP_RANGE + 1
    xor ebx, ebx
.up_aim:
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    cmp dword [rcx + Soldier.health], 0
    jle .up_aim_next
    mov eax, [rcx + Soldier.x]
    sub eax, r13d
    imul eax, eax
    mov edx, [rcx + Soldier.y]
    sub edx, r14d
    imul edx, edx
    add eax, edx
    cmp eax, r12d
    jae .up_aim_next
    push rax
    push rcx
    mov edi, r13d
    mov esi, r14d
    mov edx, [rcx + Soldier.x]
    mov ecx, [rcx + Soldier.y]
    call sight_blocked
    pop rcx
    mov edx, eax
    pop rax
    test edx, edx
    jnz .up_aim_next
    mov r12d, eax
    mov r15d, ebx
.up_aim_next:
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .up_aim
    cmp r15d, -1
    je .up_done
    mov edi, 100
    call rand_range
    xor ebx, ebx
    cmp eax, COP_HIT_CHANCE
    setb bl                       ; hit?
    mov [fx_src], r13d
    mov [fx_src + 4], r14d
    mov edi, WEAPON_PISTOL
    mov esi, -1
    mov edx, r15d
    mov ecx, ebx
    call spawn_effect
    test ebx, ebx
    jz .up_done
    mov edi, r15d
    mov esi, COP_DAMAGE
    call event_damage
    add [cop_kills], eax
    jmp .up_done
.up_leave:
    mov dword [cop_active], 0
.up_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ---- the pitbull ----
update_dog:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, [dog_state]
    cmp eax, DOG_NONE
    jne .ud_walking
    cmp dword [ticks], DOG_FIRST_DELAY
    jb .ud_done
    mov edi, DOG_CHANCE
    call chance
    test eax, eax
    jz .ud_done
    mov edi, DOG_WALKS
    call rand_range
    imul eax, eax, 12
    lea rsi, [dog_walks]
    add rsi, rax
    mov eax, [rsi]
    mov [walker_x], eax
    mov eax, [rsi + 4]
    mov [walker_y], eax
    mov eax, [rsi + 8]
    mov [walker_dx], eax
    mov dword [dog_state], DOG_LEASHED

.ud_walking:
    ; the walker keeps walking, whatever the dog does
    mov eax, [walker_dx]
    add [walker_x], eax
    ; the dog, on its leash, trots a little ahead
    cmp dword [dog_state], DOG_LEASHED
    jne .ud_not_leashed
    imul eax, [walker_dx], 16
    add eax, [walker_x]
    mov [dog_x], eax
    mov eax, [walker_y]
    inc eax
    mov [dog_y], eax
    ; slips the leash? (only once it's on screen)
    mov eax, [dog_x]
    cmp eax, 0
    jl .ud_check_end
    cmp eax, SCREEN_W - DOG_W
    jg .ud_check_end
    mov edi, DOG_BREAK_CHANCE
    call chance
    test eax, eax
    jz .ud_check_end
    mov dword [dog_state], DOG_LOOSE
    mov dword [dog_timer], DOG_RAGE_TICKS
    mov dword [dog_bite], 0
    jmp .ud_check_end

.ud_not_leashed:
    cmp dword [dog_state], DOG_LOOSE
    jne .ud_check_end
    dec dword [dog_timer]
    jg .ud_hunt
    mov dword [dog_state], DOG_GONE   ; animal control
    jmp .ud_check_end
.ud_hunt:
    cmp dword [dog_bite], 0
    jle .ud_bite_ready
    dec dword [dog_bite]
.ud_bite_ready:
    ; nearest living soldier, either gang
    mov r15d, -1
    mov r12d, 0x7FFFFFFF
    lea rcx, [soldiers]
    xor ebx, ebx
.ud_near:
    cmp dword [rcx + Soldier.health], 0
    jle .ud_near_next
    mov eax, [rcx + Soldier.x]
    sub eax, [dog_x]
    imul eax, eax
    mov edx, [rcx + Soldier.y]
    sub edx, [dog_y]
    imul edx, edx
    add eax, edx
    cmp eax, r12d
    jae .ud_near_next
    mov r12d, eax
    mov r15d, ebx
.ud_near_next:
    add rcx, Soldier_size
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .ud_near
    cmp r15d, -1
    je .ud_check_end
    imul eax, r15d, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    mov r13d, [rcx + Soldier.x]   ; target corner
    mov r14d, [rcx + Soldier.y]
    ; in reach? bite
    cmp r12d, CONTACT_RANGE * CONTACT_RANGE
    jg .ud_chase
    cmp dword [dog_bite], 0
    jg .ud_check_end
    mov dword [dog_bite], DOG_BITE_TICKS
    mov edi, 100
    call rand_range
    xor ebx, ebx
    cmp eax, DOG_BITE_CHANCE
    setb bl
    mov eax, [dog_x]
    mov [fx_src], eax
    mov eax, [dog_y]
    mov [fx_src + 4], eax
    mov edi, WEAPON_KNIFE         ; a lunge, drawn like a knife thrust
    mov esi, -1
    mov edx, r15d
    mov ecx, ebx
    call spawn_effect
    test ebx, ebx
    jz .ud_check_end
    mov edi, r15d
    mov esi, DOG_DAMAGE
    call event_damage
    add [dog_kills], eax
    jmp .ud_check_end
.ud_chase:
    ; step toward it; if that's blocked, try each axis alone
    mov r8d, r13d
    sub r8d, [dog_x]
    CLAMP_DOG r8d
    mov r9d, r14d
    sub r9d, [dog_y]
    CLAMP_DOG r9d
    mov r12d, r8d                 ; dx
    mov r13d, r9d                 ; dy
    mov edi, [dog_x]
    add edi, r12d
    mov esi, [dog_y]
    add esi, r13d
    call is_box_blocked
    test eax, eax
    jz .ud_move
    xor r13d, r13d                ; x only
    mov edi, [dog_x]
    add edi, r12d
    mov esi, [dog_y]
    call is_box_blocked
    test eax, eax
    jz .ud_move
    mov r8d, r14d                 ; y only
    sub r8d, [dog_y]
    CLAMP_DOG r8d
    mov r13d, r8d
    xor r12d, r12d
    mov edi, [dog_x]
    mov esi, [dog_y]
    add esi, r13d
    call is_box_blocked
    test eax, eax
    jnz .ud_check_end             ; boxed in: wait
.ud_move:
    add [dog_x], r12d
    add [dog_y], r13d

.ud_check_end:
    ; the encounter is over once the walker is off screen and the dog
    ; isn't loose (it left with them, or animal control has it)
    cmp dword [dog_state], DOG_LOOSE
    je .ud_done
    mov eax, [walker_x]
    cmp eax, -60
    jl .ud_over
    cmp eax, SCREEN_W + 60
    jg .ud_over
    jmp .ud_done
.ud_over:
    mov dword [dog_state], DOG_NONE
.ud_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_events(void) -- the police car, the walker and the dog
draw_events:
    push rbx
    push r12
    sub rsp, 8
    cmp dword [cop_active], 0
    je .de_walker
    ; body
    lea rdi, [back_fb]
    mov esi, [cop_rect]
    mov edx, [cop_rect + 4]
    mov ecx, [cop_rect + 8]
    mov r8d, [cop_rect + 12]
    mov r9d, COLOR_COP_BODY
    call fill_rect
    ; white doors across the middle third, windscreen, light bar
    mov eax, [cop_rect + 8]
    cmp eax, [cop_rect + 12]
    jl .de_cop_vertical
    lea rdi, [back_fb]
    mov esi, [cop_rect]
    add esi, 13
    mov edx, [cop_rect + 4]
    mov ecx, 14
    mov r8d, [cop_rect + 12]
    mov r9d, COLOR_COP_DOOR
    call fill_rect
    mov ebx, [cop_rect]           ; light bar: two 6x4 halves at the centre
    add ebx, 14
    mov r12d, [cop_rect + 4]
    add r12d, 8
    jmp .de_siren
.de_cop_vertical:
    lea rdi, [back_fb]
    mov esi, [cop_rect]
    mov edx, [cop_rect + 4]
    add edx, 13
    mov ecx, [cop_rect + 8]
    mov r8d, 14
    mov r9d, COLOR_COP_DOOR
    call fill_rect
    mov ebx, [cop_rect]
    add ebx, 4
    mov r12d, [cop_rect + 4]
    add r12d, 18
.de_siren:
    ; red and blue swap sides every 8 frames
    lea rdi, [back_fb]
    mov esi, ebx
    mov edx, r12d
    mov ecx, 6
    mov r8d, 4
    mov r9d, COLOR_SIREN_R
    test dword [ticks], 8
    jz .de_s1
    mov r9d, COLOR_SIREN_B
.de_s1:
    call fill_rect
    lea rdi, [back_fb]
    lea esi, [ebx + 6]
    mov edx, r12d
    mov ecx, 6
    mov r8d, 4
    mov r9d, COLOR_SIREN_B
    test dword [ticks], 8
    jz .de_s2
    mov r9d, COLOR_SIREN_R
.de_s2:
    call fill_rect

.de_walker:
    cmp dword [dog_state], DOG_NONE
    je .de_done
    call draw_walker
    cmp dword [dog_state], DOG_GONE
    je .de_done
    ; the leash, while it holds
    cmp dword [dog_state], DOG_LEASHED
    jne .de_dog
    lea rdi, [back_fb]
    mov esi, [walker_x]
    add esi, WALKER_SIZE / 2
    mov edx, [walker_y]
    add edx, WALKER_SIZE / 2
    mov ecx, [dog_x]
    add ecx, DOG_W / 2
    mov r8d, [dog_y]
    add r8d, DOG_H / 2
    mov r9d, COLOR_LEASH
    call draw_line
.de_dog:
    lea rdi, [back_fb]
    mov esi, [dog_x]
    mov edx, [dog_y]
    mov ecx, DOG_W
    mov r8d, DOG_H
    mov r9d, COLOR_DOG
    cmp dword [dog_state], DOG_LOOSE
    jne .de_dog_colour
    mov r9d, COLOR_DOG_MAD
.de_dog_colour:
    call fill_rect
.de_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void build_title(void)
; title_buf = "Stage 7.13 - Neighborhood", 0-terminated for SDL.
build_title:
    lea rdi, [title_buf]
    lea rsi, [title_prefix]
    mov edx, title_prefix_len
    call append_bytes
    call append_arena_name
    mov byte [rdi], 0
    ret


; append_arena_name(dst: rdi) -> rdi = past the name
append_arena_name:
    lea rsi, [map_name]
    mov edx, map_name_len
    jmp append_bytes


; int find_nearest_enemy(int self_index: edi) -> eax (index, or -1)
FNE_SELF     equ -8
FNE_MY_X     equ -16
FNE_MY_Y     equ -24
FNE_MY_TEAM  equ -32
FNE_BEST_IDX equ -40
FNE_BEST_DIST equ -48
FNE_J        equ -56

find_nearest_enemy:
    push rbp
    mov rbp, rsp
    sub rsp, 64

    mov [rbp + FNE_SELF], edi

    mov eax, edi
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    mov [rbp + FNE_MY_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + FNE_MY_Y], eax
    mov eax, [r10 + Soldier.team]
    mov [rbp + FNE_MY_TEAM], eax

    mov dword [rbp + FNE_BEST_IDX], -1
    mov dword [rbp + FNE_BEST_DIST], 0x7FFFFFFF

    mov dword [rbp + FNE_J], 0
.scan_loop:
    mov eax, [rbp + FNE_J]
    cmp eax, TOTAL_SOLDIERS
    jge .scan_done

    cmp eax, [rbp + FNE_SELF]
    je .scan_next

    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    cmp dword [r10 + Soldier.health], 0
    jle .scan_next

    mov eax, [r10 + Soldier.team]
    cmp eax, [rbp + FNE_MY_TEAM]
    je .scan_next

    mov eax, [r10 + Soldier.x]
    sub eax, [rbp + FNE_MY_X]
    imul eax, eax
    mov ecx, eax

    mov eax, [r10 + Soldier.y]
    sub eax, [rbp + FNE_MY_Y]
    imul eax, eax
    add ecx, eax

    cmp ecx, [rbp + FNE_BEST_DIST]
    jge .scan_next
    mov [rbp + FNE_BEST_DIST], ecx
    mov eax, [rbp + FNE_J]
    mov [rbp + FNE_BEST_IDX], eax

.scan_next:
    mov eax, [rbp + FNE_J]
    inc eax
    mov [rbp + FNE_J], eax
    jmp .scan_loop
.scan_done:
    mov eax, [rbp + FNE_BEST_IDX]
    mov rsp, rbp
    pop rbp
    ret


; int find_nearest_pickup(int self_index: edi) -> eax (index, or -1)
FNP_MY_X      equ -8
FNP_MY_Y      equ -16
FNP_BEST_IDX  equ -24
FNP_BEST_DIST equ -32
FNP_J         equ -40

find_nearest_pickup:
    push rbp
    mov rbp, rsp
    sub rsp, 48

    mov eax, edi
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    mov [rbp + FNP_MY_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + FNP_MY_Y], eax

    mov dword [rbp + FNP_BEST_IDX], -1
    mov dword [rbp + FNP_BEST_DIST], 0x7FFFFFFF

    mov dword [rbp + FNP_J], 0
.scan_loop:
    mov eax, [rbp + FNP_J]
    cmp eax, MAX_PICKUPS
    jge .scan_done

    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax

    cmp dword [r10 + Pickup.active], 0
    je .scan_next

    mov eax, [r10 + Pickup.x]
    sub eax, [rbp + FNP_MY_X]
    imul eax, eax
    mov ecx, eax
    mov eax, [r10 + Pickup.y]
    sub eax, [rbp + FNP_MY_Y]
    imul eax, eax
    add ecx, eax

    cmp ecx, [rbp + FNP_BEST_DIST]
    jge .scan_next
    mov [rbp + FNP_BEST_DIST], ecx
    mov eax, [rbp + FNP_J]
    mov [rbp + FNP_BEST_IDX], eax

.scan_next:
    mov eax, [rbp + FNP_J]
    inc eax
    mov [rbp + FNP_J], eax
    jmp .scan_loop
.scan_done:
    mov eax, [rbp + FNP_BEST_IDX]
    mov rsp, rbp
    pop rbp
    ret


; int get_weapon_range_sq(int weapon: edi) -> eax
get_weapon_range_sq:
    cmp edi, WEAPON_KNIFE
    jne .not_knife
    mov eax, CONTACT_RANGE * CONTACT_RANGE
    ret
.not_knife:
    cmp edi, WEAPON_PISTOL
    jne .not_pistol
    mov eax, PISTOL_RANGE * PISTOL_RANGE
    ret
.not_pistol:
    mov eax, SHOTGUN_RANGE * SHOTGUN_RANGE
    ret


; void drop_weapon(int x: edi, int y: esi, int type: edx)
drop_weapon:
    push rbx
    xor ebx, ebx
.dw_loop:
    cmp ebx, MAX_PICKUPS
    jge .dw_done

    mov eax, ebx
    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax
    cmp dword [r10 + Pickup.active], 0
    jne .dw_next

    mov [r10 + Pickup.x], edi
    mov [r10 + Pickup.y], esi
    mov [r10 + Pickup.type], edx
    mov dword [r10 + Pickup.active], 1
    jmp .dw_done
.dw_next:
    inc ebx
    jmp .dw_loop
.dw_done:
    pop rbx
    ret


; int is_box_blocked(int x: edi, int y: esi) -> eax (1 or 0)
; Could a soldier's box stand with its corner at (x, y)? Not if any of
; it is off the field (see 06's README for why the edges count), and
; not if it overlaps a wall or a prop: one blockmap byte, precomputed
; by build_blockmap. 06-12 looped over every wall here; the
; neighborhood has 54 walls and props, and line_blocked calls this
; for every point on every line.
is_box_blocked:
    mov dword [lb_mask], BLOCK_WALK
; int box_mask_blocked(int x: edi, int y: esi) -> eax: the same test,
; for whichever bit lb_mask holds (line_blocked's sight mode uses it)
box_mask_blocked:
    cmp edi, SCREEN_W - SOLDIER_SIZE
    ja .bmb_blocked               ; unsigned: negative x too
    cmp esi, SCREEN_H - SOLDIER_SIZE
    ja .bmb_blocked
    imul eax, esi, BM_W
    add eax, edi
    lea rcx, [blockmap]
    movzx eax, byte [rcx + rax]
    and eax, [lb_mask]
    setnz al
    movzx eax, al
    ret
.bmb_blocked:
    mov eax, 1
    ret


; void build_blockmap(void)
; blockmap[y * BM_W + x] gets BLOCK_WALK | BLOCK_SIGHT for every corner
; position whose soldier box would overlap a wall, and BLOCK_WALK for
; every one that would overlap a prop. A box at corner cx overlaps a
; rectangle starting at wx, wx+ww wide, when wx - 15 <= cx <= wx+ww-1,
; so each rectangle just marks a slightly bigger rectangle of bytes.
build_blockmap:
    push rbx
    push r12
    sub rsp, 8
    lea rbx, [map_walls]
    mov r12d, map_walls_count
.bbm_wall:
    mov r8d, BLOCK_WALK | BLOCK_SIGHT
    call mark_rect
    add rbx, 16
    dec r12d
    jnz .bbm_wall
    lea rbx, [map_props]
    mov r12d, map_props_count
.bbm_prop:
    mov r8d, BLOCK_WALK
    call mark_rect
    add rbx, 16
    dec r12d
    jnz .bbm_prop
    add rsp, 8
    pop r12
    pop rbx
    ret

; mark_rect: OR bits r8b into the blockmap for the rectangle at [rbx]
; (x, y, w, h). Clobbers eax, ecx, edx, esi, edi, r9-r11.
mark_rect:
    mov eax, [rbx]
    sub eax, SOLDIER_SIZE - 1
    CLAMP_TO eax, BM_W - 1
    mov edi, eax                  ; x0
    mov eax, [rbx]
    add eax, [rbx + 8]
    dec eax
    CLAMP_TO eax, BM_W - 1
    mov edx, eax                  ; x1
    mov eax, [rbx + 4]
    sub eax, SOLDIER_SIZE - 1
    CLAMP_TO eax, BM_H - 1
    mov esi, eax                  ; y0
    mov eax, [rbx + 4]
    add eax, [rbx + 12]
    dec eax
    CLAMP_TO eax, BM_H - 1
    mov ecx, eax                  ; y1
    lea r9, [blockmap]
.mr_row:
    cmp esi, ecx
    jg .mr_done
    imul r10d, esi, BM_W
    add r10d, edi
    mov r11d, edx
    sub r11d, edi
.mr_col:
    or [r9 + r10], r8b
    inc r10d
    dec r11d
    jns .mr_col
    inc esi
    jmp .mr_row
.mr_done:
    ret


;
; int is_spot_blocked(int self: edi, int x: esi, int y: edx) -> eax (1 or 0)
;
; Could soldier `self` stand with its box anchored at (x, y)? No if
; is_box_blocked says so (wall or screen edge), and no if the box would
; overlap any OTHER living soldier's box. Two SOLDIER_SIZE boxes overlap
; exactly when both |dx| and |dy| between their corners are under
; SOLDIER_SIZE -- the same AABB test as is_box_blocked, simplified
; because both boxes are the same size.
;
; Every move in update_soldiers goes through this, and spawns never
; overlap, so "no two living soldiers overlap" stays true for the whole
; game. That matters: a soldier that somehow started out overlapping a
; neighbour would find every single candidate step blocked by it.
; Dead soldiers are skipped, so a body never blocks anyone.
;
; Not used by line_blocked: sight lines and wall-routing only care
; about walls (see the note at the top of update_soldiers' .do_move).
is_spot_blocked:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8                   ; keep the stack 16-byte aligned for the call

    mov r12d, edi                ; self
    mov r13d, esi                ; x
    mov r14d, edx                ; y

    mov edi, r13d
    mov esi, r14d
    call is_box_blocked
    test eax, eax
    jnz .isb_done                ; eax is already 1

    xor ebx, ebx
.isb_loop:
    cmp ebx, TOTAL_SOLDIERS
    jge .isb_clear
    cmp ebx, r12d
    je .isb_next

    mov eax, ebx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .isb_next

    mov eax, [r10 + Soldier.x]
    sub eax, r13d
    jns .isb_dx_ok
    neg eax
.isb_dx_ok:
    cmp eax, SOLDIER_SIZE
    jge .isb_next                ; far enough apart horizontally

    mov eax, [r10 + Soldier.y]
    sub eax, r14d
    jns .isb_dy_ok
    neg eax
.isb_dy_ok:
    cmp eax, SOLDIER_SIZE
    jge .isb_next                ; far enough apart vertically

    mov eax, 1                   ; overlaps soldier ebx
    jmp .isb_done
.isb_next:
    inc ebx
    jmp .isb_loop
.isb_clear:
    xor eax, eax
.isb_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int line_blocked(int x0: edi, int y0: esi, int x1: edx, int y1: ecx) -> eax (1 or 0)
; Stage3's draw_line, Bresenham step for Bresenham step -- set_pixel
; is replaced with a call to is_box_blocked, and the walk exits
; the moment any step is blocked instead of always visiting every
; point on the line.
LB_X0  equ -8
LB_Y0  equ -16
LB_X1  equ -24
LB_Y1  equ -32
LB_SX  equ -40
LB_SY  equ -48
LB_DX  equ -56
LB_DY  equ -64
LB_ERR equ -72

; int sight_blocked(same arguments) -> eax: line_blocked for bullets
; and line of sight. Only walls count: you can shoot over a car.
sight_blocked:
    mov dword [lb_mask], BLOCK_SIGHT
    jmp line_blocked_core
line_blocked:
    mov dword [lb_mask], BLOCK_WALK
line_blocked_core:
    push rbp
    mov rbp, rsp
    sub rsp, 80

    mov [rbp + LB_X0], edi
    mov [rbp + LB_Y0], esi
    mov [rbp + LB_X1], edx
    mov [rbp + LB_Y1], ecx

    mov eax, [rbp + LB_X1]
    sub eax, [rbp + LB_X0]
    jns .dx_nonneg
    neg eax
.dx_nonneg:
    mov [rbp + LB_DX], eax

    mov eax, [rbp + LB_X0]
    cmp eax, [rbp + LB_X1]
    mov eax, 1
    jl .sx_done
    mov eax, -1
.sx_done:
    mov [rbp + LB_SX], eax

    mov eax, [rbp + LB_Y1]
    sub eax, [rbp + LB_Y0]
    jns .dy_nonneg
    neg eax
.dy_nonneg:
    neg eax
    mov [rbp + LB_DY], eax

    mov eax, [rbp + LB_Y0]
    cmp eax, [rbp + LB_Y1]
    mov eax, 1
    jl .sy_done
    mov eax, -1
.sy_done:
    mov [rbp + LB_SY], eax

    mov eax, [rbp + LB_DX]
    add eax, [rbp + LB_DY]
    mov [rbp + LB_ERR], eax

.step_loop:
    mov edi, [rbp + LB_X0]
    mov esi, [rbp + LB_Y0]
    call box_mask_blocked
    test eax, eax
    jz .not_blocked_here
    mov eax, 1
    mov rsp, rbp
    pop rbp
    ret
.not_blocked_here:
    mov eax, [rbp + LB_X0]
    cmp eax, [rbp + LB_X1]
    jne .continue_step
    mov eax, [rbp + LB_Y0]
    cmp eax, [rbp + LB_Y1]
    je .lb_clear
.continue_step:
    mov eax, [rbp + LB_ERR]
    add eax, eax

    cmp eax, [rbp + LB_DY]
    jl .skip_x
    mov ecx, [rbp + LB_ERR]
    add ecx, [rbp + LB_DY]
    mov [rbp + LB_ERR], ecx
    mov ecx, [rbp + LB_X0]
    add ecx, [rbp + LB_SX]
    mov [rbp + LB_X0], ecx
.skip_x:
    cmp eax, [rbp + LB_DX]
    jg .skip_y
    mov ecx, [rbp + LB_ERR]
    add ecx, [rbp + LB_DX]
    mov [rbp + LB_ERR], ecx
    mov ecx, [rbp + LB_Y0]
    add ecx, [rbp + LB_SY]
    mov [rbp + LB_Y0], ecx
.skip_y:
    jmp .step_loop
.lb_clear:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret


; void update_soldiers(void)
; Same as stage6c/01 except `.do_move`: every candidate position is now
; checked with is_spot_blocked (walls AND other soldiers), and a step
; blocked by a soldier falls back to main-axis-only, then to the same
; sticky side-step that already routes around walls.
US_I         equ -32
US_ACTUAL    equ -40
US_SELF_X    equ -48
US_SELF_Y    equ -56
US_WEAPON    equ -64
US_GOAL_X    equ -72
US_GOAL_Y    equ -80
US_IS_PICKUP equ -88
US_PICKUP_IDX equ -96
US_TARGET    equ -104
US_DIST_SQ   equ -112
US_NEG_BLOCKED equ -120
US_POS_BLOCKED equ -128
US_FWD_STEP  equ -136
US_STEP_X    equ -144
US_STEP_Y    equ -152
US_HIT       equ -160    ; this attack's hit roll, 1 = hit (for spawn_effect)

update_soldiers:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8
    sub rsp, 128                ; 96 in stage6b, +16 for US_FWD_STEP (6c),
                                ; +16 for US_STEP_X/Y. (US_HIT at -160 is the
                                ; last slot this leaves: rbp-24 pushes, 8 pad)

    call rng_next              ; per-tick random processing direction (03_combat.asm's
    and eax, 1                    ; fair-turn-order fix) -- was missing here too, carried
    mov [pass_reverse], eax          ; over from stage6a/04_weapons.asm's same regression

    call build_fields                ; one snapshot per tick, before anyone moves
    call update_events               ; police and dog move, shoot, bite

    mov dword [rbp + US_I], 0
.update_loop:
    mov eax, [rbp + US_I]
    cmp eax, TOTAL_SOLDIERS
    jge .update_done

    cmp dword [pass_reverse], 0
    je .use_forward
    mov ecx, TOTAL_SOLDIERS - 1
    sub ecx, eax
    jmp .have_actual
.use_forward:
    mov ecx, eax
.have_actual:
    mov [rbp + US_ACTUAL], ecx

    mov eax, ecx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .update_next

    cmp dword [r10 + Soldier.cooldown], 0
    jle .cooldown_done
    dec dword [r10 + Soldier.cooldown]
.cooldown_done:

    mov eax, [r10 + Soldier.x]
    mov [rbp + US_SELF_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + US_SELF_Y], eax
    mov eax, [r10 + Soldier.weapon]
    mov [rbp + US_WEAPON], eax
    mov dword [rbp + US_IS_PICKUP], 0

    ; ---- police nearby? run: the goal becomes a point away from the car ----
    mov dword [us_flee], 0
    cmp dword [cop_active], 0
    je .no_fear
    cmp dword [rbp + US_ACTUAL], SQUAD
    jae .no_fear                  ; the Big Homie doesn't run
    mov ecx, [rbp + US_SELF_X]
    mov eax, [cop_rect + 8]
    shr eax, 1
    add eax, [cop_rect]
    sub eax, SOLDIER_SIZE / 2     ; car centre, as a soldier corner
    sub ecx, eax                  ; dx: from the car to us
    mov edx, [rbp + US_SELF_Y]
    mov eax, [cop_rect + 12]
    shr eax, 1
    add eax, [cop_rect + 4]
    sub eax, SOLDIER_SIZE / 2
    sub edx, eax                  ; dy
    mov eax, ecx
    imul eax, eax
    mov r8d, edx
    imul r8d, r8d
    add eax, r8d
    cmp eax, FEAR_RADIUS * FEAR_RADIUS
    jg .no_fear
    mov dword [us_flee], 1
    ; Run OFF THE ROAD: across the car's direction of travel, plus a
    ; little further away along it. 14/15 ran straight away from the
    ; car, which for anyone ahead of it in its lane meant running down
    ; the road in front of it -- at 2 px a tick, from a car doing 3.
    ; (dx, dy: from the car's centre to this soldier)
    cmp dword [cop_vel], 0
    je .flee_car_vertical
    ; car going left/right: get off sideways, up or down
    mov eax, FLEE_DIST
    test edx, edx
    jns .flee_y_sign
    neg eax
.flee_y_sign:
    add eax, [rbp + US_SELF_Y]
    CLAMP_TO eax, SCREEN_H - SOLDIER_SIZE
    mov [rbp + US_GOAL_Y], eax
    mov eax, ecx
    add eax, [rbp + US_SELF_X]
    CLAMP_TO eax, SCREEN_W - SOLDIER_SIZE
    mov [rbp + US_GOAL_X], eax
    jmp .do_move                  ; no fighting, no pickups: just go
.flee_car_vertical:
    ; car going up/down: get off sideways, left or right
    mov eax, FLEE_DIST
    test ecx, ecx
    jns .flee_x_sign
    neg eax
.flee_x_sign:
    add eax, [rbp + US_SELF_X]
    CLAMP_TO eax, SCREEN_W - SOLDIER_SIZE
    mov [rbp + US_GOAL_X], eax
    mov eax, edx
    add eax, [rbp + US_SELF_Y]
    CLAMP_TO eax, SCREEN_H - SOLDIER_SIZE
    mov [rbp + US_GOAL_Y], eax
    jmp .do_move
.no_fear:

    cmp dword [rbp + US_WEAPON], WEAPON_KNIFE
    jne .have_enemy_only

    mov edi, [rbp + US_ACTUAL]
    call find_nearest_pickup
    mov [rbp + US_PICKUP_IDX], eax

    mov edi, [rbp + US_ACTUAL]
    call find_nearest_enemy
    mov [rbp + US_TARGET], eax

    cmp dword [rbp + US_PICKUP_IDX], -1
    je .no_pickup_candidate

    mov eax, [rbp + US_PICKUP_IDX]
    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax
    mov eax, [r10 + Pickup.x]
    sub eax, [rbp + US_SELF_X]
    imul eax, eax
    mov ecx, eax
    mov eax, [r10 + Pickup.y]
    sub eax, [rbp + US_SELF_Y]
    imul eax, eax
    add ecx, eax

    cmp dword [rbp + US_TARGET], -1
    je .use_pickup_goal

    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    sub eax, [rbp + US_SELF_X]
    imul eax, eax
    mov edx, eax
    mov eax, [r10 + Soldier.y]
    sub eax, [rbp + US_SELF_Y]
    imul eax, eax
    add edx, eax

    cmp ecx, edx
    jl .use_pickup_goal
    jmp .use_enemy_goal

.no_pickup_candidate:
    cmp dword [rbp + US_TARGET], -1
    je .update_next
    jmp .use_enemy_goal

.use_pickup_goal:
    mov dword [rbp + US_IS_PICKUP], 1
    mov eax, [rbp + US_PICKUP_IDX]
    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax
    mov eax, [r10 + Pickup.x]
    mov [rbp + US_GOAL_X], eax
    mov eax, [r10 + Pickup.y]
    mov [rbp + US_GOAL_Y], eax
    jmp .goal_decided

.have_enemy_only:
    mov edi, [rbp + US_ACTUAL]
    call find_nearest_enemy
    mov [rbp + US_TARGET], eax
    cmp eax, -1
    je .update_next

.use_enemy_goal:
    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    mov [rbp + US_GOAL_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + US_GOAL_Y], eax

.goal_decided:
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]
    imul eax, eax
    mov ecx, eax
    mov eax, [rbp + US_GOAL_Y]
    sub eax, [rbp + US_SELF_Y]
    imul eax, eax
    add ecx, eax
    mov [rbp + US_DIST_SQ], ecx

    cmp dword [rbp + US_IS_PICKUP], 0
    jne .handle_pickup_goal
    jmp .handle_enemy_goal

.handle_pickup_goal:
    mov eax, [rbp + US_DIST_SQ]
    cmp eax, PICKUP_RADIUS * PICKUP_RADIUS
    jg .do_move

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    mov eax, [rbp + US_PICKUP_IDX]
    imul eax, Pickup_size
    lea r11, [pickups]
    add r11, rax

    mov eax, [r11 + Pickup.type]
    mov [r10 + Soldier.weapon], eax
    mov dword [r11 + Pickup.active], 0
    jmp .update_next

.handle_enemy_goal:
    mov edi, [rbp + US_WEAPON]
    call get_weapon_range_sq
    cmp dword [rbp + US_DIST_SQ], eax
    jg .do_move

    ; ranged weapons need line of sight to actually fire; knife is
    ; contact-range only, and an obstacle blocking contact would
    ; already have blocked the movement that got here, so skip the
    ; check for it entirely
    mov eax, [rbp + US_WEAPON]
    cmp eax, WEAPON_KNIFE
    je .los_ok

    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    mov edx, [rbp + US_GOAL_X]
    mov ecx, [rbp + US_GOAL_Y]
    call sight_blocked             ; walls only: you can shoot over a car
    test eax, eax
    jnz .do_move                   ; blocked -- can't fire, try to reposition instead
.los_ok:

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.cooldown], 0
    jg .update_next

    ; ---- ready to fire: who would the shot hit? ----
    ; (knife: contact range, so the target is the only one it can reach)
    cmp dword [rbp + US_WEAPON], WEAPON_KNIFE
    je .victim_ok
    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_TARGET]
    call first_in_line

    ; a teammate first in the line -> hold fire and side-step for a
    ; clear shot. .side_step steps perpendicular to US_GOAL, which here
    ; is the target, so it moves the soldier across the line of fire
    mov ecx, eax
    imul ecx, Soldier_size
    lea rdx, [soldiers]
    mov ecx, [rdx + rcx + Soldier.team]
    mov r8d, [rbp + US_ACTUAL]
    imul r8d, Soldier_size
    cmp ecx, [rdx + r8 + Soldier.team]
    jne .fire_clear
    inc dword [ff_held]
    jmp .side_step
.fire_clear:
    mov [rbp + US_TARGET], eax     ; from here on, "target" = whoever gets hit

    ; first_in_line used r10 as scratch -- point it back at the shooter
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
.victim_ok:

    mov eax, [rbp + US_WEAPON]
    cmp eax, WEAPON_KNIFE
    jne .not_atk_knife
    mov r12d, KNIFE_DAMAGE
    mov r13d, KNIFE_HIT_CHANCE
    mov r14d, KNIFE_COOLDOWN_TICKS
    jmp .have_atk_stats
.not_atk_knife:
    cmp eax, WEAPON_PISTOL
    jne .atk_shotgun
    mov r12d, PISTOL_DAMAGE
    mov r13d, PISTOL_HIT_CHANCE
    mov r14d, PISTOL_COOLDOWN_TICKS
    jmp .have_atk_stats
.atk_shotgun:
    mov eax, [rbp + US_DIST_SQ]
    cmp eax, SHOTGUN_CLOSE_RANGE * SHOTGUN_CLOSE_RANGE
    jg .shotgun_far
    mov r12d, SHOTGUN_CLOSE_DAMAGE
    mov r13d, SHOTGUN_CLOSE_HIT
    jmp .shotgun_cd
.shotgun_far:
    mov r12d, SHOTGUN_FAR_DAMAGE
    mov r13d, SHOTGUN_FAR_HIT
.shotgun_cd:
    mov r14d, SHOTGUN_COOLDOWN_TICKS
.have_atk_stats:
    cmp dword [rbp + US_ACTUAL], SQUAD
    jb .not_boss_attack
    shl r12d, 1                   ; the Big Homie: double damage,
    add r13d, BOSS_HIT_BONUS      ; and harder to miss
    cmp r13d, BOSS_HIT_CAP
    jle .not_boss_attack
    mov r13d, BOSS_HIT_CAP
.not_boss_attack:
    mov [r10 + Soldier.cooldown], r14d

    call rng_next
    xor edx, edx
    mov ecx, 100
    div ecx
    xor eax, eax
    cmp edx, r13d
    setl al                        ; same roll as before, just kept
    mov [rbp + US_HIT], eax

    ; record the attack for the renderer -- hit or miss. Drawing only:
    ; no RNG, no soldier state, so the fight is unchanged
    mov edi, [rbp + US_WEAPON]
    mov esi, [rbp + US_ACTUAL]
    mov edx, [rbp + US_TARGET]
    mov ecx, eax
    call spawn_effect

    cmp dword [rbp + US_HIT], 0
    je .update_next

    ; spawn protection: the hit lands (and shows) but does nothing
    mov eax, [rbp + US_TARGET]
    lea rcx, [protect_timer]
    cmp dword [rcx + rax*4], 0
    jg .update_next

    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r11, [soldiers]
    add r11, rax

    ; tally friendly fire. r13d (the hit chance) is free after the roll,
    ; so it holds "same team" through the kill check below
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea rcx, [soldiers]
    mov eax, [rcx + rax + Soldier.team]
    xor r13d, r13d
    cmp eax, [r11 + Soldier.team]
    jne .ff_tallied
    mov r13d, 1
    inc dword [ff_hits]
.ff_tallied:

    sub dword [r11 + Soldier.health], r12d
    cmp dword [r11 + Soldier.health], 0
    jg .update_next
    mov dword [r11 + Soldier.health], 0
    add [ff_kills], r13d

    ; ---- a kill: score it, and book the victim's respawn ----
    ; (r11 still points at the victim for the weapon drop below)
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea rcx, [soldiers]
    mov ecx, [rcx + rax + Soldier.team]  ; killer's team
    cmp ecx, [r11 + Soldier.team]
    je .scored                     ; friendly kills score nothing
    inc dword [score + rcx*4]
    mov eax, [score_limit]
    test eax, eax
    jle .scored                    ; no limit
    cmp [score + rcx*4], eax
    jne .scored
    cmp dword [score_winner], 0
    jne .scored                    ; the other team got there first
    inc ecx
    mov [score_winner], ecx
.scored:
    ; a respawn needs one from the soldier's own lives (LIVES) AND one
    ; from the team's pool (RESPAWNS); either can be unlimited (-1)
    mov eax, [rbp + US_TARGET]
    lea rcx, [lives_left]
    cmp dword [rcx + rax*4], 0
    je .no_respawn                 ; last life: dead for good
    mov edx, [r11 + Soldier.team]
    cmp dword [tickets + rdx*4], 0
    je .no_respawn                 ; team pool empty: dead for good
    jl .pool_ok                    ; unlimited
    dec dword [tickets + rdx*4]
.pool_ok:
    cmp dword [rcx + rax*4], 0
    jl .book_respawn               ; unlimited
    dec dword [rcx + rax*4]
.book_respawn:
    lea rcx, [respawn_timer]
    mov dword [rcx + rax*4], RESPAWN_TICKS
.no_respawn:

    mov eax, [r11 + Soldier.weapon]
    cmp eax, WEAPON_KNIFE
    je .update_next

    mov edi, [r11 + Soldier.x]
    mov esi, [r11 + Soldier.y]
    mov edx, eax
    call drop_weapon
    jmp .update_next

.do_move:
    ; ---- is the direct path to the goal clear of WALLS? ----
    ; (line_blocked deliberately ignores soldiers: it also answers the
    ; line-of-sight question, and a teammate standing in the line would
    ; otherwise block every shot -- including the target itself, which
    ; sits right at the end of the line)
    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    mov edx, [rbp + US_GOAL_X]
    mov ecx, [rbp + US_GOAL_Y]
    call line_blocked
    test eax, eax
    jnz .follow_field

.clear_step:
    ; ---- clear of walls: the usual step, clamped to MOVE_SPEED per axis ----
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]
    cmp eax, MOVE_SPEED
    jle .sx_hi_ok
    mov eax, MOVE_SPEED
.sx_hi_ok:
    cmp eax, -MOVE_SPEED
    jge .sx_lo_ok
    mov eax, -MOVE_SPEED
.sx_lo_ok:
    mov [rbp + US_STEP_X], eax

    mov eax, [rbp + US_GOAL_Y]
    sub eax, [rbp + US_SELF_Y]
    cmp eax, MOVE_SPEED
    jle .sy_hi_ok
    mov eax, MOVE_SPEED
.sy_hi_ok:
    cmp eax, -MOVE_SPEED
    jge .sy_lo_ok
    mov eax, -MOVE_SPEED
.sy_lo_ok:
    mov [rbp + US_STEP_Y], eax

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    add esi, [rbp + US_STEP_X]
    mov edx, [rbp + US_SELF_Y]
    add edx, [rbp + US_STEP_Y]
    call is_spot_blocked
    test eax, eax
    jz .apply_step

    ; ---- another soldier is in the way: try the MAIN axis alone ----
    ; Only the main axis (whichever of |dx|, |dy| is larger), never the
    ; minor one. Sliding along the minor axis is what a side-step around
    ; the blocker would immediately undo: step up to get around someone,
    ; then next tick the minor-axis slide pulls you straight back down
    ; into line behind them -- stage6b's bug #5 oscillation all over
    ; again. If the main axis is blocked too, hand off to the sticky
    ; side-step below, which exists precisely to commit to one way round.
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]
    jns .mx_abs_ok
    neg eax
.mx_abs_ok:
    mov ecx, [rbp + US_GOAL_Y]
    sub ecx, [rbp + US_SELF_Y]
    jns .my_abs_ok
    neg ecx
.my_abs_ok:
    cmp eax, ecx
    jl .main_axis_y
    mov dword [rbp + US_STEP_Y], 0
    jmp .try_main_axis
.main_axis_y:
    mov dword [rbp + US_STEP_X], 0
.try_main_axis:
    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    add esi, [rbp + US_STEP_X]
    mov edx, [rbp + US_SELF_Y]
    add edx, [rbp + US_STEP_Y]
    call is_spot_blocked
    test eax, eax
    jnz .side_step

.apply_step:
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [rbp + US_STEP_X]
    add [r10 + Soldier.x], eax
    mov eax, [rbp + US_STEP_Y]
    add [r10 + Soldier.y], eax
    jmp .update_next

.follow_field:
    ; running from the police: there's no field for "away", so the old
    ; side-step it is
    cmp dword [us_flee], 0
    jne .side_step
    ; ---- a wall is in the way: head for the next cell on the flow field ----
    ; Which field: pickups if that's the goal, else the enemy team's.
    ; The waypoint replaces the goal, and .clear_step walks to it, with
    ; the usual fallbacks if a soldier is standing there
    lea rsi, [field_pk]
    cmp dword [rbp + US_IS_PICKUP], 0
    jne .have_field
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea rcx, [soldiers]
    lea rsi, [field_to1]
    cmp dword [rcx + rax + Soldier.team], 0
    je .have_field
    lea rsi, [field_to0]
.have_field:
    mov edi, [rbp + US_ACTUAL]
    call flow_waypoint
    test eax, eax
    jz .side_step                  ; no closer neighbour: old behaviour
    mov eax, [flow_wx]
    mov [rbp + US_GOAL_X], eax
    mov eax, [flow_wy]
    mov [rbp + US_GOAL_Y], eax
    jmp .clear_step

.side_step:
    ; ---- blocked (by a wall or a soldier): step perpendicular to the goal ----
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]           ; dx
    mov ecx, [rbp + US_GOAL_Y]
    sub ecx, [rbp + US_SELF_Y]              ; dy

    mov edx, eax
    cmp edx, 0
    jns .dx_abs_ok
    neg edx
.dx_abs_ok:
    mov r8d, ecx
    cmp r8d, 0
    jns .dy_abs_ok
    neg r8d
.dy_abs_ok:
    cmp edx, r8d
    jl .try_horizontal

    ; goal is mostly sideways, so try stepping vertically around
    ; whatever's in the way. Which side to try FIRST is "sticky": prefer
    ; whichever side (up/negative or down/positive) actually worked last
    ; time for this soldier -- see stage6b's README, bug #5, for the
    ; permanent 2-tick oscillation that always defaulting to "up" caused.
    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    mov edx, [rbp + US_SELF_Y]
    sub edx, MOVE_SPEED
    call is_spot_blocked
    mov [rbp + US_NEG_BLOCKED], eax          ; "up" blocked?

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    mov edx, [rbp + US_SELF_Y]
    add edx, MOVE_SPEED
    call is_spot_blocked
    mov [rbp + US_POS_BLOCKED], eax          ; "down" blocked?

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.avoid_dir]
    test eax, eax
    jnz .prefer_down

    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .fallback_down
    mov dword [r10 + Soldier.avoid_dir], 0      ; up worked again -- keep preferring it
    sub dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.fallback_down:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .update_next                               ; both blocked -- hold position
    mov dword [r10 + Soldier.avoid_dir], 1            ; up failed, down worked -- switch preference
    add dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.prefer_down:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .fallback_up
    mov dword [r10 + Soldier.avoid_dir], 1
    add dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.fallback_up:
    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .update_next
    mov dword [r10 + Soldier.avoid_dir], 0
    sub dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next

.try_horizontal:
    ; Left/right is NOT the same choice for both teams the way up/down
    ; is, so "first choice" here means FORWARD, toward the enemy's home
    ; complex (fwd_sign, set by choose_sides). See stage6c's README, bug #1 -- a
    ; plain "left first" gave the team on the right 39 of 48 games.
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.team]
    imul eax, [fwd_sign + rax*4], MOVE_SPEED   ; toward the enemy's home
    mov [rbp + US_FWD_STEP], eax

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    add esi, [rbp + US_FWD_STEP]
    mov edx, [rbp + US_SELF_Y]
    call is_spot_blocked
    mov [rbp + US_NEG_BLOCKED], eax          ; "forward" blocked?

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    sub esi, [rbp + US_FWD_STEP]
    mov edx, [rbp + US_SELF_Y]
    call is_spot_blocked
    mov [rbp + US_POS_BLOCKED], eax          ; "back" blocked?

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov ecx, [rbp + US_FWD_STEP]
    mov eax, [r10 + Soldier.avoid_dir]
    test eax, eax
    jnz .prefer_back

    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .fallback_back
    mov dword [r10 + Soldier.avoid_dir], 0
    add [r10 + Soldier.x], ecx
    jmp .update_next
.fallback_back:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .update_next
    mov dword [r10 + Soldier.avoid_dir], 1
    sub [r10 + Soldier.x], ecx
    jmp .update_next
.prefer_back:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .fallback_fwd
    mov dword [r10 + Soldier.avoid_dir], 1
    sub [r10 + Soldier.x], ecx
    jmp .update_next
.fallback_fwd:
    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .update_next
    mov dword [r10 + Soldier.avoid_dir], 0
    add [r10 + Soldier.x], ecx
    jmp .update_next

.update_next:
    mov eax, [rbp + US_I]
    inc eax
    mov [rbp + US_I], eax
    jmp .update_loop
.update_done:
    call process_respawns
    lea rsp, [rbp - 24]
    pop r14
    pop r13
    pop r12
    pop rbp
    ret


; int first_in_line(int shooter: edi, int target: esi) -> eax
;
; Who actually takes this shot: the first living soldier (not the
; shooter) whose box contains a point on the line from the shooter's
; centre to the target's centre. Bresenham again, as in draw_line and
; line_blocked, but it checks every soldier's box at each point
; instead of plotting or checking walls.
;
; The walk is in HALF-PIXEL units (every coordinate doubled). In whole
; pixels, a 16px box at x has no centre pixel: x+8 is 8 pixels in from
; the left edge but 7 from the right. Under the left-right mirror that
; puts every team 1 line of fire 1px off the mirror image of team 0's,
; while the boxes themselves mirror exactly. In 06, which asks this
; ~3,300 times a game to decide whether to hold fire, team 1 won 259 of
; 480 games with the 1px and 142-146 over 288 without it. Doubled, the
; centre is exactly 2x + 15 and a box exactly [2x, 2x + 30], and both
; mirror exactly. (Bresenham's steps depend only on |dx| and |dy|, so
; the walk itself was already mirror-symmetric.)
;
; No calls, so the walk state lives in registers:
;   ebx shooter    r12d target
;   r8d/r9d  current x,y    r10d/r11d end x,y
;   r13d/r14d sx,sy   r15d dx   edi dy (<= 0)   esi err
; Cost: up to ~500 half-pixel points x 100 boxes per check, a few
; thousand checks per game. Nothing at this scale.
first_in_line:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov ebx, edi
    mov r12d, esi

    mov eax, ebx
    imul eax, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    ; half-pixel units: a box's true centre is 2x + SIZE - 1 (see above)
    mov r8d, [rcx + Soldier.x]
    lea r8d, [r8d * 2 + SOLDIER_SIZE - 1]
    mov r9d, [rcx + Soldier.y]
    lea r9d, [r9d * 2 + SOLDIER_SIZE - 1]
    mov eax, r12d
    imul eax, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    mov r10d, [rcx + Soldier.x]
    lea r10d, [r10d * 2 + SOLDIER_SIZE - 1]
    mov r11d, [rcx + Soldier.y]
    lea r11d, [r11d * 2 + SOLDIER_SIZE - 1]

    ; dx = |x1-x0|, sx = sign; dy = -|y1-y0|, sy = sign; err = dx + dy
    mov r13d, 1
    mov r15d, r10d
    sub r15d, r8d
    jns .fil_dx_ok
    neg r15d
    mov r13d, -1
.fil_dx_ok:
    mov r14d, 1
    mov edi, r11d
    sub edi, r9d
    jns .fil_dy_ok
    neg edi
    mov r14d, -1
.fil_dy_ok:
    neg edi
    mov esi, r15d
    add esi, edi

.fil_step:
    xor ecx, ecx
    lea rdx, [soldiers]
.fil_scan:
    cmp ecx, TOTAL_SOLDIERS
    jge .fil_nobody
    cmp ecx, ebx
    je .fil_scan_next               ; the line starts inside the shooter
    cmp dword [rdx + Soldier.health], 0
    jle .fil_scan_next
    ; inside the box when 0 <= X - 2*box.x <= 2*SIZE - 2 (half-pixel
    ; units). Compared unsigned, a negative difference becomes huge, so
    ; one jae covers both ends
    mov eax, [rdx + Soldier.x]
    add eax, eax
    neg eax
    add eax, r8d
    cmp eax, 2 * SOLDIER_SIZE - 1
    jae .fil_scan_next
    mov eax, [rdx + Soldier.y]
    add eax, eax
    neg eax
    add eax, r9d
    cmp eax, 2 * SOLDIER_SIZE - 1
    jae .fil_scan_next
    mov eax, ecx                    ; this soldier is in the way
    jmp .fil_done
.fil_scan_next:
    inc ecx
    add rdx, Soldier_size
    jmp .fil_scan

.fil_nobody:
    cmp r8d, r10d
    jne .fil_advance
    cmp r9d, r11d
    jne .fil_advance
    mov eax, r12d                   ; reached the end (can't really miss
    jmp .fil_done                   ; the target's box, but just in case)
.fil_advance:
    lea eax, [esi + esi]            ; 2*err
    cmp eax, edi
    jl .fil_skip_x
    add esi, edi
    add r8d, r13d
.fil_skip_x:
    cmp eax, r15d
    jg .fil_skip_y
    add esi, r15d
    add r9d, r14d
.fil_skip_y:
    jmp .fil_step

.fil_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void print_result(char* msg: rsi, int len: edx)
;
; Writes "<msg> (friendly fire: H hits, K kills; held fire N times)\n"
; in ONE write().
; batch.sh stops a game as soon as its output file isn't empty, so
; with more than one write it could read half a line.
print_result:
    push rbx
    lea rdi, [msg_buf]
    call append_bytes
    lea rsi, [on_msg]
    mov edx, on_msg_len
    call append_bytes
    call append_arena_name
    lea rsi, [ff_msg1]
    mov edx, ff_msg1_len
    call append_bytes
    mov esi, [ff_hits]
    call append_uint
    lea rsi, [ff_msg2]
    mov edx, ff_msg2_len
    call append_bytes
    mov esi, [ff_kills]
    call append_uint
    lea rsi, [ff_msg3]
    mov edx, ff_msg3_len
    call append_bytes
    mov esi, [ff_held]
    call append_uint
    lea rsi, [ff_msg4]
    mov edx, ff_msg4_len
    call append_bytes
    mov esi, [ticks]
    call append_uint
    lea rsi, [ff_msg5]
    mov edx, ff_msg5_len
    call append_bytes
    lea rsi, [score_msg]
    mov edx, score_msg_len
    call append_bytes
    mov esi, [score]
    call append_uint
    mov byte [rdi], '-'
    inc rdi
    mov esi, [score + 4]
    call append_uint
    lea rsi, [boss_msg]
    mov edx, boss_msg_len
    call append_bytes
    mov esi, [boss_state]
    shr esi, 1                    ; 2 (out) -> 1, else 0
    call append_uint
    mov byte [rdi], '-'
    inc rdi
    mov esi, [boss_state + 4]
    shr esi, 1
    call append_uint
    cmp dword [boss_tick], 0
    je .pr_no_boss_tick
    lea rsi, [boss_tick_msg]
    mov edx, boss_tick_msg_len
    call append_bytes
    mov esi, [boss_tick]
    call append_uint
.pr_no_boss_tick:
    lea rsi, [ev_msg1]
    mov edx, ev_msg1_len
    call append_bytes
    mov esi, [arrests]
    call append_uint
    lea rsi, [ev_msg2]
    mov edx, ev_msg2_len
    call append_bytes
    mov esi, [cop_kills]
    call append_uint
    lea rsi, [ev_msg3]
    mov edx, ev_msg3_len
    call append_bytes
    mov esi, [dog_kills]
    call append_uint
    lea rsi, [home_msg]
    mov edx, home_msg_len
    call append_bytes
    mov eax, [home]
    lea rsi, [side_names + rax*4]
    mov edx, 4
    call append_bytes
    cmp dword [show_seed], 0
    je .pr_no_seed
    lea rsi, [seed_msg]
    mov edx, seed_msg_len
    call append_bytes
    mov rsi, [game_seed]
    call append_hex64
.pr_no_seed:
    lea rsi, [ff_msg6]
    mov edx, ff_msg6_len
    call append_bytes

    lea rsi, [msg_buf]
    mov rdx, rdi
    sub rdx, rsi                    ; length = end - start
    mov eax, 1                      ; write(stdout, msg_buf, len)
    mov edi, 1
    syscall
    pop rbx
    ret

; append_hex64(dst: rdi, n: rsi) -> rdi = past the digits
; "0x" and all 16 hex digits, most significant first: rotate the next
; nibble into the bottom 4 bits, then look it up.
append_hex64:
    mov word [rdi], '0x'
    add rdi, 2
    mov ecx, 16
.ah_loop:
    rol rsi, 4
    mov eax, esi
    and eax, 0xF
    lea rdx, [hex_digits]
    mov al, [rdx + rax]
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .ah_loop
    ret

; append_bytes(dst: rdi, src: rsi, len: edx) -> rdi = dst + len
append_bytes:
    mov ecx, edx
    cld
    rep movsb
    ret

; append_uint(dst: rdi, n: esi) -> rdi = past the last digit
;
; Divides by 10 repeatedly, which gives the digits last-first, so they
; are written backwards into scratch space below rsp and then copied
; forwards. It's a leaf function, so the 128 bytes below rsp (the
; System V "red zone") are ours to use without moving rsp. 10 digits
; is the most a 32-bit number needs.
append_uint:
    mov eax, esi
    lea r9, [rsp - 8]               ; one past the last digit
    mov r8, r9
    mov ecx, 10
.au_loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec r8
    mov [r8], dl
    test eax, eax
    jnz .au_loop
    mov rsi, r8
    mov rcx, r9
    sub rcx, r8
    rep movsb
    ret


; void spawn_effect(int weapon: edi, int shooter: esi, int target: edx,
;                   int hit: ecx)
;
; Records one attack in the effects ring buffer, overwriting the oldest
; slot. Everything is worked out here, once, so draw_effects only has
; to interpolate:
;   - both endpoints are box centres (x + SOLDIER_SIZE/2)
;   - (px, py) is perpendicular to the shot and about PELLET_SPREAD
;     long: (-dy, dx) * SPREAD / max(|dx|, |dy|). Dividing by the
;     larger axis instead of the true length skips the square root.
;     The result is 1x to 1.41x too long, depending on angle, which is
;     fine for a spread
;   - a miss moves the aim point MISS_OFFSET spreads sideways and 25%
;     further on, so the tracer visibly flies past. The side alternates
;     with the slot number. It's cosmetic, so it must not call rng_next
;     (that would change the game)
;   - a hit keeps the target drawn until its flash ends, in case this
;     attack killed it (death_linger)
spawn_effect:
    push rbx
    push r12
    push r13
    push r14

    mov r13d, esi               ; shooter
    mov r14d, ecx               ; hit

    mov eax, [fx_next]
    mov ebx, eax                ; slot number, for the miss side below
    lea ecx, [eax + 1]
    and ecx, MAX_EFFECTS - 1
    mov [fx_next], ecx
    imul eax, Effect_size
    lea r8, [effects]
    add r8, rax

    lea eax, [edi + 1]
    mov [r8 + Effect.type], eax
    mov dword [r8 + Effect.age], 0
    mov [r8 + Effect.target], edx
    mov [r8 + Effect.hit], r14d

    lea r9, [fx_src]            ; shooter -1: the police or the dog,
    cmp r13d, -1                ; at fx_src (laid out like Soldier.x/y)
    je .se_have_shooter
    mov eax, r13d
    imul eax, Soldier_size
    lea r9, [soldiers]
    add r9, rax
.se_have_shooter:
    mov eax, edx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    mov eax, [r9 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.x0], eax
    mov eax, [r9 + Soldier.y]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.y0], eax
    mov eax, [r10 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.x1], eax
    mov eax, [r10 + Soldier.y]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.y1], eax

    ; r11d = dx, r12d = dy
    mov r11d, [r8 + Effect.x1]
    sub r11d, [r8 + Effect.x0]
    mov r12d, [r8 + Effect.y1]
    sub r12d, [r8 + Effect.y0]

    ; ecx = max(|dx|, |dy|)  (neg, then cmovs puts back the original
    ; if negating made it negative, i.e. if it was positive)
    mov eax, r11d
    neg eax
    cmovs eax, r11d
    mov ecx, r12d
    neg ecx
    cmovs ecx, r12d
    cmp ecx, eax
    cmovl ecx, eax

    mov dword [r8 + Effect.px], 0
    mov dword [r8 + Effect.py], 0
    test ecx, ecx
    jz .se_perp_done            ; same centre -- no direction to be perpendicular to
    mov eax, r12d
    neg eax
    imul eax, PELLET_SPREAD
    cdq
    idiv ecx
    mov [r8 + Effect.px], eax
    mov eax, r11d
    imul eax, PELLET_SPREAD
    cdq
    idiv ecx
    mov [r8 + Effect.py], eax
.se_perp_done:

    test r14d, r14d
    jnz .se_hit
    cmp edi, WEAPON_KNIFE
    je .se_done                 ; a missed stab looks the same, minus the flash

    mov ecx, MISS_OFFSET
    test ebx, 1
    jz .se_side_ok
    neg ecx
.se_side_ok:
    mov eax, [r8 + Effect.px]
    imul eax, ecx
    add [r8 + Effect.x1], eax
    sar r11d, 2
    add [r8 + Effect.x1], r11d
    mov eax, [r8 + Effect.py]
    imul eax, ecx
    add [r8 + Effect.y1], eax
    sar r12d, 2
    add [r8 + Effect.y1], r12d
    jmp .se_done

.se_hit:
    ; linger through arrival + flash, +1 because the soldier loop
    ; counts down in the frame before draw_effects starts the flash
    mov ecx, BULLET_TRAVEL + FLASH_FRAMES + 1
    cmp edi, WEAPON_KNIFE
    jne .se_have_linger
    mov ecx, KNIFE_PEAK + FLASH_FRAMES + 1
.se_have_linger:
    mov eax, [r8 + Effect.target]   ; not edx: cdq/idiv above clobbered it
    lea r9, [death_linger]
    cmp [r9 + rax*4], ecx
    jge .se_done                ; an earlier shot already set a longer one
    mov [r9 + rax*4], ecx

.se_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_effects(void)
;
; Draws every live effect into the back buffer, then ages it one
; frame. It runs once per rendered frame, not per update tick, so
; effects still finish after game_over stops the updates.
;
; Every line is "tail to head" along the path from (X0,Y0) to
; (X1,Y1), with both ends given as fractions TN/DEN and HN/DEN:
;   tracer: head = (age+1)/TRAVEL, tail TRACER_TAIL behind -> it flies
;   knife:  head = f/PEAK, f going 0..PEAK..0, tail KNIFE_BLADE behind
;           -> the blade slides out and back
; .emit_line and .set_endpoints are small subroutines that share this
; function's rbp frame, since they need its locals. (A `call` to a
; local label is just a call. rbp doesn't move, so [rbp + DE_*] still
; points at the same slots.)
DE_KMIN  equ -32     ; pellet range: k = KMIN..KMAX, aim = (x1,y1) + k*(px,py)
DE_KMAX  equ -40
DE_X0    equ -48
DE_Y0    equ -56
DE_X1    equ -64
DE_Y1    equ -72
DE_TN    equ -80
DE_HN    equ -88
DE_DEN   equ -96
DE_COLOR equ -104
DE_SIZE  equ -112
DE_TX    equ -120
DE_TY    equ -128
DE_HX    equ -136

draw_effects:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8 + 112            ; keeps rsp 16-byte aligned for calls

    xor ebx, ebx
.de_loop:
    cmp ebx, MAX_EFFECTS
    jge .de_done
    mov eax, ebx
    imul eax, Effect_size
    lea r12, [effects]
    add r12, rax

    mov eax, [r12 + Effect.type]
    test eax, eax
    jz .de_next
    cmp eax, FX_KNIFE
    je .de_knife

    ; ---- pistol: one tracer. shotgun: three, k = -1, 0, +1 ----
    mov dword [rbp + DE_KMIN], 0
    mov dword [rbp + DE_KMAX], 0
    mov dword [rbp + DE_COLOR], COLOR_TRACER
    cmp eax, FX_SHOTGUN
    jne .de_have_k
    mov dword [rbp + DE_KMIN], -1
    mov dword [rbp + DE_KMAX], 1
    mov dword [rbp + DE_COLOR], COLOR_PELLET
.de_have_k:

    mov eax, [r12 + Effect.age]
    cmp eax, BULLET_TRAVEL
    jge .de_impact

    lea ecx, [eax + 1]
    mov [rbp + DE_HN], ecx
    sub ecx, TRACER_TAIL
    jns .de_tail_ok
    xor ecx, ecx                ; tail can't start behind the shooter
.de_tail_ok:
    mov [rbp + DE_TN], ecx
    mov dword [rbp + DE_DEN], BULLET_TRAVEL

    mov r13d, [rbp + DE_KMIN]
.de_tracer_loop:
    call .set_endpoints
    call .emit_line
    inc r13d
    cmp r13d, [rbp + DE_KMAX]
    jle .de_tracer_loop
    jmp .de_age

.de_impact:
    cmp dword [r12 + Effect.hit], 0
    je .de_age                  ; a miss just flies off: no spark

    cmp eax, BULLET_TRAVEL
    jne .de_no_flash
    call .start_flash           ; the frame the tracer arrives
.de_no_flash:
    mov dword [rbp + DE_SIZE], 5
    cmp dword [r12 + Effect.age], BULLET_TRAVEL + IMPACT_FRAMES / 2
    jl .de_have_size
    mov dword [rbp + DE_SIZE], 3        ; spark shrinks for its second half
.de_have_size:
    mov r13d, [rbp + DE_KMIN]
.de_spark_loop:
    call .set_endpoints
    lea rdi, [back_fb]
    mov eax, [rbp + DE_SIZE]
    shr eax, 1
    mov esi, [rbp + DE_X1]
    sub esi, eax
    mov edx, [rbp + DE_Y1]
    sub edx, eax
    mov ecx, [rbp + DE_SIZE]
    mov r8d, ecx
    mov r9d, COLOR_SPARK
    call fill_rect
    inc r13d
    cmp r13d, [rbp + DE_KMAX]
    jle .de_spark_loop
    jmp .de_age

    ; ---- knife: f = age up to PEAK, then back down ----
.de_knife:
    mov eax, [r12 + Effect.age]
    cmp eax, KNIFE_PEAK
    jle .de_have_f
    mov ecx, KNIFE_LIFE
    sub ecx, eax
    mov eax, ecx
.de_have_f:
    mov [rbp + DE_HN], eax
    sub eax, KNIFE_BLADE
    jns .de_blade_ok
    xor eax, eax
.de_blade_ok:
    mov [rbp + DE_TN], eax
    mov dword [rbp + DE_DEN], KNIFE_PEAK
    mov dword [rbp + DE_COLOR], COLOR_BLADE

    xor r13d, r13d
    call .set_endpoints
    call .emit_line

    ; draw it again 1px over to make it 2px thick: step across the
    ; blade, so y for a mostly-horizontal stab, x for a mostly-vertical one
    mov eax, [rbp + DE_X1]
    sub eax, [rbp + DE_X0]
    mov ecx, eax
    neg ecx
    cmovs ecx, eax              ; ecx = |dx|
    mov eax, [rbp + DE_Y1]
    sub eax, [rbp + DE_Y0]
    mov edx, eax
    neg edx
    cmovs edx, eax              ; edx = |dy|
    cmp ecx, edx
    jl .de_thick_x
    inc dword [rbp + DE_Y0]
    inc dword [rbp + DE_Y1]
    jmp .de_thick_draw
.de_thick_x:
    inc dword [rbp + DE_X0]
    inc dword [rbp + DE_X1]
.de_thick_draw:
    call .emit_line

    cmp dword [r12 + Effect.age], KNIFE_PEAK
    jne .de_age
    cmp dword [r12 + Effect.hit], 0
    je .de_age
    call .start_flash           ; the frame the blade reaches its target

.de_age:
    mov eax, [r12 + Effect.age]
    inc eax
    mov [r12 + Effect.age], eax
    mov ecx, BULLET_LIFE
    cmp dword [r12 + Effect.type], FX_KNIFE
    jne .de_have_life
    mov ecx, KNIFE_LIFE
.de_have_life:
    cmp eax, ecx
    jl .de_next
    mov dword [r12 + Effect.type], 0    ; done -- free the slot

.de_next:
    inc ebx
    jmp .de_loop

.de_done:
    add rsp, 8 + 112
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---- local subroutines, sharing draw_effects' frame ----

; X0,Y0 = attacker centre; X1,Y1 = aim point + k*(px,py), k in r13d
.set_endpoints:
    mov eax, [r12 + Effect.x0]
    mov [rbp + DE_X0], eax
    mov eax, [r12 + Effect.y0]
    mov [rbp + DE_Y0], eax
    mov eax, [r12 + Effect.px]
    imul eax, r13d
    add eax, [r12 + Effect.x1]
    mov [rbp + DE_X1], eax
    mov eax, [r12 + Effect.py]
    imul eax, r13d
    add eax, [r12 + Effect.y1]
    mov [rbp + DE_Y1], eax
    ret

.start_flash:
    mov eax, [r12 + Effect.target]
    lea rcx, [hit_flash]
    mov dword [rcx + rax*4], FLASH_FRAMES
    ret

; line from TN/DEN to HN/DEN of the way along (X0,Y0)->(X1,Y1)
.emit_line:
    sub rsp, 8                  ; the call here pushed 8; realign
    mov edi, [rbp + DE_X0]
    mov esi, [rbp + DE_X1]
    mov edx, [rbp + DE_TN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov [rbp + DE_TX], eax
    mov edi, [rbp + DE_Y0]
    mov esi, [rbp + DE_Y1]
    mov edx, [rbp + DE_TN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov [rbp + DE_TY], eax
    mov edi, [rbp + DE_X0]
    mov esi, [rbp + DE_X1]
    mov edx, [rbp + DE_HN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov [rbp + DE_HX], eax
    mov edi, [rbp + DE_Y0]
    mov esi, [rbp + DE_Y1]
    mov edx, [rbp + DE_HN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov r8d, eax                ; head y
    mov ecx, [rbp + DE_HX]
    mov edx, [rbp + DE_TY]
    mov esi, [rbp + DE_TX]
    lea rdi, [back_fb]
    mov r9d, [rbp + DE_COLOR]
    call draw_line
    add rsp, 8
    ret


; int lerp(int a: edi, int b: esi, int n: edx, int d: ecx)
;   -> eax = a + (b - a) * n / d   (signed, truncating)
lerp:
    mov eax, esi
    sub eax, edi
    imul eax, edx
    cdq
    idiv ecx
    add eax, edi
    ret


; int check_win(void) -> eax: 0 = still going, 1 = team 0 won,
; 2 = team 1 won.
; A team that reached the score limit wins. Otherwise a team is out
; when nobody on it is alive AND nobody is waiting to respawn.
check_win:
    mov eax, [score_winner]
    test eax, eax
    jnz .cw_ret
    push rbx
    push r12
    xor ebx, ebx                  ; team 0 in play
    xor r12d, r12d                ; team 1 in play
    lea r10, [soldiers]
    lea r11, [respawn_timer]
    xor ecx, ecx
.cw_loop:
    cmp dword [r10 + Soldier.health], 0
    jg .cw_in_play
    cmp dword [r11 + rcx*4], 0
    jle .cw_next
.cw_in_play:
    cmp dword [r10 + Soldier.team], 0
    jne .cw_team1
    inc ebx
    jmp .cw_next
.cw_team1:
    inc r12d
.cw_next:
    add r10, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .cw_loop
    xor eax, eax
    test ebx, ebx
    jnz .check_t1
    mov eax, 2
    jmp .cw_return
.check_t1:
    test r12d, r12d
    jnz .cw_return
    mov eax, 1
.cw_return:
    pop r12
    pop rbx
.cw_ret:
    ret


; void set_pixel(FrameBuffer* fb: rdi, int x: esi, int y: edx, u32 color: ecx)
set_pixel:
    cmp esi, 0
    jl .done
    cmp esi, [rdi + FrameBuffer.w]
    jge .done
    cmp edx, 0
    jl .done
    cmp edx, [rdi + FrameBuffer.h]
    jge .done
    mov eax, edx
    imul eax, [rdi + FrameBuffer.pitch]
    lea eax, [eax + esi*4]
    mov r10, [rdi + FrameBuffer.pixels]
    mov dword [r10 + rax], ecx
.done:
    ret


; void fill_rect(FrameBuffer* fb: rdi, int x: esi, int y: edx,
;                int w: ecx, int h: r8d, u32 color: r9d)
fill_rect:
    push rbx
    push r12
    push r13
    push r14

    mov r10, [rdi + FrameBuffer.pixels]
    mov r11d, [rdi + FrameBuffer.pitch]
    mov ebx, [rdi + FrameBuffer.w]
    mov r12d, [rdi + FrameBuffer.h]

    mov r13d, esi
    add r13d, ecx
    cmp r13d, ebx
    jle .x_end_ok
    mov r13d, ebx
.x_end_ok:

    mov r14d, edx
    add r14d, r8d
    cmp r14d, r12d
    jle .y_end_ok
    mov r14d, r12d
.y_end_ok:

    ; clip the left and top edges too (the ends are already computed
    ; from the unclipped start, above). Without this a negative x
    ; writes into the previous row, and a negative y writes before the
    ; start of the buffer
    test esi, esi
    jns .x_start_ok
    xor esi, esi
.x_start_ok:
    test edx, edx
    jns .y_start_ok
    xor edx, edx
.y_start_ok:

.row_loop:
    cmp edx, r14d
    jge .done
    mov eax, edx
    imul eax, r11d
    mov ecx, esi
.col_loop:
    cmp ecx, r13d
    jge .row_done
    lea r8d, [eax + ecx*4]
    mov dword [r10 + r8], r9d
    inc ecx
    jmp .col_loop
.row_done:
    inc edx
    jmp .row_loop
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_line(FrameBuffer* fb: rdi, int x0: esi, int y0: edx,
;                int x1: ecx, int y1: r8d, u32 color: r9d)
;
; Bresenham's line algorithm, integer-only. Copied unchanged from
; stage3/03_line_and_scene.asm. Named stack locals
; (rbp-relative) instead of registers, since this function's own
; loop calls set_pixel repeatedly and memory survives a `call`
; without needing callee-saved juggling for ~9 live values.
L_FB    equ -8
L_X0    equ -16
L_Y0    equ -24
L_X1    equ -32
L_Y1    equ -40
L_SX    equ -48
L_SY    equ -56
L_DX    equ -64
L_DY    equ -72
L_ERR   equ -80
L_COLOR equ -88

draw_line:
    push rbp
    mov rbp, rsp
    sub rsp, 96

    mov [rbp + L_FB], rdi
    mov [rbp + L_X0], esi
    mov [rbp + L_Y0], edx
    mov [rbp + L_X1], ecx
    mov [rbp + L_Y1], r8d
    mov [rbp + L_COLOR], r9d

    ; dx = abs(x1 - x0)
    mov eax, [rbp + L_X1]
    sub eax, [rbp + L_X0]
    jns .dx_nonneg
    neg eax
.dx_nonneg:
    mov [rbp + L_DX], eax

    ; sx = (x0 < x1) ? 1 : -1
    mov eax, [rbp + L_X0]
    cmp eax, [rbp + L_X1]
    mov eax, 1
    jl .sx_done
    mov eax, -1
.sx_done:
    mov [rbp + L_SX], eax

    ; dy = -abs(y1 - y0)
    mov eax, [rbp + L_Y1]
    sub eax, [rbp + L_Y0]
    jns .dy_nonneg
    neg eax
.dy_nonneg:
    neg eax
    mov [rbp + L_DY], eax

    ; sy = (y0 < y1) ? 1 : -1
    mov eax, [rbp + L_Y0]
    cmp eax, [rbp + L_Y1]
    mov eax, 1
    jl .sy_done
    mov eax, -1
.sy_done:
    mov [rbp + L_SY], eax

    ; err = dx + dy
    mov eax, [rbp + L_DX]
    add eax, [rbp + L_DY]
    mov [rbp + L_ERR], eax

.plot_loop:
    mov rdi, [rbp + L_FB]
    mov esi, [rbp + L_X0]
    mov edx, [rbp + L_Y0]
    mov ecx, [rbp + L_COLOR]
    call set_pixel

    mov eax, [rbp + L_X0]
    cmp eax, [rbp + L_X1]
    jne .continue_loop
    mov eax, [rbp + L_Y0]
    cmp eax, [rbp + L_Y1]
    je .plot_done
.continue_loop:
    mov eax, [rbp + L_ERR]
    add eax, eax                    ; eax = 2*err

    cmp eax, [rbp + L_DY]
    jl .skip_x
    mov ecx, [rbp + L_ERR]
    add ecx, [rbp + L_DY]
    mov [rbp + L_ERR], ecx
    mov ecx, [rbp + L_X0]
    add ecx, [rbp + L_SX]
    mov [rbp + L_X0], ecx
.skip_x:
    cmp eax, [rbp + L_DX]
    jg .skip_y
    mov ecx, [rbp + L_ERR]
    add ecx, [rbp + L_DX]
    mov [rbp + L_ERR], ecx
    mov ecx, [rbp + L_Y0]
    add ecx, [rbp + L_SY]
    mov [rbp + L_Y0], ecx
.skip_y:
    jmp .plot_loop

.plot_done:
    mov rsp, rbp
    pop rbp
    ret

; ------------------------------------------------------------
; Build and run:
;   make
;   ./build/01_sprites
;   HEADLESS=1 SEED=0x1234 ./build/01_sprites
;   STAGGER=0 ./batch.sh 48                   # headless, 4 at a time
; To change the art: edit tools/gen_sprites.py, then
;   python3 tools/gen_sprites.py --write 01_sprites.asm
;
; Questions to answer by experimenting:
;   - Draw a sixth pose for SW instead of mirroring SE. Where does the
;     mirror give it away (which hand holds the gun)?
;   - Soldiers that stand still keep their last facing. Make them face
;     their target instead: what does draw_soldier need to know that
;     only update_soldiers knows today?
;   - TELEPORT is 8. What goes wrong at 1? At 100?
; ------------------------------------------------------------
