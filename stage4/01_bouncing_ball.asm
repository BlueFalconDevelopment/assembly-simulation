; ============================================================
; 01 — Per-frame animation driven by state you update each tick
;
; Everything before this was either static (stage3) or had no
; persistent state at all beyond a frame counter used just to shift
; a color (stage2/03). This is the real shift: (x, y, vx, vy) live
; in .data, survive across every frame, and get updated once per
; tick BEFORE drawing. Drawing is now just "render whatever the
; current state says" -- the state is the simulation, the render is
; a side effect of it. That's the exact structure Stage 6's soldiers
; will use, just with one object instead of a hundred.
;
; Reuses set_pixel/fill_rect/draw_line and the sky+ground+horizon
; scene from stage3/03 unchanged -- the ball is drawn on top of it.
; Still drawing straight into the locked texture each frame, same as
; stage3 -- 02 upgrades that part to a real back buffer.
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
BALL_SIZE equ 40

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

COLOR_SKY      equ 0xFFFFAA64
COLOR_MUD      equ 0xFF3C8C5A
COLOR_HORIZON  equ 0xFF323C46
COLOR_BALL     equ 0xFF2050F0   ; R=240 G=80 B=32 A=255 -- bright, pops against the scene

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
FB_OFF          equ 80
STACK_LOCALS_SIZE equ 112

section .data
    title db "Stage 4.01 - a ball with state", 0
    ball_x  dd 100         ; these four survive across every frame --
    ball_y  dd 100            ; this IS the animation. Drawing just
    ball_vx dd 4                 ; reflects whatever they currently say.
    ball_vy dd 3

section .text
main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
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

    mov dword [rsp + FB_OFF + FrameBuffer.w], SCREEN_W
    mov dword [rsp + FB_OFF + FrameBuffer.h], SCREEN_H

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
    ; ---- x axis: move, then bounce if we've gone past an edge ----
    mov eax, [ball_x]
    add eax, [ball_vx]
    mov [ball_x], eax
    cmp eax, 0
    jl .bounce_x
    mov ecx, eax
    add ecx, BALL_SIZE
    cmp ecx, SCREEN_W
    jle .x_ok
.bounce_x:
    neg dword [ball_vx]        ; reverse direction -- a small overshoot
.x_ok:                            ; past the edge before the bounce takes
                                      ; effect is normal for this simple a
                                      ; scheme; not something to fix here

    ; ---- y axis: same idea ----
    mov eax, [ball_y]
    add eax, [ball_vy]
    mov [ball_y], eax
    cmp eax, 0
    jl .bounce_y
    mov ecx, eax
    add ecx, BALL_SIZE
    cmp ecx, SCREEN_H
    jle .y_ok
.bounce_y:
    neg dword [ball_vy]
.y_ok:

.lock:
    mov rdi, r14
    xor esi, esi
    lea rdx, [rsp + LOCK_PIXELS_OFF]
    lea rcx, [rsp + LOCK_PITCH_OFF]
    call SDL_LockTexture
    test eax, eax
    js .cleanup_all

    mov rax, [rsp + LOCK_PIXELS_OFF]
    mov [rsp + FB_OFF + FrameBuffer.pixels], rax
    mov eax, [rsp + LOCK_PITCH_OFF]
    mov [rsp + FB_OFF + FrameBuffer.pitch], eax

    ; ---- the (static) scene from stage3, unchanged ----
    lea rdi, [rsp + FB_OFF]
    xor esi, esi
    xor edx, edx
    mov ecx, SCREEN_W
    mov r8d, 450
    mov r9d, COLOR_SKY
    call fill_rect

    lea rdi, [rsp + FB_OFF]
    xor esi, esi
    mov edx, 450
    mov ecx, SCREEN_W
    mov r8d, 150
    mov r9d, COLOR_MUD
    call fill_rect

    lea rdi, [rsp + FB_OFF]
    mov esi, 0
    mov edx, 430
    mov ecx, 400
    mov r8d, 390
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [rsp + FB_OFF]
    mov esi, 400
    mov edx, 390
    mov ecx, 800
    mov r8d, 420
    mov r9d, COLOR_HORIZON
    call draw_line

    ; ---- the ball: reads straight from the state we updated above ----
    lea rdi, [rsp + FB_OFF]
    mov esi, [ball_x]
    mov edx, [ball_y]
    mov ecx, BALL_SIZE
    mov r8d, BALL_SIZE
    mov r9d, COLOR_BALL
    call fill_rect

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
    xor eax, eax
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
;   ./build/01_bouncing_ball
; A bright orange-red square should bounce around the window,
; reflecting off all four edges, over the sky/ground/horizon scene.
;
; Try this in gdb:
;   (gdb) break main.update
;   (gdb) run
;   (gdb) print (int)ball_x
;   (gdb) print (int)ball_vx
;   (gdb) continue                    # one tick later
;   (gdb) print (int)ball_x           # should differ by exactly vx
;                                         (unless a bounce happened
;                                         this tick, in which case
;                                         look at ball_vx too -- did
;                                         its sign flip?)
;
; Questions to answer by experimenting:
;   - Change ball_vx's initial value to 25 (a big jump per tick).
;     Rebuild, run, watch closely near a wall -- does the ball visibly
;     overshoot further before bouncing? Why does a bigger step size
;     make the "small overshoot is normal" comment above more
;     noticeable rather than less?
;   - What happens if you delete `neg dword [ball_vx]` from
;     `.bounce_x` (leave the label and fall-through, but no actual
;     velocity flip)? Predict first, then run it.
;   - The ball's fill_rect call and the scene's fill_rect calls all
;     target the SAME locked texture, drawn in a fixed order every
;     frame. What would visually break if the ball were drawn BEFORE
;     the ground instead of after?
; ------------------------------------------------------------
