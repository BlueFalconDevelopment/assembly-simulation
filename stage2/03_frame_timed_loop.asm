; ============================================================
; 03 — A stable, frame-timed main loop
;
; 02 spun the CPU as fast as it could. This version measures how
; long each frame actually took (SDL_GetTicks, milliseconds since
; SDL_Init) and sleeps off whatever's left of a ~16ms budget
; (SDL_Delay) — a ~60 FPS cap, pacing itself instead of burning a
; core. Run this next to 02 in `top` and compare CPU% directly;
; that comparison is the actual point of this file.
;
; It also updates a tiny piece of per-frame state (a frame counter)
; and uses it to shift the clear color — proof that the loop really
; is advancing frame by frame, not just idling. This is the same
; "state you update each tick" idea Stage 4 builds on for real
; animation.
; ============================================================
default rel
global main

extern SDL_Init
extern SDL_CreateWindow
extern SDL_CreateRenderer
extern SDL_SetRenderDrawColor
extern SDL_RenderClear
extern SDL_RenderPresent
extern SDL_PollEvent
extern SDL_GetTicks
extern SDL_Delay
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit

SDL_INIT_VIDEO            equ 0x00000020
SDL_WINDOWPOS_UNDEFINED   equ 0x1FFF0000
SDL_WINDOW_SHOWN          equ 0x00000004
SDL_RENDERER_ACCELERATED  equ 0x00000002
SDL_QUIT_EVENT            equ 0x100
FRAME_BUDGET_MS           equ 16     ; ~1000/60 rounded down -> targets ~60 FPS

section .data
    title db "Stage 2.03 - frame-timed (check top: should be ~0% CPU)", 0

section .bss
    frame_count resd 1        ; Uint32, one per-process counter, zero-initialized by .bss

section .text
main:
    push rbp
    mov rbp, rsp
    push r12              ; SDL_Window*
    push r13                 ; SDL_Renderer*
    push r14                    ; frame start time (ms), reloaded each lap
    push r15                       ; padding partner for r14, unused -- keeps the push
                                       ; count even so rsp stays 16-aligned (4 pushes = 32 bytes)
    sub rsp, 64                          ; SDL_Event scratch buffer

    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    test eax, eax
    js .cleanup_none

    lea rdi, [title]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, 800
    mov r8d, 600
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

.loop:
    call SDL_GetTicks
    mov r14d, eax               ; r14d = this frame's start time in ms

.poll_events:
    mov rdi, rsp
    call SDL_PollEvent
    test eax, eax
    jz .update
    mov eax, [rsp]
    cmp eax, SDL_QUIT_EVENT
    je .cleanup_all
    jmp .poll_events

.update:
    inc dword [frame_count]

.render:
    mov eax, [frame_count]
    and eax, 0xFF                 ; 0..255, wraps every 256 frames (~4 seconds at 60fps)

    mov rdi, r13
    mov esi, eax                      ; r channel cycles
    mov edx, 40                         ; g fixed
    mov ecx, 80                           ; b fixed
    mov r8d, 255                            ; a
    call SDL_SetRenderDrawColor

    mov rdi, r13
    call SDL_RenderClear

    mov rdi, r13
    call SDL_RenderPresent

    ; ---- frame pacing: sleep off whatever's left of the budget ----
    call SDL_GetTicks
    sub eax, r14d                  ; eax = elapsed ms this frame
    cmp eax, FRAME_BUDGET_MS
    jge .loop                         ; already over budget -- skip the delay, go straight around

    mov ecx, FRAME_BUDGET_MS
    sub ecx, eax                        ; ecx = ms remaining in this frame's budget
    mov edi, ecx
    call SDL_Delay

    jmp .loop

.cleanup_all:
    mov rdi, r13
    call SDL_DestroyRenderer
.cleanup_window:
    mov rdi, r12
    call SDL_DestroyWindow
.cleanup_sdl:
    call SDL_Quit
.cleanup_none:
    add rsp, 64
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ------------------------------------------------------------
; Build and run:
;   make
;   ./build/03_frame_timed_loop
; The window should slowly cycle its red channel (a ~4 second loop)
; instead of sitting on one flat color. Close it via the X to quit.
;
; Compare CPU cost directly against 02:
;   ./build/02_clear_and_quit &    then `top` -> note CPU%, kill it
;   ./build/03_frame_timed_loop &  then `top` -> note CPU%, close its window
; 03 should sit near 0% on its core; 02 should sit near 100%. Same
; visual result (a cleared window), wildly different cost — that gap
; IS frame pacing.
;
; Try this in gdb:
;   (gdb) break main.update
;   (gdb) run
;   (gdb) watch frame_count            # data watchpoint -- gdb stops
;                                          the instant this memory changes,
;                                          no breakpoint needed
;   (gdb) continue                       # repeat a few times, confirm
;                                            it increments by exactly 1 each hit
;
; Questions to answer by experimenting:
;   - Change FRAME_BUDGET_MS from 16 to 200 (5 FPS). Rebuild, run —
;     does the color cycle visibly slower? Should it, given how
;     frame_count and the budget interact? Predict before you look.
;   - Temporarily remove the `jge .loop` early-out (always fall
;     through to the delay math). Force a case where a frame takes
;     LONGER than the budget by adding a dummy spin (e.g. a
;     million-iteration `dec`/`jnz` loop) right before SDL_GetTicks
;     is called the second time. What garbage happens to `ecx` after
;     `sub ecx, eax` when eax > FRAME_BUDGET_MS, and what does
;     SDL_Delay do when handed that value? (This is exactly why the
;     jge guard exists.)
; ------------------------------------------------------------
