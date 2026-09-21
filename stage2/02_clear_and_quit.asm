; ============================================================
; 02 — Clear the screen to a color, and handle the quit event
;
; This adds the actual main loop: poll every pending input event
; each frame, watch for SDL_QUIT (fired when you click the window's
; close button), and otherwise clear the screen to a solid color
; and present it.
;
; No frame timing yet — this loop spins as fast as the CPU will let
; it, calling SDL_RenderClear/SDL_RenderPresent thousands of times a
; second for no visual benefit. That's deliberate: run this and check
; a core pegged at ~100% in `top`/`htop` while the window is open.
; 03 fixes it. Seeing the "wrong" version first makes the fix mean
; something instead of being a rule you just took on faith.
;
; Also: this version checks SDL_Init's and SDL_CreateWindow's return
; values properly (01 didn't) — this is the actual habit to build.
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
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit

SDL_INIT_VIDEO            equ 0x00000020
SDL_WINDOWPOS_UNDEFINED   equ 0x1FFF0000
SDL_WINDOW_SHOWN          equ 0x00000004
SDL_RENDERER_ACCELERATED  equ 0x00000002
SDL_QUIT_EVENT            equ 0x100    ; SDL_QUIT from SDL_events.h — the first Uint32 in
                                        ; every SDL_Event variant is its `type` field, so we
                                        ; can always check it the same way regardless of
                                        ; which kind of event actually came in

section .data
    title db "Stage 2.02 - close the window to quit", 0

section .text
main:
    push rbp
    mov rbp, rsp
    push r12              ; SDL_Window*
    push r13                 ; SDL_Renderer*
    sub rsp, 64                 ; scratch space for one SDL_Event (real size is 56 bytes;
                                    ; we round up to 64 to keep a clean 16-byte-aligned total)

    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    test eax, eax                 ; SDL_Init returns 0 on success, negative on failure
    js .cleanup_none                 ; js = jump if sign flag set = jump if negative

    lea rdi, [title]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, 800
    mov r8d, 600
    mov r9d, SDL_WINDOW_SHOWN
    call SDL_CreateWindow
    mov r12, rax
    test r12, r12                    ; NULL means failure for pointer-returning SDL calls
    jz .cleanup_sdl

    mov rdi, r12
    mov esi, -1
    mov edx, SDL_RENDERER_ACCELERATED
    call SDL_CreateRenderer
    mov r13, rax
    test r13, r13
    jz .cleanup_window

.loop:
    ; ---- drain every pending event this frame ----
.poll_events:
    mov rdi, rsp                    ; pointer to our 56-byte SDL_Event scratch buffer
    call SDL_PollEvent
    test eax, eax                     ; returns 1 if it wrote an event, 0 if the queue's empty
    jz .render                          ; nothing left this frame -> go render

    mov eax, [rsp]                        ; event.type (first field of every event struct)
    cmp eax, SDL_QUIT_EVENT
    je .cleanup_all
    jmp .poll_events                        ; there may be more than one event queued -- keep draining

.render:
    mov rdi, r13
    mov esi, 30                     ; r
    mov edx, 30                       ; g
    mov ecx, 60                         ; b
    mov r8d, 255                          ; a
    call SDL_SetRenderDrawColor

    mov rdi, r13
    call SDL_RenderClear

    mov rdi, r13
    call SDL_RenderPresent

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
    pop r13
    pop r12
    pop rbp
    ret

; ------------------------------------------------------------
; Build and run:
;   make
;   ./build/02_clear_and_quit
; A dark-blue window should appear. Click its close button (X) — the
; process should exit cleanly (check `echo $?` -> 0), not need to be
; killed.
;
; While it's running, in another terminal:
;   top          (look for this process, note the CPU% — expect ~100
;                 of one core, since nothing paces the loop)
;
; Try this in gdb:
;   (gdb) break .cleanup_all           # NASM local labels need the
;                                         function-qualified form here:
;   (gdb) break main.cleanup_all         # try this exact form instead
;   (gdb) run
;   ... click the window's close button, gdb should stop at the
;   breakpoint the instant SDL_QUIT is detected.
;
; Questions to answer by experimenting:
;   - Change `js .cleanup_none` to always fall through (e.g. comment
;     it out). Break SDL_Init in gdb, force it to return -1 with
;     `return -1` — does the program now crash trying to use a NULL
;     window later, or does something else happen first?
;   - Add a second `mov edi, ...` / `call SDL_PollEvent`-style check
;     for a key press (SDL_KEYDOWN = 0x300) inside `.poll_events`
;     that also jumps to `.cleanup_all` — now you can quit with a
;     keypress too. (You don't need to read which key; just react to
;     the event type.)
; ------------------------------------------------------------
