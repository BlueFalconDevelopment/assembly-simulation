; ============================================================
; 02 — Random spawn points (mirrored)
;
; 01_collision.asm with the fixed 5x10 spawn grid replaced by random
; positions, and the pickups jittered around their table spots.
;
; Every layout is still a mirror image across the middle: team 0's
; soldiers are placed at random on the left, and team 1's soldier k is
; the exact mirror of team 0's soldier k. Same for pickups. Each game
; gets a different map but neither team gets a better half, which is
; the kind of fairness stage6b/6c found the hard way.
;
; One ordering change in main that's easy to miss: srand now runs
; BEFORE the spawn functions. Before this file, spawning never called
; rand, so the order didn't matter. Now it would give every game the
; same "random" layout (rand's default seed), whatever the clock says.
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
extern rand
extern srand
extern time

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

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title db "Stage 7.02 - random mirrored spawns", 0
    win_msg0 db "Team 0 (blue) wins!", 10
    win_msg0_len equ $ - win_msg0
    win_msg1 db "Team 1 (red) wins!", 10
    win_msg1_len equ $ - win_msg1
    game_over dd 0
    pass_reverse dd 0

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

    ; seed FIRST -- the spawn functions below now call rand
    xor edi, edi
    call time
    mov edi, eax
    call srand

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

    cmp eax, 1
    jne .print_team1
    mov eax, 1
    mov edi, 1
    lea rsi, [win_msg0]
    mov edx, win_msg0_len
    syscall
    jmp .render
.print_team1:
    mov eax, 1
    mov edi, 1
    lea rsi, [win_msg1]
    mov edx, win_msg1_len
    syscall

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

    cmp dword [r10 + Soldier.health], 0
    jle .draw_next

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
    mov eax, [rsp + LOOP_I_OFF]
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .draw_loop
.draw_done:

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


; int rand_range(int n: edi) -> eax in [0, n)
; rand() % n. (The low bits of some rand()s are poor, but glibc's are
; fine, and the batch results are the real test anyway.)
rand_range:
    push rbx
    mov ebx, edi
    call rand
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

update_soldiers:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8
    sub rsp, 128                ; 96 in stage6b, +16 for US_FWD_STEP (6c),
                                ; +16 for US_STEP_X/Y

    call rand                  ; per-tick random processing direction (03_combat.asm's
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

    call rand
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp edx, r13d
    jge .update_next

    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r11, [soldiers]
    add r11, rax

    sub dword [r11 + Soldier.health], r12d
    cmp dword [r11 + Soldier.health], 0
    jg .update_next
    mov dword [r11 + Soldier.health], 0

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

; ------------------------------------------------------------
; Build and run:
;   make
;   ./build/02_random_spawn
; Or, to count wins over many games without watching them:
;   ./batch.sh 48
;
; Every launch is a different map (well, every launch in a different
; second -- srand(time(NULL)) again), but always a mirror image.
;
; Questions to answer by experimenting:
;   - Move `call srand` back after the spawn calls in main. Run it a few
;     times. What do you see, and why is it the same every time?
;   - Set NUM_PER_TEAM to 110 (or SPAWN_GAP to 40). The window never
;     opens -- why? Confirm it in gdb (Ctrl-C, then `bt`). How would you
;     make spawn_soldiers give up gracefully instead of retrying forever?
;   - Instead of mirroring, spawn team 1 independently at random on the
;     right. Batch it. The long-run split should still be about even,
;     but look at individual games: how often does a lopsided layout
;     decide the fight?
; ------------------------------------------------------------
