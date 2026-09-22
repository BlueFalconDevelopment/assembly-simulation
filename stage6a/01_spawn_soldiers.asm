; ============================================================
; 01 — An array of soldier structs, spawned and rendered
;
; This is the capstone's actual starting point: everything before
; this stage was one object (a ball, a player square). Now it's an
; ARRAY of structs, each describing one soldier, walked with a loop.
; No AI yet, no movement, no combat -- just proving the data layout
; and the "loop over N records, draw each one" pattern before any
; behavior gets built on top of it. Sixteen soldiers stand in two
; still lines, colored by team.
;
; No player, no camera, no input to speak of here beyond closing the
; window -- Stage 6 is a simulation you WATCH, not one you play.
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

WEAPON_KNIFE   equ 0
STATE_SEEK_ENEMY equ 1

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

; ---- one soldier. Everything Stage 6 does from here on is reading
; and writing these seven fields through a pointer, same as the
; FrameBuffer pattern from stage3 -- just a different block of memory
; with a different meaning. ----
struc Soldier
    .x:      resd 1
    .y:      resd 1
    .health: resd 1
    .team:   resd 1      ; 0 or 1
    .weapon: resd 1       ; 0=knife 1=pistol 2=shotgun
    .state:  resd 1          ; 0=seek_weapon 1=seek_enemy 2=attack 3=dead
    .target: resd 1             ; index of enemy or pickup, -1 = none
endstruc

COLOR_FIELD equ 0xFF50966E
COLOR_TEAM0 equ 0xFFDC783C   ; R=60  G=120 B=220 A=255 (blue)
COLOR_TEAM1 equ 0xFF3C3CDC   ; R=220 G=60  B=60  A=255 (red)

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title db "Stage 6a.01 - spawned soldiers", 0

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
    jz .render
    mov eax, [rsp + EVENT_OFF]
    cmp eax, SDL_QUIT_EVENT
    je .cleanup_all
    jmp .poll_events

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
; Places NUM_PER_TEAM soldiers in a vertical line on the left (team 0)
; and another on the right (team 1). No arguments, no return value --
; it just writes into the global `soldiers` array directly.
spawn_soldiers:
    push rbx

    xor ebx, ebx                  ; ebx = i = 0 (callee-saved -- this
                                      ; function makes no calls, but the
                                         ; habit of using a saved register
                                         ; for a loop index that outlives
                                         ; a single expression costs nothing)
.spawn_loop:
    cmp ebx, TOTAL_SOLDIERS
    jge .spawn_done

    mov eax, ebx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax                    ; r10 = &soldiers[i]

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
;   ./build/01_spawn_soldiers
; Eight blue squares in a vertical line on the left, eight red on the
; right, on an open green field. Nothing moves yet.
;
; Try this in gdb:
;   (gdb) break spawn_soldiers.spawn_done
;   (gdb) run
;   (gdb) print sizeof(struct Soldier)     # won't work -- gdb doesn't
;                                              know our struc as a type.
;                                              Instead just check the
;                                              raw bytes of soldier 0
;                                              and soldier 1 directly:
;   (gdb) print *(int*)&soldiers                        # soldier[0].x
;   (gdb) print *(int*)((char*)&soldiers + 28)           # soldier[1].x
;                                                            (28 = Soldier_size)
;   (gdb) print *(int*)((char*)&soldiers + 28*8)         # soldier[8].x
;                                                            -- first
;                                                            team-1 soldier,
;                                                            should be 700
;
; Questions to answer by experimenting:
;   - Change NUM_PER_TEAM to 10 (the top of the roadmap's 6-10 range).
;     Rebuild. Does the array size, the spawn loop, and the draw loop
;     all just work with zero other changes? That's the entire point
;     of writing them in terms of TOTAL_SOLDIERS instead of a literal
;     16 -- confirm it for real, don't just take it on faith.
;   - `Soldier.health` sits at byte offset 8 within each record (x=0,
;     y=4, health=8). Verify that by hand from the struc definition,
;     then confirm it against `print *(int*)((char*)&soldiers + 8)` in
;     gdb, which should read 100.
; ------------------------------------------------------------
