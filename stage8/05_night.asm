; ============================================================
; Stage 8.05 — Day and night
;
; 04_ground.asm, with the time of day. A whole day passes in
; DAY_TICKS (4 minutes), so a one-minute game covers about six hours:
; some start in sunshine and end in the dark, some go from night into
; dawn. The scoreboard shows the time (9:40 PM).
;
;   - daylight is untouched; dusk turns orange; night is dark blue;
;     dawn warms back up (ambient keyframes, interpolated)
;   - at night the light comes from the 21 streetlights, the gangs'
;     lit lobbies (spilling out of their doors), the police car's
;     headlights and light bar, and muzzle flashes
;   - tracers and sparks are drawn after the lighting, so gunfire is
;     bright in the dark
;
; How: each frame, a light map at half resolution (LM_W x LM_H) starts
; at 0, and every light adds a round falloff kernel (saturating at
; 255). Then every field pixel is scaled per channel through three
; 256-entry tables, rebuilt from the time of day: level 0 is the
; ambient colour, 255 the warm lamp colour. At full daylight the pass
; is skipped.
;
; The starting time comes from the game's seed (or TIME=h, 0-23), not
; from the game's RNG, and all of this is drawing: byte-identical to
; 8.04, and headless runs never do any of it.
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
DEATH_LIE  equ 36             ; frames a fallen soldier lies there
; ---- day and night (see header) ----
DAY_TICKS  equ 14400          ; 24 hours; must be a multiple of 1440
MIN_TICKS  equ DAY_TICKS / 1440   ; ticks per minute of the day
LM_SCALE   equ 2              ; light map: one cell per 2x2 pixels
LM_W       equ SCREEN_W / LM_SCALE
LM_H       equ SCREEN_H / LM_SCALE
LAMP_R     equ 36             ; kernel radii, in light-map cells
MID_R      equ 22
SMALL_R    equ 14
LIT_R      equ 256            ; the colour of lamplight (x/256 a channel)
LIT_G      equ 236
LIT_B      equ 186
LOBBY_LIGHT equ 150           ; a lit lobby, 0..255
COLOR_BRASS      equ 0xFF3CAADC
COLOR_BRASS_DARK equ 0xFF1E6E96
COLOR_SHELL      equ 0xFF2828B4
SPR_MIRROR equ 1              ; draw_sprite_ex flags: flip left-right,
SPR_FLIP   equ 2              ; flip upside down
COP_W      equ 40             ; the police car sprite, long way
COP_H      equ 20
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
    title_prefix db "Stage 8.05 - "
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
    ; the look, layer 1: ground (x, y, w, h, colour), drawn in order
    bg_ground:
        dd 0, 0, 1280, 720, 0xFF4E8C60
        dd 1237, 594, 2, 1, 0xFF5A9C70
        dd 390, 713, 1, 1, 0xFF3C7346
        dd 1271, 135, 2, 1, 0xFF3C7346
        dd 575, 578, 2, 1, 0xFF3C7346
        dd 372, 255, 1, 1, 0xFF3C7346
        dd 769, 191, 1, 1, 0xFF5A9C70
        dd 668, 656, 2, 1, 0xFF3C7346
        dd 1136, 438, 2, 1, 0xFF5A9C70
        dd 1275, 82, 1, 1, 0xFF3C7346
        dd 228, 4, 1, 1, 0xFF3C7346
        dd 742, 415, 2, 1, 0xFF5A9C70
        dd 664, 182, 1, 1, 0xFF3C7346
        dd 996, 704, 2, 1, 0xFF3C7346
        dd 1096, 703, 2, 1, 0xFF5A9C70
        dd 984, 597, 1, 1, 0xFF5A9C70
        dd 845, 0, 2, 1, 0xFF5A9C70
        dd 964, 202, 2, 1, 0xFF5A9C70
        dd 553, 401, 2, 1, 0xFF5A9C70
        dd 539, 30, 2, 1, 0xFF5A9C70
        dd 80, 172, 2, 1, 0xFF3C7346
        dd 1230, 706, 2, 1, 0xFF5A9C70
        dd 971, 532, 1, 1, 0xFF5A9C70
        dd 706, 657, 1, 1, 0xFF5A9C70
        dd 861, 0, 1, 1, 0xFF5A9C70
        dd 703, 442, 2, 1, 0xFF5A9C70
        dd 979, 668, 1, 1, 0xFF3C7346
        dd 12, 666, 1, 1, 0xFF5A9C70
        dd 1276, 456, 2, 1, 0xFF5A9C70
        dd 287, 310, 1, 1, 0xFF5A9C70
        dd 166, 718, 2, 1, 0xFF3C7346
        dd 227, 15, 1, 1, 0xFF5A9C70
        dd 604, 79, 1, 1, 0xFF3C7346
        dd 1117, 611, 1, 1, 0xFF5A9C70
        dd 543, 424, 1, 1, 0xFF3C7346
        dd 759, 22, 1, 1, 0xFF3C7346
        dd 1245, 667, 2, 1, 0xFF3C7346
        dd 11, 297, 1, 1, 0xFF3C7346
        dd 752, 579, 1, 1, 0xFF3C7346
        dd 39, 175, 2, 1, 0xFF3C7346
        dd 628, 7, 2, 1, 0xFF3C7346
        dd 1134, 702, 2, 1, 0xFF3C7346
        dd 1247, 97, 2, 1, 0xFF3C7346
        dd 364, 53, 2, 1, 0xFF3C7346
        dd 15, 561, 1, 1, 0xFF3C7346
        dd 793, 21, 1, 1, 0xFF3C7346
        dd 477, 18, 1, 1, 0xFF5A9C70
        dd 1240, 633, 2, 1, 0xFF5A9C70
        dd 440, 30, 2, 1, 0xFF5A9C70
        dd 692, 478, 2, 1, 0xFF5A9C70
        dd 591, 8, 1, 1, 0xFF3C7346
        dd 1258, 491, 1, 1, 0xFF3C7346
        dd 389, 39, 1, 1, 0xFF3C7346
        dd 1278, 661, 1, 1, 0xFF3C7346
        dd 270, 402, 2, 1, 0xFF5A9C70
        dd 366, 521, 1, 1, 0xFF3C7346
        dd 699, 515, 2, 1, 0xFF5A9C70
        dd 597, 571, 2, 1, 0xFF5A9C70
        dd 11, 488, 2, 1, 0xFF3C7346
        dd 700, 153, 1, 1, 0xFF3C7346
        dd 980, 470, 1, 1, 0xFF3C7346
        dd 369, 239, 1, 1, 0xFF3C7346
        dd 469, 195, 2, 1, 0xFF3C7346
        dd 988, 306, 2, 1, 0xFF5A9C70
        dd 824, 409, 1, 1, 0xFF5A9C70
        dd 33, 96, 2, 1, 0xFF3C7346
        dd 870, 20, 2, 1, 0xFF3C7346
        dd 707, 168, 1, 1, 0xFF5A9C70
        dd 1193, 400, 1, 1, 0xFF3C7346
        dd 697, 652, 1, 1, 0xFF5A9C70
        dd 273, 195, 2, 1, 0xFF5A9C70
        dd 855, 20, 1, 1, 0xFF3C7346
        dd 393, 282, 1, 1, 0xFF3C7346
        dd 1274, 528, 2, 1, 0xFF5A9C70
        dd 823, 161, 2, 1, 0xFF3C7346
        dd 761, 674, 1, 1, 0xFF5A9C70
        dd 680, 149, 1, 1, 0xFF3C7346
        dd 19, 151, 2, 1, 0xFF3C7346
        dd 982, 555, 2, 1, 0xFF3C7346
        dd 819, 660, 1, 1, 0xFF3C7346
        dd 699, 581, 1, 1, 0xFF3C7346
        dd 384, 153, 1, 1, 0xFF3C7346
        dd 23, 275, 2, 1, 0xFF3C7346
        dd 838, 659, 1, 1, 0xFF3C7346
        dd 642, 521, 1, 1, 0xFF3C7346
        dd 491, 15, 1, 1, 0xFF3C7346
        dd 367, 219, 2, 1, 0xFF3C7346
        dd 1201, 16, 2, 1, 0xFF3C7346
        dd 1023, 425, 1, 1, 0xFF5A9C70
        dd 289, 529, 1, 1, 0xFF3C7346
        dd 382, 244, 2, 1, 0xFF3C7346
        dd 564, 556, 1, 1, 0xFF5A9C70
        dd 1120, 455, 1, 1, 0xFF3C7346
        dd 1210, 681, 1, 1, 0xFF5A9C70
        dd 1263, 595, 2, 1, 0xFF5A9C70
        dd 640, 135, 1, 1, 0xFF3C7346
        dd 159, 196, 1, 1, 0xFF5A9C70
        dd 1043, 25, 1, 1, 0xFF5A9C70
        dd 648, 719, 2, 1, 0xFF3C7346
        dd 506, 11, 1, 1, 0xFF3C7346
        dd 995, 21, 1, 1, 0xFF5A9C70
        dd 740, 574, 1, 1, 0xFF5A9C70
        dd 176, 155, 2, 1, 0xFF3C7346
        dd 1268, 95, 1, 1, 0xFF5A9C70
        dd 872, 408, 2, 1, 0xFF3C7346
        dd 167, 164, 2, 1, 0xFF5A9C70
        dd 803, 710, 2, 1, 0xFF5A9C70
        dd 22, 713, 1, 1, 0xFF5A9C70
        dd 25, 421, 1, 1, 0xFF3C7346
        dd 23, 296, 1, 1, 0xFF3C7346
        dd 853, 196, 1, 1, 0xFF5A9C70
        dd 680, 474, 1, 1, 0xFF3C7346
        dd 106, 700, 2, 1, 0xFF3C7346
        dd 689, 495, 2, 1, 0xFF5A9C70
        dd 265, 298, 1, 1, 0xFF3C7346
        dd 1138, 618, 1, 1, 0xFF3C7346
        dd 43, 707, 1, 1, 0xFF5A9C70
        dd 485, 26, 2, 1, 0xFF3C7346
        dd 6, 657, 1, 1, 0xFF3C7346
        dd 637, 414, 2, 1, 0xFF3C7346
        dd 518, 12, 2, 1, 0xFF5A9C70
        dd 988, 482, 1, 1, 0xFF5A9C70
        dd 419, 6, 1, 1, 0xFF3C7346
        dd 1199, 608, 1, 1, 0xFF3C7346
        dd 539, 582, 2, 1, 0xFF3C7346
        dd 1022, 705, 1, 1, 0xFF5A9C70
        dd 1261, 564, 1, 1, 0xFF3C7346
        dd 288, 105, 2, 1, 0xFF5A9C70
        dd 581, 29, 1, 1, 0xFF5A9C70
        dd 884, 226, 2, 1, 0xFF3C7346
        dd 887, 84, 1, 1, 0xFF5A9C70
        dd 657, 187, 1, 1, 0xFF5A9C70
        dd 964, 81, 2, 1, 0xFF3C7346
        dd 157, 310, 2, 1, 0xFF3C7346
        dd 427, 577, 1, 1, 0xFF5A9C70
        dd 37, 717, 2, 1, 0xFF3C7346
        dd 141, 192, 1, 1, 0xFF5A9C70
        dd 261, 47, 2, 1, 0xFF3C7346
        dd 1125, 521, 2, 1, 0xFF3C7346
        dd 1200, 628, 2, 1, 0xFF3C7346
        dd 549, 182, 1, 1, 0xFF5A9C70
        dd 241, 39, 2, 1, 0xFF3C7346
        dd 1267, 430, 1, 1, 0xFF3C7346
        dd 641, 416, 1, 1, 0xFF5A9C70
        dd 641, 548, 1, 1, 0xFF3C7346
        dd 1085, 566, 2, 1, 0xFF5A9C70
        dd 1018, 543, 1, 1, 0xFF5A9C70
        dd 148, 27, 2, 1, 0xFF5A9C70
        dd 569, 576, 2, 1, 0xFF3C7346
        dd 769, 665, 1, 1, 0xFF3C7346
        dd 886, 694, 2, 1, 0xFF3C7346
        dd 388, 14, 2, 1, 0xFF3C7346
        dd 757, 570, 2, 1, 0xFF5A9C70
        dd 421, 574, 2, 1, 0xFF3C7346
        dd 1023, 578, 1, 1, 0xFF5A9C70
        dd 1274, 33, 1, 1, 0xFF3C7346
        dd 5, 284, 1, 1, 0xFF3C7346
        dd 283, 594, 2, 1, 0xFF5A9C70
        dd 1256, 211, 1, 1, 0xFF5A9C70
        dd 1258, 313, 2, 1, 0xFF3C7346
        dd 240, 15, 2, 1, 0xFF3C7346
        dd 1275, 183, 2, 1, 0xFF3C7346
        dd 983, 550, 1, 1, 0xFF3C7346
        dd 24, 484, 1, 1, 0xFF3C7346
        dd 798, 316, 1, 1, 0xFF3C7346
        dd 33, 277, 2, 1, 0xFF3C7346
        dd 140, 269, 2, 1, 0xFF5A9C70
        dd 1217, 680, 2, 1, 0xFF5A9C70
        dd 1063, 559, 1, 1, 0xFF5A9C70
        dd 11, 474, 1, 1, 0xFF5A9C70
        dd 7, 180, 2, 1, 0xFF5A9C70
        dd 833, 319, 1, 1, 0xFF5A9C70
        dd 1105, 701, 1, 1, 0xFF3C7346
        dd 965, 470, 2, 1, 0xFF3C7346
        dd 693, 527, 2, 1, 0xFF5A9C70
        dd 1212, 643, 1, 1, 0xFF5A9C70
        dd 175, 174, 2, 1, 0xFF5A9C70
        dd 126, 306, 1, 1, 0xFF5A9C70
        dd 18, 266, 1, 1, 0xFF3C7346
        dd 1257, 487, 1, 1, 0xFF3C7346
        dd 271, 194, 1, 1, 0xFF3C7346
        dd 285, 90, 2, 1, 0xFF3C7346
        dd 76, 403, 1, 1, 0xFF3C7346
        dd 838, 655, 1, 1, 0xFF3C7346
        dd 790, 146, 2, 1, 0xFF3C7346
        dd 60, 701, 1, 1, 0xFF3C7346
        dd 795, 412, 1, 1, 0xFF3C7346
        dd 438, 5, 2, 1, 0xFF3C7346
        dd 1128, 559, 2, 1, 0xFF3C7346
        dd 1259, 557, 2, 1, 0xFF3C7346
        dd 415, 13, 2, 1, 0xFF3C7346
        dd 1236, 710, 1, 1, 0xFF3C7346
        dd 754, 668, 1, 1, 0xFF5A9C70
        dd 982, 648, 1, 1, 0xFF3C7346
        dd 104, 154, 2, 1, 0xFF3C7346
        dd 1271, 677, 2, 1, 0xFF5A9C70
        dd 845, 585, 2, 1, 0xFF3C7346
        dd 1242, 283, 1, 1, 0xFF5A9C70
        dd 810, 165, 2, 1, 0xFF3C7346
        dd 1143, 675, 2, 1, 0xFF3C7346
        dd 467, 19, 1, 1, 0xFF5A9C70
        dd 435, 586, 1, 1, 0xFF3C7346
        dd 1210, 712, 2, 1, 0xFF3C7346
        dd 642, 136, 1, 1, 0xFF5A9C70
        dd 11, 709, 1, 1, 0xFF5A9C70
        dd 101, 306, 2, 1, 0xFF3C7346
        dd 36, 282, 1, 1, 0xFF3C7346
        dd 287, 71, 2, 1, 0xFF3C7346
        dd 853, 578, 1, 1, 0xFF5A9C70
        dd 212, 151, 1, 1, 0xFF3C7346
        dd 38, 14, 1, 1, 0xFF3C7346
        dd 1177, 27, 2, 1, 0xFF3C7346
        dd 414, 196, 2, 1, 0xFF5A9C70
        dd 369, 271, 1, 1, 0xFF5A9C70
        dd 463, 24, 2, 1, 0xFF3C7346
        dd 254, 157, 2, 1, 0xFF3C7346
        dd 378, 68, 1, 1, 0xFF5A9C70
        dd 1060, 701, 1, 1, 0xFF3C7346
        dd 1263, 80, 2, 1, 0xFF5A9C70
        dd 882, 544, 1, 1, 0xFF3C7346
        dd 218, 57, 2, 1, 0xFF3C7346
        dd 557, 5, 2, 1, 0xFF3C7346
        dd 1081, 570, 2, 1, 0xFF5A9C70
        dd 881, 539, 1, 1, 0xFF3C7346
        dd 1063, 581, 2, 1, 0xFF3C7346
        dd 1113, 563, 2, 1, 0xFF5A9C70
        dd 25, 495, 1, 1, 0xFF3C7346
        dd 1129, 435, 1, 1, 0xFF3C7346
        dd 368, 678, 2, 1, 0xFF5A9C70
        dd 395, 715, 2, 1, 0xFF5A9C70
        dd 5, 209, 2, 1, 0xFF3C7346
        dd 773, 651, 1, 1, 0xFF5A9C70
        dd 247, 409, 2, 1, 0xFF5A9C70
        dd 616, 715, 1, 1, 0xFF5A9C70
        dd 576, 3, 2, 1, 0xFF3C7346
        dd 1008, 711, 2, 1, 0xFF5A9C70
        dd 1226, 632, 2, 1, 0xFF5A9C70
        dd 497, 703, 2, 1, 0xFF3C7346
        dd 853, 152, 1, 1, 0xFF3C7346
        dd 1127, 508, 2, 1, 0xFF5A9C70
        dd 665, 518, 2, 1, 0xFF5A9C70
        dd 282, 716, 2, 1, 0xFF3C7346
        dd 879, 314, 2, 1, 0xFF3C7346
        dd 1241, 701, 2, 1, 0xFF3C7346
        dd 26, 201, 2, 1, 0xFF3C7346
        dd 991, 574, 1, 1, 0xFF5A9C70
        dd 7, 67, 1, 1, 0xFF3C7346
        dd 386, 235, 1, 1, 0xFF3C7346
        dd 1112, 474, 1, 1, 0xFF5A9C70
        dd 495, 573, 2, 1, 0xFF3C7346
        dd 378, 445, 1, 1, 0xFF3C7346
        dd 981, 640, 1, 1, 0xFF5A9C70
        dd 185, 163, 1, 1, 0xFF5A9C70
        dd 18, 207, 2, 1, 0xFF5A9C70
        dd 670, 584, 1, 1, 0xFF3C7346
        dd 1055, 422, 1, 1, 0xFF3C7346
        dd 4, 176, 1, 1, 0xFF3C7346
        dd 15, 622, 2, 1, 0xFF3C7346
        dd 374, 565, 1, 1, 0xFF5A9C70
        dd 33, 272, 1, 1, 0xFF3C7346
        dd 967, 168, 2, 1, 0xFF3C7346
        dd 186, 408, 1, 1, 0xFF3C7346
        dd 30, 258, 1, 1, 0xFF3C7346
        dd 677, 27, 1, 1, 0xFF3C7346
        dd 48, 716, 1, 1, 0xFF3C7346
        dd 717, 536, 2, 1, 0xFF3C7346
        dd 384, 128, 2, 1, 0xFF3C7346
        dd 363, 208, 1, 1, 0xFF3C7346
        dd 410, 664, 1, 1, 0xFF5A9C70
        dd 55, 315, 1, 1, 0xFF3C7346
        dd 642, 170, 1, 1, 0xFF3C7346
        dd 538, 549, 2, 1, 0xFF3C7346
        dd 165, 168, 1, 1, 0xFF3C7346
        dd 532, 31, 2, 1, 0xFF3C7346
        dd 478, 406, 1, 1, 0xFF3C7346
        dd 31, 195, 1, 1, 0xFF5A9C70
        dd 611, 53, 2, 1, 0xFF5A9C70
        dd 797, 185, 2, 1, 0xFF5A9C70
        dd 1010, 429, 1, 1, 0xFF5A9C70
        dd 1178, 676, 2, 1, 0xFF3C7346
        dd 244, 45, 1, 1, 0xFF3C7346
        dd 500, 579, 1, 1, 0xFF3C7346
        dd 275, 711, 1, 1, 0xFF3C7346
        dd 365, 494, 1, 1, 0xFF5A9C70
        dd 1240, 200, 2, 1, 0xFF3C7346
        dd 1211, 309, 1, 1, 0xFF5A9C70
        dd 38, 92, 2, 1, 0xFF5A9C70
        dd 399, 31, 2, 1, 0xFF5A9C70
        dd 622, 529, 1, 1, 0xFF5A9C70
        dd 1271, 558, 1, 1, 0xFF3C7346
        dd 705, 559, 2, 1, 0xFF5A9C70
        dd 20, 613, 1, 1, 0xFF3C7346
        dd 365, 564, 2, 1, 0xFF3C7346
        dd 1104, 707, 1, 1, 0xFF3C7346
        dd 807, 409, 2, 1, 0xFF3C7346
        dd 889, 680, 2, 1, 0xFF3C7346
        dd 269, 31, 2, 1, 0xFF3C7346
        dd 43, 29, 2, 1, 0xFF3C7346
        dd 1075, 584, 2, 1, 0xFF5A9C70
        dd 566, 27, 1, 1, 0xFF5A9C70
        dd 1245, 314, 1, 1, 0xFF5A9C70
        dd 185, 14, 1, 1, 0xFF3C7346
        dd 677, 186, 1, 1, 0xFF3C7346
        dd 1053, 13, 2, 1, 0xFF5A9C70
        dd 233, 24, 2, 1, 0xFF5A9C70
        dd 968, 155, 1, 1, 0xFF5A9C70
        dd 1252, 239, 1, 1, 0xFF3C7346
        dd 139, 256, 2, 1, 0xFF3C7346
        dd 70, 713, 1, 1, 0xFF5A9C70
        dd 154, 17, 1, 1, 0xFF5A9C70
        dd 1028, 555, 1, 1, 0xFF5A9C70
        dd 1027, 425, 2, 1, 0xFF5A9C70
        dd 32, 76, 1, 1, 0xFF3C7346
        dd 689, 173, 2, 1, 0xFF3C7346
        dd 1053, 29, 1, 1, 0xFF3C7346
        dd 1248, 615, 2, 1, 0xFF3C7346
        dd 607, 717, 1, 1, 0xFF3C7346
        dd 715, 163, 2, 1, 0xFF3C7346
        dd 614, 43, 1, 1, 0xFF5A9C70
        dd 977, 577, 2, 1, 0xFF3C7346
        dd 874, 139, 1, 1, 0xFF3C7346
        dd 1200, 413, 1, 1, 0xFF3C7346
        dd 1217, 28, 2, 1, 0xFF3C7346
        dd 43, 27, 1, 1, 0xFF5A9C70
        dd 254, 711, 1, 1, 0xFF5A9C70
        dd 492, 572, 2, 1, 0xFF3C7346
        dd 286, 551, 1, 1, 0xFF5A9C70
        dd 761, 698, 2, 1, 0xFF5A9C70
        dd 102, 14, 2, 1, 0xFF3C7346
        dd 646, 139, 2, 1, 0xFF3C7346
        dd 109, 194, 1, 1, 0xFF3C7346
        dd 632, 707, 1, 1, 0xFF3C7346
        dd 715, 579, 1, 1, 0xFF3C7346
        dd 887, 699, 1, 1, 0xFF3C7346
        dd 151, 51, 2, 1, 0xFF5A9C70
        dd 978, 634, 2, 1, 0xFF3C7346
        dd 730, 34, 1, 1, 0xFF5A9C70
        dd 674, 153, 2, 1, 0xFF3C7346
        dd 980, 703, 1, 1, 0xFF5A9C70
        dd 683, 148, 1, 1, 0xFF3C7346
        dd 398, 45, 1, 1, 0xFF3C7346
        dd 277, 155, 2, 1, 0xFF3C7346
        dd 682, 501, 2, 1, 0xFF5A9C70
        dd 539, 462, 2, 1, 0xFF3C7346
        dd 99, 176, 1, 1, 0xFF3C7346
        dd 1095, 20, 1, 1, 0xFF3C7346
        dd 1194, 677, 2, 1, 0xFF5A9C70
        dd 284, 172, 1, 1, 0xFF3C7346
        dd 1086, 4, 2, 1, 0xFF5A9C70
        dd 1146, 300, 2, 1, 0xFF5A9C70
        dd 368, 695, 1, 1, 0xFF3C7346
        dd 21, 54, 2, 1, 0xFF3C7346
        dd 390, 198, 2, 1, 0xFF3C7346
        dd 702, 36, 1, 1, 0xFF5A9C70
        dd 1274, 220, 1, 1, 0xFF5A9C70
        dd 532, 584, 1, 1, 0xFF5A9C70
        dd 45, 308, 1, 1, 0xFF5A9C70
        dd 983, 470, 1, 1, 0xFF3C7346
        dd 282, 241, 2, 1, 0xFF3C7346
        dd 406, 38, 2, 1, 0xFF5A9C70
        dd 1228, 603, 1, 1, 0xFF3C7346
        dd 863, 18, 1, 1, 0xFF3C7346
        dd 365, 223, 2, 1, 0xFF3C7346
        dd 391, 56, 2, 1, 0xFF3C7346
        dd 1279, 51, 1, 1, 0xFF5A9C70
        dd 427, 191, 2, 1, 0xFF3C7346
        dd 559, 1, 1, 1, 0xFF5A9C70
        dd 1129, 492, 2, 1, 0xFF3C7346
        dd 131, 226, 1, 1, 0xFF5A9C70
        dd 976, 670, 2, 1, 0xFF3C7346
        dd 969, 270, 1, 1, 0xFF3C7346
        dd 1259, 421, 2, 1, 0xFF3C7346
        dd 488, 656, 1, 1, 0xFF3C7346
        dd 1077, 570, 1, 1, 0xFF5A9C70
        dd 1199, 633, 2, 1, 0xFF5A9C70
        dd 1251, 136, 2, 1, 0xFF3C7346
        dd 624, 165, 2, 1, 0xFF3C7346
        dd 674, 169, 1, 1, 0xFF5A9C70
        dd 753, 654, 2, 1, 0xFF3C7346
        dd 186, 151, 1, 1, 0xFF5A9C70
        dd 516, 580, 2, 1, 0xFF3C7346
        dd 608, 142, 1, 1, 0xFF5A9C70
        dd 166, 72, 2, 1, 0xFF5A9C70
        dd 1134, 451, 1, 1, 0xFF5A9C70
        dd 1137, 456, 1, 1, 0xFF5A9C70
        dd 845, 186, 2, 1, 0xFF3C7346
        dd 365, 132, 2, 1, 0xFF3C7346
        dd 379, 258, 1, 1, 0xFF3C7346
        dd 1252, 116, 1, 1, 0xFF5A9C70
        dd 1120, 714, 1, 1, 0xFF3C7346
        dd 377, 11, 2, 1, 0xFF5A9C70
        dd 714, 147, 1, 1, 0xFF5A9C70
        dd 982, 456, 1, 1, 0xFF5A9C70
        dd 454, 191, 1, 1, 0xFF3C7346
        dd 1269, 570, 2, 1, 0xFF3C7346
        dd 1020, 4, 1, 1, 0xFF5A9C70
        dd 652, 404, 2, 1, 0xFF3C7346
        dd 287, 641, 2, 1, 0xFF5A9C70
        dd 825, 198, 2, 1, 0xFF5A9C70
        dd 543, 474, 2, 1, 0xFF3C7346
        dd 371, 448, 2, 1, 0xFF5A9C70
        dd 9, 483, 2, 1, 0xFF3C7346
        dd 562, 659, 1, 1, 0xFF5A9C70
        dd 704, 316, 2, 1, 0xFF3C7346
        dd 562, 29, 2, 1, 0xFF5A9C70
        dd 382, 193, 2, 1, 0xFF5A9C70
        dd 1019, 706, 1, 1, 0xFF3C7346
        dd 90, 714, 1, 1, 0xFF5A9C70
        dd 140, 710, 1, 1, 0xFF5A9C70
        dd 34, 272, 1, 1, 0xFF5A9C70
        dd 360, 254, 1, 1, 0xFF3C7346
        dd 1147, 678, 1, 1, 0xFF5A9C70
        dd 283, 525, 2, 1, 0xFF5A9C70
        dd 27, 147, 2, 1, 0xFF5A9C70
        dd 283, 586, 1, 1, 0xFF3C7346
        dd 1213, 416, 2, 1, 0xFF3C7346
        dd 442, 575, 2, 1, 0xFF5A9C70
        dd 1268, 183, 2, 1, 0xFF3C7346
        dd 27, 158, 1, 1, 0xFF3C7346
        dd 693, 559, 2, 1, 0xFF5A9C70
        dd 648, 151, 2, 1, 0xFF3C7346
        dd 1110, 671, 2, 1, 0xFF3C7346
        dd 1242, 613, 1, 1, 0xFF5A9C70
        dd 854, 184, 2, 1, 0xFF3C7346
        dd 555, 180, 2, 1, 0xFF3C7346
        dd 1273, 258, 2, 1, 0xFF5A9C70
        dd 475, 696, 1, 1, 0xFF3C7346
        dd 1251, 71, 2, 1, 0xFF3C7346
        dd 602, 173, 2, 1, 0xFF3C7346
        dd 30, 704, 2, 1, 0xFF3C7346
        dd 1246, 269, 2, 1, 0xFF5A9C70
        dd 798, 151, 1, 1, 0xFF3C7346
        dd 615, 715, 2, 1, 0xFF3C7346
        dd 381, 570, 2, 1, 0xFF3C7346
        dd 21, 290, 2, 1, 0xFF3C7346
        dd 675, 197, 2, 1, 0xFF5A9C70
        dd 37, 147, 2, 1, 0xFF3C7346
        dd 457, 718, 1, 1, 0xFF3C7346
        dd 866, 4, 1, 1, 0xFF3C7346
        dd 161, 122, 2, 1, 0xFF3C7346
        dd 287, 237, 1, 1, 0xFF3C7346
        dd 149, 269, 1, 1, 0xFF5A9C70
        dd 1022, 414, 1, 1, 0xFF5A9C70
        dd 771, 317, 2, 1, 0xFF3C7346
        dd 561, 11, 2, 1, 0xFF3C7346
        dd 1262, 592, 2, 1, 0xFF3C7346
        dd 1119, 651, 1, 1, 0xFF5A9C70
        dd 285, 538, 2, 1, 0xFF3C7346
        dd 834, 415, 2, 1, 0xFF3C7346
        dd 1258, 476, 2, 1, 0xFF3C7346
        dd 378, 435, 2, 1, 0xFF5A9C70
        dd 1218, 414, 1, 1, 0xFF3C7346
        dd 718, 534, 2, 1, 0xFF3C7346
        dd 971, 519, 2, 1, 0xFF3C7346
        dd 705, 586, 1, 1, 0xFF3C7346
        dd 1094, 547, 1, 1, 0xFF3C7346
        dd 1255, 316, 2, 1, 0xFF5A9C70
        dd 828, 5, 2, 1, 0xFF3C7346
        dd 157, 79, 1, 1, 0xFF3C7346
        dd 878, 517, 1, 1, 0xFF3C7346
        dd 130, 263, 1, 1, 0xFF3C7346
        dd 207, 187, 1, 1, 0xFF3C7346
        dd 1175, 622, 2, 1, 0xFF3C7346
        dd 813, 0, 2, 1, 0xFF3C7346
        dd 214, 319, 1, 1, 0xFF5A9C70
        dd 389, 70, 2, 1, 0xFF5A9C70
        dd 6, 443, 1, 1, 0xFF5A9C70
        dd 1256, 134, 1, 1, 0xFF3C7346
        dd 1127, 305, 2, 1, 0xFF3C7346
        dd 1247, 157, 2, 1, 0xFF5A9C70
        dd 377, 485, 1, 1, 0xFF5A9C70
        dd 636, 172, 2, 1, 0xFF5A9C70
        dd 1155, 319, 1, 1, 0xFF5A9C70
        dd 119, 316, 1, 1, 0xFF3C7346
        dd 622, 139, 2, 1, 0xFF5A9C70
        dd 1275, 420, 1, 1, 0xFF5A9C70
        dd 376, 449, 1, 1, 0xFF5A9C70
        dd 712, 196, 1, 1, 0xFF3C7346
        dd 3, 299, 1, 1, 0xFF3C7346
        dd 11, 411, 2, 1, 0xFF3C7346
        dd 1190, 613, 2, 1, 0xFF5A9C70
        dd 1148, 408, 1, 1, 0xFF3C7346
        dd 427, 0, 1, 1, 0xFF5A9C70
        dd 272, 319, 1, 1, 0xFF5A9C70
        dd 152, 63, 1, 1, 0xFF3C7346
        dd 25, 30, 1, 1, 0xFF5A9C70
        dd 149, 274, 2, 1, 0xFF5A9C70
        dd 366, 236, 1, 1, 0xFF3C7346
        dd 1150, 307, 1, 1, 0xFF3C7346
        dd 593, 663, 2, 1, 0xFF3C7346
        dd 695, 454, 1, 1, 0xFF5A9C70
        dd 1182, 604, 1, 1, 0xFF5A9C70
        dd 1272, 689, 1, 1, 0xFF5A9C70
        dd 552, 531, 1, 1, 0xFF5A9C70
        dd 542, 585, 2, 1, 0xFF3C7346
        dd 719, 404, 2, 1, 0xFF3C7346
        dd 26, 703, 1, 1, 0xFF5A9C70
        dd 745, 198, 1, 1, 0xFF3C7346
        dd 426, 22, 1, 1, 0xFF5A9C70
        dd 1082, 5, 1, 1, 0xFF5A9C70
        dd 1109, 410, 1, 1, 0xFF5A9C70
        dd 391, 204, 1, 1, 0xFF5A9C70
        dd 1248, 141, 1, 1, 0xFF3C7346
        dd 1227, 428, 1, 1, 0xFF3C7346
        dd 969, 660, 2, 1, 0xFF3C7346
        dd 666, 541, 2, 1, 0xFF3C7346
        dd 1, 210, 2, 1, 0xFF3C7346
        dd 1261, 650, 1, 1, 0xFF5A9C70
        dd 363, 466, 2, 1, 0xFF5A9C70
        dd 1083, 313, 2, 1, 0xFF3C7346
        dd 630, 68, 2, 1, 0xFF3C7346
        dd 668, 20, 2, 1, 0xFF5A9C70
        dd 94, 152, 2, 1, 0xFF5A9C70
        dd 608, 2, 1, 1, 0xFF5A9C70
        dd 1135, 25, 2, 1, 0xFF5A9C70
        dd 1163, 594, 2, 1, 0xFF3C7346
        dd 798, 17, 2, 1, 0xFF5A9C70
        dd 1192, 424, 2, 1, 0xFF3C7346
        dd 93, 315, 1, 1, 0xFF3C7346
        dd 151, 242, 2, 1, 0xFF5A9C70
        dd 12, 608, 2, 1, 0xFF5A9C70
        dd 90, 3, 1, 1, 0xFF5A9C70
        dd 1119, 702, 1, 1, 0xFF3C7346
        dd 749, 413, 1, 1, 0xFF3C7346
        dd 519, 13, 1, 1, 0xFF5A9C70
        dd 604, 27, 1, 1, 0xFF5A9C70
        dd 969, 24, 1, 1, 0xFF5A9C70
        dd 765, 683, 2, 1, 0xFF5A9C70
        dd 192, 719, 1, 1, 0xFF3C7346
        dd 288, 227, 2, 1, 0xFF5A9C70
        dd 882, 695, 2, 1, 0xFF3C7346
        dd 163, 138, 2, 1, 0xFF5A9C70
        dd 55, 707, 1, 1, 0xFF5A9C70
        dd 133, 293, 2, 1, 0xFF5A9C70
        dd 741, 407, 2, 1, 0xFF3C7346
        dd 1180, 428, 2, 1, 0xFF3C7346
        dd 578, 510, 2, 1, 0xFF5A9C70
        dd 19, 15, 2, 1, 0xFF5A9C70
        dd 1234, 708, 2, 1, 0xFF3C7346
        dd 207, 36, 2, 1, 0xFF3C7346
        dd 641, 686, 1, 1, 0xFF5A9C70
        dd 1127, 653, 2, 1, 0xFF3C7346
        dd 1160, 707, 2, 1, 0xFF3C7346
        dd 198, 301, 1, 1, 0xFF5A9C70
        dd 231, 199, 2, 1, 0xFF3C7346
        dd 788, 150, 2, 1, 0xFF3C7346
        dd 1251, 254, 1, 1, 0xFF3C7346
        dd 831, 579, 1, 1, 0xFF3C7346
        dd 650, 155, 2, 1, 0xFF3C7346
        dd 383, 120, 2, 1, 0xFF3C7346
        dd 271, 268, 2, 1, 0xFF3C7346
        dd 75, 308, 1, 1, 0xFF3C7346
        dd 1214, 656, 2, 1, 0xFF5A9C70
        dd 25, 668, 1, 1, 0xFF3C7346
        dd 699, 319, 1, 1, 0xFF5A9C70
        dd 618, 154, 1, 1, 0xFF3C7346
        dd 884, 552, 1, 1, 0xFF5A9C70
        dd 624, 572, 1, 1, 0xFF3C7346
        dd 443, 659, 1, 1, 0xFF5A9C70
        dd 150, 17, 2, 1, 0xFF3C7346
        dd 418, 662, 2, 1, 0xFF5A9C70
        dd 116, 315, 2, 1, 0xFF5A9C70
        dd 734, 176, 1, 1, 0xFF5A9C70
        dd 1251, 144, 1, 1, 0xFF5A9C70
        dd 1035, 9, 1, 1, 0xFF3C7346
        dd 685, 572, 2, 1, 0xFF3C7346
        dd 560, 582, 2, 1, 0xFF5A9C70
        dd 617, 67, 2, 1, 0xFF3C7346
        dd 384, 35, 2, 1, 0xFF5A9C70
        dd 537, 538, 1, 1, 0xFF5A9C70
        dd 875, 577, 1, 1, 0xFF3C7346
        dd 175, 708, 1, 1, 0xFF3C7346
        dd 378, 408, 2, 1, 0xFF5A9C70
        dd 389, 199, 1, 1, 0xFF3C7346
        dd 10, 519, 1, 1, 0xFF5A9C70
        dd 1098, 418, 2, 1, 0xFF3C7346
        dd 1223, 411, 1, 1, 0xFF3C7346
        dd 680, 24, 2, 1, 0xFF3C7346
        dd 27, 488, 2, 1, 0xFF5A9C70
        dd 288, 234, 1, 1, 0xFF5A9C70
        dd 635, 714, 2, 1, 0xFF3C7346
        dd 1120, 638, 1, 1, 0xFF3C7346
        dd 672, 570, 2, 1, 0xFF3C7346
        dd 980, 515, 1, 1, 0xFF3C7346
        dd 801, 191, 2, 1, 0xFF5A9C70
        dd 736, 661, 2, 1, 0xFF5A9C70
        dd 616, 586, 1, 1, 0xFF3C7346
        dd 435, 660, 1, 1, 0xFF5A9C70
        dd 962, 75, 2, 1, 0xFF5A9C70
        dd 374, 497, 1, 1, 0xFF3C7346
        dd 16, 121, 2, 1, 0xFF5A9C70
        dd 441, 31, 2, 1, 0xFF5A9C70
        dd 397, 412, 2, 1, 0xFF5A9C70
        dd 1117, 451, 1, 1, 0xFF5A9C70
        dd 589, 589, 1, 1, 0xFF5A9C70
        dd 141, 407, 2, 1, 0xFF3C7346
        dd 615, 564, 1, 1, 0xFF3C7346
        dd 24, 73, 2, 1, 0xFF5A9C70
        dd 216, 164, 1, 1, 0xFF3C7346
        dd 971, 482, 2, 1, 0xFF5A9C70
        dd 373, 411, 2, 1, 0xFF3C7346
        dd 408, 405, 1, 1, 0xFF3C7346
        dd 464, 19, 1, 1, 0xFF3C7346
        dd 1086, 29, 1, 1, 0xFF3C7346
        dd 590, 0, 1, 1, 0xFF5A9C70
        dd 1270, 438, 1, 1, 0xFF3C7346
        dd 651, 171, 1, 1, 0xFF3C7346
        dd 1073, 584, 1, 1, 0xFF3C7346
        dd 965, 472, 1, 1, 0xFF3C7346
        dd 804, 19, 2, 1, 0xFF5A9C70
        dd 547, 466, 2, 1, 0xFF5A9C70
        dd 1241, 669, 2, 1, 0xFF3C7346
        dd 372, 569, 2, 1, 0xFF3C7346
        dd 637, 400, 1, 1, 0xFF3C7346
        dd 629, 694, 1, 1, 0xFF3C7346
        dd 961, 275, 1, 1, 0xFF5A9C70
        dd 261, 45, 1, 1, 0xFF5A9C70
        dd 1150, 679, 1, 1, 0xFF5A9C70
        dd 457, 578, 1, 1, 0xFF5A9C70
        dd 800, 19, 1, 1, 0xFF3C7346
        dd 469, 587, 2, 1, 0xFF3C7346
        dd 219, 51, 1, 1, 0xFF5A9C70
        dd 285, 319, 2, 1, 0xFF5A9C70
        dd 11, 299, 2, 1, 0xFF3C7346
        dd 369, 296, 2, 1, 0xFF5A9C70
        dd 28, 460, 1, 1, 0xFF3C7346
        dd 11, 480, 1, 1, 0xFF3C7346
        dd 572, 197, 2, 1, 0xFF3C7346
        dd 174, 705, 2, 1, 0xFF3C7346
        dd 649, 123, 2, 1, 0xFF5A9C70
        dd 549, 434, 2, 1, 0xFF5A9C70
        dd 865, 655, 1, 1, 0xFF3C7346
        dd 709, 714, 2, 1, 0xFF3C7346
        dd 1175, 596, 2, 1, 0xFF5A9C70
        dd 11, 101, 1, 1, 0xFF3C7346
        dd 536, 517, 1, 1, 0xFF3C7346
        dd 502, 661, 2, 1, 0xFF3C7346
        dd 1, 668, 1, 1, 0xFF3C7346
        dd 370, 147, 2, 1, 0xFF3C7346
        dd 1064, 319, 2, 1, 0xFF3C7346
        dd 1059, 707, 2, 1, 0xFF5A9C70
        dd 1047, 564, 2, 1, 0xFF5A9C70
        dd 1245, 244, 2, 1, 0xFF3C7346
        dd 682, 417, 2, 1, 0xFF3C7346
        dd 988, 701, 2, 1, 0xFF3C7346
        dd 427, 588, 1, 1, 0xFF5A9C70
        dd 1130, 474, 2, 1, 0xFF3C7346
        dd 374, 552, 2, 1, 0xFF3C7346
        dd 583, 522, 2, 1, 0xFF3C7346
        dd 239, 186, 1, 1, 0xFF5A9C70
        dd 84, 198, 2, 1, 0xFF5A9C70
        dd 559, 442, 1, 1, 0xFF5A9C70
        dd 1183, 643, 1, 1, 0xFF5A9C70
        dd 1141, 610, 1, 1, 0xFF5A9C70
        dd 1016, 417, 2, 1, 0xFF5A9C70
        dd 973, 513, 1, 1, 0xFF5A9C70
        dd 33, 233, 1, 1, 0xFF3C7346
        dd 222, 10, 2, 1, 0xFF3C7346
        dd 648, 64, 1, 1, 0xFF3C7346
        dd 239, 36, 1, 1, 0xFF5A9C70
        dd 701, 154, 2, 1, 0xFF5A9C70
        dd 50, 168, 1, 1, 0xFF5A9C70
        dd 864, 167, 2, 1, 0xFF5A9C70
        dd 1235, 642, 2, 1, 0xFF5A9C70
        dd 1242, 14, 2, 1, 0xFF5A9C70
        dd 965, 47, 1, 1, 0xFF3C7346
        dd 151, 21, 1, 1, 0xFF5A9C70
        dd 1263, 454, 1, 1, 0xFF3C7346
        dd 278, 118, 1, 1, 0xFF5A9C70
        dd 870, 266, 1, 1, 0xFF5A9C70
        dd 1207, 631, 1, 1, 0xFF5A9C70
        dd 637, 78, 2, 1, 0xFF5A9C70
        dd 169, 151, 1, 1, 0xFF3C7346
        dd 980, 587, 1, 1, 0xFF5A9C70
        dd 762, 315, 2, 1, 0xFF3C7346
        dd 1256, 601, 1, 1, 0xFF3C7346
        dd 566, 562, 2, 1, 0xFF5A9C70
        dd 207, 163, 2, 1, 0xFF5A9C70
        dd 289, 153, 1, 1, 0xFF5A9C70
        dd 1175, 301, 2, 1, 0xFF3C7346
        dd 1270, 15, 1, 1, 0xFF5A9C70
        dd 704, 573, 2, 1, 0xFF3C7346
        dd 427, 651, 1, 1, 0xFF3C7346
        dd 970, 449, 1, 1, 0xFF5A9C70
        dd 139, 701, 2, 1, 0xFF5A9C70
        dd 282, 288, 1, 1, 0xFF3C7346
        dd 962, 145, 1, 1, 0xFF3C7346
        dd 1235, 15, 2, 1, 0xFF5A9C70
        dd 699, 539, 1, 1, 0xFF5A9C70
        dd 1068, 572, 2, 1, 0xFF5A9C70
        dd 562, 535, 2, 1, 0xFF5A9C70
        dd 1248, 114, 1, 1, 0xFF5A9C70
        dd 1050, 710, 2, 1, 0xFF5A9C70
        dd 1125, 600, 2, 1, 0xFF5A9C70
        dd 648, 412, 2, 1, 0xFF3C7346
        dd 872, 254, 1, 1, 0xFF3C7346
        dd 171, 4, 2, 1, 0xFF3C7346
        dd 727, 577, 2, 1, 0xFF3C7346
        dd 103, 9, 2, 1, 0xFF5A9C70
        dd 39, 297, 1, 1, 0xFF3C7346
        dd 169, 712, 1, 1, 0xFF3C7346
        dd 674, 143, 2, 1, 0xFF5A9C70
        dd 1009, 707, 2, 1, 0xFF3C7346
        dd 627, 131, 1, 1, 0xFF5A9C70
        dd 1253, 515, 2, 1, 0xFF3C7346
        dd 688, 181, 2, 1, 0xFF3C7346
        dd 818, 317, 1, 1, 0xFF3C7346
        dd 635, 692, 2, 1, 0xFF5A9C70
        dd 139, 401, 2, 1, 0xFF3C7346
        dd 776, 151, 1, 1, 0xFF5A9C70
        dd 674, 558, 2, 1, 0xFF5A9C70
        dd 1233, 660, 1, 1, 0xFF3C7346
        dd 103, 197, 2, 1, 0xFF3C7346
        dd 1184, 650, 2, 1, 0xFF5A9C70
        dd 687, 483, 1, 1, 0xFF5A9C70
        dd 1244, 711, 2, 1, 0xFF3C7346
        dd 373, 662, 1, 1, 0xFF3C7346
        dd 873, 90, 1, 1, 0xFF5A9C70
        dd 613, 96, 1, 1, 0xFF3C7346
        dd 881, 245, 1, 1, 0xFF5A9C70
        dd 1175, 598, 1, 1, 0xFF3C7346
        dd 384, 410, 1, 1, 0xFF5A9C70
        dd 399, 318, 2, 1, 0xFF3C7346
        dd 420, 12, 1, 1, 0xFF5A9C70
        dd 66, 185, 1, 1, 0xFF5A9C70
        dd 632, 98, 2, 1, 0xFF5A9C70
        dd 844, 190, 2, 1, 0xFF3C7346
        dd 1251, 28, 2, 1, 0xFF5A9C70
        dd 270, 124, 2, 1, 0xFF3C7346
        dd 835, 714, 2, 1, 0xFF5A9C70
        dd 1174, 603, 2, 1, 0xFF5A9C70
        dd 280, 516, 2, 1, 0xFF3C7346
        dd 1078, 18, 1, 1, 0xFF5A9C70
        dd 696, 651, 2, 1, 0xFF3C7346
        dd 963, 522, 2, 1, 0xFF3C7346
        dd 258, 161, 1, 1, 0xFF3C7346
        dd 964, 518, 2, 1, 0xFF3C7346
        dd 1240, 713, 1, 1, 0xFF3C7346
        dd 757, 677, 2, 1, 0xFF3C7346
        dd 1049, 405, 2, 1, 0xFF3C7346
        dd 478, 580, 2, 1, 0xFF5A9C70
        dd 727, 182, 1, 1, 0xFF3C7346
        dd 734, 173, 1, 1, 0xFF5A9C70
        dd 527, 713, 2, 1, 0xFF5A9C70
        dd 135, 251, 2, 1, 0xFF5A9C70
        dd 272, 310, 2, 1, 0xFF5A9C70
        dd 1237, 627, 1, 1, 0xFF3C7346
        dd 887, 697, 1, 1, 0xFF3C7346
        dd 883, 582, 2, 1, 0xFF5A9C70
        dd 969, 559, 2, 1, 0xFF5A9C70
        dd 866, 155, 2, 1, 0xFF5A9C70
        dd 579, 518, 1, 1, 0xFF3C7346
        dd 596, 402, 2, 1, 0xFF5A9C70
        dd 1172, 592, 2, 1, 0xFF5A9C70
        dd 865, 405, 1, 1, 0xFF5A9C70
        dd 1259, 591, 1, 1, 0xFF5A9C70
        dd 634, 191, 1, 1, 0xFF3C7346
        dd 870, 130, 1, 1, 0xFF5A9C70
        dd 24, 247, 2, 1, 0xFF3C7346
        dd 880, 104, 1, 1, 0xFF3C7346
        dd 22, 204, 1, 1, 0xFF3C7346
        dd 1081, 701, 2, 1, 0xFF5A9C70
        dd 288, 585, 1, 1, 0xFF5A9C70
        dd 1095, 402, 2, 1, 0xFF5A9C70
        dd 662, 14, 1, 1, 0xFF3C7346
        dd 998, 304, 2, 1, 0xFF5A9C70
        dd 53, 185, 2, 1, 0xFF3C7346
        dd 664, 157, 1, 1, 0xFF5A9C70
        dd 1257, 427, 2, 1, 0xFF3C7346
        dd 611, 100, 1, 1, 0xFF5A9C70
        dd 1153, 609, 1, 1, 0xFF3C7346
        dd 880, 305, 2, 1, 0xFF3C7346
        dd 865, 25, 2, 1, 0xFF5A9C70
        dd 1095, 709, 2, 1, 0xFF5A9C70
        dd 659, 158, 1, 1, 0xFF3C7346
        dd 526, 655, 1, 1, 0xFF3C7346
        dd 814, 199, 1, 1, 0xFF3C7346
        dd 1112, 689, 2, 1, 0xFF5A9C70
        dd 1137, 564, 2, 1, 0xFF3C7346
        dd 147, 255, 1, 1, 0xFF3C7346
        dd 380, 654, 2, 1, 0xFF5A9C70
        dd 989, 711, 1, 1, 0xFF3C7346
        dd 374, 196, 2, 1, 0xFF3C7346
        dd 703, 715, 1, 1, 0xFF5A9C70
        dd 94, 151, 2, 1, 0xFF3C7346
        dd 371, 43, 2, 1, 0xFF3C7346
        dd 1274, 259, 1, 1, 0xFF3C7346
        dd 963, 131, 1, 1, 0xFF3C7346
        dd 1009, 704, 2, 1, 0xFF5A9C70
        dd 1121, 423, 2, 1, 0xFF5A9C70
        dd 1126, 315, 2, 1, 0xFF3C7346
        dd 577, 2, 2, 1, 0xFF5A9C70
        dd 1193, 682, 2, 1, 0xFF3C7346
        dd 94, 178, 1, 1, 0xFF3C7346
        dd 733, 150, 2, 1, 0xFF3C7346
        dd 161, 176, 2, 1, 0xFF3C7346
        dd 963, 246, 1, 1, 0xFF5A9C70
        dd 1265, 43, 2, 1, 0xFF3C7346
        dd 1254, 502, 2, 1, 0xFF3C7346
        dd 878, 480, 2, 1, 0xFF3C7346
        dd 877, 652, 2, 1, 0xFF3C7346
        dd 874, 428, 2, 1, 0xFF3C7346
        dd 1240, 196, 1, 1, 0xFF5A9C70
        dd 976, 28, 1, 1, 0xFF3C7346
        dd 2, 135, 1, 1, 0xFF3C7346
        dd 960, 4, 2, 1, 0xFF3C7346
        dd 1139, 693, 1, 1, 0xFF5A9C70
        dd 1154, 426, 2, 1, 0xFF3C7346
        dd 406, 574, 2, 1, 0xFF5A9C70
        dd 720, 651, 1, 1, 0xFF3C7346
        dd 733, 414, 2, 1, 0xFF5A9C70
        dd 1273, 197, 1, 1, 0xFF5A9C70
        dd 225, 172, 2, 1, 0xFF3C7346
        dd 265, 186, 1, 1, 0xFF3C7346
        dd 1213, 402, 1, 1, 0xFF3C7346
        dd 478, 651, 2, 1, 0xFF3C7346
        dd 1275, 230, 1, 1, 0xFF3C7346
        dd 398, 132, 2, 1, 0xFF3C7346
        dd 136, 173, 2, 1, 0xFF3C7346
        dd 1272, 22, 2, 1, 0xFF3C7346
        dd 29, 476, 2, 1, 0xFF3C7346
        dd 152, 6, 2, 1, 0xFF3C7346
        dd 982, 507, 2, 1, 0xFF3C7346
        dd 592, 408, 2, 1, 0xFF3C7346
        dd 567, 407, 1, 1, 0xFF5A9C70
        dd 667, 176, 2, 1, 0xFF3C7346
        dd 1031, 719, 1, 1, 0xFF3C7346
        dd 197, 6, 1, 1, 0xFF5A9C70
        dd 19, 131, 2, 1, 0xFF5A9C70
        dd 1258, 146, 2, 1, 0xFF3C7346
        dd 110, 306, 1, 1, 0xFF3C7346
        dd 1044, 563, 2, 1, 0xFF3C7346
        dd 373, 233, 2, 1, 0xFF5A9C70
        dd 1124, 601, 1, 1, 0xFF3C7346
        dd 553, 434, 1, 1, 0xFF3C7346
        dd 795, 11, 1, 1, 0xFF5A9C70
        dd 874, 296, 2, 1, 0xFF5A9C70
        dd 647, 73, 2, 1, 0xFF3C7346
        dd 706, 432, 1, 1, 0xFF5A9C70
        dd 1120, 465, 1, 1, 0xFF3C7346
        dd 984, 28, 1, 1, 0xFF5A9C70
        dd 1117, 605, 2, 1, 0xFF3C7346
        dd 1248, 682, 2, 1, 0xFF5A9C70
        dd 588, 550, 2, 1, 0xFF3C7346
        dd 592, 653, 2, 1, 0xFF3C7346
        dd 8, 33, 2, 1, 0xFF5A9C70
        dd 1028, 19, 2, 1, 0xFF3C7346
        dd 1275, 478, 1, 1, 0xFF3C7346
        dd 621, 71, 1, 1, 0xFF5A9C70
        dd 625, 532, 2, 1, 0xFF5A9C70
        dd 215, 8, 2, 1, 0xFF5A9C70
        dd 783, 168, 2, 1, 0xFF5A9C70
        dd 403, 412, 2, 1, 0xFF3C7346
        dd 0, 552, 1, 1, 0xFF3C7346
        dd 606, 130, 1, 1, 0xFF3C7346
        dd 233, 44, 1, 1, 0xFF5A9C70
        dd 691, 573, 2, 1, 0xFF3C7346
        dd 719, 715, 1, 1, 0xFF3C7346
        dd 17, 427, 2, 1, 0xFF3C7346
        dd 618, 180, 2, 1, 0xFF3C7346
        dd 107, 310, 1, 1, 0xFF3C7346
        dd 383, 655, 2, 1, 0xFF3C7346
        dd 438, 34, 2, 1, 0xFF5A9C70
        dd 966, 530, 2, 1, 0xFF5A9C70
        dd 709, 184, 2, 1, 0xFF5A9C70
        dd 150, 166, 2, 1, 0xFF3C7346
        dd 187, 290, 1, 1, 0xFF5A9C70
        dd 234, 11, 1, 1, 0xFF3C7346
        dd 85, 402, 1, 1, 0xFF3C7346
        dd 284, 449, 1, 1, 0xFF5A9C70
        dd 1085, 700, 2, 1, 0xFF3C7346
        dd 978, 24, 2, 1, 0xFF5A9C70
        dd 1194, 424, 2, 1, 0xFF3C7346
        dd 1107, 700, 2, 1, 0xFF5A9C70
        dd 21, 116, 1, 1, 0xFF3C7346
        dd 612, 55, 1, 1, 0xFF3C7346
        dd 987, 531, 1, 1, 0xFF3C7346
        dd 707, 567, 2, 1, 0xFF5A9C70
        dd 283, 183, 2, 1, 0xFF5A9C70
        dd 259, 308, 1, 1, 0xFF3C7346
        dd 39, 92, 1, 1, 0xFF3C7346
        dd 216, 174, 1, 1, 0xFF5A9C70
        dd 260, 53, 2, 1, 0xFF5A9C70
        dd 285, 72, 1, 1, 0xFF5A9C70
        dd 820, 147, 2, 1, 0xFF5A9C70
        dd 1259, 51, 2, 1, 0xFF5A9C70
        dd 87, 38, 2, 1, 0xFF5A9C70
        dd 998, 541, 2, 1, 0xFF3C7346
        dd 1240, 196, 2, 1, 0xFF5A9C70
        dd 801, 149, 2, 1, 0xFF5A9C70
        dd 1049, 553, 1, 1, 0xFF3C7346
        dd 163, 156, 2, 1, 0xFF3C7346
        dd 1269, 87, 1, 1, 0xFF3C7346
        dd 799, 573, 1, 1, 0xFF3C7346
        dd 186, 46, 2, 1, 0xFF3C7346
        dd 512, 710, 2, 1, 0xFF3C7346
        dd 627, 529, 1, 1, 0xFF3C7346
        dd 367, 286, 2, 1, 0xFF3C7346
        dd 270, 287, 1, 1, 0xFF3C7346
        dd 887, 102, 2, 1, 0xFF5A9C70
        dd 638, 567, 1, 1, 0xFF5A9C70
        dd 461, 198, 1, 1, 0xFF3C7346
        dd 129, 713, 1, 1, 0xFF5A9C70
        dd 232, 194, 2, 1, 0xFF5A9C70
        dd 13, 267, 1, 1, 0xFF5A9C70
        dd 601, 124, 1, 1, 0xFF5A9C70
        dd 200, 317, 2, 1, 0xFF3C7346
        dd 114, 305, 1, 1, 0xFF5A9C70
        dd 161, 315, 1, 1, 0xFF3C7346
        dd 673, 27, 2, 1, 0xFF5A9C70
        dd 722, 182, 2, 1, 0xFF5A9C70
        dd 756, 167, 2, 1, 0xFF3C7346
        dd 693, 19, 1, 1, 0xFF3C7346
        dd 1023, 574, 1, 1, 0xFF5A9C70
        dd 626, 159, 1, 1, 0xFF5A9C70
        dd 183, 186, 1, 1, 0xFF3C7346
        dd 1276, 15, 1, 1, 0xFF3C7346
        dd 175, 171, 1, 1, 0xFF5A9C70
        dd 872, 168, 2, 1, 0xFF3C7346
        dd 494, 13, 2, 1, 0xFF5A9C70
        dd 180, 301, 1, 1, 0xFF5A9C70
        dd 1196, 675, 1, 1, 0xFF5A9C70
        dd 1217, 707, 2, 1, 0xFF3C7346
        dd 1150, 705, 2, 1, 0xFF5A9C70
        dd 80, 404, 1, 1, 0xFF5A9C70
        dd 610, 159, 1, 1, 0xFF5A9C70
        dd 518, 570, 1, 1, 0xFF3C7346
        dd 15, 665, 1, 1, 0xFF3C7346
        dd 0, 35, 2, 1, 0xFF5A9C70
        dd 228, 0, 2, 1, 0xFF5A9C70
        dd 549, 414, 1, 1, 0xFF5A9C70
        dd 602, 48, 1, 1, 0xFF5A9C70
        dd 1279, 699, 2, 1, 0xFF5A9C70
        dd 845, 4, 2, 1, 0xFF3C7346
        dd 517, 193, 2, 1, 0xFF5A9C70
        dd 688, 141, 2, 1, 0xFF5A9C70
        dd 273, 51, 2, 1, 0xFF3C7346
        dd 1172, 605, 2, 1, 0xFF5A9C70
        dd 1202, 710, 1, 1, 0xFF5A9C70
        dd 1119, 537, 2, 1, 0xFF3C7346
        dd 360, 45, 2, 1, 0xFF5A9C70
        dd 218, 316, 1, 1, 0xFF3C7346
        dd 887, 289, 2, 1, 0xFF5A9C70
        dd 1000, 1, 2, 1, 0xFF3C7346
        dd 879, 113, 2, 1, 0xFF3C7346
        dd 616, 115, 2, 1, 0xFF5A9C70
        dd 115, 5, 1, 1, 0xFF5A9C70
        dd 366, 468, 2, 1, 0xFF5A9C70
        dd 69, 27, 1, 1, 0xFF3C7346
        dd 545, 568, 2, 1, 0xFF5A9C70
        dd 968, 543, 2, 1, 0xFF3C7346
        dd 611, 523, 1, 1, 0xFF5A9C70
        dd 1133, 6, 1, 1, 0xFF5A9C70
        dd 289, 525, 2, 1, 0xFF5A9C70
        dd 703, 440, 2, 1, 0xFF3C7346
        dd 1263, 159, 1, 1, 0xFF3C7346
        dd 379, 252, 2, 1, 0xFF5A9C70
        dd 1229, 714, 2, 1, 0xFF3C7346
        dd 1134, 473, 2, 1, 0xFF3C7346
        dd 439, 585, 2, 1, 0xFF3C7346
        dd 973, 683, 1, 1, 0xFF3C7346
        dd 1252, 550, 2, 1, 0xFF3C7346
        dd 877, 140, 1, 1, 0xFF3C7346
        dd 665, 573, 1, 1, 0xFF3C7346
        dd 1054, 425, 2, 1, 0xFF3C7346
        dd 608, 560, 2, 1, 0xFF3C7346
        dd 393, 48, 1, 1, 0xFF5A9C70
        dd 1158, 601, 1, 1, 0xFF3C7346
        dd 974, 516, 1, 1, 0xFF5A9C70
        dd 1181, 630, 1, 1, 0xFF3C7346
        dd 663, 37, 2, 1, 0xFF5A9C70
        dd 1259, 555, 2, 1, 0xFF5A9C70
        dd 1259, 522, 1, 1, 0xFF5A9C70
        dd 811, 140, 1, 1, 0xFF5A9C70
        dd 525, 713, 2, 1, 0xFF5A9C70
        dd 1204, 644, 1, 1, 0xFF3C7346
        dd 634, 410, 1, 1, 0xFF3C7346
        dd 167, 718, 1, 1, 0xFF5A9C70
        dd 384, 242, 1, 1, 0xFF5A9C70
        dd 417, 650, 1, 1, 0xFF3C7346
        dd 1132, 665, 1, 1, 0xFF5A9C70
        dd 171, 5, 1, 1, 0xFF5A9C70
        dd 1279, 163, 2, 1, 0xFF3C7346
        dd 610, 190, 1, 1, 0xFF3C7346
        dd 769, 142, 1, 1, 0xFF5A9C70
        dd 1252, 663, 1, 1, 0xFF5A9C70
        dd 1087, 29, 1, 1, 0xFF3C7346
        dd 1224, 669, 1, 1, 0xFF5A9C70
        dd 208, 47, 2, 1, 0xFF5A9C70
        dd 655, 38, 2, 1, 0xFF3C7346
        dd 185, 308, 1, 1, 0xFF5A9C70
        dd 139, 296, 1, 1, 0xFF5A9C70
        dd 1104, 417, 1, 1, 0xFF3C7346
        dd 1262, 683, 1, 1, 0xFF3C7346
        dd 277, 219, 1, 1, 0xFF3C7346
        dd 289, 467, 1, 1, 0xFF3C7346
        dd 537, 713, 2, 1, 0xFF3C7346
        dd 366, 481, 2, 1, 0xFF3C7346
        dd 1278, 148, 1, 1, 0xFF3C7346
        dd 149, 263, 2, 1, 0xFF3C7346
        dd 361, 125, 1, 1, 0xFF5A9C70
        dd 9, 252, 2, 1, 0xFF5A9C70
        dd 672, 412, 1, 1, 0xFF5A9C70
        dd 830, 582, 2, 1, 0xFF3C7346
        dd 882, 78, 1, 1, 0xFF3C7346
        dd 1083, 419, 2, 1, 0xFF3C7346
        dd 982, 470, 1, 1, 0xFF5A9C70
        dd 15, 252, 1, 1, 0xFF5A9C70
        dd 1253, 96, 2, 1, 0xFF3C7346
        dd 197, 56, 2, 1, 0xFF5A9C70
        dd 1007, 566, 2, 1, 0xFF3C7346
        dd 213, 14, 1, 1, 0xFF5A9C70
        dd 442, 198, 2, 1, 0xFF3C7346
        dd 499, 14, 2, 1, 0xFF3C7346
        dd 512, 187, 2, 1, 0xFF5A9C70
        dd 26, 625, 2, 1, 0xFF3C7346
        dd 1162, 621, 1, 1, 0xFF3C7346
        dd 552, 492, 1, 1, 0xFF3C7346
        dd 1247, 600, 2, 1, 0xFF3C7346
        dd 163, 176, 1, 1, 0xFF3C7346
        dd 200, 154, 2, 1, 0xFF3C7346
        dd 149, 267, 2, 1, 0xFF3C7346
        dd 709, 10, 1, 1, 0xFF5A9C70
        dd 113, 188, 1, 1, 0xFF5A9C70
        dd 750, 673, 1, 1, 0xFF5A9C70
        dd 1118, 538, 2, 1, 0xFF3C7346
        dd 700, 524, 2, 1, 0xFF3C7346
        dd 539, 524, 1, 1, 0xFF5A9C70
        dd 1256, 1, 2, 1, 0xFF5A9C70
        dd 1170, 679, 1, 1, 0xFF3C7346
        dd 1261, 37, 2, 1, 0xFF3C7346
        dd 1120, 1, 2, 1, 0xFF3C7346
        dd 719, 567, 2, 1, 0xFF5A9C70
        dd 1057, 706, 2, 1, 0xFF3C7346
        dd 1205, 29, 2, 1, 0xFF3C7346
        dd 372, 126, 1, 1, 0xFF3C7346
        dd 1250, 198, 2, 1, 0xFF3C7346
        dd 287, 616, 1, 1, 0xFF3C7346
        dd 771, 588, 2, 1, 0xFF5A9C70
        dd 984, 485, 2, 1, 0xFF5A9C70
        dd 374, 71, 1, 1, 0xFF3C7346
        dd 719, 546, 2, 1, 0xFF5A9C70
        dd 732, 35, 1, 1, 0xFF5A9C70
        dd 998, 558, 2, 1, 0xFF5A9C70
        dd 554, 196, 2, 1, 0xFF5A9C70
        dd 961, 198, 1, 1, 0xFF3C7346
        dd 1279, 32, 1, 1, 0xFF5A9C70
        dd 875, 578, 1, 1, 0xFF5A9C70
        dd 385, 408, 2, 1, 0xFF5A9C70
        dd 1279, 300, 1, 1, 0xFF3C7346
        dd 91, 706, 1, 1, 0xFF5A9C70
        dd 880, 694, 1, 1, 0xFF5A9C70
        dd 380, 301, 1, 1, 0xFF3C7346
        dd 611, 589, 1, 1, 0xFF3C7346
        dd 139, 255, 2, 1, 0xFF3C7346
        dd 1, 193, 1, 1, 0xFF5A9C70
        dd 542, 466, 2, 1, 0xFF5A9C70
        dd 179, 718, 1, 1, 0xFF5A9C70
        dd 840, 415, 2, 1, 0xFF5A9C70
        dd 689, 571, 1, 1, 0xFF3C7346
        dd 989, 664, 2, 1, 0xFF3C7346
        dd 1130, 623, 1, 1, 0xFF5A9C70
        dd 870, 560, 1, 1, 0xFF3C7346
        dd 1251, 175, 1, 1, 0xFF5A9C70
        dd 1122, 514, 1, 1, 0xFF5A9C70
        dd 6, 425, 2, 1, 0xFF5A9C70
        dd 1005, 548, 1, 1, 0xFF5A9C70
        dd 383, 406, 2, 1, 0xFF3C7346
        dd 751, 155, 2, 1, 0xFF3C7346
        dd 867, 187, 1, 1, 0xFF5A9C70
        dd 1131, 620, 2, 1, 0xFF3C7346
        dd 668, 158, 2, 1, 0xFF5A9C70
        dd 135, 281, 2, 1, 0xFF5A9C70
        dd 1254, 233, 2, 1, 0xFF5A9C70
        dd 436, 664, 2, 1, 0xFF3C7346
        dd 378, 149, 1, 1, 0xFF5A9C70
        dd 724, 157, 1, 1, 0xFF5A9C70
        dd 1089, 552, 1, 1, 0xFF3C7346
        dd 26, 618, 2, 1, 0xFF3C7346
        dd 36, 36, 1, 1, 0xFF3C7346
        dd 1242, 620, 2, 1, 0xFF5A9C70
        dd 258, 167, 1, 1, 0xFF5A9C70
        dd 988, 515, 1, 1, 0xFF3C7346
        dd 784, 13, 2, 1, 0xFF3C7346
        dd 630, 153, 1, 1, 0xFF5A9C70
        dd 801, 167, 2, 1, 0xFF3C7346
        dd 882, 689, 2, 1, 0xFF5A9C70
        dd 780, 4, 2, 1, 0xFF5A9C70
        dd 619, 56, 1, 1, 0xFF5A9C70
        dd 149, 405, 2, 1, 0xFF3C7346
        dd 779, 173, 1, 1, 0xFF3C7346
        dd 569, 558, 1, 1, 0xFF5A9C70
        dd 118, 401, 1, 1, 0xFF5A9C70
        dd 608, 148, 2, 1, 0xFF3C7346
        dd 690, 15, 2, 1, 0xFF5A9C70
        dd 16, 622, 1, 1, 0xFF3C7346
        dd 6, 290, 1, 1, 0xFF3C7346
        dd 1182, 677, 2, 1, 0xFF5A9C70
        dd 33, 101, 1, 1, 0xFF3C7346
        dd 2, 707, 1, 1, 0xFF3C7346
        dd 801, 584, 2, 1, 0xFF3C7346
        dd 1, 643, 2, 1, 0xFF3C7346
        dd 223, 702, 2, 1, 0xFF3C7346
        dd 282, 128, 1, 1, 0xFF3C7346
        dd 18, 433, 1, 1, 0xFF3C7346
        dd 1250, 583, 2, 1, 0xFF3C7346
        dd 604, 121, 1, 1, 0xFF3C7346
        dd 1114, 27, 2, 1, 0xFF5A9C70
        dd 505, 407, 1, 1, 0xFF3C7346
        dd 992, 316, 1, 1, 0xFF3C7346
        dd 569, 656, 1, 1, 0xFF5A9C70
        dd 1261, 261, 2, 1, 0xFF5A9C70
        dd 395, 139, 1, 1, 0xFF5A9C70
        dd 137, 312, 1, 1, 0xFF3C7346
        dd 701, 555, 2, 1, 0xFF3C7346
        dd 234, 713, 2, 1, 0xFF5A9C70
        dd 646, 181, 2, 1, 0xFF5A9C70
        dd 176, 18, 2, 1, 0xFF3C7346
        dd 1150, 642, 1, 1, 0xFF3C7346
        dd 522, 315, 2, 1, 0xFF3C7346
        dd 966, 617, 2, 1, 0xFF3C7346
        dd 1143, 590, 1, 1, 0xFF3C7346
        dd 1046, 552, 2, 1, 0xFF3C7346
        dd 664, 24, 1, 1, 0xFF3C7346
        dd 3, 460, 2, 1, 0xFF5A9C70
        dd 1257, 130, 2, 1, 0xFF3C7346
        dd 577, 537, 2, 1, 0xFF3C7346
        dd 28, 88, 1, 1, 0xFF3C7346
        dd 36, 317, 2, 1, 0xFF5A9C70
        dd 3, 210, 2, 1, 0xFF3C7346
        dd 23, 678, 1, 1, 0xFF3C7346
        dd 366, 211, 2, 1, 0xFF3C7346
        dd 1113, 525, 2, 1, 0xFF3C7346
        dd 627, 62, 1, 1, 0xFF3C7346
        dd 1247, 108, 2, 1, 0xFF3C7346
        dd 11, 463, 2, 1, 0xFF5A9C70
        dd 54, 189, 2, 1, 0xFF5A9C70
        dd 614, 567, 1, 1, 0xFF5A9C70
        dd 529, 184, 1, 1, 0xFF3C7346
        dd 164, 18, 2, 1, 0xFF5A9C70
        dd 513, 658, 2, 1, 0xFF3C7346
        dd 507, 405, 1, 1, 0xFF3C7346
        dd 975, 29, 1, 1, 0xFF3C7346
        dd 1013, 564, 2, 1, 0xFF3C7346
        dd 1177, 690, 1, 1, 0xFF3C7346
        dd 287, 92, 1, 1, 0xFF5A9C70
        dd 877, 59, 1, 1, 0xFF3C7346
        dd 1218, 657, 2, 1, 0xFF3C7346
        dd 231, 170, 2, 1, 0xFF3C7346
        dd 777, 717, 2, 1, 0xFF3C7346
        dd 367, 38, 1, 1, 0xFF5A9C70
        dd 242, 39, 1, 1, 0xFF3C7346
        dd 1120, 552, 1, 1, 0xFF5A9C70
        dd 16, 589, 2, 1, 0xFF5A9C70
        dd 847, 663, 2, 1, 0xFF5A9C70
        dd 1097, 4, 2, 1, 0xFF5A9C70
        dd 629, 516, 1, 1, 0xFF5A9C70
        dd 643, 412, 2, 1, 0xFF3C7346
        dd 399, 85, 1, 1, 0xFF3C7346
        dd 602, 121, 1, 1, 0xFF3C7346
        dd 373, 218, 1, 1, 0xFF3C7346
        dd 206, 30, 1, 1, 0xFF3C7346
        dd 771, 25, 1, 1, 0xFF3C7346
        dd 1152, 633, 1, 1, 0xFF3C7346
        dd 1160, 659, 2, 1, 0xFF3C7346
        dd 1123, 695, 1, 1, 0xFF3C7346
        dd 1248, 294, 1, 1, 0xFF5A9C70
        dd 1097, 578, 1, 1, 0xFF5A9C70
        dd 625, 409, 1, 1, 0xFF5A9C70
        dd 595, 182, 1, 1, 0xFF5A9C70
        dd 363, 116, 1, 1, 0xFF3C7346
        dd 40, 400, 1, 1, 0xFF5A9C70
        dd 529, 411, 1, 1, 0xFF3C7346
        dd 269, 706, 1, 1, 0xFF5A9C70
        dd 540, 23, 2, 1, 0xFF3C7346
        dd 883, 119, 1, 1, 0xFF5A9C70
        dd 437, 715, 2, 1, 0xFF3C7346
        dd 834, 711, 1, 1, 0xFF5A9C70
        dd 1177, 303, 1, 1, 0xFF3C7346
        dd 414, 658, 2, 1, 0xFF3C7346
        dd 546, 453, 2, 1, 0xFF5A9C70
        dd 1187, 305, 1, 1, 0xFF3C7346
        dd 1130, 549, 2, 1, 0xFF3C7346
        dd 1128, 301, 2, 1, 0xFF5A9C70
        dd 14, 255, 1, 1, 0xFF3C7346
        dd 16, 57, 2, 1, 0xFF3C7346
        dd 543, 462, 1, 1, 0xFF3C7346
        dd 506, 580, 1, 1, 0xFF5A9C70
        dd 983, 547, 1, 1, 0xFF3C7346
        dd 221, 195, 2, 1, 0xFF3C7346
        dd 2, 40, 2, 1, 0xFF3C7346
        dd 1243, 635, 2, 1, 0xFF5A9C70
        dd 13, 312, 1, 1, 0xFF5A9C70
        dd 872, 586, 1, 1, 0xFF5A9C70
        dd 242, 311, 2, 1, 0xFF5A9C70
        dd 1057, 23, 2, 1, 0xFF5A9C70
        dd 1275, 296, 1, 1, 0xFF3C7346
        dd 856, 710, 1, 1, 0xFF3C7346
        dd 652, 716, 1, 1, 0xFF5A9C70
        dd 577, 406, 2, 1, 0xFF3C7346
        dd 503, 1, 1, 1, 0xFF3C7346
        dd 128, 33, 2, 1, 0xFF3C7346
        dd 641, 319, 2, 1, 0xFF3C7346
        dd 394, 316, 2, 1, 0xFF5A9C70
        dd 631, 88, 1, 1, 0xFF3C7346
        dd 778, 165, 2, 1, 0xFF3C7346
        dd 604, 81, 2, 1, 0xFF5A9C70
        dd 371, 426, 2, 1, 0xFF3C7346
        dd 788, 404, 1, 1, 0xFF3C7346
        dd 606, 589, 1, 1, 0xFF3C7346
        dd 395, 654, 1, 1, 0xFF5A9C70
        dd 480, 668, 1, 1, 0xFF3C7346
        dd 1186, 310, 1, 1, 0xFF3C7346
        dd 1094, 407, 2, 1, 0xFF3C7346
        dd 1026, 565, 1, 1, 0xFF3C7346
        dd 1232, 11, 1, 1, 0xFF3C7346
        dd 20, 31, 2, 1, 0xFF5A9C70
        dd 1154, 644, 1, 1, 0xFF5A9C70
        dd 1267, 547, 2, 1, 0xFF5A9C70
        dd 659, 554, 1, 1, 0xFF3C7346
        dd 794, 657, 2, 1, 0xFF5A9C70
        dd 475, 0, 1, 1, 0xFF5A9C70
        dd 395, 418, 1, 1, 0xFF5A9C70
        dd 9, 200, 1, 1, 0xFF5A9C70
        dd 550, 198, 2, 1, 0xFF3C7346
        dd 682, 469, 2, 1, 0xFF5A9C70
        dd 98, 403, 1, 1, 0xFF3C7346
        dd 764, 145, 1, 1, 0xFF5A9C70
        dd 274, 299, 2, 1, 0xFF5A9C70
        dd 972, 622, 2, 1, 0xFF3C7346
        dd 649, 137, 2, 1, 0xFF3C7346
        dd 613, 89, 1, 1, 0xFF3C7346
        dd 208, 297, 1, 1, 0xFF5A9C70
        dd 143, 704, 2, 1, 0xFF3C7346
        dd 1150, 424, 2, 1, 0xFF5A9C70
        dd 679, 529, 1, 1, 0xFF3C7346
        dd 588, 532, 2, 1, 0xFF3C7346
        dd 548, 576, 1, 1, 0xFF5A9C70
        dd 1278, 455, 1, 1, 0xFF3C7346
        dd 136, 306, 2, 1, 0xFF5A9C70
        dd 1164, 633, 1, 1, 0xFF3C7346
        dd 380, 577, 1, 1, 0xFF3C7346
        dd 469, 196, 2, 1, 0xFF5A9C70
        dd 51, 17, 2, 1, 0xFF3C7346
        dd 1084, 23, 2, 1, 0xFF5A9C70
        dd 271, 202, 2, 1, 0xFF3C7346
        dd 392, 91, 2, 1, 0xFF5A9C70
        dd 1181, 19, 2, 1, 0xFF3C7346
        dd 804, 161, 2, 1, 0xFF5A9C70
        dd 616, 76, 2, 1, 0xFF3C7346
        dd 130, 32, 1, 1, 0xFF5A9C70
        dd 873, 200, 1, 1, 0xFF5A9C70
        dd 538, 548, 1, 1, 0xFF3C7346
        dd 989, 706, 1, 1, 0xFF5A9C70
        dd 15, 257, 2, 1, 0xFF5A9C70
        dd 752, 140, 2, 1, 0xFF3C7346
        dd 634, 653, 2, 1, 0xFF5A9C70
        dd 603, 182, 2, 1, 0xFF3C7346
        dd 1049, 427, 1, 1, 0xFF3C7346
        dd 628, 120, 2, 1, 0xFF5A9C70
        dd 765, 681, 1, 1, 0xFF5A9C70
        dd 1254, 52, 1, 1, 0xFF3C7346
        dd 832, 585, 2, 1, 0xFF3C7346
        dd 1245, 222, 2, 1, 0xFF3C7346
        dd 876, 420, 1, 1, 0xFF3C7346
        dd 881, 713, 2, 1, 0xFF3C7346
        dd 371, 139, 2, 1, 0xFF5A9C70
        dd 286, 228, 1, 1, 0xFF5A9C70
        dd 732, 711, 2, 1, 0xFF5A9C70
        dd 23, 94, 2, 1, 0xFF5A9C70
        dd 1232, 626, 2, 1, 0xFF3C7346
        dd 4, 536, 2, 1, 0xFF5A9C70
        dd 966, 402, 2, 1, 0xFF3C7346
        dd 760, 404, 2, 1, 0xFF5A9C70
        dd 613, 651, 2, 1, 0xFF5A9C70
        dd 1242, 405, 2, 1, 0xFF5A9C70
        dd 29, 292, 1, 1, 0xFF5A9C70
        dd 1241, 169, 2, 1, 0xFF5A9C70
        dd 771, 674, 2, 1, 0xFF3C7346
        dd 1024, 300, 1, 1, 0xFF3C7346
        dd 1120, 422, 1, 1, 0xFF5A9C70
        dd 1088, 412, 2, 1, 0xFF5A9C70
        dd 365, 551, 2, 1, 0xFF5A9C70
        dd 15, 172, 1, 1, 0xFF3C7346
        dd 522, 411, 1, 1, 0xFF5A9C70
        dd 735, 650, 1, 1, 0xFF3C7346
        dd 268, 711, 1, 1, 0xFF5A9C70
        dd 631, 70, 1, 1, 0xFF3C7346
        dd 1128, 701, 2, 1, 0xFF3C7346
        dd 1221, 593, 1, 1, 0xFF3C7346
        dd 1047, 5, 1, 1, 0xFF3C7346
        dd 850, 170, 2, 1, 0xFF3C7346
        dd 362, 442, 1, 1, 0xFF3C7346
        dd 1148, 653, 2, 1, 0xFF5A9C70
        dd 278, 98, 1, 1, 0xFF5A9C70
        dd 866, 299, 1, 1, 0xFF3C7346
        dd 8, 33, 2, 1, 0xFF5A9C70
        dd 365, 56, 1, 1, 0xFF5A9C70
        dd 1278, 149, 2, 1, 0xFF3C7346
        dd 732, 14, 2, 1, 0xFF3C7346
        dd 691, 512, 1, 1, 0xFF3C7346
        dd 1006, 716, 1, 1, 0xFF5A9C70
        dd 482, 35, 1, 1, 0xFF3C7346
        dd 639, 317, 2, 1, 0xFF5A9C70
        dd 285, 246, 1, 1, 0xFF3C7346
        dd 1065, 425, 1, 1, 0xFF3C7346
        dd 421, 8, 2, 1, 0xFF3C7346
        dd 1141, 400, 1, 1, 0xFF5A9C70
        dd 1273, 514, 2, 1, 0xFF3C7346
        dd 574, 576, 1, 1, 0xFF5A9C70
        dd 1111, 569, 1, 1, 0xFF5A9C70
        dd 1151, 310, 2, 1, 0xFF5A9C70
        dd 1257, 6, 1, 1, 0xFF3C7346
        dd 575, 664, 1, 1, 0xFF5A9C70
        dd 881, 197, 1, 1, 0xFF3C7346
        dd 230, 54, 1, 1, 0xFF5A9C70
        dd 558, 192, 1, 1, 0xFF5A9C70
        dd 700, 185, 1, 1, 0xFF5A9C70
        dd 605, 572, 1, 1, 0xFF3C7346
        dd 1274, 19, 1, 1, 0xFF3C7346
        dd 1042, 558, 1, 1, 0xFF5A9C70
        dd 1246, 594, 2, 1, 0xFF5A9C70
        dd 597, 521, 2, 1, 0xFF5A9C70
        dd 221, 1, 2, 1, 0xFF5A9C70
        dd 1272, 217, 1, 1, 0xFF5A9C70
        dd 27, 292, 1, 1, 0xFF5A9C70
        dd 215, 701, 2, 1, 0xFF3C7346
        dd 576, 37, 1, 1, 0xFF5A9C70
        dd 543, 588, 2, 1, 0xFF3C7346
        dd 137, 164, 2, 1, 0xFF3C7346
        dd 980, 441, 1, 1, 0xFF3C7346
        dd 1037, 565, 2, 1, 0xFF5A9C70
        dd 1023, 415, 1, 1, 0xFF3C7346
        dd 704, 660, 1, 1, 0xFF3C7346
        dd 573, 188, 2, 1, 0xFF5A9C70
        dd 987, 412, 1, 1, 0xFF5A9C70
        dd 274, 245, 1, 1, 0xFF3C7346
        dd 963, 564, 1, 1, 0xFF5A9C70
        dd 722, 663, 1, 1, 0xFF3C7346
        dd 1239, 618, 2, 1, 0xFF3C7346
        dd 993, 718, 1, 1, 0xFF3C7346
        dd 374, 431, 2, 1, 0xFF5A9C70
        dd 97, 719, 2, 1, 0xFF3C7346
        dd 368, 250, 1, 1, 0xFF5A9C70
        dd 496, 0, 2, 1, 0xFF5A9C70
        dd 1204, 16, 1, 1, 0xFF5A9C70
        dd 289, 98, 1, 1, 0xFF5A9C70
        dd 363, 462, 2, 1, 0xFF3C7346
        dd 1034, 589, 2, 1, 0xFF3C7346
        dd 287, 253, 1, 1, 0xFF3C7346
        dd 1229, 666, 2, 1, 0xFF5A9C70
        dd 1104, 421, 2, 1, 0xFF5A9C70
        dd 989, 674, 1, 1, 0xFF3C7346
        dd 610, 185, 1, 1, 0xFF3C7346
        dd 135, 183, 2, 1, 0xFF3C7346
        dd 248, 300, 2, 1, 0xFF3C7346
        dd 660, 569, 2, 1, 0xFF3C7346
        dd 648, 582, 2, 1, 0xFF5A9C70
        dd 1258, 545, 1, 1, 0xFF5A9C70
        dd 1136, 459, 2, 1, 0xFF5A9C70
        dd 1168, 599, 1, 1, 0xFF3C7346
        dd 181, 182, 1, 1, 0xFF3C7346
        dd 18, 658, 2, 1, 0xFF5A9C70
        dd 669, 717, 1, 1, 0xFF5A9C70
        dd 822, 659, 2, 1, 0xFF3C7346
        dd 2, 80, 2, 1, 0xFF5A9C70
        dd 74, 703, 2, 1, 0xFF3C7346
        dd 245, 175, 1, 1, 0xFF3C7346
        dd 382, 148, 1, 1, 0xFF3C7346
        dd 737, 319, 1, 1, 0xFF3C7346
        dd 660, 661, 1, 1, 0xFF3C7346
        dd 24, 653, 1, 1, 0xFF3C7346
        dd 1014, 400, 2, 1, 0xFF5A9C70
        dd 883, 42, 1, 1, 0xFF5A9C70
        dd 401, 586, 2, 1, 0xFF3C7346
        dd 157, 128, 2, 1, 0xFF5A9C70
        dd 816, 156, 2, 1, 0xFF5A9C70
        dd 762, 6, 1, 1, 0xFF3C7346
        dd 866, 31, 1, 1, 0xFF3C7346
        dd 658, 1, 1, 1, 0xFF5A9C70
        dd 412, 0, 1, 1, 0xFF5A9C70
        dd 1215, 637, 2, 1, 0xFF3C7346
        dd 13, 20, 2, 1, 0xFF5A9C70
        dd 248, 711, 1, 1, 0xFF3C7346
        dd 3, 14, 1, 1, 0xFF5A9C70
        dd 1142, 26, 1, 1, 0xFF3C7346
        dd 262, 308, 1, 1, 0xFF3C7346
        dd 698, 532, 1, 1, 0xFF5A9C70
        dd 393, 81, 1, 1, 0xFF5A9C70
        dd 883, 124, 1, 1, 0xFF3C7346
        dd 715, 156, 2, 1, 0xFF5A9C70
        dd 773, 695, 1, 1, 0xFF5A9C70
        dd 1261, 499, 2, 1, 0xFF3C7346
        dd 14, 603, 1, 1, 0xFF5A9C70
        dd 1221, 719, 1, 1, 0xFF5A9C70
        dd 32, 282, 2, 1, 0xFF5A9C70
        dd 260, 300, 1, 1, 0xFF5A9C70
        dd 1111, 318, 1, 1, 0xFF3C7346
        dd 1061, 703, 2, 1, 0xFF3C7346
        dd 1183, 25, 2, 1, 0xFF5A9C70
        dd 541, 454, 2, 1, 0xFF5A9C70
        dd 854, 718, 2, 1, 0xFF5A9C70
        dd 285, 28, 2, 1, 0xFF3C7346
        dd 1188, 611, 2, 1, 0xFF5A9C70
        dd 692, 155, 1, 1, 0xFF3C7346
        dd 368, 309, 1, 1, 0xFF5A9C70
        dd 20, 488, 1, 1, 0xFF5A9C70
        dd 981, 410, 2, 1, 0xFF3C7346
        dd 621, 564, 2, 1, 0xFF3C7346
        dd 1107, 560, 1, 1, 0xFF3C7346
        dd 868, 298, 1, 1, 0xFF5A9C70
        dd 990, 306, 2, 1, 0xFF3C7346
        dd 50, 301, 1, 1, 0xFF3C7346
        dd 1041, 403, 1, 1, 0xFF3C7346
        dd 888, 291, 2, 1, 0xFF5A9C70
        dd 536, 530, 1, 1, 0xFF5A9C70
        dd 1076, 694, 1, 1, 0xFF3C7346
        dd 161, 178, 2, 1, 0xFF5A9C70
        dd 486, 400, 1, 1, 0xFF5A9C70
        dd 147, 224, 1, 1, 0xFF5A9C70
        dd 841, 145, 1, 1, 0xFF5A9C70
        dd 651, 165, 1, 1, 0xFF5A9C70
        dd 1036, 422, 2, 1, 0xFF5A9C70
        dd 287, 687, 2, 1, 0xFF5A9C70
        dd 597, 654, 1, 1, 0xFF3C7346
        dd 751, 24, 2, 1, 0xFF5A9C70
        dd 25, 194, 2, 1, 0xFF3C7346
        dd 645, 73, 2, 1, 0xFF5A9C70
        dd 605, 140, 2, 1, 0xFF3C7346
        dd 242, 38, 2, 1, 0xFF3C7346
        dd 70, 302, 2, 1, 0xFF5A9C70
        dd 1202, 600, 2, 1, 0xFF3C7346
        dd 829, 10, 1, 1, 0xFF5A9C70
        dd 241, 22, 1, 1, 0xFF5A9C70
        dd 632, 702, 1, 1, 0xFF3C7346
        dd 1018, 553, 2, 1, 0xFF3C7346
        dd 453, 717, 1, 1, 0xFF3C7346
        dd 1145, 408, 2, 1, 0xFF5A9C70
        dd 711, 10, 2, 1, 0xFF3C7346
        dd 552, 431, 1, 1, 0xFF3C7346
        dd 21, 28, 1, 1, 0xFF3C7346
        dd 1217, 687, 1, 1, 0xFF5A9C70
        dd 1224, 611, 2, 1, 0xFF5A9C70
        dd 1243, 647, 2, 1, 0xFF3C7346
        dd 385, 55, 1, 1, 0xFF5A9C70
        dd 177, 151, 2, 1, 0xFF5A9C70
        dd 1188, 408, 2, 1, 0xFF5A9C70
        dd 793, 28, 1, 1, 0xFF3C7346
        dd 814, 710, 2, 1, 0xFF3C7346
        dd 601, 82, 1, 1, 0xFF3C7346
        dd 275, 183, 1, 1, 0xFF5A9C70
        dd 632, 141, 1, 1, 0xFF5A9C70
        dd 1070, 706, 1, 1, 0xFF5A9C70
        dd 618, 122, 1, 1, 0xFF5A9C70
        dd 598, 543, 1, 1, 0xFF5A9C70
        dd 486, 18, 1, 1, 0xFF5A9C70
        dd 280, 699, 1, 1, 0xFF3C7346
        dd 1121, 627, 1, 1, 0xFF3C7346
        dd 982, 476, 1, 1, 0xFF3C7346
        dd 1253, 158, 2, 1, 0xFF3C7346
        dd 1269, 413, 2, 1, 0xFF3C7346
        dd 1037, 558, 2, 1, 0xFF3C7346
        dd 717, 167, 2, 1, 0xFF5A9C70
        dd 445, 7, 2, 1, 0xFF5A9C70
        dd 1068, 415, 2, 1, 0xFF3C7346
        dd 235, 170, 1, 1, 0xFF3C7346
        dd 479, 715, 1, 1, 0xFF5A9C70
        dd 822, 162, 2, 1, 0xFF3C7346
        dd 20, 0, 1, 1, 0xFF3C7346
        dd 807, 401, 1, 1, 0xFF5A9C70
        dd 231, 407, 2, 1, 0xFF5A9C70
        dd 1252, 714, 1, 1, 0xFF3C7346
        dd 28, 96, 1, 1, 0xFF5A9C70
        dd 517, 586, 2, 1, 0xFF5A9C70
        dd 882, 527, 1, 1, 0xFF5A9C70
        dd 646, 402, 1, 1, 0xFF3C7346
        dd 733, 715, 2, 1, 0xFF5A9C70
        dd 230, 169, 1, 1, 0xFF5A9C70
        dd 643, 19, 2, 1, 0xFF5A9C70
        dd 167, 128, 2, 1, 0xFF3C7346
        dd 88, 172, 1, 1, 0xFF5A9C70
        dd 694, 0, 1, 1, 0xFF5A9C70
        dd 549, 463, 2, 1, 0xFF5A9C70
        dd 45, 13, 2, 1, 0xFF3C7346
        dd 230, 408, 2, 1, 0xFF3C7346
        dd 874, 225, 1, 1, 0xFF3C7346
        dd 281, 23, 2, 1, 0xFF5A9C70
        dd 284, 691, 2, 1, 0xFF5A9C70
        dd 1269, 202, 2, 1, 0xFF5A9C70
        dd 148, 703, 2, 1, 0xFF5A9C70
        dd 680, 580, 2, 1, 0xFF5A9C70
        dd 522, 577, 1, 1, 0xFF3C7346
        dd 687, 6, 1, 1, 0xFF5A9C70
        dd 198, 405, 2, 1, 0xFF3C7346
        dd 22, 147, 2, 1, 0xFF3C7346
        dd 134, 709, 1, 1, 0xFF5A9C70
        dd 188, 59, 1, 1, 0xFF5A9C70
        dd 616, 552, 2, 1, 0xFF5A9C70
        dd 1252, 62, 1, 1, 0xFF5A9C70
        dd 760, 572, 2, 1, 0xFF5A9C70
        dd 644, 190, 1, 1, 0xFF3C7346
        dd 1167, 645, 2, 1, 0xFF3C7346
        dd 804, 0, 2, 1, 0xFF5A9C70
        dd 617, 407, 2, 1, 0xFF5A9C70
        dd 1129, 691, 1, 1, 0xFF5A9C70
        dd 613, 105, 2, 1, 0xFF5A9C70
        dd 375, 278, 1, 1, 0xFF3C7346
        dd 551, 458, 2, 1, 0xFF3C7346
        dd 447, 581, 2, 1, 0xFF3C7346
        dd 372, 57, 2, 1, 0xFF5A9C70
        dd 1255, 406, 2, 1, 0xFF5A9C70
        dd 400, 710, 1, 1, 0xFF3C7346
        dd 365, 170, 1, 1, 0xFF5A9C70
        dd 212, 162, 2, 1, 0xFF3C7346
        dd 692, 191, 2, 1, 0xFF5A9C70
        dd 1279, 514, 2, 1, 0xFF3C7346
        dd 552, 7, 2, 1, 0xFF3C7346
        dd 273, 41, 1, 1, 0xFF5A9C70
        dd 643, 584, 2, 1, 0xFF5A9C70
        dd 603, 401, 1, 1, 0xFF5A9C70
        dd 1105, 552, 2, 1, 0xFF5A9C70
        dd 1241, 293, 2, 1, 0xFF3C7346
        dd 881, 676, 2, 1, 0xFF5A9C70
        dd 24, 104, 2, 1, 0xFF5A9C70
        dd 987, 419, 1, 1, 0xFF5A9C70
        dd 1011, 576, 2, 1, 0xFF5A9C70
        dd 1101, 317, 1, 1, 0xFF3C7346
        dd 385, 196, 1, 1, 0xFF5A9C70
        dd 864, 27, 2, 1, 0xFF5A9C70
        dd 13, 17, 2, 1, 0xFF3C7346
        dd 26, 589, 2, 1, 0xFF5A9C70
        dd 833, 408, 1, 1, 0xFF5A9C70
        dd 378, 49, 1, 1, 0xFF3C7346
        dd 1129, 637, 2, 1, 0xFF5A9C70
        dd 1110, 526, 1, 1, 0xFF3C7346
        dd 1103, 696, 2, 1, 0xFF5A9C70
        dd 402, 185, 1, 1, 0xFF3C7346
        dd 394, 7, 1, 1, 0xFF5A9C70
        dd 15, 238, 2, 1, 0xFF3C7346
        dd 577, 410, 2, 1, 0xFF3C7346
        dd 1234, 422, 1, 1, 0xFF3C7346
        dd 822, 190, 2, 1, 0xFF3C7346
        dd 368, 115, 1, 1, 0xFF3C7346
        dd 880, 75, 2, 1, 0xFF3C7346
        dd 18, 239, 2, 1, 0xFF3C7346
        dd 621, 10, 2, 1, 0xFF3C7346
        dd 1068, 701, 2, 1, 0xFF5A9C70
        dd 256, 310, 1, 1, 0xFF3C7346
        dd 613, 414, 2, 1, 0xFF5A9C70
        dd 1268, 662, 1, 1, 0xFF3C7346
        dd 1109, 24, 1, 1, 0xFF3C7346
        dd 182, 310, 2, 1, 0xFF3C7346
        dd 1178, 635, 1, 1, 0xFF5A9C70
        dd 1138, 589, 2, 1, 0xFF3C7346
        dd 38, 137, 1, 1, 0xFF5A9C70
        dd 1251, 492, 2, 1, 0xFF3C7346
        dd 284, 409, 2, 1, 0xFF5A9C70
        dd 6, 512, 1, 1, 0xFF3C7346
        dd 986, 601, 2, 1, 0xFF5A9C70
        dd 852, 179, 1, 1, 0xFF3C7346
        dd 1122, 311, 1, 1, 0xFF5A9C70
        dd 1171, 651, 2, 1, 0xFF3C7346
        dd 536, 663, 2, 1, 0xFF3C7346
        dd 1181, 307, 2, 1, 0xFF3C7346
        dd 1201, 402, 2, 1, 0xFF5A9C70
        dd 11, 417, 1, 1, 0xFF5A9C70
        dd 109, 311, 2, 1, 0xFF5A9C70
        dd 1161, 407, 1, 1, 0xFF3C7346
        dd 65, 19, 1, 1, 0xFF3C7346
        dd 1249, 297, 1, 1, 0xFF3C7346
        dd 1263, 418, 1, 1, 0xFF3C7346
        dd 1208, 607, 1, 1, 0xFF3C7346
        dd 373, 96, 1, 1, 0xFF5A9C70
        dd 261, 318, 1, 1, 0xFF3C7346
        dd 859, 169, 2, 1, 0xFF3C7346
        dd 985, 546, 2, 1, 0xFF5A9C70
        dd 1139, 629, 2, 1, 0xFF3C7346
        dd 499, 189, 1, 1, 0xFF3C7346
        dd 978, 451, 2, 1, 0xFF5A9C70
        dd 100, 189, 2, 1, 0xFF5A9C70
        dd 1258, 461, 2, 1, 0xFF3C7346
        dd 1265, 186, 2, 1, 0xFF3C7346
        dd 1254, 313, 2, 1, 0xFF5A9C70
        dd 637, 558, 2, 1, 0xFF3C7346
        dd 797, 198, 2, 1, 0xFF3C7346
        dd 622, 26, 2, 1, 0xFF5A9C70
        dd 889, 81, 2, 1, 0xFF5A9C70
        dd 1095, 546, 1, 1, 0xFF3C7346
        dd 962, 706, 2, 1, 0xFF3C7346
        dd 20, 259, 2, 1, 0xFF3C7346
        dd 127, 308, 1, 1, 0xFF3C7346
        dd 881, 282, 2, 1, 0xFF5A9C70
        dd 1232, 710, 1, 1, 0xFF5A9C70
        dd 113, 165, 2, 1, 0xFF3C7346
        dd 522, 404, 1, 1, 0xFF3C7346
        dd 760, 148, 2, 1, 0xFF5A9C70
        dd 690, 571, 1, 1, 0xFF5A9C70
        dd 1234, 624, 1, 1, 0xFF3C7346
        dd 644, 654, 2, 1, 0xFF3C7346
        dd 10, 417, 1, 1, 0xFF3C7346
        dd 30, 195, 2, 1, 0xFF3C7346
        dd 569, 192, 1, 1, 0xFF3C7346
        dd 1079, 542, 1, 1, 0xFF5A9C70
        dd 429, 718, 1, 1, 0xFF3C7346
        dd 652, 416, 1, 1, 0xFF3C7346
        dd 20, 549, 2, 1, 0xFF3C7346
        dd 845, 30, 2, 1, 0xFF3C7346
        dd 645, 563, 1, 1, 0xFF5A9C70
        dd 872, 498, 1, 1, 0xFF3C7346
        dd 1243, 170, 2, 1, 0xFF5A9C70
        dd 1019, 308, 2, 1, 0xFF3C7346
        dd 619, 11, 2, 1, 0xFF3C7346
        dd 7, 116, 2, 1, 0xFF5A9C70
        dd 709, 424, 2, 1, 0xFF3C7346
        dd 674, 8, 1, 1, 0xFF3C7346
        dd 740, 190, 1, 1, 0xFF3C7346
        dd 418, 192, 1, 1, 0xFF3C7346
        dd 1073, 419, 1, 1, 0xFF5A9C70
        dd 860, 402, 1, 1, 0xFF5A9C70
        dd 288, 437, 2, 1, 0xFF5A9C70
        dd 282, 61, 1, 1, 0xFF3C7346
        dd 1272, 94, 1, 1, 0xFF3C7346
        dd 360, 104, 2, 1, 0xFF5A9C70
        dd 155, 270, 1, 1, 0xFF3C7346
        dd 691, 507, 2, 1, 0xFF3C7346
        dd 702, 24, 2, 1, 0xFF5A9C70
        dd 627, 710, 1, 1, 0xFF3C7346
        dd 631, 650, 2, 1, 0xFF3C7346
        dd 1134, 551, 2, 1, 0xFF3C7346
        dd 874, 535, 1, 1, 0xFF3C7346
        dd 402, 25, 2, 1, 0xFF5A9C70
        dd 408, 586, 1, 1, 0xFF5A9C70
        dd 267, 5, 2, 1, 0xFF3C7346
        dd 1270, 405, 2, 1, 0xFF3C7346
        dd 547, 662, 2, 1, 0xFF3C7346
        dd 1257, 491, 1, 1, 0xFF3C7346
        dd 699, 710, 1, 1, 0xFF3C7346
        dd 766, 192, 1, 1, 0xFF3C7346
        dd 13, 71, 2, 1, 0xFF3C7346
        dd 1265, 202, 2, 1, 0xFF3C7346
        dd 466, 662, 2, 1, 0xFF3C7346
        dd 630, 530, 1, 1, 0xFF3C7346
        dd 576, 583, 1, 1, 0xFF5A9C70
        dd 219, 176, 1, 1, 0xFF3C7346
        dd 1068, 423, 2, 1, 0xFF3C7346
        dd 395, 651, 1, 1, 0xFF3C7346
        dd 19, 121, 1, 1, 0xFF5A9C70
        dd 622, 17, 1, 1, 0xFF3C7346
        dd 20, 589, 2, 1, 0xFF3C7346
        dd 19, 210, 1, 1, 0xFF3C7346
        dd 1256, 687, 2, 1, 0xFF3C7346
        dd 489, 199, 1, 1, 0xFF5A9C70
        dd 771, 685, 2, 1, 0xFF3C7346
        dd 366, 271, 2, 1, 0xFF5A9C70
        dd 760, 156, 1, 1, 0xFF5A9C70
        dd 1111, 407, 1, 1, 0xFF3C7346
        dd 569, 551, 1, 1, 0xFF5A9C70
        dd 1203, 419, 1, 1, 0xFF3C7346
        dd 94, 31, 2, 1, 0xFF5A9C70
        dd 375, 296, 2, 1, 0xFF5A9C70
        dd 1087, 20, 2, 1, 0xFF5A9C70
        dd 89, 150, 1, 1, 0xFF3C7346
        dd 803, 581, 1, 1, 0xFF3C7346
        dd 626, 663, 1, 1, 0xFF3C7346
        dd 157, 124, 1, 1, 0xFF5A9C70
        dd 694, 573, 2, 1, 0xFF5A9C70
        dd 620, 670, 1, 1, 0xFF3C7346
        dd 151, 95, 2, 1, 0xFF5A9C70
        dd 969, 25, 2, 1, 0xFF3C7346
        dd 225, 155, 1, 1, 0xFF3C7346
        dd 978, 435, 2, 1, 0xFF5A9C70
        dd 98, 716, 2, 1, 0xFF5A9C70
        dd 592, 194, 1, 1, 0xFF3C7346
        dd 381, 32, 1, 1, 0xFF3C7346
        dd 1266, 529, 1, 1, 0xFF5A9C70
        dd 1123, 553, 1, 1, 0xFF5A9C70
        dd 3, 555, 1, 1, 0xFF5A9C70
        dd 75, 16, 2, 1, 0xFF3C7346
        dd 674, 534, 1, 1, 0xFF3C7346
        dd 970, 597, 1, 1, 0xFF3C7346
        dd 288, 70, 2, 1, 0xFF3C7346
        dd 6, 18, 2, 1, 0xFF3C7346
        dd 609, 2, 1, 1, 0xFF3C7346
        dd 94, 703, 2, 1, 0xFF5A9C70
        dd 735, 179, 2, 1, 0xFF3C7346
        dd 635, 698, 1, 1, 0xFF3C7346
        dd 1176, 17, 2, 1, 0xFF5A9C70
        dd 680, 547, 1, 1, 0xFF3C7346
        dd 276, 261, 2, 1, 0xFF5A9C70
        dd 1152, 29, 2, 1, 0xFF3C7346
        dd 0, 310, 2, 1, 0xFF5A9C70
        dd 754, 189, 1, 1, 0xFF3C7346
        dd 277, 270, 1, 1, 0xFF3C7346
        dd 41, 714, 2, 1, 0xFF3C7346
        dd 1268, 642, 1, 1, 0xFF3C7346
        dd 423, 26, 2, 1, 0xFF3C7346
        dd 649, 540, 1, 1, 0xFF5A9C70
        dd 385, 48, 2, 1, 0xFF3C7346
        dd 840, 10, 1, 1, 0xFF5A9C70
        dd 786, 147, 1, 1, 0xFF3C7346
        dd 221, 9, 1, 1, 0xFF3C7346
        dd 111, 177, 2, 1, 0xFF5A9C70
        dd 154, 273, 1, 1, 0xFF5A9C70
        dd 280, 164, 1, 1, 0xFF3C7346
        dd 532, 33, 2, 1, 0xFF3C7346
        dd 964, 154, 1, 1, 0xFF5A9C70
        dd 378, 139, 2, 1, 0xFF3C7346
        dd 174, 42, 2, 1, 0xFF3C7346
        dd 1033, 588, 2, 1, 0xFF3C7346
        dd 1262, 683, 1, 1, 0xFF3C7346
        dd 889, 692, 1, 1, 0xFF5A9C70
        dd 870, 586, 2, 1, 0xFF3C7346
        dd 206, 193, 2, 1, 0xFF3C7346
        dd 769, 197, 1, 1, 0xFF3C7346
        dd 83, 163, 1, 1, 0xFF3C7346
        dd 1127, 509, 1, 1, 0xFF3C7346
        dd 519, 14, 2, 1, 0xFF3C7346
        dd 755, 702, 2, 1, 0xFF3C7346
        dd 702, 478, 1, 1, 0xFF3C7346
        dd 761, 190, 2, 1, 0xFF5A9C70
        dd 871, 116, 1, 1, 0xFF3C7346
        dd 608, 82, 1, 1, 0xFF3C7346
        dd 642, 109, 1, 1, 0xFF5A9C70
        dd 157, 15, 1, 1, 0xFF5A9C70
        dd 605, 5, 1, 1, 0xFF3C7346
        dd 645, 530, 2, 1, 0xFF5A9C70
        dd 576, 35, 2, 1, 0xFF3C7346
        dd 1194, 632, 1, 1, 0xFF3C7346
        dd 89, 26, 1, 1, 0xFF3C7346
        dd 658, 140, 2, 1, 0xFF5A9C70
        dd 586, 664, 2, 1, 0xFF5A9C70
        dd 861, 180, 1, 1, 0xFF3C7346
        dd 1043, 716, 1, 1, 0xFF5A9C70
        dd 367, 19, 1, 1, 0xFF5A9C70
        dd 559, 409, 1, 1, 0xFF3C7346
        dd 98, 314, 1, 1, 0xFF5A9C70
        dd 1271, 560, 2, 1, 0xFF5A9C70
        dd 728, 717, 2, 1, 0xFF3C7346
        dd 1218, 601, 2, 1, 0xFF5A9C70
        dd 1160, 618, 1, 1, 0xFF5A9C70
        dd 628, 175, 1, 1, 0xFF3C7346
        dd 24, 713, 2, 1, 0xFF3C7346
        dd 112, 29, 2, 1, 0xFF3C7346
        dd 648, 533, 2, 1, 0xFF5A9C70
        dd 34, 47, 2, 1, 0xFF3C7346
        dd 526, 589, 2, 1, 0xFF3C7346
        dd 835, 411, 1, 1, 0xFF5A9C70
        dd 1270, 252, 2, 1, 0xFF3C7346
        dd 363, 133, 2, 1, 0xFF3C7346
        dd 470, 671, 2, 1, 0xFF3C7346
        dd 247, 51, 2, 1, 0xFF5A9C70
        dd 698, 718, 1, 1, 0xFF3C7346
        dd 1145, 27, 2, 1, 0xFF5A9C70
        dd 818, 191, 2, 1, 0xFF5A9C70
        dd 1, 32, 1, 1, 0xFF3C7346
        dd 3, 286, 2, 1, 0xFF3C7346
        dd 875, 133, 1, 1, 0xFF3C7346
        dd 865, 211, 1, 1, 0xFF5A9C70
        dd 501, 194, 1, 1, 0xFF5A9C70
        dd 1258, 16, 1, 1, 0xFF3C7346
        dd 181, 158, 1, 1, 0xFF3C7346
        dd 287, 516, 2, 1, 0xFF3C7346
        dd 784, 188, 1, 1, 0xFF5A9C70
        dd 144, 184, 2, 1, 0xFF5A9C70
        dd 659, 3, 1, 1, 0xFF3C7346
        dd 854, 164, 2, 1, 0xFF3C7346
        dd 856, 402, 1, 1, 0xFF5A9C70
        dd 1277, 610, 1, 1, 0xFF5A9C70
        dd 876, 10, 1, 1, 0xFF5A9C70
        dd 601, 558, 1, 1, 0xFF3C7346
        dd 1252, 472, 1, 1, 0xFF3C7346
        dd 877, 534, 2, 1, 0xFF5A9C70
        dd 1244, 307, 2, 1, 0xFF3C7346
        dd 1096, 311, 2, 1, 0xFF3C7346
        dd 710, 409, 1, 1, 0xFF3C7346
        dd 384, 178, 1, 1, 0xFF5A9C70
        dd 539, 711, 2, 1, 0xFF3C7346
        dd 522, 182, 1, 1, 0xFF5A9C70
        dd 24, 281, 2, 1, 0xFF3C7346
        dd 651, 11, 1, 1, 0xFF3C7346
        dd 492, 652, 1, 1, 0xFF3C7346
        dd 57, 708, 1, 1, 0xFF3C7346
        dd 982, 467, 2, 1, 0xFF3C7346
        dd 1276, 554, 2, 1, 0xFF5A9C70
        dd 686, 485, 2, 1, 0xFF3C7346
        dd 374, 73, 2, 1, 0xFF5A9C70
        dd 1254, 547, 1, 1, 0xFF5A9C70
        dd 1005, 711, 1, 1, 0xFF3C7346
        dd 1278, 694, 2, 1, 0xFF5A9C70
        dd 876, 40, 1, 1, 0xFF5A9C70
        dd 1111, 678, 2, 1, 0xFF5A9C70
        dd 1239, 593, 1, 1, 0xFF3C7346
        dd 881, 37, 2, 1, 0xFF3C7346
        dd 698, 553, 1, 1, 0xFF3C7346
        dd 770, 708, 1, 1, 0xFF3C7346
        dd 271, 35, 1, 1, 0xFF5A9C70
        dd 816, 144, 2, 1, 0xFF3C7346
        dd 1264, 411, 1, 1, 0xFF3C7346
        dd 460, 19, 2, 1, 0xFF3C7346
        dd 1242, 635, 2, 1, 0xFF3C7346
        dd 23, 231, 2, 1, 0xFF3C7346
        dd 363, 170, 1, 1, 0xFF3C7346
        dd 52, 712, 1, 1, 0xFF5A9C70
        dd 1113, 492, 1, 1, 0xFF5A9C70
        dd 802, 39, 1, 1, 0xFF5A9C70
        dd 1037, 17, 1, 1, 0xFF3C7346
        dd 13, 17, 2, 1, 0xFF3C7346
        dd 821, 718, 2, 1, 0xFF3C7346
        dd 422, 581, 1, 1, 0xFF3C7346
        dd 704, 21, 2, 1, 0xFF5A9C70
        dd 555, 28, 2, 1, 0xFF5A9C70
        dd 280, 258, 1, 1, 0xFF5A9C70
        dd 386, 84, 2, 1, 0xFF3C7346
        dd 370, 253, 2, 1, 0xFF3C7346
        dd 794, 22, 2, 1, 0xFF3C7346
        dd 221, 30, 2, 1, 0xFF5A9C70
        dd 68, 401, 1, 1, 0xFF5A9C70
        dd 643, 703, 1, 1, 0xFF5A9C70
        dd 748, 18, 1, 1, 0xFF3C7346
        dd 1012, 559, 1, 1, 0xFF3C7346
        dd 289, 706, 1, 1, 0xFF3C7346
        dd 682, 410, 2, 1, 0xFF5A9C70
        dd 666, 713, 1, 1, 0xFF3C7346
        dd 714, 493, 1, 1, 0xFF3C7346
        dd 507, 29, 1, 1, 0xFF5A9C70
        dd 411, 660, 2, 1, 0xFF5A9C70
        dd 513, 11, 2, 1, 0xFF5A9C70
        dd 493, 573, 1, 1, 0xFF3C7346
        dd 247, 407, 1, 1, 0xFF5A9C70
        dd 377, 407, 1, 1, 0xFF3C7346
        dd 1247, 63, 1, 1, 0xFF5A9C70
        dd 996, 553, 1, 1, 0xFF5A9C70
        dd 178, 42, 1, 1, 0xFF3C7346
        dd 881, 59, 2, 1, 0xFF5A9C70
        dd 1275, 133, 2, 1, 0xFF3C7346
        dd 1149, 424, 1, 1, 0xFF5A9C70
        dd 998, 402, 1, 1, 0xFF5A9C70
        dd 162, 187, 1, 1, 0xFF3C7346
        dd 1048, 547, 2, 1, 0xFF3C7346
        dd 781, 21, 1, 1, 0xFF3C7346
        dd 1251, 662, 1, 1, 0xFF3C7346
        dd 660, 523, 1, 1, 0xFF5A9C70
        dd 167, 102, 2, 1, 0xFF5A9C70
        dd 31, 405, 2, 1, 0xFF5A9C70
        dd 1242, 64, 2, 1, 0xFF3C7346
        dd 1273, 593, 2, 1, 0xFF5A9C70
        dd 672, 654, 1, 1, 0xFF5A9C70
        dd 644, 564, 2, 1, 0xFF3C7346
        dd 1265, 488, 2, 1, 0xFF3C7346
        dd 1186, 680, 1, 1, 0xFF3C7346
        dd 72, 715, 2, 1, 0xFF3C7346
        dd 71, 311, 2, 1, 0xFF3C7346
        dd 1202, 424, 2, 1, 0xFF5A9C70
        dd 1100, 308, 1, 1, 0xFF5A9C70
        dd 758, 315, 1, 1, 0xFF3C7346
        dd 1066, 582, 2, 1, 0xFF3C7346
        dd 672, 32, 2, 1, 0xFF3C7346
        dd 1252, 707, 2, 1, 0xFF3C7346
        dd 531, 654, 1, 1, 0xFF3C7346
        dd 1108, 697, 2, 1, 0xFF3C7346
        dd 1258, 628, 1, 1, 0xFF3C7346
        dd 962, 715, 2, 1, 0xFF3C7346
        dd 534, 5, 1, 1, 0xFF3C7346
        dd 987, 662, 2, 1, 0xFF5A9C70
        dd 1242, 234, 2, 1, 0xFF5A9C70
        dd 5, 620, 2, 1, 0xFF3C7346
        dd 58, 17, 1, 1, 0xFF3C7346
        dd 605, 93, 1, 1, 0xFF5A9C70
        dd 463, 402, 1, 1, 0xFF5A9C70
        dd 979, 522, 2, 1, 0xFF3C7346
        dd 383, 651, 1, 1, 0xFF3C7346
        dd 195, 319, 1, 1, 0xFF3C7346
        dd 1170, 405, 1, 1, 0xFF3C7346
        dd 1194, 618, 2, 1, 0xFF3C7346
        dd 419, 656, 2, 1, 0xFF3C7346
        dd 13, 661, 1, 1, 0xFF5A9C70
        dd 274, 260, 2, 1, 0xFF5A9C70
        dd 1195, 703, 1, 1, 0xFF3C7346
        dd 1117, 531, 2, 1, 0xFF3C7346
        dd 243, 308, 1, 1, 0xFF5A9C70
        dd 1274, 679, 1, 1, 0xFF5A9C70
        dd 987, 1, 1, 1, 0xFF5A9C70
        dd 122, 408, 2, 1, 0xFF5A9C70
        dd 706, 158, 2, 1, 0xFF3C7346
        dd 701, 149, 1, 1, 0xFF5A9C70
        dd 976, 17, 1, 1, 0xFF5A9C70
        dd 13, 130, 2, 1, 0xFF5A9C70
        dd 1170, 23, 1, 1, 0xFF5A9C70
        dd 89, 23, 2, 1, 0xFF3C7346
        dd 14, 426, 2, 1, 0xFF3C7346
        dd 430, 402, 1, 1, 0xFF3C7346
        dd 718, 563, 2, 1, 0xFF5A9C70
        dd 1196, 0, 1, 1, 0xFF5A9C70
        dd 1125, 713, 1, 1, 0xFF3C7346
        dd 257, 305, 1, 1, 0xFF3C7346
        dd 257, 171, 1, 1, 0xFF5A9C70
        dd 968, 239, 1, 1, 0xFF5A9C70
        dd 584, 6, 1, 1, 0xFF5A9C70
        dd 287, 153, 2, 1, 0xFF5A9C70
        dd 40, 6, 2, 1, 0xFF5A9C70
        dd 14, 432, 1, 1, 0xFF5A9C70
        dd 1249, 94, 1, 1, 0xFF3C7346
        dd 190, 43, 1, 1, 0xFF3C7346
        dd 424, 414, 1, 1, 0xFF3C7346
        dd 485, 20, 1, 1, 0xFF5A9C70
        dd 146, 175, 2, 1, 0xFF5A9C70
        dd 674, 560, 2, 1, 0xFF3C7346
        dd 650, 657, 2, 1, 0xFF5A9C70
        dd 842, 169, 1, 1, 0xFF5A9C70
        dd 371, 139, 2, 1, 0xFF3C7346
        dd 361, 505, 2, 1, 0xFF3C7346
        dd 1110, 675, 2, 1, 0xFF5A9C70
        dd 663, 1, 2, 1, 0xFF5A9C70
        dd 138, 208, 1, 1, 0xFF5A9C70
        dd 818, 184, 1, 1, 0xFF5A9C70
        dd 828, 717, 1, 1, 0xFF3C7346
        dd 867, 279, 2, 1, 0xFF3C7346
        dd 989, 306, 1, 1, 0xFF5A9C70
        dd 22, 274, 2, 1, 0xFF3C7346
        dd 1065, 409, 1, 1, 0xFF3C7346
        dd 103, 704, 1, 1, 0xFF5A9C70
        dd 620, 17, 2, 1, 0xFF3C7346
        dd 777, 171, 2, 1, 0xFF5A9C70
        dd 877, 489, 2, 1, 0xFF5A9C70
        dd 40, 312, 2, 1, 0xFF3C7346
        dd 657, 0, 2, 1, 0xFF3C7346
        dd 1174, 401, 2, 1, 0xFF3C7346
        dd 1009, 15, 1, 1, 0xFF5A9C70
        dd 1078, 709, 2, 1, 0xFF3C7346
        dd 26, 95, 2, 1, 0xFF3C7346
        dd 1117, 499, 1, 1, 0xFF3C7346
        dd 971, 479, 1, 1, 0xFF5A9C70
        dd 1160, 651, 1, 1, 0xFF3C7346
        dd 872, 105, 2, 1, 0xFF3C7346
        dd 1256, 229, 2, 1, 0xFF5A9C70
        dd 536, 9, 2, 1, 0xFF5A9C70
        dd 1133, 669, 2, 1, 0xFF3C7346
        dd 1261, 64, 2, 1, 0xFF3C7346
        dd 1254, 79, 2, 1, 0xFF3C7346
        dd 745, 192, 1, 1, 0xFF5A9C70
        dd 363, 25, 1, 1, 0xFF3C7346
        dd 29, 93, 2, 1, 0xFF3C7346
        dd 378, 557, 1, 1, 0xFF3C7346
        dd 687, 167, 1, 1, 0xFF3C7346
        dd 837, 24, 2, 1, 0xFF5A9C70
        dd 2, 591, 1, 1, 0xFF5A9C70
        dd 702, 181, 2, 1, 0xFF5A9C70
        dd 31, 148, 1, 1, 0xFF3C7346
        dd 172, 194, 1, 1, 0xFF3C7346
        dd 671, 712, 2, 1, 0xFF5A9C70
        dd 369, 212, 1, 1, 0xFF5A9C70
        dd 589, 527, 1, 1, 0xFF3C7346
        dd 639, 558, 1, 1, 0xFF3C7346
        dd 1137, 653, 2, 1, 0xFF3C7346
        dd 287, 638, 1, 1, 0xFF3C7346
        dd 1131, 447, 1, 1, 0xFF5A9C70
        dd 848, 33, 1, 1, 0xFF3C7346
        dd 976, 418, 1, 1, 0xFF3C7346
        dd 600, 419, 1, 1, 0xFF5A9C70
        dd 549, 542, 2, 1, 0xFF3C7346
        dd 283, 531, 1, 1, 0xFF3C7346
        dd 981, 629, 1, 1, 0xFF3C7346
        dd 360, 710, 1, 1, 0xFF3C7346
        dd 989, 403, 2, 1, 0xFF3C7346
        dd 1096, 700, 2, 1, 0xFF3C7346
        dd 571, 511, 2, 1, 0xFF3C7346
        dd 1273, 15, 2, 1, 0xFF5A9C70
        dd 1204, 12, 2, 1, 0xFF5A9C70
        dd 1024, 13, 2, 1, 0xFF3C7346
        dd 205, 17, 2, 1, 0xFF3C7346
        dd 765, 579, 1, 1, 0xFF5A9C70
        dd 1233, 690, 2, 1, 0xFF5A9C70
        dd 150, 106, 2, 1, 0xFF3C7346
        dd 282, 177, 1, 1, 0xFF5A9C70
        dd 679, 511, 2, 1, 0xFF5A9C70
        dd 1009, 419, 1, 1, 0xFF5A9C70
        dd 700, 512, 2, 1, 0xFF5A9C70
        dd 48, 15, 2, 1, 0xFF5A9C70
        dd 371, 36, 2, 1, 0xFF5A9C70
        dd 642, 719, 2, 1, 0xFF3C7346
        dd 875, 189, 1, 1, 0xFF5A9C70
        dd 487, 35, 2, 1, 0xFF3C7346
        dd 373, 97, 2, 1, 0xFF3C7346
        dd 809, 584, 2, 1, 0xFF3C7346
        dd 2, 53, 2, 1, 0xFF5A9C70
        dd 255, 160, 1, 1, 0xFF5A9C70
        dd 1019, 303, 2, 1, 0xFF3C7346
        dd 235, 708, 2, 1, 0xFF5A9C70
        dd 1272, 5, 2, 1, 0xFF5A9C70
        dd 474, 579, 2, 1, 0xFF3C7346
        dd 138, 716, 1, 1, 0xFF5A9C70
        dd 1267, 36, 1, 1, 0xFF3C7346
        dd 263, 171, 2, 1, 0xFF3C7346
        dd 668, 712, 1, 1, 0xFF3C7346
        dd 1139, 437, 2, 1, 0xFF3C7346
        dd 382, 215, 2, 1, 0xFF5A9C70
        dd 876, 582, 1, 1, 0xFF3C7346
        dd 1142, 411, 1, 1, 0xFF3C7346
        dd 260, 719, 2, 1, 0xFF5A9C70
        dd 509, 11, 1, 1, 0xFF3C7346
        dd 1126, 307, 2, 1, 0xFF3C7346
        dd 1270, 454, 1, 1, 0xFF3C7346
        dd 1021, 565, 2, 1, 0xFF3C7346
        dd 1275, 629, 1, 1, 0xFF3C7346
        dd 10, 28, 1, 1, 0xFF3C7346
        dd 622, 657, 2, 1, 0xFF3C7346
        dd 1183, 624, 1, 1, 0xFF3C7346
        dd 691, 456, 2, 1, 0xFF3C7346
        dd 623, 662, 2, 1, 0xFF3C7346
        dd 1049, 556, 2, 1, 0xFF3C7346
        dd 488, 415, 2, 1, 0xFF3C7346
        dd 1066, 569, 1, 1, 0xFF5A9C70
        dd 10, 188, 2, 1, 0xFF5A9C70
        dd 629, 317, 1, 1, 0xFF5A9C70
        dd 240, 161, 1, 1, 0xFF5A9C70
        dd 960, 43, 2, 1, 0xFF3C7346
        dd 977, 507, 2, 1, 0xFF3C7346
        dd 790, 149, 1, 1, 0xFF3C7346
        dd 281, 468, 1, 1, 0xFF3C7346
        dd 244, 310, 1, 1, 0xFF5A9C70
        dd 580, 580, 1, 1, 0xFF5A9C70
        dd 1078, 578, 2, 1, 0xFF5A9C70
        dd 1263, 560, 1, 1, 0xFF3C7346
        dd 85, 313, 1, 1, 0xFF3C7346
        dd 144, 174, 1, 1, 0xFF5A9C70
        dd 525, 410, 2, 1, 0xFF3C7346
        dd 1110, 698, 2, 1, 0xFF3C7346
        dd 632, 15, 2, 1, 0xFF3C7346
        dd 178, 27, 2, 1, 0xFF3C7346
        dd 697, 10, 2, 1, 0xFF5A9C70
        dd 1276, 105, 1, 1, 0xFF3C7346
        dd 714, 153, 1, 1, 0xFF3C7346
        dd 981, 610, 1, 1, 0xFF3C7346
        dd 207, 193, 2, 1, 0xFF3C7346
        dd 618, 24, 1, 1, 0xFF5A9C70
        dd 471, 36, 2, 1, 0xFF3C7346
        dd 704, 718, 1, 1, 0xFF5A9C70
        dd 105, 701, 2, 1, 0xFF3C7346
        dd 875, 518, 2, 1, 0xFF3C7346
        dd 794, 401, 2, 1, 0xFF5A9C70
        dd 367, 526, 1, 1, 0xFF3C7346
        dd 551, 535, 2, 1, 0xFF5A9C70
        dd 24, 20, 1, 1, 0xFF3C7346
        dd 817, 167, 1, 1, 0xFF3C7346
        dd 156, 310, 1, 1, 0xFF3C7346
        dd 1049, 563, 2, 1, 0xFF5A9C70
        dd 678, 169, 1, 1, 0xFF3C7346
        dd 148, 281, 2, 1, 0xFF3C7346
        dd 639, 139, 1, 1, 0xFF3C7346
        dd 1047, 26, 2, 1, 0xFF3C7346
        dd 1121, 1, 2, 1, 0xFF5A9C70
        dd 622, 658, 2, 1, 0xFF5A9C70
        dd 163, 118, 2, 1, 0xFF3C7346
        dd 633, 69, 2, 1, 0xFF5A9C70
        dd 6, 494, 1, 1, 0xFF5A9C70
        dd 960, 581, 2, 1, 0xFF3C7346
        dd 92, 304, 2, 1, 0xFF3C7346
        dd 428, 3, 1, 1, 0xFF5A9C70
        dd 1208, 615, 2, 1, 0xFF3C7346
        dd 885, 124, 1, 1, 0xFF5A9C70
        dd 486, 28, 1, 1, 0xFF5A9C70
        dd 836, 33, 2, 1, 0xFF5A9C70
        dd 967, 148, 1, 1, 0xFF3C7346
        dd 34, 258, 1, 1, 0xFF5A9C70
        dd 1179, 693, 1, 1, 0xFF3C7346
        dd 810, 575, 2, 1, 0xFF3C7346
        dd 364, 700, 2, 1, 0xFF5A9C70
        dd 619, 0, 1, 1, 0xFF5A9C70
        dd 134, 180, 1, 1, 0xFF3C7346
        dd 1145, 421, 1, 1, 0xFF3C7346
        dd 659, 164, 1, 1, 0xFF5A9C70
        dd 10, 14, 2, 1, 0xFF5A9C70
        dd 1212, 672, 1, 1, 0xFF5A9C70
        dd 129, 198, 1, 1, 0xFF3C7346
        dd 977, 687, 1, 1, 0xFF5A9C70
        dd 888, 233, 1, 1, 0xFF3C7346
        dd 368, 224, 1, 1, 0xFF3C7346
        dd 873, 507, 2, 1, 0xFF3C7346
        dd 979, 499, 1, 1, 0xFF5A9C70
        dd 1271, 449, 2, 1, 0xFF3C7346
        dd 16, 698, 2, 1, 0xFF5A9C70
        dd 167, 99, 2, 1, 0xFF5A9C70
        dd 598, 20, 2, 1, 0xFF5A9C70
        dd 981, 651, 1, 1, 0xFF5A9C70
        dd 645, 172, 1, 1, 0xFF3C7346
        dd 883, 172, 2, 1, 0xFF5A9C70
        dd 723, 20, 1, 1, 0xFF3C7346
        dd 1216, 636, 1, 1, 0xFF3C7346
        dd 495, 402, 1, 1, 0xFF5A9C70
        dd 713, 191, 1, 1, 0xFF5A9C70
        dd 201, 7, 1, 1, 0xFF3C7346
        dd 736, 28, 1, 1, 0xFF3C7346
        dd 73, 709, 2, 1, 0xFF5A9C70
        dd 288, 12, 1, 1, 0xFF3C7346
        dd 105, 24, 2, 1, 0xFF3C7346
        dd 1000, 719, 1, 1, 0xFF3C7346
        dd 229, 51, 1, 1, 0xFF5A9C70
        dd 155, 47, 2, 1, 0xFF5A9C70
        dd 1221, 709, 1, 1, 0xFF5A9C70
        dd 550, 582, 1, 1, 0xFF5A9C70
        dd 282, 499, 1, 1, 0xFF3C7346
        dd 1260, 717, 2, 1, 0xFF5A9C70
        dd 271, 9, 1, 1, 0xFF3C7346
        dd 30, 18, 1, 1, 0xFF3C7346
        dd 805, 586, 1, 1, 0xFF3C7346
        dd 100, 713, 2, 1, 0xFF5A9C70
        dd 965, 280, 2, 1, 0xFF3C7346
        dd 965, 472, 1, 1, 0xFF3C7346
        dd 1157, 606, 2, 1, 0xFF3C7346
        dd 382, 131, 1, 1, 0xFF3C7346
        dd 1214, 603, 1, 1, 0xFF3C7346
        dd 1257, 512, 2, 1, 0xFF5A9C70
        dd 770, 407, 2, 1, 0xFF3C7346
        dd 1014, 555, 2, 1, 0xFF5A9C70
        dd 130, 239, 2, 1, 0xFF5A9C70
        dd 1113, 408, 2, 1, 0xFF5A9C70
        dd 880, 667, 1, 1, 0xFF3C7346
        dd 1208, 301, 1, 1, 0xFF5A9C70
        dd 386, 213, 1, 1, 0xFF3C7346
        dd 23, 479, 2, 1, 0xFF3C7346
        dd 536, 199, 2, 1, 0xFF3C7346
        dd 601, 39, 1, 1, 0xFF5A9C70
        dd 1136, 667, 2, 1, 0xFF5A9C70
        dd 488, 407, 1, 1, 0xFF5A9C70
        dd 826, 661, 2, 1, 0xFF5A9C70
        dd 277, 65, 1, 1, 0xFF3C7346
        dd 664, 27, 1, 1, 0xFF3C7346
        dd 1269, 405, 1, 1, 0xFF5A9C70
        dd 1064, 580, 1, 1, 0xFF3C7346
        dd 675, 185, 2, 1, 0xFF3C7346
        dd 90, 719, 2, 1, 0xFF3C7346
        dd 971, 443, 1, 1, 0xFF3C7346
        dd 1242, 118, 2, 1, 0xFF3C7346
        dd 767, 159, 2, 1, 0xFF5A9C70
        dd 1252, 308, 1, 1, 0xFF3C7346
        dd 1133, 664, 2, 1, 0xFF3C7346
        dd 859, 173, 2, 1, 0xFF5A9C70
        dd 1117, 6, 1, 1, 0xFF3C7346
        dd 270, 207, 2, 1, 0xFF5A9C70
        dd 703, 561, 2, 1, 0xFF3C7346
        dd 562, 37, 1, 1, 0xFF3C7346
        dd 695, 418, 2, 1, 0xFF5A9C70
        dd 232, 54, 2, 1, 0xFF5A9C70
        dd 873, 408, 2, 1, 0xFF3C7346
        dd 57, 317, 2, 1, 0xFF5A9C70
        dd 436, 587, 2, 1, 0xFF5A9C70
        dd 226, 403, 1, 1, 0xFF3C7346
        dd 390, 308, 1, 1, 0xFF3C7346
        dd 700, 167, 1, 1, 0xFF5A9C70
        dd 360, 315, 2, 1, 0xFF3C7346
        dd 982, 578, 1, 1, 0xFF3C7346
        dd 1005, 8, 2, 1, 0xFF5A9C70
        dd 374, 162, 1, 1, 0xFF3C7346
        dd 700, 157, 2, 1, 0xFF5A9C70
        dd 4, 228, 2, 1, 0xFF5A9C70
        dd 13, 501, 2, 1, 0xFF5A9C70
        dd 495, 701, 1, 1, 0xFF3C7346
        dd 984, 492, 2, 1, 0xFF3C7346
        dd 63, 153, 2, 1, 0xFF3C7346
        dd 962, 429, 2, 1, 0xFF3C7346
        dd 412, 653, 2, 1, 0xFF3C7346
        dd 170, 4, 1, 1, 0xFF3C7346
        dd 1085, 541, 1, 1, 0xFF5A9C70
        dd 542, 475, 2, 1, 0xFF3C7346
        dd 861, 19, 2, 1, 0xFF5A9C70
        dd 1129, 609, 1, 1, 0xFF5A9C70
        dd 872, 248, 2, 1, 0xFF5A9C70
        dd 13, 582, 1, 1, 0xFF5A9C70
        dd 15, 171, 2, 1, 0xFF3C7346
        dd 772, 581, 2, 1, 0xFF3C7346
        dd 370, 425, 1, 1, 0xFF3C7346
        dd 1273, 703, 2, 1, 0xFF5A9C70
        dd 13, 178, 1, 1, 0xFF5A9C70
        dd 172, 709, 2, 1, 0xFF3C7346
        dd 746, 164, 1, 1, 0xFF3C7346
        dd 369, 113, 1, 1, 0xFF3C7346
        dd 1272, 13, 2, 1, 0xFF5A9C70
        dd 443, 10, 1, 1, 0xFF3C7346
        dd 1274, 607, 1, 1, 0xFF5A9C70
        dd 1240, 608, 1, 1, 0xFF3C7346
        dd 127, 702, 1, 1, 0xFF5A9C70
        dd 286, 247, 2, 1, 0xFF5A9C70
        dd 875, 242, 2, 1, 0xFF3C7346
        dd 1102, 3, 1, 1, 0xFF3C7346
        dd 828, 144, 2, 1, 0xFF5A9C70
        dd 32, 146, 2, 1, 0xFF5A9C70
        dd 1138, 457, 2, 1, 0xFF3C7346
        dd 1111, 548, 2, 1, 0xFF5A9C70
        dd 572, 191, 2, 1, 0xFF5A9C70
        dd 18, 154, 2, 1, 0xFF5A9C70
        dd 140, 409, 1, 1, 0xFF5A9C70
        dd 16, 490, 2, 1, 0xFF3C7346
        dd 389, 241, 2, 1, 0xFF3C7346
        dd 1073, 2, 2, 1, 0xFF3C7346
        dd 149, 215, 1, 1, 0xFF3C7346
        dd 65, 159, 2, 1, 0xFF5A9C70
        dd 706, 528, 1, 1, 0xFF3C7346
        dd 482, 3, 2, 1, 0xFF3C7346
        dd 1103, 571, 1, 1, 0xFF5A9C70
        dd 731, 150, 2, 1, 0xFF5A9C70
        dd 395, 88, 2, 1, 0xFF5A9C70
        dd 986, 462, 2, 1, 0xFF3C7346
        dd 1201, 713, 1, 1, 0xFF5A9C70
        dd 407, 404, 1, 1, 0xFF3C7346
        dd 1252, 34, 1, 1, 0xFF5A9C70
        dd 1, 475, 2, 1, 0xFF3C7346
        dd 87, 5, 2, 1, 0xFF3C7346
        dd 1246, 151, 2, 1, 0xFF3C7346
        dd 267, 167, 1, 1, 0xFF3C7346
        dd 383, 214, 1, 1, 0xFF3C7346
        dd 639, 42, 2, 1, 0xFF3C7346
        dd 715, 401, 2, 1, 0xFF5A9C70
        dd 410, 188, 2, 1, 0xFF3C7346
        dd 1214, 407, 1, 1, 0xFF5A9C70
        dd 149, 402, 2, 1, 0xFF3C7346
        dd 879, 580, 1, 1, 0xFF5A9C70
        dd 1124, 669, 1, 1, 0xFF3C7346
        dd 406, 401, 2, 1, 0xFF5A9C70
        dd 547, 651, 2, 1, 0xFF5A9C70
        dd 672, 545, 1, 1, 0xFF3C7346
        dd 690, 179, 2, 1, 0xFF3C7346
        dd 31, 136, 2, 1, 0xFF5A9C70
        dd 1169, 23, 2, 1, 0xFF5A9C70
        dd 1255, 512, 1, 1, 0xFF5A9C70
        dd 1072, 22, 2, 1, 0xFF3C7346
        dd 980, 686, 2, 1, 0xFF5A9C70
        dd 1276, 577, 2, 1, 0xFF3C7346
        dd 1041, 582, 2, 1, 0xFF3C7346
        dd 976, 569, 2, 1, 0xFF3C7346
        dd 878, 535, 1, 1, 0xFF5A9C70
        dd 379, 121, 2, 1, 0xFF3C7346
        dd 1105, 552, 2, 1, 0xFF5A9C70
        dd 714, 483, 2, 1, 0xFF5A9C70
        dd 366, 462, 2, 1, 0xFF3C7346
        dd 123, 1, 1, 1, 0xFF5A9C70
        dd 406, 317, 1, 1, 0xFF3C7346
        dd 1228, 28, 2, 1, 0xFF3C7346
        dd 646, 156, 1, 1, 0xFF3C7346
        dd 874, 26, 1, 1, 0xFF3C7346
        dd 754, 5, 2, 1, 0xFF5A9C70
        dd 27, 68, 1, 1, 0xFF3C7346
        dd 1167, 424, 2, 1, 0xFF5A9C70
        dd 1261, 486, 2, 1, 0xFF5A9C70
        dd 127, 301, 1, 1, 0xFF3C7346
        dd 887, 545, 1, 1, 0xFF5A9C70
        dd 571, 194, 1, 1, 0xFF5A9C70
        dd 717, 172, 2, 1, 0xFF3C7346
        dd 861, 319, 2, 1, 0xFF3C7346
        dd 515, 575, 2, 1, 0xFF3C7346
        dd 37, 717, 1, 1, 0xFF3C7346
        dd 632, 78, 2, 1, 0xFF3C7346
        dd 1066, 540, 2, 1, 0xFF3C7346
        dd 175, 185, 2, 1, 0xFF5A9C70
        dd 378, 283, 1, 1, 0xFF3C7346
        dd 708, 156, 2, 1, 0xFF3C7346
        dd 811, 182, 1, 1, 0xFF3C7346
        dd 537, 31, 1, 1, 0xFF3C7346
        dd 470, 39, 2, 1, 0xFF3C7346
        dd 1208, 28, 1, 1, 0xFF5A9C70
        dd 283, 595, 1, 1, 0xFF3C7346
        dd 1264, 121, 2, 1, 0xFF5A9C70
        dd 882, 96, 2, 1, 0xFF3C7346
        dd 995, 17, 1, 1, 0xFF3C7346
        dd 971, 504, 2, 1, 0xFF5A9C70
        dd 965, 280, 2, 1, 0xFF5A9C70
        dd 281, 620, 2, 1, 0xFF5A9C70
        dd 140, 265, 1, 1, 0xFF3C7346
        dd 78, 19, 1, 1, 0xFF3C7346
        dd 1079, 10, 2, 1, 0xFF5A9C70
        dd 384, 195, 1, 1, 0xFF5A9C70
        dd 283, 122, 1, 1, 0xFF5A9C70
        dd 1253, 702, 2, 1, 0xFF5A9C70
        dd 1279, 305, 1, 1, 0xFF3C7346
        dd 208, 181, 1, 1, 0xFF3C7346
        dd 648, 512, 1, 1, 0xFF5A9C70
        dd 785, 18, 1, 1, 0xFF3C7346
        dd 1187, 719, 1, 1, 0xFF3C7346
        dd 368, 8, 2, 1, 0xFF3C7346
        dd 860, 154, 2, 1, 0xFF5A9C70
        dd 960, 668, 1, 1, 0xFF3C7346
        dd 1106, 20, 1, 1, 0xFF5A9C70
        dd 1062, 706, 1, 1, 0xFF5A9C70
        dd 550, 16, 1, 1, 0xFF3C7346
        dd 1146, 4, 1, 1, 0xFF5A9C70
        dd 971, 699, 1, 1, 0xFF3C7346
        dd 811, 17, 1, 1, 0xFF3C7346
        dd 370, 717, 1, 1, 0xFF3C7346
        dd 873, 31, 1, 1, 0xFF3C7346
        dd 1135, 430, 1, 1, 0xFF5A9C70
        dd 968, 596, 1, 1, 0xFF3C7346
        dd 1120, 409, 1, 1, 0xFF3C7346
        dd 974, 436, 1, 1, 0xFF5A9C70
        dd 1180, 591, 1, 1, 0xFF3C7346
        dd 754, 671, 1, 1, 0xFF3C7346
        dd 234, 166, 2, 1, 0xFF5A9C70
        dd 633, 701, 2, 1, 0xFF3C7346
        dd 196, 296, 2, 1, 0xFF3C7346
        dd 375, 300, 2, 1, 0xFF3C7346
        dd 1175, 686, 2, 1, 0xFF5A9C70
        dd 968, 553, 1, 1, 0xFF3C7346
        dd 1254, 412, 2, 1, 0xFF5A9C70
        dd 630, 26, 2, 1, 0xFF3C7346
        dd 399, 103, 2, 1, 0xFF3C7346
        dd 17, 252, 2, 1, 0xFF3C7346
        dd 1024, 418, 2, 1, 0xFF5A9C70
        dd 1051, 565, 2, 1, 0xFF5A9C70
        dd 134, 205, 2, 1, 0xFF3C7346
        dd 73, 156, 1, 1, 0xFF3C7346
        dd 1270, 314, 1, 1, 0xFF3C7346
        dd 386, 571, 2, 1, 0xFF3C7346
        dd 774, 319, 1, 1, 0xFF3C7346
        dd 434, 33, 2, 1, 0xFF3C7346
        dd 964, 518, 2, 1, 0xFF3C7346
        dd 885, 207, 1, 1, 0xFF5A9C70
        dd 182, 19, 1, 1, 0xFF3C7346
        dd 1148, 9, 2, 1, 0xFF5A9C70
        dd 531, 463, 1, 1, 0xFF3C7346
        dd 969, 18, 1, 1, 0xFF3C7346
        dd 582, 663, 2, 1, 0xFF3C7346
        dd 850, 151, 1, 1, 0xFF3C7346
        dd 21, 579, 1, 1, 0xFF5A9C70
        dd 3, 51, 2, 1, 0xFF3C7346
        dd 1233, 0, 2, 1, 0xFF5A9C70
        dd 1038, 544, 1, 1, 0xFF3C7346
        dd 284, 636, 2, 1, 0xFF3C7346
        dd 377, 433, 1, 1, 0xFF3C7346
        dd 1065, 308, 1, 1, 0xFF5A9C70
        dd 123, 23, 1, 1, 0xFF5A9C70
        dd 18, 606, 2, 1, 0xFF5A9C70
        dd 1267, 204, 1, 1, 0xFF5A9C70
        dd 519, 21, 2, 1, 0xFF5A9C70
        dd 150, 299, 2, 1, 0xFF3C7346
        dd 381, 207, 2, 1, 0xFF3C7346
        dd 1096, 553, 2, 1, 0xFF5A9C70
        dd 378, 5, 2, 1, 0xFF5A9C70
        dd 288, 251, 2, 1, 0xFF5A9C70
        dd 541, 514, 2, 1, 0xFF3C7346
        dd 145, 237, 2, 1, 0xFF5A9C70
        dd 20, 655, 1, 1, 0xFF5A9C70
        dd 802, 588, 1, 1, 0xFF3C7346
        dd 1243, 116, 2, 1, 0xFF3C7346
        dd 15, 505, 1, 1, 0xFF5A9C70
        dd 727, 570, 2, 1, 0xFF3C7346
        dd 970, 650, 1, 1, 0xFF3C7346
        dd 606, 653, 1, 1, 0xFF3C7346
        dd 1211, 625, 1, 1, 0xFF3C7346
        dd 770, 581, 1, 1, 0xFF3C7346
        dd 381, 237, 1, 1, 0xFF5A9C70
        dd 1216, 653, 2, 1, 0xFF3C7346
        dd 1123, 474, 1, 1, 0xFF5A9C70
        dd 981, 411, 2, 1, 0xFF3C7346
        dd 384, 49, 2, 1, 0xFF5A9C70
        dd 613, 153, 2, 1, 0xFF5A9C70
        dd 558, 531, 1, 1, 0xFF5A9C70
        dd 363, 573, 1, 1, 0xFF5A9C70
        dd 1254, 547, 2, 1, 0xFF3C7346
        dd 576, 556, 2, 1, 0xFF5A9C70
        dd 520, 572, 2, 1, 0xFF5A9C70
        dd 184, 18, 2, 1, 0xFF3C7346
        dd 846, 663, 2, 1, 0xFF5A9C70
        dd 1019, 401, 2, 1, 0xFF3C7346
        dd 582, 17, 2, 1, 0xFF3C7346
        dd 839, 189, 1, 1, 0xFF3C7346
        dd 119, 315, 2, 1, 0xFF3C7346
        dd 146, 27, 1, 1, 0xFF3C7346
        dd 623, 131, 1, 1, 0xFF5A9C70
        dd 231, 23, 1, 1, 0xFF3C7346
        dd 1217, 663, 2, 1, 0xFF5A9C70
        dd 223, 190, 2, 1, 0xFF3C7346
        dd 384, 581, 1, 1, 0xFF3C7346
        dd 750, 401, 2, 1, 0xFF3C7346
        dd 1199, 614, 2, 1, 0xFF3C7346
        dd 437, 404, 2, 1, 0xFF3C7346
        dd 538, 589, 2, 1, 0xFF3C7346
        dd 1204, 700, 2, 1, 0xFF5A9C70
        dd 243, 37, 1, 1, 0xFF3C7346
        dd 537, 23, 2, 1, 0xFF3C7346
        dd 146, 188, 2, 1, 0xFF5A9C70
        dd 960, 557, 1, 1, 0xFF3C7346
        dd 284, 97, 1, 1, 0xFF3C7346
        dd 14, 487, 2, 1, 0xFF3C7346
        dd 1267, 654, 1, 1, 0xFF3C7346
        dd 1264, 680, 2, 1, 0xFF3C7346
        dd 883, 658, 1, 1, 0xFF3C7346
        dd 831, 582, 1, 1, 0xFF5A9C70
        dd 151, 26, 2, 1, 0xFF5A9C70
        dd 1157, 15, 1, 1, 0xFF3C7346
        dd 629, 702, 2, 1, 0xFF3C7346
        dd 1120, 478, 1, 1, 0xFF3C7346
        dd 878, 424, 2, 1, 0xFF5A9C70
        dd 32, 401, 2, 1, 0xFF3C7346
        dd 798, 711, 2, 1, 0xFF3C7346
        dd 14, 33, 1, 1, 0xFF3C7346
        dd 425, 187, 1, 1, 0xFF5A9C70
        dd 58, 715, 2, 1, 0xFF5A9C70
        dd 603, 194, 1, 1, 0xFF5A9C70
        dd 274, 708, 2, 1, 0xFF3C7346
        dd 274, 77, 2, 1, 0xFF5A9C70
        dd 659, 718, 1, 1, 0xFF5A9C70
        dd 542, 400, 1, 1, 0xFF3C7346
        dd 64, 20, 1, 1, 0xFF3C7346
        dd 869, 5, 1, 1, 0xFF3C7346
        dd 13, 139, 2, 1, 0xFF5A9C70
        dd 714, 543, 2, 1, 0xFF3C7346
        dd 600, 575, 2, 1, 0xFF3C7346
        dd 1187, 653, 2, 1, 0xFF3C7346
        dd 55, 407, 1, 1, 0xFF3C7346
        dd 832, 661, 1, 1, 0xFF5A9C70
        dd 1116, 592, 1, 1, 0xFF5A9C70
        dd 480, 688, 1, 1, 0xFF3C7346
        dd 845, 167, 1, 1, 0xFF3C7346
        dd 1007, 543, 2, 1, 0xFF5A9C70
        dd 13, 685, 2, 1, 0xFF5A9C70
        dd 11, 462, 2, 1, 0xFF5A9C70
        dd 20, 432, 1, 1, 0xFF3C7346
        dd 865, 265, 2, 1, 0xFF5A9C70
        dd 24, 186, 2, 1, 0xFF3C7346
        dd 422, 1, 2, 1, 0xFF5A9C70
        dd 220, 151, 2, 1, 0xFF5A9C70
        dd 197, 700, 1, 1, 0xFF3C7346
        dd 1254, 118, 2, 1, 0xFF5A9C70
        dd 613, 123, 1, 1, 0xFF5A9C70
        dd 640, 316, 1, 1, 0xFF5A9C70
        dd 122, 16, 2, 1, 0xFF3C7346
        dd 1265, 310, 2, 1, 0xFF5A9C70
        dd 883, 467, 2, 1, 0xFF5A9C70
        dd 18, 485, 1, 1, 0xFF3C7346
        dd 1167, 21, 1, 1, 0xFF3C7346
        dd 18, 79, 1, 1, 0xFF3C7346
        dd 1096, 9, 1, 1, 0xFF5A9C70
        dd 286, 449, 1, 1, 0xFF3C7346
        dd 1, 301, 1, 1, 0xFF3C7346
        dd 461, 190, 2, 1, 0xFF5A9C70
        dd 993, 318, 2, 1, 0xFF5A9C70
        dd 777, 680, 2, 1, 0xFF3C7346
        dd 704, 491, 1, 1, 0xFF3C7346
        dd 645, 121, 2, 1, 0xFF3C7346
        dd 28, 624, 2, 1, 0xFF5A9C70
        dd 764, 664, 1, 1, 0xFF3C7346
        dd 582, 14, 1, 1, 0xFF5A9C70
        dd 264, 707, 2, 1, 0xFF3C7346
        dd 47, 154, 1, 1, 0xFF5A9C70
        dd 364, 316, 1, 1, 0xFF3C7346
        dd 834, 178, 2, 1, 0xFF3C7346
        dd 1051, 429, 1, 1, 0xFF5A9C70
        dd 6, 602, 2, 1, 0xFF3C7346
        dd 649, 681, 1, 1, 0xFF5A9C70
        dd 135, 274, 2, 1, 0xFF5A9C70
        dd 885, 21, 1, 1, 0xFF5A9C70
        dd 418, 651, 2, 1, 0xFF5A9C70
        dd 1279, 519, 2, 1, 0xFF3C7346
        dd 127, 407, 1, 1, 0xFF5A9C70
        dd 1127, 439, 1, 1, 0xFF5A9C70
        dd 695, 471, 2, 1, 0xFF3C7346
        dd 405, 582, 2, 1, 0xFF3C7346
        dd 280, 686, 1, 1, 0xFF5A9C70
        dd 1119, 536, 1, 1, 0xFF5A9C70
        dd 1123, 472, 1, 1, 0xFF5A9C70
        dd 581, 197, 2, 1, 0xFF5A9C70
        dd 547, 419, 2, 1, 0xFF5A9C70
        dd 133, 294, 2, 1, 0xFF3C7346
        dd 768, 657, 2, 1, 0xFF3C7346
        dd 639, 162, 2, 1, 0xFF3C7346
        dd 605, 88, 1, 1, 0xFF3C7346
        dd 682, 14, 1, 1, 0xFF5A9C70
        dd 776, 701, 1, 1, 0xFF3C7346
        dd 33, 400, 1, 1, 0xFF3C7346
        dd 600, 34, 2, 1, 0xFF3C7346
        dd 21, 527, 2, 1, 0xFF5A9C70
        dd 5, 125, 1, 1, 0xFF5A9C70
        dd 368, 531, 1, 1, 0xFF5A9C70
        dd 1025, 1, 2, 1, 0xFF3C7346
        dd 50, 710, 1, 1, 0xFF5A9C70
        dd 132, 229, 1, 1, 0xFF3C7346
        dd 288, 403, 2, 1, 0xFF3C7346
        dd 282, 0, 1, 1, 0xFF3C7346
        dd 1193, 680, 1, 1, 0xFF3C7346
        dd 849, 149, 2, 1, 0xFF3C7346
        dd 594, 587, 1, 1, 0xFF5A9C70
        dd 615, 132, 2, 1, 0xFF3C7346
        dd 880, 672, 2, 1, 0xFF3C7346
        dd 1271, 539, 2, 1, 0xFF5A9C70
        dd 531, 455, 1, 1, 0xFF3C7346
        dd 1264, 173, 2, 1, 0xFF5A9C70
        dd 286, 102, 2, 1, 0xFF3C7346
        dd 670, 525, 1, 1, 0xFF5A9C70
        dd 361, 295, 2, 1, 0xFF3C7346
        dd 381, 34, 2, 1, 0xFF3C7346
        dd 1264, 115, 2, 1, 0xFF3C7346
        dd 774, 679, 1, 1, 0xFF3C7346
        dd 1191, 301, 2, 1, 0xFF5A9C70
        dd 50, 21, 1, 1, 0xFF5A9C70
        dd 749, 158, 1, 1, 0xFF5A9C70
        dd 163, 102, 2, 1, 0xFF5A9C70
        dd 1113, 462, 1, 1, 0xFF5A9C70
        dd 1263, 165, 1, 1, 0xFF3C7346
        dd 671, 661, 2, 1, 0xFF3C7346
        dd 1253, 121, 1, 1, 0xFF5A9C70
        dd 871, 407, 2, 1, 0xFF3C7346
        dd 15, 152, 1, 1, 0xFF3C7346
        dd 380, 199, 1, 1, 0xFF3C7346
        dd 383, 581, 1, 1, 0xFF3C7346
        dd 1216, 619, 2, 1, 0xFF3C7346
        dd 571, 545, 1, 1, 0xFF5A9C70
        dd 33, 102, 2, 1, 0xFF5A9C70
        dd 199, 11, 1, 1, 0xFF3C7346
        dd 1248, 141, 2, 1, 0xFF3C7346
        dd 193, 53, 1, 1, 0xFF3C7346
        dd 726, 7, 2, 1, 0xFF3C7346
        dd 576, 570, 2, 1, 0xFF3C7346
        dd 76, 319, 2, 1, 0xFF3C7346
        dd 1270, 165, 1, 1, 0xFF3C7346
        dd 715, 567, 1, 1, 0xFF5A9C70
        dd 495, 572, 1, 1, 0xFF5A9C70
        dd 4, 163, 2, 1, 0xFF5A9C70
        dd 260, 6, 2, 1, 0xFF5A9C70
        dd 567, 523, 1, 1, 0xFF3C7346
        dd 57, 715, 1, 1, 0xFF5A9C70
        dd 968, 642, 1, 1, 0xFF3C7346
        dd 612, 77, 1, 1, 0xFF5A9C70
        dd 683, 22, 1, 1, 0xFF3C7346
        dd 60, 168, 1, 1, 0xFF5A9C70
        dd 169, 295, 2, 1, 0xFF3C7346
        dd 616, 44, 2, 1, 0xFF5A9C70
        dd 573, 719, 1, 1, 0xFF5A9C70
        dd 1081, 578, 1, 1, 0xFF3C7346
        dd 1267, 309, 1, 1, 0xFF3C7346
        dd 424, 5, 2, 1, 0xFF5A9C70
        dd 197, 709, 2, 1, 0xFF3C7346
        dd 1234, 425, 1, 1, 0xFF5A9C70
        dd 764, 145, 2, 1, 0xFF3C7346
        dd 268, 11, 1, 1, 0xFF3C7346
        dd 658, 525, 1, 1, 0xFF3C7346
        dd 15, 202, 2, 1, 0xFF5A9C70
        dd 1055, 419, 1, 1, 0xFF3C7346
        dd 1038, 427, 2, 1, 0xFF3C7346
        dd 669, 570, 1, 1, 0xFF5A9C70
        dd 23, 169, 2, 1, 0xFF3C7346
        dd 648, 113, 1, 1, 0xFF3C7346
        dd 867, 13, 2, 1, 0xFF5A9C70
        dd 1247, 112, 1, 1, 0xFF5A9C70
        dd 618, 29, 2, 1, 0xFF3C7346
        dd 1185, 633, 1, 1, 0xFF5A9C70
        dd 382, 6, 2, 1, 0xFF3C7346
        dd 1258, 542, 2, 1, 0xFF5A9C70
        dd 572, 586, 1, 1, 0xFF3C7346
        dd 1267, 60, 1, 1, 0xFF5A9C70
        dd 1095, 559, 1, 1, 0xFF3C7346
        dd 134, 304, 1, 1, 0xFF3C7346
        dd 161, 67, 2, 1, 0xFF5A9C70
        dd 0, 77, 2, 1, 0xFF3C7346
        dd 879, 457, 1, 1, 0xFF3C7346
        dd 543, 512, 2, 1, 0xFF5A9C70
        dd 813, 39, 2, 1, 0xFF3C7346
        dd 415, 417, 1, 1, 0xFF3C7346
        dd 365, 34, 2, 1, 0xFF3C7346
        dd 376, 302, 1, 1, 0xFF3C7346
        dd 1138, 541, 1, 1, 0xFF3C7346
        dd 237, 178, 2, 1, 0xFF5A9C70
        dd 248, 44, 1, 1, 0xFF3C7346
        dd 361, 449, 2, 1, 0xFF3C7346
        dd 1173, 611, 2, 1, 0xFF3C7346
        dd 780, 159, 1, 1, 0xFF5A9C70
        dd 1074, 695, 2, 1, 0xFF3C7346
        dd 133, 301, 1, 1, 0xFF3C7346
        dd 1273, 45, 2, 1, 0xFF3C7346
        dd 234, 28, 2, 1, 0xFF5A9C70
        dd 140, 15, 2, 1, 0xFF3C7346
        dd 858, 2, 1, 1, 0xFF3C7346
        dd 32, 158, 2, 1, 0xFF3C7346
        dd 706, 586, 1, 1, 0xFF3C7346
        dd 1232, 18, 2, 1, 0xFF3C7346
        dd 1258, 319, 2, 1, 0xFF5A9C70
        dd 715, 25, 2, 1, 0xFF5A9C70
        dd 1112, 609, 2, 1, 0xFF5A9C70
        dd 588, 654, 2, 1, 0xFF3C7346
        dd 1106, 580, 1, 1, 0xFF3C7346
        dd 1170, 302, 2, 1, 0xFF3C7346
        dd 998, 300, 1, 1, 0xFF5A9C70
        dd 570, 577, 2, 1, 0xFF5A9C70
        dd 885, 19, 2, 1, 0xFF3C7346
        dd 535, 532, 1, 1, 0xFF5A9C70
        dd 125, 18, 2, 1, 0xFF3C7346
        dd 1275, 54, 2, 1, 0xFF3C7346
        dd 360, 308, 2, 1, 0xFF5A9C70
        dd 647, 693, 1, 1, 0xFF5A9C70
        dd 571, 190, 1, 1, 0xFF3C7346
        dd 874, 127, 2, 1, 0xFF3C7346
        dd 660, 181, 2, 1, 0xFF5A9C70
        dd 821, 659, 1, 1, 0xFF3C7346
        dd 665, 526, 2, 1, 0xFF5A9C70
        dd 514, 664, 1, 1, 0xFF5A9C70
        dd 6, 82, 2, 1, 0xFF3C7346
        dd 879, 244, 2, 1, 0xFF5A9C70
        dd 688, 493, 2, 1, 0xFF5A9C70
        dd 889, 92, 1, 1, 0xFF5A9C70
        dd 162, 173, 1, 1, 0xFF3C7346
        dd 1254, 496, 2, 1, 0xFF3C7346
        dd 37, 69, 1, 1, 0xFF3C7346
        dd 710, 482, 2, 1, 0xFF3C7346
        dd 287, 664, 1, 1, 0xFF3C7346
        dd 0, 320, 1300, 80, 0xFFA5AAAA
        dd 290, 0, 70, 740, 0xFFA5AAAA
        dd 890, 0, 70, 740, 0xFFA5AAAA
        dd 340, 590, 570, 60, 0xFFA5AAAA
        dd 20, 320, 1, 80, 0xFF929696
        dd 40, 320, 1, 80, 0xFF929696
        dd 60, 320, 1, 80, 0xFF929696
        dd 80, 320, 1, 80, 0xFF929696
        dd 100, 320, 1, 80, 0xFF929696
        dd 120, 320, 1, 80, 0xFF929696
        dd 140, 320, 1, 80, 0xFF929696
        dd 160, 320, 1, 80, 0xFF929696
        dd 180, 320, 1, 80, 0xFF929696
        dd 200, 320, 1, 80, 0xFF929696
        dd 220, 320, 1, 80, 0xFF929696
        dd 240, 320, 1, 80, 0xFF929696
        dd 260, 320, 1, 80, 0xFF929696
        dd 280, 320, 1, 80, 0xFF929696
        dd 300, 320, 1, 80, 0xFF929696
        dd 320, 320, 1, 80, 0xFF929696
        dd 340, 320, 1, 80, 0xFF929696
        dd 360, 320, 1, 80, 0xFF929696
        dd 380, 320, 1, 80, 0xFF929696
        dd 400, 320, 1, 80, 0xFF929696
        dd 420, 320, 1, 80, 0xFF929696
        dd 440, 320, 1, 80, 0xFF929696
        dd 460, 320, 1, 80, 0xFF929696
        dd 480, 320, 1, 80, 0xFF929696
        dd 500, 320, 1, 80, 0xFF929696
        dd 520, 320, 1, 80, 0xFF929696
        dd 540, 320, 1, 80, 0xFF929696
        dd 560, 320, 1, 80, 0xFF929696
        dd 580, 320, 1, 80, 0xFF929696
        dd 600, 320, 1, 80, 0xFF929696
        dd 620, 320, 1, 80, 0xFF929696
        dd 640, 320, 1, 80, 0xFF929696
        dd 660, 320, 1, 80, 0xFF929696
        dd 680, 320, 1, 80, 0xFF929696
        dd 700, 320, 1, 80, 0xFF929696
        dd 720, 320, 1, 80, 0xFF929696
        dd 740, 320, 1, 80, 0xFF929696
        dd 760, 320, 1, 80, 0xFF929696
        dd 780, 320, 1, 80, 0xFF929696
        dd 800, 320, 1, 80, 0xFF929696
        dd 820, 320, 1, 80, 0xFF929696
        dd 840, 320, 1, 80, 0xFF929696
        dd 860, 320, 1, 80, 0xFF929696
        dd 880, 320, 1, 80, 0xFF929696
        dd 900, 320, 1, 80, 0xFF929696
        dd 920, 320, 1, 80, 0xFF929696
        dd 940, 320, 1, 80, 0xFF929696
        dd 960, 320, 1, 80, 0xFF929696
        dd 980, 320, 1, 80, 0xFF929696
        dd 1000, 320, 1, 80, 0xFF929696
        dd 1020, 320, 1, 80, 0xFF929696
        dd 1040, 320, 1, 80, 0xFF929696
        dd 1060, 320, 1, 80, 0xFF929696
        dd 1080, 320, 1, 80, 0xFF929696
        dd 1100, 320, 1, 80, 0xFF929696
        dd 1120, 320, 1, 80, 0xFF929696
        dd 1140, 320, 1, 80, 0xFF929696
        dd 1160, 320, 1, 80, 0xFF929696
        dd 1180, 320, 1, 80, 0xFF929696
        dd 1200, 320, 1, 80, 0xFF929696
        dd 1220, 320, 1, 80, 0xFF929696
        dd 1240, 320, 1, 80, 0xFF929696
        dd 1260, 320, 1, 80, 0xFF929696
        dd 1280, 320, 1, 80, 0xFF929696
        dd 290, 20, 70, 1, 0xFF929696
        dd 290, 40, 70, 1, 0xFF929696
        dd 290, 60, 70, 1, 0xFF929696
        dd 290, 80, 70, 1, 0xFF929696
        dd 290, 100, 70, 1, 0xFF929696
        dd 290, 120, 70, 1, 0xFF929696
        dd 290, 140, 70, 1, 0xFF929696
        dd 290, 160, 70, 1, 0xFF929696
        dd 290, 180, 70, 1, 0xFF929696
        dd 290, 200, 70, 1, 0xFF929696
        dd 290, 220, 70, 1, 0xFF929696
        dd 290, 240, 70, 1, 0xFF929696
        dd 290, 260, 70, 1, 0xFF929696
        dd 290, 280, 70, 1, 0xFF929696
        dd 290, 300, 70, 1, 0xFF929696
        dd 290, 320, 70, 1, 0xFF929696
        dd 290, 340, 70, 1, 0xFF929696
        dd 290, 360, 70, 1, 0xFF929696
        dd 290, 380, 70, 1, 0xFF929696
        dd 290, 400, 70, 1, 0xFF929696
        dd 290, 420, 70, 1, 0xFF929696
        dd 290, 440, 70, 1, 0xFF929696
        dd 290, 460, 70, 1, 0xFF929696
        dd 290, 480, 70, 1, 0xFF929696
        dd 290, 500, 70, 1, 0xFF929696
        dd 290, 520, 70, 1, 0xFF929696
        dd 290, 540, 70, 1, 0xFF929696
        dd 290, 560, 70, 1, 0xFF929696
        dd 290, 580, 70, 1, 0xFF929696
        dd 290, 600, 70, 1, 0xFF929696
        dd 290, 620, 70, 1, 0xFF929696
        dd 290, 640, 70, 1, 0xFF929696
        dd 290, 660, 70, 1, 0xFF929696
        dd 290, 680, 70, 1, 0xFF929696
        dd 290, 700, 70, 1, 0xFF929696
        dd 290, 720, 70, 1, 0xFF929696
        dd 890, 20, 70, 1, 0xFF929696
        dd 890, 40, 70, 1, 0xFF929696
        dd 890, 60, 70, 1, 0xFF929696
        dd 890, 80, 70, 1, 0xFF929696
        dd 890, 100, 70, 1, 0xFF929696
        dd 890, 120, 70, 1, 0xFF929696
        dd 890, 140, 70, 1, 0xFF929696
        dd 890, 160, 70, 1, 0xFF929696
        dd 890, 180, 70, 1, 0xFF929696
        dd 890, 200, 70, 1, 0xFF929696
        dd 890, 220, 70, 1, 0xFF929696
        dd 890, 240, 70, 1, 0xFF929696
        dd 890, 260, 70, 1, 0xFF929696
        dd 890, 280, 70, 1, 0xFF929696
        dd 890, 300, 70, 1, 0xFF929696
        dd 890, 320, 70, 1, 0xFF929696
        dd 890, 340, 70, 1, 0xFF929696
        dd 890, 360, 70, 1, 0xFF929696
        dd 890, 380, 70, 1, 0xFF929696
        dd 890, 400, 70, 1, 0xFF929696
        dd 890, 420, 70, 1, 0xFF929696
        dd 890, 440, 70, 1, 0xFF929696
        dd 890, 460, 70, 1, 0xFF929696
        dd 890, 480, 70, 1, 0xFF929696
        dd 890, 500, 70, 1, 0xFF929696
        dd 890, 520, 70, 1, 0xFF929696
        dd 890, 540, 70, 1, 0xFF929696
        dd 890, 560, 70, 1, 0xFF929696
        dd 890, 580, 70, 1, 0xFF929696
        dd 890, 600, 70, 1, 0xFF929696
        dd 890, 620, 70, 1, 0xFF929696
        dd 890, 640, 70, 1, 0xFF929696
        dd 890, 660, 70, 1, 0xFF929696
        dd 890, 680, 70, 1, 0xFF929696
        dd 890, 700, 70, 1, 0xFF929696
        dd 890, 720, 70, 1, 0xFF929696
        dd 360, 590, 1, 60, 0xFF929696
        dd 380, 590, 1, 60, 0xFF929696
        dd 400, 590, 1, 60, 0xFF929696
        dd 420, 590, 1, 60, 0xFF929696
        dd 440, 590, 1, 60, 0xFF929696
        dd 460, 590, 1, 60, 0xFF929696
        dd 480, 590, 1, 60, 0xFF929696
        dd 500, 590, 1, 60, 0xFF929696
        dd 520, 590, 1, 60, 0xFF929696
        dd 540, 590, 1, 60, 0xFF929696
        dd 560, 590, 1, 60, 0xFF929696
        dd 580, 590, 1, 60, 0xFF929696
        dd 600, 590, 1, 60, 0xFF929696
        dd 620, 590, 1, 60, 0xFF929696
        dd 640, 590, 1, 60, 0xFF929696
        dd 660, 590, 1, 60, 0xFF929696
        dd 680, 590, 1, 60, 0xFF929696
        dd 700, 590, 1, 60, 0xFF929696
        dd 720, 590, 1, 60, 0xFF929696
        dd 740, 590, 1, 60, 0xFF929696
        dd 760, 590, 1, 60, 0xFF929696
        dd 780, 590, 1, 60, 0xFF929696
        dd 800, 590, 1, 60, 0xFF929696
        dd 820, 590, 1, 60, 0xFF929696
        dd 840, 590, 1, 60, 0xFF929696
        dd 860, 590, 1, 60, 0xFF929696
        dd 880, 590, 1, 60, 0xFF929696
        dd 900, 590, 1, 60, 0xFF929696
        dd 0, 330, 1280, 60, 0xFF403C3C
        dd 300, 0, 50, 720, 0xFF403C3C
        dd 900, 0, 50, 720, 0xFF403C3C
        dd 350, 600, 550, 40, 0xFF403C3C
        dd 395, 200, 470, 115, 0xFF545050
        dd 934, 286, 1, 1, 0xFF363232
        dd 220, 377, 1, 1, 0xFF4C4848
        dd 314, 295, 1, 1, 0xFF363232
        dd 339, 26, 1, 1, 0xFF4C4848
        dd 540, 388, 1, 1, 0xFF4C4848
        dd 484, 331, 1, 1, 0xFF363232
        dd 933, 205, 1, 1, 0xFF4C4848
        dd 644, 639, 1, 1, 0xFF363232
        dd 315, 621, 1, 1, 0xFF4C4848
        dd 932, 61, 1, 1, 0xFF363232
        dd 768, 372, 1, 1, 0xFF4C4848
        dd 584, 253, 1, 1, 0xFF363232
        dd 545, 289, 1, 1, 0xFF363232
        dd 837, 235, 1, 1, 0xFF4C4848
        dd 594, 352, 1, 1, 0xFF363232
        dd 2, 336, 1, 1, 0xFF4C4848
        dd 860, 308, 1, 1, 0xFF4C4848
        dd 888, 620, 1, 1, 0xFF4C4848
        dd 341, 391, 1, 1, 0xFF363232
        dd 537, 252, 1, 1, 0xFF4C4848
        dd 489, 244, 1, 1, 0xFF363232
        dd 685, 368, 1, 1, 0xFF4C4848
        dd 630, 355, 1, 1, 0xFF4C4848
        dd 342, 670, 1, 1, 0xFF4C4848
        dd 934, 498, 1, 1, 0xFF363232
        dd 957, 364, 1, 1, 0xFF363232
        dd 470, 239, 1, 1, 0xFF363232
        dd 914, 188, 1, 1, 0xFF363232
        dd 151, 361, 1, 1, 0xFF4C4848
        dd 934, 553, 1, 1, 0xFF4C4848
        dd 925, 455, 1, 1, 0xFF4C4848
        dd 902, 484, 1, 1, 0xFF4C4848
        dd 947, 86, 1, 1, 0xFF4C4848
        dd 344, 376, 1, 1, 0xFF4C4848
        dd 306, 683, 1, 1, 0xFF363232
        dd 652, 367, 1, 1, 0xFF363232
        dd 288, 383, 1, 1, 0xFF4C4848
        dd 321, 583, 1, 1, 0xFF4C4848
        dd 911, 177, 1, 1, 0xFF4C4848
        dd 931, 509, 1, 1, 0xFF4C4848
        dd 398, 633, 1, 1, 0xFF4C4848
        dd 651, 257, 1, 1, 0xFF4C4848
        dd 145, 378, 1, 1, 0xFF4C4848
        dd 1020, 345, 1, 1, 0xFF4C4848
        dd 698, 237, 1, 1, 0xFF4C4848
        dd 1155, 367, 1, 1, 0xFF4C4848
        dd 686, 294, 1, 1, 0xFF363232
        dd 964, 330, 1, 1, 0xFF363232
        dd 662, 639, 1, 1, 0xFF363232
        dd 1129, 382, 1, 1, 0xFF363232
        dd 1109, 334, 1, 1, 0xFF4C4848
        dd 617, 278, 1, 1, 0xFF363232
        dd 540, 301, 1, 1, 0xFF363232
        dd 437, 242, 1, 1, 0xFF363232
        dd 989, 333, 1, 1, 0xFF4C4848
        dd 396, 205, 1, 1, 0xFF363232
        dd 319, 411, 1, 1, 0xFF4C4848
        dd 529, 358, 1, 1, 0xFF4C4848
        dd 317, 618, 1, 1, 0xFF363232
        dd 389, 624, 1, 1, 0xFF363232
        dd 405, 369, 1, 1, 0xFF363232
        dd 616, 611, 1, 1, 0xFF4C4848
        dd 588, 210, 1, 1, 0xFF363232
        dd 770, 373, 1, 1, 0xFF363232
        dd 925, 110, 1, 1, 0xFF4C4848
        dd 319, 160, 1, 1, 0xFF363232
        dd 705, 374, 1, 1, 0xFF4C4848
        dd 643, 280, 1, 1, 0xFF4C4848
        dd 668, 201, 1, 1, 0xFF4C4848
        dd 569, 217, 1, 1, 0xFF363232
        dd 648, 202, 1, 1, 0xFF4C4848
        dd 468, 609, 1, 1, 0xFF4C4848
        dd 722, 362, 1, 1, 0xFF4C4848
        dd 320, 615, 1, 1, 0xFF363232
        dd 898, 625, 1, 1, 0xFF363232
        dd 922, 321, 1, 1, 0xFF363232
        dd 826, 241, 1, 1, 0xFF4C4848
        dd 568, 219, 1, 1, 0xFF4C4848
        dd 480, 343, 1, 1, 0xFF4C4848
        dd 655, 370, 1, 1, 0xFF363232
        dd 819, 313, 1, 1, 0xFF4C4848
        dd 762, 202, 1, 1, 0xFF363232
        dd 350, 348, 1, 1, 0xFF363232
        dd 931, 707, 1, 1, 0xFF4C4848
        dd 540, 369, 1, 1, 0xFF363232
        dd 472, 253, 1, 1, 0xFF363232
        dd 1090, 365, 1, 1, 0xFF363232
        dd 1020, 370, 1, 1, 0xFF363232
        dd 735, 333, 1, 1, 0xFF4C4848
        dd 319, 654, 1, 1, 0xFF4C4848
        dd 35, 331, 1, 1, 0xFF363232
        dd 902, 279, 1, 1, 0xFF363232
        dd 790, 225, 1, 1, 0xFF4C4848
        dd 722, 291, 1, 1, 0xFF363232
        dd 1196, 366, 1, 1, 0xFF363232
        dd 907, 395, 1, 1, 0xFF4C4848
        dd 305, 326, 1, 1, 0xFF4C4848
        dd 594, 232, 1, 1, 0xFF363232
        dd 919, 645, 1, 1, 0xFF4C4848
        dd 1109, 389, 1, 1, 0xFF4C4848
        dd 332, 288, 1, 1, 0xFF4C4848
        dd 10, 355, 1, 1, 0xFF363232
        dd 332, 599, 1, 1, 0xFF363232
        dd 79, 380, 1, 1, 0xFF363232
        dd 615, 337, 1, 1, 0xFF4C4848
        dd 945, 562, 1, 1, 0xFF363232
        dd 1208, 353, 1, 1, 0xFF363232
        dd 527, 303, 1, 1, 0xFF4C4848
        dd 944, 183, 1, 1, 0xFF4C4848
        dd 788, 275, 1, 1, 0xFF4C4848
        dd 911, 463, 1, 1, 0xFF4C4848
        dd 990, 383, 1, 1, 0xFF363232
        dd 582, 276, 1, 1, 0xFF4C4848
        dd 842, 206, 1, 1, 0xFF363232
        dd 606, 286, 1, 1, 0xFF363232
        dd 1269, 370, 1, 1, 0xFF4C4848
        dd 927, 286, 1, 1, 0xFF363232
        dd 814, 623, 1, 1, 0xFF4C4848
        dd 337, 568, 1, 1, 0xFF4C4848
        dd 547, 261, 1, 1, 0xFF363232
        dd 343, 622, 1, 1, 0xFF363232
        dd 123, 381, 1, 1, 0xFF4C4848
        dd 616, 377, 1, 1, 0xFF4C4848
        dd 701, 611, 1, 1, 0xFF363232
        dd 376, 361, 1, 1, 0xFF363232
        dd 212, 352, 1, 1, 0xFF363232
        dd 742, 240, 1, 1, 0xFF4C4848
        dd 332, 515, 1, 1, 0xFF4C4848
        dd 337, 277, 1, 1, 0xFF4C4848
        dd 154, 365, 1, 1, 0xFF363232
        dd 917, 60, 1, 1, 0xFF363232
        dd 693, 262, 1, 1, 0xFF4C4848
        dd 935, 421, 1, 1, 0xFF4C4848
        dd 457, 208, 1, 1, 0xFF363232
        dd 697, 307, 1, 1, 0xFF4C4848
        dd 305, 614, 1, 1, 0xFF363232
        dd 1257, 341, 1, 1, 0xFF363232
        dd 347, 286, 1, 1, 0xFF4C4848
        dd 1006, 382, 1, 1, 0xFF363232
        dd 12, 341, 1, 1, 0xFF4C4848
        dd 793, 347, 1, 1, 0xFF363232
        dd 478, 207, 1, 1, 0xFF4C4848
        dd 1239, 344, 1, 1, 0xFF363232
        dd 640, 626, 1, 1, 0xFF363232
        dd 511, 288, 1, 1, 0xFF4C4848
        dd 260, 374, 1, 1, 0xFF4C4848
        dd 778, 231, 1, 1, 0xFF4C4848
        dd 855, 604, 1, 1, 0xFF363232
        dd 17, 350, 1, 1, 0xFF4C4848
        dd 493, 273, 1, 1, 0xFF363232
        dd 601, 249, 1, 1, 0xFF363232
        dd 759, 253, 1, 1, 0xFF4C4848
        dd 296, 343, 1, 1, 0xFF363232
        dd 913, 664, 1, 1, 0xFF363232
        dd 331, 447, 1, 1, 0xFF4C4848
        dd 631, 222, 1, 1, 0xFF4C4848
        dd 1021, 387, 1, 1, 0xFF363232
        dd 936, 539, 1, 1, 0xFF4C4848
        dd 567, 253, 1, 1, 0xFF363232
        dd 162, 363, 1, 1, 0xFF363232
        dd 617, 621, 1, 1, 0xFF363232
        dd 467, 343, 1, 1, 0xFF4C4848
        dd 336, 70, 1, 1, 0xFF4C4848
        dd 524, 384, 1, 1, 0xFF4C4848
        dd 347, 412, 1, 1, 0xFF363232
        dd 917, 214, 1, 1, 0xFF363232
        dd 331, 632, 1, 1, 0xFF363232
        dd 368, 366, 1, 1, 0xFF363232
        dd 478, 349, 1, 1, 0xFF363232
        dd 623, 637, 1, 1, 0xFF4C4848
        dd 933, 463, 1, 1, 0xFF363232
        dd 317, 495, 1, 1, 0xFF363232
        dd 492, 261, 1, 1, 0xFF4C4848
        dd 924, 342, 1, 1, 0xFF363232
        dd 907, 334, 1, 1, 0xFF363232
        dd 932, 412, 1, 1, 0xFF4C4848
        dd 588, 634, 1, 1, 0xFF363232
        dd 366, 389, 1, 1, 0xFF363232
        dd 537, 383, 1, 1, 0xFF363232
        dd 849, 223, 1, 1, 0xFF363232
        dd 823, 624, 1, 1, 0xFF363232
        dd 684, 366, 1, 1, 0xFF363232
        dd 1155, 358, 1, 1, 0xFF4C4848
        dd 823, 269, 1, 1, 0xFF363232
        dd 456, 287, 1, 1, 0xFF363232
        dd 437, 379, 1, 1, 0xFF363232
        dd 885, 631, 1, 1, 0xFF4C4848
        dd 1068, 388, 1, 1, 0xFF4C4848
        dd 825, 625, 1, 1, 0xFF4C4848
        dd 9, 351, 1, 1, 0xFF363232
        dd 919, 101, 1, 1, 0xFF363232
        dd 908, 85, 1, 1, 0xFF363232
        dd 823, 625, 1, 1, 0xFF4C4848
        dd 91, 364, 1, 1, 0xFF4C4848
        dd 533, 260, 1, 1, 0xFF4C4848
        dd 927, 684, 1, 1, 0xFF4C4848
        dd 341, 184, 1, 1, 0xFF4C4848
        dd 337, 697, 1, 1, 0xFF4C4848
        dd 589, 633, 1, 1, 0xFF363232
        dd 827, 265, 1, 1, 0xFF4C4848
        dd 809, 202, 1, 1, 0xFF363232
        dd 536, 222, 1, 1, 0xFF4C4848
        dd 806, 357, 1, 1, 0xFF4C4848
        dd 338, 73, 1, 1, 0xFF363232
        dd 906, 550, 1, 1, 0xFF363232
        dd 102, 341, 1, 1, 0xFF4C4848
        dd 926, 343, 1, 1, 0xFF4C4848
        dd 647, 304, 1, 1, 0xFF363232
        dd 609, 355, 1, 1, 0xFF4C4848
        dd 521, 234, 1, 1, 0xFF363232
        dd 929, 182, 1, 1, 0xFF4C4848
        dd 807, 334, 1, 1, 0xFF4C4848
        dd 520, 345, 1, 1, 0xFF4C4848
        dd 314, 692, 1, 1, 0xFF363232
        dd 444, 610, 1, 1, 0xFF363232
        dd 197, 349, 1, 1, 0xFF4C4848
        dd 574, 244, 1, 1, 0xFF4C4848
        dd 490, 602, 1, 1, 0xFF4C4848
        dd 554, 627, 1, 1, 0xFF363232
        dd 339, 277, 1, 1, 0xFF4C4848
        dd 340, 44, 1, 1, 0xFF4C4848
        dd 534, 602, 1, 1, 0xFF4C4848
        dd 601, 375, 1, 1, 0xFF4C4848
        dd 1133, 332, 1, 1, 0xFF4C4848
        dd 907, 11, 1, 1, 0xFF363232
        dd 1067, 331, 1, 1, 0xFF4C4848
        dd 626, 211, 1, 1, 0xFF4C4848
        dd 334, 381, 1, 1, 0xFF4C4848
        dd 705, 604, 1, 1, 0xFF4C4848
        dd 74, 374, 1, 1, 0xFF4C4848
        dd 561, 620, 1, 1, 0xFF363232
        dd 322, 296, 1, 1, 0xFF4C4848
        dd 603, 289, 1, 1, 0xFF4C4848
        dd 534, 246, 1, 1, 0xFF363232
        dd 904, 113, 1, 1, 0xFF363232
        dd 708, 353, 1, 1, 0xFF4C4848
        dd 580, 292, 1, 1, 0xFF363232
        dd 335, 50, 1, 1, 0xFF4C4848
        dd 316, 76, 1, 1, 0xFF363232
        dd 325, 517, 1, 1, 0xFF4C4848
        dd 630, 340, 1, 1, 0xFF363232
        dd 659, 340, 1, 1, 0xFF363232
        dd 361, 377, 1, 1, 0xFF4C4848
        dd 678, 221, 1, 1, 0xFF4C4848
        dd 938, 371, 1, 1, 0xFF4C4848
        dd 792, 635, 1, 1, 0xFF363232
        dd 490, 233, 1, 1, 0xFF363232
        dd 455, 635, 1, 1, 0xFF363232
        dd 346, 70, 1, 1, 0xFF363232
        dd 756, 349, 1, 1, 0xFF363232
        dd 354, 380, 1, 1, 0xFF363232
        dd 932, 269, 1, 1, 0xFF4C4848
        dd 881, 358, 1, 1, 0xFF363232
        dd 502, 331, 1, 1, 0xFF4C4848
        dd 832, 285, 1, 1, 0xFF4C4848
        dd 312, 98, 1, 1, 0xFF363232
        dd 793, 227, 1, 1, 0xFF4C4848
        dd 650, 287, 1, 1, 0xFF4C4848
        dd 1187, 356, 1, 1, 0xFF4C4848
        dd 813, 214, 1, 1, 0xFF4C4848
        dd 34, 353, 1, 1, 0xFF4C4848
        dd 732, 621, 1, 1, 0xFF363232
        dd 861, 211, 1, 1, 0xFF4C4848
        dd 316, 294, 1, 1, 0xFF4C4848
        dd 911, 456, 1, 1, 0xFF363232
        dd 361, 600, 1, 1, 0xFF4C4848
        dd 517, 285, 1, 1, 0xFF363232
        dd 1070, 356, 1, 1, 0xFF4C4848
        dd 268, 345, 1, 1, 0xFF363232
        dd 922, 692, 1, 1, 0xFF363232
        dd 343, 565, 1, 1, 0xFF363232
        dd 501, 311, 1, 1, 0xFF363232
        dd 467, 617, 1, 1, 0xFF4C4848
        dd 670, 621, 1, 1, 0xFF363232
        dd 81, 374, 1, 1, 0xFF4C4848
        dd 571, 314, 1, 1, 0xFF4C4848
        dd 307, 272, 1, 1, 0xFF4C4848
        dd 924, 719, 1, 1, 0xFF4C4848
        dd 368, 364, 1, 1, 0xFF4C4848
        dd 767, 639, 1, 1, 0xFF363232
        dd 577, 352, 1, 1, 0xFF363232
        dd 1253, 368, 1, 1, 0xFF363232
        dd 594, 337, 1, 1, 0xFF4C4848
        dd 672, 332, 1, 1, 0xFF363232
        dd 905, 303, 1, 1, 0xFF363232
        dd 303, 252, 1, 1, 0xFF4C4848
        dd 796, 218, 1, 1, 0xFF363232
        dd 907, 71, 1, 1, 0xFF4C4848
        dd 756, 290, 1, 1, 0xFF4C4848
        dd 437, 295, 1, 1, 0xFF363232
        dd 468, 212, 1, 1, 0xFF4C4848
        dd 584, 352, 1, 1, 0xFF363232
        dd 1108, 333, 1, 1, 0xFF4C4848
        dd 569, 274, 1, 1, 0xFF363232
        dd 947, 557, 1, 1, 0xFF363232
        dd 575, 228, 1, 1, 0xFF4C4848
        dd 903, 392, 1, 1, 0xFF363232
        dd 777, 253, 1, 1, 0xFF4C4848
        dd 309, 142, 1, 1, 0xFF363232
        dd 515, 220, 1, 1, 0xFF363232
        dd 341, 346, 1, 1, 0xFF363232
        dd 1022, 334, 1, 1, 0xFF4C4848
        dd 945, 252, 1, 1, 0xFF4C4848
        dd 646, 309, 1, 1, 0xFF363232
        dd 311, 612, 1, 1, 0xFF4C4848
        dd 327, 51, 1, 1, 0xFF4C4848
        dd 589, 382, 1, 1, 0xFF363232
        dd 556, 280, 1, 1, 0xFF4C4848
        dd 606, 618, 1, 1, 0xFF363232
        dd 256, 352, 1, 1, 0xFF4C4848
        dd 935, 205, 1, 1, 0xFF4C4848
        dd 924, 516, 1, 1, 0xFF363232
        dd 320, 137, 1, 1, 0xFF363232
        dd 876, 619, 1, 1, 0xFF363232
        dd 947, 634, 1, 1, 0xFF363232
        dd 572, 634, 1, 1, 0xFF363232
        dd 503, 255, 1, 1, 0xFF4C4848
        dd 944, 618, 1, 1, 0xFF363232
        dd 347, 112, 1, 1, 0xFF363232
        dd 471, 386, 1, 1, 0xFF4C4848
        dd 444, 343, 1, 1, 0xFF363232
        dd 697, 290, 1, 1, 0xFF4C4848
        dd 908, 554, 1, 1, 0xFF363232
        dd 900, 668, 1, 1, 0xFF363232
        dd 289, 384, 1, 1, 0xFF363232
        dd 636, 314, 1, 1, 0xFF363232
        dd 336, 235, 1, 1, 0xFF363232
        dd 361, 636, 1, 1, 0xFF363232
        dd 507, 377, 1, 1, 0xFF4C4848
        dd 790, 342, 1, 1, 0xFF363232
        dd 331, 544, 1, 1, 0xFF4C4848
        dd 566, 270, 1, 1, 0xFF363232
        dd 864, 295, 1, 1, 0xFF363232
        dd 1114, 373, 1, 1, 0xFF363232
        dd 870, 631, 1, 1, 0xFF4C4848
        dd 841, 632, 1, 1, 0xFF4C4848
        dd 833, 270, 1, 1, 0xFF4C4848
        dd 336, 543, 1, 1, 0xFF4C4848
        dd 763, 630, 1, 1, 0xFF363232
        dd 940, 156, 1, 1, 0xFF4C4848
        dd 196, 365, 1, 1, 0xFF363232
        dd 717, 298, 1, 1, 0xFF4C4848
        dd 741, 335, 1, 1, 0xFF4C4848
        dd 561, 614, 1, 1, 0xFF4C4848
        dd 924, 71, 1, 1, 0xFF363232
        dd 1167, 366, 1, 1, 0xFF4C4848
        dd 891, 371, 1, 1, 0xFF4C4848
        dd 568, 282, 1, 1, 0xFF363232
        dd 1070, 345, 1, 1, 0xFF4C4848
        dd 520, 601, 1, 1, 0xFF363232
        dd 456, 386, 1, 1, 0xFF363232
        dd 343, 299, 1, 1, 0xFF363232
        dd 660, 221, 1, 1, 0xFF363232
        dd 948, 259, 1, 1, 0xFF4C4848
        dd 908, 72, 1, 1, 0xFF363232
        dd 688, 229, 1, 1, 0xFF363232
        dd 547, 305, 1, 1, 0xFF363232
        dd 678, 205, 1, 1, 0xFF363232
        dd 937, 286, 1, 1, 0xFF4C4848
        dd 447, 615, 1, 1, 0xFF4C4848
        dd 319, 558, 1, 1, 0xFF4C4848
        dd 844, 380, 1, 1, 0xFF4C4848
        dd 328, 175, 1, 1, 0xFF363232
        dd 989, 387, 1, 1, 0xFF363232
        dd 667, 384, 1, 1, 0xFF4C4848
        dd 947, 77, 1, 1, 0xFF363232
        dd 934, 708, 1, 1, 0xFF363232
        dd 262, 368, 1, 1, 0xFF363232
        dd 753, 634, 1, 1, 0xFF363232
        dd 518, 639, 1, 1, 0xFF363232
        dd 371, 632, 1, 1, 0xFF4C4848
        dd 409, 386, 1, 1, 0xFF4C4848
        dd 1156, 372, 1, 1, 0xFF363232
        dd 443, 352, 1, 1, 0xFF4C4848
        dd 948, 45, 1, 1, 0xFF363232
        dd 569, 283, 1, 1, 0xFF363232
        dd 712, 308, 1, 1, 0xFF363232
        dd 923, 324, 1, 1, 0xFF363232
        dd 596, 215, 1, 1, 0xFF363232
        dd 569, 385, 1, 1, 0xFF4C4848
        dd 196, 381, 1, 1, 0xFF363232
        dd 495, 215, 1, 1, 0xFF363232
        dd 598, 276, 1, 1, 0xFF363232
        dd 164, 355, 1, 1, 0xFF4C4848
        dd 856, 201, 1, 1, 0xFF363232
        dd 302, 330, 1, 1, 0xFF363232
        dd 475, 623, 1, 1, 0xFF4C4848
        dd 726, 216, 1, 1, 0xFF363232
        dd 1021, 346, 1, 1, 0xFF4C4848
        dd 327, 440, 1, 1, 0xFF363232
        dd 800, 338, 1, 1, 0xFF363232
        dd 829, 381, 1, 1, 0xFF363232
        dd 720, 297, 1, 1, 0xFF363232
        dd 1031, 385, 1, 1, 0xFF4C4848
        dd 446, 374, 1, 1, 0xFF363232
        dd 938, 451, 1, 1, 0xFF4C4848
        dd 310, 706, 1, 1, 0xFF363232
        dd 76, 341, 1, 1, 0xFF363232
        dd 311, 562, 1, 1, 0xFF4C4848
        dd 960, 357, 1, 1, 0xFF4C4848
        dd 905, 391, 1, 1, 0xFF363232
        dd 770, 639, 1, 1, 0xFF4C4848
        dd 696, 299, 1, 1, 0xFF4C4848
        dd 550, 384, 1, 1, 0xFF363232
        dd 902, 583, 1, 1, 0xFF4C4848
        dd 924, 222, 1, 1, 0xFF363232
        dd 816, 243, 1, 1, 0xFF4C4848
        dd 328, 469, 1, 1, 0xFF4C4848
        dd 947, 297, 1, 1, 0xFF4C4848
        dd 727, 297, 1, 1, 0xFF4C4848
        dd 565, 636, 1, 1, 0xFF363232
        dd 939, 291, 1, 1, 0xFF4C4848
        dd 1220, 353, 1, 1, 0xFF363232
        dd 151, 330, 1, 1, 0xFF363232
        dd 1218, 373, 1, 1, 0xFF363232
        dd 693, 285, 1, 1, 0xFF363232
        dd 862, 372, 1, 1, 0xFF4C4848
        dd 974, 355, 1, 1, 0xFF4C4848
        dd 799, 206, 1, 1, 0xFF4C4848
        dd 572, 261, 1, 1, 0xFF4C4848
        dd 300, 23, 1, 1, 0xFF4C4848
        dd 854, 619, 1, 1, 0xFF363232
        dd 736, 227, 1, 1, 0xFF4C4848
        dd 1216, 352, 1, 1, 0xFF4C4848
        dd 828, 303, 1, 1, 0xFF363232
        dd 865, 333, 1, 1, 0xFF363232
        dd 848, 299, 1, 1, 0xFF4C4848
        dd 348, 448, 1, 1, 0xFF4C4848
        dd 317, 362, 1, 1, 0xFF363232
        dd 545, 248, 1, 1, 0xFF4C4848
        dd 1123, 355, 1, 1, 0xFF4C4848
        dd 585, 623, 1, 1, 0xFF363232
        dd 842, 621, 1, 1, 0xFF4C4848
        dd 344, 88, 1, 1, 0xFF4C4848
        dd 925, 708, 1, 1, 0xFF4C4848
        dd 748, 615, 1, 1, 0xFF363232
        dd 648, 618, 1, 1, 0xFF4C4848
        dd 348, 178, 1, 1, 0xFF4C4848
        dd 1114, 355, 1, 1, 0xFF363232
        dd 1117, 360, 1, 1, 0xFF4C4848
        dd 948, 97, 1, 1, 0xFF4C4848
        dd 1013, 367, 1, 1, 0xFF363232
        dd 417, 603, 1, 1, 0xFF363232
        dd 664, 387, 1, 1, 0xFF363232
        dd 650, 268, 1, 1, 0xFF4C4848
        dd 396, 231, 1, 1, 0xFF4C4848
        dd 231, 334, 1, 1, 0xFF4C4848
        dd 503, 300, 1, 1, 0xFF363232
        dd 948, 496, 1, 1, 0xFF363232
        dd 907, 320, 1, 1, 0xFF4C4848
        dd 706, 236, 1, 1, 0xFF4C4848
        dd 901, 207, 1, 1, 0xFF363232
        dd 1122, 372, 1, 1, 0xFF4C4848
        dd 943, 204, 1, 1, 0xFF363232
        dd 16, 339, 1, 1, 0xFF4C4848
        dd 231, 376, 1, 1, 0xFF363232
        dd 322, 75, 1, 1, 0xFF4C4848
        dd 538, 285, 1, 1, 0xFF363232
        dd 342, 114, 1, 1, 0xFF363232
        dd 331, 103, 1, 1, 0xFF4C4848
        dd 862, 618, 1, 1, 0xFF363232
        dd 1251, 336, 1, 1, 0xFF363232
        dd 682, 637, 1, 1, 0xFF363232
        dd 402, 635, 1, 1, 0xFF4C4848
        dd 930, 214, 1, 1, 0xFF4C4848
        dd 111, 341, 1, 1, 0xFF363232
        dd 325, 130, 1, 1, 0xFF4C4848
        dd 517, 305, 1, 1, 0xFF4C4848
        dd 770, 230, 1, 1, 0xFF4C4848
        dd 943, 600, 1, 1, 0xFF363232
        dd 654, 333, 1, 1, 0xFF4C4848
        dd 934, 614, 1, 1, 0xFF363232
        dd 687, 605, 1, 1, 0xFF363232
        dd 338, 363, 1, 1, 0xFF363232
        dd 322, 92, 1, 1, 0xFF363232
        dd 816, 614, 1, 1, 0xFF4C4848
        dd 626, 205, 1, 1, 0xFF4C4848
        dd 331, 264, 1, 1, 0xFF363232
        dd 582, 346, 1, 1, 0xFF363232
        dd 633, 628, 1, 1, 0xFF363232
        dd 169, 351, 1, 1, 0xFF4C4848
        dd 644, 299, 1, 1, 0xFF4C4848
        dd 381, 382, 1, 1, 0xFF363232
        dd 1140, 345, 1, 1, 0xFF363232
        dd 277, 364, 1, 1, 0xFF363232
        dd 338, 560, 1, 1, 0xFF363232
        dd 1266, 377, 1, 1, 0xFF363232
        dd 1075, 338, 1, 1, 0xFF363232
        dd 302, 242, 1, 1, 0xFF363232
        dd 1068, 342, 1, 1, 0xFF4C4848
        dd 947, 553, 1, 1, 0xFF4C4848
        dd 337, 382, 1, 1, 0xFF4C4848
        dd 951, 359, 1, 1, 0xFF4C4848
        dd 656, 624, 1, 1, 0xFF4C4848
        dd 613, 220, 1, 1, 0xFF4C4848
        dd 1125, 350, 1, 1, 0xFF4C4848
        dd 425, 616, 1, 1, 0xFF4C4848
        dd 192, 387, 1, 1, 0xFF4C4848
        dd 1161, 352, 1, 1, 0xFF363232
        dd 447, 312, 1, 1, 0xFF4C4848
        dd 301, 96, 1, 1, 0xFF4C4848
        dd 411, 359, 1, 1, 0xFF4C4848
        dd 452, 282, 1, 1, 0xFF363232
        dd 736, 222, 1, 1, 0xFF4C4848
        dd 1082, 386, 1, 1, 0xFF4C4848
        dd 131, 342, 1, 1, 0xFF4C4848
        dd 308, 161, 1, 1, 0xFF363232
        dd 903, 382, 1, 1, 0xFF363232
        dd 933, 495, 1, 1, 0xFF4C4848
        dd 318, 136, 1, 1, 0xFF4C4848
        dd 923, 399, 1, 1, 0xFF4C4848
        dd 575, 376, 1, 1, 0xFF363232
        dd 566, 355, 1, 1, 0xFF4C4848
        dd 397, 213, 1, 1, 0xFF4C4848
        dd 1007, 359, 1, 1, 0xFF363232
        dd 323, 22, 1, 1, 0xFF4C4848
        dd 730, 373, 1, 1, 0xFF4C4848
        dd 455, 387, 1, 1, 0xFF363232
        dd 1078, 382, 1, 1, 0xFF363232
        dd 926, 454, 1, 1, 0xFF363232
        dd 498, 629, 1, 1, 0xFF363232
        dd 320, 311, 1, 1, 0xFF363232
        dd 317, 632, 1, 1, 0xFF4C4848
        dd 176, 332, 1, 1, 0xFF4C4848
        dd 513, 336, 1, 1, 0xFF363232
        dd 736, 307, 1, 1, 0xFF363232
        dd 561, 247, 1, 1, 0xFF4C4848
        dd 434, 217, 1, 1, 0xFF363232
        dd 553, 270, 1, 1, 0xFF363232
        dd 564, 619, 1, 1, 0xFF4C4848
        dd 503, 242, 1, 1, 0xFF4C4848
        dd 946, 134, 1, 1, 0xFF4C4848
        dd 932, 390, 1, 1, 0xFF4C4848
        dd 870, 341, 1, 1, 0xFF4C4848
        dd 414, 298, 1, 1, 0xFF363232
        dd 605, 311, 1, 1, 0xFF4C4848
        dd 463, 337, 1, 1, 0xFF363232
        dd 691, 257, 1, 1, 0xFF363232
        dd 904, 32, 1, 1, 0xFF4C4848
        dd 738, 206, 1, 1, 0xFF4C4848
        dd 944, 449, 1, 1, 0xFF363232
        dd 490, 299, 1, 1, 0xFF363232
        dd 1077, 343, 1, 1, 0xFF4C4848
        dd 797, 275, 1, 1, 0xFF363232
        dd 911, 589, 1, 1, 0xFF4C4848
        dd 313, 410, 1, 1, 0xFF363232
        dd 649, 339, 1, 1, 0xFF4C4848
        dd 344, 406, 1, 1, 0xFF363232
        dd 935, 303, 1, 1, 0xFF4C4848
        dd 339, 675, 1, 1, 0xFF4C4848
        dd 540, 257, 1, 1, 0xFF363232
        dd 327, 415, 1, 1, 0xFF4C4848
        dd 832, 601, 1, 1, 0xFF4C4848
        dd 859, 338, 1, 1, 0xFF4C4848
        dd 342, 18, 1, 1, 0xFF4C4848
        dd 335, 493, 1, 1, 0xFF363232
        dd 844, 606, 1, 1, 0xFF4C4848
        dd 819, 236, 1, 1, 0xFF363232
        dd 1141, 364, 1, 1, 0xFF4C4848
        dd 921, 397, 1, 1, 0xFF4C4848
        dd 790, 204, 1, 1, 0xFF4C4848
        dd 908, 459, 1, 1, 0xFF363232
        dd 806, 287, 1, 1, 0xFF363232
        dd 744, 346, 1, 1, 0xFF4C4848
        dd 406, 611, 1, 1, 0xFF363232
        dd 430, 282, 1, 1, 0xFF363232
        dd 143, 373, 1, 1, 0xFF363232
        dd 675, 604, 1, 1, 0xFF363232
        dd 533, 276, 1, 1, 0xFF4C4848
        dd 772, 301, 1, 1, 0xFF363232
        dd 1043, 375, 1, 1, 0xFF363232
        dd 1215, 381, 1, 1, 0xFF363232
        dd 536, 220, 1, 1, 0xFF363232
        dd 778, 354, 1, 1, 0xFF363232
        dd 361, 384, 1, 1, 0xFF4C4848
        dd 792, 293, 1, 1, 0xFF4C4848
        dd 599, 203, 1, 1, 0xFF363232
        dd 5, 363, 1, 1, 0xFF363232
        dd 672, 248, 1, 1, 0xFF363232
        dd 645, 241, 1, 1, 0xFF4C4848
        dd 467, 217, 1, 1, 0xFF363232
        dd 916, 453, 1, 1, 0xFF4C4848
        dd 465, 282, 1, 1, 0xFF363232
        dd 597, 379, 1, 1, 0xFF363232
        dd 699, 284, 1, 1, 0xFF4C4848
        dd 809, 215, 1, 1, 0xFF4C4848
        dd 747, 376, 1, 1, 0xFF4C4848
        dd 317, 606, 1, 1, 0xFF363232
        dd 916, 424, 1, 1, 0xFF4C4848
        dd 1116, 335, 1, 1, 0xFF4C4848
        dd 324, 62, 1, 1, 0xFF4C4848
        dd 583, 630, 1, 1, 0xFF4C4848
        dd 842, 234, 1, 1, 0xFF363232
        dd 907, 486, 1, 1, 0xFF4C4848
        dd 1023, 336, 1, 1, 0xFF4C4848
        dd 509, 619, 1, 1, 0xFF363232
        dd 878, 383, 1, 1, 0xFF363232
        dd 333, 495, 1, 1, 0xFF363232
        dd 318, 352, 1, 1, 0xFF4C4848
        dd 312, 311, 1, 1, 0xFF363232
        dd 584, 279, 1, 1, 0xFF4C4848
        dd 324, 563, 1, 1, 0xFF4C4848
        dd 334, 308, 1, 1, 0xFF363232
        dd 342, 361, 1, 1, 0xFF4C4848
        dd 340, 622, 1, 1, 0xFF363232
        dd 419, 358, 1, 1, 0xFF363232
        dd 932, 718, 1, 1, 0xFF4C4848
        dd 756, 308, 1, 1, 0xFF4C4848
        dd 315, 240, 1, 1, 0xFF363232
        dd 771, 624, 1, 1, 0xFF363232
        dd 717, 221, 1, 1, 0xFF4C4848
        dd 734, 231, 1, 1, 0xFF4C4848
        dd 765, 248, 1, 1, 0xFF4C4848
        dd 866, 639, 1, 1, 0xFF363232
        dd 27, 332, 1, 1, 0xFF4C4848
        dd 496, 276, 1, 1, 0xFF4C4848
        dd 653, 365, 1, 1, 0xFF4C4848
        dd 832, 630, 1, 1, 0xFF363232
        dd 305, 153, 1, 1, 0xFF363232
        dd 816, 613, 1, 1, 0xFF363232
        dd 262, 356, 1, 1, 0xFF4C4848
        dd 931, 605, 1, 1, 0xFF4C4848
        dd 1276, 338, 1, 1, 0xFF4C4848
        dd 937, 399, 1, 1, 0xFF363232
        dd 341, 702, 1, 1, 0xFF4C4848
        dd 1170, 344, 1, 1, 0xFF363232
        dd 850, 299, 1, 1, 0xFF4C4848
        dd 329, 490, 1, 1, 0xFF363232
        dd 733, 234, 1, 1, 0xFF363232
        dd 1057, 358, 1, 1, 0xFF4C4848
        dd 912, 696, 1, 1, 0xFF4C4848
        dd 1019, 345, 1, 1, 0xFF363232
        dd 787, 344, 1, 1, 0xFF4C4848
        dd 336, 329, 1, 1, 0xFF363232
        dd 693, 299, 1, 1, 0xFF363232
        dd 494, 382, 1, 1, 0xFF363232
        dd 314, 25, 1, 1, 0xFF4C4848
        dd 449, 607, 1, 1, 0xFF363232
        dd 610, 622, 1, 1, 0xFF4C4848
        dd 924, 191, 1, 1, 0xFF4C4848
        dd 922, 309, 1, 1, 0xFF363232
        dd 671, 248, 1, 1, 0xFF4C4848
        dd 946, 501, 1, 1, 0xFF4C4848
        dd 651, 305, 1, 1, 0xFF4C4848
        dd 321, 517, 1, 1, 0xFF363232
        dd 862, 362, 1, 1, 0xFF363232
        dd 401, 340, 1, 1, 0xFF363232
        dd 529, 359, 1, 1, 0xFF4C4848
        dd 1117, 369, 1, 1, 0xFF4C4848
        dd 948, 438, 1, 1, 0xFF4C4848
        dd 1051, 371, 1, 1, 0xFF4C4848
        dd 305, 297, 1, 1, 0xFF4C4848
        dd 1058, 344, 1, 1, 0xFF4C4848
        dd 620, 628, 1, 1, 0xFF363232
        dd 701, 276, 1, 1, 0xFF4C4848
        dd 356, 389, 1, 1, 0xFF363232
        dd 789, 240, 1, 1, 0xFF363232
        dd 739, 624, 1, 1, 0xFF4C4848
        dd 937, 645, 1, 1, 0xFF363232
        dd 150, 357, 1, 1, 0xFF363232
        dd 853, 203, 1, 1, 0xFF363232
        dd 555, 630, 1, 1, 0xFF363232
        dd 935, 337, 1, 1, 0xFF363232
        dd 340, 68, 1, 1, 0xFF4C4848
        dd 145, 340, 1, 1, 0xFF4C4848
        dd 798, 278, 1, 1, 0xFF363232
        dd 344, 531, 1, 1, 0xFF4C4848
        dd 327, 424, 1, 1, 0xFF363232
        dd 627, 235, 1, 1, 0xFF4C4848
        dd 336, 169, 1, 1, 0xFF363232
        dd 926, 406, 1, 1, 0xFF363232
        dd 327, 411, 1, 1, 0xFF363232
        dd 1259, 385, 1, 1, 0xFF363232
        dd 615, 618, 1, 1, 0xFF4C4848
        dd 732, 614, 1, 1, 0xFF4C4848
        dd 66, 379, 1, 1, 0xFF4C4848
        dd 126, 339, 1, 1, 0xFF363232
        dd 923, 403, 1, 1, 0xFF4C4848
        dd 317, 572, 1, 1, 0xFF4C4848
        dd 301, 91, 1, 1, 0xFF4C4848
        dd 849, 354, 1, 1, 0xFF363232
        dd 679, 304, 1, 1, 0xFF363232
        dd 645, 274, 1, 1, 0xFF363232
        dd 472, 356, 1, 1, 0xFF363232
        dd 325, 377, 1, 1, 0xFF4C4848
        dd 339, 65, 1, 1, 0xFF4C4848
        dd 160, 338, 1, 1, 0xFF363232
        dd 75, 379, 1, 1, 0xFF4C4848
        dd 863, 605, 1, 1, 0xFF363232
        dd 338, 622, 1, 1, 0xFF4C4848
        dd 839, 288, 1, 1, 0xFF4C4848
        dd 804, 333, 1, 1, 0xFF4C4848
        dd 692, 601, 1, 1, 0xFF363232
        dd 574, 623, 1, 1, 0xFF363232
        dd 705, 222, 1, 1, 0xFF4C4848
        dd 576, 341, 1, 1, 0xFF4C4848
        dd 681, 205, 1, 1, 0xFF4C4848
        dd 643, 202, 1, 1, 0xFF363232
        dd 315, 428, 1, 1, 0xFF363232
        dd 928, 147, 1, 1, 0xFF363232
        dd 948, 211, 1, 1, 0xFF363232
        dd 678, 631, 1, 1, 0xFF4C4848
        dd 832, 373, 1, 1, 0xFF363232
        dd 94, 356, 1, 1, 0xFF4C4848
        dd 918, 122, 1, 1, 0xFF4C4848
        dd 902, 17, 1, 1, 0xFF4C4848
        dd 637, 306, 1, 1, 0xFF4C4848
        dd 773, 603, 1, 1, 0xFF4C4848
        dd 947, 217, 1, 1, 0xFF363232
        dd 1013, 360, 1, 1, 0xFF4C4848
        dd 744, 274, 1, 1, 0xFF363232
        dd 726, 297, 1, 1, 0xFF4C4848
        dd 759, 207, 1, 1, 0xFF363232
        dd 628, 604, 1, 1, 0xFF4C4848
        dd 848, 380, 1, 1, 0xFF4C4848
        dd 405, 221, 1, 1, 0xFF363232
        dd 1186, 374, 1, 1, 0xFF4C4848
        dd 327, 333, 1, 1, 0xFF363232
        dd 333, 651, 1, 1, 0xFF363232
        dd 424, 269, 1, 1, 0xFF4C4848
        dd 369, 610, 1, 1, 0xFF4C4848
        dd 328, 235, 1, 1, 0xFF4C4848
        dd 674, 278, 1, 1, 0xFF4C4848
        dd 924, 331, 1, 1, 0xFF4C4848
        dd 731, 349, 1, 1, 0xFF4C4848
        dd 318, 124, 1, 1, 0xFF4C4848
        dd 836, 211, 1, 1, 0xFF363232
        dd 314, 668, 1, 1, 0xFF4C4848
        dd 564, 343, 1, 1, 0xFF363232
        dd 872, 614, 1, 1, 0xFF4C4848
        dd 940, 68, 1, 1, 0xFF363232
        dd 532, 299, 1, 1, 0xFF363232
        dd 515, 348, 1, 1, 0xFF4C4848
        dd 973, 342, 1, 1, 0xFF363232
        dd 927, 293, 1, 1, 0xFF363232
        dd 934, 82, 1, 1, 0xFF363232
        dd 494, 633, 1, 1, 0xFF363232
        dd 374, 346, 1, 1, 0xFF363232
        dd 782, 387, 1, 1, 0xFF4C4848
        dd 859, 211, 1, 1, 0xFF363232
        dd 948, 615, 1, 1, 0xFF4C4848
        dd 862, 206, 1, 1, 0xFF4C4848
        dd 334, 3, 1, 1, 0xFF363232
        dd 824, 384, 1, 1, 0xFF4C4848
        dd 204, 339, 1, 1, 0xFF4C4848
        dd 197, 330, 1, 1, 0xFF363232
        dd 344, 689, 1, 1, 0xFF363232
        dd 678, 338, 1, 1, 0xFF4C4848
        dd 459, 291, 1, 1, 0xFF363232
        dd 935, 110, 1, 1, 0xFF363232
        dd 307, 663, 1, 1, 0xFF4C4848
        dd 1108, 350, 1, 1, 0xFF363232
        dd 49, 388, 1, 1, 0xFF363232
        dd 699, 290, 1, 1, 0xFF363232
        dd 11, 385, 1, 1, 0xFF4C4848
        dd 891, 362, 1, 1, 0xFF4C4848
        dd 5, 370, 1, 1, 0xFF4C4848
        dd 339, 168, 1, 1, 0xFF4C4848
        dd 550, 360, 1, 1, 0xFF4C4848
        dd 441, 291, 1, 1, 0xFF363232
        dd 885, 366, 1, 1, 0xFF363232
        dd 392, 331, 1, 1, 0xFF363232
        dd 679, 272, 1, 1, 0xFF4C4848
        dd 489, 626, 1, 1, 0xFF363232
        dd 436, 268, 1, 1, 0xFF4C4848
        dd 1133, 365, 1, 1, 0xFF363232
        dd 278, 351, 1, 1, 0xFF4C4848
        dd 840, 217, 1, 1, 0xFF363232
        dd 926, 10, 1, 1, 0xFF4C4848
        dd 937, 418, 1, 1, 0xFF4C4848
        dd 1211, 352, 1, 1, 0xFF4C4848
        dd 1215, 380, 1, 1, 0xFF4C4848
        dd 862, 381, 1, 1, 0xFF363232
        dd 813, 354, 1, 1, 0xFF363232
        dd 765, 359, 1, 1, 0xFF363232
        dd 929, 369, 1, 1, 0xFF363232
        dd 814, 226, 1, 1, 0xFF363232
        dd 756, 288, 1, 1, 0xFF4C4848
        dd 703, 342, 1, 1, 0xFF4C4848
        dd 587, 639, 1, 1, 0xFF4C4848
        dd 838, 359, 1, 1, 0xFF4C4848
        dd 933, 510, 1, 1, 0xFF4C4848
        dd 447, 233, 1, 1, 0xFF363232
        dd 627, 383, 1, 1, 0xFF363232
        dd 939, 379, 1, 1, 0xFF363232
        dd 325, 498, 1, 1, 0xFF363232
        dd 440, 218, 1, 1, 0xFF4C4848
        dd 607, 219, 1, 1, 0xFF4C4848
        dd 138, 381, 1, 1, 0xFF363232
        dd 733, 239, 1, 1, 0xFF4C4848
        dd 682, 638, 1, 1, 0xFF363232
        dd 88, 332, 1, 1, 0xFF363232
        dd 317, 306, 1, 1, 0xFF4C4848
        dd 922, 23, 1, 1, 0xFF363232
        dd 318, 513, 1, 1, 0xFF4C4848
        dd 765, 610, 1, 1, 0xFF4C4848
        dd 946, 696, 1, 1, 0xFF363232
        dd 7, 336, 1, 1, 0xFF4C4848
        dd 709, 218, 1, 1, 0xFF363232
        dd 489, 620, 1, 1, 0xFF4C4848
        dd 399, 217, 1, 1, 0xFF4C4848
        dd 804, 336, 1, 1, 0xFF4C4848
        dd 724, 289, 1, 1, 0xFF4C4848
        dd 783, 608, 1, 1, 0xFF363232
        dd 488, 356, 1, 1, 0xFF363232
        dd 944, 423, 1, 1, 0xFF4C4848
        dd 499, 279, 1, 1, 0xFF4C4848
        dd 461, 350, 1, 1, 0xFF4C4848
        dd 439, 309, 1, 1, 0xFF363232
        dd 912, 109, 1, 1, 0xFF363232
        dd 487, 627, 1, 1, 0xFF363232
        dd 303, 525, 1, 1, 0xFF4C4848
        dd 711, 601, 1, 1, 0xFF4C4848
        dd 333, 362, 1, 1, 0xFF363232
        dd 1072, 345, 1, 1, 0xFF363232
        dd 754, 268, 1, 1, 0xFF363232
        dd 318, 200, 1, 1, 0xFF4C4848
        dd 946, 500, 1, 1, 0xFF363232
        dd 304, 226, 1, 1, 0xFF4C4848
        dd 824, 340, 1, 1, 0xFF4C4848
        dd 928, 370, 1, 1, 0xFF4C4848
        dd 538, 246, 1, 1, 0xFF363232
        dd 915, 378, 1, 1, 0xFF4C4848
        dd 657, 296, 1, 1, 0xFF4C4848
        dd 255, 341, 1, 1, 0xFF363232
        dd 578, 628, 1, 1, 0xFF363232
        dd 845, 267, 1, 1, 0xFF363232
        dd 937, 610, 1, 1, 0xFF363232
        dd 925, 315, 1, 1, 0xFF4C4848
        dd 516, 280, 1, 1, 0xFF363232
        dd 340, 676, 1, 1, 0xFF4C4848
        dd 345, 80, 1, 1, 0xFF363232
        dd 1149, 359, 1, 1, 0xFF4C4848
        dd 436, 224, 1, 1, 0xFF363232
        dd 332, 318, 1, 1, 0xFF4C4848
        dd 511, 200, 1, 1, 0xFF4C4848
        dd 331, 514, 1, 1, 0xFF4C4848
        dd 158, 334, 1, 1, 0xFF4C4848
        dd 699, 246, 1, 1, 0xFF363232
        dd 892, 637, 1, 1, 0xFF4C4848
        dd 1095, 378, 1, 1, 0xFF4C4848
        dd 520, 381, 1, 1, 0xFF363232
        dd 915, 307, 1, 1, 0xFF4C4848
        dd 719, 222, 1, 1, 0xFF363232
        dd 344, 650, 1, 1, 0xFF363232
        dd 851, 222, 1, 1, 0xFF363232
        dd 788, 354, 1, 1, 0xFF4C4848
        dd 961, 355, 1, 1, 0xFF4C4848
        dd 1275, 371, 1, 1, 0xFF4C4848
        dd 325, 408, 1, 1, 0xFF4C4848
        dd 926, 697, 1, 1, 0xFF4C4848
        dd 15, 342, 1, 1, 0xFF363232
        dd 925, 39, 1, 1, 0xFF363232
        dd 1179, 364, 1, 1, 0xFF4C4848
        dd 318, 437, 1, 1, 0xFF4C4848
        dd 504, 265, 1, 1, 0xFF363232
        dd 334, 390, 1, 1, 0xFF4C4848
        dd 85, 339, 1, 1, 0xFF4C4848
        dd 774, 381, 1, 1, 0xFF363232
        dd 526, 306, 1, 1, 0xFF363232
        dd 926, 665, 1, 1, 0xFF363232
        dd 741, 271, 1, 1, 0xFF4C4848
        dd 988, 330, 1, 1, 0xFF4C4848
        dd 60, 337, 1, 1, 0xFF4C4848
        dd 159, 362, 1, 1, 0xFF4C4848
        dd 791, 290, 1, 1, 0xFF363232
        dd 405, 222, 1, 1, 0xFF363232
        dd 903, 161, 1, 1, 0xFF363232
        dd 309, 554, 1, 1, 0xFF4C4848
        dd 921, 230, 1, 1, 0xFF363232
        dd 455, 613, 1, 1, 0xFF4C4848
        dd 929, 499, 1, 1, 0xFF4C4848
        dd 398, 300, 1, 1, 0xFF363232
        dd 940, 474, 1, 1, 0xFF4C4848
        dd 914, 606, 1, 1, 0xFF4C4848
        dd 590, 617, 1, 1, 0xFF4C4848
        dd 658, 638, 1, 1, 0xFF363232
        dd 775, 338, 1, 1, 0xFF4C4848
        dd 636, 389, 1, 1, 0xFF363232
        dd 1255, 348, 1, 1, 0xFF363232
        dd 902, 331, 1, 1, 0xFF363232
        dd 923, 339, 1, 1, 0xFF363232
        dd 470, 229, 1, 1, 0xFF4C4848
        dd 860, 200, 1, 1, 0xFF363232
        dd 908, 35, 1, 1, 0xFF4C4848
        dd 396, 309, 1, 1, 0xFF4C4848
        dd 931, 577, 1, 1, 0xFF363232
        dd 906, 223, 1, 1, 0xFF363232
        dd 1237, 341, 1, 1, 0xFF363232
        dd 907, 559, 1, 1, 0xFF4C4848
        dd 522, 256, 1, 1, 0xFF4C4848
        dd 303, 338, 1, 1, 0xFF363232
        dd 817, 345, 1, 1, 0xFF363232
        dd 306, 675, 1, 1, 0xFF363232
        dd 74, 354, 1, 1, 0xFF363232
        dd 597, 232, 1, 1, 0xFF4C4848
        dd 885, 360, 1, 1, 0xFF363232
        dd 938, 357, 1, 1, 0xFF363232
        dd 739, 605, 1, 1, 0xFF363232
        dd 874, 389, 1, 1, 0xFF4C4848
        dd 794, 260, 1, 1, 0xFF4C4848
        dd 1062, 374, 1, 1, 0xFF363232
        dd 86, 357, 1, 1, 0xFF4C4848
        dd 88, 383, 1, 1, 0xFF4C4848
        dd 1026, 365, 1, 1, 0xFF363232
        dd 437, 302, 1, 1, 0xFF4C4848
        dd 825, 289, 1, 1, 0xFF4C4848
        dd 917, 185, 1, 1, 0xFF363232
        dd 681, 224, 1, 1, 0xFF363232
        dd 109, 378, 1, 1, 0xFF363232
        dd 45, 340, 1, 1, 0xFF363232
        dd 519, 380, 1, 1, 0xFF4C4848
        dd 587, 290, 1, 1, 0xFF4C4848
        dd 756, 381, 1, 1, 0xFF363232
        dd 936, 358, 1, 1, 0xFF363232
        dd 843, 342, 1, 1, 0xFF363232
        dd 330, 316, 1, 1, 0xFF4C4848
        dd 789, 227, 1, 1, 0xFF363232
        dd 665, 259, 1, 1, 0xFF363232
        dd 789, 222, 1, 1, 0xFF363232
        dd 613, 209, 1, 1, 0xFF363232
        dd 332, 22, 1, 1, 0xFF363232
        dd 649, 232, 1, 1, 0xFF4C4848
        dd 330, 595, 1, 1, 0xFF363232
        dd 907, 268, 1, 1, 0xFF363232
        dd 395, 265, 1, 1, 0xFF363232
        dd 690, 371, 1, 1, 0xFF363232
        dd 850, 334, 1, 1, 0xFF363232
        dd 904, 457, 1, 1, 0xFF4C4848
        dd 931, 316, 1, 1, 0xFF363232
        dd 333, 142, 1, 1, 0xFF363232
        dd 135, 371, 1, 1, 0xFF4C4848
        dd 416, 266, 1, 1, 0xFF4C4848
        dd 426, 639, 1, 1, 0xFF4C4848
        dd 783, 232, 1, 1, 0xFF4C4848
        dd 656, 631, 1, 1, 0xFF4C4848
        dd 316, 236, 1, 1, 0xFF4C4848
        dd 304, 400, 1, 1, 0xFF4C4848
        dd 1204, 365, 1, 1, 0xFF4C4848
        dd 442, 638, 1, 1, 0xFF4C4848
        dd 415, 276, 1, 1, 0xFF363232
        dd 302, 385, 1, 1, 0xFF363232
        dd 326, 426, 1, 1, 0xFF363232
        dd 816, 269, 1, 1, 0xFF363232
        dd 947, 294, 1, 1, 0xFF363232
        dd 813, 223, 1, 1, 0xFF4C4848
        dd 747, 378, 1, 1, 0xFF363232
        dd 925, 482, 1, 1, 0xFF363232
        dd 343, 714, 1, 1, 0xFF363232
        dd 781, 346, 1, 1, 0xFF363232
        dd 793, 372, 1, 1, 0xFF363232
        dd 760, 312, 1, 1, 0xFF4C4848
        dd 633, 231, 1, 1, 0xFF363232
        dd 917, 317, 1, 1, 0xFF4C4848
        dd 331, 122, 1, 1, 0xFF363232
        dd 488, 202, 1, 1, 0xFF4C4848
        dd 346, 492, 1, 1, 0xFF363232
        dd 205, 361, 1, 1, 0xFF4C4848
        dd 529, 219, 1, 1, 0xFF363232
        dd 972, 341, 1, 1, 0xFF4C4848
        dd 1196, 332, 1, 1, 0xFF363232
        dd 315, 424, 1, 1, 0xFF4C4848
        dd 781, 372, 1, 1, 0xFF363232
        dd 340, 317, 1, 1, 0xFF363232
        dd 35, 349, 1, 1, 0xFF363232
        dd 530, 350, 1, 1, 0xFF363232
        dd 849, 245, 1, 1, 0xFF4C4848
        dd 732, 314, 1, 1, 0xFF363232
        dd 1216, 374, 1, 1, 0xFF363232
        dd 858, 607, 1, 1, 0xFF363232
        dd 301, 1, 1, 1, 0xFF363232
        dd 602, 626, 1, 1, 0xFF4C4848
        dd 334, 162, 1, 1, 0xFF4C4848
        dd 859, 208, 1, 1, 0xFF363232
        dd 539, 243, 1, 1, 0xFF4C4848
        dd 912, 651, 1, 1, 0xFF363232
        dd 479, 357, 1, 1, 0xFF4C4848
        dd 917, 331, 1, 1, 0xFF363232
        dd 949, 565, 1, 1, 0xFF363232
        dd 824, 622, 1, 1, 0xFF4C4848
        dd 521, 301, 1, 1, 0xFF4C4848
        dd 341, 474, 1, 1, 0xFF363232
        dd 943, 499, 1, 1, 0xFF4C4848
        dd 1060, 333, 1, 1, 0xFF4C4848
        dd 877, 377, 1, 1, 0xFF363232
        dd 602, 355, 1, 1, 0xFF4C4848
        dd 697, 239, 1, 1, 0xFF4C4848
        dd 75, 375, 1, 1, 0xFF4C4848
        dd 312, 132, 1, 1, 0xFF4C4848
        dd 670, 332, 1, 1, 0xFF4C4848
        dd 443, 221, 1, 1, 0xFF4C4848
        dd 791, 354, 1, 1, 0xFF363232
        dd 300, 137, 1, 1, 0xFF363232
        dd 318, 304, 1, 1, 0xFF363232
        dd 416, 281, 1, 1, 0xFF4C4848
        dd 809, 633, 1, 1, 0xFF4C4848
        dd 404, 340, 1, 1, 0xFF4C4848
        dd 719, 351, 1, 1, 0xFF363232
        dd 402, 312, 1, 1, 0xFF363232
        dd 536, 294, 1, 1, 0xFF4C4848
        dd 322, 394, 1, 1, 0xFF4C4848
        dd 192, 330, 1, 1, 0xFF363232
        dd 325, 89, 1, 1, 0xFF363232
        dd 934, 624, 1, 1, 0xFF4C4848
        dd 661, 368, 1, 1, 0xFF4C4848
        dd 635, 615, 1, 1, 0xFF4C4848
        dd 497, 351, 1, 1, 0xFF4C4848
        dd 746, 240, 1, 1, 0xFF4C4848
        dd 442, 632, 1, 1, 0xFF363232
        dd 1189, 347, 1, 1, 0xFF4C4848
        dd 491, 363, 1, 1, 0xFF363232
        dd 348, 200, 1, 1, 0xFF363232
        dd 174, 341, 1, 1, 0xFF363232
        dd 37, 342, 1, 1, 0xFF4C4848
        dd 666, 611, 1, 1, 0xFF363232
        dd 416, 292, 1, 1, 0xFF4C4848
        dd 323, 108, 1, 1, 0xFF363232
        dd 303, 214, 1, 1, 0xFF4C4848
        dd 283, 349, 1, 1, 0xFF4C4848
        dd 475, 330, 1, 1, 0xFF4C4848
        dd 317, 460, 1, 1, 0xFF363232
        dd 381, 333, 1, 1, 0xFF4C4848
        dd 495, 209, 1, 1, 0xFF4C4848
        dd 558, 245, 1, 1, 0xFF4C4848
        dd 338, 616, 1, 1, 0xFF4C4848
        dd 655, 204, 1, 1, 0xFF4C4848
        dd 938, 545, 1, 1, 0xFF363232
        dd 683, 222, 1, 1, 0xFF4C4848
        dd 934, 548, 1, 1, 0xFF4C4848
        dd 701, 347, 1, 1, 0xFF363232
        dd 933, 29, 1, 1, 0xFF4C4848
        dd 1217, 359, 1, 1, 0xFF4C4848
        dd 939, 88, 1, 1, 0xFF4C4848
        dd 685, 287, 1, 1, 0xFF4C4848
        dd 572, 299, 1, 1, 0xFF363232
        dd 664, 621, 1, 1, 0xFF363232
        dd 757, 235, 1, 1, 0xFF363232
        dd 774, 279, 1, 1, 0xFF363232
        dd 537, 270, 1, 1, 0xFF4C4848
        dd 1071, 335, 1, 1, 0xFF4C4848
        dd 330, 606, 1, 1, 0xFF363232
        dd 340, 121, 1, 1, 0xFF4C4848
        dd 1087, 380, 1, 1, 0xFF363232
        dd 1113, 373, 1, 1, 0xFF363232
        dd 368, 348, 1, 1, 0xFF4C4848
        dd 784, 611, 1, 1, 0xFF4C4848
        dd 347, 637, 1, 1, 0xFF363232
        dd 596, 295, 1, 1, 0xFF4C4848
        dd 326, 272, 1, 1, 0xFF4C4848
        dd 1109, 387, 1, 1, 0xFF363232
        dd 880, 602, 1, 1, 0xFF363232
        dd 1261, 379, 1, 1, 0xFF363232
        dd 929, 168, 1, 1, 0xFF363232
        dd 1118, 362, 1, 1, 0xFF4C4848
        dd 318, 103, 1, 1, 0xFF4C4848
        dd 838, 283, 1, 1, 0xFF4C4848
        dd 900, 491, 1, 1, 0xFF4C4848
        dd 319, 462, 1, 1, 0xFF4C4848
        dd 846, 251, 1, 1, 0xFF4C4848
        dd 883, 600, 1, 1, 0xFF363232
        dd 542, 331, 1, 1, 0xFF363232
        dd 778, 284, 1, 1, 0xFF4C4848
        dd 136, 365, 1, 1, 0xFF4C4848
        dd 920, 206, 1, 1, 0xFF363232
        dd 704, 282, 1, 1, 0xFF363232
        dd 258, 380, 1, 1, 0xFF4C4848
        dd 922, 429, 1, 1, 0xFF4C4848
        dd 322, 340, 1, 1, 0xFF4C4848
        dd 327, 124, 1, 1, 0xFF363232
        dd 143, 357, 1, 1, 0xFF363232
        dd 945, 330, 1, 1, 0xFF4C4848
        dd 948, 325, 1, 1, 0xFF363232
        dd 357, 624, 1, 1, 0xFF4C4848
        dd 868, 336, 1, 1, 0xFF4C4848
        dd 545, 232, 1, 1, 0xFF363232
        dd 338, 577, 1, 1, 0xFF4C4848
        dd 499, 629, 1, 1, 0xFF363232
        dd 446, 334, 1, 1, 0xFF4C4848
        dd 686, 213, 1, 1, 0xFF4C4848
        dd 510, 629, 1, 1, 0xFF4C4848
        dd 428, 258, 1, 1, 0xFF4C4848
        dd 933, 559, 1, 1, 0xFF363232
        dd 692, 375, 1, 1, 0xFF4C4848
        dd 734, 239, 1, 1, 0xFF363232
        dd 616, 229, 1, 1, 0xFF4C4848
        dd 692, 278, 1, 1, 0xFF4C4848
        dd 651, 370, 1, 1, 0xFF363232
        dd 777, 287, 1, 1, 0xFF4C4848
        dd 307, 566, 1, 1, 0xFF363232
        dd 157, 368, 1, 1, 0xFF4C4848
        dd 300, 346, 1, 1, 0xFF363232
        dd 463, 384, 1, 1, 0xFF363232
        dd 604, 370, 1, 1, 0xFF4C4848
        dd 555, 375, 1, 1, 0xFF4C4848
        dd 940, 18, 1, 1, 0xFF363232
        dd 922, 206, 1, 1, 0xFF363232
        dd 924, 143, 1, 1, 0xFF363232
        dd 493, 251, 1, 1, 0xFF363232
        dd 442, 366, 1, 1, 0xFF4C4848
        dd 422, 605, 1, 1, 0xFF4C4848
        dd 347, 480, 1, 1, 0xFF363232
        dd 562, 625, 1, 1, 0xFF363232
        dd 923, 137, 1, 1, 0xFF363232
        dd 658, 295, 1, 1, 0xFF4C4848
        dd 811, 303, 1, 1, 0xFF4C4848
        dd 430, 606, 1, 1, 0xFF4C4848
        dd 447, 337, 1, 1, 0xFF4C4848
        dd 1078, 358, 1, 1, 0xFF363232
        dd 410, 307, 1, 1, 0xFF363232
        dd 949, 480, 1, 1, 0xFF363232
        dd 930, 680, 1, 1, 0xFF363232
        dd 10, 374, 1, 1, 0xFF363232
        dd 326, 433, 1, 1, 0xFF363232
        dd 471, 306, 1, 1, 0xFF4C4848
        dd 622, 335, 1, 1, 0xFF4C4848
        dd 947, 61, 1, 1, 0xFF363232
        dd 540, 290, 1, 1, 0xFF363232
        dd 1220, 345, 1, 1, 0xFF4C4848
        dd 375, 609, 1, 1, 0xFF363232
        dd 899, 372, 1, 1, 0xFF4C4848
        dd 834, 216, 1, 1, 0xFF4C4848
        dd 330, 652, 1, 1, 0xFF4C4848
        dd 980, 374, 1, 1, 0xFF4C4848
        dd 433, 253, 1, 1, 0xFF4C4848
        dd 689, 263, 1, 1, 0xFF4C4848
        dd 303, 637, 1, 1, 0xFF4C4848
        dd 747, 261, 1, 1, 0xFF363232
        dd 580, 302, 1, 1, 0xFF363232
        dd 603, 266, 1, 1, 0xFF4C4848
        dd 593, 289, 1, 1, 0xFF363232
        dd 126, 353, 1, 1, 0xFF4C4848
        dd 668, 387, 1, 1, 0xFF4C4848
        dd 582, 621, 1, 1, 0xFF4C4848
        dd 431, 331, 1, 1, 0xFF363232
        dd 509, 246, 1, 1, 0xFF4C4848
        dd 930, 399, 1, 1, 0xFF4C4848
        dd 557, 334, 1, 1, 0xFF363232
        dd 917, 418, 1, 1, 0xFF363232
        dd 150, 358, 1, 1, 0xFF363232
        dd 321, 634, 1, 1, 0xFF363232
        dd 546, 380, 1, 1, 0xFF4C4848
        dd 309, 400, 1, 1, 0xFF363232
        dd 1264, 337, 1, 1, 0xFF4C4848
        dd 918, 559, 1, 1, 0xFF4C4848
        dd 467, 289, 1, 1, 0xFF363232
        dd 448, 206, 1, 1, 0xFF363232
        dd 410, 276, 1, 1, 0xFF363232
        dd 609, 290, 1, 1, 0xFF4C4848
        dd 770, 206, 1, 1, 0xFF363232
        dd 912, 301, 1, 1, 0xFF363232
        dd 512, 201, 1, 1, 0xFF4C4848
        dd 693, 620, 1, 1, 0xFF4C4848
        dd 945, 566, 1, 1, 0xFF363232
        dd 935, 389, 1, 1, 0xFF4C4848
        dd 347, 691, 1, 1, 0xFF363232
        dd 910, 158, 1, 1, 0xFF4C4848
        dd 631, 215, 1, 1, 0xFF4C4848
        dd 128, 375, 1, 1, 0xFF4C4848
        dd 348, 637, 1, 1, 0xFF4C4848
        dd 922, 26, 1, 1, 0xFF363232
        dd 62, 379, 1, 1, 0xFF4C4848
        dd 337, 202, 1, 1, 0xFF4C4848
        dd 83, 383, 1, 1, 0xFF363232
        dd 729, 274, 1, 1, 0xFF4C4848
        dd 135, 339, 1, 1, 0xFF4C4848
        dd 330, 124, 1, 1, 0xFF363232
        dd 448, 373, 1, 1, 0xFF363232
        dd 316, 33, 1, 1, 0xFF363232
        dd 1067, 368, 1, 1, 0xFF363232
        dd 645, 218, 1, 1, 0xFF4C4848
        dd 429, 604, 1, 1, 0xFF4C4848
        dd 328, 104, 1, 1, 0xFF363232
        dd 921, 518, 1, 1, 0xFF363232
        dd 547, 205, 1, 1, 0xFF363232
        dd 237, 380, 1, 1, 0xFF4C4848
        dd 780, 634, 1, 1, 0xFF4C4848
        dd 349, 326, 1, 1, 0xFF363232
        dd 313, 457, 1, 1, 0xFF4C4848
        dd 561, 234, 1, 1, 0xFF4C4848
        dd 1120, 381, 1, 1, 0xFF363232
        dd 1112, 333, 1, 1, 0xFF363232
        dd 550, 351, 1, 1, 0xFF4C4848
        dd 706, 212, 1, 1, 0xFF363232
        dd 573, 360, 1, 1, 0xFF363232
        dd 945, 177, 1, 1, 0xFF4C4848
        dd 85, 374, 1, 1, 0xFF4C4848
        dd 1122, 360, 1, 1, 0xFF4C4848
        dd 688, 377, 1, 1, 0xFF4C4848
        dd 935, 622, 1, 1, 0xFF363232
        dd 706, 310, 1, 1, 0xFF363232
        dd 143, 334, 1, 1, 0xFF4C4848
        dd 713, 286, 1, 1, 0xFF4C4848
        dd 1098, 340, 1, 1, 0xFF4C4848
        dd 450, 634, 1, 1, 0xFF4C4848
        dd 1209, 370, 1, 1, 0xFF363232
        dd 894, 629, 1, 1, 0xFF363232
        dd 403, 383, 1, 1, 0xFF4C4848
        dd 627, 388, 1, 1, 0xFF363232
        dd 54, 330, 1, 1, 0xFF363232
        dd 496, 296, 1, 1, 0xFF363232
        dd 109, 338, 1, 1, 0xFF4C4848
        dd 905, 653, 1, 1, 0xFF363232
        dd 310, 110, 1, 1, 0xFF4C4848
        dd 361, 384, 1, 1, 0xFF363232
        dd 192, 369, 1, 1, 0xFF363232
        dd 731, 223, 1, 1, 0xFF4C4848
        dd 332, 214, 1, 1, 0xFF363232
        dd 1242, 332, 1, 1, 0xFF363232
        dd 854, 386, 1, 1, 0xFF4C4848
        dd 647, 604, 1, 1, 0xFF363232
        dd 668, 360, 1, 1, 0xFF4C4848
        dd 463, 339, 1, 1, 0xFF363232
        dd 939, 110, 1, 1, 0xFF4C4848
        dd 754, 273, 1, 1, 0xFF363232
        dd 339, 67, 1, 1, 0xFF4C4848
        dd 452, 244, 1, 1, 0xFF363232
        dd 338, 247, 1, 1, 0xFF363232
        dd 594, 630, 1, 1, 0xFF4C4848
        dd 477, 608, 1, 1, 0xFF4C4848
        dd 762, 206, 1, 1, 0xFF363232
        dd 936, 143, 1, 1, 0xFF4C4848
        dd 752, 205, 1, 1, 0xFF4C4848
        dd 923, 674, 1, 1, 0xFF363232
        dd 1191, 361, 1, 1, 0xFF4C4848
        dd 269, 361, 1, 1, 0xFF363232
        dd 342, 44, 1, 1, 0xFF4C4848
        dd 900, 84, 1, 1, 0xFF363232
        dd 932, 15, 1, 1, 0xFF363232
        dd 690, 247, 1, 1, 0xFF363232
        dd 667, 335, 1, 1, 0xFF4C4848
        dd 624, 269, 1, 1, 0xFF4C4848
        dd 921, 62, 1, 1, 0xFF363232
        dd 344, 551, 1, 1, 0xFF4C4848
        dd 633, 298, 1, 1, 0xFF4C4848
        dd 919, 539, 1, 1, 0xFF363232
        dd 1228, 349, 1, 1, 0xFF363232
        dd 932, 175, 1, 1, 0xFF363232
        dd 336, 187, 1, 1, 0xFF4C4848
        dd 748, 214, 1, 1, 0xFF363232
        dd 1118, 344, 1, 1, 0xFF4C4848
        dd 570, 211, 1, 1, 0xFF363232
        dd 298, 367, 1, 1, 0xFF363232
        dd 1092, 373, 1, 1, 0xFF363232
        dd 79, 335, 1, 1, 0xFF4C4848
        dd 835, 376, 1, 1, 0xFF363232
        dd 938, 448, 1, 1, 0xFF363232
        dd 424, 262, 1, 1, 0xFF363232
        dd 917, 642, 1, 1, 0xFF363232
        dd 914, 460, 1, 1, 0xFF4C4848
        dd 674, 337, 1, 1, 0xFF4C4848
        dd 107, 373, 1, 1, 0xFF4C4848
        dd 325, 301, 1, 1, 0xFF363232
        dd 947, 576, 1, 1, 0xFF4C4848
        dd 943, 438, 1, 1, 0xFF363232
        dd 381, 623, 1, 1, 0xFF4C4848
        dd 978, 332, 1, 1, 0xFF4C4848
        dd 322, 556, 1, 1, 0xFF4C4848
        dd 428, 307, 1, 1, 0xFF363232
        dd 346, 60, 1, 1, 0xFF4C4848
        dd 663, 622, 1, 1, 0xFF363232
        dd 732, 260, 1, 1, 0xFF4C4848
        dd 557, 251, 1, 1, 0xFF363232
        dd 496, 636, 1, 1, 0xFF4C4848
        dd 128, 381, 1, 1, 0xFF363232
        dd 209, 379, 1, 1, 0xFF363232
        dd 576, 615, 1, 1, 0xFF4C4848
        dd 396, 629, 1, 1, 0xFF363232
        dd 425, 243, 1, 1, 0xFF363232
        dd 383, 347, 1, 1, 0xFF363232
        dd 554, 335, 1, 1, 0xFF4C4848
        dd 903, 623, 1, 1, 0xFF363232
        dd 512, 333, 1, 1, 0xFF4C4848
        dd 905, 322, 1, 1, 0xFF363232
        dd 1222, 377, 1, 1, 0xFF4C4848
        dd 1235, 388, 1, 1, 0xFF363232
        dd 522, 263, 1, 1, 0xFF4C4848
        dd 1191, 332, 1, 1, 0xFF4C4848
        dd 781, 245, 1, 1, 0xFF4C4848
        dd 312, 181, 1, 1, 0xFF363232
        dd 558, 607, 1, 1, 0xFF4C4848
        dd 1157, 330, 1, 1, 0xFF4C4848
        dd 46, 351, 1, 1, 0xFF363232
        dd 583, 260, 1, 1, 0xFF4C4848
        dd 450, 244, 1, 1, 0xFF363232
        dd 948, 459, 1, 1, 0xFF363232
        dd 132, 388, 1, 1, 0xFF4C4848
        dd 384, 613, 1, 1, 0xFF4C4848
        dd 929, 310, 1, 1, 0xFF4C4848
        dd 540, 253, 1, 1, 0xFF4C4848
        dd 180, 384, 1, 1, 0xFF363232
        dd 931, 225, 1, 1, 0xFF4C4848
        dd 601, 635, 1, 1, 0xFF4C4848
        dd 926, 305, 1, 1, 0xFF363232
        dd 428, 629, 1, 1, 0xFF363232
        dd 920, 41, 1, 1, 0xFF363232
        dd 931, 166, 1, 1, 0xFF4C4848
        dd 941, 323, 1, 1, 0xFF4C4848
        dd 502, 264, 1, 1, 0xFF363232
        dd 1170, 353, 1, 1, 0xFF363232
        dd 905, 578, 1, 1, 0xFF363232
        dd 486, 374, 1, 1, 0xFF4C4848
        dd 301, 205, 1, 1, 0xFF363232
        dd 327, 577, 1, 1, 0xFF363232
        dd 485, 277, 1, 1, 0xFF4C4848
        dd 527, 352, 1, 1, 0xFF4C4848
        dd 415, 385, 1, 1, 0xFF363232
        dd 547, 240, 1, 1, 0xFF363232
        dd 942, 465, 1, 1, 0xFF363232
        dd 933, 114, 1, 1, 0xFF363232
        dd 885, 353, 1, 1, 0xFF4C4848
        dd 346, 85, 1, 1, 0xFF4C4848
        dd 524, 343, 1, 1, 0xFF363232
        dd 674, 242, 1, 1, 0xFF4C4848
        dd 685, 378, 1, 1, 0xFF4C4848
        dd 938, 600, 1, 1, 0xFF363232
        dd 833, 311, 1, 1, 0xFF363232
        dd 636, 601, 1, 1, 0xFF363232
        dd 616, 311, 1, 1, 0xFF4C4848
        dd 830, 278, 1, 1, 0xFF4C4848
        dd 898, 345, 1, 1, 0xFF363232
        dd 765, 237, 1, 1, 0xFF363232
        dd 421, 270, 1, 1, 0xFF363232
        dd 900, 460, 1, 1, 0xFF4C4848
        dd 377, 612, 1, 1, 0xFF363232
        dd 125, 350, 1, 1, 0xFF4C4848
        dd 1224, 363, 1, 1, 0xFF4C4848
        dd 924, 228, 1, 1, 0xFF4C4848
        dd 410, 633, 1, 1, 0xFF4C4848
        dd 809, 354, 1, 1, 0xFF363232
        dd 530, 275, 1, 1, 0xFF4C4848
        dd 947, 271, 1, 1, 0xFF363232
        dd 325, 440, 1, 1, 0xFF363232
        dd 747, 614, 1, 1, 0xFF4C4848
        dd 623, 303, 1, 1, 0xFF4C4848
        dd 605, 345, 1, 1, 0xFF4C4848
        dd 796, 252, 1, 1, 0xFF4C4848
        dd 215, 376, 1, 1, 0xFF4C4848
        dd 141, 340, 1, 1, 0xFF363232
        dd 346, 178, 1, 1, 0xFF4C4848
        dd 635, 632, 1, 1, 0xFF363232
        dd 86, 335, 1, 1, 0xFF4C4848
        dd 939, 656, 1, 1, 0xFF363232
        dd 931, 391, 1, 1, 0xFF4C4848
        dd 654, 258, 1, 1, 0xFF363232
        dd 931, 358, 1, 1, 0xFF4C4848
        dd 528, 245, 1, 1, 0xFF363232
        dd 309, 374, 1, 1, 0xFF363232
        dd 921, 28, 1, 1, 0xFF363232
        dd 1102, 379, 1, 1, 0xFF363232
        dd 811, 628, 1, 1, 0xFF4C4848
        dd 469, 232, 1, 1, 0xFF4C4848
        dd 323, 128, 1, 1, 0xFF363232
        dd 434, 229, 1, 1, 0xFF363232
        dd 846, 312, 1, 1, 0xFF363232
        dd 1260, 357, 1, 1, 0xFF363232
        dd 920, 384, 1, 1, 0xFF363232
        dd 929, 327, 1, 1, 0xFF363232
        dd 425, 216, 1, 1, 0xFF363232
        dd 329, 348, 1, 1, 0xFF363232
        dd 317, 49, 1, 1, 0xFF363232
        dd 652, 621, 1, 1, 0xFF363232
        dd 995, 385, 1, 1, 0xFF4C4848
        dd 1265, 358, 1, 1, 0xFF363232
        dd 918, 352, 1, 1, 0xFF363232
        dd 766, 351, 1, 1, 0xFF363232
        dd 936, 304, 1, 1, 0xFF363232
        dd 404, 365, 1, 1, 0xFF4C4848
        dd 774, 239, 1, 1, 0xFF363232
        dd 1173, 366, 1, 1, 0xFF363232
        dd 69, 373, 1, 1, 0xFF4C4848
        dd 647, 603, 1, 1, 0xFF4C4848
        dd 420, 218, 1, 1, 0xFF4C4848
        dd 775, 636, 1, 1, 0xFF4C4848
        dd 303, 442, 1, 1, 0xFF4C4848
        dd 607, 381, 1, 1, 0xFF4C4848
        dd 471, 369, 1, 1, 0xFF4C4848
        dd 599, 236, 1, 1, 0xFF363232
        dd 686, 230, 1, 1, 0xFF363232
        dd 343, 178, 1, 1, 0xFF363232
        dd 282, 365, 1, 1, 0xFF4C4848
        dd 916, 647, 1, 1, 0xFF4C4848
        dd 1097, 389, 1, 1, 0xFF363232
        dd 900, 561, 1, 1, 0xFF363232
        dd 338, 54, 1, 1, 0xFF363232
        dd 795, 297, 1, 1, 0xFF4C4848
        dd 328, 374, 1, 1, 0xFF4C4848
        dd 196, 353, 1, 1, 0xFF363232
        dd 310, 228, 1, 1, 0xFF363232
        dd 918, 239, 1, 1, 0xFF4C4848
        dd 902, 429, 1, 1, 0xFF4C4848
        dd 460, 610, 1, 1, 0xFF4C4848
        dd 901, 269, 1, 1, 0xFF4C4848
        dd 1167, 335, 1, 1, 0xFF4C4848
        dd 943, 651, 1, 1, 0xFF363232
        dd 1136, 335, 1, 1, 0xFF363232
        dd 56, 371, 1, 1, 0xFF363232
        dd 244, 342, 1, 1, 0xFF363232
        dd 1241, 360, 1, 1, 0xFF363232
        dd 668, 354, 1, 1, 0xFF4C4848
        dd 130, 381, 1, 1, 0xFF363232
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
    bg_ground_count equ ($ - bg_ground) / 20
    ; layer 2: shadows (x, y, w, h): darken what's there
    bg_shadows:
        dd 47, 47, 110, 110
        dd 177, 67, 100, 90
        dd 47, 207, 90, 100
        dd 167, 207, 110, 90
        dd 407, 47, 200, 140
        dd 657, 47, 220, 100
        dd 387, 427, 150, 150
        dd 567, 427, 120, 90
        dd 727, 427, 150, 150
        dd 377, 672, 100, 45
        dd 507, 672, 120, 45
        dd 657, 672, 100, 45
        dd 787, 672, 100, 45
        dd 997, 437, 120, 110
        dd 1147, 437, 110, 160
        dd 997, 597, 120, 100
        dd 34, 414, 90, 10
        dd 164, 414, 120, 10
        dd 34, 694, 250, 10
        dd 34, 414, 10, 290
        dd 274, 414, 10, 110
        dd 274, 564, 10, 140
        dd 974, 34, 270, 10
        dd 974, 294, 110, 10
        dd 1124, 294, 120, 10
        dd 974, 34, 10, 100
        dd 974, 174, 10, 130
        dd 1234, 34, 10, 270
        dd 423, 218, 40, 20
        dd 483, 218, 40, 20
        dd 603, 218, 40, 20
        dd 723, 218, 40, 20
        dd 783, 218, 40, 20
        dd 423, 278, 40, 20
        dd 543, 278, 40, 20
        dd 663, 278, 40, 20
        dd 823, 278, 40, 20
        dd 643, 610, 40, 20
        dd 543, 543, 26, 16
        dd 693, 543, 26, 16
        dd 1118, 613, 16, 26
        dd 183, 303, 26, 16
        dd 883, 153, 16, 26
        dd 392, 197, 480, 4
        dd 392, 317, 4, 15
        dd 868, 201, 4, 116
        dd 152, 162, 4, 40
        dd 1122, 562, 4, 30
        dd 21, 13, 6, 1
        dd 19, 14, 10, 1
        dd 18, 15, 12, 1
        dd 17, 16, 14, 1
        dd 16, 17, 16, 1
        dd 15, 18, 18, 1
        dd 15, 19, 18, 1
        dd 14, 20, 20, 1
        dd 14, 21, 20, 1
        dd 13, 22, 22, 1
        dd 13, 23, 22, 1
        dd 13, 24, 22, 1
        dd 13, 25, 22, 1
        dd 13, 26, 22, 1
        dd 14, 27, 20, 1
        dd 14, 28, 20, 1
        dd 15, 29, 18, 1
        dd 15, 30, 18, 1
        dd 16, 31, 16, 1
        dd 17, 32, 14, 1
        dd 18, 33, 12, 1
        dd 20, 34, 8, 1
        dd 165, 10, 6, 1
        dd 163, 11, 10, 1
        dd 162, 12, 12, 1
        dd 161, 13, 14, 1
        dd 160, 14, 16, 1
        dd 159, 15, 18, 1
        dd 159, 16, 18, 1
        dd 158, 17, 20, 1
        dd 158, 18, 20, 1
        dd 157, 19, 22, 1
        dd 157, 20, 22, 1
        dd 157, 21, 22, 1
        dd 157, 22, 22, 1
        dd 157, 23, 22, 1
        dd 158, 24, 20, 1
        dd 158, 25, 20, 1
        dd 159, 26, 18, 1
        dd 159, 27, 18, 1
        dd 160, 28, 16, 1
        dd 161, 29, 14, 1
        dd 162, 30, 12, 1
        dd 164, 31, 8, 1
        dd 275, 10, 6, 1
        dd 273, 11, 10, 1
        dd 272, 12, 12, 1
        dd 271, 13, 14, 1
        dd 270, 14, 16, 1
        dd 269, 15, 18, 1
        dd 269, 16, 18, 1
        dd 268, 17, 20, 1
        dd 268, 18, 20, 1
        dd 267, 19, 22, 1
        dd 267, 20, 22, 1
        dd 267, 21, 22, 1
        dd 267, 22, 22, 1
        dd 267, 23, 22, 1
        dd 268, 24, 20, 1
        dd 268, 25, 20, 1
        dd 269, 26, 18, 1
        dd 269, 27, 18, 1
        dd 270, 28, 16, 1
        dd 271, 29, 14, 1
        dd 272, 30, 12, 1
        dd 274, 31, 8, 1
        dd 21, 170, 6, 1
        dd 19, 171, 10, 1
        dd 18, 172, 12, 1
        dd 17, 173, 14, 1
        dd 16, 174, 16, 1
        dd 15, 175, 18, 1
        dd 15, 176, 18, 1
        dd 14, 177, 20, 1
        dd 14, 178, 20, 1
        dd 13, 179, 22, 1
        dd 13, 180, 22, 1
        dd 13, 181, 22, 1
        dd 13, 182, 22, 1
        dd 13, 183, 22, 1
        dd 14, 184, 20, 1
        dd 14, 185, 20, 1
        dd 15, 186, 18, 1
        dd 15, 187, 18, 1
        dd 16, 188, 16, 1
        dd 17, 189, 14, 1
        dd 18, 190, 12, 1
        dd 20, 191, 8, 1
        dd 135, 173, 6, 1
        dd 133, 174, 10, 1
        dd 132, 175, 12, 1
        dd 131, 176, 14, 1
        dd 130, 177, 16, 1
        dd 129, 178, 18, 1
        dd 129, 179, 18, 1
        dd 128, 180, 20, 1
        dd 128, 181, 20, 1
        dd 127, 182, 22, 1
        dd 127, 183, 22, 1
        dd 127, 184, 22, 1
        dd 127, 185, 22, 1
        dd 127, 186, 22, 1
        dd 128, 187, 20, 1
        dd 128, 188, 20, 1
        dd 129, 189, 18, 1
        dd 129, 190, 18, 1
        dd 130, 191, 16, 1
        dd 131, 192, 14, 1
        dd 132, 193, 12, 1
        dd 134, 194, 8, 1
        dd 373, 10, 6, 1
        dd 371, 11, 10, 1
        dd 370, 12, 12, 1
        dd 369, 13, 14, 1
        dd 368, 14, 16, 1
        dd 367, 15, 18, 1
        dd 367, 16, 18, 1
        dd 366, 17, 20, 1
        dd 366, 18, 20, 1
        dd 365, 19, 22, 1
        dd 365, 20, 22, 1
        dd 365, 21, 22, 1
        dd 365, 22, 22, 1
        dd 365, 23, 22, 1
        dd 366, 24, 20, 1
        dd 366, 25, 20, 1
        dd 367, 26, 18, 1
        dd 367, 27, 18, 1
        dd 368, 28, 16, 1
        dd 369, 29, 14, 1
        dd 370, 30, 12, 1
        dd 372, 31, 8, 1
        dd 623, 155, 6, 1
        dd 621, 156, 10, 1
        dd 620, 157, 12, 1
        dd 619, 158, 14, 1
        dd 618, 159, 16, 1
        dd 617, 160, 18, 1
        dd 617, 161, 18, 1
        dd 616, 162, 20, 1
        dd 616, 163, 20, 1
        dd 615, 164, 22, 1
        dd 615, 165, 22, 1
        dd 615, 166, 22, 1
        dd 615, 167, 22, 1
        dd 615, 168, 22, 1
        dd 616, 169, 20, 1
        dd 616, 170, 20, 1
        dd 617, 171, 18, 1
        dd 617, 172, 18, 1
        dd 618, 173, 16, 1
        dd 619, 174, 14, 1
        dd 620, 175, 12, 1
        dd 622, 176, 8, 1
        dd 18, 410, 6, 1
        dd 16, 411, 10, 1
        dd 15, 412, 12, 1
        dd 14, 413, 14, 1
        dd 13, 414, 16, 1
        dd 12, 415, 18, 1
        dd 12, 416, 18, 1
        dd 11, 417, 20, 1
        dd 11, 418, 20, 1
        dd 10, 419, 22, 1
        dd 10, 420, 22, 1
        dd 10, 421, 22, 1
        dd 10, 422, 22, 1
        dd 10, 423, 22, 1
        dd 11, 424, 20, 1
        dd 11, 425, 20, 1
        dd 12, 426, 18, 1
        dd 12, 427, 18, 1
        dd 13, 428, 16, 1
        dd 14, 429, 14, 1
        dd 15, 430, 12, 1
        dd 17, 431, 8, 1
        dd 588, 525, 6, 1
        dd 586, 526, 10, 1
        dd 585, 527, 12, 1
        dd 584, 528, 14, 1
        dd 583, 529, 16, 1
        dd 582, 530, 18, 1
        dd 582, 531, 18, 1
        dd 581, 532, 20, 1
        dd 581, 533, 20, 1
        dd 580, 534, 22, 1
        dd 580, 535, 22, 1
        dd 580, 536, 22, 1
        dd 580, 537, 22, 1
        dd 580, 538, 22, 1
        dd 581, 539, 20, 1
        dd 581, 540, 20, 1
        dd 582, 541, 18, 1
        dd 582, 542, 18, 1
        dd 583, 543, 16, 1
        dd 584, 544, 14, 1
        dd 585, 545, 12, 1
        dd 587, 546, 8, 1
        dd 708, 567, 6, 1
        dd 706, 568, 10, 1
        dd 705, 569, 12, 1
        dd 704, 570, 14, 1
        dd 703, 571, 16, 1
        dd 702, 572, 18, 1
        dd 702, 573, 18, 1
        dd 701, 574, 20, 1
        dd 701, 575, 20, 1
        dd 700, 576, 22, 1
        dd 700, 577, 22, 1
        dd 700, 578, 22, 1
        dd 700, 579, 22, 1
        dd 700, 580, 22, 1
        dd 701, 581, 20, 1
        dd 701, 582, 20, 1
        dd 702, 583, 18, 1
        dd 702, 584, 18, 1
        dd 703, 585, 16, 1
        dd 704, 586, 14, 1
        dd 705, 587, 12, 1
        dd 707, 588, 8, 1
        dd 487, 665, 6, 1
        dd 485, 666, 10, 1
        dd 484, 667, 12, 1
        dd 483, 668, 14, 1
        dd 482, 669, 16, 1
        dd 481, 670, 18, 1
        dd 481, 671, 18, 1
        dd 480, 672, 20, 1
        dd 480, 673, 20, 1
        dd 479, 674, 22, 1
        dd 479, 675, 22, 1
        dd 479, 676, 22, 1
        dd 479, 677, 22, 1
        dd 479, 678, 22, 1
        dd 480, 679, 20, 1
        dd 480, 680, 20, 1
        dd 481, 681, 18, 1
        dd 481, 682, 18, 1
        dd 482, 683, 16, 1
        dd 483, 684, 14, 1
        dd 484, 685, 12, 1
        dd 486, 686, 8, 1
        dd 768, 665, 6, 1
        dd 766, 666, 10, 1
        dd 765, 667, 12, 1
        dd 764, 668, 14, 1
        dd 763, 669, 16, 1
        dd 762, 670, 18, 1
        dd 762, 671, 18, 1
        dd 761, 672, 20, 1
        dd 761, 673, 20, 1
        dd 760, 674, 22, 1
        dd 760, 675, 22, 1
        dd 760, 676, 22, 1
        dd 760, 677, 22, 1
        dd 760, 678, 22, 1
        dd 761, 679, 20, 1
        dd 761, 680, 20, 1
        dd 762, 681, 18, 1
        dd 762, 682, 18, 1
        dd 763, 683, 16, 1
        dd 764, 684, 14, 1
        dd 765, 685, 12, 1
        dd 767, 686, 8, 1
        dd 1128, 405, 6, 1
        dd 1126, 406, 10, 1
        dd 1125, 407, 12, 1
        dd 1124, 408, 14, 1
        dd 1123, 409, 16, 1
        dd 1122, 410, 18, 1
        dd 1122, 411, 18, 1
        dd 1121, 412, 20, 1
        dd 1121, 413, 20, 1
        dd 1120, 414, 22, 1
        dd 1120, 415, 22, 1
        dd 1120, 416, 22, 1
        dd 1120, 417, 22, 1
        dd 1120, 418, 22, 1
        dd 1121, 419, 20, 1
        dd 1121, 420, 20, 1
        dd 1122, 421, 18, 1
        dd 1122, 422, 18, 1
        dd 1123, 423, 16, 1
        dd 1124, 424, 14, 1
        dd 1125, 425, 12, 1
        dd 1127, 426, 8, 1
        dd 1163, 625, 6, 1
        dd 1161, 626, 10, 1
        dd 1160, 627, 12, 1
        dd 1159, 628, 14, 1
        dd 1158, 629, 16, 1
        dd 1157, 630, 18, 1
        dd 1157, 631, 18, 1
        dd 1156, 632, 20, 1
        dd 1156, 633, 20, 1
        dd 1155, 634, 22, 1
        dd 1155, 635, 22, 1
        dd 1155, 636, 22, 1
        dd 1155, 637, 22, 1
        dd 1155, 638, 22, 1
        dd 1156, 639, 20, 1
        dd 1156, 640, 20, 1
        dd 1157, 641, 18, 1
        dd 1157, 642, 18, 1
        dd 1158, 643, 16, 1
        dd 1159, 644, 14, 1
        dd 1160, 645, 12, 1
        dd 1162, 646, 8, 1
        dd 1263, 655, 6, 1
        dd 1261, 656, 10, 1
        dd 1260, 657, 12, 1
        dd 1259, 658, 14, 1
        dd 1258, 659, 16, 1
        dd 1257, 660, 18, 1
        dd 1257, 661, 18, 1
        dd 1256, 662, 20, 1
        dd 1256, 663, 20, 1
        dd 1255, 664, 22, 1
        dd 1255, 665, 22, 1
        dd 1255, 666, 22, 1
        dd 1255, 667, 22, 1
        dd 1255, 668, 22, 1
        dd 1256, 669, 20, 1
        dd 1256, 670, 20, 1
        dd 1257, 671, 18, 1
        dd 1257, 672, 18, 1
        dd 1258, 673, 16, 1
        dd 1259, 674, 14, 1
        dd 1260, 675, 12, 1
        dd 1262, 676, 8, 1
        dd 14, 303, 4, 1
        dd 13, 304, 6, 1
        dd 12, 305, 8, 1
        dd 11, 306, 10, 1
        dd 11, 307, 10, 1
        dd 11, 308, 10, 1
        dd 12, 309, 9, 1
        dd 12, 310, 8, 1
        dd 13, 311, 6, 1
        dd 15, 312, 2, 1
        dd 281, 163, 4, 1
        dd 280, 164, 6, 1
        dd 279, 165, 8, 1
        dd 278, 166, 10, 1
        dd 278, 167, 10, 1
        dd 278, 168, 10, 1
        dd 279, 169, 9, 1
        dd 279, 170, 8, 1
        dd 280, 171, 6, 1
        dd 282, 172, 2, 1
        dd 611, 186, 4, 1
        dd 610, 187, 6, 1
        dd 609, 188, 8, 1
        dd 608, 189, 10, 1
        dd 608, 190, 10, 1
        dd 608, 191, 10, 1
        dd 609, 192, 9, 1
        dd 609, 193, 8, 1
        dd 610, 194, 6, 1
        dd 612, 195, 2, 1
        dd 1256, 293, 4, 1
        dd 1255, 294, 6, 1
        dd 1254, 295, 8, 1
        dd 1253, 296, 10, 1
        dd 1253, 297, 10, 1
        dd 1253, 298, 10, 1
        dd 1254, 299, 9, 1
        dd 1254, 300, 8, 1
        dd 1255, 301, 6, 1
        dd 1257, 302, 2, 1
        dd 968, 408, 4, 1
        dd 967, 409, 6, 1
        dd 966, 410, 8, 1
        dd 965, 411, 10, 1
        dd 965, 412, 10, 1
        dd 965, 413, 10, 1
        dd 966, 414, 9, 1
        dd 966, 415, 8, 1
        dd 967, 416, 6, 1
        dd 969, 417, 2, 1
        dd 546, 405, 4, 1
        dd 545, 406, 6, 1
        dd 544, 407, 8, 1
        dd 543, 408, 10, 1
        dd 543, 409, 10, 1
        dd 543, 410, 10, 1
        dd 544, 411, 9, 1
        dd 544, 412, 8, 1
        dd 545, 413, 6, 1
        dd 547, 414, 2, 1
        dd 886, 563, 4, 1
        dd 885, 564, 6, 1
        dd 884, 565, 8, 1
        dd 883, 566, 10, 1
        dd 883, 567, 10, 1
        dd 883, 568, 10, 1
        dd 884, 569, 9, 1
        dd 884, 570, 8, 1
        dd 885, 571, 6, 1
        dd 887, 572, 2, 1
        dd 138, 308, 4, 1
        dd 137, 309, 6, 1
        dd 136, 310, 8, 1
        dd 135, 311, 10, 1
        dd 135, 312, 10, 1
        dd 135, 313, 10, 1
        dd 136, 314, 9, 1
        dd 136, 315, 8, 1
        dd 137, 316, 6, 1
        dd 139, 317, 2, 1
        dd 66, 325, 4, 1
        dd 65, 326, 6, 1
        dd 65, 327, 6, 1
        dd 66, 328, 4, 1
        dd 67, 329, 2, 1
        dd 67, 330, 2, 1
        dd 66, 331, 4, 1
        dd 66, 332, 4, 1
        dd 226, 325, 4, 1
        dd 225, 326, 6, 1
        dd 225, 327, 6, 1
        dd 226, 328, 4, 1
        dd 227, 329, 2, 1
        dd 227, 330, 2, 1
        dd 226, 331, 4, 1
        dd 226, 332, 4, 1
        dd 466, 325, 4, 1
        dd 465, 326, 6, 1
        dd 465, 327, 6, 1
        dd 466, 328, 4, 1
        dd 467, 329, 2, 1
        dd 467, 330, 2, 1
        dd 466, 331, 4, 1
        dd 466, 332, 4, 1
        dd 626, 325, 4, 1
        dd 625, 326, 6, 1
        dd 625, 327, 6, 1
        dd 626, 328, 4, 1
        dd 627, 329, 2, 1
        dd 627, 330, 2, 1
        dd 626, 331, 4, 1
        dd 626, 332, 4, 1
        dd 786, 325, 4, 1
        dd 785, 326, 6, 1
        dd 785, 327, 6, 1
        dd 786, 328, 4, 1
        dd 787, 329, 2, 1
        dd 787, 330, 2, 1
        dd 786, 331, 4, 1
        dd 786, 332, 4, 1
        dd 1046, 325, 4, 1
        dd 1045, 326, 6, 1
        dd 1045, 327, 6, 1
        dd 1046, 328, 4, 1
        dd 1047, 329, 2, 1
        dd 1047, 330, 2, 1
        dd 1046, 331, 4, 1
        dd 1046, 332, 4, 1
        dd 1206, 325, 4, 1
        dd 1205, 326, 6, 1
        dd 1205, 327, 6, 1
        dd 1206, 328, 4, 1
        dd 1207, 329, 2, 1
        dd 1207, 330, 2, 1
        dd 1206, 331, 4, 1
        dd 1206, 332, 4, 1
        dd 146, 395, 4, 1
        dd 145, 396, 6, 1
        dd 145, 397, 6, 1
        dd 146, 398, 4, 1
        dd 147, 399, 2, 1
        dd 147, 400, 2, 1
        dd 146, 401, 4, 1
        dd 146, 402, 4, 1
        dd 546, 395, 4, 1
        dd 545, 396, 6, 1
        dd 545, 397, 6, 1
        dd 546, 398, 4, 1
        dd 547, 399, 2, 1
        dd 547, 400, 2, 1
        dd 546, 401, 4, 1
        dd 546, 402, 4, 1
        dd 706, 395, 4, 1
        dd 705, 396, 6, 1
        dd 705, 397, 6, 1
        dd 706, 398, 4, 1
        dd 707, 399, 2, 1
        dd 707, 400, 2, 1
        dd 706, 401, 4, 1
        dd 706, 402, 4, 1
        dd 866, 395, 4, 1
        dd 865, 396, 6, 1
        dd 865, 397, 6, 1
        dd 866, 398, 4, 1
        dd 867, 399, 2, 1
        dd 867, 400, 2, 1
        dd 866, 401, 4, 1
        dd 866, 402, 4, 1
        dd 1006, 395, 4, 1
        dd 1005, 396, 6, 1
        dd 1005, 397, 6, 1
        dd 1006, 398, 4, 1
        dd 1007, 399, 2, 1
        dd 1007, 400, 2, 1
        dd 1006, 401, 4, 1
        dd 1006, 402, 4, 1
        dd 1166, 395, 4, 1
        dd 1165, 396, 6, 1
        dd 1165, 397, 6, 1
        dd 1166, 398, 4, 1
        dd 1167, 399, 2, 1
        dd 1167, 400, 2, 1
        dd 1166, 401, 4, 1
        dd 1166, 402, 4, 1
        dd 297, 154, 4, 1
        dd 296, 155, 6, 1
        dd 296, 156, 6, 1
        dd 297, 157, 4, 1
        dd 298, 158, 2, 1
        dd 298, 159, 2, 1
        dd 297, 160, 4, 1
        dd 297, 161, 4, 1
        dd 297, 524, 4, 1
        dd 296, 525, 6, 1
        dd 296, 526, 6, 1
        dd 297, 527, 4, 1
        dd 298, 528, 2, 1
        dd 298, 529, 2, 1
        dd 297, 530, 4, 1
        dd 297, 531, 4, 1
        dd 357, 254, 4, 1
        dd 356, 255, 6, 1
        dd 356, 256, 6, 1
        dd 357, 257, 4, 1
        dd 358, 258, 2, 1
        dd 358, 259, 2, 1
        dd 357, 260, 4, 1
        dd 357, 261, 4, 1
        dd 357, 464, 4, 1
        dd 356, 465, 6, 1
        dd 356, 466, 6, 1
        dd 357, 467, 4, 1
        dd 358, 468, 2, 1
        dd 358, 469, 2, 1
        dd 357, 470, 4, 1
        dd 357, 471, 4, 1
        dd 897, 64, 4, 1
        dd 896, 65, 6, 1
        dd 896, 66, 6, 1
        dd 897, 67, 4, 1
        dd 898, 68, 2, 1
        dd 898, 69, 2, 1
        dd 897, 70, 4, 1
        dd 897, 71, 4, 1
        dd 897, 524, 4, 1
        dd 896, 525, 6, 1
        dd 896, 526, 6, 1
        dd 897, 527, 4, 1
        dd 898, 528, 2, 1
        dd 898, 529, 2, 1
        dd 897, 530, 4, 1
        dd 897, 531, 4, 1
        dd 957, 254, 4, 1
        dd 956, 255, 6, 1
        dd 956, 256, 6, 1
        dd 957, 257, 4, 1
        dd 958, 258, 2, 1
        dd 958, 259, 2, 1
        dd 957, 260, 4, 1
        dd 957, 261, 4, 1
        dd 957, 474, 4, 1
        dd 956, 475, 6, 1
        dd 956, 476, 6, 1
        dd 957, 477, 4, 1
        dd 958, 478, 2, 1
        dd 958, 479, 2, 1
        dd 957, 480, 4, 1
        dd 957, 481, 4, 1
    bg_shadows_count equ ($ - bg_shadows) / 16
    ; layer 3: buildings, cars, dumpsters, fences, trees, lamps
    bg_objects:
        dd 40, 40, 110, 110, 0xFF303237
        dd 43, 43, 104, 104, 0xFF5F6978
        dd 59, 94, 1, 1, 0xFF505864
        dd 63, 115, 1, 1, 0xFF505864
        dd 143, 54, 1, 1, 0xFF505864
        dd 68, 47, 1, 1, 0xFF505864
        dd 61, 133, 1, 1, 0xFF505864
        dd 45, 118, 1, 1, 0xFF505864
        dd 49, 102, 1, 1, 0xFF505864
        dd 76, 130, 1, 1, 0xFF505864
        dd 77, 68, 1, 1, 0xFF505864
        dd 119, 118, 1, 1, 0xFF505864
        dd 84, 136, 1, 1, 0xFF505864
        dd 144, 76, 1, 1, 0xFF505864
        dd 91, 145, 1, 1, 0xFF505864
        dd 78, 74, 1, 1, 0xFF505864
        dd 45, 124, 1, 1, 0xFF505864
        dd 113, 140, 1, 1, 0xFF505864
        dd 78, 141, 1, 1, 0xFF505864
        dd 140, 116, 1, 1, 0xFF505864
        dd 88, 113, 1, 1, 0xFF505864
        dd 69, 122, 1, 1, 0xFF505864
        dd 58, 107, 1, 1, 0xFF505864
        dd 57, 54, 1, 1, 0xFF505864
        dd 130, 50, 1, 1, 0xFF505864
        dd 83, 104, 1, 1, 0xFF505864
        dd 101, 84, 1, 1, 0xFF505864
        dd 94, 78, 1, 1, 0xFF505864
        dd 46, 101, 1, 1, 0xFF505864
        dd 62, 73, 1, 1, 0xFF505864
        dd 98, 122, 1, 1, 0xFF505864
        dd 90, 62, 1, 1, 0xFF505864
        dd 144, 89, 1, 1, 0xFF505864
        dd 64, 81, 1, 1, 0xFF505864
        dd 132, 129, 1, 1, 0xFF505864
        dd 45, 66, 1, 1, 0xFF505864
        dd 94, 135, 1, 1, 0xFF505864
        dd 113, 98, 1, 1, 0xFF505864
        dd 142, 120, 1, 1, 0xFF505864
        dd 47, 93, 1, 1, 0xFF505864
        dd 67, 132, 1, 1, 0xFF505864
        dd 70, 91, 1, 1, 0xFF505864
        dd 113, 99, 1, 1, 0xFF505864
        dd 122, 144, 1, 1, 0xFF505864
        dd 144, 80, 1, 1, 0xFF505864
        dd 139, 123, 1, 1, 0xFF505864
        dd 65, 109, 1, 1, 0xFF505864
        dd 105, 81, 1, 1, 0xFF505864
        dd 125, 46, 1, 1, 0xFF505864
        dd 82, 136, 1, 1, 0xFF505864
        dd 127, 114, 1, 1, 0xFF505864
        dd 64, 66, 1, 1, 0xFF505864
        dd 64, 73, 1, 1, 0xFF505864
        dd 80, 89, 1, 1, 0xFF505864
        dd 48, 95, 1, 1, 0xFF505864
        dd 59, 83, 1, 1, 0xFF505864
        dd 131, 113, 1, 1, 0xFF505864
        dd 79, 84, 1, 1, 0xFF505864
        dd 125, 103, 1, 1, 0xFF505864
        dd 112, 115, 1, 1, 0xFF505864
        dd 45, 86, 1, 1, 0xFF505864
        dd 139, 92, 1, 1, 0xFF505864
        dd 130, 58, 1, 1, 0xFF505864
        dd 82, 84, 1, 1, 0xFF505864
        dd 51, 111, 1, 1, 0xFF505864
        dd 82, 78, 1, 1, 0xFF505864
        dd 44, 54, 1, 1, 0xFF505864
        dd 100, 137, 1, 1, 0xFF505864
        dd 136, 45, 1, 1, 0xFF505864
        dd 67, 67, 12, 1, 0xFF736E6E
        dd 67, 68, 1, 1, 0xFF736E6E
        dd 68, 68, 10, 1, 0xFFAFAAAA
        dd 78, 68, 1, 1, 0xFF736E6E
        dd 67, 69, 1, 1, 0xFF736E6E
        dd 68, 69, 3, 1, 0xFFAFAAAA
        dd 71, 69, 4, 1, 0xFF4B4646
        dd 75, 69, 3, 1, 0xFFAFAAAA
        dd 78, 69, 1, 1, 0xFF736E6E
        dd 67, 70, 1, 1, 0xFF736E6E
        dd 68, 70, 2, 1, 0xFFAFAAAA
        dd 70, 70, 6, 1, 0xFF4B4646
        dd 76, 70, 2, 1, 0xFFAFAAAA
        dd 78, 70, 1, 1, 0xFF736E6E
        dd 67, 71, 1, 1, 0xFF736E6E
        dd 68, 71, 2, 1, 0xFFAFAAAA
        dd 70, 71, 2, 1, 0xFF4B4646
        dd 72, 71, 2, 1, 0xFF2D2828
        dd 74, 71, 2, 1, 0xFF4B4646
        dd 76, 71, 2, 1, 0xFFAFAAAA
        dd 78, 71, 1, 1, 0xFF736E6E
        dd 67, 72, 1, 1, 0xFF736E6E
        dd 68, 72, 2, 1, 0xFFAFAAAA
        dd 70, 72, 2, 1, 0xFF4B4646
        dd 72, 72, 2, 1, 0xFF2D2828
        dd 74, 72, 2, 1, 0xFF4B4646
        dd 76, 72, 2, 1, 0xFFAFAAAA
        dd 78, 72, 1, 1, 0xFF736E6E
        dd 67, 73, 1, 1, 0xFF736E6E
        dd 68, 73, 2, 1, 0xFFAFAAAA
        dd 70, 73, 6, 1, 0xFF4B4646
        dd 76, 73, 2, 1, 0xFFAFAAAA
        dd 78, 73, 1, 1, 0xFF736E6E
        dd 67, 74, 1, 1, 0xFF736E6E
        dd 68, 74, 3, 1, 0xFFAFAAAA
        dd 71, 74, 4, 1, 0xFF4B4646
        dd 75, 74, 3, 1, 0xFFAFAAAA
        dd 78, 74, 1, 1, 0xFF736E6E
        dd 67, 75, 1, 1, 0xFF736E6E
        dd 68, 75, 10, 1, 0xFFAFAAAA
        dd 78, 75, 1, 1, 0xFF736E6E
        dd 67, 76, 12, 1, 0xFF736E6E
        dd 170, 60, 100, 90, 0xFF303237
        dd 173, 63, 94, 84, 0xFF545C69
        dd 237, 69, 1, 1, 0xFF505864
        dd 252, 82, 1, 1, 0xFF505864
        dd 252, 75, 1, 1, 0xFF505864
        dd 243, 125, 1, 1, 0xFF505864
        dd 235, 71, 1, 1, 0xFF505864
        dd 188, 120, 1, 1, 0xFF505864
        dd 205, 104, 1, 1, 0xFF505864
        dd 225, 142, 1, 1, 0xFF505864
        dd 211, 84, 1, 1, 0xFF505864
        dd 203, 98, 1, 1, 0xFF505864
        dd 241, 82, 1, 1, 0xFF505864
        dd 239, 120, 1, 1, 0xFF505864
        dd 261, 108, 1, 1, 0xFF505864
        dd 195, 74, 1, 1, 0xFF505864
        dd 259, 101, 1, 1, 0xFF505864
        dd 206, 81, 1, 1, 0xFF505864
        dd 184, 77, 1, 1, 0xFF505864
        dd 230, 129, 1, 1, 0xFF505864
        dd 188, 110, 1, 1, 0xFF505864
        dd 235, 64, 1, 1, 0xFF505864
        dd 251, 64, 1, 1, 0xFF505864
        dd 179, 137, 1, 1, 0xFF505864
        dd 213, 87, 1, 1, 0xFF505864
        dd 263, 142, 1, 1, 0xFF505864
        dd 204, 74, 1, 1, 0xFF505864
        dd 256, 91, 1, 1, 0xFF505864
        dd 220, 71, 1, 1, 0xFF505864
        dd 203, 77, 1, 1, 0xFF505864
        dd 202, 94, 1, 1, 0xFF505864
        dd 265, 95, 1, 1, 0xFF505864
        dd 196, 142, 1, 1, 0xFF505864
        dd 214, 109, 1, 1, 0xFF505864
        dd 252, 73, 1, 1, 0xFF505864
        dd 207, 75, 1, 1, 0xFF505864
        dd 233, 103, 1, 1, 0xFF505864
        dd 175, 121, 1, 1, 0xFF505864
        dd 241, 87, 1, 1, 0xFF505864
        dd 226, 124, 1, 1, 0xFF505864
        dd 206, 141, 1, 1, 0xFF505864
        dd 250, 79, 1, 1, 0xFF505864
        dd 255, 71, 1, 1, 0xFF505864
        dd 218, 112, 1, 1, 0xFF505864
        dd 235, 80, 1, 1, 0xFF505864
        dd 203, 145, 1, 1, 0xFF505864
        dd 211, 116, 1, 1, 0xFF505864
        dd 243, 83, 1, 1, 0xFF505864
        dd 223, 85, 1, 1, 0xFF505864
        dd 264, 75, 1, 1, 0xFF505864
        dd 180, 128, 1, 1, 0xFF505864
        dd 189, 144, 1, 1, 0xFF505864
        dd 195, 82, 12, 1, 0xFF736E6E
        dd 195, 83, 1, 1, 0xFF736E6E
        dd 196, 83, 10, 1, 0xFFAFAAAA
        dd 206, 83, 1, 1, 0xFF736E6E
        dd 195, 84, 1, 1, 0xFF736E6E
        dd 196, 84, 3, 1, 0xFFAFAAAA
        dd 199, 84, 4, 1, 0xFF4B4646
        dd 203, 84, 3, 1, 0xFFAFAAAA
        dd 206, 84, 1, 1, 0xFF736E6E
        dd 195, 85, 1, 1, 0xFF736E6E
        dd 196, 85, 2, 1, 0xFFAFAAAA
        dd 198, 85, 6, 1, 0xFF4B4646
        dd 204, 85, 2, 1, 0xFFAFAAAA
        dd 206, 85, 1, 1, 0xFF736E6E
        dd 195, 86, 1, 1, 0xFF736E6E
        dd 196, 86, 2, 1, 0xFFAFAAAA
        dd 198, 86, 2, 1, 0xFF4B4646
        dd 200, 86, 2, 1, 0xFF2D2828
        dd 202, 86, 2, 1, 0xFF4B4646
        dd 204, 86, 2, 1, 0xFFAFAAAA
        dd 206, 86, 1, 1, 0xFF736E6E
        dd 195, 87, 1, 1, 0xFF736E6E
        dd 196, 87, 2, 1, 0xFFAFAAAA
        dd 198, 87, 2, 1, 0xFF4B4646
        dd 200, 87, 2, 1, 0xFF2D2828
        dd 202, 87, 2, 1, 0xFF4B4646
        dd 204, 87, 2, 1, 0xFFAFAAAA
        dd 206, 87, 1, 1, 0xFF736E6E
        dd 195, 88, 1, 1, 0xFF736E6E
        dd 196, 88, 2, 1, 0xFFAFAAAA
        dd 198, 88, 6, 1, 0xFF4B4646
        dd 204, 88, 2, 1, 0xFFAFAAAA
        dd 206, 88, 1, 1, 0xFF736E6E
        dd 195, 89, 1, 1, 0xFF736E6E
        dd 196, 89, 3, 1, 0xFFAFAAAA
        dd 199, 89, 4, 1, 0xFF4B4646
        dd 203, 89, 3, 1, 0xFFAFAAAA
        dd 206, 89, 1, 1, 0xFF736E6E
        dd 195, 90, 1, 1, 0xFF736E6E
        dd 196, 90, 10, 1, 0xFFAFAAAA
        dd 206, 90, 1, 1, 0xFF736E6E
        dd 195, 91, 12, 1, 0xFF736E6E
        dd 40, 200, 90, 100, 0xFF303237
        dd 43, 203, 84, 94, 0xFF5F6978
        dd 67, 249, 1, 1, 0xFF505864
        dd 124, 245, 1, 1, 0xFF505864
        dd 103, 257, 1, 1, 0xFF505864
        dd 111, 278, 1, 1, 0xFF505864
        dd 112, 244, 1, 1, 0xFF505864
        dd 76, 259, 1, 1, 0xFF505864
        dd 51, 232, 1, 1, 0xFF505864
        dd 108, 208, 1, 1, 0xFF505864
        dd 83, 275, 1, 1, 0xFF505864
        dd 49, 288, 1, 1, 0xFF505864
        dd 113, 242, 1, 1, 0xFF505864
        dd 52, 239, 1, 1, 0xFF505864
        dd 68, 256, 1, 1, 0xFF505864
        dd 110, 271, 1, 1, 0xFF505864
        dd 95, 257, 1, 1, 0xFF505864
        dd 78, 268, 1, 1, 0xFF505864
        dd 118, 221, 1, 1, 0xFF505864
        dd 110, 267, 1, 1, 0xFF505864
        dd 50, 243, 1, 1, 0xFF505864
        dd 98, 239, 1, 1, 0xFF505864
        dd 107, 283, 1, 1, 0xFF505864
        dd 44, 207, 1, 1, 0xFF505864
        dd 78, 238, 1, 1, 0xFF505864
        dd 99, 248, 1, 1, 0xFF505864
        dd 73, 243, 1, 1, 0xFF505864
        dd 119, 247, 1, 1, 0xFF505864
        dd 72, 237, 1, 1, 0xFF505864
        dd 124, 249, 1, 1, 0xFF505864
        dd 122, 246, 1, 1, 0xFF505864
        dd 45, 222, 1, 1, 0xFF505864
        dd 121, 218, 1, 1, 0xFF505864
        dd 85, 214, 1, 1, 0xFF505864
        dd 77, 282, 1, 1, 0xFF505864
        dd 113, 207, 1, 1, 0xFF505864
        dd 81, 291, 1, 1, 0xFF505864
        dd 48, 267, 1, 1, 0xFF505864
        dd 52, 234, 1, 1, 0xFF505864
        dd 55, 211, 1, 1, 0xFF505864
        dd 101, 270, 1, 1, 0xFF505864
        dd 108, 246, 1, 1, 0xFF505864
        dd 54, 208, 1, 1, 0xFF505864
        dd 86, 290, 1, 1, 0xFF505864
        dd 83, 246, 1, 1, 0xFF505864
        dd 71, 247, 1, 1, 0xFF505864
        dd 60, 261, 1, 1, 0xFF505864
        dd 66, 260, 1, 1, 0xFF505864
        dd 53, 247, 1, 1, 0xFF505864
        dd 95, 209, 1, 1, 0xFF505864
        dd 114, 231, 1, 1, 0xFF505864
        dd 56, 289, 1, 1, 0xFF505864
        dd 62, 225, 12, 1, 0xFF736E6E
        dd 62, 226, 1, 1, 0xFF736E6E
        dd 63, 226, 10, 1, 0xFFAFAAAA
        dd 73, 226, 1, 1, 0xFF736E6E
        dd 62, 227, 1, 1, 0xFF736E6E
        dd 63, 227, 3, 1, 0xFFAFAAAA
        dd 66, 227, 4, 1, 0xFF4B4646
        dd 70, 227, 3, 1, 0xFFAFAAAA
        dd 73, 227, 1, 1, 0xFF736E6E
        dd 62, 228, 1, 1, 0xFF736E6E
        dd 63, 228, 2, 1, 0xFFAFAAAA
        dd 65, 228, 6, 1, 0xFF4B4646
        dd 71, 228, 2, 1, 0xFFAFAAAA
        dd 73, 228, 1, 1, 0xFF736E6E
        dd 62, 229, 1, 1, 0xFF736E6E
        dd 63, 229, 2, 1, 0xFFAFAAAA
        dd 65, 229, 2, 1, 0xFF4B4646
        dd 67, 229, 2, 1, 0xFF2D2828
        dd 69, 229, 2, 1, 0xFF4B4646
        dd 71, 229, 2, 1, 0xFFAFAAAA
        dd 73, 229, 1, 1, 0xFF736E6E
        dd 62, 230, 1, 1, 0xFF736E6E
        dd 63, 230, 2, 1, 0xFFAFAAAA
        dd 65, 230, 2, 1, 0xFF4B4646
        dd 67, 230, 2, 1, 0xFF2D2828
        dd 69, 230, 2, 1, 0xFF4B4646
        dd 71, 230, 2, 1, 0xFFAFAAAA
        dd 73, 230, 1, 1, 0xFF736E6E
        dd 62, 231, 1, 1, 0xFF736E6E
        dd 63, 231, 2, 1, 0xFFAFAAAA
        dd 65, 231, 6, 1, 0xFF4B4646
        dd 71, 231, 2, 1, 0xFFAFAAAA
        dd 73, 231, 1, 1, 0xFF736E6E
        dd 62, 232, 1, 1, 0xFF736E6E
        dd 63, 232, 3, 1, 0xFFAFAAAA
        dd 66, 232, 4, 1, 0xFF4B4646
        dd 70, 232, 3, 1, 0xFFAFAAAA
        dd 73, 232, 1, 1, 0xFF736E6E
        dd 62, 233, 1, 1, 0xFF736E6E
        dd 63, 233, 10, 1, 0xFFAFAAAA
        dd 73, 233, 1, 1, 0xFF736E6E
        dd 62, 234, 12, 1, 0xFF736E6E
        dd 160, 200, 110, 90, 0xFF303237
        dd 163, 203, 104, 84, 0xFF545C69
        dd 166, 255, 1, 1, 0xFF505864
        dd 204, 213, 1, 1, 0xFF505864
        dd 219, 209, 1, 1, 0xFF505864
        dd 249, 234, 1, 1, 0xFF505864
        dd 227, 247, 1, 1, 0xFF505864
        dd 179, 261, 1, 1, 0xFF505864
        dd 264, 233, 1, 1, 0xFF505864
        dd 231, 235, 1, 1, 0xFF505864
        dd 248, 280, 1, 1, 0xFF505864
        dd 253, 276, 1, 1, 0xFF505864
        dd 258, 269, 1, 1, 0xFF505864
        dd 189, 271, 1, 1, 0xFF505864
        dd 264, 278, 1, 1, 0xFF505864
        dd 187, 280, 1, 1, 0xFF505864
        dd 256, 211, 1, 1, 0xFF505864
        dd 183, 281, 1, 1, 0xFF505864
        dd 204, 268, 1, 1, 0xFF505864
        dd 257, 204, 1, 1, 0xFF505864
        dd 193, 278, 1, 1, 0xFF505864
        dd 197, 231, 1, 1, 0xFF505864
        dd 240, 262, 1, 1, 0xFF505864
        dd 209, 221, 1, 1, 0xFF505864
        dd 228, 283, 1, 1, 0xFF505864
        dd 226, 240, 1, 1, 0xFF505864
        dd 209, 263, 1, 1, 0xFF505864
        dd 165, 285, 1, 1, 0xFF505864
        dd 182, 234, 1, 1, 0xFF505864
        dd 189, 255, 1, 1, 0xFF505864
        dd 202, 219, 1, 1, 0xFF505864
        dd 202, 275, 1, 1, 0xFF505864
        dd 217, 282, 1, 1, 0xFF505864
        dd 221, 260, 1, 1, 0xFF505864
        dd 233, 205, 1, 1, 0xFF505864
        dd 178, 282, 1, 1, 0xFF505864
        dd 230, 238, 1, 1, 0xFF505864
        dd 192, 261, 1, 1, 0xFF505864
        dd 233, 236, 1, 1, 0xFF505864
        dd 185, 243, 1, 1, 0xFF505864
        dd 201, 262, 1, 1, 0xFF505864
        dd 217, 240, 1, 1, 0xFF505864
        dd 210, 256, 1, 1, 0xFF505864
        dd 170, 213, 1, 1, 0xFF505864
        dd 169, 229, 1, 1, 0xFF505864
        dd 261, 224, 1, 1, 0xFF505864
        dd 214, 281, 1, 1, 0xFF505864
        dd 201, 263, 1, 1, 0xFF505864
        dd 194, 275, 1, 1, 0xFF505864
        dd 179, 276, 1, 1, 0xFF505864
        dd 254, 272, 1, 1, 0xFF505864
        dd 255, 211, 1, 1, 0xFF505864
        dd 170, 279, 1, 1, 0xFF505864
        dd 244, 228, 1, 1, 0xFF505864
        dd 238, 222, 1, 1, 0xFF505864
        dd 194, 235, 1, 1, 0xFF505864
        dd 180, 205, 1, 1, 0xFF505864
        dd 187, 222, 12, 1, 0xFF736E6E
        dd 187, 223, 1, 1, 0xFF736E6E
        dd 188, 223, 10, 1, 0xFFAFAAAA
        dd 198, 223, 1, 1, 0xFF736E6E
        dd 187, 224, 1, 1, 0xFF736E6E
        dd 188, 224, 3, 1, 0xFFAFAAAA
        dd 191, 224, 4, 1, 0xFF4B4646
        dd 195, 224, 3, 1, 0xFFAFAAAA
        dd 198, 224, 1, 1, 0xFF736E6E
        dd 187, 225, 1, 1, 0xFF736E6E
        dd 188, 225, 2, 1, 0xFFAFAAAA
        dd 190, 225, 6, 1, 0xFF4B4646
        dd 196, 225, 2, 1, 0xFFAFAAAA
        dd 198, 225, 1, 1, 0xFF736E6E
        dd 187, 226, 1, 1, 0xFF736E6E
        dd 188, 226, 2, 1, 0xFFAFAAAA
        dd 190, 226, 2, 1, 0xFF4B4646
        dd 192, 226, 2, 1, 0xFF2D2828
        dd 194, 226, 2, 1, 0xFF4B4646
        dd 196, 226, 2, 1, 0xFFAFAAAA
        dd 198, 226, 1, 1, 0xFF736E6E
        dd 187, 227, 1, 1, 0xFF736E6E
        dd 188, 227, 2, 1, 0xFFAFAAAA
        dd 190, 227, 2, 1, 0xFF4B4646
        dd 192, 227, 2, 1, 0xFF2D2828
        dd 194, 227, 2, 1, 0xFF4B4646
        dd 196, 227, 2, 1, 0xFFAFAAAA
        dd 198, 227, 1, 1, 0xFF736E6E
        dd 187, 228, 1, 1, 0xFF736E6E
        dd 188, 228, 2, 1, 0xFFAFAAAA
        dd 190, 228, 6, 1, 0xFF4B4646
        dd 196, 228, 2, 1, 0xFFAFAAAA
        dd 198, 228, 1, 1, 0xFF736E6E
        dd 187, 229, 1, 1, 0xFF736E6E
        dd 188, 229, 3, 1, 0xFFAFAAAA
        dd 191, 229, 4, 1, 0xFF4B4646
        dd 195, 229, 3, 1, 0xFFAFAAAA
        dd 198, 229, 1, 1, 0xFF736E6E
        dd 187, 230, 1, 1, 0xFF736E6E
        dd 188, 230, 10, 1, 0xFFAFAAAA
        dd 198, 230, 1, 1, 0xFF736E6E
        dd 187, 231, 12, 1, 0xFF736E6E
        dd 400, 40, 200, 140, 0xFF303237
        dd 403, 43, 194, 134, 0xFF5F6978
        dd 462, 100, 1, 1, 0xFF505864
        dd 425, 134, 1, 1, 0xFF505864
        dd 458, 113, 1, 1, 0xFF505864
        dd 458, 129, 1, 1, 0xFF505864
        dd 483, 58, 1, 1, 0xFF505864
        dd 455, 148, 1, 1, 0xFF505864
        dd 441, 115, 1, 1, 0xFF505864
        dd 531, 82, 1, 1, 0xFF505864
        dd 423, 120, 1, 1, 0xFF505864
        dd 514, 72, 1, 1, 0xFF505864
        dd 468, 134, 1, 1, 0xFF505864
        dd 431, 59, 1, 1, 0xFF505864
        dd 415, 85, 1, 1, 0xFF505864
        dd 529, 48, 1, 1, 0xFF505864
        dd 532, 147, 1, 1, 0xFF505864
        dd 412, 50, 1, 1, 0xFF505864
        dd 589, 87, 1, 1, 0xFF505864
        dd 515, 66, 1, 1, 0xFF505864
        dd 524, 67, 1, 1, 0xFF505864
        dd 524, 170, 1, 1, 0xFF505864
        dd 404, 52, 1, 1, 0xFF505864
        dd 564, 128, 1, 1, 0xFF505864
        dd 581, 173, 1, 1, 0xFF505864
        dd 454, 151, 1, 1, 0xFF505864
        dd 509, 80, 1, 1, 0xFF505864
        dd 594, 112, 1, 1, 0xFF505864
        dd 456, 175, 1, 1, 0xFF505864
        dd 489, 59, 1, 1, 0xFF505864
        dd 513, 98, 1, 1, 0xFF505864
        dd 556, 68, 1, 1, 0xFF505864
        dd 544, 138, 1, 1, 0xFF505864
        dd 511, 140, 1, 1, 0xFF505864
        dd 593, 128, 1, 1, 0xFF505864
        dd 522, 90, 1, 1, 0xFF505864
        dd 545, 49, 1, 1, 0xFF505864
        dd 421, 104, 1, 1, 0xFF505864
        dd 553, 154, 1, 1, 0xFF505864
        dd 413, 91, 1, 1, 0xFF505864
        dd 542, 105, 1, 1, 0xFF505864
        dd 449, 129, 1, 1, 0xFF505864
        dd 414, 138, 1, 1, 0xFF505864
        dd 411, 127, 1, 1, 0xFF505864
        dd 430, 129, 1, 1, 0xFF505864
        dd 498, 94, 1, 1, 0xFF505864
        dd 567, 90, 1, 1, 0xFF505864
        dd 571, 105, 1, 1, 0xFF505864
        dd 567, 142, 1, 1, 0xFF505864
        dd 503, 84, 1, 1, 0xFF505864
        dd 444, 102, 1, 1, 0xFF505864
        dd 424, 134, 1, 1, 0xFF505864
        dd 566, 163, 1, 1, 0xFF505864
        dd 433, 82, 1, 1, 0xFF505864
        dd 485, 54, 1, 1, 0xFF505864
        dd 474, 84, 1, 1, 0xFF505864
        dd 449, 115, 1, 1, 0xFF505864
        dd 484, 156, 1, 1, 0xFF505864
        dd 481, 137, 1, 1, 0xFF505864
        dd 508, 159, 1, 1, 0xFF505864
        dd 559, 83, 1, 1, 0xFF505864
        dd 539, 133, 1, 1, 0xFF505864
        dd 553, 46, 1, 1, 0xFF505864
        dd 456, 89, 1, 1, 0xFF505864
        dd 520, 73, 1, 1, 0xFF505864
        dd 458, 55, 1, 1, 0xFF505864
        dd 500, 127, 1, 1, 0xFF505864
        dd 407, 76, 1, 1, 0xFF505864
        dd 566, 120, 1, 1, 0xFF505864
        dd 426, 170, 1, 1, 0xFF505864
        dd 576, 87, 1, 1, 0xFF505864
        dd 497, 67, 1, 1, 0xFF505864
        dd 461, 73, 1, 1, 0xFF505864
        dd 474, 125, 1, 1, 0xFF505864
        dd 451, 163, 1, 1, 0xFF505864
        dd 508, 52, 1, 1, 0xFF505864
        dd 434, 118, 1, 1, 0xFF505864
        dd 421, 143, 1, 1, 0xFF505864
        dd 506, 106, 1, 1, 0xFF505864
        dd 511, 170, 1, 1, 0xFF505864
        dd 513, 99, 1, 1, 0xFF505864
        dd 592, 110, 1, 1, 0xFF505864
        dd 437, 164, 1, 1, 0xFF505864
        dd 423, 77, 1, 1, 0xFF505864
        dd 448, 114, 1, 1, 0xFF505864
        dd 454, 66, 1, 1, 0xFF505864
        dd 522, 102, 1, 1, 0xFF505864
        dd 446, 136, 1, 1, 0xFF505864
        dd 546, 148, 1, 1, 0xFF505864
        dd 534, 150, 1, 1, 0xFF505864
        dd 408, 120, 1, 1, 0xFF505864
        dd 500, 129, 1, 1, 0xFF505864
        dd 580, 82, 1, 1, 0xFF505864
        dd 583, 173, 1, 1, 0xFF505864
        dd 528, 97, 1, 1, 0xFF505864
        dd 472, 173, 1, 1, 0xFF505864
        dd 488, 74, 1, 1, 0xFF505864
        dd 557, 90, 1, 1, 0xFF505864
        dd 571, 166, 1, 1, 0xFF505864
        dd 521, 88, 1, 1, 0xFF505864
        dd 495, 105, 1, 1, 0xFF505864
        dd 572, 134, 1, 1, 0xFF505864
        dd 531, 165, 1, 1, 0xFF505864
        dd 475, 109, 1, 1, 0xFF505864
        dd 472, 49, 1, 1, 0xFF505864
        dd 477, 73, 1, 1, 0xFF505864
        dd 565, 78, 1, 1, 0xFF505864
        dd 434, 137, 1, 1, 0xFF505864
        dd 511, 121, 1, 1, 0xFF505864
        dd 571, 84, 1, 1, 0xFF505864
        dd 529, 104, 1, 1, 0xFF505864
        dd 567, 146, 1, 1, 0xFF505864
        dd 457, 139, 1, 1, 0xFF505864
        dd 572, 107, 1, 1, 0xFF505864
        dd 461, 173, 1, 1, 0xFF505864
        dd 443, 147, 1, 1, 0xFF505864
        dd 448, 127, 1, 1, 0xFF505864
        dd 489, 73, 1, 1, 0xFF505864
        dd 557, 45, 1, 1, 0xFF505864
        dd 536, 90, 1, 1, 0xFF505864
        dd 413, 52, 1, 1, 0xFF505864
        dd 461, 145, 1, 1, 0xFF505864
        dd 551, 47, 1, 1, 0xFF505864
        dd 471, 168, 1, 1, 0xFF505864
        dd 441, 106, 1, 1, 0xFF505864
        dd 443, 136, 1, 1, 0xFF505864
        dd 565, 51, 1, 1, 0xFF505864
        dd 563, 122, 1, 1, 0xFF505864
        dd 581, 77, 1, 1, 0xFF505864
        dd 410, 101, 1, 1, 0xFF505864
        dd 539, 60, 1, 1, 0xFF505864
        dd 411, 140, 1, 1, 0xFF505864
        dd 500, 99, 1, 1, 0xFF505864
        dd 503, 97, 1, 1, 0xFF505864
        dd 475, 124, 1, 1, 0xFF505864
        dd 497, 111, 1, 1, 0xFF505864
        dd 481, 92, 1, 1, 0xFF505864
        dd 514, 129, 1, 1, 0xFF505864
        dd 575, 153, 1, 1, 0xFF505864
        dd 508, 142, 1, 1, 0xFF505864
        dd 449, 70, 1, 1, 0xFF505864
        dd 517, 115, 1, 1, 0xFF505864
        dd 592, 92, 1, 1, 0xFF505864
        dd 569, 141, 1, 1, 0xFF505864
        dd 500, 56, 1, 1, 0xFF505864
        dd 506, 73, 1, 1, 0xFF505864
        dd 591, 89, 1, 1, 0xFF505864
        dd 419, 53, 1, 1, 0xFF505864
        dd 406, 61, 1, 1, 0xFF505864
        dd 581, 125, 1, 1, 0xFF505864
        dd 437, 138, 1, 1, 0xFF505864
        dd 583, 158, 1, 1, 0xFF505864
        dd 461, 98, 1, 1, 0xFF505864
        dd 404, 98, 1, 1, 0xFF505864
        dd 579, 172, 1, 1, 0xFF505864
        dd 487, 136, 1, 1, 0xFF505864
        dd 566, 56, 1, 1, 0xFF505864
        dd 450, 75, 12, 1, 0xFF736E6E
        dd 450, 76, 1, 1, 0xFF736E6E
        dd 451, 76, 10, 1, 0xFFAFAAAA
        dd 461, 76, 1, 1, 0xFF736E6E
        dd 450, 77, 1, 1, 0xFF736E6E
        dd 451, 77, 3, 1, 0xFFAFAAAA
        dd 454, 77, 4, 1, 0xFF4B4646
        dd 458, 77, 3, 1, 0xFFAFAAAA
        dd 461, 77, 1, 1, 0xFF736E6E
        dd 450, 78, 1, 1, 0xFF736E6E
        dd 451, 78, 2, 1, 0xFFAFAAAA
        dd 453, 78, 6, 1, 0xFF4B4646
        dd 459, 78, 2, 1, 0xFFAFAAAA
        dd 461, 78, 1, 1, 0xFF736E6E
        dd 450, 79, 1, 1, 0xFF736E6E
        dd 451, 79, 2, 1, 0xFFAFAAAA
        dd 453, 79, 2, 1, 0xFF4B4646
        dd 455, 79, 2, 1, 0xFF2D2828
        dd 457, 79, 2, 1, 0xFF4B4646
        dd 459, 79, 2, 1, 0xFFAFAAAA
        dd 461, 79, 1, 1, 0xFF736E6E
        dd 450, 80, 1, 1, 0xFF736E6E
        dd 451, 80, 2, 1, 0xFFAFAAAA
        dd 453, 80, 2, 1, 0xFF4B4646
        dd 455, 80, 2, 1, 0xFF2D2828
        dd 457, 80, 2, 1, 0xFF4B4646
        dd 459, 80, 2, 1, 0xFFAFAAAA
        dd 461, 80, 1, 1, 0xFF736E6E
        dd 450, 81, 1, 1, 0xFF736E6E
        dd 451, 81, 2, 1, 0xFFAFAAAA
        dd 453, 81, 6, 1, 0xFF4B4646
        dd 459, 81, 2, 1, 0xFFAFAAAA
        dd 461, 81, 1, 1, 0xFF736E6E
        dd 450, 82, 1, 1, 0xFF736E6E
        dd 451, 82, 3, 1, 0xFFAFAAAA
        dd 454, 82, 4, 1, 0xFF4B4646
        dd 458, 82, 3, 1, 0xFFAFAAAA
        dd 461, 82, 1, 1, 0xFF736E6E
        dd 450, 83, 1, 1, 0xFF736E6E
        dd 451, 83, 10, 1, 0xFFAFAAAA
        dd 461, 83, 1, 1, 0xFF736E6E
        dd 450, 84, 12, 1, 0xFF736E6E
        dd 534, 130, 12, 1, 0xFF736E6E
        dd 534, 131, 1, 1, 0xFF736E6E
        dd 535, 131, 10, 1, 0xFFAFAAAA
        dd 545, 131, 1, 1, 0xFF736E6E
        dd 534, 132, 1, 1, 0xFF736E6E
        dd 535, 132, 3, 1, 0xFFAFAAAA
        dd 538, 132, 4, 1, 0xFF4B4646
        dd 542, 132, 3, 1, 0xFFAFAAAA
        dd 545, 132, 1, 1, 0xFF736E6E
        dd 534, 133, 1, 1, 0xFF736E6E
        dd 535, 133, 2, 1, 0xFFAFAAAA
        dd 537, 133, 6, 1, 0xFF4B4646
        dd 543, 133, 2, 1, 0xFFAFAAAA
        dd 545, 133, 1, 1, 0xFF736E6E
        dd 534, 134, 1, 1, 0xFF736E6E
        dd 535, 134, 2, 1, 0xFFAFAAAA
        dd 537, 134, 2, 1, 0xFF4B4646
        dd 539, 134, 2, 1, 0xFF2D2828
        dd 541, 134, 2, 1, 0xFF4B4646
        dd 543, 134, 2, 1, 0xFFAFAAAA
        dd 545, 134, 1, 1, 0xFF736E6E
        dd 534, 135, 1, 1, 0xFF736E6E
        dd 535, 135, 2, 1, 0xFFAFAAAA
        dd 537, 135, 2, 1, 0xFF4B4646
        dd 539, 135, 2, 1, 0xFF2D2828
        dd 541, 135, 2, 1, 0xFF4B4646
        dd 543, 135, 2, 1, 0xFFAFAAAA
        dd 545, 135, 1, 1, 0xFF736E6E
        dd 534, 136, 1, 1, 0xFF736E6E
        dd 535, 136, 2, 1, 0xFFAFAAAA
        dd 537, 136, 6, 1, 0xFF4B4646
        dd 543, 136, 2, 1, 0xFFAFAAAA
        dd 545, 136, 1, 1, 0xFF736E6E
        dd 534, 137, 1, 1, 0xFF736E6E
        dd 535, 137, 3, 1, 0xFFAFAAAA
        dd 538, 137, 4, 1, 0xFF4B4646
        dd 542, 137, 3, 1, 0xFFAFAAAA
        dd 545, 137, 1, 1, 0xFF736E6E
        dd 534, 138, 1, 1, 0xFF736E6E
        dd 535, 138, 10, 1, 0xFFAFAAAA
        dd 545, 138, 1, 1, 0xFF736E6E
        dd 534, 139, 12, 1, 0xFF736E6E
        dd 650, 40, 220, 100, 0xFF303237
        dd 653, 43, 214, 94, 0xFF545C69
        dd 768, 71, 1, 1, 0xFF505864
        dd 763, 50, 1, 1, 0xFF505864
        dd 808, 133, 1, 1, 0xFF505864
        dd 706, 105, 1, 1, 0xFF505864
        dd 725, 45, 1, 1, 0xFF505864
        dd 758, 101, 1, 1, 0xFF505864
        dd 840, 59, 1, 1, 0xFF505864
        dd 725, 62, 1, 1, 0xFF505864
        dd 667, 134, 1, 1, 0xFF505864
        dd 833, 95, 1, 1, 0xFF505864
        dd 716, 63, 1, 1, 0xFF505864
        dd 704, 116, 1, 1, 0xFF505864
        dd 744, 100, 1, 1, 0xFF505864
        dd 812, 48, 1, 1, 0xFF505864
        dd 827, 95, 1, 1, 0xFF505864
        dd 780, 48, 1, 1, 0xFF505864
        dd 655, 70, 1, 1, 0xFF505864
        dd 819, 80, 1, 1, 0xFF505864
        dd 668, 130, 1, 1, 0xFF505864
        dd 691, 115, 1, 1, 0xFF505864
        dd 863, 127, 1, 1, 0xFF505864
        dd 793, 106, 1, 1, 0xFF505864
        dd 838, 112, 1, 1, 0xFF505864
        dd 854, 95, 1, 1, 0xFF505864
        dd 822, 104, 1, 1, 0xFF505864
        dd 682, 108, 1, 1, 0xFF505864
        dd 681, 121, 1, 1, 0xFF505864
        dd 696, 52, 1, 1, 0xFF505864
        dd 794, 96, 1, 1, 0xFF505864
        dd 829, 101, 1, 1, 0xFF505864
        dd 836, 109, 1, 1, 0xFF505864
        dd 775, 107, 1, 1, 0xFF505864
        dd 753, 56, 1, 1, 0xFF505864
        dd 732, 57, 1, 1, 0xFF505864
        dd 711, 77, 1, 1, 0xFF505864
        dd 680, 135, 1, 1, 0xFF505864
        dd 813, 99, 1, 1, 0xFF505864
        dd 747, 93, 1, 1, 0xFF505864
        dd 721, 51, 1, 1, 0xFF505864
        dd 794, 75, 1, 1, 0xFF505864
        dd 686, 116, 1, 1, 0xFF505864
        dd 742, 70, 1, 1, 0xFF505864
        dd 722, 69, 1, 1, 0xFF505864
        dd 678, 124, 1, 1, 0xFF505864
        dd 685, 89, 1, 1, 0xFF505864
        dd 693, 88, 1, 1, 0xFF505864
        dd 835, 100, 1, 1, 0xFF505864
        dd 802, 134, 1, 1, 0xFF505864
        dd 808, 59, 1, 1, 0xFF505864
        dd 857, 92, 1, 1, 0xFF505864
        dd 833, 72, 1, 1, 0xFF505864
        dd 809, 55, 1, 1, 0xFF505864
        dd 678, 96, 1, 1, 0xFF505864
        dd 822, 64, 1, 1, 0xFF505864
        dd 852, 75, 1, 1, 0xFF505864
        dd 659, 97, 1, 1, 0xFF505864
        dd 754, 72, 1, 1, 0xFF505864
        dd 844, 110, 1, 1, 0xFF505864
        dd 656, 48, 1, 1, 0xFF505864
        dd 746, 49, 1, 1, 0xFF505864
        dd 695, 49, 1, 1, 0xFF505864
        dd 712, 72, 1, 1, 0xFF505864
        dd 669, 78, 1, 1, 0xFF505864
        dd 788, 135, 1, 1, 0xFF505864
        dd 724, 59, 1, 1, 0xFF505864
        dd 692, 49, 1, 1, 0xFF505864
        dd 850, 56, 1, 1, 0xFF505864
        dd 676, 73, 1, 1, 0xFF505864
        dd 666, 102, 1, 1, 0xFF505864
        dd 808, 79, 1, 1, 0xFF505864
        dd 821, 123, 1, 1, 0xFF505864
        dd 842, 109, 1, 1, 0xFF505864
        dd 754, 103, 1, 1, 0xFF505864
        dd 734, 77, 1, 1, 0xFF505864
        dd 774, 88, 1, 1, 0xFF505864
        dd 666, 94, 1, 1, 0xFF505864
        dd 785, 55, 1, 1, 0xFF505864
        dd 741, 67, 1, 1, 0xFF505864
        dd 841, 106, 1, 1, 0xFF505864
        dd 821, 50, 1, 1, 0xFF505864
        dd 674, 65, 1, 1, 0xFF505864
        dd 790, 107, 1, 1, 0xFF505864
        dd 819, 118, 1, 1, 0xFF505864
        dd 769, 106, 1, 1, 0xFF505864
        dd 853, 119, 1, 1, 0xFF505864
        dd 714, 60, 1, 1, 0xFF505864
        dd 741, 60, 1, 1, 0xFF505864
        dd 688, 98, 1, 1, 0xFF505864
        dd 774, 86, 1, 1, 0xFF505864
        dd 770, 63, 1, 1, 0xFF505864
        dd 838, 55, 1, 1, 0xFF505864
        dd 799, 54, 1, 1, 0xFF505864
        dd 861, 131, 1, 1, 0xFF505864
        dd 812, 56, 1, 1, 0xFF505864
        dd 823, 102, 1, 1, 0xFF505864
        dd 836, 107, 1, 1, 0xFF505864
        dd 786, 113, 1, 1, 0xFF505864
        dd 694, 62, 1, 1, 0xFF505864
        dd 826, 72, 1, 1, 0xFF505864
        dd 808, 120, 1, 1, 0xFF505864
        dd 704, 112, 1, 1, 0xFF505864
        dd 799, 92, 1, 1, 0xFF505864
        dd 819, 109, 1, 1, 0xFF505864
        dd 816, 126, 1, 1, 0xFF505864
        dd 682, 44, 1, 1, 0xFF505864
        dd 777, 62, 1, 1, 0xFF505864
        dd 704, 72, 1, 1, 0xFF505864
        dd 746, 122, 1, 1, 0xFF505864
        dd 694, 127, 1, 1, 0xFF505864
        dd 689, 131, 1, 1, 0xFF505864
        dd 706, 85, 1, 1, 0xFF505864
        dd 673, 89, 1, 1, 0xFF505864
        dd 686, 100, 1, 1, 0xFF505864
        dd 679, 66, 1, 1, 0xFF505864
        dd 692, 69, 1, 1, 0xFF505864
        dd 713, 64, 1, 1, 0xFF505864
        dd 785, 110, 1, 1, 0xFF505864
        dd 811, 51, 1, 1, 0xFF505864
        dd 852, 66, 1, 1, 0xFF505864
        dd 758, 108, 1, 1, 0xFF505864
        dd 683, 97, 1, 1, 0xFF505864
        dd 791, 81, 1, 1, 0xFF505864
        dd 705, 65, 12, 1, 0xFF736E6E
        dd 705, 66, 1, 1, 0xFF736E6E
        dd 706, 66, 10, 1, 0xFFAFAAAA
        dd 716, 66, 1, 1, 0xFF736E6E
        dd 705, 67, 1, 1, 0xFF736E6E
        dd 706, 67, 3, 1, 0xFFAFAAAA
        dd 709, 67, 4, 1, 0xFF4B4646
        dd 713, 67, 3, 1, 0xFFAFAAAA
        dd 716, 67, 1, 1, 0xFF736E6E
        dd 705, 68, 1, 1, 0xFF736E6E
        dd 706, 68, 2, 1, 0xFFAFAAAA
        dd 708, 68, 6, 1, 0xFF4B4646
        dd 714, 68, 2, 1, 0xFFAFAAAA
        dd 716, 68, 1, 1, 0xFF736E6E
        dd 705, 69, 1, 1, 0xFF736E6E
        dd 706, 69, 2, 1, 0xFFAFAAAA
        dd 708, 69, 2, 1, 0xFF4B4646
        dd 710, 69, 2, 1, 0xFF2D2828
        dd 712, 69, 2, 1, 0xFF4B4646
        dd 714, 69, 2, 1, 0xFFAFAAAA
        dd 716, 69, 1, 1, 0xFF736E6E
        dd 705, 70, 1, 1, 0xFF736E6E
        dd 706, 70, 2, 1, 0xFFAFAAAA
        dd 708, 70, 2, 1, 0xFF4B4646
        dd 710, 70, 2, 1, 0xFF2D2828
        dd 712, 70, 2, 1, 0xFF4B4646
        dd 714, 70, 2, 1, 0xFFAFAAAA
        dd 716, 70, 1, 1, 0xFF736E6E
        dd 705, 71, 1, 1, 0xFF736E6E
        dd 706, 71, 2, 1, 0xFFAFAAAA
        dd 708, 71, 6, 1, 0xFF4B4646
        dd 714, 71, 2, 1, 0xFFAFAAAA
        dd 716, 71, 1, 1, 0xFF736E6E
        dd 705, 72, 1, 1, 0xFF736E6E
        dd 706, 72, 3, 1, 0xFFAFAAAA
        dd 709, 72, 4, 1, 0xFF4B4646
        dd 713, 72, 3, 1, 0xFFAFAAAA
        dd 716, 72, 1, 1, 0xFF736E6E
        dd 705, 73, 1, 1, 0xFF736E6E
        dd 706, 73, 10, 1, 0xFFAFAAAA
        dd 716, 73, 1, 1, 0xFF736E6E
        dd 705, 74, 12, 1, 0xFF736E6E
        dd 797, 103, 12, 1, 0xFF736E6E
        dd 797, 104, 1, 1, 0xFF736E6E
        dd 798, 104, 10, 1, 0xFFAFAAAA
        dd 808, 104, 1, 1, 0xFF736E6E
        dd 797, 105, 1, 1, 0xFF736E6E
        dd 798, 105, 3, 1, 0xFFAFAAAA
        dd 801, 105, 4, 1, 0xFF4B4646
        dd 805, 105, 3, 1, 0xFFAFAAAA
        dd 808, 105, 1, 1, 0xFF736E6E
        dd 797, 106, 1, 1, 0xFF736E6E
        dd 798, 106, 2, 1, 0xFFAFAAAA
        dd 800, 106, 6, 1, 0xFF4B4646
        dd 806, 106, 2, 1, 0xFFAFAAAA
        dd 808, 106, 1, 1, 0xFF736E6E
        dd 797, 107, 1, 1, 0xFF736E6E
        dd 798, 107, 2, 1, 0xFFAFAAAA
        dd 800, 107, 2, 1, 0xFF4B4646
        dd 802, 107, 2, 1, 0xFF2D2828
        dd 804, 107, 2, 1, 0xFF4B4646
        dd 806, 107, 2, 1, 0xFFAFAAAA
        dd 808, 107, 1, 1, 0xFF736E6E
        dd 797, 108, 1, 1, 0xFF736E6E
        dd 798, 108, 2, 1, 0xFFAFAAAA
        dd 800, 108, 2, 1, 0xFF4B4646
        dd 802, 108, 2, 1, 0xFF2D2828
        dd 804, 108, 2, 1, 0xFF4B4646
        dd 806, 108, 2, 1, 0xFFAFAAAA
        dd 808, 108, 1, 1, 0xFF736E6E
        dd 797, 109, 1, 1, 0xFF736E6E
        dd 798, 109, 2, 1, 0xFFAFAAAA
        dd 800, 109, 6, 1, 0xFF4B4646
        dd 806, 109, 2, 1, 0xFFAFAAAA
        dd 808, 109, 1, 1, 0xFF736E6E
        dd 797, 110, 1, 1, 0xFF736E6E
        dd 798, 110, 3, 1, 0xFFAFAAAA
        dd 801, 110, 4, 1, 0xFF4B4646
        dd 805, 110, 3, 1, 0xFFAFAAAA
        dd 808, 110, 1, 1, 0xFF736E6E
        dd 797, 111, 1, 1, 0xFF736E6E
        dd 798, 111, 10, 1, 0xFFAFAAAA
        dd 808, 111, 1, 1, 0xFF736E6E
        dd 797, 112, 12, 1, 0xFF736E6E
        dd 380, 420, 150, 150, 0xFF303237
        dd 383, 423, 144, 144, 0xFF5F6978
        dd 468, 439, 1, 1, 0xFF505864
        dd 494, 555, 1, 1, 0xFF505864
        dd 467, 442, 1, 1, 0xFF505864
        dd 495, 489, 1, 1, 0xFF505864
        dd 487, 547, 1, 1, 0xFF505864
        dd 514, 513, 1, 1, 0xFF505864
        dd 496, 533, 1, 1, 0xFF505864
        dd 504, 509, 1, 1, 0xFF505864
        dd 514, 508, 1, 1, 0xFF505864
        dd 425, 544, 1, 1, 0xFF505864
        dd 445, 433, 1, 1, 0xFF505864
        dd 401, 446, 1, 1, 0xFF505864
        dd 512, 436, 1, 1, 0xFF505864
        dd 509, 473, 1, 1, 0xFF505864
        dd 488, 450, 1, 1, 0xFF505864
        dd 426, 530, 1, 1, 0xFF505864
        dd 444, 469, 1, 1, 0xFF505864
        dd 508, 530, 1, 1, 0xFF505864
        dd 449, 488, 1, 1, 0xFF505864
        dd 441, 443, 1, 1, 0xFF505864
        dd 516, 561, 1, 1, 0xFF505864
        dd 487, 482, 1, 1, 0xFF505864
        dd 468, 464, 1, 1, 0xFF505864
        dd 488, 464, 1, 1, 0xFF505864
        dd 483, 510, 1, 1, 0xFF505864
        dd 472, 494, 1, 1, 0xFF505864
        dd 426, 521, 1, 1, 0xFF505864
        dd 462, 564, 1, 1, 0xFF505864
        dd 414, 436, 1, 1, 0xFF505864
        dd 457, 559, 1, 1, 0xFF505864
        dd 397, 476, 1, 1, 0xFF505864
        dd 438, 530, 1, 1, 0xFF505864
        dd 418, 518, 1, 1, 0xFF505864
        dd 525, 527, 1, 1, 0xFF505864
        dd 442, 426, 1, 1, 0xFF505864
        dd 437, 446, 1, 1, 0xFF505864
        dd 519, 456, 1, 1, 0xFF505864
        dd 486, 463, 1, 1, 0xFF505864
        dd 412, 495, 1, 1, 0xFF505864
        dd 471, 489, 1, 1, 0xFF505864
        dd 416, 481, 1, 1, 0xFF505864
        dd 414, 509, 1, 1, 0xFF505864
        dd 417, 487, 1, 1, 0xFF505864
        dd 473, 526, 1, 1, 0xFF505864
        dd 486, 564, 1, 1, 0xFF505864
        dd 417, 513, 1, 1, 0xFF505864
        dd 498, 548, 1, 1, 0xFF505864
        dd 447, 538, 1, 1, 0xFF505864
        dd 411, 519, 1, 1, 0xFF505864
        dd 515, 433, 1, 1, 0xFF505864
        dd 483, 462, 1, 1, 0xFF505864
        dd 482, 476, 1, 1, 0xFF505864
        dd 426, 425, 1, 1, 0xFF505864
        dd 388, 523, 1, 1, 0xFF505864
        dd 431, 489, 1, 1, 0xFF505864
        dd 400, 495, 1, 1, 0xFF505864
        dd 488, 431, 1, 1, 0xFF505864
        dd 467, 539, 1, 1, 0xFF505864
        dd 433, 484, 1, 1, 0xFF505864
        dd 421, 464, 1, 1, 0xFF505864
        dd 483, 524, 1, 1, 0xFF505864
        dd 466, 498, 1, 1, 0xFF505864
        dd 386, 496, 1, 1, 0xFF505864
        dd 481, 454, 1, 1, 0xFF505864
        dd 404, 432, 1, 1, 0xFF505864
        dd 406, 498, 1, 1, 0xFF505864
        dd 465, 554, 1, 1, 0xFF505864
        dd 402, 486, 1, 1, 0xFF505864
        dd 440, 477, 1, 1, 0xFF505864
        dd 414, 472, 1, 1, 0xFF505864
        dd 389, 540, 1, 1, 0xFF505864
        dd 450, 564, 1, 1, 0xFF505864
        dd 468, 563, 1, 1, 0xFF505864
        dd 516, 426, 1, 1, 0xFF505864
        dd 387, 512, 1, 1, 0xFF505864
        dd 460, 564, 1, 1, 0xFF505864
        dd 482, 507, 1, 1, 0xFF505864
        dd 415, 465, 1, 1, 0xFF505864
        dd 499, 460, 1, 1, 0xFF505864
        dd 462, 498, 1, 1, 0xFF505864
        dd 457, 489, 1, 1, 0xFF505864
        dd 483, 431, 1, 1, 0xFF505864
        dd 485, 511, 1, 1, 0xFF505864
        dd 477, 541, 1, 1, 0xFF505864
        dd 460, 502, 1, 1, 0xFF505864
        dd 388, 550, 1, 1, 0xFF505864
        dd 491, 482, 1, 1, 0xFF505864
        dd 505, 525, 1, 1, 0xFF505864
        dd 473, 549, 1, 1, 0xFF505864
        dd 438, 470, 1, 1, 0xFF505864
        dd 465, 485, 1, 1, 0xFF505864
        dd 503, 475, 1, 1, 0xFF505864
        dd 413, 472, 1, 1, 0xFF505864
        dd 499, 474, 1, 1, 0xFF505864
        dd 401, 457, 1, 1, 0xFF505864
        dd 414, 466, 1, 1, 0xFF505864
        dd 405, 497, 1, 1, 0xFF505864
        dd 492, 546, 1, 1, 0xFF505864
        dd 436, 478, 1, 1, 0xFF505864
        dd 392, 545, 1, 1, 0xFF505864
        dd 460, 442, 1, 1, 0xFF505864
        dd 467, 559, 1, 1, 0xFF505864
        dd 492, 547, 1, 1, 0xFF505864
        dd 422, 468, 1, 1, 0xFF505864
        dd 481, 483, 1, 1, 0xFF505864
        dd 404, 429, 1, 1, 0xFF505864
        dd 470, 474, 1, 1, 0xFF505864
        dd 523, 455, 1, 1, 0xFF505864
        dd 436, 435, 1, 1, 0xFF505864
        dd 464, 430, 1, 1, 0xFF505864
        dd 521, 561, 1, 1, 0xFF505864
        dd 456, 479, 1, 1, 0xFF505864
        dd 522, 553, 1, 1, 0xFF505864
        dd 484, 436, 1, 1, 0xFF505864
        dd 448, 453, 1, 1, 0xFF505864
        dd 488, 438, 1, 1, 0xFF505864
        dd 484, 464, 1, 1, 0xFF505864
        dd 418, 548, 1, 1, 0xFF505864
        dd 471, 476, 1, 1, 0xFF505864
        dd 483, 494, 1, 1, 0xFF505864
        dd 401, 522, 1, 1, 0xFF505864
        dd 458, 445, 1, 1, 0xFF505864
        dd 420, 432, 1, 1, 0xFF505864
        dd 492, 525, 1, 1, 0xFF505864
        dd 445, 473, 1, 1, 0xFF505864
        dd 417, 457, 12, 1, 0xFF736E6E
        dd 417, 458, 1, 1, 0xFF736E6E
        dd 418, 458, 10, 1, 0xFFAFAAAA
        dd 428, 458, 1, 1, 0xFF736E6E
        dd 417, 459, 1, 1, 0xFF736E6E
        dd 418, 459, 3, 1, 0xFFAFAAAA
        dd 421, 459, 4, 1, 0xFF4B4646
        dd 425, 459, 3, 1, 0xFFAFAAAA
        dd 428, 459, 1, 1, 0xFF736E6E
        dd 417, 460, 1, 1, 0xFF736E6E
        dd 418, 460, 2, 1, 0xFFAFAAAA
        dd 420, 460, 6, 1, 0xFF4B4646
        dd 426, 460, 2, 1, 0xFFAFAAAA
        dd 428, 460, 1, 1, 0xFF736E6E
        dd 417, 461, 1, 1, 0xFF736E6E
        dd 418, 461, 2, 1, 0xFFAFAAAA
        dd 420, 461, 2, 1, 0xFF4B4646
        dd 422, 461, 2, 1, 0xFF2D2828
        dd 424, 461, 2, 1, 0xFF4B4646
        dd 426, 461, 2, 1, 0xFFAFAAAA
        dd 428, 461, 1, 1, 0xFF736E6E
        dd 417, 462, 1, 1, 0xFF736E6E
        dd 418, 462, 2, 1, 0xFFAFAAAA
        dd 420, 462, 2, 1, 0xFF4B4646
        dd 422, 462, 2, 1, 0xFF2D2828
        dd 424, 462, 2, 1, 0xFF4B4646
        dd 426, 462, 2, 1, 0xFFAFAAAA
        dd 428, 462, 1, 1, 0xFF736E6E
        dd 417, 463, 1, 1, 0xFF736E6E
        dd 418, 463, 2, 1, 0xFFAFAAAA
        dd 420, 463, 6, 1, 0xFF4B4646
        dd 426, 463, 2, 1, 0xFFAFAAAA
        dd 428, 463, 1, 1, 0xFF736E6E
        dd 417, 464, 1, 1, 0xFF736E6E
        dd 418, 464, 3, 1, 0xFFAFAAAA
        dd 421, 464, 4, 1, 0xFF4B4646
        dd 425, 464, 3, 1, 0xFFAFAAAA
        dd 428, 464, 1, 1, 0xFF736E6E
        dd 417, 465, 1, 1, 0xFF736E6E
        dd 418, 465, 10, 1, 0xFFAFAAAA
        dd 428, 465, 1, 1, 0xFF736E6E
        dd 417, 466, 12, 1, 0xFF736E6E
        dd 480, 516, 12, 1, 0xFF736E6E
        dd 480, 517, 1, 1, 0xFF736E6E
        dd 481, 517, 10, 1, 0xFFAFAAAA
        dd 491, 517, 1, 1, 0xFF736E6E
        dd 480, 518, 1, 1, 0xFF736E6E
        dd 481, 518, 3, 1, 0xFFAFAAAA
        dd 484, 518, 4, 1, 0xFF4B4646
        dd 488, 518, 3, 1, 0xFFAFAAAA
        dd 491, 518, 1, 1, 0xFF736E6E
        dd 480, 519, 1, 1, 0xFF736E6E
        dd 481, 519, 2, 1, 0xFFAFAAAA
        dd 483, 519, 6, 1, 0xFF4B4646
        dd 489, 519, 2, 1, 0xFFAFAAAA
        dd 491, 519, 1, 1, 0xFF736E6E
        dd 480, 520, 1, 1, 0xFF736E6E
        dd 481, 520, 2, 1, 0xFFAFAAAA
        dd 483, 520, 2, 1, 0xFF4B4646
        dd 485, 520, 2, 1, 0xFF2D2828
        dd 487, 520, 2, 1, 0xFF4B4646
        dd 489, 520, 2, 1, 0xFFAFAAAA
        dd 491, 520, 1, 1, 0xFF736E6E
        dd 480, 521, 1, 1, 0xFF736E6E
        dd 481, 521, 2, 1, 0xFFAFAAAA
        dd 483, 521, 2, 1, 0xFF4B4646
        dd 485, 521, 2, 1, 0xFF2D2828
        dd 487, 521, 2, 1, 0xFF4B4646
        dd 489, 521, 2, 1, 0xFFAFAAAA
        dd 491, 521, 1, 1, 0xFF736E6E
        dd 480, 522, 1, 1, 0xFF736E6E
        dd 481, 522, 2, 1, 0xFFAFAAAA
        dd 483, 522, 6, 1, 0xFF4B4646
        dd 489, 522, 2, 1, 0xFFAFAAAA
        dd 491, 522, 1, 1, 0xFF736E6E
        dd 480, 523, 1, 1, 0xFF736E6E
        dd 481, 523, 3, 1, 0xFFAFAAAA
        dd 484, 523, 4, 1, 0xFF4B4646
        dd 488, 523, 3, 1, 0xFFAFAAAA
        dd 491, 523, 1, 1, 0xFF736E6E
        dd 480, 524, 1, 1, 0xFF736E6E
        dd 481, 524, 10, 1, 0xFFAFAAAA
        dd 491, 524, 1, 1, 0xFF736E6E
        dd 480, 525, 12, 1, 0xFF736E6E
        dd 560, 420, 120, 90, 0xFF303237
        dd 563, 423, 114, 84, 0xFF545C69
        dd 574, 447, 1, 1, 0xFF505864
        dd 580, 489, 1, 1, 0xFF505864
        dd 637, 495, 1, 1, 0xFF505864
        dd 590, 489, 1, 1, 0xFF505864
        dd 673, 431, 1, 1, 0xFF505864
        dd 602, 444, 1, 1, 0xFF505864
        dd 637, 426, 1, 1, 0xFF505864
        dd 605, 454, 1, 1, 0xFF505864
        dd 671, 470, 1, 1, 0xFF505864
        dd 636, 427, 1, 1, 0xFF505864
        dd 593, 487, 1, 1, 0xFF505864
        dd 590, 492, 1, 1, 0xFF505864
        dd 646, 445, 1, 1, 0xFF505864
        dd 620, 425, 1, 1, 0xFF505864
        dd 641, 496, 1, 1, 0xFF505864
        dd 631, 451, 1, 1, 0xFF505864
        dd 641, 470, 1, 1, 0xFF505864
        dd 626, 427, 1, 1, 0xFF505864
        dd 565, 436, 1, 1, 0xFF505864
        dd 586, 442, 1, 1, 0xFF505864
        dd 622, 476, 1, 1, 0xFF505864
        dd 572, 473, 1, 1, 0xFF505864
        dd 596, 483, 1, 1, 0xFF505864
        dd 603, 429, 1, 1, 0xFF505864
        dd 670, 456, 1, 1, 0xFF505864
        dd 566, 454, 1, 1, 0xFF505864
        dd 607, 482, 1, 1, 0xFF505864
        dd 651, 427, 1, 1, 0xFF505864
        dd 622, 496, 1, 1, 0xFF505864
        dd 673, 503, 1, 1, 0xFF505864
        dd 669, 426, 1, 1, 0xFF505864
        dd 634, 442, 1, 1, 0xFF505864
        dd 594, 501, 1, 1, 0xFF505864
        dd 642, 503, 1, 1, 0xFF505864
        dd 637, 498, 1, 1, 0xFF505864
        dd 582, 495, 1, 1, 0xFF505864
        dd 610, 457, 1, 1, 0xFF505864
        dd 654, 466, 1, 1, 0xFF505864
        dd 589, 450, 1, 1, 0xFF505864
        dd 564, 464, 1, 1, 0xFF505864
        dd 606, 432, 1, 1, 0xFF505864
        dd 675, 460, 1, 1, 0xFF505864
        dd 643, 455, 1, 1, 0xFF505864
        dd 600, 425, 1, 1, 0xFF505864
        dd 621, 495, 1, 1, 0xFF505864
        dd 573, 500, 1, 1, 0xFF505864
        dd 620, 488, 1, 1, 0xFF505864
        dd 572, 425, 1, 1, 0xFF505864
        dd 659, 432, 1, 1, 0xFF505864
        dd 635, 456, 1, 1, 0xFF505864
        dd 634, 449, 1, 1, 0xFF505864
        dd 673, 446, 1, 1, 0xFF505864
        dd 634, 485, 1, 1, 0xFF505864
        dd 661, 448, 1, 1, 0xFF505864
        dd 664, 498, 1, 1, 0xFF505864
        dd 644, 500, 1, 1, 0xFF505864
        dd 665, 496, 1, 1, 0xFF505864
        dd 570, 458, 1, 1, 0xFF505864
        dd 602, 505, 1, 1, 0xFF505864
        dd 622, 460, 1, 1, 0xFF505864
        dd 590, 442, 12, 1, 0xFF736E6E
        dd 590, 443, 1, 1, 0xFF736E6E
        dd 591, 443, 10, 1, 0xFFAFAAAA
        dd 601, 443, 1, 1, 0xFF736E6E
        dd 590, 444, 1, 1, 0xFF736E6E
        dd 591, 444, 3, 1, 0xFFAFAAAA
        dd 594, 444, 4, 1, 0xFF4B4646
        dd 598, 444, 3, 1, 0xFFAFAAAA
        dd 601, 444, 1, 1, 0xFF736E6E
        dd 590, 445, 1, 1, 0xFF736E6E
        dd 591, 445, 2, 1, 0xFFAFAAAA
        dd 593, 445, 6, 1, 0xFF4B4646
        dd 599, 445, 2, 1, 0xFFAFAAAA
        dd 601, 445, 1, 1, 0xFF736E6E
        dd 590, 446, 1, 1, 0xFF736E6E
        dd 591, 446, 2, 1, 0xFFAFAAAA
        dd 593, 446, 2, 1, 0xFF4B4646
        dd 595, 446, 2, 1, 0xFF2D2828
        dd 597, 446, 2, 1, 0xFF4B4646
        dd 599, 446, 2, 1, 0xFFAFAAAA
        dd 601, 446, 1, 1, 0xFF736E6E
        dd 590, 447, 1, 1, 0xFF736E6E
        dd 591, 447, 2, 1, 0xFFAFAAAA
        dd 593, 447, 2, 1, 0xFF4B4646
        dd 595, 447, 2, 1, 0xFF2D2828
        dd 597, 447, 2, 1, 0xFF4B4646
        dd 599, 447, 2, 1, 0xFFAFAAAA
        dd 601, 447, 1, 1, 0xFF736E6E
        dd 590, 448, 1, 1, 0xFF736E6E
        dd 591, 448, 2, 1, 0xFFAFAAAA
        dd 593, 448, 6, 1, 0xFF4B4646
        dd 599, 448, 2, 1, 0xFFAFAAAA
        dd 601, 448, 1, 1, 0xFF736E6E
        dd 590, 449, 1, 1, 0xFF736E6E
        dd 591, 449, 3, 1, 0xFFAFAAAA
        dd 594, 449, 4, 1, 0xFF4B4646
        dd 598, 449, 3, 1, 0xFFAFAAAA
        dd 601, 449, 1, 1, 0xFF736E6E
        dd 590, 450, 1, 1, 0xFF736E6E
        dd 591, 450, 10, 1, 0xFFAFAAAA
        dd 601, 450, 1, 1, 0xFF736E6E
        dd 590, 451, 12, 1, 0xFF736E6E
        dd 640, 476, 12, 1, 0xFF736E6E
        dd 640, 477, 1, 1, 0xFF736E6E
        dd 641, 477, 10, 1, 0xFFAFAAAA
        dd 651, 477, 1, 1, 0xFF736E6E
        dd 640, 478, 1, 1, 0xFF736E6E
        dd 641, 478, 3, 1, 0xFFAFAAAA
        dd 644, 478, 4, 1, 0xFF4B4646
        dd 648, 478, 3, 1, 0xFFAFAAAA
        dd 651, 478, 1, 1, 0xFF736E6E
        dd 640, 479, 1, 1, 0xFF736E6E
        dd 641, 479, 2, 1, 0xFFAFAAAA
        dd 643, 479, 6, 1, 0xFF4B4646
        dd 649, 479, 2, 1, 0xFFAFAAAA
        dd 651, 479, 1, 1, 0xFF736E6E
        dd 640, 480, 1, 1, 0xFF736E6E
        dd 641, 480, 2, 1, 0xFFAFAAAA
        dd 643, 480, 2, 1, 0xFF4B4646
        dd 645, 480, 2, 1, 0xFF2D2828
        dd 647, 480, 2, 1, 0xFF4B4646
        dd 649, 480, 2, 1, 0xFFAFAAAA
        dd 651, 480, 1, 1, 0xFF736E6E
        dd 640, 481, 1, 1, 0xFF736E6E
        dd 641, 481, 2, 1, 0xFFAFAAAA
        dd 643, 481, 2, 1, 0xFF4B4646
        dd 645, 481, 2, 1, 0xFF2D2828
        dd 647, 481, 2, 1, 0xFF4B4646
        dd 649, 481, 2, 1, 0xFFAFAAAA
        dd 651, 481, 1, 1, 0xFF736E6E
        dd 640, 482, 1, 1, 0xFF736E6E
        dd 641, 482, 2, 1, 0xFFAFAAAA
        dd 643, 482, 6, 1, 0xFF4B4646
        dd 649, 482, 2, 1, 0xFFAFAAAA
        dd 651, 482, 1, 1, 0xFF736E6E
        dd 640, 483, 1, 1, 0xFF736E6E
        dd 641, 483, 3, 1, 0xFFAFAAAA
        dd 644, 483, 4, 1, 0xFF4B4646
        dd 648, 483, 3, 1, 0xFFAFAAAA
        dd 651, 483, 1, 1, 0xFF736E6E
        dd 640, 484, 1, 1, 0xFF736E6E
        dd 641, 484, 10, 1, 0xFFAFAAAA
        dd 651, 484, 1, 1, 0xFF736E6E
        dd 640, 485, 12, 1, 0xFF736E6E
        dd 720, 420, 150, 150, 0xFF303237
        dd 723, 423, 144, 144, 0xFF5F6978
        dd 751, 459, 1, 1, 0xFF505864
        dd 788, 565, 1, 1, 0xFF505864
        dd 782, 534, 1, 1, 0xFF505864
        dd 849, 545, 1, 1, 0xFF505864
        dd 821, 538, 1, 1, 0xFF505864
        dd 807, 512, 1, 1, 0xFF505864
        dd 787, 466, 1, 1, 0xFF505864
        dd 742, 523, 1, 1, 0xFF505864
        dd 733, 452, 1, 1, 0xFF505864
        dd 754, 538, 1, 1, 0xFF505864
        dd 738, 558, 1, 1, 0xFF505864
        dd 861, 519, 1, 1, 0xFF505864
        dd 857, 439, 1, 1, 0xFF505864
        dd 761, 527, 1, 1, 0xFF505864
        dd 758, 534, 1, 1, 0xFF505864
        dd 749, 540, 1, 1, 0xFF505864
        dd 779, 478, 1, 1, 0xFF505864
        dd 763, 487, 1, 1, 0xFF505864
        dd 840, 561, 1, 1, 0xFF505864
        dd 794, 490, 1, 1, 0xFF505864
        dd 848, 485, 1, 1, 0xFF505864
        dd 743, 427, 1, 1, 0xFF505864
        dd 769, 428, 1, 1, 0xFF505864
        dd 847, 476, 1, 1, 0xFF505864
        dd 826, 438, 1, 1, 0xFF505864
        dd 763, 429, 1, 1, 0xFF505864
        dd 737, 452, 1, 1, 0xFF505864
        dd 796, 554, 1, 1, 0xFF505864
        dd 853, 425, 1, 1, 0xFF505864
        dd 818, 541, 1, 1, 0xFF505864
        dd 796, 526, 1, 1, 0xFF505864
        dd 766, 444, 1, 1, 0xFF505864
        dd 857, 485, 1, 1, 0xFF505864
        dd 755, 564, 1, 1, 0xFF505864
        dd 740, 544, 1, 1, 0xFF505864
        dd 815, 543, 1, 1, 0xFF505864
        dd 839, 456, 1, 1, 0xFF505864
        dd 761, 543, 1, 1, 0xFF505864
        dd 808, 479, 1, 1, 0xFF505864
        dd 865, 435, 1, 1, 0xFF505864
        dd 739, 457, 1, 1, 0xFF505864
        dd 739, 510, 1, 1, 0xFF505864
        dd 732, 546, 1, 1, 0xFF505864
        dd 795, 463, 1, 1, 0xFF505864
        dd 810, 501, 1, 1, 0xFF505864
        dd 817, 553, 1, 1, 0xFF505864
        dd 782, 564, 1, 1, 0xFF505864
        dd 730, 535, 1, 1, 0xFF505864
        dd 779, 506, 1, 1, 0xFF505864
        dd 838, 544, 1, 1, 0xFF505864
        dd 858, 483, 1, 1, 0xFF505864
        dd 810, 461, 1, 1, 0xFF505864
        dd 741, 436, 1, 1, 0xFF505864
        dd 780, 523, 1, 1, 0xFF505864
        dd 774, 464, 1, 1, 0xFF505864
        dd 737, 562, 1, 1, 0xFF505864
        dd 725, 436, 1, 1, 0xFF505864
        dd 786, 512, 1, 1, 0xFF505864
        dd 758, 483, 1, 1, 0xFF505864
        dd 844, 529, 1, 1, 0xFF505864
        dd 750, 561, 1, 1, 0xFF505864
        dd 791, 461, 1, 1, 0xFF505864
        dd 805, 460, 1, 1, 0xFF505864
        dd 865, 479, 1, 1, 0xFF505864
        dd 772, 539, 1, 1, 0xFF505864
        dd 759, 441, 1, 1, 0xFF505864
        dd 746, 443, 1, 1, 0xFF505864
        dd 830, 442, 1, 1, 0xFF505864
        dd 812, 557, 1, 1, 0xFF505864
        dd 817, 538, 1, 1, 0xFF505864
        dd 755, 506, 1, 1, 0xFF505864
        dd 770, 428, 1, 1, 0xFF505864
        dd 812, 535, 1, 1, 0xFF505864
        dd 853, 537, 1, 1, 0xFF505864
        dd 751, 424, 1, 1, 0xFF505864
        dd 728, 433, 1, 1, 0xFF505864
        dd 826, 544, 1, 1, 0xFF505864
        dd 760, 543, 1, 1, 0xFF505864
        dd 746, 444, 1, 1, 0xFF505864
        dd 770, 482, 1, 1, 0xFF505864
        dd 728, 513, 1, 1, 0xFF505864
        dd 807, 538, 1, 1, 0xFF505864
        dd 789, 558, 1, 1, 0xFF505864
        dd 746, 440, 1, 1, 0xFF505864
        dd 852, 436, 1, 1, 0xFF505864
        dd 823, 513, 1, 1, 0xFF505864
        dd 761, 474, 1, 1, 0xFF505864
        dd 796, 440, 1, 1, 0xFF505864
        dd 731, 470, 1, 1, 0xFF505864
        dd 785, 446, 1, 1, 0xFF505864
        dd 809, 510, 1, 1, 0xFF505864
        dd 831, 441, 1, 1, 0xFF505864
        dd 804, 517, 1, 1, 0xFF505864
        dd 782, 493, 1, 1, 0xFF505864
        dd 778, 442, 1, 1, 0xFF505864
        dd 752, 436, 1, 1, 0xFF505864
        dd 798, 455, 1, 1, 0xFF505864
        dd 749, 465, 1, 1, 0xFF505864
        dd 797, 533, 1, 1, 0xFF505864
        dd 777, 537, 1, 1, 0xFF505864
        dd 815, 428, 1, 1, 0xFF505864
        dd 735, 481, 1, 1, 0xFF505864
        dd 779, 470, 1, 1, 0xFF505864
        dd 824, 537, 1, 1, 0xFF505864
        dd 838, 458, 1, 1, 0xFF505864
        dd 855, 443, 1, 1, 0xFF505864
        dd 755, 526, 1, 1, 0xFF505864
        dd 789, 561, 1, 1, 0xFF505864
        dd 724, 553, 1, 1, 0xFF505864
        dd 728, 503, 1, 1, 0xFF505864
        dd 806, 446, 1, 1, 0xFF505864
        dd 821, 474, 1, 1, 0xFF505864
        dd 730, 535, 1, 1, 0xFF505864
        dd 794, 472, 1, 1, 0xFF505864
        dd 748, 478, 1, 1, 0xFF505864
        dd 746, 516, 1, 1, 0xFF505864
        dd 743, 450, 1, 1, 0xFF505864
        dd 801, 453, 1, 1, 0xFF505864
        dd 732, 526, 1, 1, 0xFF505864
        dd 849, 447, 1, 1, 0xFF505864
        dd 865, 499, 1, 1, 0xFF505864
        dd 753, 537, 1, 1, 0xFF505864
        dd 850, 535, 1, 1, 0xFF505864
        dd 753, 489, 1, 1, 0xFF505864
        dd 842, 563, 1, 1, 0xFF505864
        dd 757, 457, 12, 1, 0xFF736E6E
        dd 757, 458, 1, 1, 0xFF736E6E
        dd 758, 458, 10, 1, 0xFFAFAAAA
        dd 768, 458, 1, 1, 0xFF736E6E
        dd 757, 459, 1, 1, 0xFF736E6E
        dd 758, 459, 3, 1, 0xFFAFAAAA
        dd 761, 459, 4, 1, 0xFF4B4646
        dd 765, 459, 3, 1, 0xFFAFAAAA
        dd 768, 459, 1, 1, 0xFF736E6E
        dd 757, 460, 1, 1, 0xFF736E6E
        dd 758, 460, 2, 1, 0xFFAFAAAA
        dd 760, 460, 6, 1, 0xFF4B4646
        dd 766, 460, 2, 1, 0xFFAFAAAA
        dd 768, 460, 1, 1, 0xFF736E6E
        dd 757, 461, 1, 1, 0xFF736E6E
        dd 758, 461, 2, 1, 0xFFAFAAAA
        dd 760, 461, 2, 1, 0xFF4B4646
        dd 762, 461, 2, 1, 0xFF2D2828
        dd 764, 461, 2, 1, 0xFF4B4646
        dd 766, 461, 2, 1, 0xFFAFAAAA
        dd 768, 461, 1, 1, 0xFF736E6E
        dd 757, 462, 1, 1, 0xFF736E6E
        dd 758, 462, 2, 1, 0xFFAFAAAA
        dd 760, 462, 2, 1, 0xFF4B4646
        dd 762, 462, 2, 1, 0xFF2D2828
        dd 764, 462, 2, 1, 0xFF4B4646
        dd 766, 462, 2, 1, 0xFFAFAAAA
        dd 768, 462, 1, 1, 0xFF736E6E
        dd 757, 463, 1, 1, 0xFF736E6E
        dd 758, 463, 2, 1, 0xFFAFAAAA
        dd 760, 463, 6, 1, 0xFF4B4646
        dd 766, 463, 2, 1, 0xFFAFAAAA
        dd 768, 463, 1, 1, 0xFF736E6E
        dd 757, 464, 1, 1, 0xFF736E6E
        dd 758, 464, 3, 1, 0xFFAFAAAA
        dd 761, 464, 4, 1, 0xFF4B4646
        dd 765, 464, 3, 1, 0xFFAFAAAA
        dd 768, 464, 1, 1, 0xFF736E6E
        dd 757, 465, 1, 1, 0xFF736E6E
        dd 758, 465, 10, 1, 0xFFAFAAAA
        dd 768, 465, 1, 1, 0xFF736E6E
        dd 757, 466, 12, 1, 0xFF736E6E
        dd 820, 516, 12, 1, 0xFF736E6E
        dd 820, 517, 1, 1, 0xFF736E6E
        dd 821, 517, 10, 1, 0xFFAFAAAA
        dd 831, 517, 1, 1, 0xFF736E6E
        dd 820, 518, 1, 1, 0xFF736E6E
        dd 821, 518, 3, 1, 0xFFAFAAAA
        dd 824, 518, 4, 1, 0xFF4B4646
        dd 828, 518, 3, 1, 0xFFAFAAAA
        dd 831, 518, 1, 1, 0xFF736E6E
        dd 820, 519, 1, 1, 0xFF736E6E
        dd 821, 519, 2, 1, 0xFFAFAAAA
        dd 823, 519, 6, 1, 0xFF4B4646
        dd 829, 519, 2, 1, 0xFFAFAAAA
        dd 831, 519, 1, 1, 0xFF736E6E
        dd 820, 520, 1, 1, 0xFF736E6E
        dd 821, 520, 2, 1, 0xFFAFAAAA
        dd 823, 520, 2, 1, 0xFF4B4646
        dd 825, 520, 2, 1, 0xFF2D2828
        dd 827, 520, 2, 1, 0xFF4B4646
        dd 829, 520, 2, 1, 0xFFAFAAAA
        dd 831, 520, 1, 1, 0xFF736E6E
        dd 820, 521, 1, 1, 0xFF736E6E
        dd 821, 521, 2, 1, 0xFFAFAAAA
        dd 823, 521, 2, 1, 0xFF4B4646
        dd 825, 521, 2, 1, 0xFF2D2828
        dd 827, 521, 2, 1, 0xFF4B4646
        dd 829, 521, 2, 1, 0xFFAFAAAA
        dd 831, 521, 1, 1, 0xFF736E6E
        dd 820, 522, 1, 1, 0xFF736E6E
        dd 821, 522, 2, 1, 0xFFAFAAAA
        dd 823, 522, 6, 1, 0xFF4B4646
        dd 829, 522, 2, 1, 0xFFAFAAAA
        dd 831, 522, 1, 1, 0xFF736E6E
        dd 820, 523, 1, 1, 0xFF736E6E
        dd 821, 523, 3, 1, 0xFFAFAAAA
        dd 824, 523, 4, 1, 0xFF4B4646
        dd 828, 523, 3, 1, 0xFFAFAAAA
        dd 831, 523, 1, 1, 0xFF736E6E
        dd 820, 524, 1, 1, 0xFF736E6E
        dd 821, 524, 10, 1, 0xFFAFAAAA
        dd 831, 524, 1, 1, 0xFF736E6E
        dd 820, 525, 12, 1, 0xFF736E6E
        dd 370, 665, 100, 45, 0xFF303237
        dd 373, 668, 94, 39, 0xFF545C69
        dd 373, 686, 94, 2, 0xFF464E5A
        dd 450, 673, 8, 8, 0xFF374682
        dd 451, 674, 6, 6, 0xFF303237
        dd 500, 665, 120, 45, 0xFF303237
        dd 503, 668, 114, 39, 0xFF5F6978
        dd 503, 686, 114, 2, 0xFF464E5A
        dd 600, 673, 8, 8, 0xFF374682
        dd 601, 674, 6, 6, 0xFF303237
        dd 650, 665, 100, 45, 0xFF303237
        dd 653, 668, 94, 39, 0xFF545C69
        dd 653, 686, 94, 2, 0xFF464E5A
        dd 730, 673, 8, 8, 0xFF374682
        dd 731, 674, 6, 6, 0xFF303237
        dd 780, 665, 100, 45, 0xFF303237
        dd 783, 668, 94, 39, 0xFF5F6978
        dd 783, 686, 94, 2, 0xFF464E5A
        dd 860, 673, 8, 8, 0xFF374682
        dd 861, 674, 6, 6, 0xFF303237
        dd 990, 430, 120, 110, 0xFF303237
        dd 993, 433, 114, 104, 0xFF545C69
        dd 1104, 441, 1, 1, 0xFF505864
        dd 1043, 519, 1, 1, 0xFF505864
        dd 1066, 533, 1, 1, 0xFF505864
        dd 1009, 477, 1, 1, 0xFF505864
        dd 1010, 485, 1, 1, 0xFF505864
        dd 1102, 448, 1, 1, 0xFF505864
        dd 1020, 503, 1, 1, 0xFF505864
        dd 1050, 470, 1, 1, 0xFF505864
        dd 1095, 490, 1, 1, 0xFF505864
        dd 1021, 493, 1, 1, 0xFF505864
        dd 1054, 461, 1, 1, 0xFF505864
        dd 1022, 450, 1, 1, 0xFF505864
        dd 1048, 469, 1, 1, 0xFF505864
        dd 1028, 493, 1, 1, 0xFF505864
        dd 1075, 435, 1, 1, 0xFF505864
        dd 1071, 460, 1, 1, 0xFF505864
        dd 1043, 534, 1, 1, 0xFF505864
        dd 1077, 481, 1, 1, 0xFF505864
        dd 1066, 480, 1, 1, 0xFF505864
        dd 1105, 500, 1, 1, 0xFF505864
        dd 1004, 434, 1, 1, 0xFF505864
        dd 998, 528, 1, 1, 0xFF505864
        dd 1085, 506, 1, 1, 0xFF505864
        dd 1032, 518, 1, 1, 0xFF505864
        dd 1101, 437, 1, 1, 0xFF505864
        dd 1078, 434, 1, 1, 0xFF505864
        dd 1051, 443, 1, 1, 0xFF505864
        dd 1037, 498, 1, 1, 0xFF505864
        dd 1001, 487, 1, 1, 0xFF505864
        dd 1094, 446, 1, 1, 0xFF505864
        dd 1029, 470, 1, 1, 0xFF505864
        dd 1005, 493, 1, 1, 0xFF505864
        dd 1034, 506, 1, 1, 0xFF505864
        dd 994, 483, 1, 1, 0xFF505864
        dd 1005, 444, 1, 1, 0xFF505864
        dd 1009, 505, 1, 1, 0xFF505864
        dd 1055, 515, 1, 1, 0xFF505864
        dd 1103, 488, 1, 1, 0xFF505864
        dd 1085, 438, 1, 1, 0xFF505864
        dd 1009, 526, 1, 1, 0xFF505864
        dd 1011, 523, 1, 1, 0xFF505864
        dd 1101, 476, 1, 1, 0xFF505864
        dd 1099, 441, 1, 1, 0xFF505864
        dd 1032, 511, 1, 1, 0xFF505864
        dd 1046, 521, 1, 1, 0xFF505864
        dd 1037, 491, 1, 1, 0xFF505864
        dd 1090, 501, 1, 1, 0xFF505864
        dd 1095, 445, 1, 1, 0xFF505864
        dd 1092, 517, 1, 1, 0xFF505864
        dd 1057, 482, 1, 1, 0xFF505864
        dd 1036, 511, 1, 1, 0xFF505864
        dd 1074, 449, 1, 1, 0xFF505864
        dd 999, 492, 1, 1, 0xFF505864
        dd 1021, 497, 1, 1, 0xFF505864
        dd 1057, 515, 1, 1, 0xFF505864
        dd 1104, 472, 1, 1, 0xFF505864
        dd 1032, 467, 1, 1, 0xFF505864
        dd 1084, 528, 1, 1, 0xFF505864
        dd 1003, 509, 1, 1, 0xFF505864
        dd 1072, 449, 1, 1, 0xFF505864
        dd 1082, 499, 1, 1, 0xFF505864
        dd 999, 457, 1, 1, 0xFF505864
        dd 1094, 526, 1, 1, 0xFF505864
        dd 1051, 434, 1, 1, 0xFF505864
        dd 999, 436, 1, 1, 0xFF505864
        dd 1043, 461, 1, 1, 0xFF505864
        dd 1089, 514, 1, 1, 0xFF505864
        dd 1086, 481, 1, 1, 0xFF505864
        dd 1077, 493, 1, 1, 0xFF505864
        dd 1007, 438, 1, 1, 0xFF505864
        dd 1063, 520, 1, 1, 0xFF505864
        dd 1101, 469, 1, 1, 0xFF505864
        dd 1104, 460, 1, 1, 0xFF505864
        dd 1020, 457, 12, 1, 0xFF736E6E
        dd 1020, 458, 1, 1, 0xFF736E6E
        dd 1021, 458, 10, 1, 0xFFAFAAAA
        dd 1031, 458, 1, 1, 0xFF736E6E
        dd 1020, 459, 1, 1, 0xFF736E6E
        dd 1021, 459, 3, 1, 0xFFAFAAAA
        dd 1024, 459, 4, 1, 0xFF4B4646
        dd 1028, 459, 3, 1, 0xFFAFAAAA
        dd 1031, 459, 1, 1, 0xFF736E6E
        dd 1020, 460, 1, 1, 0xFF736E6E
        dd 1021, 460, 2, 1, 0xFFAFAAAA
        dd 1023, 460, 6, 1, 0xFF4B4646
        dd 1029, 460, 2, 1, 0xFFAFAAAA
        dd 1031, 460, 1, 1, 0xFF736E6E
        dd 1020, 461, 1, 1, 0xFF736E6E
        dd 1021, 461, 2, 1, 0xFFAFAAAA
        dd 1023, 461, 2, 1, 0xFF4B4646
        dd 1025, 461, 2, 1, 0xFF2D2828
        dd 1027, 461, 2, 1, 0xFF4B4646
        dd 1029, 461, 2, 1, 0xFFAFAAAA
        dd 1031, 461, 1, 1, 0xFF736E6E
        dd 1020, 462, 1, 1, 0xFF736E6E
        dd 1021, 462, 2, 1, 0xFFAFAAAA
        dd 1023, 462, 2, 1, 0xFF4B4646
        dd 1025, 462, 2, 1, 0xFF2D2828
        dd 1027, 462, 2, 1, 0xFF4B4646
        dd 1029, 462, 2, 1, 0xFFAFAAAA
        dd 1031, 462, 1, 1, 0xFF736E6E
        dd 1020, 463, 1, 1, 0xFF736E6E
        dd 1021, 463, 2, 1, 0xFFAFAAAA
        dd 1023, 463, 6, 1, 0xFF4B4646
        dd 1029, 463, 2, 1, 0xFFAFAAAA
        dd 1031, 463, 1, 1, 0xFF736E6E
        dd 1020, 464, 1, 1, 0xFF736E6E
        dd 1021, 464, 3, 1, 0xFFAFAAAA
        dd 1024, 464, 4, 1, 0xFF4B4646
        dd 1028, 464, 3, 1, 0xFFAFAAAA
        dd 1031, 464, 1, 1, 0xFF736E6E
        dd 1020, 465, 1, 1, 0xFF736E6E
        dd 1021, 465, 10, 1, 0xFFAFAAAA
        dd 1031, 465, 1, 1, 0xFF736E6E
        dd 1020, 466, 12, 1, 0xFF736E6E
        dd 1070, 500, 12, 1, 0xFF736E6E
        dd 1070, 501, 1, 1, 0xFF736E6E
        dd 1071, 501, 10, 1, 0xFFAFAAAA
        dd 1081, 501, 1, 1, 0xFF736E6E
        dd 1070, 502, 1, 1, 0xFF736E6E
        dd 1071, 502, 3, 1, 0xFFAFAAAA
        dd 1074, 502, 4, 1, 0xFF4B4646
        dd 1078, 502, 3, 1, 0xFFAFAAAA
        dd 1081, 502, 1, 1, 0xFF736E6E
        dd 1070, 503, 1, 1, 0xFF736E6E
        dd 1071, 503, 2, 1, 0xFFAFAAAA
        dd 1073, 503, 6, 1, 0xFF4B4646
        dd 1079, 503, 2, 1, 0xFFAFAAAA
        dd 1081, 503, 1, 1, 0xFF736E6E
        dd 1070, 504, 1, 1, 0xFF736E6E
        dd 1071, 504, 2, 1, 0xFFAFAAAA
        dd 1073, 504, 2, 1, 0xFF4B4646
        dd 1075, 504, 2, 1, 0xFF2D2828
        dd 1077, 504, 2, 1, 0xFF4B4646
        dd 1079, 504, 2, 1, 0xFFAFAAAA
        dd 1081, 504, 1, 1, 0xFF736E6E
        dd 1070, 505, 1, 1, 0xFF736E6E
        dd 1071, 505, 2, 1, 0xFFAFAAAA
        dd 1073, 505, 2, 1, 0xFF4B4646
        dd 1075, 505, 2, 1, 0xFF2D2828
        dd 1077, 505, 2, 1, 0xFF4B4646
        dd 1079, 505, 2, 1, 0xFFAFAAAA
        dd 1081, 505, 1, 1, 0xFF736E6E
        dd 1070, 506, 1, 1, 0xFF736E6E
        dd 1071, 506, 2, 1, 0xFFAFAAAA
        dd 1073, 506, 6, 1, 0xFF4B4646
        dd 1079, 506, 2, 1, 0xFFAFAAAA
        dd 1081, 506, 1, 1, 0xFF736E6E
        dd 1070, 507, 1, 1, 0xFF736E6E
        dd 1071, 507, 3, 1, 0xFFAFAAAA
        dd 1074, 507, 4, 1, 0xFF4B4646
        dd 1078, 507, 3, 1, 0xFFAFAAAA
        dd 1081, 507, 1, 1, 0xFF736E6E
        dd 1070, 508, 1, 1, 0xFF736E6E
        dd 1071, 508, 10, 1, 0xFFAFAAAA
        dd 1081, 508, 1, 1, 0xFF736E6E
        dd 1070, 509, 12, 1, 0xFF736E6E
        dd 1140, 430, 110, 160, 0xFF303237
        dd 1143, 433, 104, 154, 0xFF5F6978
        dd 1180, 472, 1, 1, 0xFF505864
        dd 1189, 551, 1, 1, 0xFF505864
        dd 1157, 491, 1, 1, 0xFF505864
        dd 1224, 530, 1, 1, 0xFF505864
        dd 1184, 438, 1, 1, 0xFF505864
        dd 1175, 463, 1, 1, 0xFF505864
        dd 1146, 585, 1, 1, 0xFF505864
        dd 1190, 473, 1, 1, 0xFF505864
        dd 1165, 569, 1, 1, 0xFF505864
        dd 1198, 488, 1, 1, 0xFF505864
        dd 1216, 444, 1, 1, 0xFF505864
        dd 1175, 542, 1, 1, 0xFF505864
        dd 1207, 529, 1, 1, 0xFF505864
        dd 1237, 478, 1, 1, 0xFF505864
        dd 1194, 512, 1, 1, 0xFF505864
        dd 1180, 443, 1, 1, 0xFF505864
        dd 1215, 441, 1, 1, 0xFF505864
        dd 1228, 446, 1, 1, 0xFF505864
        dd 1182, 537, 1, 1, 0xFF505864
        dd 1223, 583, 1, 1, 0xFF505864
        dd 1189, 526, 1, 1, 0xFF505864
        dd 1176, 583, 1, 1, 0xFF505864
        dd 1206, 484, 1, 1, 0xFF505864
        dd 1163, 553, 1, 1, 0xFF505864
        dd 1194, 464, 1, 1, 0xFF505864
        dd 1236, 476, 1, 1, 0xFF505864
        dd 1239, 548, 1, 1, 0xFF505864
        dd 1211, 494, 1, 1, 0xFF505864
        dd 1212, 448, 1, 1, 0xFF505864
        dd 1150, 584, 1, 1, 0xFF505864
        dd 1170, 487, 1, 1, 0xFF505864
        dd 1211, 461, 1, 1, 0xFF505864
        dd 1147, 464, 1, 1, 0xFF505864
        dd 1159, 496, 1, 1, 0xFF505864
        dd 1209, 437, 1, 1, 0xFF505864
        dd 1184, 528, 1, 1, 0xFF505864
        dd 1205, 476, 1, 1, 0xFF505864
        dd 1233, 488, 1, 1, 0xFF505864
        dd 1219, 438, 1, 1, 0xFF505864
        dd 1230, 451, 1, 1, 0xFF505864
        dd 1156, 583, 1, 1, 0xFF505864
        dd 1195, 531, 1, 1, 0xFF505864
        dd 1227, 479, 1, 1, 0xFF505864
        dd 1232, 494, 1, 1, 0xFF505864
        dd 1217, 459, 1, 1, 0xFF505864
        dd 1240, 452, 1, 1, 0xFF505864
        dd 1187, 541, 1, 1, 0xFF505864
        dd 1235, 501, 1, 1, 0xFF505864
        dd 1182, 474, 1, 1, 0xFF505864
        dd 1177, 471, 1, 1, 0xFF505864
        dd 1173, 444, 1, 1, 0xFF505864
        dd 1160, 440, 1, 1, 0xFF505864
        dd 1194, 513, 1, 1, 0xFF505864
        dd 1194, 552, 1, 1, 0xFF505864
        dd 1208, 438, 1, 1, 0xFF505864
        dd 1176, 517, 1, 1, 0xFF505864
        dd 1238, 523, 1, 1, 0xFF505864
        dd 1216, 559, 1, 1, 0xFF505864
        dd 1243, 510, 1, 1, 0xFF505864
        dd 1197, 443, 1, 1, 0xFF505864
        dd 1204, 575, 1, 1, 0xFF505864
        dd 1220, 494, 1, 1, 0xFF505864
        dd 1231, 460, 1, 1, 0xFF505864
        dd 1196, 538, 1, 1, 0xFF505864
        dd 1178, 512, 1, 1, 0xFF505864
        dd 1144, 471, 1, 1, 0xFF505864
        dd 1169, 497, 1, 1, 0xFF505864
        dd 1157, 486, 1, 1, 0xFF505864
        dd 1153, 469, 1, 1, 0xFF505864
        dd 1164, 567, 1, 1, 0xFF505864
        dd 1215, 547, 1, 1, 0xFF505864
        dd 1174, 516, 1, 1, 0xFF505864
        dd 1172, 514, 1, 1, 0xFF505864
        dd 1240, 542, 1, 1, 0xFF505864
        dd 1237, 513, 1, 1, 0xFF505864
        dd 1159, 473, 1, 1, 0xFF505864
        dd 1178, 557, 1, 1, 0xFF505864
        dd 1205, 534, 1, 1, 0xFF505864
        dd 1199, 570, 1, 1, 0xFF505864
        dd 1158, 515, 1, 1, 0xFF505864
        dd 1182, 568, 1, 1, 0xFF505864
        dd 1227, 471, 1, 1, 0xFF505864
        dd 1213, 520, 1, 1, 0xFF505864
        dd 1222, 476, 1, 1, 0xFF505864
        dd 1183, 504, 1, 1, 0xFF505864
        dd 1179, 551, 1, 1, 0xFF505864
        dd 1236, 443, 1, 1, 0xFF505864
        dd 1181, 458, 1, 1, 0xFF505864
        dd 1205, 454, 1, 1, 0xFF505864
        dd 1172, 456, 1, 1, 0xFF505864
        dd 1216, 567, 1, 1, 0xFF505864
        dd 1206, 487, 1, 1, 0xFF505864
        dd 1144, 476, 1, 1, 0xFF505864
        dd 1194, 485, 1, 1, 0xFF505864
        dd 1232, 499, 1, 1, 0xFF505864
        dd 1209, 489, 1, 1, 0xFF505864
        dd 1218, 508, 1, 1, 0xFF505864
        dd 1167, 470, 12, 1, 0xFF736E6E
        dd 1167, 471, 1, 1, 0xFF736E6E
        dd 1168, 471, 10, 1, 0xFFAFAAAA
        dd 1178, 471, 1, 1, 0xFF736E6E
        dd 1167, 472, 1, 1, 0xFF736E6E
        dd 1168, 472, 3, 1, 0xFFAFAAAA
        dd 1171, 472, 4, 1, 0xFF4B4646
        dd 1175, 472, 3, 1, 0xFFAFAAAA
        dd 1178, 472, 1, 1, 0xFF736E6E
        dd 1167, 473, 1, 1, 0xFF736E6E
        dd 1168, 473, 2, 1, 0xFFAFAAAA
        dd 1170, 473, 6, 1, 0xFF4B4646
        dd 1176, 473, 2, 1, 0xFFAFAAAA
        dd 1178, 473, 1, 1, 0xFF736E6E
        dd 1167, 474, 1, 1, 0xFF736E6E
        dd 1168, 474, 2, 1, 0xFFAFAAAA
        dd 1170, 474, 2, 1, 0xFF4B4646
        dd 1172, 474, 2, 1, 0xFF2D2828
        dd 1174, 474, 2, 1, 0xFF4B4646
        dd 1176, 474, 2, 1, 0xFFAFAAAA
        dd 1178, 474, 1, 1, 0xFF736E6E
        dd 1167, 475, 1, 1, 0xFF736E6E
        dd 1168, 475, 2, 1, 0xFFAFAAAA
        dd 1170, 475, 2, 1, 0xFF4B4646
        dd 1172, 475, 2, 1, 0xFF2D2828
        dd 1174, 475, 2, 1, 0xFF4B4646
        dd 1176, 475, 2, 1, 0xFFAFAAAA
        dd 1178, 475, 1, 1, 0xFF736E6E
        dd 1167, 476, 1, 1, 0xFF736E6E
        dd 1168, 476, 2, 1, 0xFFAFAAAA
        dd 1170, 476, 6, 1, 0xFF4B4646
        dd 1176, 476, 2, 1, 0xFFAFAAAA
        dd 1178, 476, 1, 1, 0xFF736E6E
        dd 1167, 477, 1, 1, 0xFF736E6E
        dd 1168, 477, 3, 1, 0xFFAFAAAA
        dd 1171, 477, 4, 1, 0xFF4B4646
        dd 1175, 477, 3, 1, 0xFFAFAAAA
        dd 1178, 477, 1, 1, 0xFF736E6E
        dd 1167, 478, 1, 1, 0xFF736E6E
        dd 1168, 478, 10, 1, 0xFFAFAAAA
        dd 1178, 478, 1, 1, 0xFF736E6E
        dd 1167, 479, 12, 1, 0xFF736E6E
        dd 990, 590, 120, 100, 0xFF303237
        dd 993, 593, 114, 94, 0xFF545C69
        dd 1019, 617, 1, 1, 0xFF505864
        dd 1053, 673, 1, 1, 0xFF505864
        dd 1044, 647, 1, 1, 0xFF505864
        dd 1010, 668, 1, 1, 0xFF505864
        dd 1020, 654, 1, 1, 0xFF505864
        dd 1102, 633, 1, 1, 0xFF505864
        dd 1065, 658, 1, 1, 0xFF505864
        dd 1027, 678, 1, 1, 0xFF505864
        dd 997, 600, 1, 1, 0xFF505864
        dd 1088, 619, 1, 1, 0xFF505864
        dd 1034, 671, 1, 1, 0xFF505864
        dd 1017, 654, 1, 1, 0xFF505864
        dd 1005, 681, 1, 1, 0xFF505864
        dd 1104, 655, 1, 1, 0xFF505864
        dd 1055, 659, 1, 1, 0xFF505864
        dd 1009, 619, 1, 1, 0xFF505864
        dd 1074, 613, 1, 1, 0xFF505864
        dd 1018, 673, 1, 1, 0xFF505864
        dd 1063, 620, 1, 1, 0xFF505864
        dd 1010, 605, 1, 1, 0xFF505864
        dd 1066, 645, 1, 1, 0xFF505864
        dd 1004, 627, 1, 1, 0xFF505864
        dd 1010, 635, 1, 1, 0xFF505864
        dd 1018, 685, 1, 1, 0xFF505864
        dd 1021, 623, 1, 1, 0xFF505864
        dd 1061, 660, 1, 1, 0xFF505864
        dd 1041, 614, 1, 1, 0xFF505864
        dd 1056, 598, 1, 1, 0xFF505864
        dd 1019, 605, 1, 1, 0xFF505864
        dd 1070, 612, 1, 1, 0xFF505864
        dd 1002, 672, 1, 1, 0xFF505864
        dd 1076, 663, 1, 1, 0xFF505864
        dd 1100, 639, 1, 1, 0xFF505864
        dd 1012, 598, 1, 1, 0xFF505864
        dd 999, 651, 1, 1, 0xFF505864
        dd 1097, 682, 1, 1, 0xFF505864
        dd 1067, 603, 1, 1, 0xFF505864
        dd 1018, 685, 1, 1, 0xFF505864
        dd 1020, 604, 1, 1, 0xFF505864
        dd 1001, 636, 1, 1, 0xFF505864
        dd 1091, 597, 1, 1, 0xFF505864
        dd 1039, 662, 1, 1, 0xFF505864
        dd 1075, 612, 1, 1, 0xFF505864
        dd 1069, 658, 1, 1, 0xFF505864
        dd 1071, 624, 1, 1, 0xFF505864
        dd 1091, 596, 1, 1, 0xFF505864
        dd 1045, 664, 1, 1, 0xFF505864
        dd 1051, 618, 1, 1, 0xFF505864
        dd 1014, 658, 1, 1, 0xFF505864
        dd 1015, 652, 1, 1, 0xFF505864
        dd 1091, 669, 1, 1, 0xFF505864
        dd 1048, 633, 1, 1, 0xFF505864
        dd 1006, 630, 1, 1, 0xFF505864
        dd 1091, 666, 1, 1, 0xFF505864
        dd 1066, 680, 1, 1, 0xFF505864
        dd 1001, 609, 1, 1, 0xFF505864
        dd 1035, 626, 1, 1, 0xFF505864
        dd 1098, 634, 1, 1, 0xFF505864
        dd 1085, 678, 1, 1, 0xFF505864
        dd 1000, 673, 1, 1, 0xFF505864
        dd 1077, 613, 1, 1, 0xFF505864
        dd 1077, 606, 1, 1, 0xFF505864
        dd 1007, 671, 1, 1, 0xFF505864
        dd 1096, 643, 1, 1, 0xFF505864
        dd 1017, 660, 1, 1, 0xFF505864
        dd 1069, 595, 1, 1, 0xFF505864
        dd 1020, 615, 12, 1, 0xFF736E6E
        dd 1020, 616, 1, 1, 0xFF736E6E
        dd 1021, 616, 10, 1, 0xFFAFAAAA
        dd 1031, 616, 1, 1, 0xFF736E6E
        dd 1020, 617, 1, 1, 0xFF736E6E
        dd 1021, 617, 3, 1, 0xFFAFAAAA
        dd 1024, 617, 4, 1, 0xFF4B4646
        dd 1028, 617, 3, 1, 0xFFAFAAAA
        dd 1031, 617, 1, 1, 0xFF736E6E
        dd 1020, 618, 1, 1, 0xFF736E6E
        dd 1021, 618, 2, 1, 0xFFAFAAAA
        dd 1023, 618, 6, 1, 0xFF4B4646
        dd 1029, 618, 2, 1, 0xFFAFAAAA
        dd 1031, 618, 1, 1, 0xFF736E6E
        dd 1020, 619, 1, 1, 0xFF736E6E
        dd 1021, 619, 2, 1, 0xFFAFAAAA
        dd 1023, 619, 2, 1, 0xFF4B4646
        dd 1025, 619, 2, 1, 0xFF2D2828
        dd 1027, 619, 2, 1, 0xFF4B4646
        dd 1029, 619, 2, 1, 0xFFAFAAAA
        dd 1031, 619, 1, 1, 0xFF736E6E
        dd 1020, 620, 1, 1, 0xFF736E6E
        dd 1021, 620, 2, 1, 0xFFAFAAAA
        dd 1023, 620, 2, 1, 0xFF4B4646
        dd 1025, 620, 2, 1, 0xFF2D2828
        dd 1027, 620, 2, 1, 0xFF4B4646
        dd 1029, 620, 2, 1, 0xFFAFAAAA
        dd 1031, 620, 1, 1, 0xFF736E6E
        dd 1020, 621, 1, 1, 0xFF736E6E
        dd 1021, 621, 2, 1, 0xFFAFAAAA
        dd 1023, 621, 6, 1, 0xFF4B4646
        dd 1029, 621, 2, 1, 0xFFAFAAAA
        dd 1031, 621, 1, 1, 0xFF736E6E
        dd 1020, 622, 1, 1, 0xFF736E6E
        dd 1021, 622, 3, 1, 0xFFAFAAAA
        dd 1024, 622, 4, 1, 0xFF4B4646
        dd 1028, 622, 3, 1, 0xFFAFAAAA
        dd 1031, 622, 1, 1, 0xFF736E6E
        dd 1020, 623, 1, 1, 0xFF736E6E
        dd 1021, 623, 10, 1, 0xFFAFAAAA
        dd 1031, 623, 1, 1, 0xFF736E6E
        dd 1020, 624, 12, 1, 0xFF736E6E
        dd 1070, 653, 12, 1, 0xFF736E6E
        dd 1070, 654, 1, 1, 0xFF736E6E
        dd 1071, 654, 10, 1, 0xFFAFAAAA
        dd 1081, 654, 1, 1, 0xFF736E6E
        dd 1070, 655, 1, 1, 0xFF736E6E
        dd 1071, 655, 3, 1, 0xFFAFAAAA
        dd 1074, 655, 4, 1, 0xFF4B4646
        dd 1078, 655, 3, 1, 0xFFAFAAAA
        dd 1081, 655, 1, 1, 0xFF736E6E
        dd 1070, 656, 1, 1, 0xFF736E6E
        dd 1071, 656, 2, 1, 0xFFAFAAAA
        dd 1073, 656, 6, 1, 0xFF4B4646
        dd 1079, 656, 2, 1, 0xFFAFAAAA
        dd 1081, 656, 1, 1, 0xFF736E6E
        dd 1070, 657, 1, 1, 0xFF736E6E
        dd 1071, 657, 2, 1, 0xFFAFAAAA
        dd 1073, 657, 2, 1, 0xFF4B4646
        dd 1075, 657, 2, 1, 0xFF2D2828
        dd 1077, 657, 2, 1, 0xFF4B4646
        dd 1079, 657, 2, 1, 0xFFAFAAAA
        dd 1081, 657, 1, 1, 0xFF736E6E
        dd 1070, 658, 1, 1, 0xFF736E6E
        dd 1071, 658, 2, 1, 0xFFAFAAAA
        dd 1073, 658, 2, 1, 0xFF4B4646
        dd 1075, 658, 2, 1, 0xFF2D2828
        dd 1077, 658, 2, 1, 0xFF4B4646
        dd 1079, 658, 2, 1, 0xFFAFAAAA
        dd 1081, 658, 1, 1, 0xFF736E6E
        dd 1070, 659, 1, 1, 0xFF736E6E
        dd 1071, 659, 2, 1, 0xFFAFAAAA
        dd 1073, 659, 6, 1, 0xFF4B4646
        dd 1079, 659, 2, 1, 0xFFAFAAAA
        dd 1081, 659, 1, 1, 0xFF736E6E
        dd 1070, 660, 1, 1, 0xFF736E6E
        dd 1071, 660, 3, 1, 0xFFAFAAAA
        dd 1074, 660, 4, 1, 0xFF4B4646
        dd 1078, 660, 3, 1, 0xFFAFAAAA
        dd 1081, 660, 1, 1, 0xFF736E6E
        dd 1070, 661, 1, 1, 0xFF736E6E
        dd 1071, 661, 10, 1, 0xFFAFAAAA
        dd 1081, 661, 1, 1, 0xFF736E6E
        dd 1070, 662, 12, 1, 0xFF736E6E
        dd 426, 215, 6, 1, 0xFF0F0F0F
        dd 448, 215, 6, 1, 0xFF0F0F0F
        dd 422, 216, 36, 1, 0xFF7E7878
        dd 421, 217, 1, 1, 0xFF7E7878
        dd 422, 217, 36, 1, 0xFFD2C8C8
        dd 458, 217, 1, 1, 0xFF7E7878
        dd 420, 218, 1, 1, 0xFF1E1EC8
        dd 421, 218, 7, 1, 0xFFD2C8C8
        dd 428, 218, 1, 1, 0xFF7E7878
        dd 429, 218, 20, 1, 0xFF826450
        dd 449, 218, 1, 1, 0xFF7E7878
        dd 450, 218, 9, 1, 0xFFD2C8C8
        dd 459, 218, 1, 1, 0xFFB4F0FF
        dd 420, 219, 1, 1, 0xFF1E1EC8
        dd 421, 219, 6, 1, 0xFFD2C8C8
        dd 427, 219, 1, 1, 0xFF7E7878
        dd 428, 219, 2, 1, 0xFF503C32
        dd 430, 219, 1, 1, 0xFF7E7878
        dd 431, 219, 17, 1, 0xFFD2C8C8
        dd 448, 219, 1, 1, 0xFF7E7878
        dd 449, 219, 4, 1, 0xFF503C32
        dd 453, 219, 1, 1, 0xFF7E7878
        dd 454, 219, 5, 1, 0xFFD2C8C8
        dd 459, 219, 1, 1, 0xFFB4F0FF
        dd 420, 220, 1, 1, 0xFF7E7878
        dd 421, 220, 6, 1, 0xFFD2C8C8
        dd 427, 220, 1, 1, 0xFF7E7878
        dd 428, 220, 2, 1, 0xFF503C32
        dd 430, 220, 1, 1, 0xFF7E7878
        dd 431, 220, 17, 1, 0xFFD2C8C8
        dd 448, 220, 1, 1, 0xFF7E7878
        dd 449, 220, 5, 1, 0xFF503C32
        dd 454, 220, 1, 1, 0xFF7E7878
        dd 455, 220, 4, 1, 0xFFD2C8C8
        dd 459, 220, 1, 1, 0xFF7E7878
        dd 420, 221, 1, 1, 0xFF7E7878
        dd 421, 221, 6, 1, 0xFFD2C8C8
        dd 427, 221, 1, 1, 0xFF7E7878
        dd 428, 221, 2, 1, 0xFF503C32
        dd 430, 221, 1, 1, 0xFF7E7878
        dd 431, 221, 17, 1, 0xFFD2C8C8
        dd 448, 221, 1, 1, 0xFF7E7878
        dd 449, 221, 5, 1, 0xFF503C32
        dd 454, 221, 1, 1, 0xFF7E7878
        dd 455, 221, 4, 1, 0xFFD2C8C8
        dd 459, 221, 1, 1, 0xFF7E7878
        dd 420, 222, 1, 1, 0xFF7E7878
        dd 421, 222, 6, 1, 0xFFD2C8C8
        dd 427, 222, 1, 1, 0xFF7E7878
        dd 428, 222, 2, 1, 0xFF503C32
        dd 430, 222, 1, 1, 0xFF7E7878
        dd 431, 222, 17, 1, 0xFFD2C8C8
        dd 448, 222, 1, 1, 0xFF7E7878
        dd 449, 222, 5, 1, 0xFF503C32
        dd 454, 222, 1, 1, 0xFF7E7878
        dd 455, 222, 4, 1, 0xFFD2C8C8
        dd 459, 222, 1, 1, 0xFF7E7878
        dd 420, 223, 1, 1, 0xFF7E7878
        dd 421, 223, 6, 1, 0xFFD2C8C8
        dd 427, 223, 1, 1, 0xFF7E7878
        dd 428, 223, 2, 1, 0xFF503C32
        dd 430, 223, 1, 1, 0xFF7E7878
        dd 431, 223, 17, 1, 0xFFD2C8C8
        dd 448, 223, 1, 1, 0xFF7E7878
        dd 449, 223, 5, 1, 0xFF503C32
        dd 454, 223, 1, 1, 0xFF7E7878
        dd 455, 223, 4, 1, 0xFFD2C8C8
        dd 459, 223, 1, 1, 0xFF7E7878
        dd 420, 224, 1, 1, 0xFF7E7878
        dd 421, 224, 6, 1, 0xFFD2C8C8
        dd 427, 224, 1, 1, 0xFF7E7878
        dd 428, 224, 2, 1, 0xFF503C32
        dd 430, 224, 1, 1, 0xFF7E7878
        dd 431, 224, 17, 1, 0xFFD2C8C8
        dd 448, 224, 1, 1, 0xFF7E7878
        dd 449, 224, 5, 1, 0xFF503C32
        dd 454, 224, 1, 1, 0xFF7E7878
        dd 455, 224, 4, 1, 0xFFD2C8C8
        dd 459, 224, 1, 1, 0xFF7E7878
        dd 420, 225, 1, 1, 0xFF7E7878
        dd 421, 225, 6, 1, 0xFFD2C8C8
        dd 427, 225, 1, 1, 0xFF7E7878
        dd 428, 225, 2, 1, 0xFF503C32
        dd 430, 225, 1, 1, 0xFF7E7878
        dd 431, 225, 17, 1, 0xFFD2C8C8
        dd 448, 225, 1, 1, 0xFF7E7878
        dd 449, 225, 5, 1, 0xFF503C32
        dd 454, 225, 1, 1, 0xFF7E7878
        dd 455, 225, 4, 1, 0xFFD2C8C8
        dd 459, 225, 1, 1, 0xFF7E7878
        dd 420, 226, 1, 1, 0xFF7E7878
        dd 421, 226, 6, 1, 0xFFD2C8C8
        dd 427, 226, 1, 1, 0xFF7E7878
        dd 428, 226, 2, 1, 0xFF503C32
        dd 430, 226, 1, 1, 0xFF7E7878
        dd 431, 226, 17, 1, 0xFFD2C8C8
        dd 448, 226, 1, 1, 0xFF7E7878
        dd 449, 226, 5, 1, 0xFF503C32
        dd 454, 226, 1, 1, 0xFF7E7878
        dd 455, 226, 4, 1, 0xFFD2C8C8
        dd 459, 226, 1, 1, 0xFF7E7878
        dd 420, 227, 1, 1, 0xFF7E7878
        dd 421, 227, 6, 1, 0xFFD2C8C8
        dd 427, 227, 1, 1, 0xFF7E7878
        dd 428, 227, 2, 1, 0xFF503C32
        dd 430, 227, 1, 1, 0xFF7E7878
        dd 431, 227, 17, 1, 0xFFD2C8C8
        dd 448, 227, 1, 1, 0xFF7E7878
        dd 449, 227, 5, 1, 0xFF503C32
        dd 454, 227, 1, 1, 0xFF7E7878
        dd 455, 227, 4, 1, 0xFFD2C8C8
        dd 459, 227, 1, 1, 0xFF7E7878
        dd 420, 228, 1, 1, 0xFF7E7878
        dd 421, 228, 6, 1, 0xFFD2C8C8
        dd 427, 228, 1, 1, 0xFF7E7878
        dd 428, 228, 2, 1, 0xFF503C32
        dd 430, 228, 1, 1, 0xFF7E7878
        dd 431, 228, 17, 1, 0xFFD2C8C8
        dd 448, 228, 1, 1, 0xFF7E7878
        dd 449, 228, 5, 1, 0xFF503C32
        dd 454, 228, 1, 1, 0xFF7E7878
        dd 455, 228, 4, 1, 0xFFD2C8C8
        dd 459, 228, 1, 1, 0xFF7E7878
        dd 420, 229, 1, 1, 0xFF7E7878
        dd 421, 229, 6, 1, 0xFFD2C8C8
        dd 427, 229, 1, 1, 0xFF7E7878
        dd 428, 229, 2, 1, 0xFF503C32
        dd 430, 229, 1, 1, 0xFF7E7878
        dd 431, 229, 17, 1, 0xFFD2C8C8
        dd 448, 229, 1, 1, 0xFF7E7878
        dd 449, 229, 5, 1, 0xFF503C32
        dd 454, 229, 1, 1, 0xFF7E7878
        dd 455, 229, 4, 1, 0xFFD2C8C8
        dd 459, 229, 1, 1, 0xFF7E7878
        dd 420, 230, 1, 1, 0xFF1E1EC8
        dd 421, 230, 6, 1, 0xFFD2C8C8
        dd 427, 230, 1, 1, 0xFF7E7878
        dd 428, 230, 2, 1, 0xFF503C32
        dd 430, 230, 1, 1, 0xFF7E7878
        dd 431, 230, 17, 1, 0xFFD2C8C8
        dd 448, 230, 1, 1, 0xFF7E7878
        dd 449, 230, 4, 1, 0xFF503C32
        dd 453, 230, 1, 1, 0xFF7E7878
        dd 454, 230, 5, 1, 0xFFD2C8C8
        dd 459, 230, 1, 1, 0xFFB4F0FF
        dd 420, 231, 1, 1, 0xFF1E1EC8
        dd 421, 231, 7, 1, 0xFFD2C8C8
        dd 428, 231, 1, 1, 0xFF7E7878
        dd 429, 231, 20, 1, 0xFF826450
        dd 449, 231, 1, 1, 0xFF7E7878
        dd 450, 231, 9, 1, 0xFFD2C8C8
        dd 459, 231, 1, 1, 0xFFB4F0FF
        dd 421, 232, 1, 1, 0xFF7E7878
        dd 422, 232, 36, 1, 0xFFD2C8C8
        dd 458, 232, 1, 1, 0xFF7E7878
        dd 422, 233, 36, 1, 0xFF7E7878
        dd 426, 234, 6, 1, 0xFF0F0F0F
        dd 448, 234, 6, 1, 0xFF0F0F0F
        dd 486, 215, 6, 1, 0xFF0F0F0F
        dd 508, 215, 6, 1, 0xFF0F0F0F
        dd 482, 216, 36, 1, 0xFF181866
        dd 481, 217, 1, 1, 0xFF181866
        dd 482, 217, 36, 1, 0xFF2828AA
        dd 518, 217, 1, 1, 0xFF181866
        dd 480, 218, 1, 1, 0xFF1E1EC8
        dd 481, 218, 7, 1, 0xFF2828AA
        dd 488, 218, 1, 1, 0xFF181866
        dd 489, 218, 20, 1, 0xFF826450
        dd 509, 218, 1, 1, 0xFF181866
        dd 510, 218, 9, 1, 0xFF2828AA
        dd 519, 218, 1, 1, 0xFFB4F0FF
        dd 480, 219, 1, 1, 0xFF1E1EC8
        dd 481, 219, 6, 1, 0xFF2828AA
        dd 487, 219, 1, 1, 0xFF181866
        dd 488, 219, 2, 1, 0xFF503C32
        dd 490, 219, 1, 1, 0xFF181866
        dd 491, 219, 17, 1, 0xFF2828AA
        dd 508, 219, 1, 1, 0xFF181866
        dd 509, 219, 4, 1, 0xFF503C32
        dd 513, 219, 1, 1, 0xFF181866
        dd 514, 219, 5, 1, 0xFF2828AA
        dd 519, 219, 1, 1, 0xFFB4F0FF
        dd 480, 220, 1, 1, 0xFF181866
        dd 481, 220, 6, 1, 0xFF2828AA
        dd 487, 220, 1, 1, 0xFF181866
        dd 488, 220, 2, 1, 0xFF503C32
        dd 490, 220, 1, 1, 0xFF181866
        dd 491, 220, 17, 1, 0xFF2828AA
        dd 508, 220, 1, 1, 0xFF181866
        dd 509, 220, 5, 1, 0xFF503C32
        dd 514, 220, 1, 1, 0xFF181866
        dd 515, 220, 4, 1, 0xFF2828AA
        dd 519, 220, 1, 1, 0xFF181866
        dd 480, 221, 1, 1, 0xFF181866
        dd 481, 221, 6, 1, 0xFF2828AA
        dd 487, 221, 1, 1, 0xFF181866
        dd 488, 221, 2, 1, 0xFF503C32
        dd 490, 221, 1, 1, 0xFF181866
        dd 491, 221, 17, 1, 0xFF2828AA
        dd 508, 221, 1, 1, 0xFF181866
        dd 509, 221, 5, 1, 0xFF503C32
        dd 514, 221, 1, 1, 0xFF181866
        dd 515, 221, 4, 1, 0xFF2828AA
        dd 519, 221, 1, 1, 0xFF181866
        dd 480, 222, 1, 1, 0xFF181866
        dd 481, 222, 6, 1, 0xFF2828AA
        dd 487, 222, 1, 1, 0xFF181866
        dd 488, 222, 2, 1, 0xFF503C32
        dd 490, 222, 1, 1, 0xFF181866
        dd 491, 222, 17, 1, 0xFF2828AA
        dd 508, 222, 1, 1, 0xFF181866
        dd 509, 222, 5, 1, 0xFF503C32
        dd 514, 222, 1, 1, 0xFF181866
        dd 515, 222, 4, 1, 0xFF2828AA
        dd 519, 222, 1, 1, 0xFF181866
        dd 480, 223, 1, 1, 0xFF181866
        dd 481, 223, 6, 1, 0xFF2828AA
        dd 487, 223, 1, 1, 0xFF181866
        dd 488, 223, 2, 1, 0xFF503C32
        dd 490, 223, 1, 1, 0xFF181866
        dd 491, 223, 17, 1, 0xFF2828AA
        dd 508, 223, 1, 1, 0xFF181866
        dd 509, 223, 5, 1, 0xFF503C32
        dd 514, 223, 1, 1, 0xFF181866
        dd 515, 223, 4, 1, 0xFF2828AA
        dd 519, 223, 1, 1, 0xFF181866
        dd 480, 224, 1, 1, 0xFF181866
        dd 481, 224, 6, 1, 0xFF2828AA
        dd 487, 224, 1, 1, 0xFF181866
        dd 488, 224, 2, 1, 0xFF503C32
        dd 490, 224, 1, 1, 0xFF181866
        dd 491, 224, 17, 1, 0xFF2828AA
        dd 508, 224, 1, 1, 0xFF181866
        dd 509, 224, 5, 1, 0xFF503C32
        dd 514, 224, 1, 1, 0xFF181866
        dd 515, 224, 4, 1, 0xFF2828AA
        dd 519, 224, 1, 1, 0xFF181866
        dd 480, 225, 1, 1, 0xFF181866
        dd 481, 225, 6, 1, 0xFF2828AA
        dd 487, 225, 1, 1, 0xFF181866
        dd 488, 225, 2, 1, 0xFF503C32
        dd 490, 225, 1, 1, 0xFF181866
        dd 491, 225, 17, 1, 0xFF2828AA
        dd 508, 225, 1, 1, 0xFF181866
        dd 509, 225, 5, 1, 0xFF503C32
        dd 514, 225, 1, 1, 0xFF181866
        dd 515, 225, 4, 1, 0xFF2828AA
        dd 519, 225, 1, 1, 0xFF181866
        dd 480, 226, 1, 1, 0xFF181866
        dd 481, 226, 6, 1, 0xFF2828AA
        dd 487, 226, 1, 1, 0xFF181866
        dd 488, 226, 2, 1, 0xFF503C32
        dd 490, 226, 1, 1, 0xFF181866
        dd 491, 226, 17, 1, 0xFF2828AA
        dd 508, 226, 1, 1, 0xFF181866
        dd 509, 226, 5, 1, 0xFF503C32
        dd 514, 226, 1, 1, 0xFF181866
        dd 515, 226, 4, 1, 0xFF2828AA
        dd 519, 226, 1, 1, 0xFF181866
        dd 480, 227, 1, 1, 0xFF181866
        dd 481, 227, 6, 1, 0xFF2828AA
        dd 487, 227, 1, 1, 0xFF181866
        dd 488, 227, 2, 1, 0xFF503C32
        dd 490, 227, 1, 1, 0xFF181866
        dd 491, 227, 17, 1, 0xFF2828AA
        dd 508, 227, 1, 1, 0xFF181866
        dd 509, 227, 5, 1, 0xFF503C32
        dd 514, 227, 1, 1, 0xFF181866
        dd 515, 227, 4, 1, 0xFF2828AA
        dd 519, 227, 1, 1, 0xFF181866
        dd 480, 228, 1, 1, 0xFF181866
        dd 481, 228, 6, 1, 0xFF2828AA
        dd 487, 228, 1, 1, 0xFF181866
        dd 488, 228, 2, 1, 0xFF503C32
        dd 490, 228, 1, 1, 0xFF181866
        dd 491, 228, 17, 1, 0xFF2828AA
        dd 508, 228, 1, 1, 0xFF181866
        dd 509, 228, 5, 1, 0xFF503C32
        dd 514, 228, 1, 1, 0xFF181866
        dd 515, 228, 4, 1, 0xFF2828AA
        dd 519, 228, 1, 1, 0xFF181866
        dd 480, 229, 1, 1, 0xFF181866
        dd 481, 229, 6, 1, 0xFF2828AA
        dd 487, 229, 1, 1, 0xFF181866
        dd 488, 229, 2, 1, 0xFF503C32
        dd 490, 229, 1, 1, 0xFF181866
        dd 491, 229, 17, 1, 0xFF2828AA
        dd 508, 229, 1, 1, 0xFF181866
        dd 509, 229, 5, 1, 0xFF503C32
        dd 514, 229, 1, 1, 0xFF181866
        dd 515, 229, 4, 1, 0xFF2828AA
        dd 519, 229, 1, 1, 0xFF181866
        dd 480, 230, 1, 1, 0xFF1E1EC8
        dd 481, 230, 6, 1, 0xFF2828AA
        dd 487, 230, 1, 1, 0xFF181866
        dd 488, 230, 2, 1, 0xFF503C32
        dd 490, 230, 1, 1, 0xFF181866
        dd 491, 230, 17, 1, 0xFF2828AA
        dd 508, 230, 1, 1, 0xFF181866
        dd 509, 230, 4, 1, 0xFF503C32
        dd 513, 230, 1, 1, 0xFF181866
        dd 514, 230, 5, 1, 0xFF2828AA
        dd 519, 230, 1, 1, 0xFFB4F0FF
        dd 480, 231, 1, 1, 0xFF1E1EC8
        dd 481, 231, 7, 1, 0xFF2828AA
        dd 488, 231, 1, 1, 0xFF181866
        dd 489, 231, 20, 1, 0xFF826450
        dd 509, 231, 1, 1, 0xFF181866
        dd 510, 231, 9, 1, 0xFF2828AA
        dd 519, 231, 1, 1, 0xFFB4F0FF
        dd 481, 232, 1, 1, 0xFF181866
        dd 482, 232, 36, 1, 0xFF2828AA
        dd 518, 232, 1, 1, 0xFF181866
        dd 482, 233, 36, 1, 0xFF181866
        dd 486, 234, 6, 1, 0xFF0F0F0F
        dd 508, 234, 6, 1, 0xFF0F0F0F
        dd 606, 215, 6, 1, 0xFF0F0F0F
        dd 628, 215, 6, 1, 0xFF0F0F0F
        dd 602, 216, 36, 1, 0xFF5A2A18
        dd 601, 217, 1, 1, 0xFF5A2A18
        dd 602, 217, 36, 1, 0xFF964628
        dd 638, 217, 1, 1, 0xFF5A2A18
        dd 600, 218, 1, 1, 0xFF1E1EC8
        dd 601, 218, 7, 1, 0xFF964628
        dd 608, 218, 1, 1, 0xFF5A2A18
        dd 609, 218, 20, 1, 0xFF826450
        dd 629, 218, 1, 1, 0xFF5A2A18
        dd 630, 218, 9, 1, 0xFF964628
        dd 639, 218, 1, 1, 0xFFB4F0FF
        dd 600, 219, 1, 1, 0xFF1E1EC8
        dd 601, 219, 6, 1, 0xFF964628
        dd 607, 219, 1, 1, 0xFF5A2A18
        dd 608, 219, 2, 1, 0xFF503C32
        dd 610, 219, 1, 1, 0xFF5A2A18
        dd 611, 219, 17, 1, 0xFF964628
        dd 628, 219, 1, 1, 0xFF5A2A18
        dd 629, 219, 4, 1, 0xFF503C32
        dd 633, 219, 1, 1, 0xFF5A2A18
        dd 634, 219, 5, 1, 0xFF964628
        dd 639, 219, 1, 1, 0xFFB4F0FF
        dd 600, 220, 1, 1, 0xFF5A2A18
        dd 601, 220, 6, 1, 0xFF964628
        dd 607, 220, 1, 1, 0xFF5A2A18
        dd 608, 220, 2, 1, 0xFF503C32
        dd 610, 220, 1, 1, 0xFF5A2A18
        dd 611, 220, 17, 1, 0xFF964628
        dd 628, 220, 1, 1, 0xFF5A2A18
        dd 629, 220, 5, 1, 0xFF503C32
        dd 634, 220, 1, 1, 0xFF5A2A18
        dd 635, 220, 4, 1, 0xFF964628
        dd 639, 220, 1, 1, 0xFF5A2A18
        dd 600, 221, 1, 1, 0xFF5A2A18
        dd 601, 221, 6, 1, 0xFF964628
        dd 607, 221, 1, 1, 0xFF5A2A18
        dd 608, 221, 2, 1, 0xFF503C32
        dd 610, 221, 1, 1, 0xFF5A2A18
        dd 611, 221, 17, 1, 0xFF964628
        dd 628, 221, 1, 1, 0xFF5A2A18
        dd 629, 221, 5, 1, 0xFF503C32
        dd 634, 221, 1, 1, 0xFF5A2A18
        dd 635, 221, 4, 1, 0xFF964628
        dd 639, 221, 1, 1, 0xFF5A2A18
        dd 600, 222, 1, 1, 0xFF5A2A18
        dd 601, 222, 6, 1, 0xFF964628
        dd 607, 222, 1, 1, 0xFF5A2A18
        dd 608, 222, 2, 1, 0xFF503C32
        dd 610, 222, 1, 1, 0xFF5A2A18
        dd 611, 222, 17, 1, 0xFF964628
        dd 628, 222, 1, 1, 0xFF5A2A18
        dd 629, 222, 5, 1, 0xFF503C32
        dd 634, 222, 1, 1, 0xFF5A2A18
        dd 635, 222, 4, 1, 0xFF964628
        dd 639, 222, 1, 1, 0xFF5A2A18
        dd 600, 223, 1, 1, 0xFF5A2A18
        dd 601, 223, 6, 1, 0xFF964628
        dd 607, 223, 1, 1, 0xFF5A2A18
        dd 608, 223, 2, 1, 0xFF503C32
        dd 610, 223, 1, 1, 0xFF5A2A18
        dd 611, 223, 17, 1, 0xFF964628
        dd 628, 223, 1, 1, 0xFF5A2A18
        dd 629, 223, 5, 1, 0xFF503C32
        dd 634, 223, 1, 1, 0xFF5A2A18
        dd 635, 223, 4, 1, 0xFF964628
        dd 639, 223, 1, 1, 0xFF5A2A18
        dd 600, 224, 1, 1, 0xFF5A2A18
        dd 601, 224, 6, 1, 0xFF964628
        dd 607, 224, 1, 1, 0xFF5A2A18
        dd 608, 224, 2, 1, 0xFF503C32
        dd 610, 224, 1, 1, 0xFF5A2A18
        dd 611, 224, 17, 1, 0xFF964628
        dd 628, 224, 1, 1, 0xFF5A2A18
        dd 629, 224, 5, 1, 0xFF503C32
        dd 634, 224, 1, 1, 0xFF5A2A18
        dd 635, 224, 4, 1, 0xFF964628
        dd 639, 224, 1, 1, 0xFF5A2A18
        dd 600, 225, 1, 1, 0xFF5A2A18
        dd 601, 225, 6, 1, 0xFF964628
        dd 607, 225, 1, 1, 0xFF5A2A18
        dd 608, 225, 2, 1, 0xFF503C32
        dd 610, 225, 1, 1, 0xFF5A2A18
        dd 611, 225, 17, 1, 0xFF964628
        dd 628, 225, 1, 1, 0xFF5A2A18
        dd 629, 225, 5, 1, 0xFF503C32
        dd 634, 225, 1, 1, 0xFF5A2A18
        dd 635, 225, 4, 1, 0xFF964628
        dd 639, 225, 1, 1, 0xFF5A2A18
        dd 600, 226, 1, 1, 0xFF5A2A18
        dd 601, 226, 6, 1, 0xFF964628
        dd 607, 226, 1, 1, 0xFF5A2A18
        dd 608, 226, 2, 1, 0xFF503C32
        dd 610, 226, 1, 1, 0xFF5A2A18
        dd 611, 226, 17, 1, 0xFF964628
        dd 628, 226, 1, 1, 0xFF5A2A18
        dd 629, 226, 5, 1, 0xFF503C32
        dd 634, 226, 1, 1, 0xFF5A2A18
        dd 635, 226, 4, 1, 0xFF964628
        dd 639, 226, 1, 1, 0xFF5A2A18
        dd 600, 227, 1, 1, 0xFF5A2A18
        dd 601, 227, 6, 1, 0xFF964628
        dd 607, 227, 1, 1, 0xFF5A2A18
        dd 608, 227, 2, 1, 0xFF503C32
        dd 610, 227, 1, 1, 0xFF5A2A18
        dd 611, 227, 17, 1, 0xFF964628
        dd 628, 227, 1, 1, 0xFF5A2A18
        dd 629, 227, 5, 1, 0xFF503C32
        dd 634, 227, 1, 1, 0xFF5A2A18
        dd 635, 227, 4, 1, 0xFF964628
        dd 639, 227, 1, 1, 0xFF5A2A18
        dd 600, 228, 1, 1, 0xFF5A2A18
        dd 601, 228, 6, 1, 0xFF964628
        dd 607, 228, 1, 1, 0xFF5A2A18
        dd 608, 228, 2, 1, 0xFF503C32
        dd 610, 228, 1, 1, 0xFF5A2A18
        dd 611, 228, 17, 1, 0xFF964628
        dd 628, 228, 1, 1, 0xFF5A2A18
        dd 629, 228, 5, 1, 0xFF503C32
        dd 634, 228, 1, 1, 0xFF5A2A18
        dd 635, 228, 4, 1, 0xFF964628
        dd 639, 228, 1, 1, 0xFF5A2A18
        dd 600, 229, 1, 1, 0xFF5A2A18
        dd 601, 229, 6, 1, 0xFF964628
        dd 607, 229, 1, 1, 0xFF5A2A18
        dd 608, 229, 2, 1, 0xFF503C32
        dd 610, 229, 1, 1, 0xFF5A2A18
        dd 611, 229, 17, 1, 0xFF964628
        dd 628, 229, 1, 1, 0xFF5A2A18
        dd 629, 229, 5, 1, 0xFF503C32
        dd 634, 229, 1, 1, 0xFF5A2A18
        dd 635, 229, 4, 1, 0xFF964628
        dd 639, 229, 1, 1, 0xFF5A2A18
        dd 600, 230, 1, 1, 0xFF1E1EC8
        dd 601, 230, 6, 1, 0xFF964628
        dd 607, 230, 1, 1, 0xFF5A2A18
        dd 608, 230, 2, 1, 0xFF503C32
        dd 610, 230, 1, 1, 0xFF5A2A18
        dd 611, 230, 17, 1, 0xFF964628
        dd 628, 230, 1, 1, 0xFF5A2A18
        dd 629, 230, 4, 1, 0xFF503C32
        dd 633, 230, 1, 1, 0xFF5A2A18
        dd 634, 230, 5, 1, 0xFF964628
        dd 639, 230, 1, 1, 0xFFB4F0FF
        dd 600, 231, 1, 1, 0xFF1E1EC8
        dd 601, 231, 7, 1, 0xFF964628
        dd 608, 231, 1, 1, 0xFF5A2A18
        dd 609, 231, 20, 1, 0xFF826450
        dd 629, 231, 1, 1, 0xFF5A2A18
        dd 630, 231, 9, 1, 0xFF964628
        dd 639, 231, 1, 1, 0xFFB4F0FF
        dd 601, 232, 1, 1, 0xFF5A2A18
        dd 602, 232, 36, 1, 0xFF964628
        dd 638, 232, 1, 1, 0xFF5A2A18
        dd 602, 233, 36, 1, 0xFF5A2A18
        dd 606, 234, 6, 1, 0xFF0F0F0F
        dd 628, 234, 6, 1, 0xFF0F0F0F
        dd 726, 215, 6, 1, 0xFF0F0F0F
        dd 748, 215, 6, 1, 0xFF0F0F0F
        dd 722, 216, 36, 1, 0xFF2A7884
        dd 721, 217, 1, 1, 0xFF2A7884
        dd 722, 217, 36, 1, 0xFF46C8DC
        dd 758, 217, 1, 1, 0xFF2A7884
        dd 720, 218, 1, 1, 0xFF1E1EC8
        dd 721, 218, 7, 1, 0xFF46C8DC
        dd 728, 218, 1, 1, 0xFF2A7884
        dd 729, 218, 20, 1, 0xFF826450
        dd 749, 218, 1, 1, 0xFF2A7884
        dd 750, 218, 9, 1, 0xFF46C8DC
        dd 759, 218, 1, 1, 0xFFB4F0FF
        dd 720, 219, 1, 1, 0xFF1E1EC8
        dd 721, 219, 6, 1, 0xFF46C8DC
        dd 727, 219, 1, 1, 0xFF2A7884
        dd 728, 219, 2, 1, 0xFF503C32
        dd 730, 219, 1, 1, 0xFF2A7884
        dd 731, 219, 17, 1, 0xFF46C8DC
        dd 748, 219, 1, 1, 0xFF2A7884
        dd 749, 219, 4, 1, 0xFF503C32
        dd 753, 219, 1, 1, 0xFF2A7884
        dd 754, 219, 5, 1, 0xFF46C8DC
        dd 759, 219, 1, 1, 0xFFB4F0FF
        dd 720, 220, 1, 1, 0xFF2A7884
        dd 721, 220, 6, 1, 0xFF46C8DC
        dd 727, 220, 1, 1, 0xFF2A7884
        dd 728, 220, 2, 1, 0xFF503C32
        dd 730, 220, 1, 1, 0xFF2A7884
        dd 731, 220, 17, 1, 0xFF46C8DC
        dd 748, 220, 1, 1, 0xFF2A7884
        dd 749, 220, 5, 1, 0xFF503C32
        dd 754, 220, 1, 1, 0xFF2A7884
        dd 755, 220, 4, 1, 0xFF46C8DC
        dd 759, 220, 1, 1, 0xFF2A7884
        dd 720, 221, 1, 1, 0xFF2A7884
        dd 721, 221, 6, 1, 0xFF46C8DC
        dd 727, 221, 1, 1, 0xFF2A7884
        dd 728, 221, 2, 1, 0xFF503C32
        dd 730, 221, 1, 1, 0xFF2A7884
        dd 731, 221, 17, 1, 0xFF46C8DC
        dd 748, 221, 1, 1, 0xFF2A7884
        dd 749, 221, 5, 1, 0xFF503C32
        dd 754, 221, 1, 1, 0xFF2A7884
        dd 755, 221, 4, 1, 0xFF46C8DC
        dd 759, 221, 1, 1, 0xFF2A7884
        dd 720, 222, 1, 1, 0xFF2A7884
        dd 721, 222, 6, 1, 0xFF46C8DC
        dd 727, 222, 1, 1, 0xFF2A7884
        dd 728, 222, 2, 1, 0xFF503C32
        dd 730, 222, 1, 1, 0xFF2A7884
        dd 731, 222, 17, 1, 0xFF46C8DC
        dd 748, 222, 1, 1, 0xFF2A7884
        dd 749, 222, 5, 1, 0xFF503C32
        dd 754, 222, 1, 1, 0xFF2A7884
        dd 755, 222, 4, 1, 0xFF46C8DC
        dd 759, 222, 1, 1, 0xFF2A7884
        dd 720, 223, 1, 1, 0xFF2A7884
        dd 721, 223, 6, 1, 0xFF46C8DC
        dd 727, 223, 1, 1, 0xFF2A7884
        dd 728, 223, 2, 1, 0xFF503C32
        dd 730, 223, 1, 1, 0xFF2A7884
        dd 731, 223, 17, 1, 0xFF46C8DC
        dd 748, 223, 1, 1, 0xFF2A7884
        dd 749, 223, 5, 1, 0xFF503C32
        dd 754, 223, 1, 1, 0xFF2A7884
        dd 755, 223, 4, 1, 0xFF46C8DC
        dd 759, 223, 1, 1, 0xFF2A7884
        dd 720, 224, 1, 1, 0xFF2A7884
        dd 721, 224, 6, 1, 0xFF46C8DC
        dd 727, 224, 1, 1, 0xFF2A7884
        dd 728, 224, 2, 1, 0xFF503C32
        dd 730, 224, 1, 1, 0xFF2A7884
        dd 731, 224, 17, 1, 0xFF46C8DC
        dd 748, 224, 1, 1, 0xFF2A7884
        dd 749, 224, 5, 1, 0xFF503C32
        dd 754, 224, 1, 1, 0xFF2A7884
        dd 755, 224, 4, 1, 0xFF46C8DC
        dd 759, 224, 1, 1, 0xFF2A7884
        dd 720, 225, 1, 1, 0xFF2A7884
        dd 721, 225, 6, 1, 0xFF46C8DC
        dd 727, 225, 1, 1, 0xFF2A7884
        dd 728, 225, 2, 1, 0xFF503C32
        dd 730, 225, 1, 1, 0xFF2A7884
        dd 731, 225, 17, 1, 0xFF46C8DC
        dd 748, 225, 1, 1, 0xFF2A7884
        dd 749, 225, 5, 1, 0xFF503C32
        dd 754, 225, 1, 1, 0xFF2A7884
        dd 755, 225, 4, 1, 0xFF46C8DC
        dd 759, 225, 1, 1, 0xFF2A7884
        dd 720, 226, 1, 1, 0xFF2A7884
        dd 721, 226, 6, 1, 0xFF46C8DC
        dd 727, 226, 1, 1, 0xFF2A7884
        dd 728, 226, 2, 1, 0xFF503C32
        dd 730, 226, 1, 1, 0xFF2A7884
        dd 731, 226, 17, 1, 0xFF46C8DC
        dd 748, 226, 1, 1, 0xFF2A7884
        dd 749, 226, 5, 1, 0xFF503C32
        dd 754, 226, 1, 1, 0xFF2A7884
        dd 755, 226, 4, 1, 0xFF46C8DC
        dd 759, 226, 1, 1, 0xFF2A7884
        dd 720, 227, 1, 1, 0xFF2A7884
        dd 721, 227, 6, 1, 0xFF46C8DC
        dd 727, 227, 1, 1, 0xFF2A7884
        dd 728, 227, 2, 1, 0xFF503C32
        dd 730, 227, 1, 1, 0xFF2A7884
        dd 731, 227, 17, 1, 0xFF46C8DC
        dd 748, 227, 1, 1, 0xFF2A7884
        dd 749, 227, 5, 1, 0xFF503C32
        dd 754, 227, 1, 1, 0xFF2A7884
        dd 755, 227, 4, 1, 0xFF46C8DC
        dd 759, 227, 1, 1, 0xFF2A7884
        dd 720, 228, 1, 1, 0xFF2A7884
        dd 721, 228, 6, 1, 0xFF46C8DC
        dd 727, 228, 1, 1, 0xFF2A7884
        dd 728, 228, 2, 1, 0xFF503C32
        dd 730, 228, 1, 1, 0xFF2A7884
        dd 731, 228, 17, 1, 0xFF46C8DC
        dd 748, 228, 1, 1, 0xFF2A7884
        dd 749, 228, 5, 1, 0xFF503C32
        dd 754, 228, 1, 1, 0xFF2A7884
        dd 755, 228, 4, 1, 0xFF46C8DC
        dd 759, 228, 1, 1, 0xFF2A7884
        dd 720, 229, 1, 1, 0xFF2A7884
        dd 721, 229, 6, 1, 0xFF46C8DC
        dd 727, 229, 1, 1, 0xFF2A7884
        dd 728, 229, 2, 1, 0xFF503C32
        dd 730, 229, 1, 1, 0xFF2A7884
        dd 731, 229, 17, 1, 0xFF46C8DC
        dd 748, 229, 1, 1, 0xFF2A7884
        dd 749, 229, 5, 1, 0xFF503C32
        dd 754, 229, 1, 1, 0xFF2A7884
        dd 755, 229, 4, 1, 0xFF46C8DC
        dd 759, 229, 1, 1, 0xFF2A7884
        dd 720, 230, 1, 1, 0xFF1E1EC8
        dd 721, 230, 6, 1, 0xFF46C8DC
        dd 727, 230, 1, 1, 0xFF2A7884
        dd 728, 230, 2, 1, 0xFF503C32
        dd 730, 230, 1, 1, 0xFF2A7884
        dd 731, 230, 17, 1, 0xFF46C8DC
        dd 748, 230, 1, 1, 0xFF2A7884
        dd 749, 230, 4, 1, 0xFF503C32
        dd 753, 230, 1, 1, 0xFF2A7884
        dd 754, 230, 5, 1, 0xFF46C8DC
        dd 759, 230, 1, 1, 0xFFB4F0FF
        dd 720, 231, 1, 1, 0xFF1E1EC8
        dd 721, 231, 7, 1, 0xFF46C8DC
        dd 728, 231, 1, 1, 0xFF2A7884
        dd 729, 231, 20, 1, 0xFF826450
        dd 749, 231, 1, 1, 0xFF2A7884
        dd 750, 231, 9, 1, 0xFF46C8DC
        dd 759, 231, 1, 1, 0xFFB4F0FF
        dd 721, 232, 1, 1, 0xFF2A7884
        dd 722, 232, 36, 1, 0xFF46C8DC
        dd 758, 232, 1, 1, 0xFF2A7884
        dd 722, 233, 36, 1, 0xFF2A7884
        dd 726, 234, 6, 1, 0xFF0F0F0F
        dd 748, 234, 6, 1, 0xFF0F0F0F
        dd 786, 215, 6, 1, 0xFF0F0F0F
        dd 808, 215, 6, 1, 0xFF0F0F0F
        dd 782, 216, 36, 1, 0xFF541E48
        dd 781, 217, 1, 1, 0xFF541E48
        dd 782, 217, 36, 1, 0xFF8C3278
        dd 818, 217, 1, 1, 0xFF541E48
        dd 780, 218, 1, 1, 0xFF1E1EC8
        dd 781, 218, 7, 1, 0xFF8C3278
        dd 788, 218, 1, 1, 0xFF541E48
        dd 789, 218, 20, 1, 0xFF826450
        dd 809, 218, 1, 1, 0xFF541E48
        dd 810, 218, 9, 1, 0xFF8C3278
        dd 819, 218, 1, 1, 0xFFB4F0FF
        dd 780, 219, 1, 1, 0xFF1E1EC8
        dd 781, 219, 6, 1, 0xFF8C3278
        dd 787, 219, 1, 1, 0xFF541E48
        dd 788, 219, 2, 1, 0xFF503C32
        dd 790, 219, 1, 1, 0xFF541E48
        dd 791, 219, 17, 1, 0xFF8C3278
        dd 808, 219, 1, 1, 0xFF541E48
        dd 809, 219, 4, 1, 0xFF503C32
        dd 813, 219, 1, 1, 0xFF541E48
        dd 814, 219, 5, 1, 0xFF8C3278
        dd 819, 219, 1, 1, 0xFFB4F0FF
        dd 780, 220, 1, 1, 0xFF541E48
        dd 781, 220, 6, 1, 0xFF8C3278
        dd 787, 220, 1, 1, 0xFF541E48
        dd 788, 220, 2, 1, 0xFF503C32
        dd 790, 220, 1, 1, 0xFF541E48
        dd 791, 220, 17, 1, 0xFF8C3278
        dd 808, 220, 1, 1, 0xFF541E48
        dd 809, 220, 5, 1, 0xFF503C32
        dd 814, 220, 1, 1, 0xFF541E48
        dd 815, 220, 4, 1, 0xFF8C3278
        dd 819, 220, 1, 1, 0xFF541E48
        dd 780, 221, 1, 1, 0xFF541E48
        dd 781, 221, 6, 1, 0xFF8C3278
        dd 787, 221, 1, 1, 0xFF541E48
        dd 788, 221, 2, 1, 0xFF503C32
        dd 790, 221, 1, 1, 0xFF541E48
        dd 791, 221, 17, 1, 0xFF8C3278
        dd 808, 221, 1, 1, 0xFF541E48
        dd 809, 221, 5, 1, 0xFF503C32
        dd 814, 221, 1, 1, 0xFF541E48
        dd 815, 221, 4, 1, 0xFF8C3278
        dd 819, 221, 1, 1, 0xFF541E48
        dd 780, 222, 1, 1, 0xFF541E48
        dd 781, 222, 6, 1, 0xFF8C3278
        dd 787, 222, 1, 1, 0xFF541E48
        dd 788, 222, 2, 1, 0xFF503C32
        dd 790, 222, 1, 1, 0xFF541E48
        dd 791, 222, 17, 1, 0xFF8C3278
        dd 808, 222, 1, 1, 0xFF541E48
        dd 809, 222, 5, 1, 0xFF503C32
        dd 814, 222, 1, 1, 0xFF541E48
        dd 815, 222, 4, 1, 0xFF8C3278
        dd 819, 222, 1, 1, 0xFF541E48
        dd 780, 223, 1, 1, 0xFF541E48
        dd 781, 223, 6, 1, 0xFF8C3278
        dd 787, 223, 1, 1, 0xFF541E48
        dd 788, 223, 2, 1, 0xFF503C32
        dd 790, 223, 1, 1, 0xFF541E48
        dd 791, 223, 17, 1, 0xFF8C3278
        dd 808, 223, 1, 1, 0xFF541E48
        dd 809, 223, 5, 1, 0xFF503C32
        dd 814, 223, 1, 1, 0xFF541E48
        dd 815, 223, 4, 1, 0xFF8C3278
        dd 819, 223, 1, 1, 0xFF541E48
        dd 780, 224, 1, 1, 0xFF541E48
        dd 781, 224, 6, 1, 0xFF8C3278
        dd 787, 224, 1, 1, 0xFF541E48
        dd 788, 224, 2, 1, 0xFF503C32
        dd 790, 224, 1, 1, 0xFF541E48
        dd 791, 224, 17, 1, 0xFF8C3278
        dd 808, 224, 1, 1, 0xFF541E48
        dd 809, 224, 5, 1, 0xFF503C32
        dd 814, 224, 1, 1, 0xFF541E48
        dd 815, 224, 4, 1, 0xFF8C3278
        dd 819, 224, 1, 1, 0xFF541E48
        dd 780, 225, 1, 1, 0xFF541E48
        dd 781, 225, 6, 1, 0xFF8C3278
        dd 787, 225, 1, 1, 0xFF541E48
        dd 788, 225, 2, 1, 0xFF503C32
        dd 790, 225, 1, 1, 0xFF541E48
        dd 791, 225, 17, 1, 0xFF8C3278
        dd 808, 225, 1, 1, 0xFF541E48
        dd 809, 225, 5, 1, 0xFF503C32
        dd 814, 225, 1, 1, 0xFF541E48
        dd 815, 225, 4, 1, 0xFF8C3278
        dd 819, 225, 1, 1, 0xFF541E48
        dd 780, 226, 1, 1, 0xFF541E48
        dd 781, 226, 6, 1, 0xFF8C3278
        dd 787, 226, 1, 1, 0xFF541E48
        dd 788, 226, 2, 1, 0xFF503C32
        dd 790, 226, 1, 1, 0xFF541E48
        dd 791, 226, 17, 1, 0xFF8C3278
        dd 808, 226, 1, 1, 0xFF541E48
        dd 809, 226, 5, 1, 0xFF503C32
        dd 814, 226, 1, 1, 0xFF541E48
        dd 815, 226, 4, 1, 0xFF8C3278
        dd 819, 226, 1, 1, 0xFF541E48
        dd 780, 227, 1, 1, 0xFF541E48
        dd 781, 227, 6, 1, 0xFF8C3278
        dd 787, 227, 1, 1, 0xFF541E48
        dd 788, 227, 2, 1, 0xFF503C32
        dd 790, 227, 1, 1, 0xFF541E48
        dd 791, 227, 17, 1, 0xFF8C3278
        dd 808, 227, 1, 1, 0xFF541E48
        dd 809, 227, 5, 1, 0xFF503C32
        dd 814, 227, 1, 1, 0xFF541E48
        dd 815, 227, 4, 1, 0xFF8C3278
        dd 819, 227, 1, 1, 0xFF541E48
        dd 780, 228, 1, 1, 0xFF541E48
        dd 781, 228, 6, 1, 0xFF8C3278
        dd 787, 228, 1, 1, 0xFF541E48
        dd 788, 228, 2, 1, 0xFF503C32
        dd 790, 228, 1, 1, 0xFF541E48
        dd 791, 228, 17, 1, 0xFF8C3278
        dd 808, 228, 1, 1, 0xFF541E48
        dd 809, 228, 5, 1, 0xFF503C32
        dd 814, 228, 1, 1, 0xFF541E48
        dd 815, 228, 4, 1, 0xFF8C3278
        dd 819, 228, 1, 1, 0xFF541E48
        dd 780, 229, 1, 1, 0xFF541E48
        dd 781, 229, 6, 1, 0xFF8C3278
        dd 787, 229, 1, 1, 0xFF541E48
        dd 788, 229, 2, 1, 0xFF503C32
        dd 790, 229, 1, 1, 0xFF541E48
        dd 791, 229, 17, 1, 0xFF8C3278
        dd 808, 229, 1, 1, 0xFF541E48
        dd 809, 229, 5, 1, 0xFF503C32
        dd 814, 229, 1, 1, 0xFF541E48
        dd 815, 229, 4, 1, 0xFF8C3278
        dd 819, 229, 1, 1, 0xFF541E48
        dd 780, 230, 1, 1, 0xFF1E1EC8
        dd 781, 230, 6, 1, 0xFF8C3278
        dd 787, 230, 1, 1, 0xFF541E48
        dd 788, 230, 2, 1, 0xFF503C32
        dd 790, 230, 1, 1, 0xFF541E48
        dd 791, 230, 17, 1, 0xFF8C3278
        dd 808, 230, 1, 1, 0xFF541E48
        dd 809, 230, 4, 1, 0xFF503C32
        dd 813, 230, 1, 1, 0xFF541E48
        dd 814, 230, 5, 1, 0xFF8C3278
        dd 819, 230, 1, 1, 0xFFB4F0FF
        dd 780, 231, 1, 1, 0xFF1E1EC8
        dd 781, 231, 7, 1, 0xFF8C3278
        dd 788, 231, 1, 1, 0xFF541E48
        dd 789, 231, 20, 1, 0xFF826450
        dd 809, 231, 1, 1, 0xFF541E48
        dd 810, 231, 9, 1, 0xFF8C3278
        dd 819, 231, 1, 1, 0xFFB4F0FF
        dd 781, 232, 1, 1, 0xFF541E48
        dd 782, 232, 36, 1, 0xFF8C3278
        dd 818, 232, 1, 1, 0xFF541E48
        dd 782, 233, 36, 1, 0xFF541E48
        dd 786, 234, 6, 1, 0xFF0F0F0F
        dd 808, 234, 6, 1, 0xFF0F0F0F
        dd 426, 275, 6, 1, 0xFF0F0F0F
        dd 448, 275, 6, 1, 0xFF0F0F0F
        dd 422, 276, 36, 1, 0xFF8A8A8A
        dd 421, 277, 1, 1, 0xFF8A8A8A
        dd 422, 277, 36, 1, 0xFFE6E6E6
        dd 458, 277, 1, 1, 0xFF8A8A8A
        dd 420, 278, 1, 1, 0xFF1E1EC8
        dd 421, 278, 7, 1, 0xFFE6E6E6
        dd 428, 278, 1, 1, 0xFF8A8A8A
        dd 429, 278, 20, 1, 0xFF826450
        dd 449, 278, 1, 1, 0xFF8A8A8A
        dd 450, 278, 9, 1, 0xFFE6E6E6
        dd 459, 278, 1, 1, 0xFFB4F0FF
        dd 420, 279, 1, 1, 0xFF1E1EC8
        dd 421, 279, 6, 1, 0xFFE6E6E6
        dd 427, 279, 1, 1, 0xFF8A8A8A
        dd 428, 279, 2, 1, 0xFF503C32
        dd 430, 279, 1, 1, 0xFF8A8A8A
        dd 431, 279, 17, 1, 0xFFE6E6E6
        dd 448, 279, 1, 1, 0xFF8A8A8A
        dd 449, 279, 4, 1, 0xFF503C32
        dd 453, 279, 1, 1, 0xFF8A8A8A
        dd 454, 279, 5, 1, 0xFFE6E6E6
        dd 459, 279, 1, 1, 0xFFB4F0FF
        dd 420, 280, 1, 1, 0xFF8A8A8A
        dd 421, 280, 6, 1, 0xFFE6E6E6
        dd 427, 280, 1, 1, 0xFF8A8A8A
        dd 428, 280, 2, 1, 0xFF503C32
        dd 430, 280, 1, 1, 0xFF8A8A8A
        dd 431, 280, 17, 1, 0xFFE6E6E6
        dd 448, 280, 1, 1, 0xFF8A8A8A
        dd 449, 280, 5, 1, 0xFF503C32
        dd 454, 280, 1, 1, 0xFF8A8A8A
        dd 455, 280, 4, 1, 0xFFE6E6E6
        dd 459, 280, 1, 1, 0xFF8A8A8A
        dd 420, 281, 1, 1, 0xFF8A8A8A
        dd 421, 281, 6, 1, 0xFFE6E6E6
        dd 427, 281, 1, 1, 0xFF8A8A8A
        dd 428, 281, 2, 1, 0xFF503C32
        dd 430, 281, 1, 1, 0xFF8A8A8A
        dd 431, 281, 17, 1, 0xFFE6E6E6
        dd 448, 281, 1, 1, 0xFF8A8A8A
        dd 449, 281, 5, 1, 0xFF503C32
        dd 454, 281, 1, 1, 0xFF8A8A8A
        dd 455, 281, 4, 1, 0xFFE6E6E6
        dd 459, 281, 1, 1, 0xFF8A8A8A
        dd 420, 282, 1, 1, 0xFF8A8A8A
        dd 421, 282, 6, 1, 0xFFE6E6E6
        dd 427, 282, 1, 1, 0xFF8A8A8A
        dd 428, 282, 2, 1, 0xFF503C32
        dd 430, 282, 1, 1, 0xFF8A8A8A
        dd 431, 282, 17, 1, 0xFFE6E6E6
        dd 448, 282, 1, 1, 0xFF8A8A8A
        dd 449, 282, 5, 1, 0xFF503C32
        dd 454, 282, 1, 1, 0xFF8A8A8A
        dd 455, 282, 4, 1, 0xFFE6E6E6
        dd 459, 282, 1, 1, 0xFF8A8A8A
        dd 420, 283, 1, 1, 0xFF8A8A8A
        dd 421, 283, 6, 1, 0xFFE6E6E6
        dd 427, 283, 1, 1, 0xFF8A8A8A
        dd 428, 283, 2, 1, 0xFF503C32
        dd 430, 283, 1, 1, 0xFF8A8A8A
        dd 431, 283, 17, 1, 0xFFE6E6E6
        dd 448, 283, 1, 1, 0xFF8A8A8A
        dd 449, 283, 5, 1, 0xFF503C32
        dd 454, 283, 1, 1, 0xFF8A8A8A
        dd 455, 283, 4, 1, 0xFFE6E6E6
        dd 459, 283, 1, 1, 0xFF8A8A8A
        dd 420, 284, 1, 1, 0xFF8A8A8A
        dd 421, 284, 6, 1, 0xFFE6E6E6
        dd 427, 284, 1, 1, 0xFF8A8A8A
        dd 428, 284, 2, 1, 0xFF503C32
        dd 430, 284, 1, 1, 0xFF8A8A8A
        dd 431, 284, 17, 1, 0xFFE6E6E6
        dd 448, 284, 1, 1, 0xFF8A8A8A
        dd 449, 284, 5, 1, 0xFF503C32
        dd 454, 284, 1, 1, 0xFF8A8A8A
        dd 455, 284, 4, 1, 0xFFE6E6E6
        dd 459, 284, 1, 1, 0xFF8A8A8A
        dd 420, 285, 1, 1, 0xFF8A8A8A
        dd 421, 285, 6, 1, 0xFFE6E6E6
        dd 427, 285, 1, 1, 0xFF8A8A8A
        dd 428, 285, 2, 1, 0xFF503C32
        dd 430, 285, 1, 1, 0xFF8A8A8A
        dd 431, 285, 17, 1, 0xFFE6E6E6
        dd 448, 285, 1, 1, 0xFF8A8A8A
        dd 449, 285, 5, 1, 0xFF503C32
        dd 454, 285, 1, 1, 0xFF8A8A8A
        dd 455, 285, 4, 1, 0xFFE6E6E6
        dd 459, 285, 1, 1, 0xFF8A8A8A
        dd 420, 286, 1, 1, 0xFF8A8A8A
        dd 421, 286, 6, 1, 0xFFE6E6E6
        dd 427, 286, 1, 1, 0xFF8A8A8A
        dd 428, 286, 2, 1, 0xFF503C32
        dd 430, 286, 1, 1, 0xFF8A8A8A
        dd 431, 286, 17, 1, 0xFFE6E6E6
        dd 448, 286, 1, 1, 0xFF8A8A8A
        dd 449, 286, 5, 1, 0xFF503C32
        dd 454, 286, 1, 1, 0xFF8A8A8A
        dd 455, 286, 4, 1, 0xFFE6E6E6
        dd 459, 286, 1, 1, 0xFF8A8A8A
        dd 420, 287, 1, 1, 0xFF8A8A8A
        dd 421, 287, 6, 1, 0xFFE6E6E6
        dd 427, 287, 1, 1, 0xFF8A8A8A
        dd 428, 287, 2, 1, 0xFF503C32
        dd 430, 287, 1, 1, 0xFF8A8A8A
        dd 431, 287, 17, 1, 0xFFE6E6E6
        dd 448, 287, 1, 1, 0xFF8A8A8A
        dd 449, 287, 5, 1, 0xFF503C32
        dd 454, 287, 1, 1, 0xFF8A8A8A
        dd 455, 287, 4, 1, 0xFFE6E6E6
        dd 459, 287, 1, 1, 0xFF8A8A8A
        dd 420, 288, 1, 1, 0xFF8A8A8A
        dd 421, 288, 6, 1, 0xFFE6E6E6
        dd 427, 288, 1, 1, 0xFF8A8A8A
        dd 428, 288, 2, 1, 0xFF503C32
        dd 430, 288, 1, 1, 0xFF8A8A8A
        dd 431, 288, 17, 1, 0xFFE6E6E6
        dd 448, 288, 1, 1, 0xFF8A8A8A
        dd 449, 288, 5, 1, 0xFF503C32
        dd 454, 288, 1, 1, 0xFF8A8A8A
        dd 455, 288, 4, 1, 0xFFE6E6E6
        dd 459, 288, 1, 1, 0xFF8A8A8A
        dd 420, 289, 1, 1, 0xFF8A8A8A
        dd 421, 289, 6, 1, 0xFFE6E6E6
        dd 427, 289, 1, 1, 0xFF8A8A8A
        dd 428, 289, 2, 1, 0xFF503C32
        dd 430, 289, 1, 1, 0xFF8A8A8A
        dd 431, 289, 17, 1, 0xFFE6E6E6
        dd 448, 289, 1, 1, 0xFF8A8A8A
        dd 449, 289, 5, 1, 0xFF503C32
        dd 454, 289, 1, 1, 0xFF8A8A8A
        dd 455, 289, 4, 1, 0xFFE6E6E6
        dd 459, 289, 1, 1, 0xFF8A8A8A
        dd 420, 290, 1, 1, 0xFF1E1EC8
        dd 421, 290, 6, 1, 0xFFE6E6E6
        dd 427, 290, 1, 1, 0xFF8A8A8A
        dd 428, 290, 2, 1, 0xFF503C32
        dd 430, 290, 1, 1, 0xFF8A8A8A
        dd 431, 290, 17, 1, 0xFFE6E6E6
        dd 448, 290, 1, 1, 0xFF8A8A8A
        dd 449, 290, 4, 1, 0xFF503C32
        dd 453, 290, 1, 1, 0xFF8A8A8A
        dd 454, 290, 5, 1, 0xFFE6E6E6
        dd 459, 290, 1, 1, 0xFFB4F0FF
        dd 420, 291, 1, 1, 0xFF1E1EC8
        dd 421, 291, 7, 1, 0xFFE6E6E6
        dd 428, 291, 1, 1, 0xFF8A8A8A
        dd 429, 291, 20, 1, 0xFF826450
        dd 449, 291, 1, 1, 0xFF8A8A8A
        dd 450, 291, 9, 1, 0xFFE6E6E6
        dd 459, 291, 1, 1, 0xFFB4F0FF
        dd 421, 292, 1, 1, 0xFF8A8A8A
        dd 422, 292, 36, 1, 0xFFE6E6E6
        dd 458, 292, 1, 1, 0xFF8A8A8A
        dd 422, 293, 36, 1, 0xFF8A8A8A
        dd 426, 294, 6, 1, 0xFF0F0F0F
        dd 448, 294, 6, 1, 0xFF0F0F0F
        dd 546, 275, 6, 1, 0xFF0F0F0F
        dd 568, 275, 6, 1, 0xFF0F0F0F
        dd 542, 276, 36, 1, 0xFF365436
        dd 541, 277, 1, 1, 0xFF365436
        dd 542, 277, 36, 1, 0xFF5A8C5A
        dd 578, 277, 1, 1, 0xFF365436
        dd 540, 278, 1, 1, 0xFF1E1EC8
        dd 541, 278, 7, 1, 0xFF5A8C5A
        dd 548, 278, 1, 1, 0xFF365436
        dd 549, 278, 20, 1, 0xFF826450
        dd 569, 278, 1, 1, 0xFF365436
        dd 570, 278, 9, 1, 0xFF5A8C5A
        dd 579, 278, 1, 1, 0xFFB4F0FF
        dd 540, 279, 1, 1, 0xFF1E1EC8
        dd 541, 279, 6, 1, 0xFF5A8C5A
        dd 547, 279, 1, 1, 0xFF365436
        dd 548, 279, 2, 1, 0xFF503C32
        dd 550, 279, 1, 1, 0xFF365436
        dd 551, 279, 17, 1, 0xFF5A8C5A
        dd 568, 279, 1, 1, 0xFF365436
        dd 569, 279, 4, 1, 0xFF503C32
        dd 573, 279, 1, 1, 0xFF365436
        dd 574, 279, 5, 1, 0xFF5A8C5A
        dd 579, 279, 1, 1, 0xFFB4F0FF
        dd 540, 280, 1, 1, 0xFF365436
        dd 541, 280, 6, 1, 0xFF5A8C5A
        dd 547, 280, 1, 1, 0xFF365436
        dd 548, 280, 2, 1, 0xFF503C32
        dd 550, 280, 1, 1, 0xFF365436
        dd 551, 280, 17, 1, 0xFF5A8C5A
        dd 568, 280, 1, 1, 0xFF365436
        dd 569, 280, 5, 1, 0xFF503C32
        dd 574, 280, 1, 1, 0xFF365436
        dd 575, 280, 4, 1, 0xFF5A8C5A
        dd 579, 280, 1, 1, 0xFF365436
        dd 540, 281, 1, 1, 0xFF365436
        dd 541, 281, 6, 1, 0xFF5A8C5A
        dd 547, 281, 1, 1, 0xFF365436
        dd 548, 281, 2, 1, 0xFF503C32
        dd 550, 281, 1, 1, 0xFF365436
        dd 551, 281, 17, 1, 0xFF5A8C5A
        dd 568, 281, 1, 1, 0xFF365436
        dd 569, 281, 5, 1, 0xFF503C32
        dd 574, 281, 1, 1, 0xFF365436
        dd 575, 281, 4, 1, 0xFF5A8C5A
        dd 579, 281, 1, 1, 0xFF365436
        dd 540, 282, 1, 1, 0xFF365436
        dd 541, 282, 6, 1, 0xFF5A8C5A
        dd 547, 282, 1, 1, 0xFF365436
        dd 548, 282, 2, 1, 0xFF503C32
        dd 550, 282, 1, 1, 0xFF365436
        dd 551, 282, 17, 1, 0xFF5A8C5A
        dd 568, 282, 1, 1, 0xFF365436
        dd 569, 282, 5, 1, 0xFF503C32
        dd 574, 282, 1, 1, 0xFF365436
        dd 575, 282, 4, 1, 0xFF5A8C5A
        dd 579, 282, 1, 1, 0xFF365436
        dd 540, 283, 1, 1, 0xFF365436
        dd 541, 283, 6, 1, 0xFF5A8C5A
        dd 547, 283, 1, 1, 0xFF365436
        dd 548, 283, 2, 1, 0xFF503C32
        dd 550, 283, 1, 1, 0xFF365436
        dd 551, 283, 17, 1, 0xFF5A8C5A
        dd 568, 283, 1, 1, 0xFF365436
        dd 569, 283, 5, 1, 0xFF503C32
        dd 574, 283, 1, 1, 0xFF365436
        dd 575, 283, 4, 1, 0xFF5A8C5A
        dd 579, 283, 1, 1, 0xFF365436
        dd 540, 284, 1, 1, 0xFF365436
        dd 541, 284, 6, 1, 0xFF5A8C5A
        dd 547, 284, 1, 1, 0xFF365436
        dd 548, 284, 2, 1, 0xFF503C32
        dd 550, 284, 1, 1, 0xFF365436
        dd 551, 284, 17, 1, 0xFF5A8C5A
        dd 568, 284, 1, 1, 0xFF365436
        dd 569, 284, 5, 1, 0xFF503C32
        dd 574, 284, 1, 1, 0xFF365436
        dd 575, 284, 4, 1, 0xFF5A8C5A
        dd 579, 284, 1, 1, 0xFF365436
        dd 540, 285, 1, 1, 0xFF365436
        dd 541, 285, 6, 1, 0xFF5A8C5A
        dd 547, 285, 1, 1, 0xFF365436
        dd 548, 285, 2, 1, 0xFF503C32
        dd 550, 285, 1, 1, 0xFF365436
        dd 551, 285, 17, 1, 0xFF5A8C5A
        dd 568, 285, 1, 1, 0xFF365436
        dd 569, 285, 5, 1, 0xFF503C32
        dd 574, 285, 1, 1, 0xFF365436
        dd 575, 285, 4, 1, 0xFF5A8C5A
        dd 579, 285, 1, 1, 0xFF365436
        dd 540, 286, 1, 1, 0xFF365436
        dd 541, 286, 6, 1, 0xFF5A8C5A
        dd 547, 286, 1, 1, 0xFF365436
        dd 548, 286, 2, 1, 0xFF503C32
        dd 550, 286, 1, 1, 0xFF365436
        dd 551, 286, 17, 1, 0xFF5A8C5A
        dd 568, 286, 1, 1, 0xFF365436
        dd 569, 286, 5, 1, 0xFF503C32
        dd 574, 286, 1, 1, 0xFF365436
        dd 575, 286, 4, 1, 0xFF5A8C5A
        dd 579, 286, 1, 1, 0xFF365436
        dd 540, 287, 1, 1, 0xFF365436
        dd 541, 287, 6, 1, 0xFF5A8C5A
        dd 547, 287, 1, 1, 0xFF365436
        dd 548, 287, 2, 1, 0xFF503C32
        dd 550, 287, 1, 1, 0xFF365436
        dd 551, 287, 17, 1, 0xFF5A8C5A
        dd 568, 287, 1, 1, 0xFF365436
        dd 569, 287, 5, 1, 0xFF503C32
        dd 574, 287, 1, 1, 0xFF365436
        dd 575, 287, 4, 1, 0xFF5A8C5A
        dd 579, 287, 1, 1, 0xFF365436
        dd 540, 288, 1, 1, 0xFF365436
        dd 541, 288, 6, 1, 0xFF5A8C5A
        dd 547, 288, 1, 1, 0xFF365436
        dd 548, 288, 2, 1, 0xFF503C32
        dd 550, 288, 1, 1, 0xFF365436
        dd 551, 288, 17, 1, 0xFF5A8C5A
        dd 568, 288, 1, 1, 0xFF365436
        dd 569, 288, 5, 1, 0xFF503C32
        dd 574, 288, 1, 1, 0xFF365436
        dd 575, 288, 4, 1, 0xFF5A8C5A
        dd 579, 288, 1, 1, 0xFF365436
        dd 540, 289, 1, 1, 0xFF365436
        dd 541, 289, 6, 1, 0xFF5A8C5A
        dd 547, 289, 1, 1, 0xFF365436
        dd 548, 289, 2, 1, 0xFF503C32
        dd 550, 289, 1, 1, 0xFF365436
        dd 551, 289, 17, 1, 0xFF5A8C5A
        dd 568, 289, 1, 1, 0xFF365436
        dd 569, 289, 5, 1, 0xFF503C32
        dd 574, 289, 1, 1, 0xFF365436
        dd 575, 289, 4, 1, 0xFF5A8C5A
        dd 579, 289, 1, 1, 0xFF365436
        dd 540, 290, 1, 1, 0xFF1E1EC8
        dd 541, 290, 6, 1, 0xFF5A8C5A
        dd 547, 290, 1, 1, 0xFF365436
        dd 548, 290, 2, 1, 0xFF503C32
        dd 550, 290, 1, 1, 0xFF365436
        dd 551, 290, 17, 1, 0xFF5A8C5A
        dd 568, 290, 1, 1, 0xFF365436
        dd 569, 290, 4, 1, 0xFF503C32
        dd 573, 290, 1, 1, 0xFF365436
        dd 574, 290, 5, 1, 0xFF5A8C5A
        dd 579, 290, 1, 1, 0xFFB4F0FF
        dd 540, 291, 1, 1, 0xFF1E1EC8
        dd 541, 291, 7, 1, 0xFF5A8C5A
        dd 548, 291, 1, 1, 0xFF365436
        dd 549, 291, 20, 1, 0xFF826450
        dd 569, 291, 1, 1, 0xFF365436
        dd 570, 291, 9, 1, 0xFF5A8C5A
        dd 579, 291, 1, 1, 0xFFB4F0FF
        dd 541, 292, 1, 1, 0xFF365436
        dd 542, 292, 36, 1, 0xFF5A8C5A
        dd 578, 292, 1, 1, 0xFF365436
        dd 542, 293, 36, 1, 0xFF365436
        dd 546, 294, 6, 1, 0xFF0F0F0F
        dd 568, 294, 6, 1, 0xFF0F0F0F
        dd 666, 275, 6, 1, 0xFF0F0F0F
        dd 688, 275, 6, 1, 0xFF0F0F0F
        dd 662, 276, 36, 1, 0xFF18365A
        dd 661, 277, 1, 1, 0xFF18365A
        dd 662, 277, 36, 1, 0xFF285A96
        dd 698, 277, 1, 1, 0xFF18365A
        dd 660, 278, 1, 1, 0xFF1E1EC8
        dd 661, 278, 7, 1, 0xFF285A96
        dd 668, 278, 1, 1, 0xFF18365A
        dd 669, 278, 20, 1, 0xFF826450
        dd 689, 278, 1, 1, 0xFF18365A
        dd 690, 278, 9, 1, 0xFF285A96
        dd 699, 278, 1, 1, 0xFFB4F0FF
        dd 660, 279, 1, 1, 0xFF1E1EC8
        dd 661, 279, 6, 1, 0xFF285A96
        dd 667, 279, 1, 1, 0xFF18365A
        dd 668, 279, 2, 1, 0xFF503C32
        dd 670, 279, 1, 1, 0xFF18365A
        dd 671, 279, 17, 1, 0xFF285A96
        dd 688, 279, 1, 1, 0xFF18365A
        dd 689, 279, 4, 1, 0xFF503C32
        dd 693, 279, 1, 1, 0xFF18365A
        dd 694, 279, 5, 1, 0xFF285A96
        dd 699, 279, 1, 1, 0xFFB4F0FF
        dd 660, 280, 1, 1, 0xFF18365A
        dd 661, 280, 6, 1, 0xFF285A96
        dd 667, 280, 1, 1, 0xFF18365A
        dd 668, 280, 2, 1, 0xFF503C32
        dd 670, 280, 1, 1, 0xFF18365A
        dd 671, 280, 17, 1, 0xFF285A96
        dd 688, 280, 1, 1, 0xFF18365A
        dd 689, 280, 5, 1, 0xFF503C32
        dd 694, 280, 1, 1, 0xFF18365A
        dd 695, 280, 4, 1, 0xFF285A96
        dd 699, 280, 1, 1, 0xFF18365A
        dd 660, 281, 1, 1, 0xFF18365A
        dd 661, 281, 6, 1, 0xFF285A96
        dd 667, 281, 1, 1, 0xFF18365A
        dd 668, 281, 2, 1, 0xFF503C32
        dd 670, 281, 1, 1, 0xFF18365A
        dd 671, 281, 17, 1, 0xFF285A96
        dd 688, 281, 1, 1, 0xFF18365A
        dd 689, 281, 5, 1, 0xFF503C32
        dd 694, 281, 1, 1, 0xFF18365A
        dd 695, 281, 4, 1, 0xFF285A96
        dd 699, 281, 1, 1, 0xFF18365A
        dd 660, 282, 1, 1, 0xFF18365A
        dd 661, 282, 6, 1, 0xFF285A96
        dd 667, 282, 1, 1, 0xFF18365A
        dd 668, 282, 2, 1, 0xFF503C32
        dd 670, 282, 1, 1, 0xFF18365A
        dd 671, 282, 17, 1, 0xFF285A96
        dd 688, 282, 1, 1, 0xFF18365A
        dd 689, 282, 5, 1, 0xFF503C32
        dd 694, 282, 1, 1, 0xFF18365A
        dd 695, 282, 4, 1, 0xFF285A96
        dd 699, 282, 1, 1, 0xFF18365A
        dd 660, 283, 1, 1, 0xFF18365A
        dd 661, 283, 6, 1, 0xFF285A96
        dd 667, 283, 1, 1, 0xFF18365A
        dd 668, 283, 2, 1, 0xFF503C32
        dd 670, 283, 1, 1, 0xFF18365A
        dd 671, 283, 17, 1, 0xFF285A96
        dd 688, 283, 1, 1, 0xFF18365A
        dd 689, 283, 5, 1, 0xFF503C32
        dd 694, 283, 1, 1, 0xFF18365A
        dd 695, 283, 4, 1, 0xFF285A96
        dd 699, 283, 1, 1, 0xFF18365A
        dd 660, 284, 1, 1, 0xFF18365A
        dd 661, 284, 6, 1, 0xFF285A96
        dd 667, 284, 1, 1, 0xFF18365A
        dd 668, 284, 2, 1, 0xFF503C32
        dd 670, 284, 1, 1, 0xFF18365A
        dd 671, 284, 17, 1, 0xFF285A96
        dd 688, 284, 1, 1, 0xFF18365A
        dd 689, 284, 5, 1, 0xFF503C32
        dd 694, 284, 1, 1, 0xFF18365A
        dd 695, 284, 4, 1, 0xFF285A96
        dd 699, 284, 1, 1, 0xFF18365A
        dd 660, 285, 1, 1, 0xFF18365A
        dd 661, 285, 6, 1, 0xFF285A96
        dd 667, 285, 1, 1, 0xFF18365A
        dd 668, 285, 2, 1, 0xFF503C32
        dd 670, 285, 1, 1, 0xFF18365A
        dd 671, 285, 17, 1, 0xFF285A96
        dd 688, 285, 1, 1, 0xFF18365A
        dd 689, 285, 5, 1, 0xFF503C32
        dd 694, 285, 1, 1, 0xFF18365A
        dd 695, 285, 4, 1, 0xFF285A96
        dd 699, 285, 1, 1, 0xFF18365A
        dd 660, 286, 1, 1, 0xFF18365A
        dd 661, 286, 6, 1, 0xFF285A96
        dd 667, 286, 1, 1, 0xFF18365A
        dd 668, 286, 2, 1, 0xFF503C32
        dd 670, 286, 1, 1, 0xFF18365A
        dd 671, 286, 17, 1, 0xFF285A96
        dd 688, 286, 1, 1, 0xFF18365A
        dd 689, 286, 5, 1, 0xFF503C32
        dd 694, 286, 1, 1, 0xFF18365A
        dd 695, 286, 4, 1, 0xFF285A96
        dd 699, 286, 1, 1, 0xFF18365A
        dd 660, 287, 1, 1, 0xFF18365A
        dd 661, 287, 6, 1, 0xFF285A96
        dd 667, 287, 1, 1, 0xFF18365A
        dd 668, 287, 2, 1, 0xFF503C32
        dd 670, 287, 1, 1, 0xFF18365A
        dd 671, 287, 17, 1, 0xFF285A96
        dd 688, 287, 1, 1, 0xFF18365A
        dd 689, 287, 5, 1, 0xFF503C32
        dd 694, 287, 1, 1, 0xFF18365A
        dd 695, 287, 4, 1, 0xFF285A96
        dd 699, 287, 1, 1, 0xFF18365A
        dd 660, 288, 1, 1, 0xFF18365A
        dd 661, 288, 6, 1, 0xFF285A96
        dd 667, 288, 1, 1, 0xFF18365A
        dd 668, 288, 2, 1, 0xFF503C32
        dd 670, 288, 1, 1, 0xFF18365A
        dd 671, 288, 17, 1, 0xFF285A96
        dd 688, 288, 1, 1, 0xFF18365A
        dd 689, 288, 5, 1, 0xFF503C32
        dd 694, 288, 1, 1, 0xFF18365A
        dd 695, 288, 4, 1, 0xFF285A96
        dd 699, 288, 1, 1, 0xFF18365A
        dd 660, 289, 1, 1, 0xFF18365A
        dd 661, 289, 6, 1, 0xFF285A96
        dd 667, 289, 1, 1, 0xFF18365A
        dd 668, 289, 2, 1, 0xFF503C32
        dd 670, 289, 1, 1, 0xFF18365A
        dd 671, 289, 17, 1, 0xFF285A96
        dd 688, 289, 1, 1, 0xFF18365A
        dd 689, 289, 5, 1, 0xFF503C32
        dd 694, 289, 1, 1, 0xFF18365A
        dd 695, 289, 4, 1, 0xFF285A96
        dd 699, 289, 1, 1, 0xFF18365A
        dd 660, 290, 1, 1, 0xFF1E1EC8
        dd 661, 290, 6, 1, 0xFF285A96
        dd 667, 290, 1, 1, 0xFF18365A
        dd 668, 290, 2, 1, 0xFF503C32
        dd 670, 290, 1, 1, 0xFF18365A
        dd 671, 290, 17, 1, 0xFF285A96
        dd 688, 290, 1, 1, 0xFF18365A
        dd 689, 290, 4, 1, 0xFF503C32
        dd 693, 290, 1, 1, 0xFF18365A
        dd 694, 290, 5, 1, 0xFF285A96
        dd 699, 290, 1, 1, 0xFFB4F0FF
        dd 660, 291, 1, 1, 0xFF1E1EC8
        dd 661, 291, 7, 1, 0xFF285A96
        dd 668, 291, 1, 1, 0xFF18365A
        dd 669, 291, 20, 1, 0xFF826450
        dd 689, 291, 1, 1, 0xFF18365A
        dd 690, 291, 9, 1, 0xFF285A96
        dd 699, 291, 1, 1, 0xFFB4F0FF
        dd 661, 292, 1, 1, 0xFF18365A
        dd 662, 292, 36, 1, 0xFF285A96
        dd 698, 292, 1, 1, 0xFF18365A
        dd 662, 293, 36, 1, 0xFF18365A
        dd 666, 294, 6, 1, 0xFF0F0F0F
        dd 688, 294, 6, 1, 0xFF0F0F0F
        dd 826, 275, 6, 1, 0xFF0F0F0F
        dd 848, 275, 6, 1, 0xFF0F0F0F
        dd 822, 276, 36, 1, 0xFF7E7878
        dd 821, 277, 1, 1, 0xFF7E7878
        dd 822, 277, 36, 1, 0xFFD2C8C8
        dd 858, 277, 1, 1, 0xFF7E7878
        dd 820, 278, 1, 1, 0xFF1E1EC8
        dd 821, 278, 7, 1, 0xFFD2C8C8
        dd 828, 278, 1, 1, 0xFF7E7878
        dd 829, 278, 20, 1, 0xFF826450
        dd 849, 278, 1, 1, 0xFF7E7878
        dd 850, 278, 9, 1, 0xFFD2C8C8
        dd 859, 278, 1, 1, 0xFFB4F0FF
        dd 820, 279, 1, 1, 0xFF1E1EC8
        dd 821, 279, 6, 1, 0xFFD2C8C8
        dd 827, 279, 1, 1, 0xFF7E7878
        dd 828, 279, 2, 1, 0xFF503C32
        dd 830, 279, 1, 1, 0xFF7E7878
        dd 831, 279, 17, 1, 0xFFD2C8C8
        dd 848, 279, 1, 1, 0xFF7E7878
        dd 849, 279, 4, 1, 0xFF503C32
        dd 853, 279, 1, 1, 0xFF7E7878
        dd 854, 279, 5, 1, 0xFFD2C8C8
        dd 859, 279, 1, 1, 0xFFB4F0FF
        dd 820, 280, 1, 1, 0xFF7E7878
        dd 821, 280, 6, 1, 0xFFD2C8C8
        dd 827, 280, 1, 1, 0xFF7E7878
        dd 828, 280, 2, 1, 0xFF503C32
        dd 830, 280, 1, 1, 0xFF7E7878
        dd 831, 280, 17, 1, 0xFFD2C8C8
        dd 848, 280, 1, 1, 0xFF7E7878
        dd 849, 280, 5, 1, 0xFF503C32
        dd 854, 280, 1, 1, 0xFF7E7878
        dd 855, 280, 4, 1, 0xFFD2C8C8
        dd 859, 280, 1, 1, 0xFF7E7878
        dd 820, 281, 1, 1, 0xFF7E7878
        dd 821, 281, 6, 1, 0xFFD2C8C8
        dd 827, 281, 1, 1, 0xFF7E7878
        dd 828, 281, 2, 1, 0xFF503C32
        dd 830, 281, 1, 1, 0xFF7E7878
        dd 831, 281, 17, 1, 0xFFD2C8C8
        dd 848, 281, 1, 1, 0xFF7E7878
        dd 849, 281, 5, 1, 0xFF503C32
        dd 854, 281, 1, 1, 0xFF7E7878
        dd 855, 281, 4, 1, 0xFFD2C8C8
        dd 859, 281, 1, 1, 0xFF7E7878
        dd 820, 282, 1, 1, 0xFF7E7878
        dd 821, 282, 6, 1, 0xFFD2C8C8
        dd 827, 282, 1, 1, 0xFF7E7878
        dd 828, 282, 2, 1, 0xFF503C32
        dd 830, 282, 1, 1, 0xFF7E7878
        dd 831, 282, 17, 1, 0xFFD2C8C8
        dd 848, 282, 1, 1, 0xFF7E7878
        dd 849, 282, 5, 1, 0xFF503C32
        dd 854, 282, 1, 1, 0xFF7E7878
        dd 855, 282, 4, 1, 0xFFD2C8C8
        dd 859, 282, 1, 1, 0xFF7E7878
        dd 820, 283, 1, 1, 0xFF7E7878
        dd 821, 283, 6, 1, 0xFFD2C8C8
        dd 827, 283, 1, 1, 0xFF7E7878
        dd 828, 283, 2, 1, 0xFF503C32
        dd 830, 283, 1, 1, 0xFF7E7878
        dd 831, 283, 17, 1, 0xFFD2C8C8
        dd 848, 283, 1, 1, 0xFF7E7878
        dd 849, 283, 5, 1, 0xFF503C32
        dd 854, 283, 1, 1, 0xFF7E7878
        dd 855, 283, 4, 1, 0xFFD2C8C8
        dd 859, 283, 1, 1, 0xFF7E7878
        dd 820, 284, 1, 1, 0xFF7E7878
        dd 821, 284, 6, 1, 0xFFD2C8C8
        dd 827, 284, 1, 1, 0xFF7E7878
        dd 828, 284, 2, 1, 0xFF503C32
        dd 830, 284, 1, 1, 0xFF7E7878
        dd 831, 284, 17, 1, 0xFFD2C8C8
        dd 848, 284, 1, 1, 0xFF7E7878
        dd 849, 284, 5, 1, 0xFF503C32
        dd 854, 284, 1, 1, 0xFF7E7878
        dd 855, 284, 4, 1, 0xFFD2C8C8
        dd 859, 284, 1, 1, 0xFF7E7878
        dd 820, 285, 1, 1, 0xFF7E7878
        dd 821, 285, 6, 1, 0xFFD2C8C8
        dd 827, 285, 1, 1, 0xFF7E7878
        dd 828, 285, 2, 1, 0xFF503C32
        dd 830, 285, 1, 1, 0xFF7E7878
        dd 831, 285, 17, 1, 0xFFD2C8C8
        dd 848, 285, 1, 1, 0xFF7E7878
        dd 849, 285, 5, 1, 0xFF503C32
        dd 854, 285, 1, 1, 0xFF7E7878
        dd 855, 285, 4, 1, 0xFFD2C8C8
        dd 859, 285, 1, 1, 0xFF7E7878
        dd 820, 286, 1, 1, 0xFF7E7878
        dd 821, 286, 6, 1, 0xFFD2C8C8
        dd 827, 286, 1, 1, 0xFF7E7878
        dd 828, 286, 2, 1, 0xFF503C32
        dd 830, 286, 1, 1, 0xFF7E7878
        dd 831, 286, 17, 1, 0xFFD2C8C8
        dd 848, 286, 1, 1, 0xFF7E7878
        dd 849, 286, 5, 1, 0xFF503C32
        dd 854, 286, 1, 1, 0xFF7E7878
        dd 855, 286, 4, 1, 0xFFD2C8C8
        dd 859, 286, 1, 1, 0xFF7E7878
        dd 820, 287, 1, 1, 0xFF7E7878
        dd 821, 287, 6, 1, 0xFFD2C8C8
        dd 827, 287, 1, 1, 0xFF7E7878
        dd 828, 287, 2, 1, 0xFF503C32
        dd 830, 287, 1, 1, 0xFF7E7878
        dd 831, 287, 17, 1, 0xFFD2C8C8
        dd 848, 287, 1, 1, 0xFF7E7878
        dd 849, 287, 5, 1, 0xFF503C32
        dd 854, 287, 1, 1, 0xFF7E7878
        dd 855, 287, 4, 1, 0xFFD2C8C8
        dd 859, 287, 1, 1, 0xFF7E7878
        dd 820, 288, 1, 1, 0xFF7E7878
        dd 821, 288, 6, 1, 0xFFD2C8C8
        dd 827, 288, 1, 1, 0xFF7E7878
        dd 828, 288, 2, 1, 0xFF503C32
        dd 830, 288, 1, 1, 0xFF7E7878
        dd 831, 288, 17, 1, 0xFFD2C8C8
        dd 848, 288, 1, 1, 0xFF7E7878
        dd 849, 288, 5, 1, 0xFF503C32
        dd 854, 288, 1, 1, 0xFF7E7878
        dd 855, 288, 4, 1, 0xFFD2C8C8
        dd 859, 288, 1, 1, 0xFF7E7878
        dd 820, 289, 1, 1, 0xFF7E7878
        dd 821, 289, 6, 1, 0xFFD2C8C8
        dd 827, 289, 1, 1, 0xFF7E7878
        dd 828, 289, 2, 1, 0xFF503C32
        dd 830, 289, 1, 1, 0xFF7E7878
        dd 831, 289, 17, 1, 0xFFD2C8C8
        dd 848, 289, 1, 1, 0xFF7E7878
        dd 849, 289, 5, 1, 0xFF503C32
        dd 854, 289, 1, 1, 0xFF7E7878
        dd 855, 289, 4, 1, 0xFFD2C8C8
        dd 859, 289, 1, 1, 0xFF7E7878
        dd 820, 290, 1, 1, 0xFF1E1EC8
        dd 821, 290, 6, 1, 0xFFD2C8C8
        dd 827, 290, 1, 1, 0xFF7E7878
        dd 828, 290, 2, 1, 0xFF503C32
        dd 830, 290, 1, 1, 0xFF7E7878
        dd 831, 290, 17, 1, 0xFFD2C8C8
        dd 848, 290, 1, 1, 0xFF7E7878
        dd 849, 290, 4, 1, 0xFF503C32
        dd 853, 290, 1, 1, 0xFF7E7878
        dd 854, 290, 5, 1, 0xFFD2C8C8
        dd 859, 290, 1, 1, 0xFFB4F0FF
        dd 820, 291, 1, 1, 0xFF1E1EC8
        dd 821, 291, 7, 1, 0xFFD2C8C8
        dd 828, 291, 1, 1, 0xFF7E7878
        dd 829, 291, 20, 1, 0xFF826450
        dd 849, 291, 1, 1, 0xFF7E7878
        dd 850, 291, 9, 1, 0xFFD2C8C8
        dd 859, 291, 1, 1, 0xFFB4F0FF
        dd 821, 292, 1, 1, 0xFF7E7878
        dd 822, 292, 36, 1, 0xFFD2C8C8
        dd 858, 292, 1, 1, 0xFF7E7878
        dd 822, 293, 36, 1, 0xFF7E7878
        dd 826, 294, 6, 1, 0xFF0F0F0F
        dd 848, 294, 6, 1, 0xFF0F0F0F
        dd 646, 607, 6, 1, 0xFF0F0F0F
        dd 668, 607, 6, 1, 0xFF0F0F0F
        dd 642, 608, 36, 1, 0xFF181866
        dd 641, 609, 1, 1, 0xFF181866
        dd 642, 609, 36, 1, 0xFF2828AA
        dd 678, 609, 1, 1, 0xFF181866
        dd 640, 610, 1, 1, 0xFF1E1EC8
        dd 641, 610, 7, 1, 0xFF2828AA
        dd 648, 610, 1, 1, 0xFF181866
        dd 649, 610, 20, 1, 0xFF826450
        dd 669, 610, 1, 1, 0xFF181866
        dd 670, 610, 9, 1, 0xFF2828AA
        dd 679, 610, 1, 1, 0xFFB4F0FF
        dd 640, 611, 1, 1, 0xFF1E1EC8
        dd 641, 611, 6, 1, 0xFF2828AA
        dd 647, 611, 1, 1, 0xFF181866
        dd 648, 611, 2, 1, 0xFF503C32
        dd 650, 611, 1, 1, 0xFF181866
        dd 651, 611, 17, 1, 0xFF2828AA
        dd 668, 611, 1, 1, 0xFF181866
        dd 669, 611, 4, 1, 0xFF503C32
        dd 673, 611, 1, 1, 0xFF181866
        dd 674, 611, 5, 1, 0xFF2828AA
        dd 679, 611, 1, 1, 0xFFB4F0FF
        dd 640, 612, 1, 1, 0xFF181866
        dd 641, 612, 6, 1, 0xFF2828AA
        dd 647, 612, 1, 1, 0xFF181866
        dd 648, 612, 2, 1, 0xFF503C32
        dd 650, 612, 1, 1, 0xFF181866
        dd 651, 612, 17, 1, 0xFF2828AA
        dd 668, 612, 1, 1, 0xFF181866
        dd 669, 612, 5, 1, 0xFF503C32
        dd 674, 612, 1, 1, 0xFF181866
        dd 675, 612, 4, 1, 0xFF2828AA
        dd 679, 612, 1, 1, 0xFF181866
        dd 640, 613, 1, 1, 0xFF181866
        dd 641, 613, 6, 1, 0xFF2828AA
        dd 647, 613, 1, 1, 0xFF181866
        dd 648, 613, 2, 1, 0xFF503C32
        dd 650, 613, 1, 1, 0xFF181866
        dd 651, 613, 17, 1, 0xFF2828AA
        dd 668, 613, 1, 1, 0xFF181866
        dd 669, 613, 5, 1, 0xFF503C32
        dd 674, 613, 1, 1, 0xFF181866
        dd 675, 613, 4, 1, 0xFF2828AA
        dd 679, 613, 1, 1, 0xFF181866
        dd 640, 614, 1, 1, 0xFF181866
        dd 641, 614, 6, 1, 0xFF2828AA
        dd 647, 614, 1, 1, 0xFF181866
        dd 648, 614, 2, 1, 0xFF503C32
        dd 650, 614, 1, 1, 0xFF181866
        dd 651, 614, 17, 1, 0xFF2828AA
        dd 668, 614, 1, 1, 0xFF181866
        dd 669, 614, 5, 1, 0xFF503C32
        dd 674, 614, 1, 1, 0xFF181866
        dd 675, 614, 4, 1, 0xFF2828AA
        dd 679, 614, 1, 1, 0xFF181866
        dd 640, 615, 1, 1, 0xFF181866
        dd 641, 615, 6, 1, 0xFF2828AA
        dd 647, 615, 1, 1, 0xFF181866
        dd 648, 615, 2, 1, 0xFF503C32
        dd 650, 615, 1, 1, 0xFF181866
        dd 651, 615, 17, 1, 0xFF2828AA
        dd 668, 615, 1, 1, 0xFF181866
        dd 669, 615, 5, 1, 0xFF503C32
        dd 674, 615, 1, 1, 0xFF181866
        dd 675, 615, 4, 1, 0xFF2828AA
        dd 679, 615, 1, 1, 0xFF181866
        dd 640, 616, 1, 1, 0xFF181866
        dd 641, 616, 6, 1, 0xFF2828AA
        dd 647, 616, 1, 1, 0xFF181866
        dd 648, 616, 2, 1, 0xFF503C32
        dd 650, 616, 1, 1, 0xFF181866
        dd 651, 616, 17, 1, 0xFF2828AA
        dd 668, 616, 1, 1, 0xFF181866
        dd 669, 616, 5, 1, 0xFF503C32
        dd 674, 616, 1, 1, 0xFF181866
        dd 675, 616, 4, 1, 0xFF2828AA
        dd 679, 616, 1, 1, 0xFF181866
        dd 640, 617, 1, 1, 0xFF181866
        dd 641, 617, 6, 1, 0xFF2828AA
        dd 647, 617, 1, 1, 0xFF181866
        dd 648, 617, 2, 1, 0xFF503C32
        dd 650, 617, 1, 1, 0xFF181866
        dd 651, 617, 17, 1, 0xFF2828AA
        dd 668, 617, 1, 1, 0xFF181866
        dd 669, 617, 5, 1, 0xFF503C32
        dd 674, 617, 1, 1, 0xFF181866
        dd 675, 617, 4, 1, 0xFF2828AA
        dd 679, 617, 1, 1, 0xFF181866
        dd 640, 618, 1, 1, 0xFF181866
        dd 641, 618, 6, 1, 0xFF2828AA
        dd 647, 618, 1, 1, 0xFF181866
        dd 648, 618, 2, 1, 0xFF503C32
        dd 650, 618, 1, 1, 0xFF181866
        dd 651, 618, 17, 1, 0xFF2828AA
        dd 668, 618, 1, 1, 0xFF181866
        dd 669, 618, 5, 1, 0xFF503C32
        dd 674, 618, 1, 1, 0xFF181866
        dd 675, 618, 4, 1, 0xFF2828AA
        dd 679, 618, 1, 1, 0xFF181866
        dd 640, 619, 1, 1, 0xFF181866
        dd 641, 619, 6, 1, 0xFF2828AA
        dd 647, 619, 1, 1, 0xFF181866
        dd 648, 619, 2, 1, 0xFF503C32
        dd 650, 619, 1, 1, 0xFF181866
        dd 651, 619, 17, 1, 0xFF2828AA
        dd 668, 619, 1, 1, 0xFF181866
        dd 669, 619, 5, 1, 0xFF503C32
        dd 674, 619, 1, 1, 0xFF181866
        dd 675, 619, 4, 1, 0xFF2828AA
        dd 679, 619, 1, 1, 0xFF181866
        dd 640, 620, 1, 1, 0xFF181866
        dd 641, 620, 6, 1, 0xFF2828AA
        dd 647, 620, 1, 1, 0xFF181866
        dd 648, 620, 2, 1, 0xFF503C32
        dd 650, 620, 1, 1, 0xFF181866
        dd 651, 620, 17, 1, 0xFF2828AA
        dd 668, 620, 1, 1, 0xFF181866
        dd 669, 620, 5, 1, 0xFF503C32
        dd 674, 620, 1, 1, 0xFF181866
        dd 675, 620, 4, 1, 0xFF2828AA
        dd 679, 620, 1, 1, 0xFF181866
        dd 640, 621, 1, 1, 0xFF181866
        dd 641, 621, 6, 1, 0xFF2828AA
        dd 647, 621, 1, 1, 0xFF181866
        dd 648, 621, 2, 1, 0xFF503C32
        dd 650, 621, 1, 1, 0xFF181866
        dd 651, 621, 17, 1, 0xFF2828AA
        dd 668, 621, 1, 1, 0xFF181866
        dd 669, 621, 5, 1, 0xFF503C32
        dd 674, 621, 1, 1, 0xFF181866
        dd 675, 621, 4, 1, 0xFF2828AA
        dd 679, 621, 1, 1, 0xFF181866
        dd 640, 622, 1, 1, 0xFF1E1EC8
        dd 641, 622, 6, 1, 0xFF2828AA
        dd 647, 622, 1, 1, 0xFF181866
        dd 648, 622, 2, 1, 0xFF503C32
        dd 650, 622, 1, 1, 0xFF181866
        dd 651, 622, 17, 1, 0xFF2828AA
        dd 668, 622, 1, 1, 0xFF181866
        dd 669, 622, 4, 1, 0xFF503C32
        dd 673, 622, 1, 1, 0xFF181866
        dd 674, 622, 5, 1, 0xFF2828AA
        dd 679, 622, 1, 1, 0xFFB4F0FF
        dd 640, 623, 1, 1, 0xFF1E1EC8
        dd 641, 623, 7, 1, 0xFF2828AA
        dd 648, 623, 1, 1, 0xFF181866
        dd 649, 623, 20, 1, 0xFF826450
        dd 669, 623, 1, 1, 0xFF181866
        dd 670, 623, 9, 1, 0xFF2828AA
        dd 679, 623, 1, 1, 0xFFB4F0FF
        dd 641, 624, 1, 1, 0xFF181866
        dd 642, 624, 36, 1, 0xFF2828AA
        dd 678, 624, 1, 1, 0xFF181866
        dd 642, 625, 36, 1, 0xFF181866
        dd 646, 626, 6, 1, 0xFF0F0F0F
        dd 668, 626, 6, 1, 0xFF0F0F0F
        dd 541, 540, 1, 1, 0xFF141414
        dd 564, 540, 1, 1, 0xFF141414
        dd 540, 541, 26, 1, 0xFF26411E
        dd 540, 542, 1, 1, 0xFF26411E
        dd 541, 542, 11, 1, 0xFF325A28
        dd 552, 542, 1, 1, 0xFF26411E
        dd 553, 542, 12, 1, 0xFF325A28
        dd 565, 542, 1, 1, 0xFF26411E
        dd 540, 543, 1, 1, 0xFF26411E
        dd 541, 543, 11, 1, 0xFF325A28
        dd 552, 543, 1, 1, 0xFF26411E
        dd 553, 543, 4, 1, 0xFF325A28
        dd 557, 543, 2, 1, 0xFF284682
        dd 559, 543, 6, 1, 0xFF325A28
        dd 565, 543, 1, 1, 0xFF26411E
        dd 540, 544, 1, 1, 0xFF26411E
        dd 541, 544, 2, 1, 0xFF325A28
        dd 543, 544, 3, 1, 0xFFA0A0A0
        dd 546, 544, 6, 1, 0xFF325A28
        dd 552, 544, 1, 1, 0xFF26411E
        dd 553, 544, 5, 1, 0xFF325A28
        dd 558, 544, 1, 1, 0xFF284682
        dd 559, 544, 2, 1, 0xFF325A28
        dd 561, 544, 3, 1, 0xFFA0A0A0
        dd 564, 544, 1, 1, 0xFF325A28
        dd 565, 544, 1, 1, 0xFF26411E
        dd 540, 545, 1, 1, 0xFF26411E
        dd 541, 545, 11, 1, 0xFF325A28
        dd 552, 545, 1, 1, 0xFF26411E
        dd 553, 545, 12, 1, 0xFF325A28
        dd 565, 545, 1, 1, 0xFF26411E
        dd 540, 546, 1, 1, 0xFF26411E
        dd 541, 546, 11, 1, 0xFF325A28
        dd 552, 546, 1, 1, 0xFF26411E
        dd 553, 546, 12, 1, 0xFF325A28
        dd 565, 546, 1, 1, 0xFF26411E
        dd 540, 547, 1, 1, 0xFF26411E
        dd 541, 547, 5, 1, 0xFF325A28
        dd 546, 547, 1, 1, 0xFF284682
        dd 547, 547, 5, 1, 0xFF325A28
        dd 552, 547, 1, 1, 0xFF26411E
        dd 553, 547, 12, 1, 0xFF325A28
        dd 565, 547, 1, 1, 0xFF26411E
        dd 540, 548, 1, 1, 0xFF26411E
        dd 541, 548, 11, 1, 0xFF325A28
        dd 552, 548, 1, 1, 0xFF26411E
        dd 553, 548, 12, 1, 0xFF325A28
        dd 565, 548, 1, 1, 0xFF26411E
        dd 540, 549, 1, 1, 0xFF26411E
        dd 541, 549, 11, 1, 0xFF325A28
        dd 552, 549, 1, 1, 0xFF26411E
        dd 553, 549, 12, 1, 0xFF325A28
        dd 565, 549, 1, 1, 0xFF26411E
        dd 540, 550, 1, 1, 0xFF26411E
        dd 541, 550, 11, 1, 0xFF325A28
        dd 552, 550, 1, 1, 0xFF26411E
        dd 553, 550, 12, 1, 0xFF325A28
        dd 565, 550, 1, 1, 0xFF26411E
        dd 540, 551, 1, 1, 0xFF26411E
        dd 541, 551, 11, 1, 0xFF325A28
        dd 552, 551, 1, 1, 0xFF26411E
        dd 553, 551, 12, 1, 0xFF325A28
        dd 565, 551, 1, 1, 0xFF26411E
        dd 540, 552, 1, 1, 0xFF26411E
        dd 541, 552, 24, 1, 0xFF464646
        dd 565, 552, 1, 1, 0xFF26411E
        dd 540, 553, 26, 1, 0xFF26411E
        dd 541, 554, 1, 1, 0xFF141414
        dd 564, 554, 1, 1, 0xFF141414
        dd 691, 540, 1, 1, 0xFF141414
        dd 714, 540, 1, 1, 0xFF141414
        dd 690, 541, 26, 1, 0xFF26411E
        dd 690, 542, 1, 1, 0xFF26411E
        dd 691, 542, 11, 1, 0xFF325A28
        dd 702, 542, 1, 1, 0xFF26411E
        dd 703, 542, 12, 1, 0xFF325A28
        dd 715, 542, 1, 1, 0xFF26411E
        dd 690, 543, 1, 1, 0xFF26411E
        dd 691, 543, 11, 1, 0xFF325A28
        dd 702, 543, 1, 1, 0xFF26411E
        dd 703, 543, 4, 1, 0xFF325A28
        dd 707, 543, 2, 1, 0xFF284682
        dd 709, 543, 6, 1, 0xFF325A28
        dd 715, 543, 1, 1, 0xFF26411E
        dd 690, 544, 1, 1, 0xFF26411E
        dd 691, 544, 2, 1, 0xFF325A28
        dd 693, 544, 3, 1, 0xFFA0A0A0
        dd 696, 544, 6, 1, 0xFF325A28
        dd 702, 544, 1, 1, 0xFF26411E
        dd 703, 544, 5, 1, 0xFF325A28
        dd 708, 544, 1, 1, 0xFF284682
        dd 709, 544, 2, 1, 0xFF325A28
        dd 711, 544, 3, 1, 0xFFA0A0A0
        dd 714, 544, 1, 1, 0xFF325A28
        dd 715, 544, 1, 1, 0xFF26411E
        dd 690, 545, 1, 1, 0xFF26411E
        dd 691, 545, 11, 1, 0xFF325A28
        dd 702, 545, 1, 1, 0xFF26411E
        dd 703, 545, 12, 1, 0xFF325A28
        dd 715, 545, 1, 1, 0xFF26411E
        dd 690, 546, 1, 1, 0xFF26411E
        dd 691, 546, 11, 1, 0xFF325A28
        dd 702, 546, 1, 1, 0xFF26411E
        dd 703, 546, 12, 1, 0xFF325A28
        dd 715, 546, 1, 1, 0xFF26411E
        dd 690, 547, 1, 1, 0xFF26411E
        dd 691, 547, 5, 1, 0xFF325A28
        dd 696, 547, 1, 1, 0xFF284682
        dd 697, 547, 5, 1, 0xFF325A28
        dd 702, 547, 1, 1, 0xFF26411E
        dd 703, 547, 12, 1, 0xFF325A28
        dd 715, 547, 1, 1, 0xFF26411E
        dd 690, 548, 1, 1, 0xFF26411E
        dd 691, 548, 11, 1, 0xFF325A28
        dd 702, 548, 1, 1, 0xFF26411E
        dd 703, 548, 12, 1, 0xFF325A28
        dd 715, 548, 1, 1, 0xFF26411E
        dd 690, 549, 1, 1, 0xFF26411E
        dd 691, 549, 11, 1, 0xFF325A28
        dd 702, 549, 1, 1, 0xFF26411E
        dd 703, 549, 12, 1, 0xFF325A28
        dd 715, 549, 1, 1, 0xFF26411E
        dd 690, 550, 1, 1, 0xFF26411E
        dd 691, 550, 11, 1, 0xFF325A28
        dd 702, 550, 1, 1, 0xFF26411E
        dd 703, 550, 12, 1, 0xFF325A28
        dd 715, 550, 1, 1, 0xFF26411E
        dd 690, 551, 1, 1, 0xFF26411E
        dd 691, 551, 11, 1, 0xFF325A28
        dd 702, 551, 1, 1, 0xFF26411E
        dd 703, 551, 12, 1, 0xFF325A28
        dd 715, 551, 1, 1, 0xFF26411E
        dd 690, 552, 1, 1, 0xFF26411E
        dd 691, 552, 24, 1, 0xFF464646
        dd 715, 552, 1, 1, 0xFF26411E
        dd 690, 553, 26, 1, 0xFF26411E
        dd 691, 554, 1, 1, 0xFF141414
        dd 714, 554, 1, 1, 0xFF141414
        dd 1117, 610, 13, 1, 0xFF26411E
        dd 1116, 611, 1, 1, 0xFF141414
        dd 1117, 611, 1, 1, 0xFF26411E
        dd 1118, 611, 1, 1, 0xFF464646
        dd 1119, 611, 10, 1, 0xFF325A28
        dd 1129, 611, 1, 1, 0xFF26411E
        dd 1130, 611, 1, 1, 0xFF141414
        dd 1117, 612, 1, 1, 0xFF26411E
        dd 1118, 612, 1, 1, 0xFF464646
        dd 1119, 612, 10, 1, 0xFF325A28
        dd 1129, 612, 1, 1, 0xFF26411E
        dd 1117, 613, 1, 1, 0xFF26411E
        dd 1118, 613, 1, 1, 0xFF464646
        dd 1119, 613, 7, 1, 0xFF325A28
        dd 1126, 613, 1, 1, 0xFFA0A0A0
        dd 1127, 613, 2, 1, 0xFF325A28
        dd 1129, 613, 1, 1, 0xFF26411E
        dd 1117, 614, 1, 1, 0xFF26411E
        dd 1118, 614, 1, 1, 0xFF464646
        dd 1119, 614, 7, 1, 0xFF325A28
        dd 1126, 614, 1, 1, 0xFFA0A0A0
        dd 1127, 614, 2, 1, 0xFF325A28
        dd 1129, 614, 1, 1, 0xFF26411E
        dd 1117, 615, 1, 1, 0xFF26411E
        dd 1118, 615, 1, 1, 0xFF464646
        dd 1119, 615, 7, 1, 0xFF325A28
        dd 1126, 615, 1, 1, 0xFFA0A0A0
        dd 1127, 615, 2, 1, 0xFF325A28
        dd 1129, 615, 1, 1, 0xFF26411E
        dd 1117, 616, 1, 1, 0xFF26411E
        dd 1118, 616, 1, 1, 0xFF464646
        dd 1119, 616, 4, 1, 0xFF325A28
        dd 1123, 616, 1, 1, 0xFF284682
        dd 1124, 616, 5, 1, 0xFF325A28
        dd 1129, 616, 1, 1, 0xFF26411E
        dd 1117, 617, 1, 1, 0xFF26411E
        dd 1118, 617, 1, 1, 0xFF464646
        dd 1119, 617, 10, 1, 0xFF325A28
        dd 1129, 617, 1, 1, 0xFF26411E
        dd 1117, 618, 1, 1, 0xFF26411E
        dd 1118, 618, 1, 1, 0xFF464646
        dd 1119, 618, 10, 1, 0xFF325A28
        dd 1129, 618, 1, 1, 0xFF26411E
        dd 1117, 619, 1, 1, 0xFF26411E
        dd 1118, 619, 1, 1, 0xFF464646
        dd 1119, 619, 10, 1, 0xFF325A28
        dd 1129, 619, 1, 1, 0xFF26411E
        dd 1117, 620, 1, 1, 0xFF26411E
        dd 1118, 620, 1, 1, 0xFF464646
        dd 1119, 620, 10, 1, 0xFF325A28
        dd 1129, 620, 1, 1, 0xFF26411E
        dd 1117, 621, 1, 1, 0xFF26411E
        dd 1118, 621, 1, 1, 0xFF464646
        dd 1119, 621, 10, 1, 0xFF325A28
        dd 1129, 621, 1, 1, 0xFF26411E
        dd 1117, 622, 1, 1, 0xFF26411E
        dd 1118, 622, 1, 1, 0xFF464646
        dd 1119, 622, 11, 1, 0xFF26411E
        dd 1117, 623, 1, 1, 0xFF26411E
        dd 1118, 623, 1, 1, 0xFF464646
        dd 1119, 623, 10, 1, 0xFF325A28
        dd 1129, 623, 1, 1, 0xFF26411E
        dd 1117, 624, 1, 1, 0xFF26411E
        dd 1118, 624, 1, 1, 0xFF464646
        dd 1119, 624, 10, 1, 0xFF325A28
        dd 1129, 624, 1, 1, 0xFF26411E
        dd 1117, 625, 1, 1, 0xFF26411E
        dd 1118, 625, 1, 1, 0xFF464646
        dd 1119, 625, 10, 1, 0xFF325A28
        dd 1129, 625, 1, 1, 0xFF26411E
        dd 1117, 626, 1, 1, 0xFF26411E
        dd 1118, 626, 1, 1, 0xFF464646
        dd 1119, 626, 10, 1, 0xFF325A28
        dd 1129, 626, 1, 1, 0xFF26411E
        dd 1117, 627, 1, 1, 0xFF26411E
        dd 1118, 627, 1, 1, 0xFF464646
        dd 1119, 627, 8, 1, 0xFF325A28
        dd 1127, 627, 1, 1, 0xFF284682
        dd 1128, 627, 1, 1, 0xFF325A28
        dd 1129, 627, 1, 1, 0xFF26411E
        dd 1117, 628, 1, 1, 0xFF26411E
        dd 1118, 628, 1, 1, 0xFF464646
        dd 1119, 628, 7, 1, 0xFF325A28
        dd 1126, 628, 2, 1, 0xFF284682
        dd 1128, 628, 1, 1, 0xFF325A28
        dd 1129, 628, 1, 1, 0xFF26411E
        dd 1117, 629, 1, 1, 0xFF26411E
        dd 1118, 629, 1, 1, 0xFF464646
        dd 1119, 629, 10, 1, 0xFF325A28
        dd 1129, 629, 1, 1, 0xFF26411E
        dd 1117, 630, 1, 1, 0xFF26411E
        dd 1118, 630, 1, 1, 0xFF464646
        dd 1119, 630, 10, 1, 0xFF325A28
        dd 1129, 630, 1, 1, 0xFF26411E
        dd 1117, 631, 1, 1, 0xFF26411E
        dd 1118, 631, 1, 1, 0xFF464646
        dd 1119, 631, 7, 1, 0xFF325A28
        dd 1126, 631, 1, 1, 0xFFA0A0A0
        dd 1127, 631, 2, 1, 0xFF325A28
        dd 1129, 631, 1, 1, 0xFF26411E
        dd 1117, 632, 1, 1, 0xFF26411E
        dd 1118, 632, 1, 1, 0xFF464646
        dd 1119, 632, 7, 1, 0xFF325A28
        dd 1126, 632, 1, 1, 0xFFA0A0A0
        dd 1127, 632, 2, 1, 0xFF325A28
        dd 1129, 632, 1, 1, 0xFF26411E
        dd 1117, 633, 1, 1, 0xFF26411E
        dd 1118, 633, 1, 1, 0xFF464646
        dd 1119, 633, 7, 1, 0xFF325A28
        dd 1126, 633, 1, 1, 0xFFA0A0A0
        dd 1127, 633, 2, 1, 0xFF325A28
        dd 1129, 633, 1, 1, 0xFF26411E
        dd 1116, 634, 1, 1, 0xFF141414
        dd 1117, 634, 1, 1, 0xFF26411E
        dd 1118, 634, 1, 1, 0xFF464646
        dd 1119, 634, 10, 1, 0xFF325A28
        dd 1129, 634, 1, 1, 0xFF26411E
        dd 1130, 634, 1, 1, 0xFF141414
        dd 1117, 635, 13, 1, 0xFF26411E
        dd 181, 300, 1, 1, 0xFF141414
        dd 204, 300, 1, 1, 0xFF141414
        dd 180, 301, 26, 1, 0xFF26411E
        dd 180, 302, 1, 1, 0xFF26411E
        dd 181, 302, 11, 1, 0xFF325A28
        dd 192, 302, 1, 1, 0xFF26411E
        dd 193, 302, 12, 1, 0xFF325A28
        dd 205, 302, 1, 1, 0xFF26411E
        dd 180, 303, 1, 1, 0xFF26411E
        dd 181, 303, 11, 1, 0xFF325A28
        dd 192, 303, 1, 1, 0xFF26411E
        dd 193, 303, 4, 1, 0xFF325A28
        dd 197, 303, 2, 1, 0xFF284682
        dd 199, 303, 6, 1, 0xFF325A28
        dd 205, 303, 1, 1, 0xFF26411E
        dd 180, 304, 1, 1, 0xFF26411E
        dd 181, 304, 2, 1, 0xFF325A28
        dd 183, 304, 3, 1, 0xFFA0A0A0
        dd 186, 304, 6, 1, 0xFF325A28
        dd 192, 304, 1, 1, 0xFF26411E
        dd 193, 304, 5, 1, 0xFF325A28
        dd 198, 304, 1, 1, 0xFF284682
        dd 199, 304, 2, 1, 0xFF325A28
        dd 201, 304, 3, 1, 0xFFA0A0A0
        dd 204, 304, 1, 1, 0xFF325A28
        dd 205, 304, 1, 1, 0xFF26411E
        dd 180, 305, 1, 1, 0xFF26411E
        dd 181, 305, 11, 1, 0xFF325A28
        dd 192, 305, 1, 1, 0xFF26411E
        dd 193, 305, 12, 1, 0xFF325A28
        dd 205, 305, 1, 1, 0xFF26411E
        dd 180, 306, 1, 1, 0xFF26411E
        dd 181, 306, 11, 1, 0xFF325A28
        dd 192, 306, 1, 1, 0xFF26411E
        dd 193, 306, 12, 1, 0xFF325A28
        dd 205, 306, 1, 1, 0xFF26411E
        dd 180, 307, 1, 1, 0xFF26411E
        dd 181, 307, 5, 1, 0xFF325A28
        dd 186, 307, 1, 1, 0xFF284682
        dd 187, 307, 5, 1, 0xFF325A28
        dd 192, 307, 1, 1, 0xFF26411E
        dd 193, 307, 12, 1, 0xFF325A28
        dd 205, 307, 1, 1, 0xFF26411E
        dd 180, 308, 1, 1, 0xFF26411E
        dd 181, 308, 11, 1, 0xFF325A28
        dd 192, 308, 1, 1, 0xFF26411E
        dd 193, 308, 12, 1, 0xFF325A28
        dd 205, 308, 1, 1, 0xFF26411E
        dd 180, 309, 1, 1, 0xFF26411E
        dd 181, 309, 11, 1, 0xFF325A28
        dd 192, 309, 1, 1, 0xFF26411E
        dd 193, 309, 12, 1, 0xFF325A28
        dd 205, 309, 1, 1, 0xFF26411E
        dd 180, 310, 1, 1, 0xFF26411E
        dd 181, 310, 11, 1, 0xFF325A28
        dd 192, 310, 1, 1, 0xFF26411E
        dd 193, 310, 12, 1, 0xFF325A28
        dd 205, 310, 1, 1, 0xFF26411E
        dd 180, 311, 1, 1, 0xFF26411E
        dd 181, 311, 11, 1, 0xFF325A28
        dd 192, 311, 1, 1, 0xFF26411E
        dd 193, 311, 12, 1, 0xFF325A28
        dd 205, 311, 1, 1, 0xFF26411E
        dd 180, 312, 1, 1, 0xFF26411E
        dd 181, 312, 24, 1, 0xFF464646
        dd 205, 312, 1, 1, 0xFF26411E
        dd 180, 313, 26, 1, 0xFF26411E
        dd 181, 314, 1, 1, 0xFF141414
        dd 204, 314, 1, 1, 0xFF141414
        dd 882, 150, 13, 1, 0xFF26411E
        dd 881, 151, 1, 1, 0xFF141414
        dd 882, 151, 1, 1, 0xFF26411E
        dd 883, 151, 1, 1, 0xFF464646
        dd 884, 151, 10, 1, 0xFF325A28
        dd 894, 151, 1, 1, 0xFF26411E
        dd 895, 151, 1, 1, 0xFF141414
        dd 882, 152, 1, 1, 0xFF26411E
        dd 883, 152, 1, 1, 0xFF464646
        dd 884, 152, 10, 1, 0xFF325A28
        dd 894, 152, 1, 1, 0xFF26411E
        dd 882, 153, 1, 1, 0xFF26411E
        dd 883, 153, 1, 1, 0xFF464646
        dd 884, 153, 7, 1, 0xFF325A28
        dd 891, 153, 1, 1, 0xFFA0A0A0
        dd 892, 153, 2, 1, 0xFF325A28
        dd 894, 153, 1, 1, 0xFF26411E
        dd 882, 154, 1, 1, 0xFF26411E
        dd 883, 154, 1, 1, 0xFF464646
        dd 884, 154, 7, 1, 0xFF325A28
        dd 891, 154, 1, 1, 0xFFA0A0A0
        dd 892, 154, 2, 1, 0xFF325A28
        dd 894, 154, 1, 1, 0xFF26411E
        dd 882, 155, 1, 1, 0xFF26411E
        dd 883, 155, 1, 1, 0xFF464646
        dd 884, 155, 7, 1, 0xFF325A28
        dd 891, 155, 1, 1, 0xFFA0A0A0
        dd 892, 155, 2, 1, 0xFF325A28
        dd 894, 155, 1, 1, 0xFF26411E
        dd 882, 156, 1, 1, 0xFF26411E
        dd 883, 156, 1, 1, 0xFF464646
        dd 884, 156, 4, 1, 0xFF325A28
        dd 888, 156, 1, 1, 0xFF284682
        dd 889, 156, 5, 1, 0xFF325A28
        dd 894, 156, 1, 1, 0xFF26411E
        dd 882, 157, 1, 1, 0xFF26411E
        dd 883, 157, 1, 1, 0xFF464646
        dd 884, 157, 10, 1, 0xFF325A28
        dd 894, 157, 1, 1, 0xFF26411E
        dd 882, 158, 1, 1, 0xFF26411E
        dd 883, 158, 1, 1, 0xFF464646
        dd 884, 158, 10, 1, 0xFF325A28
        dd 894, 158, 1, 1, 0xFF26411E
        dd 882, 159, 1, 1, 0xFF26411E
        dd 883, 159, 1, 1, 0xFF464646
        dd 884, 159, 10, 1, 0xFF325A28
        dd 894, 159, 1, 1, 0xFF26411E
        dd 882, 160, 1, 1, 0xFF26411E
        dd 883, 160, 1, 1, 0xFF464646
        dd 884, 160, 10, 1, 0xFF325A28
        dd 894, 160, 1, 1, 0xFF26411E
        dd 882, 161, 1, 1, 0xFF26411E
        dd 883, 161, 1, 1, 0xFF464646
        dd 884, 161, 10, 1, 0xFF325A28
        dd 894, 161, 1, 1, 0xFF26411E
        dd 882, 162, 1, 1, 0xFF26411E
        dd 883, 162, 1, 1, 0xFF464646
        dd 884, 162, 11, 1, 0xFF26411E
        dd 882, 163, 1, 1, 0xFF26411E
        dd 883, 163, 1, 1, 0xFF464646
        dd 884, 163, 10, 1, 0xFF325A28
        dd 894, 163, 1, 1, 0xFF26411E
        dd 882, 164, 1, 1, 0xFF26411E
        dd 883, 164, 1, 1, 0xFF464646
        dd 884, 164, 10, 1, 0xFF325A28
        dd 894, 164, 1, 1, 0xFF26411E
        dd 882, 165, 1, 1, 0xFF26411E
        dd 883, 165, 1, 1, 0xFF464646
        dd 884, 165, 10, 1, 0xFF325A28
        dd 894, 165, 1, 1, 0xFF26411E
        dd 882, 166, 1, 1, 0xFF26411E
        dd 883, 166, 1, 1, 0xFF464646
        dd 884, 166, 10, 1, 0xFF325A28
        dd 894, 166, 1, 1, 0xFF26411E
        dd 882, 167, 1, 1, 0xFF26411E
        dd 883, 167, 1, 1, 0xFF464646
        dd 884, 167, 8, 1, 0xFF325A28
        dd 892, 167, 1, 1, 0xFF284682
        dd 893, 167, 1, 1, 0xFF325A28
        dd 894, 167, 1, 1, 0xFF26411E
        dd 882, 168, 1, 1, 0xFF26411E
        dd 883, 168, 1, 1, 0xFF464646
        dd 884, 168, 7, 1, 0xFF325A28
        dd 891, 168, 2, 1, 0xFF284682
        dd 893, 168, 1, 1, 0xFF325A28
        dd 894, 168, 1, 1, 0xFF26411E
        dd 882, 169, 1, 1, 0xFF26411E
        dd 883, 169, 1, 1, 0xFF464646
        dd 884, 169, 10, 1, 0xFF325A28
        dd 894, 169, 1, 1, 0xFF26411E
        dd 882, 170, 1, 1, 0xFF26411E
        dd 883, 170, 1, 1, 0xFF464646
        dd 884, 170, 10, 1, 0xFF325A28
        dd 894, 170, 1, 1, 0xFF26411E
        dd 882, 171, 1, 1, 0xFF26411E
        dd 883, 171, 1, 1, 0xFF464646
        dd 884, 171, 7, 1, 0xFF325A28
        dd 891, 171, 1, 1, 0xFFA0A0A0
        dd 892, 171, 2, 1, 0xFF325A28
        dd 894, 171, 1, 1, 0xFF26411E
        dd 882, 172, 1, 1, 0xFF26411E
        dd 883, 172, 1, 1, 0xFF464646
        dd 884, 172, 7, 1, 0xFF325A28
        dd 891, 172, 1, 1, 0xFFA0A0A0
        dd 892, 172, 2, 1, 0xFF325A28
        dd 894, 172, 1, 1, 0xFF26411E
        dd 882, 173, 1, 1, 0xFF26411E
        dd 883, 173, 1, 1, 0xFF464646
        dd 884, 173, 7, 1, 0xFF325A28
        dd 891, 173, 1, 1, 0xFFA0A0A0
        dd 892, 173, 2, 1, 0xFF325A28
        dd 894, 173, 1, 1, 0xFF26411E
        dd 881, 174, 1, 1, 0xFF141414
        dd 882, 174, 1, 1, 0xFF26411E
        dd 883, 174, 1, 1, 0xFF464646
        dd 884, 174, 10, 1, 0xFF325A28
        dd 894, 174, 1, 1, 0xFF26411E
        dd 895, 174, 1, 1, 0xFF141414
        dd 882, 175, 13, 1, 0xFF26411E
        dd 390, 195, 480, 4, 0xFFA09B96
        dd 390, 197, 1, 2, 0xFF69645F
        dd 392, 195, 1, 2, 0xFF69645F
        dd 394, 197, 1, 2, 0xFF69645F
        dd 396, 195, 1, 2, 0xFF69645F
        dd 398, 197, 1, 2, 0xFF69645F
        dd 400, 195, 1, 2, 0xFF69645F
        dd 402, 197, 1, 2, 0xFF69645F
        dd 404, 195, 1, 2, 0xFF69645F
        dd 406, 197, 1, 2, 0xFF69645F
        dd 408, 195, 1, 2, 0xFF69645F
        dd 410, 197, 1, 2, 0xFF69645F
        dd 412, 195, 1, 2, 0xFF69645F
        dd 414, 197, 1, 2, 0xFF69645F
        dd 416, 195, 1, 2, 0xFF69645F
        dd 418, 197, 1, 2, 0xFF69645F
        dd 420, 195, 1, 2, 0xFF69645F
        dd 422, 197, 1, 2, 0xFF69645F
        dd 424, 195, 1, 2, 0xFF69645F
        dd 426, 197, 1, 2, 0xFF69645F
        dd 428, 195, 1, 2, 0xFF69645F
        dd 430, 197, 1, 2, 0xFF69645F
        dd 432, 195, 1, 2, 0xFF69645F
        dd 434, 197, 1, 2, 0xFF69645F
        dd 436, 195, 1, 2, 0xFF69645F
        dd 438, 197, 1, 2, 0xFF69645F
        dd 440, 195, 1, 2, 0xFF69645F
        dd 442, 197, 1, 2, 0xFF69645F
        dd 444, 195, 1, 2, 0xFF69645F
        dd 446, 197, 1, 2, 0xFF69645F
        dd 448, 195, 1, 2, 0xFF69645F
        dd 450, 197, 1, 2, 0xFF69645F
        dd 452, 195, 1, 2, 0xFF69645F
        dd 454, 197, 1, 2, 0xFF69645F
        dd 456, 195, 1, 2, 0xFF69645F
        dd 458, 197, 1, 2, 0xFF69645F
        dd 460, 195, 1, 2, 0xFF69645F
        dd 462, 197, 1, 2, 0xFF69645F
        dd 464, 195, 1, 2, 0xFF69645F
        dd 466, 197, 1, 2, 0xFF69645F
        dd 468, 195, 1, 2, 0xFF69645F
        dd 470, 197, 1, 2, 0xFF69645F
        dd 472, 195, 1, 2, 0xFF69645F
        dd 474, 197, 1, 2, 0xFF69645F
        dd 476, 195, 1, 2, 0xFF69645F
        dd 478, 197, 1, 2, 0xFF69645F
        dd 480, 195, 1, 2, 0xFF69645F
        dd 482, 197, 1, 2, 0xFF69645F
        dd 484, 195, 1, 2, 0xFF69645F
        dd 486, 197, 1, 2, 0xFF69645F
        dd 488, 195, 1, 2, 0xFF69645F
        dd 490, 197, 1, 2, 0xFF69645F
        dd 492, 195, 1, 2, 0xFF69645F
        dd 494, 197, 1, 2, 0xFF69645F
        dd 496, 195, 1, 2, 0xFF69645F
        dd 498, 197, 1, 2, 0xFF69645F
        dd 500, 195, 1, 2, 0xFF69645F
        dd 502, 197, 1, 2, 0xFF69645F
        dd 504, 195, 1, 2, 0xFF69645F
        dd 506, 197, 1, 2, 0xFF69645F
        dd 508, 195, 1, 2, 0xFF69645F
        dd 510, 197, 1, 2, 0xFF69645F
        dd 512, 195, 1, 2, 0xFF69645F
        dd 514, 197, 1, 2, 0xFF69645F
        dd 516, 195, 1, 2, 0xFF69645F
        dd 518, 197, 1, 2, 0xFF69645F
        dd 520, 195, 1, 2, 0xFF69645F
        dd 522, 197, 1, 2, 0xFF69645F
        dd 524, 195, 1, 2, 0xFF69645F
        dd 526, 197, 1, 2, 0xFF69645F
        dd 528, 195, 1, 2, 0xFF69645F
        dd 530, 197, 1, 2, 0xFF69645F
        dd 532, 195, 1, 2, 0xFF69645F
        dd 534, 197, 1, 2, 0xFF69645F
        dd 536, 195, 1, 2, 0xFF69645F
        dd 538, 197, 1, 2, 0xFF69645F
        dd 540, 195, 1, 2, 0xFF69645F
        dd 542, 197, 1, 2, 0xFF69645F
        dd 544, 195, 1, 2, 0xFF69645F
        dd 546, 197, 1, 2, 0xFF69645F
        dd 548, 195, 1, 2, 0xFF69645F
        dd 550, 197, 1, 2, 0xFF69645F
        dd 552, 195, 1, 2, 0xFF69645F
        dd 554, 197, 1, 2, 0xFF69645F
        dd 556, 195, 1, 2, 0xFF69645F
        dd 558, 197, 1, 2, 0xFF69645F
        dd 560, 195, 1, 2, 0xFF69645F
        dd 562, 197, 1, 2, 0xFF69645F
        dd 564, 195, 1, 2, 0xFF69645F
        dd 566, 197, 1, 2, 0xFF69645F
        dd 568, 195, 1, 2, 0xFF69645F
        dd 570, 197, 1, 2, 0xFF69645F
        dd 572, 195, 1, 2, 0xFF69645F
        dd 574, 197, 1, 2, 0xFF69645F
        dd 576, 195, 1, 2, 0xFF69645F
        dd 578, 197, 1, 2, 0xFF69645F
        dd 580, 195, 1, 2, 0xFF69645F
        dd 582, 197, 1, 2, 0xFF69645F
        dd 584, 195, 1, 2, 0xFF69645F
        dd 586, 197, 1, 2, 0xFF69645F
        dd 588, 195, 1, 2, 0xFF69645F
        dd 590, 197, 1, 2, 0xFF69645F
        dd 592, 195, 1, 2, 0xFF69645F
        dd 594, 197, 1, 2, 0xFF69645F
        dd 596, 195, 1, 2, 0xFF69645F
        dd 598, 197, 1, 2, 0xFF69645F
        dd 600, 195, 1, 2, 0xFF69645F
        dd 602, 197, 1, 2, 0xFF69645F
        dd 604, 195, 1, 2, 0xFF69645F
        dd 606, 197, 1, 2, 0xFF69645F
        dd 608, 195, 1, 2, 0xFF69645F
        dd 610, 197, 1, 2, 0xFF69645F
        dd 612, 195, 1, 2, 0xFF69645F
        dd 614, 197, 1, 2, 0xFF69645F
        dd 616, 195, 1, 2, 0xFF69645F
        dd 618, 197, 1, 2, 0xFF69645F
        dd 620, 195, 1, 2, 0xFF69645F
        dd 622, 197, 1, 2, 0xFF69645F
        dd 624, 195, 1, 2, 0xFF69645F
        dd 626, 197, 1, 2, 0xFF69645F
        dd 628, 195, 1, 2, 0xFF69645F
        dd 630, 197, 1, 2, 0xFF69645F
        dd 632, 195, 1, 2, 0xFF69645F
        dd 634, 197, 1, 2, 0xFF69645F
        dd 636, 195, 1, 2, 0xFF69645F
        dd 638, 197, 1, 2, 0xFF69645F
        dd 640, 195, 1, 2, 0xFF69645F
        dd 642, 197, 1, 2, 0xFF69645F
        dd 644, 195, 1, 2, 0xFF69645F
        dd 646, 197, 1, 2, 0xFF69645F
        dd 648, 195, 1, 2, 0xFF69645F
        dd 650, 197, 1, 2, 0xFF69645F
        dd 652, 195, 1, 2, 0xFF69645F
        dd 654, 197, 1, 2, 0xFF69645F
        dd 656, 195, 1, 2, 0xFF69645F
        dd 658, 197, 1, 2, 0xFF69645F
        dd 660, 195, 1, 2, 0xFF69645F
        dd 662, 197, 1, 2, 0xFF69645F
        dd 664, 195, 1, 2, 0xFF69645F
        dd 666, 197, 1, 2, 0xFF69645F
        dd 668, 195, 1, 2, 0xFF69645F
        dd 670, 197, 1, 2, 0xFF69645F
        dd 672, 195, 1, 2, 0xFF69645F
        dd 674, 197, 1, 2, 0xFF69645F
        dd 676, 195, 1, 2, 0xFF69645F
        dd 678, 197, 1, 2, 0xFF69645F
        dd 680, 195, 1, 2, 0xFF69645F
        dd 682, 197, 1, 2, 0xFF69645F
        dd 684, 195, 1, 2, 0xFF69645F
        dd 686, 197, 1, 2, 0xFF69645F
        dd 688, 195, 1, 2, 0xFF69645F
        dd 690, 197, 1, 2, 0xFF69645F
        dd 692, 195, 1, 2, 0xFF69645F
        dd 694, 197, 1, 2, 0xFF69645F
        dd 696, 195, 1, 2, 0xFF69645F
        dd 698, 197, 1, 2, 0xFF69645F
        dd 700, 195, 1, 2, 0xFF69645F
        dd 702, 197, 1, 2, 0xFF69645F
        dd 704, 195, 1, 2, 0xFF69645F
        dd 706, 197, 1, 2, 0xFF69645F
        dd 708, 195, 1, 2, 0xFF69645F
        dd 710, 197, 1, 2, 0xFF69645F
        dd 712, 195, 1, 2, 0xFF69645F
        dd 714, 197, 1, 2, 0xFF69645F
        dd 716, 195, 1, 2, 0xFF69645F
        dd 718, 197, 1, 2, 0xFF69645F
        dd 720, 195, 1, 2, 0xFF69645F
        dd 722, 197, 1, 2, 0xFF69645F
        dd 724, 195, 1, 2, 0xFF69645F
        dd 726, 197, 1, 2, 0xFF69645F
        dd 728, 195, 1, 2, 0xFF69645F
        dd 730, 197, 1, 2, 0xFF69645F
        dd 732, 195, 1, 2, 0xFF69645F
        dd 734, 197, 1, 2, 0xFF69645F
        dd 736, 195, 1, 2, 0xFF69645F
        dd 738, 197, 1, 2, 0xFF69645F
        dd 740, 195, 1, 2, 0xFF69645F
        dd 742, 197, 1, 2, 0xFF69645F
        dd 744, 195, 1, 2, 0xFF69645F
        dd 746, 197, 1, 2, 0xFF69645F
        dd 748, 195, 1, 2, 0xFF69645F
        dd 750, 197, 1, 2, 0xFF69645F
        dd 752, 195, 1, 2, 0xFF69645F
        dd 754, 197, 1, 2, 0xFF69645F
        dd 756, 195, 1, 2, 0xFF69645F
        dd 758, 197, 1, 2, 0xFF69645F
        dd 760, 195, 1, 2, 0xFF69645F
        dd 762, 197, 1, 2, 0xFF69645F
        dd 764, 195, 1, 2, 0xFF69645F
        dd 766, 197, 1, 2, 0xFF69645F
        dd 768, 195, 1, 2, 0xFF69645F
        dd 770, 197, 1, 2, 0xFF69645F
        dd 772, 195, 1, 2, 0xFF69645F
        dd 774, 197, 1, 2, 0xFF69645F
        dd 776, 195, 1, 2, 0xFF69645F
        dd 778, 197, 1, 2, 0xFF69645F
        dd 780, 195, 1, 2, 0xFF69645F
        dd 782, 197, 1, 2, 0xFF69645F
        dd 784, 195, 1, 2, 0xFF69645F
        dd 786, 197, 1, 2, 0xFF69645F
        dd 788, 195, 1, 2, 0xFF69645F
        dd 790, 197, 1, 2, 0xFF69645F
        dd 792, 195, 1, 2, 0xFF69645F
        dd 794, 197, 1, 2, 0xFF69645F
        dd 796, 195, 1, 2, 0xFF69645F
        dd 798, 197, 1, 2, 0xFF69645F
        dd 800, 195, 1, 2, 0xFF69645F
        dd 802, 197, 1, 2, 0xFF69645F
        dd 804, 195, 1, 2, 0xFF69645F
        dd 806, 197, 1, 2, 0xFF69645F
        dd 808, 195, 1, 2, 0xFF69645F
        dd 810, 197, 1, 2, 0xFF69645F
        dd 812, 195, 1, 2, 0xFF69645F
        dd 814, 197, 1, 2, 0xFF69645F
        dd 816, 195, 1, 2, 0xFF69645F
        dd 818, 197, 1, 2, 0xFF69645F
        dd 820, 195, 1, 2, 0xFF69645F
        dd 822, 197, 1, 2, 0xFF69645F
        dd 824, 195, 1, 2, 0xFF69645F
        dd 826, 197, 1, 2, 0xFF69645F
        dd 828, 195, 1, 2, 0xFF69645F
        dd 830, 197, 1, 2, 0xFF69645F
        dd 832, 195, 1, 2, 0xFF69645F
        dd 834, 197, 1, 2, 0xFF69645F
        dd 836, 195, 1, 2, 0xFF69645F
        dd 838, 197, 1, 2, 0xFF69645F
        dd 840, 195, 1, 2, 0xFF69645F
        dd 842, 197, 1, 2, 0xFF69645F
        dd 844, 195, 1, 2, 0xFF69645F
        dd 846, 197, 1, 2, 0xFF69645F
        dd 848, 195, 1, 2, 0xFF69645F
        dd 850, 197, 1, 2, 0xFF69645F
        dd 852, 195, 1, 2, 0xFF69645F
        dd 854, 197, 1, 2, 0xFF69645F
        dd 856, 195, 1, 2, 0xFF69645F
        dd 858, 197, 1, 2, 0xFF69645F
        dd 860, 195, 1, 2, 0xFF69645F
        dd 862, 197, 1, 2, 0xFF69645F
        dd 864, 195, 1, 2, 0xFF69645F
        dd 866, 197, 1, 2, 0xFF69645F
        dd 868, 195, 1, 2, 0xFF69645F
        dd 390, 194, 3, 6, 0xFF5A5550
        dd 414, 194, 3, 6, 0xFF5A5550
        dd 438, 194, 3, 6, 0xFF5A5550
        dd 462, 194, 3, 6, 0xFF5A5550
        dd 486, 194, 3, 6, 0xFF5A5550
        dd 510, 194, 3, 6, 0xFF5A5550
        dd 534, 194, 3, 6, 0xFF5A5550
        dd 558, 194, 3, 6, 0xFF5A5550
        dd 582, 194, 3, 6, 0xFF5A5550
        dd 606, 194, 3, 6, 0xFF5A5550
        dd 630, 194, 3, 6, 0xFF5A5550
        dd 654, 194, 3, 6, 0xFF5A5550
        dd 678, 194, 3, 6, 0xFF5A5550
        dd 702, 194, 3, 6, 0xFF5A5550
        dd 726, 194, 3, 6, 0xFF5A5550
        dd 750, 194, 3, 6, 0xFF5A5550
        dd 774, 194, 3, 6, 0xFF5A5550
        dd 798, 194, 3, 6, 0xFF5A5550
        dd 822, 194, 3, 6, 0xFF5A5550
        dd 846, 194, 3, 6, 0xFF5A5550
        dd 390, 315, 4, 15, 0xFFA09B96
        dd 392, 315, 2, 1, 0xFF69645F
        dd 390, 317, 2, 1, 0xFF69645F
        dd 392, 319, 2, 1, 0xFF69645F
        dd 390, 321, 2, 1, 0xFF69645F
        dd 392, 323, 2, 1, 0xFF69645F
        dd 390, 325, 2, 1, 0xFF69645F
        dd 392, 327, 2, 1, 0xFF69645F
        dd 390, 329, 2, 1, 0xFF69645F
        dd 389, 315, 6, 3, 0xFF5A5550
        dd 866, 199, 4, 116, 0xFFA09B96
        dd 868, 199, 2, 1, 0xFF69645F
        dd 866, 201, 2, 1, 0xFF69645F
        dd 868, 203, 2, 1, 0xFF69645F
        dd 866, 205, 2, 1, 0xFF69645F
        dd 868, 207, 2, 1, 0xFF69645F
        dd 866, 209, 2, 1, 0xFF69645F
        dd 868, 211, 2, 1, 0xFF69645F
        dd 866, 213, 2, 1, 0xFF69645F
        dd 868, 215, 2, 1, 0xFF69645F
        dd 866, 217, 2, 1, 0xFF69645F
        dd 868, 219, 2, 1, 0xFF69645F
        dd 866, 221, 2, 1, 0xFF69645F
        dd 868, 223, 2, 1, 0xFF69645F
        dd 866, 225, 2, 1, 0xFF69645F
        dd 868, 227, 2, 1, 0xFF69645F
        dd 866, 229, 2, 1, 0xFF69645F
        dd 868, 231, 2, 1, 0xFF69645F
        dd 866, 233, 2, 1, 0xFF69645F
        dd 868, 235, 2, 1, 0xFF69645F
        dd 866, 237, 2, 1, 0xFF69645F
        dd 868, 239, 2, 1, 0xFF69645F
        dd 866, 241, 2, 1, 0xFF69645F
        dd 868, 243, 2, 1, 0xFF69645F
        dd 866, 245, 2, 1, 0xFF69645F
        dd 868, 247, 2, 1, 0xFF69645F
        dd 866, 249, 2, 1, 0xFF69645F
        dd 868, 251, 2, 1, 0xFF69645F
        dd 866, 253, 2, 1, 0xFF69645F
        dd 868, 255, 2, 1, 0xFF69645F
        dd 866, 257, 2, 1, 0xFF69645F
        dd 868, 259, 2, 1, 0xFF69645F
        dd 866, 261, 2, 1, 0xFF69645F
        dd 868, 263, 2, 1, 0xFF69645F
        dd 866, 265, 2, 1, 0xFF69645F
        dd 868, 267, 2, 1, 0xFF69645F
        dd 866, 269, 2, 1, 0xFF69645F
        dd 868, 271, 2, 1, 0xFF69645F
        dd 866, 273, 2, 1, 0xFF69645F
        dd 868, 275, 2, 1, 0xFF69645F
        dd 866, 277, 2, 1, 0xFF69645F
        dd 868, 279, 2, 1, 0xFF69645F
        dd 866, 281, 2, 1, 0xFF69645F
        dd 868, 283, 2, 1, 0xFF69645F
        dd 866, 285, 2, 1, 0xFF69645F
        dd 868, 287, 2, 1, 0xFF69645F
        dd 866, 289, 2, 1, 0xFF69645F
        dd 868, 291, 2, 1, 0xFF69645F
        dd 866, 293, 2, 1, 0xFF69645F
        dd 868, 295, 2, 1, 0xFF69645F
        dd 866, 297, 2, 1, 0xFF69645F
        dd 868, 299, 2, 1, 0xFF69645F
        dd 866, 301, 2, 1, 0xFF69645F
        dd 868, 303, 2, 1, 0xFF69645F
        dd 866, 305, 2, 1, 0xFF69645F
        dd 868, 307, 2, 1, 0xFF69645F
        dd 866, 309, 2, 1, 0xFF69645F
        dd 868, 311, 2, 1, 0xFF69645F
        dd 866, 313, 2, 1, 0xFF69645F
        dd 865, 199, 6, 3, 0xFF5A5550
        dd 865, 223, 6, 3, 0xFF5A5550
        dd 865, 247, 6, 3, 0xFF5A5550
        dd 865, 271, 6, 3, 0xFF5A5550
        dd 865, 295, 6, 3, 0xFF5A5550
        dd 150, 160, 4, 40, 0xFF3C648C
        dd 149, 160, 6, 3, 0xFF284664
        dd 149, 176, 6, 3, 0xFF284664
        dd 149, 192, 6, 3, 0xFF284664
        dd 1120, 560, 4, 30, 0xFF3C648C
        dd 1119, 560, 6, 3, 0xFF284664
        dd 1119, 576, 6, 3, 0xFF284664
        dd 16, 8, 6, 1, 0xFF1E461E
        dd 14, 9, 2, 1, 0xFF1E461E
        dd 16, 9, 6, 1, 0xFF32783C
        dd 22, 9, 2, 1, 0xFF1E461E
        dd 13, 10, 1, 1, 0xFF1E461E
        dd 14, 10, 1, 1, 0xFF32783C
        dd 15, 10, 2, 1, 0xFF46A064
        dd 17, 10, 7, 1, 0xFF32783C
        dd 24, 10, 1, 1, 0xFF1E461E
        dd 12, 11, 1, 1, 0xFF1E461E
        dd 13, 11, 1, 1, 0xFF32783C
        dd 14, 11, 4, 1, 0xFF46A064
        dd 18, 11, 3, 1, 0xFF32783C
        dd 21, 11, 1, 1, 0xFF285A28
        dd 22, 11, 3, 1, 0xFF32783C
        dd 25, 11, 1, 1, 0xFF1E461E
        dd 11, 12, 1, 1, 0xFF1E461E
        dd 12, 12, 2, 1, 0xFF32783C
        dd 14, 12, 3, 1, 0xFF46A064
        dd 17, 12, 9, 1, 0xFF32783C
        dd 26, 12, 1, 1, 0xFF1E461E
        dd 10, 13, 1, 1, 0xFF1E461E
        dd 11, 13, 3, 1, 0xFF32783C
        dd 14, 13, 2, 1, 0xFF46A064
        dd 16, 13, 4, 1, 0xFF32783C
        dd 20, 13, 1, 1, 0xFF285A28
        dd 21, 13, 6, 1, 0xFF32783C
        dd 27, 13, 1, 1, 0xFF1E461E
        dd 10, 14, 1, 1, 0xFF1E461E
        dd 11, 14, 12, 1, 0xFF32783C
        dd 23, 14, 2, 1, 0xFF46A064
        dd 25, 14, 2, 1, 0xFF32783C
        dd 27, 14, 1, 1, 0xFF1E461E
        dd 9, 15, 1, 1, 0xFF1E461E
        dd 10, 15, 1, 1, 0xFF32783C
        dd 11, 15, 1, 1, 0xFF285A28
        dd 12, 15, 6, 1, 0xFF32783C
        dd 18, 15, 2, 1, 0xFF46A064
        dd 20, 15, 2, 1, 0xFF32783C
        dd 22, 15, 3, 1, 0xFF46A064
        dd 25, 15, 3, 1, 0xFF32783C
        dd 28, 15, 1, 1, 0xFF1E461E
        dd 9, 16, 1, 1, 0xFF1E461E
        dd 10, 16, 7, 1, 0xFF32783C
        dd 17, 16, 3, 1, 0xFF46A064
        dd 20, 16, 3, 1, 0xFF32783C
        dd 23, 16, 1, 1, 0xFF46A064
        dd 24, 16, 3, 1, 0xFF32783C
        dd 27, 16, 1, 1, 0xFF285A28
        dd 28, 16, 1, 1, 0xFF1E461E
        dd 8, 17, 1, 1, 0xFF1E461E
        dd 9, 17, 4, 1, 0xFF32783C
        dd 13, 17, 1, 1, 0xFF46A064
        dd 14, 17, 4, 1, 0xFF32783C
        dd 18, 17, 2, 1, 0xFF46A064
        dd 20, 17, 9, 1, 0xFF32783C
        dd 29, 17, 1, 1, 0xFF1E461E
        dd 8, 18, 1, 1, 0xFF1E461E
        dd 9, 18, 3, 1, 0xFF32783C
        dd 12, 18, 3, 1, 0xFF46A064
        dd 15, 18, 8, 1, 0xFF32783C
        dd 23, 18, 1, 1, 0xFF285A28
        dd 24, 18, 5, 1, 0xFF32783C
        dd 29, 18, 1, 1, 0xFF1E461E
        dd 8, 19, 1, 1, 0xFF1E461E
        dd 9, 19, 4, 1, 0xFF32783C
        dd 13, 19, 1, 1, 0xFF46A064
        dd 14, 19, 15, 1, 0xFF32783C
        dd 29, 19, 1, 1, 0xFF1E461E
        dd 8, 20, 1, 1, 0xFF1E461E
        dd 9, 20, 8, 1, 0xFF32783C
        dd 17, 20, 1, 1, 0xFF285A28
        dd 18, 20, 4, 1, 0xFF32783C
        dd 22, 20, 3, 1, 0xFF46A064
        dd 25, 20, 3, 1, 0xFF32783C
        dd 28, 20, 1, 1, 0xFF285A28
        dd 29, 20, 1, 1, 0xFF1E461E
        dd 8, 21, 1, 1, 0xFF1E461E
        dd 9, 21, 2, 1, 0xFF32783C
        dd 11, 21, 1, 1, 0xFF285A28
        dd 12, 21, 11, 1, 0xFF32783C
        dd 23, 21, 1, 1, 0xFF46A064
        dd 24, 21, 5, 1, 0xFF32783C
        dd 29, 21, 1, 1, 0xFF1E461E
        dd 9, 22, 1, 1, 0xFF1E461E
        dd 10, 22, 5, 1, 0xFF32783C
        dd 15, 22, 2, 1, 0xFF46A064
        dd 17, 22, 11, 1, 0xFF32783C
        dd 28, 22, 1, 1, 0xFF1E461E
        dd 9, 23, 1, 1, 0xFF1E461E
        dd 10, 23, 4, 1, 0xFF32783C
        dd 14, 23, 3, 1, 0xFF46A064
        dd 17, 23, 4, 1, 0xFF32783C
        dd 21, 23, 1, 1, 0xFF285A28
        dd 22, 23, 5, 1, 0xFF32783C
        dd 27, 23, 1, 1, 0xFF285A28
        dd 28, 23, 1, 1, 0xFF1E461E
        dd 10, 24, 1, 1, 0xFF1E461E
        dd 11, 24, 4, 1, 0xFF32783C
        dd 15, 24, 1, 1, 0xFF46A064
        dd 16, 24, 10, 1, 0xFF32783C
        dd 26, 24, 1, 1, 0xFF285A28
        dd 27, 24, 1, 1, 0xFF1E461E
        dd 10, 25, 1, 1, 0xFF1E461E
        dd 11, 25, 9, 1, 0xFF32783C
        dd 20, 25, 2, 1, 0xFF46A064
        dd 22, 25, 3, 1, 0xFF32783C
        dd 25, 25, 2, 1, 0xFF285A28
        dd 27, 25, 1, 1, 0xFF1E461E
        dd 11, 26, 1, 1, 0xFF1E461E
        dd 12, 26, 2, 1, 0xFF32783C
        dd 14, 26, 1, 1, 0xFF285A28
        dd 15, 26, 5, 1, 0xFF32783C
        dd 20, 26, 1, 1, 0xFF46A064
        dd 21, 26, 4, 1, 0xFF32783C
        dd 25, 26, 1, 1, 0xFF285A28
        dd 26, 26, 1, 1, 0xFF1E461E
        dd 12, 27, 1, 1, 0xFF1E461E
        dd 13, 27, 10, 1, 0xFF32783C
        dd 23, 27, 2, 1, 0xFF285A28
        dd 25, 27, 1, 1, 0xFF1E461E
        dd 13, 28, 2, 1, 0xFF1E461E
        dd 15, 28, 6, 1, 0xFF32783C
        dd 21, 28, 3, 1, 0xFF285A28
        dd 24, 28, 1, 1, 0xFF1E461E
        dd 15, 29, 8, 1, 0xFF1E461E
        dd 160, 5, 6, 1, 0xFF1E461E
        dd 158, 6, 2, 1, 0xFF1E461E
        dd 160, 6, 6, 1, 0xFF32783C
        dd 166, 6, 2, 1, 0xFF1E461E
        dd 157, 7, 1, 1, 0xFF1E461E
        dd 158, 7, 1, 1, 0xFF32783C
        dd 159, 7, 2, 1, 0xFF46A064
        dd 161, 7, 7, 1, 0xFF32783C
        dd 168, 7, 1, 1, 0xFF1E461E
        dd 156, 8, 1, 1, 0xFF1E461E
        dd 157, 8, 1, 1, 0xFF32783C
        dd 158, 8, 4, 1, 0xFF46A064
        dd 162, 8, 3, 1, 0xFF32783C
        dd 165, 8, 1, 1, 0xFF285A28
        dd 166, 8, 3, 1, 0xFF32783C
        dd 169, 8, 1, 1, 0xFF1E461E
        dd 155, 9, 1, 1, 0xFF1E461E
        dd 156, 9, 2, 1, 0xFF32783C
        dd 158, 9, 3, 1, 0xFF46A064
        dd 161, 9, 9, 1, 0xFF32783C
        dd 170, 9, 1, 1, 0xFF1E461E
        dd 154, 10, 1, 1, 0xFF1E461E
        dd 155, 10, 3, 1, 0xFF32783C
        dd 158, 10, 2, 1, 0xFF46A064
        dd 160, 10, 4, 1, 0xFF32783C
        dd 164, 10, 1, 1, 0xFF285A28
        dd 165, 10, 6, 1, 0xFF32783C
        dd 171, 10, 1, 1, 0xFF1E461E
        dd 154, 11, 1, 1, 0xFF1E461E
        dd 155, 11, 12, 1, 0xFF32783C
        dd 167, 11, 2, 1, 0xFF46A064
        dd 169, 11, 2, 1, 0xFF32783C
        dd 171, 11, 1, 1, 0xFF1E461E
        dd 153, 12, 1, 1, 0xFF1E461E
        dd 154, 12, 1, 1, 0xFF32783C
        dd 155, 12, 1, 1, 0xFF285A28
        dd 156, 12, 6, 1, 0xFF32783C
        dd 162, 12, 2, 1, 0xFF46A064
        dd 164, 12, 2, 1, 0xFF32783C
        dd 166, 12, 3, 1, 0xFF46A064
        dd 169, 12, 3, 1, 0xFF32783C
        dd 172, 12, 1, 1, 0xFF1E461E
        dd 153, 13, 1, 1, 0xFF1E461E
        dd 154, 13, 7, 1, 0xFF32783C
        dd 161, 13, 3, 1, 0xFF46A064
        dd 164, 13, 3, 1, 0xFF32783C
        dd 167, 13, 1, 1, 0xFF46A064
        dd 168, 13, 3, 1, 0xFF32783C
        dd 171, 13, 1, 1, 0xFF285A28
        dd 172, 13, 1, 1, 0xFF1E461E
        dd 152, 14, 1, 1, 0xFF1E461E
        dd 153, 14, 4, 1, 0xFF32783C
        dd 157, 14, 1, 1, 0xFF46A064
        dd 158, 14, 4, 1, 0xFF32783C
        dd 162, 14, 2, 1, 0xFF46A064
        dd 164, 14, 9, 1, 0xFF32783C
        dd 173, 14, 1, 1, 0xFF1E461E
        dd 152, 15, 1, 1, 0xFF1E461E
        dd 153, 15, 3, 1, 0xFF32783C
        dd 156, 15, 3, 1, 0xFF46A064
        dd 159, 15, 8, 1, 0xFF32783C
        dd 167, 15, 1, 1, 0xFF285A28
        dd 168, 15, 5, 1, 0xFF32783C
        dd 173, 15, 1, 1, 0xFF1E461E
        dd 152, 16, 1, 1, 0xFF1E461E
        dd 153, 16, 4, 1, 0xFF32783C
        dd 157, 16, 1, 1, 0xFF46A064
        dd 158, 16, 15, 1, 0xFF32783C
        dd 173, 16, 1, 1, 0xFF1E461E
        dd 152, 17, 1, 1, 0xFF1E461E
        dd 153, 17, 8, 1, 0xFF32783C
        dd 161, 17, 1, 1, 0xFF285A28
        dd 162, 17, 4, 1, 0xFF32783C
        dd 166, 17, 3, 1, 0xFF46A064
        dd 169, 17, 3, 1, 0xFF32783C
        dd 172, 17, 1, 1, 0xFF285A28
        dd 173, 17, 1, 1, 0xFF1E461E
        dd 152, 18, 1, 1, 0xFF1E461E
        dd 153, 18, 2, 1, 0xFF32783C
        dd 155, 18, 1, 1, 0xFF285A28
        dd 156, 18, 11, 1, 0xFF32783C
        dd 167, 18, 1, 1, 0xFF46A064
        dd 168, 18, 5, 1, 0xFF32783C
        dd 173, 18, 1, 1, 0xFF1E461E
        dd 153, 19, 1, 1, 0xFF1E461E
        dd 154, 19, 5, 1, 0xFF32783C
        dd 159, 19, 2, 1, 0xFF46A064
        dd 161, 19, 11, 1, 0xFF32783C
        dd 172, 19, 1, 1, 0xFF1E461E
        dd 153, 20, 1, 1, 0xFF1E461E
        dd 154, 20, 4, 1, 0xFF32783C
        dd 158, 20, 3, 1, 0xFF46A064
        dd 161, 20, 4, 1, 0xFF32783C
        dd 165, 20, 1, 1, 0xFF285A28
        dd 166, 20, 5, 1, 0xFF32783C
        dd 171, 20, 1, 1, 0xFF285A28
        dd 172, 20, 1, 1, 0xFF1E461E
        dd 154, 21, 1, 1, 0xFF1E461E
        dd 155, 21, 4, 1, 0xFF32783C
        dd 159, 21, 1, 1, 0xFF46A064
        dd 160, 21, 10, 1, 0xFF32783C
        dd 170, 21, 1, 1, 0xFF285A28
        dd 171, 21, 1, 1, 0xFF1E461E
        dd 154, 22, 1, 1, 0xFF1E461E
        dd 155, 22, 9, 1, 0xFF32783C
        dd 164, 22, 2, 1, 0xFF46A064
        dd 166, 22, 3, 1, 0xFF32783C
        dd 169, 22, 2, 1, 0xFF285A28
        dd 171, 22, 1, 1, 0xFF1E461E
        dd 155, 23, 1, 1, 0xFF1E461E
        dd 156, 23, 2, 1, 0xFF32783C
        dd 158, 23, 1, 1, 0xFF285A28
        dd 159, 23, 5, 1, 0xFF32783C
        dd 164, 23, 1, 1, 0xFF46A064
        dd 165, 23, 4, 1, 0xFF32783C
        dd 169, 23, 1, 1, 0xFF285A28
        dd 170, 23, 1, 1, 0xFF1E461E
        dd 156, 24, 1, 1, 0xFF1E461E
        dd 157, 24, 10, 1, 0xFF32783C
        dd 167, 24, 2, 1, 0xFF285A28
        dd 169, 24, 1, 1, 0xFF1E461E
        dd 157, 25, 2, 1, 0xFF1E461E
        dd 159, 25, 6, 1, 0xFF32783C
        dd 165, 25, 3, 1, 0xFF285A28
        dd 168, 25, 1, 1, 0xFF1E461E
        dd 159, 26, 8, 1, 0xFF1E461E
        dd 270, 5, 6, 1, 0xFF1E461E
        dd 268, 6, 2, 1, 0xFF1E461E
        dd 270, 6, 6, 1, 0xFF32783C
        dd 276, 6, 2, 1, 0xFF1E461E
        dd 267, 7, 1, 1, 0xFF1E461E
        dd 268, 7, 1, 1, 0xFF32783C
        dd 269, 7, 2, 1, 0xFF46A064
        dd 271, 7, 7, 1, 0xFF32783C
        dd 278, 7, 1, 1, 0xFF1E461E
        dd 266, 8, 1, 1, 0xFF1E461E
        dd 267, 8, 1, 1, 0xFF32783C
        dd 268, 8, 4, 1, 0xFF46A064
        dd 272, 8, 3, 1, 0xFF32783C
        dd 275, 8, 1, 1, 0xFF285A28
        dd 276, 8, 3, 1, 0xFF32783C
        dd 279, 8, 1, 1, 0xFF1E461E
        dd 265, 9, 1, 1, 0xFF1E461E
        dd 266, 9, 2, 1, 0xFF32783C
        dd 268, 9, 3, 1, 0xFF46A064
        dd 271, 9, 9, 1, 0xFF32783C
        dd 280, 9, 1, 1, 0xFF1E461E
        dd 264, 10, 1, 1, 0xFF1E461E
        dd 265, 10, 3, 1, 0xFF32783C
        dd 268, 10, 2, 1, 0xFF46A064
        dd 270, 10, 4, 1, 0xFF32783C
        dd 274, 10, 1, 1, 0xFF285A28
        dd 275, 10, 6, 1, 0xFF32783C
        dd 281, 10, 1, 1, 0xFF1E461E
        dd 264, 11, 1, 1, 0xFF1E461E
        dd 265, 11, 12, 1, 0xFF32783C
        dd 277, 11, 2, 1, 0xFF46A064
        dd 279, 11, 2, 1, 0xFF32783C
        dd 281, 11, 1, 1, 0xFF1E461E
        dd 263, 12, 1, 1, 0xFF1E461E
        dd 264, 12, 1, 1, 0xFF32783C
        dd 265, 12, 1, 1, 0xFF285A28
        dd 266, 12, 6, 1, 0xFF32783C
        dd 272, 12, 2, 1, 0xFF46A064
        dd 274, 12, 2, 1, 0xFF32783C
        dd 276, 12, 3, 1, 0xFF46A064
        dd 279, 12, 3, 1, 0xFF32783C
        dd 282, 12, 1, 1, 0xFF1E461E
        dd 263, 13, 1, 1, 0xFF1E461E
        dd 264, 13, 7, 1, 0xFF32783C
        dd 271, 13, 3, 1, 0xFF46A064
        dd 274, 13, 3, 1, 0xFF32783C
        dd 277, 13, 1, 1, 0xFF46A064
        dd 278, 13, 3, 1, 0xFF32783C
        dd 281, 13, 1, 1, 0xFF285A28
        dd 282, 13, 1, 1, 0xFF1E461E
        dd 262, 14, 1, 1, 0xFF1E461E
        dd 263, 14, 4, 1, 0xFF32783C
        dd 267, 14, 1, 1, 0xFF46A064
        dd 268, 14, 4, 1, 0xFF32783C
        dd 272, 14, 2, 1, 0xFF46A064
        dd 274, 14, 9, 1, 0xFF32783C
        dd 283, 14, 1, 1, 0xFF1E461E
        dd 262, 15, 1, 1, 0xFF1E461E
        dd 263, 15, 3, 1, 0xFF32783C
        dd 266, 15, 3, 1, 0xFF46A064
        dd 269, 15, 8, 1, 0xFF32783C
        dd 277, 15, 1, 1, 0xFF285A28
        dd 278, 15, 5, 1, 0xFF32783C
        dd 283, 15, 1, 1, 0xFF1E461E
        dd 262, 16, 1, 1, 0xFF1E461E
        dd 263, 16, 4, 1, 0xFF32783C
        dd 267, 16, 1, 1, 0xFF46A064
        dd 268, 16, 15, 1, 0xFF32783C
        dd 283, 16, 1, 1, 0xFF1E461E
        dd 262, 17, 1, 1, 0xFF1E461E
        dd 263, 17, 8, 1, 0xFF32783C
        dd 271, 17, 1, 1, 0xFF285A28
        dd 272, 17, 4, 1, 0xFF32783C
        dd 276, 17, 3, 1, 0xFF46A064
        dd 279, 17, 3, 1, 0xFF32783C
        dd 282, 17, 1, 1, 0xFF285A28
        dd 283, 17, 1, 1, 0xFF1E461E
        dd 262, 18, 1, 1, 0xFF1E461E
        dd 263, 18, 2, 1, 0xFF32783C
        dd 265, 18, 1, 1, 0xFF285A28
        dd 266, 18, 11, 1, 0xFF32783C
        dd 277, 18, 1, 1, 0xFF46A064
        dd 278, 18, 5, 1, 0xFF32783C
        dd 283, 18, 1, 1, 0xFF1E461E
        dd 263, 19, 1, 1, 0xFF1E461E
        dd 264, 19, 5, 1, 0xFF32783C
        dd 269, 19, 2, 1, 0xFF46A064
        dd 271, 19, 11, 1, 0xFF32783C
        dd 282, 19, 1, 1, 0xFF1E461E
        dd 263, 20, 1, 1, 0xFF1E461E
        dd 264, 20, 4, 1, 0xFF32783C
        dd 268, 20, 3, 1, 0xFF46A064
        dd 271, 20, 4, 1, 0xFF32783C
        dd 275, 20, 1, 1, 0xFF285A28
        dd 276, 20, 5, 1, 0xFF32783C
        dd 281, 20, 1, 1, 0xFF285A28
        dd 282, 20, 1, 1, 0xFF1E461E
        dd 264, 21, 1, 1, 0xFF1E461E
        dd 265, 21, 4, 1, 0xFF32783C
        dd 269, 21, 1, 1, 0xFF46A064
        dd 270, 21, 10, 1, 0xFF32783C
        dd 280, 21, 1, 1, 0xFF285A28
        dd 281, 21, 1, 1, 0xFF1E461E
        dd 264, 22, 1, 1, 0xFF1E461E
        dd 265, 22, 9, 1, 0xFF32783C
        dd 274, 22, 2, 1, 0xFF46A064
        dd 276, 22, 3, 1, 0xFF32783C
        dd 279, 22, 2, 1, 0xFF285A28
        dd 281, 22, 1, 1, 0xFF1E461E
        dd 265, 23, 1, 1, 0xFF1E461E
        dd 266, 23, 2, 1, 0xFF32783C
        dd 268, 23, 1, 1, 0xFF285A28
        dd 269, 23, 5, 1, 0xFF32783C
        dd 274, 23, 1, 1, 0xFF46A064
        dd 275, 23, 4, 1, 0xFF32783C
        dd 279, 23, 1, 1, 0xFF285A28
        dd 280, 23, 1, 1, 0xFF1E461E
        dd 266, 24, 1, 1, 0xFF1E461E
        dd 267, 24, 10, 1, 0xFF32783C
        dd 277, 24, 2, 1, 0xFF285A28
        dd 279, 24, 1, 1, 0xFF1E461E
        dd 267, 25, 2, 1, 0xFF1E461E
        dd 269, 25, 6, 1, 0xFF32783C
        dd 275, 25, 3, 1, 0xFF285A28
        dd 278, 25, 1, 1, 0xFF1E461E
        dd 269, 26, 8, 1, 0xFF1E461E
        dd 16, 165, 6, 1, 0xFF1E461E
        dd 14, 166, 2, 1, 0xFF1E461E
        dd 16, 166, 6, 1, 0xFF32783C
        dd 22, 166, 2, 1, 0xFF1E461E
        dd 13, 167, 1, 1, 0xFF1E461E
        dd 14, 167, 1, 1, 0xFF32783C
        dd 15, 167, 2, 1, 0xFF46A064
        dd 17, 167, 7, 1, 0xFF32783C
        dd 24, 167, 1, 1, 0xFF1E461E
        dd 12, 168, 1, 1, 0xFF1E461E
        dd 13, 168, 1, 1, 0xFF32783C
        dd 14, 168, 4, 1, 0xFF46A064
        dd 18, 168, 3, 1, 0xFF32783C
        dd 21, 168, 1, 1, 0xFF285A28
        dd 22, 168, 3, 1, 0xFF32783C
        dd 25, 168, 1, 1, 0xFF1E461E
        dd 11, 169, 1, 1, 0xFF1E461E
        dd 12, 169, 2, 1, 0xFF32783C
        dd 14, 169, 3, 1, 0xFF46A064
        dd 17, 169, 9, 1, 0xFF32783C
        dd 26, 169, 1, 1, 0xFF1E461E
        dd 10, 170, 1, 1, 0xFF1E461E
        dd 11, 170, 3, 1, 0xFF32783C
        dd 14, 170, 2, 1, 0xFF46A064
        dd 16, 170, 4, 1, 0xFF32783C
        dd 20, 170, 1, 1, 0xFF285A28
        dd 21, 170, 6, 1, 0xFF32783C
        dd 27, 170, 1, 1, 0xFF1E461E
        dd 10, 171, 1, 1, 0xFF1E461E
        dd 11, 171, 12, 1, 0xFF32783C
        dd 23, 171, 2, 1, 0xFF46A064
        dd 25, 171, 2, 1, 0xFF32783C
        dd 27, 171, 1, 1, 0xFF1E461E
        dd 9, 172, 1, 1, 0xFF1E461E
        dd 10, 172, 1, 1, 0xFF32783C
        dd 11, 172, 1, 1, 0xFF285A28
        dd 12, 172, 6, 1, 0xFF32783C
        dd 18, 172, 2, 1, 0xFF46A064
        dd 20, 172, 2, 1, 0xFF32783C
        dd 22, 172, 3, 1, 0xFF46A064
        dd 25, 172, 3, 1, 0xFF32783C
        dd 28, 172, 1, 1, 0xFF1E461E
        dd 9, 173, 1, 1, 0xFF1E461E
        dd 10, 173, 7, 1, 0xFF32783C
        dd 17, 173, 3, 1, 0xFF46A064
        dd 20, 173, 3, 1, 0xFF32783C
        dd 23, 173, 1, 1, 0xFF46A064
        dd 24, 173, 3, 1, 0xFF32783C
        dd 27, 173, 1, 1, 0xFF285A28
        dd 28, 173, 1, 1, 0xFF1E461E
        dd 8, 174, 1, 1, 0xFF1E461E
        dd 9, 174, 4, 1, 0xFF32783C
        dd 13, 174, 1, 1, 0xFF46A064
        dd 14, 174, 4, 1, 0xFF32783C
        dd 18, 174, 2, 1, 0xFF46A064
        dd 20, 174, 9, 1, 0xFF32783C
        dd 29, 174, 1, 1, 0xFF1E461E
        dd 8, 175, 1, 1, 0xFF1E461E
        dd 9, 175, 3, 1, 0xFF32783C
        dd 12, 175, 3, 1, 0xFF46A064
        dd 15, 175, 8, 1, 0xFF32783C
        dd 23, 175, 1, 1, 0xFF285A28
        dd 24, 175, 5, 1, 0xFF32783C
        dd 29, 175, 1, 1, 0xFF1E461E
        dd 8, 176, 1, 1, 0xFF1E461E
        dd 9, 176, 4, 1, 0xFF32783C
        dd 13, 176, 1, 1, 0xFF46A064
        dd 14, 176, 15, 1, 0xFF32783C
        dd 29, 176, 1, 1, 0xFF1E461E
        dd 8, 177, 1, 1, 0xFF1E461E
        dd 9, 177, 8, 1, 0xFF32783C
        dd 17, 177, 1, 1, 0xFF285A28
        dd 18, 177, 4, 1, 0xFF32783C
        dd 22, 177, 3, 1, 0xFF46A064
        dd 25, 177, 3, 1, 0xFF32783C
        dd 28, 177, 1, 1, 0xFF285A28
        dd 29, 177, 1, 1, 0xFF1E461E
        dd 8, 178, 1, 1, 0xFF1E461E
        dd 9, 178, 2, 1, 0xFF32783C
        dd 11, 178, 1, 1, 0xFF285A28
        dd 12, 178, 11, 1, 0xFF32783C
        dd 23, 178, 1, 1, 0xFF46A064
        dd 24, 178, 5, 1, 0xFF32783C
        dd 29, 178, 1, 1, 0xFF1E461E
        dd 9, 179, 1, 1, 0xFF1E461E
        dd 10, 179, 5, 1, 0xFF32783C
        dd 15, 179, 2, 1, 0xFF46A064
        dd 17, 179, 11, 1, 0xFF32783C
        dd 28, 179, 1, 1, 0xFF1E461E
        dd 9, 180, 1, 1, 0xFF1E461E
        dd 10, 180, 4, 1, 0xFF32783C
        dd 14, 180, 3, 1, 0xFF46A064
        dd 17, 180, 4, 1, 0xFF32783C
        dd 21, 180, 1, 1, 0xFF285A28
        dd 22, 180, 5, 1, 0xFF32783C
        dd 27, 180, 1, 1, 0xFF285A28
        dd 28, 180, 1, 1, 0xFF1E461E
        dd 10, 181, 1, 1, 0xFF1E461E
        dd 11, 181, 4, 1, 0xFF32783C
        dd 15, 181, 1, 1, 0xFF46A064
        dd 16, 181, 10, 1, 0xFF32783C
        dd 26, 181, 1, 1, 0xFF285A28
        dd 27, 181, 1, 1, 0xFF1E461E
        dd 10, 182, 1, 1, 0xFF1E461E
        dd 11, 182, 9, 1, 0xFF32783C
        dd 20, 182, 2, 1, 0xFF46A064
        dd 22, 182, 3, 1, 0xFF32783C
        dd 25, 182, 2, 1, 0xFF285A28
        dd 27, 182, 1, 1, 0xFF1E461E
        dd 11, 183, 1, 1, 0xFF1E461E
        dd 12, 183, 2, 1, 0xFF32783C
        dd 14, 183, 1, 1, 0xFF285A28
        dd 15, 183, 5, 1, 0xFF32783C
        dd 20, 183, 1, 1, 0xFF46A064
        dd 21, 183, 4, 1, 0xFF32783C
        dd 25, 183, 1, 1, 0xFF285A28
        dd 26, 183, 1, 1, 0xFF1E461E
        dd 12, 184, 1, 1, 0xFF1E461E
        dd 13, 184, 10, 1, 0xFF32783C
        dd 23, 184, 2, 1, 0xFF285A28
        dd 25, 184, 1, 1, 0xFF1E461E
        dd 13, 185, 2, 1, 0xFF1E461E
        dd 15, 185, 6, 1, 0xFF32783C
        dd 21, 185, 3, 1, 0xFF285A28
        dd 24, 185, 1, 1, 0xFF1E461E
        dd 15, 186, 8, 1, 0xFF1E461E
        dd 130, 168, 6, 1, 0xFF1E461E
        dd 128, 169, 2, 1, 0xFF1E461E
        dd 130, 169, 6, 1, 0xFF32783C
        dd 136, 169, 2, 1, 0xFF1E461E
        dd 127, 170, 1, 1, 0xFF1E461E
        dd 128, 170, 1, 1, 0xFF32783C
        dd 129, 170, 2, 1, 0xFF46A064
        dd 131, 170, 7, 1, 0xFF32783C
        dd 138, 170, 1, 1, 0xFF1E461E
        dd 126, 171, 1, 1, 0xFF1E461E
        dd 127, 171, 1, 1, 0xFF32783C
        dd 128, 171, 4, 1, 0xFF46A064
        dd 132, 171, 3, 1, 0xFF32783C
        dd 135, 171, 1, 1, 0xFF285A28
        dd 136, 171, 3, 1, 0xFF32783C
        dd 139, 171, 1, 1, 0xFF1E461E
        dd 125, 172, 1, 1, 0xFF1E461E
        dd 126, 172, 2, 1, 0xFF32783C
        dd 128, 172, 3, 1, 0xFF46A064
        dd 131, 172, 9, 1, 0xFF32783C
        dd 140, 172, 1, 1, 0xFF1E461E
        dd 124, 173, 1, 1, 0xFF1E461E
        dd 125, 173, 3, 1, 0xFF32783C
        dd 128, 173, 2, 1, 0xFF46A064
        dd 130, 173, 4, 1, 0xFF32783C
        dd 134, 173, 1, 1, 0xFF285A28
        dd 135, 173, 6, 1, 0xFF32783C
        dd 141, 173, 1, 1, 0xFF1E461E
        dd 124, 174, 1, 1, 0xFF1E461E
        dd 125, 174, 12, 1, 0xFF32783C
        dd 137, 174, 2, 1, 0xFF46A064
        dd 139, 174, 2, 1, 0xFF32783C
        dd 141, 174, 1, 1, 0xFF1E461E
        dd 123, 175, 1, 1, 0xFF1E461E
        dd 124, 175, 1, 1, 0xFF32783C
        dd 125, 175, 1, 1, 0xFF285A28
        dd 126, 175, 6, 1, 0xFF32783C
        dd 132, 175, 2, 1, 0xFF46A064
        dd 134, 175, 2, 1, 0xFF32783C
        dd 136, 175, 3, 1, 0xFF46A064
        dd 139, 175, 3, 1, 0xFF32783C
        dd 142, 175, 1, 1, 0xFF1E461E
        dd 123, 176, 1, 1, 0xFF1E461E
        dd 124, 176, 7, 1, 0xFF32783C
        dd 131, 176, 3, 1, 0xFF46A064
        dd 134, 176, 3, 1, 0xFF32783C
        dd 137, 176, 1, 1, 0xFF46A064
        dd 138, 176, 3, 1, 0xFF32783C
        dd 141, 176, 1, 1, 0xFF285A28
        dd 142, 176, 1, 1, 0xFF1E461E
        dd 122, 177, 1, 1, 0xFF1E461E
        dd 123, 177, 4, 1, 0xFF32783C
        dd 127, 177, 1, 1, 0xFF46A064
        dd 128, 177, 4, 1, 0xFF32783C
        dd 132, 177, 2, 1, 0xFF46A064
        dd 134, 177, 9, 1, 0xFF32783C
        dd 143, 177, 1, 1, 0xFF1E461E
        dd 122, 178, 1, 1, 0xFF1E461E
        dd 123, 178, 3, 1, 0xFF32783C
        dd 126, 178, 3, 1, 0xFF46A064
        dd 129, 178, 8, 1, 0xFF32783C
        dd 137, 178, 1, 1, 0xFF285A28
        dd 138, 178, 5, 1, 0xFF32783C
        dd 143, 178, 1, 1, 0xFF1E461E
        dd 122, 179, 1, 1, 0xFF1E461E
        dd 123, 179, 4, 1, 0xFF32783C
        dd 127, 179, 1, 1, 0xFF46A064
        dd 128, 179, 15, 1, 0xFF32783C
        dd 143, 179, 1, 1, 0xFF1E461E
        dd 122, 180, 1, 1, 0xFF1E461E
        dd 123, 180, 8, 1, 0xFF32783C
        dd 131, 180, 1, 1, 0xFF285A28
        dd 132, 180, 4, 1, 0xFF32783C
        dd 136, 180, 3, 1, 0xFF46A064
        dd 139, 180, 3, 1, 0xFF32783C
        dd 142, 180, 1, 1, 0xFF285A28
        dd 143, 180, 1, 1, 0xFF1E461E
        dd 122, 181, 1, 1, 0xFF1E461E
        dd 123, 181, 2, 1, 0xFF32783C
        dd 125, 181, 1, 1, 0xFF285A28
        dd 126, 181, 11, 1, 0xFF32783C
        dd 137, 181, 1, 1, 0xFF46A064
        dd 138, 181, 5, 1, 0xFF32783C
        dd 143, 181, 1, 1, 0xFF1E461E
        dd 123, 182, 1, 1, 0xFF1E461E
        dd 124, 182, 5, 1, 0xFF32783C
        dd 129, 182, 2, 1, 0xFF46A064
        dd 131, 182, 11, 1, 0xFF32783C
        dd 142, 182, 1, 1, 0xFF1E461E
        dd 123, 183, 1, 1, 0xFF1E461E
        dd 124, 183, 4, 1, 0xFF32783C
        dd 128, 183, 3, 1, 0xFF46A064
        dd 131, 183, 4, 1, 0xFF32783C
        dd 135, 183, 1, 1, 0xFF285A28
        dd 136, 183, 5, 1, 0xFF32783C
        dd 141, 183, 1, 1, 0xFF285A28
        dd 142, 183, 1, 1, 0xFF1E461E
        dd 124, 184, 1, 1, 0xFF1E461E
        dd 125, 184, 4, 1, 0xFF32783C
        dd 129, 184, 1, 1, 0xFF46A064
        dd 130, 184, 10, 1, 0xFF32783C
        dd 140, 184, 1, 1, 0xFF285A28
        dd 141, 184, 1, 1, 0xFF1E461E
        dd 124, 185, 1, 1, 0xFF1E461E
        dd 125, 185, 9, 1, 0xFF32783C
        dd 134, 185, 2, 1, 0xFF46A064
        dd 136, 185, 3, 1, 0xFF32783C
        dd 139, 185, 2, 1, 0xFF285A28
        dd 141, 185, 1, 1, 0xFF1E461E
        dd 125, 186, 1, 1, 0xFF1E461E
        dd 126, 186, 2, 1, 0xFF32783C
        dd 128, 186, 1, 1, 0xFF285A28
        dd 129, 186, 5, 1, 0xFF32783C
        dd 134, 186, 1, 1, 0xFF46A064
        dd 135, 186, 4, 1, 0xFF32783C
        dd 139, 186, 1, 1, 0xFF285A28
        dd 140, 186, 1, 1, 0xFF1E461E
        dd 126, 187, 1, 1, 0xFF1E461E
        dd 127, 187, 10, 1, 0xFF32783C
        dd 137, 187, 2, 1, 0xFF285A28
        dd 139, 187, 1, 1, 0xFF1E461E
        dd 127, 188, 2, 1, 0xFF1E461E
        dd 129, 188, 6, 1, 0xFF32783C
        dd 135, 188, 3, 1, 0xFF285A28
        dd 138, 188, 1, 1, 0xFF1E461E
        dd 129, 189, 8, 1, 0xFF1E461E
        dd 368, 5, 6, 1, 0xFF1E461E
        dd 366, 6, 2, 1, 0xFF1E461E
        dd 368, 6, 6, 1, 0xFF32783C
        dd 374, 6, 2, 1, 0xFF1E461E
        dd 365, 7, 1, 1, 0xFF1E461E
        dd 366, 7, 1, 1, 0xFF32783C
        dd 367, 7, 2, 1, 0xFF46A064
        dd 369, 7, 7, 1, 0xFF32783C
        dd 376, 7, 1, 1, 0xFF1E461E
        dd 364, 8, 1, 1, 0xFF1E461E
        dd 365, 8, 1, 1, 0xFF32783C
        dd 366, 8, 4, 1, 0xFF46A064
        dd 370, 8, 3, 1, 0xFF32783C
        dd 373, 8, 1, 1, 0xFF285A28
        dd 374, 8, 3, 1, 0xFF32783C
        dd 377, 8, 1, 1, 0xFF1E461E
        dd 363, 9, 1, 1, 0xFF1E461E
        dd 364, 9, 2, 1, 0xFF32783C
        dd 366, 9, 3, 1, 0xFF46A064
        dd 369, 9, 9, 1, 0xFF32783C
        dd 378, 9, 1, 1, 0xFF1E461E
        dd 362, 10, 1, 1, 0xFF1E461E
        dd 363, 10, 3, 1, 0xFF32783C
        dd 366, 10, 2, 1, 0xFF46A064
        dd 368, 10, 4, 1, 0xFF32783C
        dd 372, 10, 1, 1, 0xFF285A28
        dd 373, 10, 6, 1, 0xFF32783C
        dd 379, 10, 1, 1, 0xFF1E461E
        dd 362, 11, 1, 1, 0xFF1E461E
        dd 363, 11, 12, 1, 0xFF32783C
        dd 375, 11, 2, 1, 0xFF46A064
        dd 377, 11, 2, 1, 0xFF32783C
        dd 379, 11, 1, 1, 0xFF1E461E
        dd 361, 12, 1, 1, 0xFF1E461E
        dd 362, 12, 1, 1, 0xFF32783C
        dd 363, 12, 1, 1, 0xFF285A28
        dd 364, 12, 6, 1, 0xFF32783C
        dd 370, 12, 2, 1, 0xFF46A064
        dd 372, 12, 2, 1, 0xFF32783C
        dd 374, 12, 3, 1, 0xFF46A064
        dd 377, 12, 3, 1, 0xFF32783C
        dd 380, 12, 1, 1, 0xFF1E461E
        dd 361, 13, 1, 1, 0xFF1E461E
        dd 362, 13, 7, 1, 0xFF32783C
        dd 369, 13, 3, 1, 0xFF46A064
        dd 372, 13, 3, 1, 0xFF32783C
        dd 375, 13, 1, 1, 0xFF46A064
        dd 376, 13, 3, 1, 0xFF32783C
        dd 379, 13, 1, 1, 0xFF285A28
        dd 380, 13, 1, 1, 0xFF1E461E
        dd 360, 14, 1, 1, 0xFF1E461E
        dd 361, 14, 4, 1, 0xFF32783C
        dd 365, 14, 1, 1, 0xFF46A064
        dd 366, 14, 4, 1, 0xFF32783C
        dd 370, 14, 2, 1, 0xFF46A064
        dd 372, 14, 9, 1, 0xFF32783C
        dd 381, 14, 1, 1, 0xFF1E461E
        dd 360, 15, 1, 1, 0xFF1E461E
        dd 361, 15, 3, 1, 0xFF32783C
        dd 364, 15, 3, 1, 0xFF46A064
        dd 367, 15, 8, 1, 0xFF32783C
        dd 375, 15, 1, 1, 0xFF285A28
        dd 376, 15, 5, 1, 0xFF32783C
        dd 381, 15, 1, 1, 0xFF1E461E
        dd 360, 16, 1, 1, 0xFF1E461E
        dd 361, 16, 4, 1, 0xFF32783C
        dd 365, 16, 1, 1, 0xFF46A064
        dd 366, 16, 15, 1, 0xFF32783C
        dd 381, 16, 1, 1, 0xFF1E461E
        dd 360, 17, 1, 1, 0xFF1E461E
        dd 361, 17, 8, 1, 0xFF32783C
        dd 369, 17, 1, 1, 0xFF285A28
        dd 370, 17, 4, 1, 0xFF32783C
        dd 374, 17, 3, 1, 0xFF46A064
        dd 377, 17, 3, 1, 0xFF32783C
        dd 380, 17, 1, 1, 0xFF285A28
        dd 381, 17, 1, 1, 0xFF1E461E
        dd 360, 18, 1, 1, 0xFF1E461E
        dd 361, 18, 2, 1, 0xFF32783C
        dd 363, 18, 1, 1, 0xFF285A28
        dd 364, 18, 11, 1, 0xFF32783C
        dd 375, 18, 1, 1, 0xFF46A064
        dd 376, 18, 5, 1, 0xFF32783C
        dd 381, 18, 1, 1, 0xFF1E461E
        dd 361, 19, 1, 1, 0xFF1E461E
        dd 362, 19, 5, 1, 0xFF32783C
        dd 367, 19, 2, 1, 0xFF46A064
        dd 369, 19, 11, 1, 0xFF32783C
        dd 380, 19, 1, 1, 0xFF1E461E
        dd 361, 20, 1, 1, 0xFF1E461E
        dd 362, 20, 4, 1, 0xFF32783C
        dd 366, 20, 3, 1, 0xFF46A064
        dd 369, 20, 4, 1, 0xFF32783C
        dd 373, 20, 1, 1, 0xFF285A28
        dd 374, 20, 5, 1, 0xFF32783C
        dd 379, 20, 1, 1, 0xFF285A28
        dd 380, 20, 1, 1, 0xFF1E461E
        dd 362, 21, 1, 1, 0xFF1E461E
        dd 363, 21, 4, 1, 0xFF32783C
        dd 367, 21, 1, 1, 0xFF46A064
        dd 368, 21, 10, 1, 0xFF32783C
        dd 378, 21, 1, 1, 0xFF285A28
        dd 379, 21, 1, 1, 0xFF1E461E
        dd 362, 22, 1, 1, 0xFF1E461E
        dd 363, 22, 9, 1, 0xFF32783C
        dd 372, 22, 2, 1, 0xFF46A064
        dd 374, 22, 3, 1, 0xFF32783C
        dd 377, 22, 2, 1, 0xFF285A28
        dd 379, 22, 1, 1, 0xFF1E461E
        dd 363, 23, 1, 1, 0xFF1E461E
        dd 364, 23, 2, 1, 0xFF32783C
        dd 366, 23, 1, 1, 0xFF285A28
        dd 367, 23, 5, 1, 0xFF32783C
        dd 372, 23, 1, 1, 0xFF46A064
        dd 373, 23, 4, 1, 0xFF32783C
        dd 377, 23, 1, 1, 0xFF285A28
        dd 378, 23, 1, 1, 0xFF1E461E
        dd 364, 24, 1, 1, 0xFF1E461E
        dd 365, 24, 10, 1, 0xFF32783C
        dd 375, 24, 2, 1, 0xFF285A28
        dd 377, 24, 1, 1, 0xFF1E461E
        dd 365, 25, 2, 1, 0xFF1E461E
        dd 367, 25, 6, 1, 0xFF32783C
        dd 373, 25, 3, 1, 0xFF285A28
        dd 376, 25, 1, 1, 0xFF1E461E
        dd 367, 26, 8, 1, 0xFF1E461E
        dd 618, 150, 6, 1, 0xFF1E461E
        dd 616, 151, 2, 1, 0xFF1E461E
        dd 618, 151, 6, 1, 0xFF32783C
        dd 624, 151, 2, 1, 0xFF1E461E
        dd 615, 152, 1, 1, 0xFF1E461E
        dd 616, 152, 1, 1, 0xFF32783C
        dd 617, 152, 2, 1, 0xFF46A064
        dd 619, 152, 7, 1, 0xFF32783C
        dd 626, 152, 1, 1, 0xFF1E461E
        dd 614, 153, 1, 1, 0xFF1E461E
        dd 615, 153, 1, 1, 0xFF32783C
        dd 616, 153, 4, 1, 0xFF46A064
        dd 620, 153, 3, 1, 0xFF32783C
        dd 623, 153, 1, 1, 0xFF285A28
        dd 624, 153, 3, 1, 0xFF32783C
        dd 627, 153, 1, 1, 0xFF1E461E
        dd 613, 154, 1, 1, 0xFF1E461E
        dd 614, 154, 2, 1, 0xFF32783C
        dd 616, 154, 3, 1, 0xFF46A064
        dd 619, 154, 9, 1, 0xFF32783C
        dd 628, 154, 1, 1, 0xFF1E461E
        dd 612, 155, 1, 1, 0xFF1E461E
        dd 613, 155, 3, 1, 0xFF32783C
        dd 616, 155, 2, 1, 0xFF46A064
        dd 618, 155, 4, 1, 0xFF32783C
        dd 622, 155, 1, 1, 0xFF285A28
        dd 623, 155, 6, 1, 0xFF32783C
        dd 629, 155, 1, 1, 0xFF1E461E
        dd 612, 156, 1, 1, 0xFF1E461E
        dd 613, 156, 12, 1, 0xFF32783C
        dd 625, 156, 2, 1, 0xFF46A064
        dd 627, 156, 2, 1, 0xFF32783C
        dd 629, 156, 1, 1, 0xFF1E461E
        dd 611, 157, 1, 1, 0xFF1E461E
        dd 612, 157, 1, 1, 0xFF32783C
        dd 613, 157, 1, 1, 0xFF285A28
        dd 614, 157, 6, 1, 0xFF32783C
        dd 620, 157, 2, 1, 0xFF46A064
        dd 622, 157, 2, 1, 0xFF32783C
        dd 624, 157, 3, 1, 0xFF46A064
        dd 627, 157, 3, 1, 0xFF32783C
        dd 630, 157, 1, 1, 0xFF1E461E
        dd 611, 158, 1, 1, 0xFF1E461E
        dd 612, 158, 7, 1, 0xFF32783C
        dd 619, 158, 3, 1, 0xFF46A064
        dd 622, 158, 3, 1, 0xFF32783C
        dd 625, 158, 1, 1, 0xFF46A064
        dd 626, 158, 3, 1, 0xFF32783C
        dd 629, 158, 1, 1, 0xFF285A28
        dd 630, 158, 1, 1, 0xFF1E461E
        dd 610, 159, 1, 1, 0xFF1E461E
        dd 611, 159, 4, 1, 0xFF32783C
        dd 615, 159, 1, 1, 0xFF46A064
        dd 616, 159, 4, 1, 0xFF32783C
        dd 620, 159, 2, 1, 0xFF46A064
        dd 622, 159, 9, 1, 0xFF32783C
        dd 631, 159, 1, 1, 0xFF1E461E
        dd 610, 160, 1, 1, 0xFF1E461E
        dd 611, 160, 3, 1, 0xFF32783C
        dd 614, 160, 3, 1, 0xFF46A064
        dd 617, 160, 8, 1, 0xFF32783C
        dd 625, 160, 1, 1, 0xFF285A28
        dd 626, 160, 5, 1, 0xFF32783C
        dd 631, 160, 1, 1, 0xFF1E461E
        dd 610, 161, 1, 1, 0xFF1E461E
        dd 611, 161, 4, 1, 0xFF32783C
        dd 615, 161, 1, 1, 0xFF46A064
        dd 616, 161, 15, 1, 0xFF32783C
        dd 631, 161, 1, 1, 0xFF1E461E
        dd 610, 162, 1, 1, 0xFF1E461E
        dd 611, 162, 8, 1, 0xFF32783C
        dd 619, 162, 1, 1, 0xFF285A28
        dd 620, 162, 4, 1, 0xFF32783C
        dd 624, 162, 3, 1, 0xFF46A064
        dd 627, 162, 3, 1, 0xFF32783C
        dd 630, 162, 1, 1, 0xFF285A28
        dd 631, 162, 1, 1, 0xFF1E461E
        dd 610, 163, 1, 1, 0xFF1E461E
        dd 611, 163, 2, 1, 0xFF32783C
        dd 613, 163, 1, 1, 0xFF285A28
        dd 614, 163, 11, 1, 0xFF32783C
        dd 625, 163, 1, 1, 0xFF46A064
        dd 626, 163, 5, 1, 0xFF32783C
        dd 631, 163, 1, 1, 0xFF1E461E
        dd 611, 164, 1, 1, 0xFF1E461E
        dd 612, 164, 5, 1, 0xFF32783C
        dd 617, 164, 2, 1, 0xFF46A064
        dd 619, 164, 11, 1, 0xFF32783C
        dd 630, 164, 1, 1, 0xFF1E461E
        dd 611, 165, 1, 1, 0xFF1E461E
        dd 612, 165, 4, 1, 0xFF32783C
        dd 616, 165, 3, 1, 0xFF46A064
        dd 619, 165, 4, 1, 0xFF32783C
        dd 623, 165, 1, 1, 0xFF285A28
        dd 624, 165, 5, 1, 0xFF32783C
        dd 629, 165, 1, 1, 0xFF285A28
        dd 630, 165, 1, 1, 0xFF1E461E
        dd 612, 166, 1, 1, 0xFF1E461E
        dd 613, 166, 4, 1, 0xFF32783C
        dd 617, 166, 1, 1, 0xFF46A064
        dd 618, 166, 10, 1, 0xFF32783C
        dd 628, 166, 1, 1, 0xFF285A28
        dd 629, 166, 1, 1, 0xFF1E461E
        dd 612, 167, 1, 1, 0xFF1E461E
        dd 613, 167, 9, 1, 0xFF32783C
        dd 622, 167, 2, 1, 0xFF46A064
        dd 624, 167, 3, 1, 0xFF32783C
        dd 627, 167, 2, 1, 0xFF285A28
        dd 629, 167, 1, 1, 0xFF1E461E
        dd 613, 168, 1, 1, 0xFF1E461E
        dd 614, 168, 2, 1, 0xFF32783C
        dd 616, 168, 1, 1, 0xFF285A28
        dd 617, 168, 5, 1, 0xFF32783C
        dd 622, 168, 1, 1, 0xFF46A064
        dd 623, 168, 4, 1, 0xFF32783C
        dd 627, 168, 1, 1, 0xFF285A28
        dd 628, 168, 1, 1, 0xFF1E461E
        dd 614, 169, 1, 1, 0xFF1E461E
        dd 615, 169, 10, 1, 0xFF32783C
        dd 625, 169, 2, 1, 0xFF285A28
        dd 627, 169, 1, 1, 0xFF1E461E
        dd 615, 170, 2, 1, 0xFF1E461E
        dd 617, 170, 6, 1, 0xFF32783C
        dd 623, 170, 3, 1, 0xFF285A28
        dd 626, 170, 1, 1, 0xFF1E461E
        dd 617, 171, 8, 1, 0xFF1E461E
        dd 13, 405, 6, 1, 0xFF1E461E
        dd 11, 406, 2, 1, 0xFF1E461E
        dd 13, 406, 6, 1, 0xFF32783C
        dd 19, 406, 2, 1, 0xFF1E461E
        dd 10, 407, 1, 1, 0xFF1E461E
        dd 11, 407, 1, 1, 0xFF32783C
        dd 12, 407, 2, 1, 0xFF46A064
        dd 14, 407, 7, 1, 0xFF32783C
        dd 21, 407, 1, 1, 0xFF1E461E
        dd 9, 408, 1, 1, 0xFF1E461E
        dd 10, 408, 1, 1, 0xFF32783C
        dd 11, 408, 4, 1, 0xFF46A064
        dd 15, 408, 3, 1, 0xFF32783C
        dd 18, 408, 1, 1, 0xFF285A28
        dd 19, 408, 3, 1, 0xFF32783C
        dd 22, 408, 1, 1, 0xFF1E461E
        dd 8, 409, 1, 1, 0xFF1E461E
        dd 9, 409, 2, 1, 0xFF32783C
        dd 11, 409, 3, 1, 0xFF46A064
        dd 14, 409, 9, 1, 0xFF32783C
        dd 23, 409, 1, 1, 0xFF1E461E
        dd 7, 410, 1, 1, 0xFF1E461E
        dd 8, 410, 3, 1, 0xFF32783C
        dd 11, 410, 2, 1, 0xFF46A064
        dd 13, 410, 4, 1, 0xFF32783C
        dd 17, 410, 1, 1, 0xFF285A28
        dd 18, 410, 6, 1, 0xFF32783C
        dd 24, 410, 1, 1, 0xFF1E461E
        dd 7, 411, 1, 1, 0xFF1E461E
        dd 8, 411, 12, 1, 0xFF32783C
        dd 20, 411, 2, 1, 0xFF46A064
        dd 22, 411, 2, 1, 0xFF32783C
        dd 24, 411, 1, 1, 0xFF1E461E
        dd 6, 412, 1, 1, 0xFF1E461E
        dd 7, 412, 1, 1, 0xFF32783C
        dd 8, 412, 1, 1, 0xFF285A28
        dd 9, 412, 6, 1, 0xFF32783C
        dd 15, 412, 2, 1, 0xFF46A064
        dd 17, 412, 2, 1, 0xFF32783C
        dd 19, 412, 3, 1, 0xFF46A064
        dd 22, 412, 3, 1, 0xFF32783C
        dd 25, 412, 1, 1, 0xFF1E461E
        dd 6, 413, 1, 1, 0xFF1E461E
        dd 7, 413, 7, 1, 0xFF32783C
        dd 14, 413, 3, 1, 0xFF46A064
        dd 17, 413, 3, 1, 0xFF32783C
        dd 20, 413, 1, 1, 0xFF46A064
        dd 21, 413, 3, 1, 0xFF32783C
        dd 24, 413, 1, 1, 0xFF285A28
        dd 25, 413, 1, 1, 0xFF1E461E
        dd 5, 414, 1, 1, 0xFF1E461E
        dd 6, 414, 4, 1, 0xFF32783C
        dd 10, 414, 1, 1, 0xFF46A064
        dd 11, 414, 4, 1, 0xFF32783C
        dd 15, 414, 2, 1, 0xFF46A064
        dd 17, 414, 9, 1, 0xFF32783C
        dd 26, 414, 1, 1, 0xFF1E461E
        dd 5, 415, 1, 1, 0xFF1E461E
        dd 6, 415, 3, 1, 0xFF32783C
        dd 9, 415, 3, 1, 0xFF46A064
        dd 12, 415, 8, 1, 0xFF32783C
        dd 20, 415, 1, 1, 0xFF285A28
        dd 21, 415, 5, 1, 0xFF32783C
        dd 26, 415, 1, 1, 0xFF1E461E
        dd 5, 416, 1, 1, 0xFF1E461E
        dd 6, 416, 4, 1, 0xFF32783C
        dd 10, 416, 1, 1, 0xFF46A064
        dd 11, 416, 15, 1, 0xFF32783C
        dd 26, 416, 1, 1, 0xFF1E461E
        dd 5, 417, 1, 1, 0xFF1E461E
        dd 6, 417, 8, 1, 0xFF32783C
        dd 14, 417, 1, 1, 0xFF285A28
        dd 15, 417, 4, 1, 0xFF32783C
        dd 19, 417, 3, 1, 0xFF46A064
        dd 22, 417, 3, 1, 0xFF32783C
        dd 25, 417, 1, 1, 0xFF285A28
        dd 26, 417, 1, 1, 0xFF1E461E
        dd 5, 418, 1, 1, 0xFF1E461E
        dd 6, 418, 2, 1, 0xFF32783C
        dd 8, 418, 1, 1, 0xFF285A28
        dd 9, 418, 11, 1, 0xFF32783C
        dd 20, 418, 1, 1, 0xFF46A064
        dd 21, 418, 5, 1, 0xFF32783C
        dd 26, 418, 1, 1, 0xFF1E461E
        dd 6, 419, 1, 1, 0xFF1E461E
        dd 7, 419, 5, 1, 0xFF32783C
        dd 12, 419, 2, 1, 0xFF46A064
        dd 14, 419, 11, 1, 0xFF32783C
        dd 25, 419, 1, 1, 0xFF1E461E
        dd 6, 420, 1, 1, 0xFF1E461E
        dd 7, 420, 4, 1, 0xFF32783C
        dd 11, 420, 3, 1, 0xFF46A064
        dd 14, 420, 4, 1, 0xFF32783C
        dd 18, 420, 1, 1, 0xFF285A28
        dd 19, 420, 5, 1, 0xFF32783C
        dd 24, 420, 1, 1, 0xFF285A28
        dd 25, 420, 1, 1, 0xFF1E461E
        dd 7, 421, 1, 1, 0xFF1E461E
        dd 8, 421, 4, 1, 0xFF32783C
        dd 12, 421, 1, 1, 0xFF46A064
        dd 13, 421, 10, 1, 0xFF32783C
        dd 23, 421, 1, 1, 0xFF285A28
        dd 24, 421, 1, 1, 0xFF1E461E
        dd 7, 422, 1, 1, 0xFF1E461E
        dd 8, 422, 9, 1, 0xFF32783C
        dd 17, 422, 2, 1, 0xFF46A064
        dd 19, 422, 3, 1, 0xFF32783C
        dd 22, 422, 2, 1, 0xFF285A28
        dd 24, 422, 1, 1, 0xFF1E461E
        dd 8, 423, 1, 1, 0xFF1E461E
        dd 9, 423, 2, 1, 0xFF32783C
        dd 11, 423, 1, 1, 0xFF285A28
        dd 12, 423, 5, 1, 0xFF32783C
        dd 17, 423, 1, 1, 0xFF46A064
        dd 18, 423, 4, 1, 0xFF32783C
        dd 22, 423, 1, 1, 0xFF285A28
        dd 23, 423, 1, 1, 0xFF1E461E
        dd 9, 424, 1, 1, 0xFF1E461E
        dd 10, 424, 10, 1, 0xFF32783C
        dd 20, 424, 2, 1, 0xFF285A28
        dd 22, 424, 1, 1, 0xFF1E461E
        dd 10, 425, 2, 1, 0xFF1E461E
        dd 12, 425, 6, 1, 0xFF32783C
        dd 18, 425, 3, 1, 0xFF285A28
        dd 21, 425, 1, 1, 0xFF1E461E
        dd 12, 426, 8, 1, 0xFF1E461E
        dd 583, 520, 6, 1, 0xFF1E461E
        dd 581, 521, 2, 1, 0xFF1E461E
        dd 583, 521, 6, 1, 0xFF32783C
        dd 589, 521, 2, 1, 0xFF1E461E
        dd 580, 522, 1, 1, 0xFF1E461E
        dd 581, 522, 1, 1, 0xFF32783C
        dd 582, 522, 2, 1, 0xFF46A064
        dd 584, 522, 7, 1, 0xFF32783C
        dd 591, 522, 1, 1, 0xFF1E461E
        dd 579, 523, 1, 1, 0xFF1E461E
        dd 580, 523, 1, 1, 0xFF32783C
        dd 581, 523, 4, 1, 0xFF46A064
        dd 585, 523, 3, 1, 0xFF32783C
        dd 588, 523, 1, 1, 0xFF285A28
        dd 589, 523, 3, 1, 0xFF32783C
        dd 592, 523, 1, 1, 0xFF1E461E
        dd 578, 524, 1, 1, 0xFF1E461E
        dd 579, 524, 2, 1, 0xFF32783C
        dd 581, 524, 3, 1, 0xFF46A064
        dd 584, 524, 9, 1, 0xFF32783C
        dd 593, 524, 1, 1, 0xFF1E461E
        dd 577, 525, 1, 1, 0xFF1E461E
        dd 578, 525, 3, 1, 0xFF32783C
        dd 581, 525, 2, 1, 0xFF46A064
        dd 583, 525, 4, 1, 0xFF32783C
        dd 587, 525, 1, 1, 0xFF285A28
        dd 588, 525, 6, 1, 0xFF32783C
        dd 594, 525, 1, 1, 0xFF1E461E
        dd 577, 526, 1, 1, 0xFF1E461E
        dd 578, 526, 12, 1, 0xFF32783C
        dd 590, 526, 2, 1, 0xFF46A064
        dd 592, 526, 2, 1, 0xFF32783C
        dd 594, 526, 1, 1, 0xFF1E461E
        dd 576, 527, 1, 1, 0xFF1E461E
        dd 577, 527, 1, 1, 0xFF32783C
        dd 578, 527, 1, 1, 0xFF285A28
        dd 579, 527, 6, 1, 0xFF32783C
        dd 585, 527, 2, 1, 0xFF46A064
        dd 587, 527, 2, 1, 0xFF32783C
        dd 589, 527, 3, 1, 0xFF46A064
        dd 592, 527, 3, 1, 0xFF32783C
        dd 595, 527, 1, 1, 0xFF1E461E
        dd 576, 528, 1, 1, 0xFF1E461E
        dd 577, 528, 7, 1, 0xFF32783C
        dd 584, 528, 3, 1, 0xFF46A064
        dd 587, 528, 3, 1, 0xFF32783C
        dd 590, 528, 1, 1, 0xFF46A064
        dd 591, 528, 3, 1, 0xFF32783C
        dd 594, 528, 1, 1, 0xFF285A28
        dd 595, 528, 1, 1, 0xFF1E461E
        dd 575, 529, 1, 1, 0xFF1E461E
        dd 576, 529, 4, 1, 0xFF32783C
        dd 580, 529, 1, 1, 0xFF46A064
        dd 581, 529, 4, 1, 0xFF32783C
        dd 585, 529, 2, 1, 0xFF46A064
        dd 587, 529, 9, 1, 0xFF32783C
        dd 596, 529, 1, 1, 0xFF1E461E
        dd 575, 530, 1, 1, 0xFF1E461E
        dd 576, 530, 3, 1, 0xFF32783C
        dd 579, 530, 3, 1, 0xFF46A064
        dd 582, 530, 8, 1, 0xFF32783C
        dd 590, 530, 1, 1, 0xFF285A28
        dd 591, 530, 5, 1, 0xFF32783C
        dd 596, 530, 1, 1, 0xFF1E461E
        dd 575, 531, 1, 1, 0xFF1E461E
        dd 576, 531, 4, 1, 0xFF32783C
        dd 580, 531, 1, 1, 0xFF46A064
        dd 581, 531, 15, 1, 0xFF32783C
        dd 596, 531, 1, 1, 0xFF1E461E
        dd 575, 532, 1, 1, 0xFF1E461E
        dd 576, 532, 8, 1, 0xFF32783C
        dd 584, 532, 1, 1, 0xFF285A28
        dd 585, 532, 4, 1, 0xFF32783C
        dd 589, 532, 3, 1, 0xFF46A064
        dd 592, 532, 3, 1, 0xFF32783C
        dd 595, 532, 1, 1, 0xFF285A28
        dd 596, 532, 1, 1, 0xFF1E461E
        dd 575, 533, 1, 1, 0xFF1E461E
        dd 576, 533, 2, 1, 0xFF32783C
        dd 578, 533, 1, 1, 0xFF285A28
        dd 579, 533, 11, 1, 0xFF32783C
        dd 590, 533, 1, 1, 0xFF46A064
        dd 591, 533, 5, 1, 0xFF32783C
        dd 596, 533, 1, 1, 0xFF1E461E
        dd 576, 534, 1, 1, 0xFF1E461E
        dd 577, 534, 5, 1, 0xFF32783C
        dd 582, 534, 2, 1, 0xFF46A064
        dd 584, 534, 11, 1, 0xFF32783C
        dd 595, 534, 1, 1, 0xFF1E461E
        dd 576, 535, 1, 1, 0xFF1E461E
        dd 577, 535, 4, 1, 0xFF32783C
        dd 581, 535, 3, 1, 0xFF46A064
        dd 584, 535, 4, 1, 0xFF32783C
        dd 588, 535, 1, 1, 0xFF285A28
        dd 589, 535, 5, 1, 0xFF32783C
        dd 594, 535, 1, 1, 0xFF285A28
        dd 595, 535, 1, 1, 0xFF1E461E
        dd 577, 536, 1, 1, 0xFF1E461E
        dd 578, 536, 4, 1, 0xFF32783C
        dd 582, 536, 1, 1, 0xFF46A064
        dd 583, 536, 10, 1, 0xFF32783C
        dd 593, 536, 1, 1, 0xFF285A28
        dd 594, 536, 1, 1, 0xFF1E461E
        dd 577, 537, 1, 1, 0xFF1E461E
        dd 578, 537, 9, 1, 0xFF32783C
        dd 587, 537, 2, 1, 0xFF46A064
        dd 589, 537, 3, 1, 0xFF32783C
        dd 592, 537, 2, 1, 0xFF285A28
        dd 594, 537, 1, 1, 0xFF1E461E
        dd 578, 538, 1, 1, 0xFF1E461E
        dd 579, 538, 2, 1, 0xFF32783C
        dd 581, 538, 1, 1, 0xFF285A28
        dd 582, 538, 5, 1, 0xFF32783C
        dd 587, 538, 1, 1, 0xFF46A064
        dd 588, 538, 4, 1, 0xFF32783C
        dd 592, 538, 1, 1, 0xFF285A28
        dd 593, 538, 1, 1, 0xFF1E461E
        dd 579, 539, 1, 1, 0xFF1E461E
        dd 580, 539, 10, 1, 0xFF32783C
        dd 590, 539, 2, 1, 0xFF285A28
        dd 592, 539, 1, 1, 0xFF1E461E
        dd 580, 540, 2, 1, 0xFF1E461E
        dd 582, 540, 6, 1, 0xFF32783C
        dd 588, 540, 3, 1, 0xFF285A28
        dd 591, 540, 1, 1, 0xFF1E461E
        dd 582, 541, 8, 1, 0xFF1E461E
        dd 703, 562, 6, 1, 0xFF1E461E
        dd 701, 563, 2, 1, 0xFF1E461E
        dd 703, 563, 6, 1, 0xFF32783C
        dd 709, 563, 2, 1, 0xFF1E461E
        dd 700, 564, 1, 1, 0xFF1E461E
        dd 701, 564, 1, 1, 0xFF32783C
        dd 702, 564, 2, 1, 0xFF46A064
        dd 704, 564, 7, 1, 0xFF32783C
        dd 711, 564, 1, 1, 0xFF1E461E
        dd 699, 565, 1, 1, 0xFF1E461E
        dd 700, 565, 1, 1, 0xFF32783C
        dd 701, 565, 4, 1, 0xFF46A064
        dd 705, 565, 3, 1, 0xFF32783C
        dd 708, 565, 1, 1, 0xFF285A28
        dd 709, 565, 3, 1, 0xFF32783C
        dd 712, 565, 1, 1, 0xFF1E461E
        dd 698, 566, 1, 1, 0xFF1E461E
        dd 699, 566, 2, 1, 0xFF32783C
        dd 701, 566, 3, 1, 0xFF46A064
        dd 704, 566, 9, 1, 0xFF32783C
        dd 713, 566, 1, 1, 0xFF1E461E
        dd 697, 567, 1, 1, 0xFF1E461E
        dd 698, 567, 3, 1, 0xFF32783C
        dd 701, 567, 2, 1, 0xFF46A064
        dd 703, 567, 4, 1, 0xFF32783C
        dd 707, 567, 1, 1, 0xFF285A28
        dd 708, 567, 6, 1, 0xFF32783C
        dd 714, 567, 1, 1, 0xFF1E461E
        dd 697, 568, 1, 1, 0xFF1E461E
        dd 698, 568, 12, 1, 0xFF32783C
        dd 710, 568, 2, 1, 0xFF46A064
        dd 712, 568, 2, 1, 0xFF32783C
        dd 714, 568, 1, 1, 0xFF1E461E
        dd 696, 569, 1, 1, 0xFF1E461E
        dd 697, 569, 1, 1, 0xFF32783C
        dd 698, 569, 1, 1, 0xFF285A28
        dd 699, 569, 6, 1, 0xFF32783C
        dd 705, 569, 2, 1, 0xFF46A064
        dd 707, 569, 2, 1, 0xFF32783C
        dd 709, 569, 3, 1, 0xFF46A064
        dd 712, 569, 3, 1, 0xFF32783C
        dd 715, 569, 1, 1, 0xFF1E461E
        dd 696, 570, 1, 1, 0xFF1E461E
        dd 697, 570, 7, 1, 0xFF32783C
        dd 704, 570, 3, 1, 0xFF46A064
        dd 707, 570, 3, 1, 0xFF32783C
        dd 710, 570, 1, 1, 0xFF46A064
        dd 711, 570, 3, 1, 0xFF32783C
        dd 714, 570, 1, 1, 0xFF285A28
        dd 715, 570, 1, 1, 0xFF1E461E
        dd 695, 571, 1, 1, 0xFF1E461E
        dd 696, 571, 4, 1, 0xFF32783C
        dd 700, 571, 1, 1, 0xFF46A064
        dd 701, 571, 4, 1, 0xFF32783C
        dd 705, 571, 2, 1, 0xFF46A064
        dd 707, 571, 9, 1, 0xFF32783C
        dd 716, 571, 1, 1, 0xFF1E461E
        dd 695, 572, 1, 1, 0xFF1E461E
        dd 696, 572, 3, 1, 0xFF32783C
        dd 699, 572, 3, 1, 0xFF46A064
        dd 702, 572, 8, 1, 0xFF32783C
        dd 710, 572, 1, 1, 0xFF285A28
        dd 711, 572, 5, 1, 0xFF32783C
        dd 716, 572, 1, 1, 0xFF1E461E
        dd 695, 573, 1, 1, 0xFF1E461E
        dd 696, 573, 4, 1, 0xFF32783C
        dd 700, 573, 1, 1, 0xFF46A064
        dd 701, 573, 15, 1, 0xFF32783C
        dd 716, 573, 1, 1, 0xFF1E461E
        dd 695, 574, 1, 1, 0xFF1E461E
        dd 696, 574, 8, 1, 0xFF32783C
        dd 704, 574, 1, 1, 0xFF285A28
        dd 705, 574, 4, 1, 0xFF32783C
        dd 709, 574, 3, 1, 0xFF46A064
        dd 712, 574, 3, 1, 0xFF32783C
        dd 715, 574, 1, 1, 0xFF285A28
        dd 716, 574, 1, 1, 0xFF1E461E
        dd 695, 575, 1, 1, 0xFF1E461E
        dd 696, 575, 2, 1, 0xFF32783C
        dd 698, 575, 1, 1, 0xFF285A28
        dd 699, 575, 11, 1, 0xFF32783C
        dd 710, 575, 1, 1, 0xFF46A064
        dd 711, 575, 5, 1, 0xFF32783C
        dd 716, 575, 1, 1, 0xFF1E461E
        dd 696, 576, 1, 1, 0xFF1E461E
        dd 697, 576, 5, 1, 0xFF32783C
        dd 702, 576, 2, 1, 0xFF46A064
        dd 704, 576, 11, 1, 0xFF32783C
        dd 715, 576, 1, 1, 0xFF1E461E
        dd 696, 577, 1, 1, 0xFF1E461E
        dd 697, 577, 4, 1, 0xFF32783C
        dd 701, 577, 3, 1, 0xFF46A064
        dd 704, 577, 4, 1, 0xFF32783C
        dd 708, 577, 1, 1, 0xFF285A28
        dd 709, 577, 5, 1, 0xFF32783C
        dd 714, 577, 1, 1, 0xFF285A28
        dd 715, 577, 1, 1, 0xFF1E461E
        dd 697, 578, 1, 1, 0xFF1E461E
        dd 698, 578, 4, 1, 0xFF32783C
        dd 702, 578, 1, 1, 0xFF46A064
        dd 703, 578, 10, 1, 0xFF32783C
        dd 713, 578, 1, 1, 0xFF285A28
        dd 714, 578, 1, 1, 0xFF1E461E
        dd 697, 579, 1, 1, 0xFF1E461E
        dd 698, 579, 9, 1, 0xFF32783C
        dd 707, 579, 2, 1, 0xFF46A064
        dd 709, 579, 3, 1, 0xFF32783C
        dd 712, 579, 2, 1, 0xFF285A28
        dd 714, 579, 1, 1, 0xFF1E461E
        dd 698, 580, 1, 1, 0xFF1E461E
        dd 699, 580, 2, 1, 0xFF32783C
        dd 701, 580, 1, 1, 0xFF285A28
        dd 702, 580, 5, 1, 0xFF32783C
        dd 707, 580, 1, 1, 0xFF46A064
        dd 708, 580, 4, 1, 0xFF32783C
        dd 712, 580, 1, 1, 0xFF285A28
        dd 713, 580, 1, 1, 0xFF1E461E
        dd 699, 581, 1, 1, 0xFF1E461E
        dd 700, 581, 10, 1, 0xFF32783C
        dd 710, 581, 2, 1, 0xFF285A28
        dd 712, 581, 1, 1, 0xFF1E461E
        dd 700, 582, 2, 1, 0xFF1E461E
        dd 702, 582, 6, 1, 0xFF32783C
        dd 708, 582, 3, 1, 0xFF285A28
        dd 711, 582, 1, 1, 0xFF1E461E
        dd 702, 583, 8, 1, 0xFF1E461E
        dd 482, 660, 6, 1, 0xFF1E461E
        dd 480, 661, 2, 1, 0xFF1E461E
        dd 482, 661, 6, 1, 0xFF32783C
        dd 488, 661, 2, 1, 0xFF1E461E
        dd 479, 662, 1, 1, 0xFF1E461E
        dd 480, 662, 1, 1, 0xFF32783C
        dd 481, 662, 2, 1, 0xFF46A064
        dd 483, 662, 7, 1, 0xFF32783C
        dd 490, 662, 1, 1, 0xFF1E461E
        dd 478, 663, 1, 1, 0xFF1E461E
        dd 479, 663, 1, 1, 0xFF32783C
        dd 480, 663, 4, 1, 0xFF46A064
        dd 484, 663, 3, 1, 0xFF32783C
        dd 487, 663, 1, 1, 0xFF285A28
        dd 488, 663, 3, 1, 0xFF32783C
        dd 491, 663, 1, 1, 0xFF1E461E
        dd 477, 664, 1, 1, 0xFF1E461E
        dd 478, 664, 2, 1, 0xFF32783C
        dd 480, 664, 3, 1, 0xFF46A064
        dd 483, 664, 9, 1, 0xFF32783C
        dd 492, 664, 1, 1, 0xFF1E461E
        dd 476, 665, 1, 1, 0xFF1E461E
        dd 477, 665, 3, 1, 0xFF32783C
        dd 480, 665, 2, 1, 0xFF46A064
        dd 482, 665, 4, 1, 0xFF32783C
        dd 486, 665, 1, 1, 0xFF285A28
        dd 487, 665, 6, 1, 0xFF32783C
        dd 493, 665, 1, 1, 0xFF1E461E
        dd 476, 666, 1, 1, 0xFF1E461E
        dd 477, 666, 12, 1, 0xFF32783C
        dd 489, 666, 2, 1, 0xFF46A064
        dd 491, 666, 2, 1, 0xFF32783C
        dd 493, 666, 1, 1, 0xFF1E461E
        dd 475, 667, 1, 1, 0xFF1E461E
        dd 476, 667, 1, 1, 0xFF32783C
        dd 477, 667, 1, 1, 0xFF285A28
        dd 478, 667, 6, 1, 0xFF32783C
        dd 484, 667, 2, 1, 0xFF46A064
        dd 486, 667, 2, 1, 0xFF32783C
        dd 488, 667, 3, 1, 0xFF46A064
        dd 491, 667, 3, 1, 0xFF32783C
        dd 494, 667, 1, 1, 0xFF1E461E
        dd 475, 668, 1, 1, 0xFF1E461E
        dd 476, 668, 7, 1, 0xFF32783C
        dd 483, 668, 3, 1, 0xFF46A064
        dd 486, 668, 3, 1, 0xFF32783C
        dd 489, 668, 1, 1, 0xFF46A064
        dd 490, 668, 3, 1, 0xFF32783C
        dd 493, 668, 1, 1, 0xFF285A28
        dd 494, 668, 1, 1, 0xFF1E461E
        dd 474, 669, 1, 1, 0xFF1E461E
        dd 475, 669, 4, 1, 0xFF32783C
        dd 479, 669, 1, 1, 0xFF46A064
        dd 480, 669, 4, 1, 0xFF32783C
        dd 484, 669, 2, 1, 0xFF46A064
        dd 486, 669, 9, 1, 0xFF32783C
        dd 495, 669, 1, 1, 0xFF1E461E
        dd 474, 670, 1, 1, 0xFF1E461E
        dd 475, 670, 3, 1, 0xFF32783C
        dd 478, 670, 3, 1, 0xFF46A064
        dd 481, 670, 8, 1, 0xFF32783C
        dd 489, 670, 1, 1, 0xFF285A28
        dd 490, 670, 5, 1, 0xFF32783C
        dd 495, 670, 1, 1, 0xFF1E461E
        dd 474, 671, 1, 1, 0xFF1E461E
        dd 475, 671, 4, 1, 0xFF32783C
        dd 479, 671, 1, 1, 0xFF46A064
        dd 480, 671, 15, 1, 0xFF32783C
        dd 495, 671, 1, 1, 0xFF1E461E
        dd 474, 672, 1, 1, 0xFF1E461E
        dd 475, 672, 8, 1, 0xFF32783C
        dd 483, 672, 1, 1, 0xFF285A28
        dd 484, 672, 4, 1, 0xFF32783C
        dd 488, 672, 3, 1, 0xFF46A064
        dd 491, 672, 3, 1, 0xFF32783C
        dd 494, 672, 1, 1, 0xFF285A28
        dd 495, 672, 1, 1, 0xFF1E461E
        dd 474, 673, 1, 1, 0xFF1E461E
        dd 475, 673, 2, 1, 0xFF32783C
        dd 477, 673, 1, 1, 0xFF285A28
        dd 478, 673, 11, 1, 0xFF32783C
        dd 489, 673, 1, 1, 0xFF46A064
        dd 490, 673, 5, 1, 0xFF32783C
        dd 495, 673, 1, 1, 0xFF1E461E
        dd 475, 674, 1, 1, 0xFF1E461E
        dd 476, 674, 5, 1, 0xFF32783C
        dd 481, 674, 2, 1, 0xFF46A064
        dd 483, 674, 11, 1, 0xFF32783C
        dd 494, 674, 1, 1, 0xFF1E461E
        dd 475, 675, 1, 1, 0xFF1E461E
        dd 476, 675, 4, 1, 0xFF32783C
        dd 480, 675, 3, 1, 0xFF46A064
        dd 483, 675, 4, 1, 0xFF32783C
        dd 487, 675, 1, 1, 0xFF285A28
        dd 488, 675, 5, 1, 0xFF32783C
        dd 493, 675, 1, 1, 0xFF285A28
        dd 494, 675, 1, 1, 0xFF1E461E
        dd 476, 676, 1, 1, 0xFF1E461E
        dd 477, 676, 4, 1, 0xFF32783C
        dd 481, 676, 1, 1, 0xFF46A064
        dd 482, 676, 10, 1, 0xFF32783C
        dd 492, 676, 1, 1, 0xFF285A28
        dd 493, 676, 1, 1, 0xFF1E461E
        dd 476, 677, 1, 1, 0xFF1E461E
        dd 477, 677, 9, 1, 0xFF32783C
        dd 486, 677, 2, 1, 0xFF46A064
        dd 488, 677, 3, 1, 0xFF32783C
        dd 491, 677, 2, 1, 0xFF285A28
        dd 493, 677, 1, 1, 0xFF1E461E
        dd 477, 678, 1, 1, 0xFF1E461E
        dd 478, 678, 2, 1, 0xFF32783C
        dd 480, 678, 1, 1, 0xFF285A28
        dd 481, 678, 5, 1, 0xFF32783C
        dd 486, 678, 1, 1, 0xFF46A064
        dd 487, 678, 4, 1, 0xFF32783C
        dd 491, 678, 1, 1, 0xFF285A28
        dd 492, 678, 1, 1, 0xFF1E461E
        dd 478, 679, 1, 1, 0xFF1E461E
        dd 479, 679, 10, 1, 0xFF32783C
        dd 489, 679, 2, 1, 0xFF285A28
        dd 491, 679, 1, 1, 0xFF1E461E
        dd 479, 680, 2, 1, 0xFF1E461E
        dd 481, 680, 6, 1, 0xFF32783C
        dd 487, 680, 3, 1, 0xFF285A28
        dd 490, 680, 1, 1, 0xFF1E461E
        dd 481, 681, 8, 1, 0xFF1E461E
        dd 763, 660, 6, 1, 0xFF1E461E
        dd 761, 661, 2, 1, 0xFF1E461E
        dd 763, 661, 6, 1, 0xFF32783C
        dd 769, 661, 2, 1, 0xFF1E461E
        dd 760, 662, 1, 1, 0xFF1E461E
        dd 761, 662, 1, 1, 0xFF32783C
        dd 762, 662, 2, 1, 0xFF46A064
        dd 764, 662, 7, 1, 0xFF32783C
        dd 771, 662, 1, 1, 0xFF1E461E
        dd 759, 663, 1, 1, 0xFF1E461E
        dd 760, 663, 1, 1, 0xFF32783C
        dd 761, 663, 4, 1, 0xFF46A064
        dd 765, 663, 3, 1, 0xFF32783C
        dd 768, 663, 1, 1, 0xFF285A28
        dd 769, 663, 3, 1, 0xFF32783C
        dd 772, 663, 1, 1, 0xFF1E461E
        dd 758, 664, 1, 1, 0xFF1E461E
        dd 759, 664, 2, 1, 0xFF32783C
        dd 761, 664, 3, 1, 0xFF46A064
        dd 764, 664, 9, 1, 0xFF32783C
        dd 773, 664, 1, 1, 0xFF1E461E
        dd 757, 665, 1, 1, 0xFF1E461E
        dd 758, 665, 3, 1, 0xFF32783C
        dd 761, 665, 2, 1, 0xFF46A064
        dd 763, 665, 4, 1, 0xFF32783C
        dd 767, 665, 1, 1, 0xFF285A28
        dd 768, 665, 6, 1, 0xFF32783C
        dd 774, 665, 1, 1, 0xFF1E461E
        dd 757, 666, 1, 1, 0xFF1E461E
        dd 758, 666, 12, 1, 0xFF32783C
        dd 770, 666, 2, 1, 0xFF46A064
        dd 772, 666, 2, 1, 0xFF32783C
        dd 774, 666, 1, 1, 0xFF1E461E
        dd 756, 667, 1, 1, 0xFF1E461E
        dd 757, 667, 1, 1, 0xFF32783C
        dd 758, 667, 1, 1, 0xFF285A28
        dd 759, 667, 6, 1, 0xFF32783C
        dd 765, 667, 2, 1, 0xFF46A064
        dd 767, 667, 2, 1, 0xFF32783C
        dd 769, 667, 3, 1, 0xFF46A064
        dd 772, 667, 3, 1, 0xFF32783C
        dd 775, 667, 1, 1, 0xFF1E461E
        dd 756, 668, 1, 1, 0xFF1E461E
        dd 757, 668, 7, 1, 0xFF32783C
        dd 764, 668, 3, 1, 0xFF46A064
        dd 767, 668, 3, 1, 0xFF32783C
        dd 770, 668, 1, 1, 0xFF46A064
        dd 771, 668, 3, 1, 0xFF32783C
        dd 774, 668, 1, 1, 0xFF285A28
        dd 775, 668, 1, 1, 0xFF1E461E
        dd 755, 669, 1, 1, 0xFF1E461E
        dd 756, 669, 4, 1, 0xFF32783C
        dd 760, 669, 1, 1, 0xFF46A064
        dd 761, 669, 4, 1, 0xFF32783C
        dd 765, 669, 2, 1, 0xFF46A064
        dd 767, 669, 9, 1, 0xFF32783C
        dd 776, 669, 1, 1, 0xFF1E461E
        dd 755, 670, 1, 1, 0xFF1E461E
        dd 756, 670, 3, 1, 0xFF32783C
        dd 759, 670, 3, 1, 0xFF46A064
        dd 762, 670, 8, 1, 0xFF32783C
        dd 770, 670, 1, 1, 0xFF285A28
        dd 771, 670, 5, 1, 0xFF32783C
        dd 776, 670, 1, 1, 0xFF1E461E
        dd 755, 671, 1, 1, 0xFF1E461E
        dd 756, 671, 4, 1, 0xFF32783C
        dd 760, 671, 1, 1, 0xFF46A064
        dd 761, 671, 15, 1, 0xFF32783C
        dd 776, 671, 1, 1, 0xFF1E461E
        dd 755, 672, 1, 1, 0xFF1E461E
        dd 756, 672, 8, 1, 0xFF32783C
        dd 764, 672, 1, 1, 0xFF285A28
        dd 765, 672, 4, 1, 0xFF32783C
        dd 769, 672, 3, 1, 0xFF46A064
        dd 772, 672, 3, 1, 0xFF32783C
        dd 775, 672, 1, 1, 0xFF285A28
        dd 776, 672, 1, 1, 0xFF1E461E
        dd 755, 673, 1, 1, 0xFF1E461E
        dd 756, 673, 2, 1, 0xFF32783C
        dd 758, 673, 1, 1, 0xFF285A28
        dd 759, 673, 11, 1, 0xFF32783C
        dd 770, 673, 1, 1, 0xFF46A064
        dd 771, 673, 5, 1, 0xFF32783C
        dd 776, 673, 1, 1, 0xFF1E461E
        dd 756, 674, 1, 1, 0xFF1E461E
        dd 757, 674, 5, 1, 0xFF32783C
        dd 762, 674, 2, 1, 0xFF46A064
        dd 764, 674, 11, 1, 0xFF32783C
        dd 775, 674, 1, 1, 0xFF1E461E
        dd 756, 675, 1, 1, 0xFF1E461E
        dd 757, 675, 4, 1, 0xFF32783C
        dd 761, 675, 3, 1, 0xFF46A064
        dd 764, 675, 4, 1, 0xFF32783C
        dd 768, 675, 1, 1, 0xFF285A28
        dd 769, 675, 5, 1, 0xFF32783C
        dd 774, 675, 1, 1, 0xFF285A28
        dd 775, 675, 1, 1, 0xFF1E461E
        dd 757, 676, 1, 1, 0xFF1E461E
        dd 758, 676, 4, 1, 0xFF32783C
        dd 762, 676, 1, 1, 0xFF46A064
        dd 763, 676, 10, 1, 0xFF32783C
        dd 773, 676, 1, 1, 0xFF285A28
        dd 774, 676, 1, 1, 0xFF1E461E
        dd 757, 677, 1, 1, 0xFF1E461E
        dd 758, 677, 9, 1, 0xFF32783C
        dd 767, 677, 2, 1, 0xFF46A064
        dd 769, 677, 3, 1, 0xFF32783C
        dd 772, 677, 2, 1, 0xFF285A28
        dd 774, 677, 1, 1, 0xFF1E461E
        dd 758, 678, 1, 1, 0xFF1E461E
        dd 759, 678, 2, 1, 0xFF32783C
        dd 761, 678, 1, 1, 0xFF285A28
        dd 762, 678, 5, 1, 0xFF32783C
        dd 767, 678, 1, 1, 0xFF46A064
        dd 768, 678, 4, 1, 0xFF32783C
        dd 772, 678, 1, 1, 0xFF285A28
        dd 773, 678, 1, 1, 0xFF1E461E
        dd 759, 679, 1, 1, 0xFF1E461E
        dd 760, 679, 10, 1, 0xFF32783C
        dd 770, 679, 2, 1, 0xFF285A28
        dd 772, 679, 1, 1, 0xFF1E461E
        dd 760, 680, 2, 1, 0xFF1E461E
        dd 762, 680, 6, 1, 0xFF32783C
        dd 768, 680, 3, 1, 0xFF285A28
        dd 771, 680, 1, 1, 0xFF1E461E
        dd 762, 681, 8, 1, 0xFF1E461E
        dd 1123, 400, 6, 1, 0xFF1E461E
        dd 1121, 401, 2, 1, 0xFF1E461E
        dd 1123, 401, 6, 1, 0xFF32783C
        dd 1129, 401, 2, 1, 0xFF1E461E
        dd 1120, 402, 1, 1, 0xFF1E461E
        dd 1121, 402, 1, 1, 0xFF32783C
        dd 1122, 402, 2, 1, 0xFF46A064
        dd 1124, 402, 7, 1, 0xFF32783C
        dd 1131, 402, 1, 1, 0xFF1E461E
        dd 1119, 403, 1, 1, 0xFF1E461E
        dd 1120, 403, 1, 1, 0xFF32783C
        dd 1121, 403, 4, 1, 0xFF46A064
        dd 1125, 403, 3, 1, 0xFF32783C
        dd 1128, 403, 1, 1, 0xFF285A28
        dd 1129, 403, 3, 1, 0xFF32783C
        dd 1132, 403, 1, 1, 0xFF1E461E
        dd 1118, 404, 1, 1, 0xFF1E461E
        dd 1119, 404, 2, 1, 0xFF32783C
        dd 1121, 404, 3, 1, 0xFF46A064
        dd 1124, 404, 9, 1, 0xFF32783C
        dd 1133, 404, 1, 1, 0xFF1E461E
        dd 1117, 405, 1, 1, 0xFF1E461E
        dd 1118, 405, 3, 1, 0xFF32783C
        dd 1121, 405, 2, 1, 0xFF46A064
        dd 1123, 405, 4, 1, 0xFF32783C
        dd 1127, 405, 1, 1, 0xFF285A28
        dd 1128, 405, 6, 1, 0xFF32783C
        dd 1134, 405, 1, 1, 0xFF1E461E
        dd 1117, 406, 1, 1, 0xFF1E461E
        dd 1118, 406, 12, 1, 0xFF32783C
        dd 1130, 406, 2, 1, 0xFF46A064
        dd 1132, 406, 2, 1, 0xFF32783C
        dd 1134, 406, 1, 1, 0xFF1E461E
        dd 1116, 407, 1, 1, 0xFF1E461E
        dd 1117, 407, 1, 1, 0xFF32783C
        dd 1118, 407, 1, 1, 0xFF285A28
        dd 1119, 407, 6, 1, 0xFF32783C
        dd 1125, 407, 2, 1, 0xFF46A064
        dd 1127, 407, 2, 1, 0xFF32783C
        dd 1129, 407, 3, 1, 0xFF46A064
        dd 1132, 407, 3, 1, 0xFF32783C
        dd 1135, 407, 1, 1, 0xFF1E461E
        dd 1116, 408, 1, 1, 0xFF1E461E
        dd 1117, 408, 7, 1, 0xFF32783C
        dd 1124, 408, 3, 1, 0xFF46A064
        dd 1127, 408, 3, 1, 0xFF32783C
        dd 1130, 408, 1, 1, 0xFF46A064
        dd 1131, 408, 3, 1, 0xFF32783C
        dd 1134, 408, 1, 1, 0xFF285A28
        dd 1135, 408, 1, 1, 0xFF1E461E
        dd 1115, 409, 1, 1, 0xFF1E461E
        dd 1116, 409, 4, 1, 0xFF32783C
        dd 1120, 409, 1, 1, 0xFF46A064
        dd 1121, 409, 4, 1, 0xFF32783C
        dd 1125, 409, 2, 1, 0xFF46A064
        dd 1127, 409, 9, 1, 0xFF32783C
        dd 1136, 409, 1, 1, 0xFF1E461E
        dd 1115, 410, 1, 1, 0xFF1E461E
        dd 1116, 410, 3, 1, 0xFF32783C
        dd 1119, 410, 3, 1, 0xFF46A064
        dd 1122, 410, 8, 1, 0xFF32783C
        dd 1130, 410, 1, 1, 0xFF285A28
        dd 1131, 410, 5, 1, 0xFF32783C
        dd 1136, 410, 1, 1, 0xFF1E461E
        dd 1115, 411, 1, 1, 0xFF1E461E
        dd 1116, 411, 4, 1, 0xFF32783C
        dd 1120, 411, 1, 1, 0xFF46A064
        dd 1121, 411, 15, 1, 0xFF32783C
        dd 1136, 411, 1, 1, 0xFF1E461E
        dd 1115, 412, 1, 1, 0xFF1E461E
        dd 1116, 412, 8, 1, 0xFF32783C
        dd 1124, 412, 1, 1, 0xFF285A28
        dd 1125, 412, 4, 1, 0xFF32783C
        dd 1129, 412, 3, 1, 0xFF46A064
        dd 1132, 412, 3, 1, 0xFF32783C
        dd 1135, 412, 1, 1, 0xFF285A28
        dd 1136, 412, 1, 1, 0xFF1E461E
        dd 1115, 413, 1, 1, 0xFF1E461E
        dd 1116, 413, 2, 1, 0xFF32783C
        dd 1118, 413, 1, 1, 0xFF285A28
        dd 1119, 413, 11, 1, 0xFF32783C
        dd 1130, 413, 1, 1, 0xFF46A064
        dd 1131, 413, 5, 1, 0xFF32783C
        dd 1136, 413, 1, 1, 0xFF1E461E
        dd 1116, 414, 1, 1, 0xFF1E461E
        dd 1117, 414, 5, 1, 0xFF32783C
        dd 1122, 414, 2, 1, 0xFF46A064
        dd 1124, 414, 11, 1, 0xFF32783C
        dd 1135, 414, 1, 1, 0xFF1E461E
        dd 1116, 415, 1, 1, 0xFF1E461E
        dd 1117, 415, 4, 1, 0xFF32783C
        dd 1121, 415, 3, 1, 0xFF46A064
        dd 1124, 415, 4, 1, 0xFF32783C
        dd 1128, 415, 1, 1, 0xFF285A28
        dd 1129, 415, 5, 1, 0xFF32783C
        dd 1134, 415, 1, 1, 0xFF285A28
        dd 1135, 415, 1, 1, 0xFF1E461E
        dd 1117, 416, 1, 1, 0xFF1E461E
        dd 1118, 416, 4, 1, 0xFF32783C
        dd 1122, 416, 1, 1, 0xFF46A064
        dd 1123, 416, 10, 1, 0xFF32783C
        dd 1133, 416, 1, 1, 0xFF285A28
        dd 1134, 416, 1, 1, 0xFF1E461E
        dd 1117, 417, 1, 1, 0xFF1E461E
        dd 1118, 417, 9, 1, 0xFF32783C
        dd 1127, 417, 2, 1, 0xFF46A064
        dd 1129, 417, 3, 1, 0xFF32783C
        dd 1132, 417, 2, 1, 0xFF285A28
        dd 1134, 417, 1, 1, 0xFF1E461E
        dd 1118, 418, 1, 1, 0xFF1E461E
        dd 1119, 418, 2, 1, 0xFF32783C
        dd 1121, 418, 1, 1, 0xFF285A28
        dd 1122, 418, 5, 1, 0xFF32783C
        dd 1127, 418, 1, 1, 0xFF46A064
        dd 1128, 418, 4, 1, 0xFF32783C
        dd 1132, 418, 1, 1, 0xFF285A28
        dd 1133, 418, 1, 1, 0xFF1E461E
        dd 1119, 419, 1, 1, 0xFF1E461E
        dd 1120, 419, 10, 1, 0xFF32783C
        dd 1130, 419, 2, 1, 0xFF285A28
        dd 1132, 419, 1, 1, 0xFF1E461E
        dd 1120, 420, 2, 1, 0xFF1E461E
        dd 1122, 420, 6, 1, 0xFF32783C
        dd 1128, 420, 3, 1, 0xFF285A28
        dd 1131, 420, 1, 1, 0xFF1E461E
        dd 1122, 421, 8, 1, 0xFF1E461E
        dd 1158, 620, 6, 1, 0xFF1E461E
        dd 1156, 621, 2, 1, 0xFF1E461E
        dd 1158, 621, 6, 1, 0xFF32783C
        dd 1164, 621, 2, 1, 0xFF1E461E
        dd 1155, 622, 1, 1, 0xFF1E461E
        dd 1156, 622, 1, 1, 0xFF32783C
        dd 1157, 622, 2, 1, 0xFF46A064
        dd 1159, 622, 7, 1, 0xFF32783C
        dd 1166, 622, 1, 1, 0xFF1E461E
        dd 1154, 623, 1, 1, 0xFF1E461E
        dd 1155, 623, 1, 1, 0xFF32783C
        dd 1156, 623, 4, 1, 0xFF46A064
        dd 1160, 623, 3, 1, 0xFF32783C
        dd 1163, 623, 1, 1, 0xFF285A28
        dd 1164, 623, 3, 1, 0xFF32783C
        dd 1167, 623, 1, 1, 0xFF1E461E
        dd 1153, 624, 1, 1, 0xFF1E461E
        dd 1154, 624, 2, 1, 0xFF32783C
        dd 1156, 624, 3, 1, 0xFF46A064
        dd 1159, 624, 9, 1, 0xFF32783C
        dd 1168, 624, 1, 1, 0xFF1E461E
        dd 1152, 625, 1, 1, 0xFF1E461E
        dd 1153, 625, 3, 1, 0xFF32783C
        dd 1156, 625, 2, 1, 0xFF46A064
        dd 1158, 625, 4, 1, 0xFF32783C
        dd 1162, 625, 1, 1, 0xFF285A28
        dd 1163, 625, 6, 1, 0xFF32783C
        dd 1169, 625, 1, 1, 0xFF1E461E
        dd 1152, 626, 1, 1, 0xFF1E461E
        dd 1153, 626, 12, 1, 0xFF32783C
        dd 1165, 626, 2, 1, 0xFF46A064
        dd 1167, 626, 2, 1, 0xFF32783C
        dd 1169, 626, 1, 1, 0xFF1E461E
        dd 1151, 627, 1, 1, 0xFF1E461E
        dd 1152, 627, 1, 1, 0xFF32783C
        dd 1153, 627, 1, 1, 0xFF285A28
        dd 1154, 627, 6, 1, 0xFF32783C
        dd 1160, 627, 2, 1, 0xFF46A064
        dd 1162, 627, 2, 1, 0xFF32783C
        dd 1164, 627, 3, 1, 0xFF46A064
        dd 1167, 627, 3, 1, 0xFF32783C
        dd 1170, 627, 1, 1, 0xFF1E461E
        dd 1151, 628, 1, 1, 0xFF1E461E
        dd 1152, 628, 7, 1, 0xFF32783C
        dd 1159, 628, 3, 1, 0xFF46A064
        dd 1162, 628, 3, 1, 0xFF32783C
        dd 1165, 628, 1, 1, 0xFF46A064
        dd 1166, 628, 3, 1, 0xFF32783C
        dd 1169, 628, 1, 1, 0xFF285A28
        dd 1170, 628, 1, 1, 0xFF1E461E
        dd 1150, 629, 1, 1, 0xFF1E461E
        dd 1151, 629, 4, 1, 0xFF32783C
        dd 1155, 629, 1, 1, 0xFF46A064
        dd 1156, 629, 4, 1, 0xFF32783C
        dd 1160, 629, 2, 1, 0xFF46A064
        dd 1162, 629, 9, 1, 0xFF32783C
        dd 1171, 629, 1, 1, 0xFF1E461E
        dd 1150, 630, 1, 1, 0xFF1E461E
        dd 1151, 630, 3, 1, 0xFF32783C
        dd 1154, 630, 3, 1, 0xFF46A064
        dd 1157, 630, 8, 1, 0xFF32783C
        dd 1165, 630, 1, 1, 0xFF285A28
        dd 1166, 630, 5, 1, 0xFF32783C
        dd 1171, 630, 1, 1, 0xFF1E461E
        dd 1150, 631, 1, 1, 0xFF1E461E
        dd 1151, 631, 4, 1, 0xFF32783C
        dd 1155, 631, 1, 1, 0xFF46A064
        dd 1156, 631, 15, 1, 0xFF32783C
        dd 1171, 631, 1, 1, 0xFF1E461E
        dd 1150, 632, 1, 1, 0xFF1E461E
        dd 1151, 632, 8, 1, 0xFF32783C
        dd 1159, 632, 1, 1, 0xFF285A28
        dd 1160, 632, 4, 1, 0xFF32783C
        dd 1164, 632, 3, 1, 0xFF46A064
        dd 1167, 632, 3, 1, 0xFF32783C
        dd 1170, 632, 1, 1, 0xFF285A28
        dd 1171, 632, 1, 1, 0xFF1E461E
        dd 1150, 633, 1, 1, 0xFF1E461E
        dd 1151, 633, 2, 1, 0xFF32783C
        dd 1153, 633, 1, 1, 0xFF285A28
        dd 1154, 633, 11, 1, 0xFF32783C
        dd 1165, 633, 1, 1, 0xFF46A064
        dd 1166, 633, 5, 1, 0xFF32783C
        dd 1171, 633, 1, 1, 0xFF1E461E
        dd 1151, 634, 1, 1, 0xFF1E461E
        dd 1152, 634, 5, 1, 0xFF32783C
        dd 1157, 634, 2, 1, 0xFF46A064
        dd 1159, 634, 11, 1, 0xFF32783C
        dd 1170, 634, 1, 1, 0xFF1E461E
        dd 1151, 635, 1, 1, 0xFF1E461E
        dd 1152, 635, 4, 1, 0xFF32783C
        dd 1156, 635, 3, 1, 0xFF46A064
        dd 1159, 635, 4, 1, 0xFF32783C
        dd 1163, 635, 1, 1, 0xFF285A28
        dd 1164, 635, 5, 1, 0xFF32783C
        dd 1169, 635, 1, 1, 0xFF285A28
        dd 1170, 635, 1, 1, 0xFF1E461E
        dd 1152, 636, 1, 1, 0xFF1E461E
        dd 1153, 636, 4, 1, 0xFF32783C
        dd 1157, 636, 1, 1, 0xFF46A064
        dd 1158, 636, 10, 1, 0xFF32783C
        dd 1168, 636, 1, 1, 0xFF285A28
        dd 1169, 636, 1, 1, 0xFF1E461E
        dd 1152, 637, 1, 1, 0xFF1E461E
        dd 1153, 637, 9, 1, 0xFF32783C
        dd 1162, 637, 2, 1, 0xFF46A064
        dd 1164, 637, 3, 1, 0xFF32783C
        dd 1167, 637, 2, 1, 0xFF285A28
        dd 1169, 637, 1, 1, 0xFF1E461E
        dd 1153, 638, 1, 1, 0xFF1E461E
        dd 1154, 638, 2, 1, 0xFF32783C
        dd 1156, 638, 1, 1, 0xFF285A28
        dd 1157, 638, 5, 1, 0xFF32783C
        dd 1162, 638, 1, 1, 0xFF46A064
        dd 1163, 638, 4, 1, 0xFF32783C
        dd 1167, 638, 1, 1, 0xFF285A28
        dd 1168, 638, 1, 1, 0xFF1E461E
        dd 1154, 639, 1, 1, 0xFF1E461E
        dd 1155, 639, 10, 1, 0xFF32783C
        dd 1165, 639, 2, 1, 0xFF285A28
        dd 1167, 639, 1, 1, 0xFF1E461E
        dd 1155, 640, 2, 1, 0xFF1E461E
        dd 1157, 640, 6, 1, 0xFF32783C
        dd 1163, 640, 3, 1, 0xFF285A28
        dd 1166, 640, 1, 1, 0xFF1E461E
        dd 1157, 641, 8, 1, 0xFF1E461E
        dd 1258, 650, 6, 1, 0xFF1E461E
        dd 1256, 651, 2, 1, 0xFF1E461E
        dd 1258, 651, 6, 1, 0xFF32783C
        dd 1264, 651, 2, 1, 0xFF1E461E
        dd 1255, 652, 1, 1, 0xFF1E461E
        dd 1256, 652, 1, 1, 0xFF32783C
        dd 1257, 652, 2, 1, 0xFF46A064
        dd 1259, 652, 7, 1, 0xFF32783C
        dd 1266, 652, 1, 1, 0xFF1E461E
        dd 1254, 653, 1, 1, 0xFF1E461E
        dd 1255, 653, 1, 1, 0xFF32783C
        dd 1256, 653, 4, 1, 0xFF46A064
        dd 1260, 653, 3, 1, 0xFF32783C
        dd 1263, 653, 1, 1, 0xFF285A28
        dd 1264, 653, 3, 1, 0xFF32783C
        dd 1267, 653, 1, 1, 0xFF1E461E
        dd 1253, 654, 1, 1, 0xFF1E461E
        dd 1254, 654, 2, 1, 0xFF32783C
        dd 1256, 654, 3, 1, 0xFF46A064
        dd 1259, 654, 9, 1, 0xFF32783C
        dd 1268, 654, 1, 1, 0xFF1E461E
        dd 1252, 655, 1, 1, 0xFF1E461E
        dd 1253, 655, 3, 1, 0xFF32783C
        dd 1256, 655, 2, 1, 0xFF46A064
        dd 1258, 655, 4, 1, 0xFF32783C
        dd 1262, 655, 1, 1, 0xFF285A28
        dd 1263, 655, 6, 1, 0xFF32783C
        dd 1269, 655, 1, 1, 0xFF1E461E
        dd 1252, 656, 1, 1, 0xFF1E461E
        dd 1253, 656, 12, 1, 0xFF32783C
        dd 1265, 656, 2, 1, 0xFF46A064
        dd 1267, 656, 2, 1, 0xFF32783C
        dd 1269, 656, 1, 1, 0xFF1E461E
        dd 1251, 657, 1, 1, 0xFF1E461E
        dd 1252, 657, 1, 1, 0xFF32783C
        dd 1253, 657, 1, 1, 0xFF285A28
        dd 1254, 657, 6, 1, 0xFF32783C
        dd 1260, 657, 2, 1, 0xFF46A064
        dd 1262, 657, 2, 1, 0xFF32783C
        dd 1264, 657, 3, 1, 0xFF46A064
        dd 1267, 657, 3, 1, 0xFF32783C
        dd 1270, 657, 1, 1, 0xFF1E461E
        dd 1251, 658, 1, 1, 0xFF1E461E
        dd 1252, 658, 7, 1, 0xFF32783C
        dd 1259, 658, 3, 1, 0xFF46A064
        dd 1262, 658, 3, 1, 0xFF32783C
        dd 1265, 658, 1, 1, 0xFF46A064
        dd 1266, 658, 3, 1, 0xFF32783C
        dd 1269, 658, 1, 1, 0xFF285A28
        dd 1270, 658, 1, 1, 0xFF1E461E
        dd 1250, 659, 1, 1, 0xFF1E461E
        dd 1251, 659, 4, 1, 0xFF32783C
        dd 1255, 659, 1, 1, 0xFF46A064
        dd 1256, 659, 4, 1, 0xFF32783C
        dd 1260, 659, 2, 1, 0xFF46A064
        dd 1262, 659, 9, 1, 0xFF32783C
        dd 1271, 659, 1, 1, 0xFF1E461E
        dd 1250, 660, 1, 1, 0xFF1E461E
        dd 1251, 660, 3, 1, 0xFF32783C
        dd 1254, 660, 3, 1, 0xFF46A064
        dd 1257, 660, 8, 1, 0xFF32783C
        dd 1265, 660, 1, 1, 0xFF285A28
        dd 1266, 660, 5, 1, 0xFF32783C
        dd 1271, 660, 1, 1, 0xFF1E461E
        dd 1250, 661, 1, 1, 0xFF1E461E
        dd 1251, 661, 4, 1, 0xFF32783C
        dd 1255, 661, 1, 1, 0xFF46A064
        dd 1256, 661, 15, 1, 0xFF32783C
        dd 1271, 661, 1, 1, 0xFF1E461E
        dd 1250, 662, 1, 1, 0xFF1E461E
        dd 1251, 662, 8, 1, 0xFF32783C
        dd 1259, 662, 1, 1, 0xFF285A28
        dd 1260, 662, 4, 1, 0xFF32783C
        dd 1264, 662, 3, 1, 0xFF46A064
        dd 1267, 662, 3, 1, 0xFF32783C
        dd 1270, 662, 1, 1, 0xFF285A28
        dd 1271, 662, 1, 1, 0xFF1E461E
        dd 1250, 663, 1, 1, 0xFF1E461E
        dd 1251, 663, 2, 1, 0xFF32783C
        dd 1253, 663, 1, 1, 0xFF285A28
        dd 1254, 663, 11, 1, 0xFF32783C
        dd 1265, 663, 1, 1, 0xFF46A064
        dd 1266, 663, 5, 1, 0xFF32783C
        dd 1271, 663, 1, 1, 0xFF1E461E
        dd 1251, 664, 1, 1, 0xFF1E461E
        dd 1252, 664, 5, 1, 0xFF32783C
        dd 1257, 664, 2, 1, 0xFF46A064
        dd 1259, 664, 11, 1, 0xFF32783C
        dd 1270, 664, 1, 1, 0xFF1E461E
        dd 1251, 665, 1, 1, 0xFF1E461E
        dd 1252, 665, 4, 1, 0xFF32783C
        dd 1256, 665, 3, 1, 0xFF46A064
        dd 1259, 665, 4, 1, 0xFF32783C
        dd 1263, 665, 1, 1, 0xFF285A28
        dd 1264, 665, 5, 1, 0xFF32783C
        dd 1269, 665, 1, 1, 0xFF285A28
        dd 1270, 665, 1, 1, 0xFF1E461E
        dd 1252, 666, 1, 1, 0xFF1E461E
        dd 1253, 666, 4, 1, 0xFF32783C
        dd 1257, 666, 1, 1, 0xFF46A064
        dd 1258, 666, 10, 1, 0xFF32783C
        dd 1268, 666, 1, 1, 0xFF285A28
        dd 1269, 666, 1, 1, 0xFF1E461E
        dd 1252, 667, 1, 1, 0xFF1E461E
        dd 1253, 667, 9, 1, 0xFF32783C
        dd 1262, 667, 2, 1, 0xFF46A064
        dd 1264, 667, 3, 1, 0xFF32783C
        dd 1267, 667, 2, 1, 0xFF285A28
        dd 1269, 667, 1, 1, 0xFF1E461E
        dd 1253, 668, 1, 1, 0xFF1E461E
        dd 1254, 668, 2, 1, 0xFF32783C
        dd 1256, 668, 1, 1, 0xFF285A28
        dd 1257, 668, 5, 1, 0xFF32783C
        dd 1262, 668, 1, 1, 0xFF46A064
        dd 1263, 668, 4, 1, 0xFF32783C
        dd 1267, 668, 1, 1, 0xFF285A28
        dd 1268, 668, 1, 1, 0xFF1E461E
        dd 1254, 669, 1, 1, 0xFF1E461E
        dd 1255, 669, 10, 1, 0xFF32783C
        dd 1265, 669, 2, 1, 0xFF285A28
        dd 1267, 669, 1, 1, 0xFF1E461E
        dd 1255, 670, 2, 1, 0xFF1E461E
        dd 1257, 670, 6, 1, 0xFF32783C
        dd 1263, 670, 3, 1, 0xFF285A28
        dd 1266, 670, 1, 1, 0xFF1E461E
        dd 1257, 671, 8, 1, 0xFF1E461E
        dd 11, 300, 4, 1, 0xFF1E461E
        dd 10, 301, 1, 1, 0xFF1E461E
        dd 11, 301, 1, 1, 0xFF46A064
        dd 12, 301, 3, 1, 0xFF32783C
        dd 15, 301, 1, 1, 0xFF1E461E
        dd 9, 302, 1, 1, 0xFF1E461E
        dd 10, 302, 2, 1, 0xFF46A064
        dd 12, 302, 2, 1, 0xFF32783C
        dd 14, 302, 1, 1, 0xFF285A28
        dd 15, 302, 1, 1, 0xFF32783C
        dd 16, 302, 1, 1, 0xFF1E461E
        dd 8, 303, 1, 1, 0xFF1E461E
        dd 9, 303, 1, 1, 0xFF32783C
        dd 10, 303, 1, 1, 0xFF46A064
        dd 11, 303, 5, 1, 0xFF32783C
        dd 16, 303, 1, 1, 0xFF285A28
        dd 17, 303, 1, 1, 0xFF1E461E
        dd 8, 304, 1, 1, 0xFF1E461E
        dd 9, 304, 4, 1, 0xFF32783C
        dd 13, 304, 1, 1, 0xFF285A28
        dd 14, 304, 2, 1, 0xFF32783C
        dd 16, 304, 1, 1, 0xFF285A28
        dd 17, 304, 1, 1, 0xFF1E461E
        dd 8, 305, 1, 1, 0xFF1E461E
        dd 9, 305, 7, 1, 0xFF32783C
        dd 16, 305, 1, 1, 0xFF285A28
        dd 17, 305, 1, 1, 0xFF1E461E
        dd 9, 306, 1, 1, 0xFF1E461E
        dd 10, 306, 2, 1, 0xFF32783C
        dd 12, 306, 1, 1, 0xFF285A28
        dd 13, 306, 2, 1, 0xFF32783C
        dd 15, 306, 2, 1, 0xFF285A28
        dd 17, 306, 1, 1, 0xFF1E461E
        dd 9, 307, 1, 1, 0xFF1E461E
        dd 10, 307, 5, 1, 0xFF32783C
        dd 15, 307, 1, 1, 0xFF285A28
        dd 16, 307, 1, 1, 0xFF1E461E
        dd 10, 308, 2, 1, 0xFF1E461E
        dd 12, 308, 2, 1, 0xFF285A28
        dd 14, 308, 2, 1, 0xFF1E461E
        dd 12, 309, 2, 1, 0xFF1E461E
        dd 278, 160, 4, 1, 0xFF1E461E
        dd 277, 161, 1, 1, 0xFF1E461E
        dd 278, 161, 1, 1, 0xFF46A064
        dd 279, 161, 3, 1, 0xFF32783C
        dd 282, 161, 1, 1, 0xFF1E461E
        dd 276, 162, 1, 1, 0xFF1E461E
        dd 277, 162, 2, 1, 0xFF46A064
        dd 279, 162, 2, 1, 0xFF32783C
        dd 281, 162, 1, 1, 0xFF285A28
        dd 282, 162, 1, 1, 0xFF32783C
        dd 283, 162, 1, 1, 0xFF1E461E
        dd 275, 163, 1, 1, 0xFF1E461E
        dd 276, 163, 1, 1, 0xFF32783C
        dd 277, 163, 1, 1, 0xFF46A064
        dd 278, 163, 5, 1, 0xFF32783C
        dd 283, 163, 1, 1, 0xFF285A28
        dd 284, 163, 1, 1, 0xFF1E461E
        dd 275, 164, 1, 1, 0xFF1E461E
        dd 276, 164, 4, 1, 0xFF32783C
        dd 280, 164, 1, 1, 0xFF285A28
        dd 281, 164, 2, 1, 0xFF32783C
        dd 283, 164, 1, 1, 0xFF285A28
        dd 284, 164, 1, 1, 0xFF1E461E
        dd 275, 165, 1, 1, 0xFF1E461E
        dd 276, 165, 7, 1, 0xFF32783C
        dd 283, 165, 1, 1, 0xFF285A28
        dd 284, 165, 1, 1, 0xFF1E461E
        dd 276, 166, 1, 1, 0xFF1E461E
        dd 277, 166, 2, 1, 0xFF32783C
        dd 279, 166, 1, 1, 0xFF285A28
        dd 280, 166, 2, 1, 0xFF32783C
        dd 282, 166, 2, 1, 0xFF285A28
        dd 284, 166, 1, 1, 0xFF1E461E
        dd 276, 167, 1, 1, 0xFF1E461E
        dd 277, 167, 5, 1, 0xFF32783C
        dd 282, 167, 1, 1, 0xFF285A28
        dd 283, 167, 1, 1, 0xFF1E461E
        dd 277, 168, 2, 1, 0xFF1E461E
        dd 279, 168, 2, 1, 0xFF285A28
        dd 281, 168, 2, 1, 0xFF1E461E
        dd 279, 169, 2, 1, 0xFF1E461E
        dd 608, 183, 4, 1, 0xFF1E461E
        dd 607, 184, 1, 1, 0xFF1E461E
        dd 608, 184, 1, 1, 0xFF46A064
        dd 609, 184, 3, 1, 0xFF32783C
        dd 612, 184, 1, 1, 0xFF1E461E
        dd 606, 185, 1, 1, 0xFF1E461E
        dd 607, 185, 2, 1, 0xFF46A064
        dd 609, 185, 2, 1, 0xFF32783C
        dd 611, 185, 1, 1, 0xFF285A28
        dd 612, 185, 1, 1, 0xFF32783C
        dd 613, 185, 1, 1, 0xFF1E461E
        dd 605, 186, 1, 1, 0xFF1E461E
        dd 606, 186, 1, 1, 0xFF32783C
        dd 607, 186, 1, 1, 0xFF46A064
        dd 608, 186, 5, 1, 0xFF32783C
        dd 613, 186, 1, 1, 0xFF285A28
        dd 614, 186, 1, 1, 0xFF1E461E
        dd 605, 187, 1, 1, 0xFF1E461E
        dd 606, 187, 4, 1, 0xFF32783C
        dd 610, 187, 1, 1, 0xFF285A28
        dd 611, 187, 2, 1, 0xFF32783C
        dd 613, 187, 1, 1, 0xFF285A28
        dd 614, 187, 1, 1, 0xFF1E461E
        dd 605, 188, 1, 1, 0xFF1E461E
        dd 606, 188, 7, 1, 0xFF32783C
        dd 613, 188, 1, 1, 0xFF285A28
        dd 614, 188, 1, 1, 0xFF1E461E
        dd 606, 189, 1, 1, 0xFF1E461E
        dd 607, 189, 2, 1, 0xFF32783C
        dd 609, 189, 1, 1, 0xFF285A28
        dd 610, 189, 2, 1, 0xFF32783C
        dd 612, 189, 2, 1, 0xFF285A28
        dd 614, 189, 1, 1, 0xFF1E461E
        dd 606, 190, 1, 1, 0xFF1E461E
        dd 607, 190, 5, 1, 0xFF32783C
        dd 612, 190, 1, 1, 0xFF285A28
        dd 613, 190, 1, 1, 0xFF1E461E
        dd 607, 191, 2, 1, 0xFF1E461E
        dd 609, 191, 2, 1, 0xFF285A28
        dd 611, 191, 2, 1, 0xFF1E461E
        dd 609, 192, 2, 1, 0xFF1E461E
        dd 1253, 290, 4, 1, 0xFF1E461E
        dd 1252, 291, 1, 1, 0xFF1E461E
        dd 1253, 291, 1, 1, 0xFF46A064
        dd 1254, 291, 3, 1, 0xFF32783C
        dd 1257, 291, 1, 1, 0xFF1E461E
        dd 1251, 292, 1, 1, 0xFF1E461E
        dd 1252, 292, 2, 1, 0xFF46A064
        dd 1254, 292, 2, 1, 0xFF32783C
        dd 1256, 292, 1, 1, 0xFF285A28
        dd 1257, 292, 1, 1, 0xFF32783C
        dd 1258, 292, 1, 1, 0xFF1E461E
        dd 1250, 293, 1, 1, 0xFF1E461E
        dd 1251, 293, 1, 1, 0xFF32783C
        dd 1252, 293, 1, 1, 0xFF46A064
        dd 1253, 293, 5, 1, 0xFF32783C
        dd 1258, 293, 1, 1, 0xFF285A28
        dd 1259, 293, 1, 1, 0xFF1E461E
        dd 1250, 294, 1, 1, 0xFF1E461E
        dd 1251, 294, 4, 1, 0xFF32783C
        dd 1255, 294, 1, 1, 0xFF285A28
        dd 1256, 294, 2, 1, 0xFF32783C
        dd 1258, 294, 1, 1, 0xFF285A28
        dd 1259, 294, 1, 1, 0xFF1E461E
        dd 1250, 295, 1, 1, 0xFF1E461E
        dd 1251, 295, 7, 1, 0xFF32783C
        dd 1258, 295, 1, 1, 0xFF285A28
        dd 1259, 295, 1, 1, 0xFF1E461E
        dd 1251, 296, 1, 1, 0xFF1E461E
        dd 1252, 296, 2, 1, 0xFF32783C
        dd 1254, 296, 1, 1, 0xFF285A28
        dd 1255, 296, 2, 1, 0xFF32783C
        dd 1257, 296, 2, 1, 0xFF285A28
        dd 1259, 296, 1, 1, 0xFF1E461E
        dd 1251, 297, 1, 1, 0xFF1E461E
        dd 1252, 297, 5, 1, 0xFF32783C
        dd 1257, 297, 1, 1, 0xFF285A28
        dd 1258, 297, 1, 1, 0xFF1E461E
        dd 1252, 298, 2, 1, 0xFF1E461E
        dd 1254, 298, 2, 1, 0xFF285A28
        dd 1256, 298, 2, 1, 0xFF1E461E
        dd 1254, 299, 2, 1, 0xFF1E461E
        dd 965, 405, 4, 1, 0xFF1E461E
        dd 964, 406, 1, 1, 0xFF1E461E
        dd 965, 406, 1, 1, 0xFF46A064
        dd 966, 406, 3, 1, 0xFF32783C
        dd 969, 406, 1, 1, 0xFF1E461E
        dd 963, 407, 1, 1, 0xFF1E461E
        dd 964, 407, 2, 1, 0xFF46A064
        dd 966, 407, 2, 1, 0xFF32783C
        dd 968, 407, 1, 1, 0xFF285A28
        dd 969, 407, 1, 1, 0xFF32783C
        dd 970, 407, 1, 1, 0xFF1E461E
        dd 962, 408, 1, 1, 0xFF1E461E
        dd 963, 408, 1, 1, 0xFF32783C
        dd 964, 408, 1, 1, 0xFF46A064
        dd 965, 408, 5, 1, 0xFF32783C
        dd 970, 408, 1, 1, 0xFF285A28
        dd 971, 408, 1, 1, 0xFF1E461E
        dd 962, 409, 1, 1, 0xFF1E461E
        dd 963, 409, 4, 1, 0xFF32783C
        dd 967, 409, 1, 1, 0xFF285A28
        dd 968, 409, 2, 1, 0xFF32783C
        dd 970, 409, 1, 1, 0xFF285A28
        dd 971, 409, 1, 1, 0xFF1E461E
        dd 962, 410, 1, 1, 0xFF1E461E
        dd 963, 410, 7, 1, 0xFF32783C
        dd 970, 410, 1, 1, 0xFF285A28
        dd 971, 410, 1, 1, 0xFF1E461E
        dd 963, 411, 1, 1, 0xFF1E461E
        dd 964, 411, 2, 1, 0xFF32783C
        dd 966, 411, 1, 1, 0xFF285A28
        dd 967, 411, 2, 1, 0xFF32783C
        dd 969, 411, 2, 1, 0xFF285A28
        dd 971, 411, 1, 1, 0xFF1E461E
        dd 963, 412, 1, 1, 0xFF1E461E
        dd 964, 412, 5, 1, 0xFF32783C
        dd 969, 412, 1, 1, 0xFF285A28
        dd 970, 412, 1, 1, 0xFF1E461E
        dd 964, 413, 2, 1, 0xFF1E461E
        dd 966, 413, 2, 1, 0xFF285A28
        dd 968, 413, 2, 1, 0xFF1E461E
        dd 966, 414, 2, 1, 0xFF1E461E
        dd 543, 402, 4, 1, 0xFF1E461E
        dd 542, 403, 1, 1, 0xFF1E461E
        dd 543, 403, 1, 1, 0xFF46A064
        dd 544, 403, 3, 1, 0xFF32783C
        dd 547, 403, 1, 1, 0xFF1E461E
        dd 541, 404, 1, 1, 0xFF1E461E
        dd 542, 404, 2, 1, 0xFF46A064
        dd 544, 404, 2, 1, 0xFF32783C
        dd 546, 404, 1, 1, 0xFF285A28
        dd 547, 404, 1, 1, 0xFF32783C
        dd 548, 404, 1, 1, 0xFF1E461E
        dd 540, 405, 1, 1, 0xFF1E461E
        dd 541, 405, 1, 1, 0xFF32783C
        dd 542, 405, 1, 1, 0xFF46A064
        dd 543, 405, 5, 1, 0xFF32783C
        dd 548, 405, 1, 1, 0xFF285A28
        dd 549, 405, 1, 1, 0xFF1E461E
        dd 540, 406, 1, 1, 0xFF1E461E
        dd 541, 406, 4, 1, 0xFF32783C
        dd 545, 406, 1, 1, 0xFF285A28
        dd 546, 406, 2, 1, 0xFF32783C
        dd 548, 406, 1, 1, 0xFF285A28
        dd 549, 406, 1, 1, 0xFF1E461E
        dd 540, 407, 1, 1, 0xFF1E461E
        dd 541, 407, 7, 1, 0xFF32783C
        dd 548, 407, 1, 1, 0xFF285A28
        dd 549, 407, 1, 1, 0xFF1E461E
        dd 541, 408, 1, 1, 0xFF1E461E
        dd 542, 408, 2, 1, 0xFF32783C
        dd 544, 408, 1, 1, 0xFF285A28
        dd 545, 408, 2, 1, 0xFF32783C
        dd 547, 408, 2, 1, 0xFF285A28
        dd 549, 408, 1, 1, 0xFF1E461E
        dd 541, 409, 1, 1, 0xFF1E461E
        dd 542, 409, 5, 1, 0xFF32783C
        dd 547, 409, 1, 1, 0xFF285A28
        dd 548, 409, 1, 1, 0xFF1E461E
        dd 542, 410, 2, 1, 0xFF1E461E
        dd 544, 410, 2, 1, 0xFF285A28
        dd 546, 410, 2, 1, 0xFF1E461E
        dd 544, 411, 2, 1, 0xFF1E461E
        dd 883, 560, 4, 1, 0xFF1E461E
        dd 882, 561, 1, 1, 0xFF1E461E
        dd 883, 561, 1, 1, 0xFF46A064
        dd 884, 561, 3, 1, 0xFF32783C
        dd 887, 561, 1, 1, 0xFF1E461E
        dd 881, 562, 1, 1, 0xFF1E461E
        dd 882, 562, 2, 1, 0xFF46A064
        dd 884, 562, 2, 1, 0xFF32783C
        dd 886, 562, 1, 1, 0xFF285A28
        dd 887, 562, 1, 1, 0xFF32783C
        dd 888, 562, 1, 1, 0xFF1E461E
        dd 880, 563, 1, 1, 0xFF1E461E
        dd 881, 563, 1, 1, 0xFF32783C
        dd 882, 563, 1, 1, 0xFF46A064
        dd 883, 563, 5, 1, 0xFF32783C
        dd 888, 563, 1, 1, 0xFF285A28
        dd 889, 563, 1, 1, 0xFF1E461E
        dd 880, 564, 1, 1, 0xFF1E461E
        dd 881, 564, 4, 1, 0xFF32783C
        dd 885, 564, 1, 1, 0xFF285A28
        dd 886, 564, 2, 1, 0xFF32783C
        dd 888, 564, 1, 1, 0xFF285A28
        dd 889, 564, 1, 1, 0xFF1E461E
        dd 880, 565, 1, 1, 0xFF1E461E
        dd 881, 565, 7, 1, 0xFF32783C
        dd 888, 565, 1, 1, 0xFF285A28
        dd 889, 565, 1, 1, 0xFF1E461E
        dd 881, 566, 1, 1, 0xFF1E461E
        dd 882, 566, 2, 1, 0xFF32783C
        dd 884, 566, 1, 1, 0xFF285A28
        dd 885, 566, 2, 1, 0xFF32783C
        dd 887, 566, 2, 1, 0xFF285A28
        dd 889, 566, 1, 1, 0xFF1E461E
        dd 881, 567, 1, 1, 0xFF1E461E
        dd 882, 567, 5, 1, 0xFF32783C
        dd 887, 567, 1, 1, 0xFF285A28
        dd 888, 567, 1, 1, 0xFF1E461E
        dd 882, 568, 2, 1, 0xFF1E461E
        dd 884, 568, 2, 1, 0xFF285A28
        dd 886, 568, 2, 1, 0xFF1E461E
        dd 884, 569, 2, 1, 0xFF1E461E
        dd 135, 305, 4, 1, 0xFF1E461E
        dd 134, 306, 1, 1, 0xFF1E461E
        dd 135, 306, 1, 1, 0xFF46A064
        dd 136, 306, 3, 1, 0xFF32783C
        dd 139, 306, 1, 1, 0xFF1E461E
        dd 133, 307, 1, 1, 0xFF1E461E
        dd 134, 307, 2, 1, 0xFF46A064
        dd 136, 307, 2, 1, 0xFF32783C
        dd 138, 307, 1, 1, 0xFF285A28
        dd 139, 307, 1, 1, 0xFF32783C
        dd 140, 307, 1, 1, 0xFF1E461E
        dd 132, 308, 1, 1, 0xFF1E461E
        dd 133, 308, 1, 1, 0xFF32783C
        dd 134, 308, 1, 1, 0xFF46A064
        dd 135, 308, 5, 1, 0xFF32783C
        dd 140, 308, 1, 1, 0xFF285A28
        dd 141, 308, 1, 1, 0xFF1E461E
        dd 132, 309, 1, 1, 0xFF1E461E
        dd 133, 309, 4, 1, 0xFF32783C
        dd 137, 309, 1, 1, 0xFF285A28
        dd 138, 309, 2, 1, 0xFF32783C
        dd 140, 309, 1, 1, 0xFF285A28
        dd 141, 309, 1, 1, 0xFF1E461E
        dd 132, 310, 1, 1, 0xFF1E461E
        dd 133, 310, 7, 1, 0xFF32783C
        dd 140, 310, 1, 1, 0xFF285A28
        dd 141, 310, 1, 1, 0xFF1E461E
        dd 133, 311, 1, 1, 0xFF1E461E
        dd 134, 311, 2, 1, 0xFF32783C
        dd 136, 311, 1, 1, 0xFF285A28
        dd 137, 311, 2, 1, 0xFF32783C
        dd 139, 311, 2, 1, 0xFF285A28
        dd 141, 311, 1, 1, 0xFF1E461E
        dd 133, 312, 1, 1, 0xFF1E461E
        dd 134, 312, 5, 1, 0xFF32783C
        dd 139, 312, 1, 1, 0xFF285A28
        dd 140, 312, 1, 1, 0xFF1E461E
        dd 134, 313, 2, 1, 0xFF1E461E
        dd 136, 313, 2, 1, 0xFF285A28
        dd 138, 313, 2, 1, 0xFF1E461E
        dd 136, 314, 2, 1, 0xFF1E461E
        dd 62, 321, 4, 1, 0xFF413C3C
        dd 61, 322, 1, 1, 0xFF413C3C
        dd 62, 322, 4, 1, 0xFFBEF0FA
        dd 66, 322, 1, 1, 0xFF413C3C
        dd 61, 323, 1, 1, 0xFF413C3C
        dd 62, 323, 4, 1, 0xFFBEF0FA
        dd 66, 323, 1, 1, 0xFF413C3C
        dd 62, 324, 4, 1, 0xFF413C3C
        dd 63, 325, 2, 1, 0xFF7D7878
        dd 63, 326, 2, 1, 0xFF7D7878
        dd 62, 327, 4, 1, 0xFF5F5A5A
        dd 62, 328, 4, 1, 0xFF5F5A5A
        dd 222, 321, 4, 1, 0xFF413C3C
        dd 221, 322, 1, 1, 0xFF413C3C
        dd 222, 322, 4, 1, 0xFFBEF0FA
        dd 226, 322, 1, 1, 0xFF413C3C
        dd 221, 323, 1, 1, 0xFF413C3C
        dd 222, 323, 4, 1, 0xFFBEF0FA
        dd 226, 323, 1, 1, 0xFF413C3C
        dd 222, 324, 4, 1, 0xFF413C3C
        dd 223, 325, 2, 1, 0xFF7D7878
        dd 223, 326, 2, 1, 0xFF7D7878
        dd 222, 327, 4, 1, 0xFF5F5A5A
        dd 222, 328, 4, 1, 0xFF5F5A5A
        dd 462, 321, 4, 1, 0xFF413C3C
        dd 461, 322, 1, 1, 0xFF413C3C
        dd 462, 322, 4, 1, 0xFFBEF0FA
        dd 466, 322, 1, 1, 0xFF413C3C
        dd 461, 323, 1, 1, 0xFF413C3C
        dd 462, 323, 4, 1, 0xFFBEF0FA
        dd 466, 323, 1, 1, 0xFF413C3C
        dd 462, 324, 4, 1, 0xFF413C3C
        dd 463, 325, 2, 1, 0xFF7D7878
        dd 463, 326, 2, 1, 0xFF7D7878
        dd 462, 327, 4, 1, 0xFF5F5A5A
        dd 462, 328, 4, 1, 0xFF5F5A5A
        dd 622, 321, 4, 1, 0xFF413C3C
        dd 621, 322, 1, 1, 0xFF413C3C
        dd 622, 322, 4, 1, 0xFFBEF0FA
        dd 626, 322, 1, 1, 0xFF413C3C
        dd 621, 323, 1, 1, 0xFF413C3C
        dd 622, 323, 4, 1, 0xFFBEF0FA
        dd 626, 323, 1, 1, 0xFF413C3C
        dd 622, 324, 4, 1, 0xFF413C3C
        dd 623, 325, 2, 1, 0xFF7D7878
        dd 623, 326, 2, 1, 0xFF7D7878
        dd 622, 327, 4, 1, 0xFF5F5A5A
        dd 622, 328, 4, 1, 0xFF5F5A5A
        dd 782, 321, 4, 1, 0xFF413C3C
        dd 781, 322, 1, 1, 0xFF413C3C
        dd 782, 322, 4, 1, 0xFFBEF0FA
        dd 786, 322, 1, 1, 0xFF413C3C
        dd 781, 323, 1, 1, 0xFF413C3C
        dd 782, 323, 4, 1, 0xFFBEF0FA
        dd 786, 323, 1, 1, 0xFF413C3C
        dd 782, 324, 4, 1, 0xFF413C3C
        dd 783, 325, 2, 1, 0xFF7D7878
        dd 783, 326, 2, 1, 0xFF7D7878
        dd 782, 327, 4, 1, 0xFF5F5A5A
        dd 782, 328, 4, 1, 0xFF5F5A5A
        dd 1042, 321, 4, 1, 0xFF413C3C
        dd 1041, 322, 1, 1, 0xFF413C3C
        dd 1042, 322, 4, 1, 0xFFBEF0FA
        dd 1046, 322, 1, 1, 0xFF413C3C
        dd 1041, 323, 1, 1, 0xFF413C3C
        dd 1042, 323, 4, 1, 0xFFBEF0FA
        dd 1046, 323, 1, 1, 0xFF413C3C
        dd 1042, 324, 4, 1, 0xFF413C3C
        dd 1043, 325, 2, 1, 0xFF7D7878
        dd 1043, 326, 2, 1, 0xFF7D7878
        dd 1042, 327, 4, 1, 0xFF5F5A5A
        dd 1042, 328, 4, 1, 0xFF5F5A5A
        dd 1202, 321, 4, 1, 0xFF413C3C
        dd 1201, 322, 1, 1, 0xFF413C3C
        dd 1202, 322, 4, 1, 0xFFBEF0FA
        dd 1206, 322, 1, 1, 0xFF413C3C
        dd 1201, 323, 1, 1, 0xFF413C3C
        dd 1202, 323, 4, 1, 0xFFBEF0FA
        dd 1206, 323, 1, 1, 0xFF413C3C
        dd 1202, 324, 4, 1, 0xFF413C3C
        dd 1203, 325, 2, 1, 0xFF7D7878
        dd 1203, 326, 2, 1, 0xFF7D7878
        dd 1202, 327, 4, 1, 0xFF5F5A5A
        dd 1202, 328, 4, 1, 0xFF5F5A5A
        dd 142, 391, 4, 1, 0xFF413C3C
        dd 141, 392, 1, 1, 0xFF413C3C
        dd 142, 392, 4, 1, 0xFFBEF0FA
        dd 146, 392, 1, 1, 0xFF413C3C
        dd 141, 393, 1, 1, 0xFF413C3C
        dd 142, 393, 4, 1, 0xFFBEF0FA
        dd 146, 393, 1, 1, 0xFF413C3C
        dd 142, 394, 4, 1, 0xFF413C3C
        dd 143, 395, 2, 1, 0xFF7D7878
        dd 143, 396, 2, 1, 0xFF7D7878
        dd 142, 397, 4, 1, 0xFF5F5A5A
        dd 142, 398, 4, 1, 0xFF5F5A5A
        dd 542, 391, 4, 1, 0xFF413C3C
        dd 541, 392, 1, 1, 0xFF413C3C
        dd 542, 392, 4, 1, 0xFFBEF0FA
        dd 546, 392, 1, 1, 0xFF413C3C
        dd 541, 393, 1, 1, 0xFF413C3C
        dd 542, 393, 4, 1, 0xFFBEF0FA
        dd 546, 393, 1, 1, 0xFF413C3C
        dd 542, 394, 4, 1, 0xFF413C3C
        dd 543, 395, 2, 1, 0xFF7D7878
        dd 543, 396, 2, 1, 0xFF7D7878
        dd 542, 397, 4, 1, 0xFF5F5A5A
        dd 542, 398, 4, 1, 0xFF5F5A5A
        dd 702, 391, 4, 1, 0xFF413C3C
        dd 701, 392, 1, 1, 0xFF413C3C
        dd 702, 392, 4, 1, 0xFFBEF0FA
        dd 706, 392, 1, 1, 0xFF413C3C
        dd 701, 393, 1, 1, 0xFF413C3C
        dd 702, 393, 4, 1, 0xFFBEF0FA
        dd 706, 393, 1, 1, 0xFF413C3C
        dd 702, 394, 4, 1, 0xFF413C3C
        dd 703, 395, 2, 1, 0xFF7D7878
        dd 703, 396, 2, 1, 0xFF7D7878
        dd 702, 397, 4, 1, 0xFF5F5A5A
        dd 702, 398, 4, 1, 0xFF5F5A5A
        dd 862, 391, 4, 1, 0xFF413C3C
        dd 861, 392, 1, 1, 0xFF413C3C
        dd 862, 392, 4, 1, 0xFFBEF0FA
        dd 866, 392, 1, 1, 0xFF413C3C
        dd 861, 393, 1, 1, 0xFF413C3C
        dd 862, 393, 4, 1, 0xFFBEF0FA
        dd 866, 393, 1, 1, 0xFF413C3C
        dd 862, 394, 4, 1, 0xFF413C3C
        dd 863, 395, 2, 1, 0xFF7D7878
        dd 863, 396, 2, 1, 0xFF7D7878
        dd 862, 397, 4, 1, 0xFF5F5A5A
        dd 862, 398, 4, 1, 0xFF5F5A5A
        dd 1002, 391, 4, 1, 0xFF413C3C
        dd 1001, 392, 1, 1, 0xFF413C3C
        dd 1002, 392, 4, 1, 0xFFBEF0FA
        dd 1006, 392, 1, 1, 0xFF413C3C
        dd 1001, 393, 1, 1, 0xFF413C3C
        dd 1002, 393, 4, 1, 0xFFBEF0FA
        dd 1006, 393, 1, 1, 0xFF413C3C
        dd 1002, 394, 4, 1, 0xFF413C3C
        dd 1003, 395, 2, 1, 0xFF7D7878
        dd 1003, 396, 2, 1, 0xFF7D7878
        dd 1002, 397, 4, 1, 0xFF5F5A5A
        dd 1002, 398, 4, 1, 0xFF5F5A5A
        dd 1162, 391, 4, 1, 0xFF413C3C
        dd 1161, 392, 1, 1, 0xFF413C3C
        dd 1162, 392, 4, 1, 0xFFBEF0FA
        dd 1166, 392, 1, 1, 0xFF413C3C
        dd 1161, 393, 1, 1, 0xFF413C3C
        dd 1162, 393, 4, 1, 0xFFBEF0FA
        dd 1166, 393, 1, 1, 0xFF413C3C
        dd 1162, 394, 4, 1, 0xFF413C3C
        dd 1163, 395, 2, 1, 0xFF7D7878
        dd 1163, 396, 2, 1, 0xFF7D7878
        dd 1162, 397, 4, 1, 0xFF5F5A5A
        dd 1162, 398, 4, 1, 0xFF5F5A5A
        dd 293, 150, 4, 1, 0xFF413C3C
        dd 292, 151, 1, 1, 0xFF413C3C
        dd 293, 151, 4, 1, 0xFFBEF0FA
        dd 297, 151, 1, 1, 0xFF413C3C
        dd 292, 152, 1, 1, 0xFF413C3C
        dd 293, 152, 4, 1, 0xFFBEF0FA
        dd 297, 152, 1, 1, 0xFF413C3C
        dd 293, 153, 4, 1, 0xFF413C3C
        dd 294, 154, 2, 1, 0xFF7D7878
        dd 294, 155, 2, 1, 0xFF7D7878
        dd 293, 156, 4, 1, 0xFF5F5A5A
        dd 293, 157, 4, 1, 0xFF5F5A5A
        dd 293, 520, 4, 1, 0xFF413C3C
        dd 292, 521, 1, 1, 0xFF413C3C
        dd 293, 521, 4, 1, 0xFFBEF0FA
        dd 297, 521, 1, 1, 0xFF413C3C
        dd 292, 522, 1, 1, 0xFF413C3C
        dd 293, 522, 4, 1, 0xFFBEF0FA
        dd 297, 522, 1, 1, 0xFF413C3C
        dd 293, 523, 4, 1, 0xFF413C3C
        dd 294, 524, 2, 1, 0xFF7D7878
        dd 294, 525, 2, 1, 0xFF7D7878
        dd 293, 526, 4, 1, 0xFF5F5A5A
        dd 293, 527, 4, 1, 0xFF5F5A5A
        dd 353, 250, 4, 1, 0xFF413C3C
        dd 352, 251, 1, 1, 0xFF413C3C
        dd 353, 251, 4, 1, 0xFFBEF0FA
        dd 357, 251, 1, 1, 0xFF413C3C
        dd 352, 252, 1, 1, 0xFF413C3C
        dd 353, 252, 4, 1, 0xFFBEF0FA
        dd 357, 252, 1, 1, 0xFF413C3C
        dd 353, 253, 4, 1, 0xFF413C3C
        dd 354, 254, 2, 1, 0xFF7D7878
        dd 354, 255, 2, 1, 0xFF7D7878
        dd 353, 256, 4, 1, 0xFF5F5A5A
        dd 353, 257, 4, 1, 0xFF5F5A5A
        dd 353, 460, 4, 1, 0xFF413C3C
        dd 352, 461, 1, 1, 0xFF413C3C
        dd 353, 461, 4, 1, 0xFFBEF0FA
        dd 357, 461, 1, 1, 0xFF413C3C
        dd 352, 462, 1, 1, 0xFF413C3C
        dd 353, 462, 4, 1, 0xFFBEF0FA
        dd 357, 462, 1, 1, 0xFF413C3C
        dd 353, 463, 4, 1, 0xFF413C3C
        dd 354, 464, 2, 1, 0xFF7D7878
        dd 354, 465, 2, 1, 0xFF7D7878
        dd 353, 466, 4, 1, 0xFF5F5A5A
        dd 353, 467, 4, 1, 0xFF5F5A5A
        dd 893, 60, 4, 1, 0xFF413C3C
        dd 892, 61, 1, 1, 0xFF413C3C
        dd 893, 61, 4, 1, 0xFFBEF0FA
        dd 897, 61, 1, 1, 0xFF413C3C
        dd 892, 62, 1, 1, 0xFF413C3C
        dd 893, 62, 4, 1, 0xFFBEF0FA
        dd 897, 62, 1, 1, 0xFF413C3C
        dd 893, 63, 4, 1, 0xFF413C3C
        dd 894, 64, 2, 1, 0xFF7D7878
        dd 894, 65, 2, 1, 0xFF7D7878
        dd 893, 66, 4, 1, 0xFF5F5A5A
        dd 893, 67, 4, 1, 0xFF5F5A5A
        dd 893, 520, 4, 1, 0xFF413C3C
        dd 892, 521, 1, 1, 0xFF413C3C
        dd 893, 521, 4, 1, 0xFFBEF0FA
        dd 897, 521, 1, 1, 0xFF413C3C
        dd 892, 522, 1, 1, 0xFF413C3C
        dd 893, 522, 4, 1, 0xFFBEF0FA
        dd 897, 522, 1, 1, 0xFF413C3C
        dd 893, 523, 4, 1, 0xFF413C3C
        dd 894, 524, 2, 1, 0xFF7D7878
        dd 894, 525, 2, 1, 0xFF7D7878
        dd 893, 526, 4, 1, 0xFF5F5A5A
        dd 893, 527, 4, 1, 0xFF5F5A5A
        dd 953, 250, 4, 1, 0xFF413C3C
        dd 952, 251, 1, 1, 0xFF413C3C
        dd 953, 251, 4, 1, 0xFFBEF0FA
        dd 957, 251, 1, 1, 0xFF413C3C
        dd 952, 252, 1, 1, 0xFF413C3C
        dd 953, 252, 4, 1, 0xFFBEF0FA
        dd 957, 252, 1, 1, 0xFF413C3C
        dd 953, 253, 4, 1, 0xFF413C3C
        dd 954, 254, 2, 1, 0xFF7D7878
        dd 954, 255, 2, 1, 0xFF7D7878
        dd 953, 256, 4, 1, 0xFF5F5A5A
        dd 953, 257, 4, 1, 0xFF5F5A5A
        dd 953, 470, 4, 1, 0xFF413C3C
        dd 952, 471, 1, 1, 0xFF413C3C
        dd 953, 471, 4, 1, 0xFFBEF0FA
        dd 957, 471, 1, 1, 0xFF413C3C
        dd 952, 472, 1, 1, 0xFF413C3C
        dd 953, 472, 4, 1, 0xFFBEF0FA
        dd 957, 472, 1, 1, 0xFF413C3C
        dd 953, 473, 4, 1, 0xFF413C3C
        dd 954, 474, 2, 1, 0xFF7D7878
        dd 954, 475, 2, 1, 0xFF7D7878
        dd 953, 476, 4, 1, 0xFF5F5A5A
        dd 953, 477, 4, 1, 0xFF5F5A5A
    bg_objects_count equ ($ - bg_objects) / 20
    ; streetlights: x, y (their 8x8 heads), for the night (8.05)
    street_lamps:
        dd 60, 321
        dd 220, 321
        dd 460, 321
        dd 620, 321
        dd 780, 321
        dd 1040, 321
        dd 1200, 321
        dd 140, 391
        dd 540, 391
        dd 700, 391
        dd 860, 391
        dd 1000, 391
        dd 1160, 391
        dd 291, 150
        dd 291, 520
        dd 351, 250
        dd 351, 460
        dd 891, 60
        dd 891, 520
        dd 951, 250
        dd 951, 470
    street_lamps_count equ ($ - street_lamps) / 8
    ; complex doorways: centre x, y, where lobby light spills out (8.05)
    door_lights:
        dd 140, 415
        dd 275, 540
        dd 1100, 295
        dd 975, 150
    door_lights_count equ ($ - door_lights) / 8
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
    ; the police car, 40x20, facing east
    cop_sprite_h:
        db 0,0,0,0,0,0,7,7,7,7,7,7,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,7,7,7,7,7,0,0,0,0,0,0
        db 0,0,2,2,2,2,2,2,2,2,2,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,2,2,2,2,2,2,2,2,0,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,1,1,1,1,1,1,1,1,1,2,0
        db 5,1,1,1,1,1,1,1,2,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,2,1,1,1,1,1,1,1,1,1,6
        db 5,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,3,3,3,3,2,1,1,1,1,1,6
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,9,9,9,9,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,9,9,9,9,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,9,9,9,9,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,10,10,10,10,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,10,10,10,10,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,10,10,10,10,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 2,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,3,3,3,3,3,2,1,1,1,1,2
        db 5,1,1,1,1,1,1,2,3,3,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,3,3,3,3,2,1,1,1,1,1,6
        db 5,1,1,1,1,1,1,1,2,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,2,1,1,1,1,1,1,1,1,1,6
        db 0,2,1,1,1,1,1,1,1,1,1,1,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,1,1,1,1,1,1,1,1,1,2,0
        db 0,0,2,2,2,2,2,2,2,2,2,2,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,2,2,2,2,2,2,2,2,2,0,0
        db 0,0,0,0,0,0,7,7,7,7,7,7,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,7,7,7,7,7,7,0,0,0,0,0,0
    ; the police car, 20x40, facing south
    cop_sprite_v:
        db 0,0,0,5,5,2,2,2,2,2,2,2,2,2,2,5,5,0,0,0
        db 0,0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 7,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,7
        db 7,2,1,1,2,2,2,2,2,2,2,2,2,2,2,2,1,1,2,7
        db 7,2,1,2,3,3,3,3,3,3,3,3,3,3,3,3,2,1,2,7
        db 7,2,1,4,3,3,3,3,3,3,3,3,3,3,3,3,4,1,2,7
        db 7,2,1,4,2,2,2,2,2,2,2,2,2,2,2,2,4,1,2,7
        db 7,2,1,4,8,8,8,8,8,8,8,8,8,8,8,8,4,1,2,7
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,10,10,10,9,9,9,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,10,10,10,9,9,9,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,10,10,10,9,9,9,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,10,10,10,9,9,9,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 0,8,8,4,8,8,8,8,8,8,8,8,8,8,8,8,4,8,8,0
        db 7,8,8,4,2,2,2,2,2,2,2,2,2,2,2,2,4,8,8,7
        db 7,2,1,2,3,3,3,3,3,3,3,3,3,3,3,3,2,1,2,7
        db 7,2,1,1,3,3,3,3,3,3,3,3,3,3,3,3,1,1,2,7
        db 7,2,1,1,3,3,3,3,3,3,3,3,3,3,3,3,1,1,2,7
        db 7,2,1,1,3,3,3,3,3,3,3,3,3,3,3,3,1,1,2,7
        db 7,2,1,1,2,3,3,3,3,3,3,3,3,3,3,2,1,1,2,7
        db 0,2,1,1,1,2,2,2,2,2,2,2,2,2,2,1,1,1,2,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0
        db 0,0,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,0,0
        db 0,0,0,6,6,2,2,2,2,2,2,2,2,2,2,6,6,0,0,0
    ; the dog, 16x16, facing east, two frames
    dog_sprites:
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,2,2,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,1,1,1,1,3,0
        db 0,4,0,0,0,0,0,0,0,0,6,1,1,1,0,0
        db 0,0,4,1,1,1,1,1,1,1,6,1,1,0,0,0
        db 0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0
        db 0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0
        db 0,0,0,5,0,5,0,0,0,0,5,0,5,0,0,0
        db 0,0,0,5,0,5,0,0,0,0,5,0,5,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,2,2,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,1,1,1,1,3,0
        db 4,0,0,0,0,0,0,0,0,0,6,1,1,1,0,0
        db 0,4,4,1,1,1,1,1,1,1,6,1,1,0,0,0
        db 0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0
        db 0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0
        db 0,0,0,0,5,5,0,0,0,5,5,0,0,0,0,0
        db 0,0,0,5,0,0,0,0,5,0,0,5,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    ; pickups, 16x16: pistol, then shotgun
    pickup_sprites:
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0
        db 0,0,0,1,2,2,2,2,2,2,2,2,2,1,0,0
        db 0,0,0,1,2,3,3,3,3,3,3,3,2,1,0,0
        db 0,0,0,1,2,2,2,2,1,1,1,1,1,0,0,0
        db 0,0,0,1,2,2,2,1,0,0,0,0,0,0,0,0
        db 0,0,0,1,2,2,2,1,0,0,0,0,0,0,0,0
        db 0,0,0,1,2,2,1,0,0,0,0,0,0,0,0,0
        db 0,0,0,1,1,1,1,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1
        db 1,4,4,4,4,2,2,2,2,2,2,2,2,2,2,1
        db 1,4,4,4,4,2,3,3,3,3,3,3,3,3,3,1
        db 1,4,4,4,1,2,2,2,1,1,1,1,1,1,1,1
        db 1,4,4,1,0,1,2,1,0,0,0,0,0,0,0,0
        db 1,1,1,1,0,1,1,1,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    ; a fallen soldier, 16x16, soldier letters (head west)
    dead_sprite:
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,3,3,0,0,0,0,0,0,0,0,0
        db 0,2,2,1,1,3,4,4,4,4,4,6,6,6,7,0
        db 2,2,1,1,1,4,4,4,4,4,4,6,6,6,6,7
        db 2,2,1,1,1,4,4,4,4,4,4,6,6,6,6,7
        db 0,2,1,1,3,3,4,4,4,4,4,6,6,6,7,0
        db 0,0,0,0,0,3,3,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    ; blood splats, 12x12, four shapes
    splat_sprites:
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,1,0,0,0,0,0,0
        db 0,0,0,0,1,2,1,0,0,1,0,0
        db 0,0,0,1,2,2,2,1,0,0,0,0
        db 0,0,1,2,2,2,2,2,1,0,0,0
        db 0,0,0,1,2,2,2,2,1,0,0,0
        db 0,0,1,0,1,2,2,1,0,0,0,0
        db 0,0,0,0,0,1,1,0,0,1,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,1,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,1,0,0,0,0,0,0,0,0,0
        db 0,0,0,1,1,0,0,0,1,0,0,0
        db 0,0,0,1,2,2,1,0,0,0,0,0
        db 0,0,0,0,2,2,2,2,1,0,0,0
        db 0,0,0,1,2,2,2,2,2,1,0,0
        db 0,0,0,0,1,2,2,2,1,0,0,0
        db 0,1,0,0,0,1,2,1,0,0,0,0
        db 0,0,0,0,0,0,0,1,0,0,0,0
        db 0,0,0,1,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,1,0,0,0,0
        db 0,0,1,0,0,1,1,0,0,0,0,0
        db 0,0,0,0,1,2,2,1,0,0,0,0
        db 0,0,0,1,2,2,2,2,1,0,1,0
        db 0,0,1,2,2,3,2,2,1,0,0,0
        db 0,0,0,1,2,2,2,1,0,0,0,0
        db 0,0,0,0,1,1,1,0,0,0,0,0
        db 0,1,0,0,0,0,0,0,1,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,1,0,1,0,0,0,0,0
        db 0,0,0,1,2,2,2,1,0,0,0,0
        db 0,0,1,2,2,2,2,2,1,0,0,0
        db 0,1,2,2,2,3,2,2,2,1,0,0
        db 0,0,1,2,2,2,2,2,1,0,0,0
        db 0,0,0,1,2,2,2,1,0,0,0,0
        db 0,0,0,0,1,0,0,1,0,0,0,0
        db 0,0,0,1,0,0,0,0,1,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0
    ; blood pools, 16x16, two shapes
    pool_sprites:
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,1,1,2,2,2,2,2,1,1,0,0,0,0
        db 0,0,1,2,2,2,2,2,2,2,2,2,1,0,0,0
        db 0,1,2,2,2,2,3,3,3,2,2,2,2,1,0,0
        db 0,1,2,2,2,3,3,3,3,3,3,2,2,2,1,0
        db 1,2,2,2,2,3,3,3,3,3,3,2,2,2,1,0
        db 0,1,2,2,2,2,3,3,3,3,2,2,2,2,1,0
        db 0,0,1,2,2,2,2,2,2,2,2,2,2,1,0,0
        db 0,0,0,1,1,2,2,2,2,2,2,1,1,0,0,0
        db 0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0
        db 0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,0,1,1,2,2,2,2,1,0,0,0,0,0
        db 0,0,1,1,2,2,2,2,2,2,2,1,0,0,0,0
        db 0,1,2,2,2,2,3,3,3,2,2,2,1,0,1,0
        db 0,1,2,2,2,3,3,3,3,3,2,2,2,1,0,0
        db 0,0,1,2,2,3,3,3,3,3,3,2,2,2,1,0
        db 0,0,1,2,2,2,3,3,3,3,2,2,2,2,1,0
        db 0,0,0,1,2,2,2,2,2,2,2,2,2,1,0,0
        db 0,0,1,0,1,1,2,2,2,2,1,1,0,0,0,0
        db 0,0,0,0,0,0,1,1,1,1,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
;; ---- END SPRITE DATA ----

    ; ---- palettes for the object sprites (gen_sprites.py's letters) ----
    ; the police car: . K k W w R L X U r b -- two, the light bar swapped
    cop_pal_a:
        dd 0, 0xFF141414, 0xFF3C3C3C, 0xFF6E503C, 0xFF826450, 0xFF1E1EC8
        dd 0xFFB4F0FF, 0xFF0A0A0A, 0xFFF0F0F0, 0xFF1E1EE6, 0xFFFF5028, 0
    cop_pal_b:
        dd 0, 0xFF141414, 0xFF3C3C3C, 0xFF6E503C, 0xFF826450, 0xFF1E1EC8
        dd 0xFFB4F0FF, 0xFF0A0A0A, 0xFFF0F0F0, 0xFFFF5028, 0xFF1E1EE6, 0
    ; the dog: . D E N T L C
    dog_pal_leashed:
        dd 0, 0xFF3C64A0, 0xFF28416E, 0xFF141414, 0xFF3C64A0, 0xFF28416E, 0xFF1E1EC8, 0
    dog_pal_loose:
        dd 0, 0xFF5AB4E6, 0xFF3C82B4, 0xFF141414, 0xFF5AB4E6, 0xFF3C82B4, 0xFF1E1EC8, 0
    ; pickups: . o G g W -- pistol outline yellow, shotgun magenta
    pickup_pal_pistol:
        dd 0, COLOR_PICKUP_PISTOL, 0xFF373232, 0xFF736E6E, 0xFF285082, 0
    pickup_pal_shotgun:
        dd 0, COLOR_PICKUP_SHOTGUN, 0xFF373232, 0xFF736E6E, 0xFF285082, 0

    ; ---- day and night ----
    time_env    db "TIME", 0
    tod_start   dd -1             ; minute of the day at tick 0 (-1: from the seed)
    ; ambient keyframes: minute of the day, then R, G, B scales (x/256)
    tod_keys:
        dd    0,  64,  74, 128    ; night
        dd  300,  64,  74, 128    ; 5:00, still night
        dd  390, 200, 160, 150    ; 6:30, dawn
        dd  480, 256, 256, 256    ; 8:00, day
        dd 1050, 256, 256, 256    ; 5:30 PM, still day
        dd 1140, 236, 160, 116    ; 7:00 PM, dusk
        dd 1230,  64,  74, 128    ; 8:30 PM, night
        dd 1440,  64,  74, 128    ; (wraps to midnight)
    TOD_KEYS equ ($ - tod_keys) / 16
    am_pm       db "AMPM"

    ; blood: . r R d
    blood_pal:
        dd 0, 0xFF1E1E8C, 0xFF2828B4, 0xFF14145A

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
    spr_h         resd 1                ; draw_sprite_ex's height
    ; ---- day and night (drawing only) ----
    lightmap      resb LM_W * LM_H      ; light per 2x2 pixels, 0..255
    light_tab     resd 256 * 3          ; per light level: R, G, B scales
    ambient       resd 3                ; this frame's R, G, B scales
    lamps_on      resd 1
    kern_lamp     resb (2 * LAMP_R + 1) * (2 * LAMP_R + 1)
    kern_mid      resb (2 * MID_R + 1) * (2 * MID_R + 1)
    kern_small    resb (2 * SMALL_R + 1) * (2 * SMALL_R + 1)
    dog_last_x    resd 1                ; drawing only: which way it ran
    dog_face      resd 1                ; SPR_MIRROR when facing west
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
    call init_lighting             ; kernels, and the starting time

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

    ; ---- shadows of everything that moves, before any of it is drawn
    ; (so no shadow darkens a neighbour's sprite) ----
    call draw_moving_shadows

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

    ; a gun, centred where the old square was
    lea rdx, [pickup_sprites]
    lea rcx, [pickup_pal_pistol]
    cmp dword [r10 + Pickup.type], WEAPON_PISTOL
    je .pickup_have_sprite
    add rdx, SPRITE_SIZE * SPRITE_SIZE
    lea rcx, [pickup_pal_shotgun]
.pickup_have_sprite:
    mov edi, [r10 + Pickup.x]
    sub edi, (SPRITE_SIZE - PICKUP_SIZE) / 2
    mov esi, [r10 + Pickup.y]
    sub esi, (SPRITE_SIZE - PICKUP_SIZE) / 2
    xor r8d, r8d
    call draw_sprite

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
    jnz .linger_done
    ; the fall's over: if it was a death, it leaves a pool (8.04)
    imul ecx, eax, Soldier_size
    lea rdx, [soldiers]
    cmp dword [rdx + rcx + Soldier.health], 0
    jg .linger_done
    mov edi, eax
    call stamp_pool
    mov eax, [rsp + LOOP_I_OFF]
.linger_done:
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .draw_loop
.draw_done:

    call draw_bosses               ; the Big Homies' health bars
    call draw_events               ; police car, walker, dog

    ; ---- the time of day: darken, tint, light (8.05) ----
    call light_scene

    ; ---- attack effects, on top of everything (bright in the dark) ----
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
    ; and the time of day (8.05)
    lea rsi, [hud_gap]
    mov edx, 2
    call append_bytes
    call append_time_of_day
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
    lea rdi, [time_env]           ; TIME=h: the game starts at h:00
    call getenv
    test rax, rax
    jz .rr_time_done
    mov rdi, rax
    call atoi
    cmp eax, 23
    ja .rr_time_done
    imul eax, eax, 60
    mov [tod_start], eax
.rr_time_done:
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
; Draws the three generated layers into bg_buffer (ground, shadows,
; objects: see the header), then each complex's walls in the
; colour of the gang that lives there this game. Once per game; every
; frame after that starts with a copy of bg_buffer.
render_background:
    push rbx
    push r12
    push r13
    ; layer 1: the ground
    lea rbx, [bg_ground]
    mov r12d, bg_ground_count
.rbg_ground:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, [rbx + 16]
    call fill_rect
    add rbx, 20
    dec r12d
    jnz .rbg_ground
    ; layer 2: shadows darken the ground under where things will stand
    lea rbx, [bg_shadows]
    mov r12d, bg_shadows_count
.rbg_shadow:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    call shade_rect
    add rbx, 16
    dec r12d
    jnz .rbg_shadow
    ; layer 3: the things themselves
    lea rbx, [bg_objects]
    mov r12d, bg_objects_count
.rbg_object:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, [rbx + 16]
    call fill_rect
    add rbx, 20
    dec r12d
    jnz .rbg_object
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


; void shade_rect(FrameBuffer* fb: rdi, int x: esi, int y: edx,
;                 int w: ecx, int h: r8d)
; Darkens a rectangle to 5/8 of its brightness: a shadow. All three
; channels at once: (p >> 1) & 0x7F7F7F is half of each, and
; (p >> 3) & 0x1F1F1F an eighth -- the masks drop the bits that slid
; in from the channel above. Alpha is put back to 0xFF. Clipped like
; fill_rect.
shade_rect:
    push rbx
    push r12
    mov r10, [rdi + FrameBuffer.pixels]
    mov r11d, [rdi + FrameBuffer.pitch]
    lea ebx, [esi + ecx]          ; x end
    cmp ebx, [rdi + FrameBuffer.w]
    jle .sr_xe
    mov ebx, [rdi + FrameBuffer.w]
.sr_xe:
    lea r12d, [edx + r8d]         ; y end
    cmp r12d, [rdi + FrameBuffer.h]
    jle .sr_ye
    mov r12d, [rdi + FrameBuffer.h]
.sr_ye:
    test esi, esi
    jns .sr_xs
    xor esi, esi
.sr_xs:
    test edx, edx
    jns .sr_row
    xor edx, edx
.sr_row:
    cmp edx, r12d
    jge .sr_done
    mov eax, edx
    imul eax, r11d
    lea r9, [r10 + rax]           ; this row
    mov ecx, esi
.sr_col:
    cmp ecx, ebx
    jge .sr_next_row
    mov eax, [r9 + rcx*4]
    mov r8d, eax
    shr eax, 1
    and eax, 0x7F7F7F
    shr r8d, 3
    and r8d, 0x1F1F1F
    add eax, r8d
    or eax, 0xFF000000
    mov [r9 + rcx*4], eax
    inc ecx
    jmp .sr_col
.sr_next_row:
    inc edx
    jmp .sr_row
.sr_done:
    pop r12
    pop rbx
    ret


; void draw_moving_shadows(void) -- a small shadow at each visible
; soldier's feet (down-right of it: light from the top left), and
; under the walker, the dog and the police car. Drawing only.
draw_moving_shadows:
    push rbx
    push r12
    sub rsp, 8
    xor ebx, ebx
.dms_soldier:
    imul eax, ebx, Soldier_size
    lea r12, [soldiers]
    add r12, rax
    cmp dword [r12 + Soldier.health], 0
    jle .dms_next                 ; the fallen lie flat: no shadow
.dms_draw:
    ; spawn protection blinks the soldier; its shadow blinks with it
    lea rcx, [protect_timer]
    cmp dword [rcx + rbx*4], 0
    jle .dms_oval
    test dword [ticks], 4
    jnz .dms_next
.dms_oval:
    ; a small oval: 7 wide, 11 wide twice, 7 wide
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    add esi, 6
    mov edx, [r12 + Soldier.y]
    add edx, 13
    mov ecx, 7
    mov r8d, 1
    call shade_rect
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    add esi, 4
    mov edx, [r12 + Soldier.y]
    add edx, 14
    mov ecx, 11
    mov r8d, 2
    call shade_rect
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    add esi, 6
    mov edx, [r12 + Soldier.y]
    add edx, 16
    mov ecx, 7
    mov r8d, 1
    call shade_rect
.dms_next:
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .dms_soldier

    cmp dword [cop_active], 0
    je .dms_walker
    lea rdi, [back_fb]
    mov esi, [cop_rect]
    add esi, 3
    mov edx, [cop_rect + 4]
    add edx, 3
    mov ecx, [cop_rect + 8]
    mov r8d, [cop_rect + 12]
    call shade_rect
.dms_walker:
    cmp dword [dog_state], DOG_NONE
    je .dms_done
    lea rdi, [back_fb]
    mov esi, [walker_x]
    add esi, 1
    mov edx, [walker_y]
    add edx, 7
    mov ecx, 11
    mov r8d, 4
    call shade_rect
    cmp dword [dog_state], DOG_GONE
    je .dms_done
    lea rdi, [back_fb]
    mov esi, [dog_x]
    add esi, 1
    mov edx, [dog_y]
    add edx, 6
    mov ecx, DOG_W
    mov r8d, 3
    call shade_rect
.dms_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; ============================================================
; Day and night (drawing only)
; ============================================================

; int tod_minute(void) -> eax: minute of the day now, 0..1439
tod_minute:
    mov eax, [ticks]
    xor edx, edx
    mov ecx, MIN_TICKS
    div ecx
    add eax, [tod_start]
    xor edx, edx
    mov ecx, 1440
    div ecx
    mov eax, edx
    ret


; append_time_of_day(dst: rdi) -> rdi: "9:40 PM"
append_time_of_day:
    push rbx
    push r12
    sub rsp, 8
    call tod_minute
    xor edx, edx
    mov ecx, 60
    div ecx                       ; eax = hour, edx = minute
    mov r12d, edx
    mov ebx, eax                  ; 0..23
    xor edx, edx
    mov ecx, 12
    div ecx                       ; edx = hour % 12
    mov esi, edx
    test esi, esi
    jnz .at_h
    mov esi, 12
.at_h:
    call append_uint
    mov byte [rdi], ':'
    inc rdi
    cmp r12d, 10
    jae .at_mm
    mov byte [rdi], '0'
    inc rdi
.at_mm:
    mov esi, r12d
    call append_uint
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [am_pm]
    cmp ebx, 12
    jb .at_ampm
    add rsi, 2
.at_ampm:
    mov edx, 2
    call append_bytes
    add rsp, 8
    pop r12
    pop rbx
    ret


; make_kernel(u8 *out: rdi, int r: esi, int peak: edx)
; A round light: peak * (1 - d^2 / r^2) for d < r, else 0, over a
; (2r+1)^2 square. Smooth falloff, no square root.
make_kernel:
    push rbx
    push r12
    push r13
    mov r8d, esi
    imul r8d, esi                 ; r^2
    mov r9d, esi
    neg r9d                       ; dy
.mk_row:
    cmp r9d, esi
    jg .mk_done
    mov r10d, esi
    neg r10d                      ; dx
.mk_col:
    cmp r10d, esi
    jg .mk_next_row
    mov eax, r9d
    imul eax, r9d
    mov ecx, r10d
    imul ecx, r10d
    add eax, ecx                  ; d^2
    xor ebx, ebx
    cmp eax, r8d
    jge .mk_store
    mov ebx, r8d
    sub ebx, eax
    imul ebx, edx
    mov eax, ebx
    push rdx
    xor edx, edx
    div r8d
    pop rdx
    mov ebx, eax
.mk_store:
    mov [rdi], bl
    inc rdi
    inc r10d
    jmp .mk_col
.mk_next_row:
    inc r9d
    jmp .mk_row
.mk_done:
    pop r13
    pop r12
    pop rbx
    ret


; void init_lighting(void) -- once, when the window opens
init_lighting:
    sub rsp, 8
    cmp dword [tod_start], 0
    jge .il_kernels
    ; no TIME=: start at a minute scrambled from the game's seed
    mov rax, [game_seed]
    mov edi, eax
    shr rax, 32
    mov esi, eax
    call deco_hash
    xor edx, edx
    mov ecx, 1440
    div ecx
    mov [tod_start], edx
.il_kernels:
    lea rdi, [kern_lamp]
    mov esi, LAMP_R
    mov edx, 230
    call make_kernel
    lea rdi, [kern_mid]
    mov esi, MID_R
    mov edx, 200
    call make_kernel
    lea rdi, [kern_small]
    mov esi, SMALL_R
    mov edx, 240
    call make_kernel
    add rsp, 8
    ret


; void light_tables(void)
; The ambient colour for this minute (interpolated between keyframes),
; and per light level L: scale = ambient + (lamp - ambient) * L / 255,
; never darker than ambient (so daylight isn't dimmed by "lamps").
light_tables:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    call tod_minute
    mov r12d, eax
    lea rbx, [tod_keys]
.lt_find:
    cmp r12d, [rbx + 16]          ; before the next key?
    jl .lt_found
    add rbx, 16
    jmp .lt_find
.lt_found:
    ; t = (m - m0) * 256 / (m1 - m0)
    mov eax, r12d
    sub eax, [rbx]
    shl eax, 8
    mov ecx, [rbx + 16]
    sub ecx, [rbx]
    xor edx, edx
    div ecx
    mov r13d, eax                 ; 0..255
    xor ecx, ecx
.lt_chan:
    mov eax, [rbx + 20 + rcx*4]   ; next key's channel
    sub eax, [rbx + 4 + rcx*4]
    imul eax, r13d
    sar eax, 8
    add eax, [rbx + 4 + rcx*4]
    lea rdx, [ambient]
    mov [rdx + rcx*4], eax
    inc ecx
    cmp ecx, 3
    jb .lt_chan
    ; lamps come on when it gets darker than about 3/4 daylight
    mov eax, [ambient]
    add eax, [ambient + 4]
    add eax, [ambient + 8]
    xor ecx, ecx
    cmp eax, 580
    setl cl
    mov [lamps_on], ecx
    ; the tables
    lea rdi, [light_tab]
    xor r8d, r8d                  ; level
.lt_level:
    xor r9d, r9d                  ; channel
.lt_tab_chan:
    lea rdx, [ambient]
    mov eax, [rdx + r9*4]         ; ambient
    mov r10d, LIT_R
    cmp r9d, 1
    jb .lt_lit
    mov r10d, LIT_G
    je .lt_lit
    mov r10d, LIT_B
.lt_lit:
    sub r10d, eax                 ; lamp - ambient
    jle .lt_store                 ; lamps no brighter: ambient
    imul r10d, r8d
    mov r11d, eax
    mov eax, r10d
    xor edx, edx
    mov ecx, 255
    div ecx
    add eax, r11d
.lt_store:
    mov [rdi], eax
    add rdi, 4
    inc r9d
    cmp r9d, 3
    jb .lt_tab_chan
    inc r8d
    cmp r8d, 256
    jb .lt_level
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; stamp_light(int x: edi, int y: esi, u8 *kernel: rdx, int r: ecx)
; Adds a kernel to the light map, centred on pixel (x, y), saturating
; at 255.
stamp_light:
    push rbx
    push r12
    push r13
    push r14
    sar edi, 1                    ; pixels -> light-map cells
    sar esi, 1
    lea r8d, [ecx * 2 + 1]        ; kernel side
    mov r9d, esi
    sub r9d, ecx                  ; first row
    xor r10d, r10d                ; kernel row
.sl_row:
    cmp r10d, r8d
    jge .sl_done
    lea r11d, [r9d + r10d]        ; map row
    cmp r11d, LM_H
    jae .sl_next_row
    imul r12d, r11d, LM_W
    xor r13d, r13d                ; kernel col
.sl_col:
    cmp r13d, r8d
    jge .sl_next_row
    lea ebx, [edi + r13d]
    sub ebx, ecx                  ; map col
    cmp ebx, LM_W
    jae .sl_next_col
    movzx eax, byte [rdx + r13]
    test eax, eax
    jz .sl_next_col
    lea r14, [lightmap]
    add ebx, r12d
    movzx r11d, byte [r14 + rbx]
    add eax, r11d
    cmp eax, 255
    jbe .sl_store
    mov eax, 255
.sl_store:
    mov [r14 + rbx], al
    lea r11d, [r9d + r10d]        ; (restore the map row)
.sl_next_col:
    inc r13d
    jmp .sl_col
.sl_next_row:
    add rdx, r8
    inc r10d
    jmp .sl_row
.sl_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; light_rect(int x: edi, int y: esi, int w: edx, int h: ecx, int v: r8d)
; Adds v to a rectangle of the light map (a lit room), saturating.
;   ebx row   r12d col   r13 this row's first cell
light_rect:
    push rbx
    push r12
    push r13
    sar edi, 1                    ; pixels -> cells
    sar esi, 1
    sar edx, 1
    sar ecx, 1
    xor ebx, ebx
.lr_row:
    cmp ebx, ecx
    jge .lr_done
    lea eax, [esi + ebx]
    imul eax, eax, LM_W
    add eax, edi
    lea r13, [lightmap]
    add r13, rax
    xor r12d, r12d
.lr_col:
    cmp r12d, edx
    jge .lr_next_row
    movzx eax, byte [r13 + r12]
    add eax, r8d
    cmp eax, 255
    jbe .lr_store
    mov eax, 255
.lr_store:
    mov [r13 + r12], al
    inc r12d
    jmp .lr_col
.lr_next_row:
    inc ebx
    jmp .lr_row
.lr_done:
    pop r13
    pop r12
    pop rbx
    ret


; void light_scene(void) -- the whole lighting pass for this frame
light_scene:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call light_tables
    ; full daylight: nothing to do
    cmp dword [ambient], 256
    jl .ls_go
    cmp dword [ambient + 4], 256
    jl .ls_go
    cmp dword [ambient + 8], 256
    jge .ls_done
.ls_go:
    ; ---- the light map ----
    lea rdi, [lightmap]
    mov ecx, LM_W * LM_H
    xor eax, eax
    cld
    rep stosb
    cmp dword [lamps_on], 0
    je .ls_dynamic
    ; streetlights
    lea rbx, [street_lamps]
    mov r12d, street_lamps_count
.ls_lamp:
    mov edi, [rbx]
    add edi, 4
    mov esi, [rbx + 4]
    add esi, 4
    lea rdx, [kern_lamp]
    mov ecx, LAMP_R
    call stamp_light
    add rbx, 8
    dec r12d
    jnz .ls_lamp
    ; the lobbies are lit, and it spills out of the doors
    lea rbx, [lobbies]
    mov r12d, 2
.ls_lobby:
    mov edi, [rbx]
    mov esi, [rbx + 4]
    mov edx, [rbx + 8]
    mov ecx, [rbx + 12]
    mov r8d, LOBBY_LIGHT
    call light_rect
    add rbx, 16
    dec r12d
    jnz .ls_lobby
    lea rbx, [door_lights]
    mov r12d, door_lights_count
.ls_door:
    mov edi, [rbx]
    mov esi, [rbx + 4]
    lea rdx, [kern_mid]
    mov ecx, MID_R
    call stamp_light
    add rbx, 8
    dec r12d
    jnz .ls_door
.ls_dynamic:
    ; the police car: headlights ahead of it, and the light bar
    cmp dword [cop_active], 0
    je .ls_flashes
    mov r13d, [cop_rect + 8]
    shr r13d, 1
    add r13d, [cop_rect]          ; centre x
    mov r14d, [cop_rect + 12]
    shr r14d, 1
    add r14d, [cop_rect + 4]      ; centre y
    mov edi, r13d
    mov esi, r14d
    lea rdx, [kern_small]
    mov ecx, SMALL_R
    call stamp_light
    ; beams: two pools ahead, 40 and 75 px (the direction is the
    ; velocity's sign, times the distance)
    mov r15d, 40
.ls_beam:
    mov eax, [cop_vel]
    cdq
    xor eax, edx
    sub eax, edx                  ; |vx|
    mov ecx, [cop_vel]
    mov edi, r13d
    test ecx, ecx
    jz .ls_beam_y
    mov eax, r15d
    test ecx, ecx
    jg .ls_bx
    neg eax
.ls_bx:
    add edi, eax
.ls_beam_y:
    mov esi, r14d
    mov ecx, [cop_vel + 4]
    test ecx, ecx
    jz .ls_beam_stamp
    mov eax, r15d
    test ecx, ecx
    jg .ls_by
    neg eax
.ls_by:
    add esi, eax
.ls_beam_stamp:
    lea rdx, [kern_mid]
    mov ecx, MID_R
    call stamp_light
    add r15d, 35
    cmp r15d, 75
    jle .ls_beam
.ls_flashes:
    ; muzzle flashes: the first frames of every shot
    lea rbx, [effects]
    mov r12d, MAX_EFFECTS
.ls_fx:
    mov eax, [rbx + Effect.type]
    cmp eax, FX_PISTOL
    je .ls_fx_gun
    cmp eax, FX_SHOTGUN
    jne .ls_fx_next
.ls_fx_gun:
    cmp dword [rbx + Effect.age], 2
    jae .ls_fx_next
    mov edi, [rbx + Effect.x0]
    mov esi, [rbx + Effect.y0]
    lea rdx, [kern_small]
    mov ecx, SMALL_R
    call stamp_light
.ls_fx_next:
    add rbx, Effect_size
    dec r12d
    jnz .ls_fx

    ; ---- every field pixel through the tables ----
    lea r8, [back_buffer]
    lea r9, [light_tab]
    xor r10d, r10d                ; y
.ls_row:
    cmp r10d, SCREEN_H
    jge .ls_done
    mov eax, r10d
    shr eax, 1
    imul eax, eax, LM_W
    lea r11, [lightmap]
    add r11, rax                  ; this row's light cells
    xor ecx, ecx                  ; x
.ls_px:
    mov eax, ecx
    shr eax, 1
    movzx eax, byte [r11 + rax]   ; light level
    lea rax, [rax + rax*2]        ; x3 (R, G, B)
    lea rbx, [r9 + rax*4]         ; this level's scales
    mov edx, [r8]
    movzx r12d, dl
    imul r12d, [rbx]
    shr r12d, 8                   ; R
    mov r13d, edx
    shr r13d, 8
    and r13d, 0xFF
    imul r13d, [rbx + 4]
    shr r13d, 8                   ; G
    shr edx, 16
    movzx r14d, dl
    imul r14d, [rbx + 8]
    shr r14d, 8                   ; B
    shl r13d, 8
    shl r14d, 16
    or r12d, r13d
    or r12d, r14d
    or r12d, 0xFF000000
    mov [r8], r12d
    add r8, 4
    inc ecx
    cmp ecx, SCREEN_W
    jb .ls_px
    inc r10d
    jmp .ls_row
.ls_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; Ground effects (drawing only)
; ============================================================

; u32 deco_hash(int a: edi, int b: esi) -> eax
; Scrambles two numbers (with the frame count) into pseudo-random bits
; for the look: which splat, where a casing lands. Never the game's
; RNG, so drawing can't change the fight.
deco_hash:
    imul eax, edi, 0x9E3779B1
    imul ecx, esi, 0x85EBCA77
    xor eax, ecx
    add eax, [ticks]
    mov ecx, eax
    shr ecx, 15
    xor eax, ecx
    imul eax, eax, 0x2C1B3C6D
    mov ecx, eax
    shr ecx, 13
    xor eax, ecx
    ret


; void stamp_blend(int x: edi, int y: esi, u8 *sprite: rdx,
;                  u32 *palette: rcx, int w: r8d, int h: r9d)
; Mixes a sprite 50/50 into bg_buffer, so it stays for the rest of the
; game and the ground shows through: half of each channel of both,
; added (the masks drop the bit that slid down from the next channel).
stamp_blend:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r10d, r10d                ; row
.sb_row:
    cmp r10d, r9d
    jge .sb_done
    lea r12d, [esi + r10d]
    cmp r12d, SCREEN_H
    jae .sb_next_row
    xor r11d, r11d                ; col
.sb_col:
    cmp r11d, r8d
    jge .sb_next_row
    movzx eax, byte [rdx + r11]
    test eax, eax
    jz .sb_next_col
    mov eax, [rcx + rax*4]
    lea ebx, [edi + r11d]
    cmp ebx, SCREEN_W
    jae .sb_next_col
    imul r13d, r12d, SCREEN_W
    add r13d, ebx
    lea r14, [bg_buffer]
    mov r15d, [r14 + r13*4]
    shr r15d, 1
    and r15d, 0x7F7F7F
    shr eax, 1
    and eax, 0x7F7F7F
    add eax, r15d
    or eax, 0xFF000000
    mov [r14 + r13*4], eax
.sb_next_col:
    inc r11d
    jmp .sb_col
.sb_next_row:
    add rdx, r8
    inc r10d
    jmp .sb_row
.sb_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void stamp_splat(int cx: edi, int cy: esi) -- blood where a hit landed
stamp_splat:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    mov r12d, esi
    call deco_hash
    and eax, 3                    ; one of four shapes
    imul eax, eax, 12 * 12
    lea rdx, [splat_sprites]
    add rdx, rax
    lea edi, [ebx - 6]
    lea esi, [r12d - 6]
    lea rcx, [blood_pal]
    mov r8d, 12
    mov r9d, 12
    call stamp_blend
    add rsp, 8
    pop r12
    pop rbx
    ret


; void stamp_pool(int i: edi) -- a pool under a soldier whose fall ended
stamp_pool:
    push rbx
    push r12
    sub rsp, 8
    imul eax, edi, Soldier_size
    lea r12, [soldiers]
    add r12, rax
    mov esi, [r12 + Soldier.y]
    mov edi, [r12 + Soldier.x]
    call deco_hash
    and eax, 1
    shl eax, 8                    ; 16 * 16
    lea rdx, [pool_sprites]
    add rdx, rax
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    add esi, 2
    lea rcx, [blood_pal]
    mov r8d, SPRITE_SIZE
    mov r9d, SPRITE_SIZE
    call stamp_blend
    add rsp, 8
    pop r12
    pop rbx
    ret


; void stamp_casing(int cx: edi, int cy: esi, int fx: edx)
; A spent casing near the shooter's feet: two brass pixels for a
; pistol, a red shell with a brass base for a shotgun. Scattered a
; few pixels by deco_hash, and drawn solid (it's metal).
stamp_casing:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    call deco_hash
    mov ecx, eax
    and ecx, 7
    sub ecx, 3
    add ebx, ecx                  ; x: -3..+4
    shr eax, 3
    and eax, 3
    add r12d, eax
    add r12d, 5                   ; y: at the feet, +5..+8
    mov eax, ebx
    cmp eax, SCREEN_W - 2
    jae .sc_done
    cmp r12d, SCREEN_H
    jae .sc_done
    imul ecx, r12d, SCREEN_W
    add ecx, ebx
    lea rdx, [bg_buffer]
    mov eax, COLOR_BRASS
    cmp r13d, FX_SHOTGUN
    jne .sc_first
    mov eax, COLOR_SHELL
.sc_first:
    mov [rdx + rcx*4], eax
    mov eax, COLOR_BRASS_DARK
    cmp r13d, FX_SHOTGUN
    jne .sc_second
    mov eax, COLOR_BRASS
.sc_second:
    mov [rdx + rcx*4 + 4], eax
.sc_done:
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; Sprites (drawing only)
; ============================================================

; void draw_sprite(int x: edi, int y: esi, u8 *sprite: rdx,
;                  u32 *palette: rcx, int flags: r8d)
; A 16x16 sprite: draw_sprite_ex with the size filled in.
draw_sprite:
    mov r9d, SPRITE_SIZE
    mov dword [spr_h], SPRITE_SIZE
; void draw_sprite_ex(x: edi, y: esi, sprite: rdx, palette: rcx,
;                     flags: r8d, width: r9d; height in spr_h)
; Palette indices (one byte a pixel, row by row) -> back_buffer,
; skipping index 0 and any colour that's 0 (a hidden weapon), clipped
; to the field. SPR_MIRROR reads each row right to left; SPR_FLIP
; reads the rows bottom to top.
;   r10d row   r11d col   ebx pixel x   r12d pixel y   r13d src index
draw_sprite_ex:
    push rbx
    push r12
    push r13
    push r14
    xor r10d, r10d
.ds_row:
    cmp r10d, [spr_h]
    jge .ds_done
    lea r12d, [esi + r10d]
    cmp r12d, SCREEN_H
    jae .ds_next_row              ; unsigned: above the top too
    mov r14d, r10d                ; source row
    test r8d, SPR_FLIP
    jz .ds_row_ok
    mov r14d, [spr_h]
    dec r14d
    sub r14d, r10d
.ds_row_ok:
    imul r14d, r9d                ; its first byte
    xor r11d, r11d
.ds_col:
    cmp r11d, r9d
    jge .ds_next_row
    mov r13d, r11d                ; source column
    test r8d, SPR_MIRROR
    jz .ds_col_ok
    mov r13d, r9d
    dec r13d
    sub r13d, r11d
.ds_col_ok:
    add r13d, r14d
    movzx eax, byte [rdx + r13]
    test eax, eax
    jz .ds_next_col
    mov eax, [rcx + rax*4]
    test eax, eax
    jz .ds_next_col
    lea ebx, [edi + r11d]
    cmp ebx, SCREEN_W
    jae .ds_next_col
    imul r13d, r12d, SCREEN_W
    add r13d, ebx
    push rdx
    lea rdx, [back_buffer]
    mov [rdx + r13*4], eax
    pop rdx
.ds_next_col:
    inc r11d
    jmp .ds_col
.ds_next_row:
    inc r10d
    jmp .ds_row
.ds_done:
    pop r14
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
    ; fallen (and the hit flash is over): lying on the ground (8.04)
    cmp dword [r12 + Soldier.health], 0
    jg .dsol_standing
    lea r8, [hit_flash]
    cmp dword [r8 + rbx*4], 0
    jg .dsol_standing
    lea rdx, [dead_sprite]
    mov r8d, ebx
    and r8d, SPR_MIRROR           ; half of them fall the other way
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    lea rcx, [pal_buf]
    call draw_sprite
    jmp .dsol_done
.dsol_standing:
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
.dsol_done:
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
    ; the car, facing the way it drives; the light bar's red and blue
    ; swap every 8 frames (two palettes)
    lea rcx, [cop_pal_a]
    test dword [ticks], 8
    jz .de_cop_pal
    lea rcx, [cop_pal_b]
.de_cop_pal:
    mov edi, [cop_rect]
    mov esi, [cop_rect + 4]
    xor r8d, r8d
    cmp dword [cop_vel], 0
    je .de_cop_vertical
    lea rdx, [cop_sprite_h]       ; drawn facing east
    jg .de_cop_h
    mov r8d, SPR_MIRROR           ; going west
.de_cop_h:
    mov r9d, COP_W
    mov dword [spr_h], COP_H
    call draw_sprite_ex
    jmp .de_walker
.de_cop_vertical:
    lea rdx, [cop_sprite_v]       ; drawn facing south
    cmp dword [cop_vel + 4], 0
    jg .de_cop_v
    mov r8d, SPR_FLIP             ; going north
.de_cop_v:
    mov r9d, COP_H
    mov dword [spr_h], COP_W
    call draw_sprite_ex

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
    ; which way: on the leash, the walker's way; loose, the way it
    ; moved since the last frame (kept if it didn't move sideways)
    mov eax, [dog_x]
    mov ecx, eax
    sub ecx, [dog_last_x]
    mov [dog_last_x], eax
    cmp dword [dog_state], DOG_LOOSE
    je .de_dog_loose
    mov dword [dog_face], 0
    cmp dword [walker_dx], 0
    jg .de_dog_frame
    mov dword [dog_face], SPR_MIRROR
    jmp .de_dog_frame
.de_dog_loose:
    test ecx, ecx
    jz .de_dog_frame
    mov dword [dog_face], 0
    jg .de_dog_frame
    mov dword [dog_face], SPR_MIRROR
.de_dog_frame:
    ; running frame: every 4 frames when loose, every 8 px on the leash
    mov eax, [ticks]
    shr eax, 2
    cmp dword [dog_state], DOG_LOOSE
    je .de_dog_f
    mov eax, [dog_x]
    shr eax, 3
.de_dog_f:
    and eax, 1
    shl eax, 8
    lea rdx, [dog_sprites]
    add rdx, rax
    lea rcx, [dog_pal_leashed]
    cmp dword [dog_state], DOG_LOOSE
    jne .de_dog_pal
    lea rcx, [dog_pal_loose]
.de_dog_pal:
    mov edi, [dog_x]
    sub edi, (SPRITE_SIZE - DOG_W) / 2
    mov esi, [dog_y]
    sub esi, 5                    ; the art's body sits in rows 4-11
    mov r8d, [dog_face]
    call draw_sprite
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
    ; (8.04: plus DEATH_LIE, the fall, if this hit is the one that kills)
    mov ecx, BULLET_TRAVEL + FLASH_FRAMES + DEATH_LIE + 1
    cmp edi, WEAPON_KNIFE
    jne .se_have_linger
    mov ecx, KNIFE_PEAK + FLASH_FRAMES + DEATH_LIE + 1
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

    ; the first frame of a shot: a casing by the shooter's feet (8.04)
    cmp dword [r12 + Effect.age], 0
    jne .de_no_casing
    mov edi, [r12 + Effect.x0]
    mov esi, [r12 + Effect.y0]
    mov edx, [r12 + Effect.type]
    call stamp_casing
.de_no_casing:

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
    ; and blood on the ground where it landed (8.04)
    sub rsp, 8                  ; the call here pushed 8; realign
    mov edi, [r12 + Effect.x1]
    mov esi, [r12 + Effect.y1]
    call stamp_splat
    add rsp, 8
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
;   ./build/05_night                          # starts at a time from the seed
;   TIME=21 ./build/05_night                  # starts at 9 PM
;   TIME=18 ./build/05_night                  # dusk, into night
;   HEADLESS=1 SEED=0x1234 ./build/05_night
;   STAGGER=0 ./batch.sh 48                   # headless, 4 at a time
;
; Questions to answer by experimenting:
;   - LM_SCALE 2 means a light map a quarter the size of the screen.
;     Try 4, then 1: what do you see, and what does it cost?
;   - The tables clamp at "never darker than ambient". Take that out
;     and play at noon: what happens under every streetlight?
;   - Coloured light (red and blue from the light bar) needs more
;     than one number per cell. How many, and how much slower is it?
; ------------------------------------------------------------
