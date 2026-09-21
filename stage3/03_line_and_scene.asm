; ============================================================
; 03 — Line drawing (Bresenham), and the first real scene
;
; draw_line below is the exact line-stepping idea the roadmap notes
; will get reused for line-of-sight checks in Stage 6: walk from one
; point to another one step at a time, deciding at each step whether
; to move in x, y, or both, using only integer arithmetic (no
; floating point, no trig, no sqrt). Bresenham's algorithm is the
; classic version of that idea; later, "does this line cross an
; obstacle cell" is the same walk with an extra check bolted on.
;
; draw_line has to survive its OWN loop across repeated calls to
; set_pixel -- that's a lot of live state (endpoint, deltas, sign,
; error term, color: ~9 values) to keep across calls without
; clobbering it. Rather than fight for callee-saved registers, it
; uses a real rbp-based stack frame with one named local per value
; -- the same pattern stage1/04's print_uint used, just with more
; locals. Memory survives a `call` automatically; that's the whole
; trick.
;
; This file's main() is otherwise identical to 02's -- same locking,
; same event loop, same frame pacing -- it just draws more.
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
SDL_QUIT_EVENT              equ 0x100
FRAME_BUDGET_MS             equ 16
SDL_PIXELFORMAT_RGBA32      equ 0x16762004
SDL_TEXTUREACCESS_STREAMING equ 1

SCREEN_W equ 800
SCREEN_H equ 600

struc FrameBuffer
    .pixels: resq 1
    .pitch:  resd 1
    .w:      resd 1
    .h:      resd 1
endstruc

; colors packed as value = R | (G<<8) | (B<<16) | (A<<24) -- see
; stage3/02's comment for the worked example deriving these
COLOR_SKY      equ 0xFFFFAA64   ; R=100 G=170 B=255 A=255
COLOR_MUD      equ 0xFF3C8C5A   ; R=90  G=140 B=60  A=255
COLOR_HORIZON  equ 0xFF323C46   ; R=70  G=60  B=50  A=255 (dark ridge line)
COLOR_OBSTACLE equ 0xFF285078   ; R=120 G=80  B=40  A=255 (cover on the ground)

LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
FB_OFF          equ 80
STACK_LOCALS_SIZE equ 112

section .data
    title db "Stage 3.03 - first scene", 0

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
    jz .lock
    mov eax, [rsp + EVENT_OFF]
    cmp eax, SDL_QUIT_EVENT
    je .cleanup_all
    jmp .poll_events

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

    ; ---- the scene ----
    lea rdi, [rsp + FB_OFF]
    xor esi, esi
    xor edx, edx
    mov ecx, SCREEN_W
    mov r8d, 450
    mov r9d, COLOR_SKY
    call fill_rect                  ; sky

    lea rdi, [rsp + FB_OFF]
    xor esi, esi
    mov edx, 450
    mov ecx, SCREEN_W
    mov r8d, 150
    mov r9d, COLOR_MUD
    call fill_rect                  ; ground

    ; horizon: five connected line segments forming a jagged ridge
    lea rdi, [rsp + FB_OFF]
    mov esi, 0
    mov edx, 430
    mov ecx, 150
    mov r8d, 380
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [rsp + FB_OFF]
    mov esi, 150
    mov edx, 380
    mov ecx, 300
    mov r8d, 420
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [rsp + FB_OFF]
    mov esi, 300
    mov edx, 420
    mov ecx, 450
    mov r8d, 360
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [rsp + FB_OFF]
    mov esi, 450
    mov edx, 360
    mov ecx, 600
    mov r8d, 410
    mov r9d, COLOR_HORIZON
    call draw_line

    lea rdi, [rsp + FB_OFF]
    mov esi, 600
    mov edx, 410
    mov ecx, 800
    mov r8d, 390
    mov r9d, COLOR_HORIZON
    call draw_line

    ; two obstacle rects on the ground (a preview of Stage 6b's cover)
    lea rdi, [rsp + FB_OFF]
    mov esi, 150
    mov edx, 500
    mov ecx, 60
    mov r8d, 60
    mov r9d, COLOR_OBSTACLE
    call fill_rect

    lea rdi, [rsp + FB_OFF]
    mov esi, 500
    mov edx, 520
    mov ecx, 80
    mov r8d, 50
    mov r9d, COLOR_OBSTACLE
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
; Precondition: x >= 0, y >= 0. Right/bottom edges are clipped.
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
;
; Bresenham's line algorithm, integer-only. Named stack locals
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
;   ./build/03_line_and_scene
; Expect: sky, ground, a jagged dark ridge line along the horizon,
; and two small obstacle-colored rectangles sitting on the ground.
;
; Try this in gdb (each local is an 8-byte slot but only its low 4
; bytes are ever written -- `mov [rbp+L_X0], esi` is a 32-bit store
; -- so read these back as `int*`, not with a bulk `x/Ndw` dump,
; which would interleave real values with the slots' untouched upper
; 4 bytes):
;   (gdb) break draw_line.plot_loop
;   (gdb) run
;   (gdb) print *(int*)($rbp-16)      ; x0 -- should be 0, matching
;                                         the first draw_line call
;   (gdb) print *(int*)($rbp-24)      ; y0 -- should be 430
;   (gdb) print *(int*)($rbp-32)      ; x1 -- should be 150
;   (gdb) print *(int*)($rbp-40)      ; y1 -- should be 380
;   (gdb) continue                      ; one more step of the loop
;   (gdb) print *(int*)($rbp-16)         ; x0 should now be 1
;   (gdb) print *(int*)($rbp-24)          ; y0 should still be 430 --
;                                            this segment is shallow
;                                            (dx=150 vs dy=-50), so x
;                                            advances every step and
;                                            y only occasionally
;
; Questions to answer by experimenting:
;   - Add a 6th point to the horizon (another draw_line call) that
;     goes DOWNWARD steeply then back up -- does a near-vertical
;     line draw as a solid connected line, or does it look dotted?
;     (This is testing whether the dx/dy/err logic really handles
;     steep slopes, not just shallow ones -- both cases exist in the
;     algorithm on purpose.)
;   - Call draw_line with x0==x1 and y0==y1 (a zero-length "line").
;     Does it crash, draw one pixel, or draw nothing? Trace through
;     the algorithm by hand first, then verify.
;   - The obstacle rects and the ground rect are drawn in a specific
;     order. Swap the order so ground is drawn AFTER the obstacles.
;     What visually breaks, and why does draw order matter here when
;     it didn't matter for the sky/ground pair?
; ------------------------------------------------------------
