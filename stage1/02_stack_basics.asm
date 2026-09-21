; ============================================================
; 02 — The stack: push, pop, and manual scratch space
;
; The stack grows DOWN: push decrements rsp by 8 then writes;
; pop reads then increments rsp by 8. It's LIFO — last pushed,
; first popped. `call`/`ret` (covered in 04) use this same stack
; implicitly to store return addresses — that's why an unbalanced
; push/pop inside a function is a guaranteed crash later.
; ============================================================
section .text
global _start

_start:
    mov rax, 111
    mov rbx, 222
    mov rcx, 333

    push rax          ; rsp -= 8; [rsp] = 111
    push rbx           ; rsp -= 8; [rsp] = 222
    push rcx             ; rsp -= 8; [rsp] = 333   <- top of stack now

    ; LIFO: the first thing we pop is the LAST thing we pushed
    pop rdx           ; rdx = 333
    pop rsi            ; rsi = 222
    pop rdi              ; rdi = 111
    ; stack is now back to where it started before the three pushes

    ; ---- manual scratch space: reserve bytes without push/pop ----
    ; `sub rsp, N` carves out N bytes of raw stack memory you can
    ; address directly. You MUST undo it with `add rsp, N` before
    ; the function returns (or before any `call`/`ret`), or you'll
    ; corrupt the return address sitting below it.
    sub rsp, 16
    mov qword [rsp], 42        ; write 8 bytes at [rsp]
    mov qword [rsp+8], 99       ; write 8 bytes at [rsp+8]
    mov rax, [rsp]
    add rax, [rsp+8]              ; rax = 42 + 99 = 141
    add rsp, 16                     ; give the 16 bytes back — MUST match the sub above

    mov rdi, rax           ; exit code = 141 (mod 256 — it fits, so it'll show as 141)
    mov rax, 60
    syscall

; ------------------------------------------------------------
; Try this in gdb:
;
;   gdb ./build/02_stack_basics
;   (gdb) break _start
;   (gdb) run
;   (gdb) print $rsp                  # note the starting address
;   (gdb) stepi                       # step past `push rax`
;   (gdb) print $rsp                  # rsp dropped by 8
;   (gdb) x/1gx $rsp                  # examine 1 giant (8-byte) hex value at rsp -> should show 111 (0x6f)
;   ... continue stepping through all three pushes, watching rsp
;   drop by 8 each time and `x/1gx $rsp` show the new top value.
;   Then step through the three pops and watch rsp climb back up.
;
; Questions to answer by experimenting:
;   - After `sub rsp, 16`, what does `x/2gx $rsp` show before you
;     write anything? (Garbage — whatever was there before. This is
;     why uninitialized stack locals are a real bug source.)
;   - Remove the final `add rsp, 16` and run it anyway (not under
;     gdb, just `./build/02_stack_basics; echo $?`). It still "works"
;     here because we exit right after via syscall — but note WHY
;     this would be fatal if there were a `ret` after it. That's the
;     bug you're setting up to avoid in 04.
; ------------------------------------------------------------
