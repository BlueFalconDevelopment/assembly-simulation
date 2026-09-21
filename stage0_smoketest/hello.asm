; Stage 0 smoke test: pure syscalls, no libc, no gcc.
; Proves nasm assembles and ld links a working Linux binary.
section .data
    msg     db "toolchain works", 10   ; 10 = newline
    msg_len equ $ - msg

section .text
    global _start

_start:
    mov rax, 1          ; syscall number: write
    mov rdi, 1          ; fd: stdout
    mov rsi, msg        ; buffer
    mov rdx, msg_len    ; length
    syscall

    mov rax, 60         ; syscall number: exit
    mov rdi, 0          ; exit code
    syscall
