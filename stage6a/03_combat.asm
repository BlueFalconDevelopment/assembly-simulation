; ============================================================
; 03 — Combat resolution, death, and the win condition
;
; Knife-only fighting (pistol/shotgun and pickups are 04). Adds:
;
; - randomness: rand()/srand() from libc, called via `extern` exactly
;   like SDL's functions -- same calling convention, same "no
;   headers, just know the real signature" approach. Seeded once from
;   time(NULL) at startup so each run plays out differently.
; - a `.cooldown` field on Soldier: without it, two soldiers in range
;   would both roll to hit every single tick -- 60 attack attempts a
;   second, resolving a fight within one frame. Rate-limiting attacks
;   to roughly twice a second is what makes a fight watchable instead
;   of an instant coin-flip.
; - death: health clamped to 0, and the existing "skip if health<=0"
;   check in find_nearest_enemy / the draw loop already treats a dead
;   soldier as gone -- no new "is it dead" logic needed anywhere else,
;   because both of those already asked the right question from 01
;   onward.
; - a win check once per tick: count living soldiers per team, and
;   the moment one hits zero, freeze the simulation and print the
;   winner with a raw `write` syscall -- the exact same technique
;   from stage0/1, still the right tool for a one-off status line.
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
KNIFE_HIT_CHANCE      equ 70    ; percent
KNIFE_COOLDOWN_TICKS  equ 30    ; ~0.5s at 60fps

WEAPON_KNIFE     equ 0
STATE_SEEK_ENEMY equ 1

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

COLOR_FIELD equ 0xFF50966E
COLOR_TEAM0 equ 0xFFDC783C
COLOR_TEAM1 equ 0xFF3C3CDC

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title db "Stage 6a.03 - knife fight to the death", 0
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


; void update_soldiers(void)
;
; IMPORTANT: soldiers are NOT always processed in index order 0..15.
; Earlier drafts of this file did exactly that, and it produced a
; strong, consistent bias -- team 0 (indices 0-7) won roughly 11 of
; 12 test runs. The cause: when two soldiers are mutually in range on
; the same tick, whoever gets its turn FIRST in the loop attacks
; first, and if that attack kills its target, the victim's own turn
; -- still later in that same tick's loop -- never happens, because
; the dead-check at the top of the loop skips it. Team 0 always went
; first, so team 0 always got the first strike in every mutual
; engagement, every tick, for the whole fight.
;
; First attempted fix: toggle the processing direction every tick
; (a fixed period-2 alternation). That made things WORSE -- team 1
; started winning 9 of 10 runs. Why: KNIFE_COOLDOWN_TICKS is 30, an
; EVEN number, so a soldier's attack always lands back on the same
; tick parity it started on, forever (30 mod 2 == 0). A period-2
; alternation resonates with any other even period in the sim instead
; of averaging it out -- it just swapped which fixed parity, and
; therefore which team, was permanently favored.
;
; Actual fix: pick the processing direction with rand() once per
; tick instead of a fixed alternation. A random choice has no period,
; so it can't resonate with the cooldown's period (or any other fixed
; period a later stage might add) the way a deterministic toggle can.
US_I      equ -8
US_TARGET equ -16
US_ACTUAL equ -24

update_soldiers:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    call rand
    and eax, 1
    mov [pass_reverse], eax

    mov dword [rbp + US_I], 0
.update_loop:
    mov eax, [rbp + US_I]
    cmp eax, TOTAL_SOLDIERS
    jge .update_done

    ; derive the ACTUAL soldier index for this iteration from the
    ; loop counter -- forward on a normal pass, mirrored on a
    ; reversed one. US_I is just "which iteration," US_ACTUAL is
    ; "which soldier we're really touching."
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

    mov edi, [rbp + US_ACTUAL]
    call find_nearest_enemy
    cmp eax, -1
    je .update_next
    mov [rbp + US_TARGET], eax

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax                        ; r10 = &soldiers[self]

    mov eax, [rbp + US_TARGET]
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
    add r8d, r9d                                    ; dist_sq

    cmp r8d, CONTACT_RANGE * CONTACT_RANGE
    jg .move_toward_target

    ; ---- in range: attack, if off cooldown ----
    cmp dword [r10 + Soldier.cooldown], 0
    jg .update_next

    mov dword [r10 + Soldier.cooldown], KNIFE_COOLDOWN_TICKS

    call rand                    ; clobbers r10/r11 -- recompute target after
    xor edx, edx
    mov ecx, 100
    div ecx                        ; edx = rand() % 100
    cmp edx, KNIFE_HIT_CHANCE
    jge .update_next                  ; miss

    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r11, [soldiers]
    add r11, rax

    sub dword [r11 + Soldier.health], KNIFE_DAMAGE
    cmp dword [r11 + Soldier.health], 0
    jg .update_next
    mov dword [r11 + Soldier.health], 0
    jmp .update_next

.move_toward_target:
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
    mov rsp, rbp
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
    mov eax, 2                    ; team 0 has none left -> team 1 wins
    jmp .cw_return
.check_t1:
    test r12d, r12d
    jnz .cw_return                   ; both still have survivors
    mov eax, 1                          ; team 1 has none left -> team 0 wins
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
;   ./build/03_combat
; The lines converge, clash, and soldiers start disappearing as they
; die. When one team hits zero, the console prints the winner and the
; window freezes on the final frame (still closable).
;
; Try this in gdb:
;   (gdb) break update_soldiers.update_done
;   (gdb) run
;   (gdb) print *(int*)((char*)&soldiers + 8)    # soldier[0].health
;   ... `continue` repeatedly; health should hold at 100 until contact,
;   then drop in chunks of 34 roughly every 30 ticks (0.5s) once
;   soldier 0 is actually in range and its cooldown allows a roll
;
; Questions to answer by experimenting:
;   - Set KNIFE_HIT_CHANCE to 100 (always hits) and KNIFE_COOLDOWN_TICKS
;     to 1 (attack almost every tick). Rebuild. How fast does the
;     whole fight resolve now, and does that match your intuition for
;     why the cooldown existed in the first place?
;   - `check_win` is only called once `update.` sees game_over == 0.
;     Trace through what would happen if `check_win` were called
;     UNCONDITIONALLY every tick instead, including after the sim is
;     already over -- would the printed message repeat? Why does the
;     `jne .render` guard prevent that specifically?
;   - Two soldiers are both in range of each other and both off
;     cooldown on the same tick. Given the soldier array is processed
;     in index order, can BOTH successfully land a killing blow on
;     each other in the same tick (mutual death), or does processing
;     order make that impossible? Trace through `update_soldiers` by
;     hand for that case.
; ------------------------------------------------------------
