; ============================================================
; 01 — Obstacles, and movement that routes around them
;
; A fixed set of rectangular `Obstacle` blocks now sit on the field
; (same "struct array + struc" pattern as Soldier/Pickup). Soldiers
; must not walk through them.
;
; The movement rule, straight from the roadmap: before stepping
; toward a goal, check whether the STRAIGHT LINE from here to the
; goal is blocked by an obstacle. If it's clear, move directly (the
; existing clamped-step code, unchanged). If it's blocked, don't try
; to path around intelligently (no A*) -- just step sideways,
; perpendicular to the goal direction, trying one side and then the
; other, and take whichever is clear. Repeated over several ticks,
; this is enough to walk around a rectangular block without ever
; computing a real path.
;
; `line_blocked` is exactly stage3's `draw_line` Bresenham walk, with
; `set_pixel` swapped for a per-step `is_box_blocked` check and
; an early return the moment any step lands inside a block. This is
; the reuse the roadmap called out three stages ago: the same
; line-stepping idea, now answering "is anything in the way" instead
; of "color this pixel."
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

NUM_PER_TEAM   equ 8
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

MAX_PICKUPS   equ 8
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
    title db "Stage 6b.01 - obstacles block movement", 0
    win_msg0 db "Team 0 (blue) wins!", 10
    win_msg0_len equ $ - win_msg0
    win_msg1 db "Team 1 (red) wins!", 10
    win_msg1_len equ $ - win_msg1
    game_over dd 0
    pass_reverse dd 0

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

    call spawn_soldiers
    call spawn_pickups
    call spawn_obstacles

    xor edi, edi
    call time
    mov edi, eax
    call srand

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


; void spawn_soldiers(void)
spawn_soldiers:
    push rbx
    xor ebx, ebx
.spawn_loop:
    cmp ebx, TOTAL_SOLDIERS
    jge .spawn_done

    mov eax, ebx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    cmp ebx, NUM_PER_TEAM
    jl .team0

    mov dword [r10 + Soldier.team], 1
    mov dword [r10 + Soldier.x], 700
    mov eax, ebx
    sub eax, NUM_PER_TEAM
    jmp .compute_y
.team0:
    mov dword [r10 + Soldier.team], 0
    mov dword [r10 + Soldier.x], 100
    mov eax, ebx
.compute_y:
    imul eax, 50
    add eax, 80
    mov [r10 + Soldier.y], eax

    mov dword [r10 + Soldier.health], 100
    mov dword [r10 + Soldier.weapon], WEAPON_KNIFE
    mov dword [r10 + Soldier.state], STATE_SEEK_ENEMY
    mov dword [r10 + Soldier.target], -1
    mov dword [r10 + Soldier.cooldown], 0

    inc ebx
    jmp .spawn_loop
.spawn_done:
    pop rbx
    ret


; void spawn_pickups(void)
; Weapon TYPE is mirrored left-right (both top pickups pistols, both
; bottom pickups shotguns), matching the teams' spawn symmetry -- see
; stage6a/04_weapons.asm's spawn_pickups and the README for why this
; matters: a rotationally-symmetric (instead of mirror-symmetric)
; assignment here produced a reproducible 24-of-24 win rate for
; whichever side's exposed rows happened to hold the pistol.
spawn_pickups:
    lea r10, [pickups]

    mov dword [r10 + 0*Pickup_size + Pickup.x], 300
    mov dword [r10 + 0*Pickup_size + Pickup.y], 200
    mov dword [r10 + 0*Pickup_size + Pickup.type], WEAPON_PISTOL
    mov dword [r10 + 0*Pickup_size + Pickup.active], 1

    mov dword [r10 + 1*Pickup_size + Pickup.x], 500
    mov dword [r10 + 1*Pickup_size + Pickup.y], 200
    mov dword [r10 + 1*Pickup_size + Pickup.type], WEAPON_PISTOL
    mov dword [r10 + 1*Pickup_size + Pickup.active], 1

    mov dword [r10 + 2*Pickup_size + Pickup.x], 300
    mov dword [r10 + 2*Pickup_size + Pickup.y], 400
    mov dword [r10 + 2*Pickup_size + Pickup.type], WEAPON_SHOTGUN
    mov dword [r10 + 2*Pickup_size + Pickup.active], 1

    mov dword [r10 + 3*Pickup_size + Pickup.x], 500
    mov dword [r10 + 3*Pickup_size + Pickup.y], 400
    mov dword [r10 + 3*Pickup_size + Pickup.type], WEAPON_SHOTGUN
    mov dword [r10 + 3*Pickup_size + Pickup.active], 1
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
; Same overall shape as stage6a/04. The one change: `.do_move` now
; checks line_blocked before taking the direct clamped step, and
; side-steps perpendicular to the goal direction if blocked.
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

