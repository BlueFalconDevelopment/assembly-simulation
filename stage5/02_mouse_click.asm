; ============================================================
; 02 — Mouse clicks that actually change the scene
;
; 01 read a live snapshot (SDL_GetKeyboardState) for continuous
; movement. Clicks are different: they're discrete, one-off events,
; so they belong in the SDL_PollEvent queue instead, alongside
; SDL_QUIT -- read event.type, and when it's SDL_MOUSEBUTTONDOWN,
; the SAME event buffer also holds which button and where, at fixed
; byte offsets (looked up from SDL_MouseButtonEvent via a C probe,
; same approach as stage3's pixel format and this stage's scancodes
; -- struct layouts are exactly the kind of thing not worth guessing).
;
; Left-clicking anywhere on the scene appends a small obstacle rect
; at that spot to a growing list in `.bss`, which then gets drawn
; every frame from then on. This is the actual payoff the roadmap
; promised for this stage: input doesn't just move something that
; was already there, it permanently changes what the simulation
; contains. It's also a direct rehearsal for Stage 6, where weapon
; pickups spawn onto the map the same way -- a location gets added
; to a list, and the render loop just draws whatever the list says.
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
SDL_MOUSEBUTTONDOWN_EVENT    equ 0x401
FRAME_BUDGET_MS              equ 16
SDL_PIXELFORMAT_RGBA32       equ 0x16762004
SDL_TEXTUREACCESS_STREAMING  equ 1

SDL_SCANCODE_RIGHT equ 79
SDL_SCANCODE_LEFT  equ 80
SDL_SCANCODE_DOWN  equ 81
SDL_SCANCODE_UP    equ 82

; ---- SDL_MouseButtonEvent field offsets, from a C probe against
; /usr/include/SDL2/SDL_events.h via offsetof() -- NOT guessed.
; Only valid to read once event.type == SDL_MOUSEBUTTONDOWN_EVENT. ----
MOUSE_BUTTON_OFF equ 16    ; Uint8: which button
MOUSE_X_OFF      equ 20    ; Sint32: click x
MOUSE_Y_OFF      equ 24    ; Sint32: click y
SDL_BUTTON_LEFT  equ 1

SCREEN_W equ 800
SCREEN_H equ 600
PLAYER_SIZE equ 30
MOVE_SPEED equ 5
OBSTACLE_SIZE equ 30
MAX_OBSTACLES equ 32
OUR_PITCH equ SCREEN_W * 4

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

COLOR_SKY      equ 0xFFFFAA64
COLOR_MUD      equ 0xFF3C8C5A
COLOR_HORIZON  equ 0xFF323C46
COLOR_PLAYER   equ 0xFF2050F0
COLOR_OBSTACLE equ 0xFF285078

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
LOOP_I_OFF      equ 80
STACK_LOCALS_SIZE equ 96

section .data
    title db "Stage 5.02 - left-click to place obstacles", 0
    player_x dd 380
    player_y dd 280
    obstacle_count dd 0

    back_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq back_buffer
        at FrameBuffer.pitch,  dd OUR_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd SCREEN_H
    iend

section .bss
    back_buffer resb SCREEN_W * SCREEN_H * 4
    obstacles    resb MAX_OBSTACLES * 8    ; each slot: dd x, dd y

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

    xor edi, edi
    call SDL_GetKeyboardState
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
    cmp eax, SDL_MOUSEBUTTONDOWN_EVENT
    je .handle_click
    jmp .poll_events

.handle_click:
    movzx eax, byte [rsp + EVENT_OFF + MOUSE_BUTTON_OFF]
    cmp eax, SDL_BUTTON_LEFT
    jne .poll_events
    mov eax, [obstacle_count]
    cmp eax, MAX_OBSTACLES
    jge .poll_events                 ; list full -- silently ignore the click

    mov ecx, eax
    imul ecx, 8                        ; ecx = byte offset of this slot
    lea r10, [obstacles]
    add r10, rcx                          ; r10 = &obstacles[count]

    mov eax, [rsp + EVENT_OFF + MOUSE_X_OFF]
    mov [r10], eax
    mov eax, [rsp + EVENT_OFF + MOUSE_Y_OFF]
    mov [r10 + 4], eax

    inc dword [obstacle_count]
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

    ; ---- every obstacle the player has placed so far ----
    mov dword [rsp + LOOP_I_OFF], 0
.obstacle_draw_loop:
    mov eax, [rsp + LOOP_I_OFF]
    cmp eax, [obstacle_count]
    jge .obstacle_draw_done

    mov ecx, eax
    imul ecx, 8
    lea r10, [obstacles]
    add r10, rcx

    lea rdi, [back_fb]
    mov esi, [r10]
    mov edx, [r10 + 4]
    mov ecx, OBSTACLE_SIZE
    mov r8d, OBSTACLE_SIZE
    mov r9d, COLOR_OBSTACLE
    call fill_rect

    mov eax, [rsp + LOOP_I_OFF]
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .obstacle_draw_loop
.obstacle_draw_done:

    lea rdi, [back_fb]
    mov esi, [player_x]
    mov edx, [player_y]
    mov ecx, PLAYER_SIZE
    mov r8d, PLAYER_SIZE
    mov r9d, COLOR_PLAYER
    call fill_rect

    ; ---- lock, blit, unlock ----
    mov rdi, r14
    xor esi, esi
    lea rdx, [rsp + LOCK_PIXELS_OFF]
    lea rcx, [rsp + LOCK_PITCH_OFF]
    call SDL_LockTexture
    test eax, eax
    js .cleanup_all

    mov r10, [rsp + LOCK_PIXELS_OFF]
    mov r11d, [rsp + LOCK_PITCH_OFF]

    push r15
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
;   ./build/02_mouse_click
; Move with arrow keys, left-click anywhere to drop an obstacle
; there. Each click should leave a permanent brownish square exactly
; where you clicked, and it should still be there next frame, and
; the frame after that, forever (until MAX_OBSTACLES=32 is reached).
;
; Try this in gdb:
;   (gdb) break main.handle_click
;   (gdb) run
;   ... click once in the actual window ...
;   (gdb) print *(int*)&obstacle_count
;   (gdb) print *(int*)&obstacles         # x of slot 0, after `continue`
;                                             past the store instructions
;
; Questions to answer by experimenting:
;   - Click 32 times (MAX_OBSTACLES). Does the 33rd click crash,
;     silently do nothing, or overwrite an existing obstacle? Trace
;     through `.handle_click`'s bounds check to predict which, then
;     verify.
;   - Right-click instead of left-click (SDL_BUTTON_RIGHT = 3). Does
;     anything happen? Should it, given what `.handle_click` actually
;     checks?
;   - The obstacle list only ever grows. Sketch (in comments, no need
;     to implement) what a `remove_obstacle(index)` would need to do
;     to the array without leaving a gap -- this is the same problem
;     Stage 6 faces when a soldier dies and needs to disappear from
;     an array other soldiers are iterating over.
; ------------------------------------------------------------
