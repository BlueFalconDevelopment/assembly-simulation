; ============================================================
; 06 — Hold fire
;
; 05_friendly_fire.asm, but soldiers no longer shoot through their own
; team. 05 made shots hit whoever is first in the line of fire. With
; no check before firing, that meant about 15 friendly kills a game.
;
; Now, when a pistol or shotgun is ready to fire, the soldier first
; calls first_in_line itself. If the first soldier in the way is a
; teammate, it doesn't fire. It side-steps instead, using the same
; sticky perpendicular step (.side_step) that routes around walls, so
; its angle to the target changes, and it checks again next tick.
; An enemy in the way is fine: that enemy takes the shot, as in 05.
;
; The friendly-fire rule itself is unchanged, so the friendly-fire
; counters should now always read 0. The win line also counts how
; often soldiers held fire:
;   Team 0 (blue) wins! (friendly fire: 0 hits, 0 kills; held fire 812 times)
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

SDL_INIT_VIDEO              equ 0x00000020
SDL_WINDOWPOS_UNDEFINED     equ 0x1FFF0000
SDL_WINDOW_SHOWN            equ 0x00000004
SDL_RENDERER_ACCELERATED    equ 0x00000002
SDL_QUIT_EVENT               equ 0x100
FRAME_BUDGET_MS              equ 16
SDL_PIXELFORMAT_RGBA32       equ 0x16762004
SDL_TEXTUREACCESS_STREAMING  equ 1

SCREEN_W equ 800
SCREEN_H equ 600
OUR_PITCH equ SCREEN_W * 4

NUM_PER_TEAM   equ 50
; Team 0 spawns anywhere with its box's corner in this rectangle; team 1
; in its mirror. The right edge keeps the box (x..x+16) left of x=200,
; where the pickup zone starts.
SPAWN_MIN_X    equ 16
SPAWN_MAX_X    equ 184
SPAWN_MIN_Y    equ 16
SPAWN_MAX_Y    equ SCREEN_H - SOLDIER_SIZE - 16
; Minimum corner-to-corner spacing between two spawns on each axis.
; SOLDIER_SIZE would only prevent overlap; the extra 8px keeps
; soldiers from starting glued together.
SPAWN_GAP      equ SOLDIER_SIZE + 8
TOTAL_SOLDIERS equ NUM_PER_TEAM * 2
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

PICKUPS_PER_SIDE equ 8
PICKUP_JITTER    equ 30      ; each pickup lands up to this far from its
                             ; table spot, on each axis
; Weapons are conserved: every weapon is either lying in exactly one
; active pickup slot or held by exactly one living soldier, and a drop
; only happens when its holder dies. So the number of weapons on the
; ground can never exceed the number spawned at the start -- one slot
; per starting pickup is enough, with no spare "drop slots" needed.
MAX_PICKUPS   equ PICKUPS_PER_SIDE * 2
PICKUP_SIZE   equ 10
PICKUP_RADIUS equ 15

NUM_OBSTACLES equ 2

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

