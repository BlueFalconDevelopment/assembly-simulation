; ============================================================
; 02 — Finding the nearest enemy, and moving toward them
;
; Two new functions on top of 01's spawn+render skeleton:
;
; find_nearest_enemy(self_index) scans every OTHER living soldier on
; the opposing team and tracks whichever has the smallest squared
; distance so far -- exactly the "compare squared distances, skip
; the square root" the roadmap calls for. Comparing dx*dx+dy*dy never
; needs a real distance, just a way to rank candidates, so the
; expensive sqrt never has to happen at all.
;
; update_soldiers(), called once per tick, calls that for every
; living soldier and steps them toward whatever it finds, MOVE_SPEED
; pixels per axis per tick, clamped so they don't overshoot -- same
; clamped-step idea as stage5's edge clamp, just aimed at a moving
; target instead of a wall.
;
; No combat yet -- soldiers that reach CONTACT_RANGE of their target
; just stop there. Watch for clustering in the middle: a soldier only
; reacts to ITS single nearest enemy, so it can get "blocked" holding
; position near a target that isn't the specific soldier converging
; on it too -- that's real behavior falling out of the rule, not a
; bug to fix here.
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

NUM_PER_TEAM   equ 8
TOTAL_SOLDIERS equ NUM_PER_TEAM * 2
SOLDIER_SIZE   equ 16
MOVE_SPEED     equ 2
CONTACT_RANGE  equ 20

WEAPON_KNIFE     equ 0
STATE_SEEK_ENEMY equ 1

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

struc Soldier
    .x:      resd 1
    .y:      resd 1
    .health: resd 1
    .team:   resd 1
    .weapon: resd 1
    .state:  resd 1
    .target: resd 1
endstruc

COLOR_FIELD equ 0xFF50966E
COLOR_TEAM0 equ 0xFFDC783C
COLOR_TEAM1 equ 0xFF3C3CDC

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title db "Stage 6a.02 - seeking (no combat yet)", 0

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
    call update_soldiers

.render:
    lea rdi, [back_fb]
    xor esi, esi
    xor edx, edx
    mov ecx, SCREEN_W
    mov r8d, SCREEN_H
    mov r9d, COLOR_FIELD
    call fill_rect

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

    inc ebx
    jmp .spawn_loop
.spawn_done:
    pop rbx
    ret


; int find_nearest_enemy(int self_index: edi) -> eax (index, or -1)
; Scans every living soldier on the other team, keeps the one with
; the smallest dx*dx+dy*dy seen so far. Named stack locals throughout
; -- this function is called once per living soldier per tick and
; itself loops TOTAL_SOLDIERS times, so at this scale (a few hundred
; iterations per tick, total) clarity costs nothing measurable.
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


; void update_soldiers(void)
; Called once per tick. For every living soldier: find its nearest
; living enemy, and if not already within CONTACT_RANGE, step
; MOVE_SPEED pixels toward it on each axis (clamped so it can't
; overshoot past the target in one tick).
US_I equ -8

update_soldiers:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    mov dword [rbp + US_I], 0
.update_loop:
    mov eax, [rbp + US_I]
    cmp eax, TOTAL_SOLDIERS
    jge .update_done

    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .update_next

    mov edi, [rbp + US_I]
    call find_nearest_enemy       ; r10/r11 etc. do NOT survive this call
    cmp eax, -1
    je .update_next

    mov ecx, eax                     ; ecx = target index

    mov eax, [rbp + US_I]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax                        ; r10 = &soldiers[self]

    mov eax, ecx
    imul eax, Soldier_size
    lea r11, [soldiers]
    add r11, rax                           ; r11 = &soldiers[target]

    mov eax, [r11 + Soldier.x]
    sub eax, [r10 + Soldier.x]                ; eax = dx
    mov ecx, [r11 + Soldier.y]
    sub ecx, [r10 + Soldier.y]                   ; ecx = dy

    mov r8d, eax
    imul r8d, r8d
    mov r9d, ecx
    imul r9d, r9d
    add r8d, r9d                                    ; r8d = dist_sq
    cmp r8d, CONTACT_RANGE * CONTACT_RANGE
    jle .update_next                                   ; close enough -- hold position

    ; step x toward target, clamped to MOVE_SPEED
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

    ; step y toward target, clamped to MOVE_SPEED
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
    mov rsp, rbp
    pop rbp
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
;   ./build/02_seek_enemy
; Both lines should advance toward each other and stop once each
; soldier is CONTACT_RANGE from whichever enemy it locked onto --
; expect some clustering, not perfectly paired-off soldiers.
;
; Try this in gdb:
;   (gdb) break update_soldiers.update_done
;   (gdb) run
;   (gdb) print *(int*)&soldiers            # soldier[0].x -- should
;                                               have decreased from
;                                               100 (team 0 moves right,
;                                               toward team 1)
;   (gdb) continue
;   (gdb) print *(int*)&soldiers            # should have decreased
;                                               again, by MOVE_SPEED
;                                               (or stayed put, if it's
;                                               already at CONTACT_RANGE)
;
; Questions to answer by experimenting:
;   - Set a breakpoint on `find_nearest_enemy.scan_done` and check
;     `eax` right before `ret` for soldier index 0 on the very first
;     tick. Given the spawn layout (team 0 on the left at x=100, team
;     1 on the right at x=700, both in vertical lines), which team-1
;     index would you PREDICT is nearest to soldier 0 before you
;     check? Then check.
;   - Change CONTACT_RANGE to 200 (much larger). Rebuild. Do the two
;     lines now stop far apart, while still LOOKING like they haven't
;     reached each other? This is deliberately testing whether you
;     understand CONTACT_RANGE as a pure number in the simulation, not
;     tied to anything visual on screen.
;   - `find_nearest_enemy` is called once PER LIVING SOLDIER per tick,
;     and itself scans all TOTAL_SOLDIERS entries. At 16 soldiers
;     that's at most 256 comparisons a tick, 60 times a second. Work
;     out what that number becomes at the roadmap's 50v50 stretch
;     goal (6c), and compare it to modern CPU speeds -- is this
;     anywhere close to a real performance concern?
; ------------------------------------------------------------
