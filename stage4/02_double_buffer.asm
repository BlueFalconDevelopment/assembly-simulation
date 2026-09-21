; ============================================================
; 02 — A real back buffer, and blitting it to the display
;
; 01 drew straight into the locked texture every frame, same as
; stage3 did. That has a real limitation: the texture's memory is
; owned by the driver, its pitch is only known AFTER locking, and
; its contents between frames aren't guaranteed to persist. Drawing
; logic ends up entangled with lock/unlock timing for no good reason.
;
; The fix: keep our OWN pixel buffer in ordinary process memory
; (`.bss`, allocated once, stride fixed forever at assembly time).
; All drawing targets that buffer -- it doesn't care about SDL at
; all. Once a frame, after the scene is fully drawn, we lock the
; texture just long enough to copy (blit) our buffer into it, row by
; row, and unlock. This is "double buffering" in the literal sense:
; a back buffer we own and draw into, and a front buffer (the
; texture) that only ever receives a finished frame.
;
; (Note: SDL/your GPU driver is ALSO doing its own double buffering
; under the hood for presentation -- that's what makes SDL_RenderPresent
; not tear. What we're adding here is different and additional: a
; stable, persistent home for OUR scene data that isn't at the mercy
; of when SDL feels like letting us touch texture memory.)
;
; The blit is where `rep movsb` shows up -- a dedicated x86 string
; instruction that copies rcx bytes from [rsi] to [rdi], advancing
; both pointers automatically. One instruction, hardware-optimized,
; instead of a hand-rolled byte-copy loop.
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
OUR_PITCH equ SCREEN_W * 4        ; our own buffer's stride -- fixed forever,
                                      ; unlike the texture's, which the driver
                                      ; decides at lock time

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

COLOR_SKY      equ 0xFFFFAA64
COLOR_MUD      equ 0xFF3C8C5A
COLOR_HORIZON  equ 0xFF323C46
COLOR_BALL     equ 0xFF2050F0

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
STACK_LOCALS_SIZE equ 80    ; just the lock out-params + event buffer now --
                                ; no per-frame FrameBuffer struct needed, see below

section .data
    title db "Stage 4.02 - real double buffering", 0
    ball_x  dd 100
    ball_y  dd 100
    ball_vx dd 4
    ball_vy dd 3

    ; ---- a compile-time-initialized FrameBuffer describing our own
    ; persistent back buffer. `istruc`/`at`/`iend` is NASM's syntax
    ; for filling in a struct's fields as static data -- this needs
    ; ZERO runtime setup, unlike stage3/4's per-frame struct, because
    ; nothing about our own buffer ever changes between frames. ----
    back_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq back_buffer
        at FrameBuffer.pitch,  dd OUR_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd SCREEN_H
    iend

section .bss
    back_buffer resb SCREEN_W * SCREEN_H * 4   ; our persistent back buffer
                                                   ; (~1.9MB, zeroed at process
                                                   ; start, never reallocated)

section .text
main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15              ; used as the blit loop's row counter below
    sub rsp, 8               ; alignment pad (6 pushes above rbp = even;
                                 ; this restores the "odd total" needed
                                 ; for rsp to land 16-aligned before calls)
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
    neg dword [ball_vx]
.x_ok:

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

    ; ---- draw the whole scene into OUR back buffer. No lock, no
    ; pitch to fetch, no dependency on SDL at all -- back_fb is
    ; always valid. ----
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
    mov esi, [ball_x]
    mov edx, [ball_y]
    mov ecx, BALL_SIZE
    mov r8d, BALL_SIZE
    mov r9d, COLOR_BALL
    call fill_rect

    ; ---- NOW lock the texture, just long enough to blit ----
    mov rdi, r14
    xor esi, esi
    lea rdx, [rsp + LOCK_PIXELS_OFF]
    lea rcx, [rsp + LOCK_PITCH_OFF]
    call SDL_LockTexture
    test eax, eax
    js .cleanup_all

    mov r10, [rsp + LOCK_PIXELS_OFF]    ; r10 = texture pixel base (dest)
    mov r11d, [rsp + LOCK_PITCH_OFF]       ; r11d = texture pitch (dest stride --
                                               ; may or may not equal OUR_PITCH;
                                               ; that's exactly why we copy row by
                                               ; row instead of one giant memcpy)

    xor r15d, r15d                ; r15d = row = 0
.blit_row_loop:
    cmp r15d, SCREEN_H
    jge .blit_done

    ; source row pointer: back_buffer + row * OUR_PITCH
    lea rsi, [back_buffer]
    mov eax, r15d
    imul eax, OUR_PITCH
    add rsi, rax

    ; dest row pointer: texture_pixels + row * texture_pitch
    mov rdi, r10
    mov eax, r15d
    imul eax, r11d
    add rdi, rax

    mov ecx, SCREEN_W * 4     ; bytes of actual pixel data in this row
                                 ; (NOT the pitch -- pitch may include
                                 ; padding we must skip over, not copy)
    cld
    rep movsb                     ; copies ecx/rcx bytes [rsi]->[rdi],
                                      ; advancing both pointers

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
;   ./build/02_double_buffer
; Should look identical to 01 -- same bouncing ball, same scene. The
; whole point of this file is that it gets there differently, not
; that it looks different.
;
; Try this in gdb:
;   (gdb) break main.blit_row_loop
;   (gdb) run
;   (gdb) print $r11d                 # the texture's actual pitch --
;                                         compare against OUR_PITCH (3200)
;   (gdb) print $r10                  # texture pixel base (dest)
;   (gdb) x/4xb &back_buffer           # first 4 bytes of OUR buffer's
;                                          row 0 -- should read 64 aa ff ff,
;                                          i.e. COLOR_SKY's R,G,B,A bytes
;                                          (the symbol needs the & -- it has
;                                          no debug type for gdb to dereference)
;   (gdb) x/4xb $r10                    # first 4 bytes of the TEXTURE's
;                                           row 0, before the blit copies
;                                           into it -- probably zero or
;                                           leftover from a prior frame
;   (gdb) continue                        # the breakpoint is at the loop's
;                                             OWN top, so `finish` just hits
;                                             it again instead of returning;
;                                             `continue` is what actually
;                                             lets this iteration's rep movsb
;                                             run before stopping again
;   (gdb) x/4xb $r10                        # now should match back_buffer's
;                                               first 4 bytes exactly
;
; Questions to answer by experimenting:
;   - Is `$r11d` (the texture's real pitch) actually different from
;     OUR_PITCH on this machine/driver? If they happen to match here,
;     the row-by-row copy is doing strictly-necessary work for
;     portability even though it looks unnecessary on this specific
;     setup -- why would you still want it written this way?
;   - Replace the whole row-by-row blit loop with a single
;     `rep movsb` sized `SCREEN_W * SCREEN_H * 4` bytes in one shot
;     (temporarily -- don't keep this). If the pitches happen to
;     match on your machine, does it look fine? Now imagine a driver
;     where the texture's pitch has 64 bytes of padding per row --
;     trace through by hand what this single-shot version would
;     produce instead of the correct image.
;   - `cld` appears right before every `rep movsb`. Look up what `std`
;     does (the opposite instruction) and explain in one sentence why
;     an assembler program should never assume the direction flag is
;     already in the state it wants.
; ------------------------------------------------------------
