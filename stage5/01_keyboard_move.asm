; ============================================================
; 01 — Reading keyboard input, and using it to drive movement
;
; Stage 4's ball moved on its own, from state nobody outside the
; program ever touched. This one replaces that with a square that
; moves only when the player holds an arrow key -- the exact same
; "update state, then draw it" structure, just fed by input instead
; of a fixed velocity.
;
; SDL_GetKeyboardState(NULL) returns a pointer to an array of Uint8,
; one byte per key, indexed by SDL_SCANCODE_* -- nonzero means
; currently held down. Unlike SDL_PollEvent (which drains one queued
; event at a time and needs calling every frame), this pointer is
; STABLE for the whole program and kept live-updated by SDL
; internally as part of its event pumping -- so we call it exactly
; once, before the loop, and just keep reading through the same
; pointer forever. Knowing which SDL calls are "drain a queue" vs.
; "read a live snapshot" matters -- get it backwards and you either
; waste calls or miss input.
;
; Everything else (the back buffer, the blit, the scene) is
; unchanged from stage4/02.
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
extern SDL_GetKeyboardState
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

; ---- looked up via a small C probe against the real headers, same
; as stage3's pixel format constant -- scancodes are just numbers,
; easy to mistype by hand ----
SDL_SCANCODE_RIGHT equ 79
SDL_SCANCODE_LEFT  equ 80
SDL_SCANCODE_DOWN  equ 81
SDL_SCANCODE_UP    equ 82

SCREEN_W equ 800
SCREEN_H equ 600
PLAYER_SIZE equ 30
MOVE_SPEED equ 5
OUR_PITCH equ SCREEN_W * 4

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

COLOR_SKY     equ 0xFFFFAA64
COLOR_MUD     equ 0xFF3C8C5A
COLOR_HORIZON equ 0xFF323C46
COLOR_PLAYER  equ 0xFF2050F0

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
STACK_LOCALS_SIZE equ 80

section .data
    title db "Stage 5.01 - arrow keys to move", 0
    player_x dd 380
    player_y dd 280

    back_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq back_buffer
        at FrameBuffer.pitch,  dd OUR_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd SCREEN_H
    iend

section .bss
    back_buffer resb SCREEN_W * SCREEN_H * 4

