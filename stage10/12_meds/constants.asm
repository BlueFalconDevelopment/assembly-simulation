; constants.asm -- constants, the map include, structs and colours
; (10.01: split out of 9.03 in its original order; main.asm includes it)


SDL_INIT_VIDEO              equ 0x00000020
SDL_WINDOWPOS_UNDEFINED     equ 0x1FFF0000
SDL_WINDOW_SHOWN            equ 0x00000004
SDL_RENDERER_ACCELERATED    equ 0x00000002
SDL_QUIT_EVENT               equ 0x100
SDL_MOUSEWHEEL_EVENT         equ 0x403
WHEEL_Y_OFF                  equ 20     ; SDL_MouseWheelEvent.y
SCANCODE_A                   equ 4
SCANCODE_D                   equ 7
SCANCODE_S                   equ 22
SCANCODE_W                   equ 26
FRAME_BUDGET_MS              equ 16
SDL_PIXELFORMAT_RGBA32       equ 0x16762004
SDL_TEXTUREACCESS_STREAMING  equ 1

SCREEN_W equ 1280
SCREEN_H equ 720              ; the window's view of the map
HUD_H    equ 40               ; scoreboard strip under it: two rows (10.07)
WINDOW_H equ SCREEN_H + HUD_H

; ---- the map (9.01): its size, and everything on it ----
%include "maps/southside3.inc"   ; 10.07: sites, pairs and delivery points
WORLD_W  equ MAP_W
WORLD_H  equ MAP_H
; back_buffer holds the biggest view: the camera zoomed all the way out
VIEW_MAX_W equ SCREEN_W * 2
VIEW_MAX_H equ SCREEN_H * 2
BB_PITCH   equ VIEW_MAX_W * 4
HUD_PITCH  equ SCREEN_W * 4

; ---- scoreboard font (see `font` in .data) ----
FONT_FIRST  equ 32            ; ' '
FONT_LAST   equ 90            ; 'Z'
FONT_ROWS   equ 7
FONT_COLS   equ 5
FONT_SCALE  equ 2             ; each font pixel is a 2x2 block
CHAR_ADV    equ (FONT_COLS + 1) * FONT_SCALE     ; one column of spacing
HUD_TEXT_Y  equ 4             ; row 1, in hud_buffer
HUD_TEXT_Y2 equ 22            ; row 2: the job board (10.07)
HUD_MARGIN  equ 8

; ---- factions (10.02) ----
; A soldier's Soldier.team is its faction. Factions 0 and 1 are the two
; gangs; the rest are slots for what's coming (Bikers, the cartel, the
; good ole boys, the police, the player). Who fights whom is the
; hostility table in data.asm, not "a different team".
MAX_FACTIONS   equ 8          ; a power of two up to 8: HOSTILE scales by it
FACTION_CRIPS  equ 0
FACTION_BLOODS equ 1
NUM_GANGS      equ 2          ; factions 0 .. NUM_GANGS-1 are gangs
FACTION_PLAYER equ 2          ; you (10.05)
FACTION_POLICE equ 3          ; the police: their row says whom they go after (10.09)
COP_WAIT_MAX   equ 120        ; ticks the car waits for you before turning round (10.09)
COP_GAP        equ 4          ; px it keeps clear ahead of its bumper
%if MAX_FACTIONS != 8 && MAX_FACTIONS != 4 && MAX_FACTIONS != 2
    %error "MAX_FACTIONS must be 2, 4 or 8"
%endif

; HOSTILE dst64, a64, b64: dst = 1 if faction a fights faction b, else 0
; (all three 64-bit registers; a and b below MAX_FACTIONS). Flags are
; set from dst, so a jz/jnz can follow straight away.
%macro HOSTILE 3
    lea %1, [%2 * MAX_FACTIONS + %3]
    add %1, hostility
    movzx %1, byte [%1]
    test %1, %1
