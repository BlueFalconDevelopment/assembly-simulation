; ============================================================
; 01 — A raw pixel buffer, and computing byte offsets by hand
;
; Stage 2 let SDL_Renderer do all the drawing (SetRenderDrawColor +
; RenderClear = "fill everything one flat color", nothing more
; granular than that). This stage gets underneath the renderer: a
; "streaming" SDL_Texture is just a block of raw memory you lock,
; write into directly (one byte per color channel per pixel), unlock,
; and hand back to SDL to display.
;
; The memory layout: each pixel is 4 bytes (R, G, B, A, in that
; order, guaranteed by the SDL_PIXELFORMAT_RGBA32 format regardless
; of CPU endianness). Each ROW is `pitch` bytes long — NOT
; necessarily width*4, since a driver is allowed to pad each row for
; alignment, though in practice for a plain streaming texture it
; usually does equal width*4. You must never assume that; always use
; the pitch SDL actually gives you.
;
; So: the byte address of pixel (col, row)'s red channel is
;     base + row * pitch + col * 4
; and green/blue/alpha are the next three bytes after that. This
; formula is the entire point of this file — everything else is
; plumbing to get a buffer to apply it to.
;
; To prove the formula is right (not just "looks like a flat color,
; who knows if row/col got swapped"), we fill it with a pattern that
; depends on BOTH row and col: red cycles with column, green cycles
; with row. If the two ever got swapped, the image would visibly
; rotate 90 degrees — a bug you can SEE, not just suspect.
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

SDL_INIT_VIDEO            equ 0x00000020
SDL_WINDOWPOS_UNDEFINED   equ 0x1FFF0000
SDL_WINDOW_SHOWN          equ 0x00000004
SDL_RENDERER_ACCELERATED  equ 0x00000002
SDL_QUIT_EVENT            equ 0x100
FRAME_BUDGET_MS           equ 16

; ---- looked up from /usr/include/SDL2/SDL_pixels.h (not guessed —
; SDL packs these into a bitfield-style Uint32, easy to get wrong by
; hand). SDL_PIXELFORMAT_RGBA32 is the endian-independent alias that
; guarantees in-memory byte order R,G,B,A regardless of CPU. ----
SDL_PIXELFORMAT_RGBA32    equ 0x16762004
SDL_TEXTUREACCESS_STREAMING equ 1

SCREEN_W equ 800
SCREEN_H equ 600

; ---- our scratch stack layout for this function (see the prologue
; below for how these offsets get carved out of one `sub rsp, N`) ----
LOCK_PIXELS_OFF equ 0     ; 8 bytes: void* written by SDL_LockTexture
LOCK_PITCH_OFF  equ 8     ; 4 bytes: int written by SDL_LockTexture
EVENT_OFF       equ 16    ; 56+ bytes: SDL_Event scratch buffer
STACK_LOCALS_SIZE equ 80  ; 16 + 64, multiple of 16

section .data
    title db "Stage 3.01 - raw pixel buffer (row=green, col=red)", 0

section .text
main:
    push rbp
    mov rbp, rsp
    push rbx              ; will hold this frame's start time (ms)
    push r12                 ; SDL_Window*
    push r13                    ; SDL_Renderer*
    push r14                       ; SDL_Texture*
    ; 5 pushes above (rbp,rbx,r12,r13,r14) -> odd count -> rsp is
    ; 16-aligned here, ready for calls
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

    ; ---- SDL_CreateTexture(renderer, format, access, w, h) ----
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
    jz .lock
    mov eax, [rsp + EVENT_OFF]
    cmp eax, SDL_QUIT_EVENT
    je .cleanup_all
    jmp .poll_events

.lock:
    ; ---- SDL_LockTexture(texture, NULL, &pixels, &pitch) ----
    ; SDL writes the pixel pointer and pitch directly through these
    ; two out-params -- we hand it stack addresses to write into.
    mov rdi, r14
    xor esi, esi
    lea rdx, [rsp + LOCK_PIXELS_OFF]
    lea rcx, [rsp + LOCK_PITCH_OFF]
    call SDL_LockTexture
    test eax, eax
    js .cleanup_all

    mov r10, [rsp + LOCK_PIXELS_OFF]    ; r10 = pixel buffer base address
    mov r11d, [rsp + LOCK_PITCH_OFF]       ; r11d = pitch (bytes per row)

    ; ---- the actual point of this file: fill every pixel by hand ----
    xor edx, edx                    ; edx = row = 0
.row_loop:
    cmp edx, SCREEN_H
    jge .fill_done

    mov eax, edx
    imul eax, r11d                    ; eax = row * pitch

    xor ecx, ecx                        ; ecx = col = 0
.col_loop:
    cmp ecx, SCREEN_W
    jge .row_done

    lea r8d, [eax + ecx*4]                ; r8d = row*pitch + col*4  (the formula)

    mov r9d, ecx
    and r9d, 0xFF
    mov byte [r10 + r8], r9b                ; R -- cycles with column
    mov r9d, edx
    and r9d, 0xFF
    mov byte [r10 + r8 + 1], r9b               ; G -- cycles with row
    mov byte [r10 + r8 + 2], 128                  ; B -- constant
    mov byte [r10 + r8 + 3], 255                    ; A -- fully opaque

    inc ecx
    jmp .col_loop
.row_done:
    inc edx
    jmp .row_loop
.fill_done:

    mov rdi, r14
    call SDL_UnlockTexture

    ; ---- SDL_RenderCopy(renderer, texture, NULL, NULL) -- NULL/NULL
    ; means "copy the whole texture, stretched to fill the whole
    ; render target" ----
    mov rdi, r13
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call SDL_RenderCopy

    mov rdi, r13
    call SDL_RenderPresent

    ; ---- same frame-pacing pattern as stage2/03 ----
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
; Build and run:
;   make
;   ./build/01_pixel_buffer
; Expect a grid-like gradient: red increases left-to-right in 256px
; bands, green increases top-to-bottom in 256px bands, constant blue.
;
; Try this in gdb to actually SEE the offset formula work:
;   (gdb) break main.row_loop
;   (gdb) run
;   (gdb) print $edx                  # current row
;   (gdb) next                        # step over the col_loop's first pass...
;   actually easier: break inside the inner loop and watch r8d:
;   (gdb) break main.col_loop
;   (gdb) continue
;   (gdb) print $ecx                  # current col
;   (gdb) print $edx                  # current row (unchanged this inner pass)
;   (gdb) next 3                      # step past the lea and both `and`s
;   (gdb) print $r8d                  # should equal row*pitch + col*4 exactly
;
; Questions to answer by experimenting:
;   - Swap `edx` and `ecx` in the `lea r8d, [eax + ecx*4]` line's
;     SOURCE data only -- i.e. make red cycle with ROW and green
;     cycle with COLUMN instead (swap which register feeds which
;     channel, not the offset formula itself). Rebuild. Does the
;     gradient visibly rotate? That's the "wrong axis" bug made
;     visible on purpose.
;   - What actually IS the pitch SDL reports for an 800-wide RGBA32
;     texture? Break at `.lock` after the LockTexture call and
;     `print $r11d`. Is it exactly 800*4=3200, or something else on
;     this driver? (Either answer is fine — the point is you now
;     KNOW instead of assuming.)
;   - Deliberately write past the buffer once on purpose (temporarily
;     change `cmp ecx, SCREEN_W` to `cmp ecx, SCREEN_W + 50` so the
;     inner loop overruns each row by 50 pixels = 200 bytes into the
;     next row's memory). Does it crash, corrupt the image, or look
;     fine? Put it back afterward — this is a "see it once,
;     understand why bounds checks in 02 matter" exercise, not a
;     pattern to keep.
; ------------------------------------------------------------