COLOR_FIELD  equ 0xFF50966E
COLOR_TEAM0  equ 0xFFDC783C
COLOR_TEAM1  equ 0xFF3C3CDC
COLOR_PICKUP_PISTOL  equ 0xFF28D2E6
COLOR_PICKUP_SHOTGUN equ 0xFFC83CAA
COLOR_OBSTACLE equ 0xFF505A64   ; R=100 G=90 B=80 A=255 -- grayish-brown cover
COLOR_BLADE    equ 0xFFF0F0F0   ; near-white
COLOR_TRACER   equ 0xFF50E6FF   ; R=255 G=230 B=80 -- yellow
COLOR_PELLET   equ 0xFF3CA0FF   ; R=255 G=160 B=60 -- orange
COLOR_SPARK    equ 0xFF28DCFF   ; R=255 G=220 B=40
COLOR_FLASH    equ 0xFFFFFFFF

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title db "Stage 7.06 - hold fire", 0
    win_msg0 db "Team 0 (blue) wins!"
    win_msg0_len equ $ - win_msg0
    win_msg1 db "Team 1 (red) wins!"
    win_msg1_len equ $ - win_msg1
    ff_msg1 db " (friendly fire: "
    ff_msg1_len equ $ - ff_msg1
    ff_msg2 db " hits, "
    ff_msg2_len equ $ - ff_msg2
    ff_msg3 db " kills; held fire "
    ff_msg3_len equ $ - ff_msg3
    ff_msg4 db " times)", 10
    ff_msg4_len equ $ - ff_msg4
    ff_held  dd 0
    ff_hits  dd 0
    ff_kills dd 0
    game_over dd 0
    pass_reverse dd 0
    rng_state    dq 0         ; xorshift64 state -- must never be 0

    ; Left half of the pickup layout: x, y, type per entry. spawn_pickups
    ; jitters each one by up to PICKUP_JITTER, then places it AND its
    ; left-right mirror, so position and weapon type are still symmetric
    ; between the teams. Two columns between the spawn area and the
    ; wall (x 200-350 after jitter), checkerboarded pistol/shotgun so no
    ; stretch of the field gets only one kind of weapon.
    left_pickups:
        dd 230,  80, WEAPON_PISTOL
        dd 310,  80, WEAPON_SHOTGUN
        dd 230, 220, WEAPON_SHOTGUN
        dd 310, 220, WEAPON_PISTOL
        dd 230, 370, WEAPON_PISTOL
        dd 310, 370, WEAPON_SHOTGUN
        dd 230, 510, WEAPON_SHOTGUN
        dd 310, 510, WEAPON_PISTOL
    LEFT_PICKUP_ENTRY equ 12      ; bytes per entry (3 dwords)
%if ($ - left_pickups) != PICKUPS_PER_SIDE * LEFT_PICKUP_ENTRY
    %error "left_pickups table size doesn't match PICKUPS_PER_SIDE"
%endif

    back_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq back_buffer
        at FrameBuffer.pitch,  dd OUR_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd SCREEN_H
    iend

section .bss
    back_buffer resb SCREEN_W * SCREEN_H * 4
    soldiers    resb TOTAL_SOLDIERS * Soldier_size
    pickups     resb MAX_PICKUPS * Pickup_size
    obstacles   resb NUM_OBSTACLES * Obstacle_size
    effects     resb MAX_EFFECTS * Effect_size
    fx_next     resd 1                  ; next ring-buffer slot to fill
    hit_flash    resd TOTAL_SOLDIERS    ; frames left drawn white
    death_linger resd TOTAL_SOLDIERS    ; frames a dead soldier stays drawn
    msg_buf      resb 128               ; the win line, built by print_result

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

    call spawn_obstacles
    call spawn_soldiers
    call spawn_pickups

    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    test eax, eax
    js .cleanup_none

    lea rdi, [title]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, SCREEN_W
    mov r8d, SCREEN_H
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
    mov r8d, SCREEN_H
    call SDL_CreateTexture
    mov r14, rax
    test r14, r14
    jz .cleanup_renderer

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
    call check_win
    test eax, eax
    jz .render
    mov [game_over], eax

    lea rsi, [win_msg0]
    mov edx, win_msg0_len
    cmp eax, 1
    je .have_win_msg
    lea rsi, [win_msg1]
    mov edx, win_msg1_len
.have_win_msg:
    call print_result

.render:
    lea rdi, [back_fb]
    xor esi, esi
    xor edx, edx
    mov ecx, SCREEN_W
    mov r8d, SCREEN_H
    mov r9d, COLOR_FIELD
    call fill_rect

    ; ---- obstacles ----
    mov dword [rsp + LOOP_I_OFF], 0
.obstacle_draw_loop:
    mov eax, [rsp + LOOP_I_OFF]
    cmp eax, NUM_OBSTACLES
    jge .obstacle_draw_done

    imul eax, Obstacle_size
    lea r10, [obstacles]
    add r10, rax

    lea rdi, [back_fb]
    mov esi, [r10 + Obstacle.x]
    mov edx, [r10 + Obstacle.y]
    mov ecx, [r10 + Obstacle.w]
    mov r8d, [r10 + Obstacle.h]
    mov r9d, COLOR_OBSTACLE
    call fill_rect

    mov eax, [rsp + LOOP_I_OFF]
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .obstacle_draw_loop
.obstacle_draw_done:

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

    lea rcx, [hit_flash]
    cmp dword [rcx + rax*4], 0
    jle .no_flash
    mov r9d, COLOR_FLASH
    jmp .have_color
