; save.asm -- the save file (10.08), through raw Linux syscalls
;
; Where: $SAVE if it's set, else $HOME/.courier_save (else ./courier_save).
; What: 64 bytes, dwords --
;    0 magic "CSV1"     4 version (1)      8 money
;   12 shifts           16 deliveries      20 kills
;   24 best shift ($)   28..59 reserved (gear, 10.10 on)
;   60 checksum: the sum of the first 15 dwords, xor SAVE_KEY
; When: at the end of every shift, and when the window closes.
; How: written to <path>.tmp, then renamed over the save, so a crash
; halfway through a write can't leave a half-written save. A save that
; doesn't check out (the wrong size, magic, version or checksum) is
; treated as no save, and the title screen says so.
;
; (A raw syscall clobbers rcx and r11 -- a trap from stage 7: nothing
; here keeps anything in them across one.)

SYS_READ    equ 0
SYS_WRITE   equ 1
SYS_OPEN    equ 2
SYS_CLOSE   equ 3
SYS_RENAME  equ 82
O_RDONLY    equ 0
O_WRONLY_CREAT_TRUNC equ 0x241
SAVE_MODE   equ 0o644
SAVE_SIZE   equ 64
SAVE_MAGIC  equ 0x31565343    ; "CSV1", little-endian
SAVE_VERSION equ 1
SAVE_KEY    equ 0xC0DE5A1E

SAVE_NEW     equ 0            ; no save file: a new one
SAVE_LOADED  equ 1
SAVE_DAMAGED equ 2            ; there was one, and it didn't check out

section .data
    save_env     db "SAVE", 0
    home_env     db "HOME", 0
    save_name    db "/.courier_save", 0
    save_local   db "courier_save", 0
    tmp_suffix   db ".tmp", 0
    save_status  dd SAVE_NEW
    shifts_done  dd 0
    total_deliveries dd 0
    total_kills  dd 0
    best_shift   dd 0

section .bss
    save_path    resb 512
    save_tmp     resb 520
    save_buf     resd SAVE_SIZE / 4

section .text

; copy a C string: rsi -> rdi, rdi left on the terminating 0
%macro STR_COPY 0
%%loop:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz %%done
    inc rsi
    inc rdi
    jmp %%loop
%%done:
%endmacro

; void save_setup(void) -- work out the path (once, at start)
save_setup:
    sub rsp, 8
    lea rdi, [save_env]
    call getenv
    test rax, rax
    jz .ss_home
    mov rsi, rax
    lea rdi, [save_path]
    STR_COPY
    jmp .ss_tmp
.ss_home:
    lea rdi, [home_env]
    call getenv
    lea rdi, [save_path]
    test rax, rax
    jz .ss_local
    mov rsi, rax
    STR_COPY
    lea rsi, [save_name]
    STR_COPY
    jmp .ss_tmp
.ss_local:
    lea rsi, [save_local]
    STR_COPY
.ss_tmp:
    lea rsi, [save_path]
    lea rdi, [save_tmp]
    STR_COPY
    lea rsi, [tmp_suffix]
    STR_COPY
    add rsp, 8
    ret


; eax = the checksum of save_buf's first 15 dwords
%macro SAVE_SUM 0
    xor eax, eax
    lea r8, [save_buf]
    xor edx, edx
%%sum:
    add eax, [r8 + rdx*4]
    inc edx
    cmp edx, 15
    jb %%sum
    xor eax, SAVE_KEY
%endmacro


; void load_save(void) -- read the save, if there is a good one, into
; money and the totals; save_status says how it went
load_save:
    push rbx
    mov dword [save_status], SAVE_NEW
    mov eax, SYS_OPEN
    lea rdi, [save_path]
    mov esi, O_RDONLY
    xor edx, edx
    syscall
    test eax, eax
    js .ls_done                   ; no file: a new save
    mov ebx, eax                  ; fd
    mov eax, SYS_READ
    mov edi, ebx
    lea rsi, [save_buf]
    mov edx, SAVE_SIZE
    syscall
    push rax
    mov eax, SYS_CLOSE
    mov edi, ebx
    syscall
    pop rax
    mov dword [save_status], SAVE_DAMAGED
    cmp eax, SAVE_SIZE
    jne .ls_done
    cmp dword [save_buf], SAVE_MAGIC
    jne .ls_done
    cmp dword [save_buf + 4], SAVE_VERSION
    jne .ls_done
    SAVE_SUM
    cmp eax, [save_buf + 60]
    jne .ls_done
    mov eax, [save_buf + 8]
    mov [money], eax
    mov eax, [save_buf + 12]
    mov [shifts_done], eax
    mov eax, [save_buf + 16]
    mov [total_deliveries], eax
    mov eax, [save_buf + 20]
    mov [total_kills], eax
    mov eax, [save_buf + 24]
    mov [best_shift], eax
    mov dword [save_status], SAVE_LOADED
.ls_done:
    pop rbx
    ret


; void write_save(void) -- money and the totals, to <path>.tmp, then
; renamed over the save
write_save:
    push rbx
    lea rdi, [save_buf]
    xor eax, eax
    mov ecx, SAVE_SIZE / 4
    cld
    rep stosd
    mov dword [save_buf], SAVE_MAGIC
    mov dword [save_buf + 4], SAVE_VERSION
    mov eax, [money]
    mov [save_buf + 8], eax
    mov eax, [shifts_done]
    mov [save_buf + 12], eax
    mov eax, [total_deliveries]
    mov [save_buf + 16], eax
    mov eax, [total_kills]
    mov [save_buf + 20], eax
    mov eax, [best_shift]
    mov [save_buf + 24], eax
    SAVE_SUM
    mov [save_buf + 60], eax
    mov eax, SYS_OPEN
    lea rdi, [save_tmp]
    mov esi, O_WRONLY_CREAT_TRUNC
    mov edx, SAVE_MODE
    syscall
    test eax, eax
    js .ws_done                   ; can't write it: carry on unsaved
    mov ebx, eax
    mov eax, SYS_WRITE
    mov edi, ebx
    lea rsi, [save_buf]
    mov edx, SAVE_SIZE
    syscall
    push rax
    mov eax, SYS_CLOSE
    mov edi, ebx
    syscall
    pop rax
    cmp eax, SAVE_SIZE
    jne .ws_done                  ; a short write: keep the old save
    mov eax, SYS_RENAME
    lea rdi, [save_tmp]
    lea rsi, [save_path]
    syscall
.ws_done:
    pop rbx
    ret