section .text
main:
    push rbp
    mov rbp, rsp
    push rbx              ; frame start time
    push r12                 ; SDL_Window*
    push r13                    ; SDL_Renderer*
    push r14                       ; SDL_Texture*
    push r15                          ; keyboard state array pointer (stable
                                          ; for the whole program's lifetime)
    sub rsp, 8                          ; alignment pad (6 pushes above = even)
    sub rsp, STACK_LOCALS_SIZE

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

    xor edi, edi               ; SDL_GetKeyboardState(NULL) -- we don't
    call SDL_GetKeyboardState     ; care about the key count, just the array
    mov r15, rax

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
    cmp byte [r15 + SDL_SCANCODE_LEFT], 0
    je .no_left
    sub dword [player_x], MOVE_SPEED
.no_left:
    cmp byte [r15 + SDL_SCANCODE_RIGHT], 0
    je .no_right
    add dword [player_x], MOVE_SPEED
.no_right:
    cmp byte [r15 + SDL_SCANCODE_UP], 0
    je .no_up
    sub dword [player_y], MOVE_SPEED
.no_up:
    cmp byte [r15 + SDL_SCANCODE_DOWN], 0
    je .no_down
    add dword [player_y], MOVE_SPEED
.no_down:

    ; clamp to the screen -- unlike stage4's bounce, holding a key
    ; against the edge should just stop, not reverse
    mov eax, [player_x]
    cmp eax, 0
    jge .x_low_ok
    xor eax, eax
.x_low_ok:
    mov ecx, SCREEN_W - PLAYER_SIZE
    cmp eax, ecx
    jle .x_high_ok
    mov eax, ecx
.x_high_ok:
    mov [player_x], eax

    mov eax, [player_y]
    cmp eax, 0
    jge .y_low_ok
    xor eax, eax
.y_low_ok:
    mov ecx, SCREEN_H - PLAYER_SIZE
    cmp eax, ecx
    jle .y_high_ok
    mov eax, ecx
.y_high_ok:
    mov [player_y], eax

    ; ---- draw the scene into the back buffer ----
    lea rdi, [back_fb]
    xor esi, esi
    xor edx, edx
    mov ecx, SCREEN_W
    mov r8d, 450
    mov r9d, COLOR_SKY
    call fill_rect

    lea rdi, [back_fb]
    xor esi, esi
    mov edx, 450
    mov ecx, SCREEN_W
    mov r8d, 150
    mov r9d, COLOR_MUD
    call fill_rect

    lea rdi, [back_fb]
    mov esi, 0
    mov edx, 430
    mov ecx, 400
    mov r8d, 390
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [back_fb]
    mov esi, 400
    mov edx, 390
    mov ecx, 800
    mov r8d, 420
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [back_fb]
    mov esi, [player_x]
    mov edx, [player_y]
    mov ecx, PLAYER_SIZE
    mov r8d, PLAYER_SIZE
    mov r9d, COLOR_PLAYER
    call fill_rect

    ; ---- lock, blit, unlock (unchanged from stage4/02) ----
    mov rdi, r14
    xor esi, esi
    lea rdx, [rsp + LOCK_PIXELS_OFF]
    lea rcx, [rsp + LOCK_PITCH_OFF]
    call SDL_LockTexture
    test eax, eax
    js .cleanup_all

    mov r10, [rsp + LOCK_PIXELS_OFF]
    mov r11d, [rsp + LOCK_PITCH_OFF]

    push r15                    ; free r15 for a moment to use as the
                                    ; blit row counter -- restored right
                                       ; after, since .update needs it as
                                          ; the keyboard-state pointer again
                                             ; next frame
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
    pop r15

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


; void draw_line(FrameBuffer* fb: rdi, int x0: esi, int y0: edx,
;                int x1: ecx, int y1: r8d, u32 color: r9d)
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

    mov eax, [rbp + L_X1]
    sub eax, [rbp + L_X0]
    jns .dx_nonneg
    neg eax
.dx_nonneg:
    mov [rbp + L_DX], eax

    mov eax, [rbp + L_X0]
    cmp eax, [rbp + L_X1]
    mov eax, 1
    jl .sx_done
    mov eax, -1
.sx_done:
    mov [rbp + L_SX], eax

    mov eax, [rbp + L_Y1]
    sub eax, [rbp + L_Y0]
    jns .dy_nonneg
    neg eax
.dy_nonneg:
    neg eax
    mov [rbp + L_DY], eax

    mov eax, [rbp + L_Y0]
    cmp eax, [rbp + L_Y1]
    mov eax, 1
    jl .sy_done
    mov eax, -1
.sy_done:
    mov [rbp + L_SY], eax

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
    add eax, eax

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
;   ./build/01_keyboard_move
; Hold an arrow key -- the square should move smoothly and stop dead
; at the window edges (no bounce, no overshoot -- that's the clamp).
;
; Try this in gdb:
;   (gdb) break main.update
;   (gdb) run
;   (gdb) print $r15                  # the keyboard state array pointer
;   (gdb) print (int)player_x
;   ... hold RIGHT physically on your keyboard is impossible mid-gdb,
;   so instead poke the array directly to simulate a held key:
;   (gdb) set *(char*)($r15 + 79) = 1    # 79 = SDL_SCANCODE_RIGHT
;   (gdb) continue
;   (gdb) print (int)player_x            # should have advanced by
;                                            MOVE_SPEED, as if RIGHT
;                                            were actually held
;
; Questions to answer by experimenting:
;   - Hold two opposite keys at once (e.g. LEFT and RIGHT together).
;     What happens, and does the code above make that inevitable, or
;     was it a specific ordering choice (which `cmp` runs first)?
;   - Change the clamp so holding a key against the edge does nothing
;     visually different from not holding it, vs. the current version
;     where the square still "presses" up to the exact edge pixel.
;     (Hint: this is really asking you to predict exact behavior at
;     player_x = SCREEN_W - PLAYER_SIZE - 1 vs already AT the clamp.)
;   - `SDL_GetKeyboardState` is called once, outside the loop. What
;     would go wrong (if anything) if you called it fresh every frame
;     instead, right before reading it? Read SDL's docs for this
;     function to check your prediction, not just intuition.
; ------------------------------------------------------------
