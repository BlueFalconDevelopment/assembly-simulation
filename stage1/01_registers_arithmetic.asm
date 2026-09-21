; ============================================================
; 01 — Registers, mov, and arithmetic
;
; This program does no I/O. It's meant to be stepped through in
; gdb, one instruction at a time, watching registers change.
; The final value ends up in rax and becomes the process exit code
; (only the low byte survives — `echo $?` will show a value 0-255).
; ============================================================
section .text
global _start

_start:
    ; ---- mov: copy an immediate value into a register ----
    mov rax, 10          ; rax = 10
    mov rbx, 3           ; rbx = 3

    ; ---- basic arithmetic: destination is always the first operand ----
    add rax, rbx         ; rax = rax + rbx      -> 13
    sub rax, 5            ; rax = rax - 5         -> 8
    imul rax, rbx           ; rax = rax * rbx        -> 24

    ; ---- division is two-operand and weird: idiv takes ONE operand,
    ; and implicitly divides the 128-bit value rdx:rax by it.
    ; rax = quotient, rdx = remainder. You MUST set up rdx first,
    ; or you're dividing by whatever garbage was sitting in rdx. ----
    mov rax, 100
    cqo                     ; sign-extends rax into rdx:rax (rdx = 0 here, since rax is positive)
    mov rcx, 7
    idiv rcx                 ; rax = 100/7 = 14, rdx = 100%7 = 2

    ; ---- bitwise ops ----
    mov rax, 0b1010            ; 10
    mov rbx, 0b0110              ; 6
    and rax, rbx                   ; rax = 0b0010 = 2
    or  rax, 0b1000                  ; rax = 0b1010 = 10
    xor rax, rax                       ; rax = 0 — the idiomatic way to zero a register
                                          ; (shorter encoding than `mov rax, 0`, and sets flags)
    mov rax, 1
    shl rax, 4                             ; rax = 1 << 4 = 16   (shift left = multiply by 2^n)
    shr rax, 2                               ; rax = 16 >> 2 = 4   (shift right = divide by 2^n)

    ; exit with rax as the exit code
    mov rdi, rax
    mov rax, 60           ; syscall number: exit
    syscall

; ------------------------------------------------------------
; Try this in gdb (from this directory, after building):
;
;   gdb ./build/01_registers_arithmetic
;   (gdb) break _start
;   (gdb) run
;   (gdb) stepi                       # step ONE instruction
;   (gdb) info registers rax rbx rcx rdx
;   ... repeat stepi + info registers after every line, and predict
;   the value BEFORE you look. Get it wrong at least once — that's
;   where the actual learning happens.
;
; Questions to answer by experimenting, not by reading docs:
;   - What does `info registers rax` show right after `xor rax, rax`?
;     Check `info registers eflags` too — which flag(s) does xor set?
;   - Change `idiv rcx` to divide by a bigger number than fits — e.g.
;     set rax huge and rdx nonzero before idiv without cqo. What happens?
;     (This is the classic "forgot to sign-extend" bug — good to see it
;     crash once on purpose.)
;   - `echo $?` after running the binary normally (not under gdb) —
;     does it match the last rax you saw?
; ------------------------------------------------------------
