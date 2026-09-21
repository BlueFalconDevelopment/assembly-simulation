; ============================================================
; 02 — Reusable drawing functions, and NASM's `struc`
;
; 01 hardcoded everything about the pixel buffer straight into main's
; loop. Now we want callable functions like `fill_rect(...)`. Those
; need to know the buffer's base pointer, its pitch, and its bounds
; (width/height, for clipping) -- that's already 4 pieces of state,
; and a rect needs x/y/w/h/color on top. That's more than the 6
; argument registers can hold.
;
; The fix: bundle the buffer's own state (pointer, pitch, w, h) into
; one struct, and pass a POINTER to it as a single argument. NASM's
; `struc`/`endstruc` defines named byte offsets into a block of raw
; memory -- there's no real "struct type" at the machine level, just
; a pointer and some offsets you promise to interpret consistently.
; This exact pattern (a pointer to a block of named fields) is what
; every "soldier" record in the Stage 6 capstone will look like too.
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

; ---- the struct. FrameBuffer.pixels / .pitch / .w / .h are the
; byte offsets NASM generates; FrameBuffer_size is the total size. ----
struc FrameBuffer
    .pixels: resq 1     ; void*  -- base address of the locked texture
    .pitch:  resd 1        ; int    -- bytes per row
    .w:      resd 1           ; int    -- width in pixels, for clipping
    .h:      resd 1              ; int    -- height in pixels, for clipping
endstruc

; ---- colors, packed as a single little-endian Uint32 such that the
; bytes in memory come out R,G,B,A. Since a little-endian 32-bit
; store writes its LOW byte to the lowest address, that means:
;     value = R | (G << 8) | (B << 16) | (A << 24)
; Written as a hex literal 0xAABBGGRR, the digit groups read left to
; right as A, B, G, R -- which is why the constants below look
; "backwards" from RGBA order at a glance. Worked example for
; COLOR_SKY: R=100 (0x64), G=170 (0xAA), B=255 (0xFF), A=255 (0xFF)
;   -> 0x64 | (0xAA<<8) | (0xFF<<16) | (0xFF<<24) = 0xFFFFAA64 ----
COLOR_SKY equ 0xFFFFAA64   ; R=100 G=170 B=255 A=255 (light blue)
COLOR_MUD equ 0xFF3C8C5A   ; R=90  G=140 B=60  A=255 (dirt green)

; ---- our stack scratch layout for main (see prologue) ----
LOCK_PIXELS_OFF equ 0
LOCK_PITCH_OFF  equ 8
EVENT_OFF       equ 16
FB_OFF          equ 80     ; FrameBuffer instance lives here
STACK_LOCALS_SIZE equ 112  ; 80 + FrameBuffer_size(20), rounded to 16

section .data
    title db "Stage 3.02 - reusable set_pixel / fill_rect", 0

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

    ; fb.w and fb.h never change -- set them once, outside the loop
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

    ; fill in fb.pixels / fb.pitch from what SDL just gave us
    mov rax, [rsp + LOCK_PIXELS_OFF]
    mov [rsp + FB_OFF + FrameBuffer.pixels], rax
    mov eax, [rsp + LOCK_PITCH_OFF]
    mov [rsp + FB_OFF + FrameBuffer.pitch], eax

    ; ---- draw the scene: sky, then a ground rect over the bottom ----
    lea rdi, [rsp + FB_OFF]
    xor esi, esi                  ; x = 0
    xor edx, edx                     ; y = 0
    mov ecx, SCREEN_W                  ; w = full width
    mov r8d, SCREEN_H                     ; h = full height
    mov r9d, COLOR_SKY
    call fill_rect

    lea rdi, [rsp + FB_OFF]
    xor esi, esi                  ; x = 0
    mov edx, 450                     ; y = 450 (bottom 150px of a 600-tall screen)
    mov ecx, SCREEN_W                  ; w = full width
    mov r8d, 150                          ; h = 150
    mov r9d, COLOR_MUD
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


