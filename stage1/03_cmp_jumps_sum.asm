; ============================================================
; 03 — cmp, conditional jumps, and a loop
;
; `cmp a, b` does `a - b` and throws the result away, but keeps the
; CPU flags (zero flag, sign flag, overflow flag, carry flag) that
; the subtraction produced. Every conditional jump after it (jg,
; jle, je, jne, ...) just reads those flags. `cmp` and the jump are
; always a pair — the jump is meaningless without a flag-setting
; instruction right before it (cmp is the most common one).
;
; This one also does real I/O: it computes something, converts the
; result to a decimal string by hand (div by 10 repeatedly, build
; digits back-to-front), and writes it to stdout. That digit-buffer
; trick is the standard way to print an integer with no libc.
; ============================================================
default rel                  ; use RIP-relative addressing for symbol references below
                              ; (modern NASM warns on the old implicit-absolute form)

section .bss
    buf resb 32              ; scratch buffer for building the decimal string

section .text
global _start

_start:
    ; ---- sum 1..10 using cmp + conditional jump as a loop ----
    xor rax, rax          ; rax = running sum, starts at 0
    mov rcx, 1              ; rcx = loop counter i, starts at 1

sum_loop:
    cmp rcx, 10                ; compare i to 10 (computes i - 10, sets flags, discards result)
    jg sum_done                  ; if i > 10 (signed "jump if greater"), exit the loop
    add rax, rcx                   ; sum += i
    inc rcx                          ; i++
    jmp sum_loop                       ; unconditional: go again

sum_done:
    ; rax = 1+2+...+10 = 55

    ; ---- a conditional clamp: if rax > 50, clamp it to 50 ----
    cmp rax, 50
    jle no_clamp             ; if rax <= 50, skip the clamp
    mov rax, 50                ; else clamp
no_clamp:
    ; rax = 50 (since 55 > 50, the clamp fired)

    ; ---- convert rax (unsigned, small) to a decimal string ----
    ; Build the string back-to-front: repeatedly divide by 10, the
    ; remainder is the next digit (least-significant first), so we
    ; write digits from the END of the buffer backward.
    mov rsi, buf + 31        ; rsi = pointer, starts at the last usable byte
    mov byte [rsi], 10         ; buf's last byte = newline ('\n' = 10)
    mov rbx, 10                  ; divisor

convert_loop:
    dec rsi                        ; move the write pointer back one byte
    xor rdx, rdx                     ; clear rdx before div (div uses rdx:rax as the dividend)
    div rbx                            ; rax = rax/10, rdx = rax%10 (unsigned division)
    add dl, '0'                          ; convert the digit (0-9) to its ASCII character
    mov [rsi], dl                          ; write that character
    test rax, rax                            ; test rax, rax sets ZF if rax == 0 (cheaper than cmp rax, 0)
    jnz convert_loop                           ; loop while there's more of the number left

    ; rsi now points at the first digit we wrote (the most significant one)
    lea rdx, [buf + 32]        ; rdx = one-past-the-end of the buffer
    sub rdx, rsi                  ; rdx = length of the string (digits + newline)

    mov rax, 1               ; syscall number: write
    mov rdi, 1                 ; fd: stdout
    ; rsi is already the string pointer, rdx is already the length
    syscall

    mov rax, 60              ; syscall number: exit
    xor rdi, rdi                ; exit code 0
    syscall

; ------------------------------------------------------------
; Build and run this one normally first — it should print "50":
;   nasm -f elf64 -g -F dwarf 03_cmp_jumps_sum.asm -o build/03.o && \
;   ld build/03.o -o build/03_cmp_jumps_sum && ./build/03_cmp_jumps_sum
; (or just `make` from the stage1 directory — see the Makefile)
;
; Then step through it in gdb:
;   (gdb) break sum_loop
;   (gdb) run
;   (gdb) display rax
;   (gdb) display rcx
;   (gdb) continue                # hits the breakpoint again each lap
;   ... watch rax and rcx climb, and count how many `continue`s it
;   takes to reach sum_done (should be 10).
;
; Questions to answer by experimenting:
;   - Change `jg sum_done` to `jge sum_done` (>=  instead of >). What
;     does the final sum become, and why? (Think about which value
;     of i gets included vs excluded.)
;   - Change the sum target from 10 to 20, remove the clamp's effect
;     by raising the clamp threshold to 500, rebuild, rerun — what
;     should print? Verify your prediction against the real output.
;   - `info registers eflags` right after the `cmp rax, 50` — which
;     flags are set, and which one does `jle` actually check?
; ------------------------------------------------------------
