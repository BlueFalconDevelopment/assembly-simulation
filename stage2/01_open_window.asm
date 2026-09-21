; ============================================================
; 01 — Open a window (the entry point changes here)
;
; Everything in Stage 1 defined `_start` and linked with `ld` alone,
; making raw syscalls directly. That only works because those
; programs needed nothing from libc.
;
; SDL2 is a dynamic library (libSDL2.so) that itself depends on libc,
; pthreads, the X11/Wayland client libraries, etc. Getting all of
; that wired up by hand (dynamic symbol resolution, the PLT/GOT,
; TLS setup for pthreads...) is a rabbit hole with no teaching value.
; So from here on we let `gcc` act as pure a linker driver: it
; supplies the real C runtime startup (crt1.o), which does real work
; (sets up TLS, calls global constructors, etc.) before calling a
; function named `main` — so THAT's the symbol we export now instead
; of `_start`. We still write zero lines of C. `main` is just a
; label as far as we're concerned; the difference is what calls it.
;
; Every SDL function we call is declared `extern` and follows the
; exact System V calling convention from stage1/04 — this is the
; payoff for learning that stage properly. No headers, no bindings,
; just: know the function's real signature, and put args in the
; right registers.
; ============================================================
default rel
global main

extern SDL_Init
extern SDL_CreateWindow
extern SDL_CreateRenderer
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit
extern SDL_Delay

; ---- constants copied from SDL2's headers (SDL_init.h, SDL_video.h,
; SDL_render.h) — we don't include the headers, so these numeric
; values just have to be known/looked up ----
SDL_INIT_VIDEO            equ 0x00000020
SDL_WINDOWPOS_UNDEFINED   equ 0x1FFF0000
SDL_WINDOW_SHOWN          equ 0x00000004
SDL_RENDERER_ACCELERATED  equ 0x00000002

section .data
    title db "Stage 2.01 - it opens", 0   ; NUL-terminated, like every C string

section .text
main:
    push rbp
    mov rbp, rsp
    push r12              ; will hold the SDL_Window*  (callee-saved: survives our calls)
    push r13                 ; will hold the SDL_Renderer*
    ; two pushes above rbp -> rsp is 16-aligned again here, ready for `call`

    ; ---- SDL_Init(SDL_INIT_VIDEO) ----
    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    ; returns 0 on success, negative on failure -- Stage 2.02 actually
    ; checks this; here we're just proving the link works at all

    ; ---- SDL_CreateWindow(title, x, y, w, h, flags) ----
    ; 6 args -> rdi, rsi, rdx, rcx, r8, r9, exactly like stage1/04 taught
    lea rdi, [title]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, 800
    mov r8d, 600
    mov r9d, SDL_WINDOW_SHOWN
    call SDL_CreateWindow
    mov r12, rax                   ; save the returned SDL_Window* (rax is caller-saved,
                                       ; would get clobbered by the next call otherwise)

    ; ---- SDL_CreateRenderer(window, index, flags) ----
    mov rdi, r12
    mov esi, -1                      ; -1 = "pick the first driver that supports these flags"
    mov edx, SDL_RENDERER_ACCELERATED
    call SDL_CreateRenderer
    mov r13, rax                        ; save the SDL_Renderer*

    ; hold the window open for 3 seconds so a human can see it
    mov edi, 3000
    call SDL_Delay

    ; ---- cleanup, in reverse order of creation ----
    mov rdi, r13
    call SDL_DestroyRenderer
    mov rdi, r12
    call SDL_DestroyWindow
    call SDL_Quit

    xor eax, eax           ; return 0 from main
    pop r13
    pop r12
    pop rbp
    ret

; ------------------------------------------------------------
; Build and run (from the stage2 directory):
;   make
;   ./build/01_open_window
; A window titled "Stage 2.01 - it opens" should appear for 3 seconds,
; showing whatever garbage was in the window's backbuffer (we never
; clear it — that's 02's job) — expect flicker/undefined content,
; that's normal and not a bug.
;
; Try this in gdb (SDL forks no extra process, so ordinary breakpoints
; work fine):
;   gdb ./build/01_open_window
;   (gdb) break SDL_CreateWindow
;   (gdb) run
;   (gdb) finish                     # runs to completion of SDL_CreateWindow
;   (gdb) print/x $rax               # libSDL2 has no debug symbols, so `finish`
;                                       won't auto-print "Value returned" -- read
;                                       rax directly instead; this is the SDL_Window*
;   (gdb) print/x $r12               # after stepping past `mov r12, rax`, should match
;
; Questions to answer by experimenting:
;   - Comment out `call SDL_Init` entirely, rebuild, run. Does the
;     window still appear? What does that tell you about how
;     defensive real code needs to be about checking return codes?
;   - Change SDL_WINDOW_SHOWN to 0. Does a window appear? (Look up
;     what SDL_WINDOW_SHOWN actually controls to predict this first.)
;   - What happens if you swap the cleanup order — destroy the window
;     before the renderer? (Try it. Does it crash, warn, or silently
;     work? SDL is often more forgiving here than raw syscalls would be.)
; ------------------------------------------------------------