update_soldiers:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8
    sub rsp, 96

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
    ; ---- is the direct path to the goal clear? ----
    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    mov edx, [rbp + US_GOAL_X]
    mov ecx, [rbp + US_GOAL_Y]
    call line_blocked
    test eax, eax
    jz .path_clear

    ; ---- blocked: step perpendicular to the goal direction instead ----
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

    ; goal is mostly sideways -- the obstacle is blocking horizontal
    ; travel, so try stepping vertically around it: up first, then down
    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    sub esi, MOVE_SPEED
    call is_box_blocked
    test eax, eax
    jz .apply_up

    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    add esi, MOVE_SPEED
    call is_box_blocked
    test eax, eax
    jnz .update_next                 ; both sides blocked -- hold position

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    add dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.apply_up:
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    sub dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next

.try_horizontal:
    ; goal is mostly vertical -- try stepping left first, then right
    mov edi, [rbp + US_SELF_X]
    sub edi, MOVE_SPEED
    mov esi, [rbp + US_SELF_Y]
    call is_box_blocked
    test eax, eax
    jz .apply_left

    mov edi, [rbp + US_SELF_X]
    add edi, MOVE_SPEED
    mov esi, [rbp + US_SELF_Y]
    call is_box_blocked
    test eax, eax
    jnz .update_next

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    add dword [r10 + Soldier.x], MOVE_SPEED
    jmp .update_next
.apply_left:
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    sub dword [r10 + Soldier.x], MOVE_SPEED
    jmp .update_next

.path_clear:
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    mov eax, [rbp + US_GOAL_X]
    sub eax, [r10 + Soldier.x]
    mov ecx, [rbp + US_GOAL_Y]
    sub ecx, [r10 + Soldier.y]

    cmp eax, 0
    je .no_move_x
    jg .move_x_pos
    neg eax
    cmp eax, MOVE_SPEED
    jle .apply_neg_x
    mov eax, MOVE_SPEED
.apply_neg_x:
    neg eax
    add [r10 + Soldier.x], eax
    jmp .no_move_x
.move_x_pos:
    cmp eax, MOVE_SPEED
    jle .apply_pos_x
    mov eax, MOVE_SPEED
.apply_pos_x:
    add [r10 + Soldier.x], eax
.no_move_x:

    cmp ecx, 0
    je .no_move_y
    jg .move_y_pos
    neg ecx
    cmp ecx, MOVE_SPEED
    jle .apply_neg_y
    mov ecx, MOVE_SPEED
.apply_neg_y:
    neg ecx
    add [r10 + Soldier.y], ecx
    jmp .no_move_y
.move_y_pos:
    cmp ecx, MOVE_SPEED
    jle .apply_pos_y
    mov ecx, MOVE_SPEED
.apply_pos_y:
    add [r10 + Soldier.y], ecx
.no_move_y:

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
;   ./build/01_obstacles
; A grayish-brown wall (two segments, a gap in the middle) now splits
; the field roughly down the center. Soldiers whose straight path to
; their goal is blocked by a segment should visibly sidestep toward
; the gap instead of walking through it.
;
; Try this in gdb:
;   (gdb) print (int)is_box_blocked(400, 100)   # won't work --
;     gdb can't call our functions like C ones without more setup.
;     Instead, break inside it and inspect:
;   (gdb) break is_box_blocked
;   (gdb) run
;   (gdb) print $edi
;   (gdb) print $esi
;   (gdb) finish                # shows the return value once debug
;                                   info allows it, or check $eax after
;
; Questions to answer by experimenting:
;   - Temporarily close the gap -- change the second segment's height
;     in spawn_obstacles so the two segments together span the whole
;     field, y=0 to y=600, with no opening. Rebuild and watch what
;     happens to soldiers trying to cross it -- does the perpendicular
;     side-step ever get them through, or do they just slide along the
;     wall forever? What does this tell you about the real difference
;     between this technique and actual pathfinding?
;   - `line_blocked` walks EVERY point between two soldiers that might
;     be 600+ pixels apart, calling `is_box_blocked` (itself a
;     loop over NUM_OBSTACLES) at every single step. Work out roughly
;     how many total checks one `do_move` call can trigger in the
;     worst case, and compare that to stage6a's README note about
;     50v50 performance headroom -- does this change the answer?
;   - The vertical-vs-horizontal choice in the "blocked" branch is
;     based on which of |dx|/|dy| is bigger. Construct a scenario
;     (goal position relative to self) where this heuristic picks the
;     WRONG axis to slide along -- i.e., sliding the chosen way still
;     can't clear the obstacle, but the other axis would have.
; ------------------------------------------------------------