%endmacro

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
PLAYER         equ SQUAD + 2               ; you (10.05)
TOTAL_SOLDIERS equ SQUAD + 3
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
MAX_PICKUPS   equ PICKUPS_PER_PAIR + 2    ; + the Big Homies' guns
PICKUP_SIZE   equ 10
; ---- the player (10.05; see player.asm) ----
PLAYER_SPEED         equ 3    ; px a tick (soldiers: MOVE_SPEED 2)
PLAYER_HEALTH        equ 150  ; (soldiers: 100)
PLAYER_AMMO          equ 60   ; pistol rounds a life
PLAYER_HIT           equ 85   ; % a pistol shot hits (soldiers: 60)
PLAYER_DAMAGE        equ 50   ; a pistol hit (soldiers: 20): two kill (10.11: was 34, three)
PLAYER_COOLDOWN      equ 14   ; ticks between pistol shots (soldiers: 20)
PLAYER_SG_COOLDOWN   equ 30   ; ... shotgun blasts (soldiers: 40)
PLAYER_SG_CLOSE_HIT  equ 95   ; the shotgun, inside SHOTGUN_CLOSE_RANGE
PLAYER_SG_CLOSE_DMG  equ 100  ; (10.11: was 60)
PLAYER_SG_FAR_HIT    equ 65   ; ... beyond it, out to SHOTGUN_RANGE
PLAYER_SG_FAR_DMG    equ 50   ; (10.11: was 30)
PICKUP_PISTOL_AMMO   equ 20   ; a gun on the ground: its rounds
PICKUP_SHOTGUN_AMMO  equ 8    ; ... its shells
LOCK_RADIUS          equ 120  ; right-click locks onto the enemy nearest the cursor, within this
LOCK_KEEP            equ 450  ; the lock breaks beyond this from you
PLAYER_AGGRO         equ 450  ; gang members only go after you within this (about 3 blocks)
REGEN_DELAY          equ 240  ; ticks unhurt before health starts coming back
REGEN_EVERY          equ 20   ; then 1 point every this many ticks
SCANCODE_Q           equ 20
SCANCODE_E           equ 8        ; get on or off (10.06)
SCANCODE_1           equ 30       ; take job 1, 2, 3 (10.07)
SCANCODE_X           equ 27       ; drop the job
SDL_BUTTON_RMASK     equ 4
COLOR_LOCK           equ 0xFF30E6FF   ; the lock-on brackets: yellow
PLAYER_RESPAWN_TICKS equ 180  ; 3 s
PLAYER_SAFE_HOME     equ 700  ; spawn at least this far from a home's lobby
PLAYER_SAFE_ENEMY    equ 300  ; ... and from anyone alive
PLAYER_EDGE          equ 100  ; ... and this far in from the map's edges
AIM_RADIUS           equ 40   ; no lock: a shot's target is the enemy nearest the cursor, within this
PLAYER_ZOOM          equ 5    ; the zoom step game mode starts at: 640 px wide, 2x
SDL_BUTTON_LMASK     equ 1
PICKUP_STALE  equ 900        ; game mode: ticks a gun lies on the ground before
                             ; it turns up somewhere else (10.04, 15 s)
; A soldier grabs a pickup when its corner is within this of the
; pickup's. It was 15, under one body width, so the grabber had to
; stand almost ON the spot. A soldier holding a gun (who never picks
; anything up) standing there, boxed in by knife-wielding teammates who
; all wanted it, was a permanent stalemate (09's README). At
; SOLDIER_SIZE + 8, anyone touching that soldier can reach it.
PICKUP_RADIUS equ SOLDIER_SIZE + 8

; ---- pathfinding grid (see header) ----
CELL        equ 9
GRID_W      equ (WORLD_W - SOLDIER_SIZE + CELL - 1) / CELL + 1   ; 569
GRID_H      equ (WORLD_H - SOLDIER_SIZE + CELL - 1) / CELL + 1   ; 320
GRID_CELLS  equ GRID_W * GRID_H
UNREACHED   equ 0xFFFF
; (09-12 needed 9px cells so the grid mirrored exactly. The
; neighborhood isn't mirrored, but 9 still works fine.)

; ---- blockmap: one byte per soldier corner position ----
BM_W         equ WORLD_W - SOLDIER_SIZE + 1
BM_H         equ WORLD_H - SOLDIER_SIZE + 1
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
    .ox:     resd 1          ; the map point at its top left (9.01):
    .oy:     resd 1          ; drawing subtracts it
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

; a flow field's search, which can stop and carry on (9.03)
struc BfsState
    .field:  resq 1          ; uint16 per cell: distance, UNREACHED = none yet
    .queue:  resq 1          ; cells in the order they were reached
    .head:   resd 1          ; the next queued cell to expand
    .tail:   resd 1          ; one past the last queued cell
    .ready:  resd 1          ; 1 once the field has been cleared the slow way
    .pad:    resd 1
endstruc

struc Obstacle
    .x: resd 1
    .y: resd 1
    .w: resd 1
    .h: resd 1
endstruc

COLOR_TEAM0  equ 0xFFDC783C
COLOR_TEAM1  equ 0xFF3C3CDC
COLOR_CLOSED equ 0xFF7D7D82     ; a site nobody lives in this game (10.03)
COLOR_CLOSED_ROOF   equ 0xFF5F6978
COLOR_CLOSED_BORDER equ 0xFF303237
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
; ---- the camera (see header) ----
ZOOM_STEPS equ 8
PAN_SPEED  equ 8              ; screen pixels a frame, at any zoom
; ---- day and night (see header) ----
DAY_TICKS  equ 14400          ; 24 hours; must be a multiple of 1440
MIN_TICKS  equ DAY_TICKS / 1440   ; ticks per minute of the day
LM_SCALE   equ 2              ; light map: one cell per 2x2 pixels
LM_W       equ VIEW_MAX_W / LM_SCALE   ; the light map covers the view
LM_H       equ VIEW_MAX_H / LM_SCALE
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

EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96