.no_flash:
    mov eax, [r10 + Soldier.team]
    test eax, eax
    jnz .team1_color
    mov r9d, COLOR_TEAM0
    jmp .have_color
.team1_color:
    mov r9d, COLOR_TEAM1
.have_color:
    lea rdi, [back_fb]
    mov esi, [r10 + Soldier.x]
    mov edx, [r10 + Soldier.y]
    mov ecx, SOLDIER_SIZE
    mov r8d, SOLDIER_SIZE
    call fill_rect

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

    ; ---- attack effects, on top of everything ----
    call draw_effects

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
    cmp r15d, SCREEN_H
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
    mov dword [r10 + Soldier.team], %4
    mov dword [r10 + Soldier.health], 100
    mov dword [r10 + Soldier.weapon], WEAPON_KNIFE
    mov dword [r10 + Soldier.state], STATE_SEEK_ENEMY
    mov dword [r10 + Soldier.target], -1
    mov dword [r10 + Soldier.cooldown], 0
    mov dword [r10 + Soldier.avoid_dir], 0
%endmacro

; void spawn_soldiers(void)
; For each k: pick a random spot in team 0's spawn rectangle, and try
; again if it's within SPAWN_GAP (on both axes) of any team 0 soldier
; already placed. Then place team 0's soldier k there and team 1's
; soldier k at the mirror image (same rule as stage6c:
; x' = SCREEN_W - SOLDIER_SIZE - x).
;
; Only team 0's spots need checking against each other. The mirror of a
; valid team 0 layout is automatically a valid team 1 layout, and the
; two halves can't touch, since the whole spawn area is left of x=200.
;
; The retry loop has no attempt limit, and at these numbers it doesn't
; need one. A Python simulation of this exact loop over 2000 layouts
; averaged ~111 random tries for all 50 soldiers, and the unluckiest
; single soldier needed 32. It's not "plenty of room," though: past
; roughly 100 per team the rectangle jams (no gap left anywhere) and
; this loop would spin forever. See the exercise at the bottom.
spawn_soldiers:
    push rbx
    push r12
    push r13
    push r14
    push r15

    xor r12d, r12d                        ; k
.ss_next_k:
    cmp r12d, NUM_PER_TEAM
    jge .ss_done

.ss_retry:
    mov edi, SPAWN_MAX_X - SPAWN_MIN_X + 1
    call rand_range
    lea r13d, [eax + SPAWN_MIN_X]        ; x
    mov edi, SPAWN_MAX_Y - SPAWN_MIN_Y + 1
    call rand_range
    lea r14d, [eax + SPAWN_MIN_Y]        ; y

    ; too close to an already-placed team 0 soldier (0..k-1)?
    xor ebx, ebx
.ss_check:
    cmp ebx, r12d
    jge .ss_place
    mov eax, ebx
    imul eax, Soldier_size
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
    jl .ss_retry                          ; too close on both axes
.ss_check_next:
    inc ebx
    jmp .ss_check

.ss_place:
    INIT_SOLDIER r12d, r13d, r14d, 0

    mov r15d, SCREEN_W - SOLDIER_SIZE
    sub r15d, r13d                        ; mirrored x
    lea ebx, [r12d + NUM_PER_TEAM]
    INIT_SOLDIER ebx, r15d, r14d, 1

    inc r12d
    jmp .ss_next_k
.ss_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void spawn_pickups(void)
; Pickup 2i is left_pickups[i] moved by a random offset in
; [-PICKUP_JITTER, +PICKUP_JITTER] on each axis; pickup 2i+1 is its
; mirror, with the same type. Weapon TYPE has to mirror too, not just
; position -- see stage6b's README bug #3.
;
; The mirror uses SOLDIER_SIZE, not PICKUP_SIZE, on purpose. Every
; distance the AI measures is corner to corner (soldier top-left to
; pickup top-left), so the pickup's corner has to mirror the same way a
; soldier's does or one team ends up 6px closer to every weapon. See
; stage6c's README, bug #2.
spawn_pickups:
    push rbx
    push r12
    push r13
    push r14
    push r15

    lea r12, [pickups]
    lea r13, [left_pickups]
    xor r14d, r14d
.sp_loop:
    cmp r14d, PICKUPS_PER_SIDE
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
    mov r8d, [r13 + 8]                    ; type

    mov [r12 + Pickup.x], ebx
    mov [r12 + Pickup.y], r15d
    mov [r12 + Pickup.type], r8d
    mov dword [r12 + Pickup.active], 1
    add r12, Pickup_size

    mov eax, SCREEN_W - SOLDIER_SIZE
    sub eax, ebx                          ; mirror the corner the AI measures from
    mov [r12 + Pickup.x], eax
    mov [r12 + Pickup.y], r15d
    mov [r12 + Pickup.type], r8d
    mov dword [r12 + Pickup.active], 1
    add r12, Pickup_size

    add r13, LEFT_PICKUP_ENTRY
    inc r14d
    jmp .sp_loop
.sp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void spawn_obstacles(void)
; One wall, split into two segments with a gap in the middle (y
; 220-380). Soldiers cross from the west spawn line to the east one
; (or vice versa) to fight, which means crossing this wall's x-range
; (370-430) at some point -- if their row falls inside a segment's
; y-range, their direct path IS blocked and the perpendicular
; side-step has to actually fire to route them toward the gap. This
; is deliberately more aggressive than "scattered cover pieces,"
; which (an earlier draft found) a symmetric spawn layout could
; often route around by accident, without the avoidance code ever
; really being exercised.
spawn_obstacles:
    lea r10, [obstacles]

    mov dword [r10 + 0*Obstacle_size + Obstacle.x], 370
    mov dword [r10 + 0*Obstacle_size + Obstacle.y], 0
    mov dword [r10 + 0*Obstacle_size + Obstacle.w], 60
    mov dword [r10 + 0*Obstacle_size + Obstacle.h], 220

    mov dword [r10 + 1*Obstacle_size + Obstacle.x], 370
    mov dword [r10 + 1*Obstacle_size + Obstacle.y], 380
    mov dword [r10 + 1*Obstacle_size + Obstacle.w], 60
    mov dword [r10 + 1*Obstacle_size + Obstacle.h], 220
    ret


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
;
; Tests the soldier's actual SOLDIER_SIZE x SOLDIER_SIZE body (a box
; anchored at x,y -- matching exactly what fill_rect draws), not just
; the bare corner point. An earlier draft (named is_point_in_obstacle)
; tested only the point, which meant a soldier could visually overlap
; up to SOLDIER_SIZE-1 pixels of a wall before their tracked corner
; itself registered as blocked -- looked like walking partway through
; solid cover. Two axis-aligned boxes overlap unless one is entirely
; to the left/right/above/below the other; that's the four `jge`s
; below (the standard AABB-overlap test, its usual form negated once
; since we want "blocked" = "they DO overlap").
;
; Also treats anything off the SCREEN_W x SCREEN_H field as blocked,
; not just points inside an Obstacle rect (now checking the FULL box
; stays on-screen, same reasoning, not just its corner). Found the
; hard way: the perpendicular side-step in update_soldiers applies a
; raw add/sub to Soldier.x/y with no clamp of its own (unlike the
; normal clamped-toward-goal move, which never wanders off-screen
; because goals are always on-screen) -- with obstacle0 sitting right
; at the top edge (y=0), a soldier repeatedly routed "up" around it
; walked straight off the field into negative y, and fill_rect's
; write ("row * pitch + col * 4") only clips the FAR edge, never
; checks for a negative one, which corrupted the write address into
; unmapped memory and segfaulted. Every side-step decision already
; funnels through this one function, so treating the screen edge as
; just another kind of "can't go there" fixes it at the single source
; instead of adding a bounds check to every caller.
is_box_blocked:
    cmp edi, 0
    jl .blocked
    mov eax, edi
    add eax, SOLDIER_SIZE
    cmp eax, SCREEN_W
    jg .blocked
    cmp esi, 0
    jl .blocked
    mov eax, esi
    add eax, SOLDIER_SIZE
    cmp eax, SCREEN_H
    jg .blocked
    jmp .check_obstacles
