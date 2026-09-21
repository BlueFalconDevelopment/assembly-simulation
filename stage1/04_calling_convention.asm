; ============================================================
; 04 — System V AMD64 calling convention: call, ret, and real
; "functions"
;
; The convention (this is what makes calling SDL2 from asm possible
; in Stage 2 — it's not a Stage-1-only toy rule):
;   - first 6 integer/pointer args go in: rdi, rsi, rdx, rcx, r8, r9
;   - return value comes back in rax
;   - `call` pushes the return address and jumps; `ret` pops it and
;     jumps back — this is why an unbalanced push/pop inside a
;     function is fatal (it eats or shifts the return address)
;   - caller-saved (rax, rdi, rsi, rdx, rcx, r8-r11): a callee is
;     free to clobber these, so the CALLER must save them first if
;     it still needs their values after the call
;   - callee-saved (rbx, rbp, r12-r15): if a function touches these,
;     IT must save and restore them — the caller can assume they
;     survive a call untouched
;   - stack alignment: at the instant `call` executes, rsp must be
;     16-byte aligned. The kernel guarantees this is true at process
;     start (_start), so as long as every push has a matching pop
;     (or every sub rsp has a matching add rsp) before any `call`,
;     you stay aligned automatically.
; ============================================================
section .text
global _start

_start:
    mov rdi, 6              ; arg: n = 6
    call factorial             ; rax = 6! = 720
    mov rdi, rax                  ; move the result into print_uint's arg register

    call print_uint                  ; prints "720\n"

    mov rax, 60              ; syscall number: exit
    xor rdi, rdi                ; exit code 0
    syscall


; ------------------------------------------------------------
; factorial(n: rdi) -> rax
; Recursive. n is caller-saved, so across the recursive `call`,
; the callee (a recursive copy of ourselves) is allowed to clobber
; rdi — we have to save our own copy on the stack first.
; ------------------------------------------------------------
factorial:
    cmp rdi, 1
    jg .recurse
    mov rax, 1              ; base case: factorial(0) = factorial(1) = 1
    ret
.recurse:
    push rdi                    ; save n (stack: was 16-aligned on entry, now +8 = still fine
                                    ; for the call below, since push made it aligned again)
    dec rdi                          ; rdi = n - 1
    call factorial                      ; rax = (n-1)!  -- recursion
    pop rdi                                ; restore our n (undo the push above)
    imul rax, rdi                             ; rax = n * (n-1)!
    ret


; ------------------------------------------------------------
; print_uint(n: rdi) -> void
; Prints n as a decimal string followed by a newline.
; Uses its own stack frame (rbp-based) for scratch space instead of
; a global .bss buffer — this is the standard "local variables"
; pattern you'll use constantly from here on.
; ------------------------------------------------------------
print_uint:
    push rbp                 ; save caller's frame pointer (rbp is callee-saved)
    mov rbp, rsp                ; establish our own frame: rbp = fixed reference point
    sub rsp, 32                    ; 32 bytes of local scratch (multiple of 16 -> stays aligned)

    mov rax, rdi              ; the number to convert
    lea rsi, [rbp - 1]           ; rsi = pointer to the last byte of our local buffer
    mov byte [rsi], 10              ; newline
    mov rbx, 10                        ; divisor (rbx is callee-saved — safe to use here since
                                           ; we don't call anything else before restoring it implicitly
                                           ; by never touching the caller's rbx value... see note below)

.convert_loop:
    dec rsi
    xor rdx, rdx
    div rbx                     ; rax = rax/10, rdx = rax%10
    add dl, '0'
    mov [rsi], dl
    test rax, rax
    jnz .convert_loop

    lea rdx, [rbp - 1]         ; one-past-the-end of the digits region
    sub rdx, rsi                  ; rdx = length of string (digits + newline)

    mov rax, 1                  ; syscall number: write
    mov rdi, 1                     ; fd: stdout
    ; rsi is already the string pointer, rdx already the length
    syscall

    mov rsp, rbp             ; tear down the local scratch space
    pop rbp                     ; restore caller's frame pointer
    ret

; ------------------------------------------------------------
; Build and run — should print "720":
;   make        (from the stage1 directory)
;   ./build/04_calling_convention
;
; Try this in gdb — watch the stack grow with each recursive call:
;   (gdb) break factorial
;   (gdb) run
;   (gdb) print $rdi              # n for this call
;   (gdb) print $rsp              # note the address
;   (gdb) continue                # hits the breakpoint again on recursion
;   ... repeat `print $rdi` / `print $rsp` / `continue` about 6 times.
;   rsp should get SMALLER (stack grows down) by 8 on each recursive
;   entry (that's the `push rdi` before each `call`). After the base
;   case, keep hitting `finish` repeatedly and watch rax build up:
;   1, then 2, then 6, then 24, then 120, then 720.
;
; Questions to answer by experimenting:
;   - Delete the `push rdi` / `pop rdi` pair in .recurse (leave the
;     `call factorial` in place). Rebuild and run it. What breaks,
;     and can you explain why from the comment above about rdi being
;     caller-saved?
;   - In print_uint, the comment claims rbx is "callee-saved" and
;     therefore safe to clobber only if we restore it. We DON'T
;     restore it here before returning. Is that actually a bug given
;     what this specific program does afterward? What would make it
;     a real bug in a bigger program?
;   - Try calling factorial(20) instead of 6. The true value of 20!
;     doesn't fit in 64 bits — what garbage value do you get, and at
;     what n does it start going wrong? (This is `idiv`/`imul`
;     overflow, silent and very real in asm — no exception like a
;     higher-level language might give you.)
; ------------------------------------------------------------