; ------------------------------------------------------------
; void set_pixel(FrameBuffer* fb: rdi, int x: esi, int y: edx, u32 color: ecx)
;
; Bounds-checked single-pixel write. This is the primitive the
; line-drawing algorithm in 03 calls once per step. No callee-saved
; registers needed -- it makes no further calls, so it's free to
; clobber any caller-saved register without saving anything.
; ------------------------------------------------------------
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
    lea eax, [eax + esi*4]        ; offset = y*pitch + x*4
                                      ; (writing eax zero-extends into rax --
                                      ; exactly what we need for the [r10+rax] below)
    mov r10, [rdi + FrameBuffer.pixels]
    mov dword [r10 + rax], ecx
.done:
    ret


; ------------------------------------------------------------
; void fill_rect(FrameBuffer* fb: rdi, int x: esi, int y: edx,
;                int w: ecx, int h: r8d, u32 color: r9d)
;
; Precondition: x >= 0 and y >= 0. The right/bottom edges ARE clipped
; against the framebuffer's actual size -- writing past the end of a
; locked texture's memory is real corruption, not just a rendering
; glitch, so this isn't optional even for a "simple" rect fill.
; ------------------------------------------------------------
fill_rect:
    push rbx                  ; callee-saved scratch, since this function is
    push r12                     ; longer-lived than set_pixel: we compute a
    push r13                        ; few things up front and hold them across
    push r14                           ; the whole nested loop below
    ; 4 pushes (even) -- but fill_rect makes no further `call`s either
    ; (it writes pixels directly, same as set_pixel does), so the
    ; 16-byte-alignment-before-`call` rule simply doesn't apply here

    mov r10, [rdi + FrameBuffer.pixels]   ; r10 = pixel buffer base
    mov r11d, [rdi + FrameBuffer.pitch]      ; r11d = pitch
    mov ebx, [rdi + FrameBuffer.w]              ; ebx = fb width
    mov r12d, [rdi + FrameBuffer.h]                ; r12d = fb height

    ; clip: x_end = min(x+w, fb.w), y_end = min(y+h, fb.h)
    mov r13d, esi
    add r13d, ecx                  ; r13d = x + w  (unclipped right edge)
    cmp r13d, ebx
    jle .x_end_ok
    mov r13d, ebx                    ; clip to fb width
.x_end_ok:

    mov r14d, edx
    add r14d, r8d                  ; r14d = y + h  (unclipped bottom edge)
    cmp r14d, r12d
    jle .y_end_ok
    mov r14d, r12d                    ; clip to fb height
.y_end_ok:

    ; now loop row = y .. r14d-1, col = x .. r13d-1
    ; (edx = row, esi still holds the original x = loop start for columns)
.row_loop:
    cmp edx, r14d
    jge .done

    mov eax, edx
    imul eax, r11d                  ; eax = row * pitch

    mov ecx, esi                      ; ecx = col = x (reset each row)
.col_loop:
    cmp ecx, r13d
    jge .row_done

    lea r8d, [eax + ecx*4]              ; r8d = row*pitch + col*4
    mov dword [r10 + r8], r9d               ; write the color

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
;   ./build/02_rect_plot
; Expect a light-blue sky over a green-ish ground band across the
; bottom quarter of the window.
;
; Try this in gdb:
;   (gdb) break fill_rect
;   (gdb) run
;   (gdb) print $esi                 # x
;   (gdb) print $edx                 # y
;   (gdb) print $ecx                 # w
;   (gdb) print $r8d                 # h
;   (gdb) print/x $r9d               # color, e.g. 0xffffaa64 for the sky
;   (gdb) continue                   # should hit again for the ground rect
;
; Questions to answer by experimenting:
;   - Call fill_rect a third time with x=700, y=500, w=200, h=200,
;     any color -- a rect that clearly overhangs both the right and
;     bottom edges of an 800x600 screen. Does it draw only the
;     clipped portion, or does it crash/corrupt? Verify your
;     prediction, then check it against the clipping code above.
;   - Temporarily delete just the `.x_end_ok`/`jle` clipping (always
;     use the unclipped x_end) and pass a rect with x+w far past 800.
;     What happens now, and why does this differ from what set_pixel
;     alone would do if called with an out-of-range x?
;   - COLOR_MUD's hex constant, 0xFF3C8C5A -- without re-reading the
;     worked example in the comments, derive R, G, B, A from it by
;     hand. Check your answer against the `equ` line's own comment.
; ------------------------------------------------------------