.blocked:
    mov eax, 1
    ret
.check_obstacles:
    push rbx
    xor ebx, ebx
.iio_loop:
    cmp ebx, NUM_OBSTACLES
    jge .iio_clear

    mov eax, ebx
    imul eax, Obstacle_size
    lea r10, [obstacles]
    add r10, rax

    ; soldier box: [edi, edi+SOLDIER_SIZE) x [esi, esi+SOLDIER_SIZE)
    ; obstacle box: [Obstacle.x, Obstacle.x+w) x [Obstacle.y, Obstacle.y+h)
    ; NOT overlapping (skip this obstacle) if the soldier box is
    ; entirely left of, right of, above, or below the obstacle box
    mov eax, edi
    add eax, SOLDIER_SIZE
    cmp eax, [r10 + Obstacle.x]
    jle .iio_next                        ; soldier box entirely left of obstacle

    mov eax, [r10 + Obstacle.x]
    add eax, [r10 + Obstacle.w]
    cmp edi, eax
    jge .iio_next                        ; soldier box entirely right of obstacle

    mov eax, esi
    add eax, SOLDIER_SIZE
    cmp eax, [r10 + Obstacle.y]
    jle .iio_next                        ; soldier box entirely above obstacle

    mov eax, [r10 + Obstacle.y]
    add eax, [r10 + Obstacle.h]
    cmp esi, eax
    jge .iio_next                        ; soldier box entirely below obstacle

    mov eax, 1
    pop rbx
    ret
.iio_next:
    inc ebx
    jmp .iio_loop
.iio_clear:
    xor eax, eax
    pop rbx
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

line_blocked:
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
    call is_box_blocked
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
    call line_blocked
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
    jnz .side_step

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
    ; is, so "first choice" here means FORWARD, toward the enemy's side:
    ; +x for team 0, -x for team 1. See stage6c's README, bug #1 -- a
    ; plain "left first" gave the team on the right 39 of 48 games.
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, MOVE_SPEED
    cmp dword [r10 + Soldier.team], 0
    je .have_fwd_step
    neg eax
.have_fwd_step:
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

    lea rsi, [msg_buf]
    mov rdx, rdi
    sub rdx, rsi                    ; length = end - start
    mov eax, 1                      ; write(stdout, msg_buf, len)
    mov edi, 1
    syscall
    pop rbx
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

    mov eax, r13d
    imul eax, Soldier_size
    lea r9, [soldiers]
    add r9, rax
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


; int check_win(void) -> eax: 0 = ongoing, 1 = team 0 wins, 2 = team 1 wins
check_win:
    push rbx
    push r12
    xor ebx, ebx
    xor r12d, r12d
    xor ecx, ecx
.cw_loop:
    cmp ecx, TOTAL_SOLDIERS
    jge .cw_done

    mov eax, ecx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .cw_next

    mov eax, [r10 + Soldier.team]
    test eax, eax
    jnz .cw_team1
    inc ebx
    jmp .cw_next
.cw_team1:
    inc r12d
.cw_next:
    inc ecx
    jmp .cw_loop
.cw_done:
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
;   ./build/06_hold_fire
; Or, to count wins over many games without watching them -- and with
; rdtsc seeding, they can all launch at once:
;   STAGGER=0 ./batch.sh 48
;
; Questions to answer by experimenting:
;   - Replace `call rng_seed` with `mov qword [rng_state], 1`. Every
;     game is now identical. When would you WANT that? (Hint: stage6b's
;     bug #5 took a per-tick trace to find. How much easier is that if
;     you can replay the exact same game on demand?)
;   - Change rng_next to return the LOW 32 bits (drop the `shr rax, 32`)
;     and batch it. Does the fairness split change? Would you expect it
;     to, given what update_soldiers does with bit 0?
;   - Remove the splitmix64 mix from rng_seed (store the raw rdtsc
;     value). Launch two games a fraction of a second apart and compare
;     their first few rng_next outputs in gdb. How many bits differ?
; ------------------------------------------------------------
