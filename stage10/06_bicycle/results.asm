; results.asm -- the win line and number formatting
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; void print_result(char* msg: rsi, int len: edx)
;
; Writes "<msg> (friendly fire: H hits, K kills; held fire N times)\n"
; in ONE write().
; batch.sh stops a game as soon as its output file isn't empty, so
; with more than one write it could read half a line.
print_result:
    push rbx
    lea rdi, [msg_buf]
    call append_bytes
    lea rsi, [on_msg]
    mov edx, on_msg_len
    call append_bytes
    call append_arena_name
    lea rsi, [ff_msg1]
    mov edx, ff_msg1_len
    call append_bytes
    mov esi, [ff_hits]
    call append_uint
    lea rsi, [ff_msg2]
    mov edx, ff_msg2_len
    call append_bytes
    mov esi, [ff_kills]
    call append_uint
    lea rsi, [ff_msg3]
    mov edx, ff_msg3_len
    call append_bytes
    mov esi, [ff_held]
    call append_uint
    lea rsi, [ff_msg4]
    mov edx, ff_msg4_len
    call append_bytes
    mov esi, [ticks]
    call append_uint
    lea rsi, [ff_msg5]
    mov edx, ff_msg5_len
    call append_bytes
    lea rsi, [score_msg]
    mov edx, score_msg_len
    call append_bytes
    mov esi, [score]
    call append_uint
    mov byte [rdi], '-'
    inc rdi
    mov esi, [score + 4]
    call append_uint
    lea rsi, [boss_msg]
    mov edx, boss_msg_len
    call append_bytes
    mov esi, [boss_count]         ; times each gang's came out (10.04)
    call append_uint
    mov byte [rdi], '-'
    inc rdi
    mov esi, [boss_count + 4]
    call append_uint
    cmp dword [boss_tick], 0
    je .pr_no_boss_tick
    lea rsi, [boss_tick_msg]
    mov edx, boss_tick_msg_len
    call append_bytes
    mov esi, [boss_tick]
    call append_uint
.pr_no_boss_tick:
    lea rsi, [ev_msg1]
    mov edx, ev_msg1_len
    call append_bytes
    mov esi, [arrests]
    call append_uint
    lea rsi, [ev_msg2]
    mov edx, ev_msg2_len
    call append_bytes
    mov esi, [cop_kills]
    call append_uint
    lea rsi, [ev_msg3]
    mov edx, ev_msg3_len
    call append_bytes
    mov esi, [dog_kills]
    call append_uint
    ; "; homes 0-1; crips home 1": the pair's two sites, and the Crips'
    ; (10.03: batches score each pair from these)
    lea rsi, [homes_msg]
    mov edx, homes_msg_len
    call append_bytes
    mov eax, [pair]
    lea rcx, [pair_sites]
    mov esi, [rcx + rax*8]
    call append_uint
    mov byte [rdi], '-'
    inc rdi
    mov eax, [pair]
    lea rcx, [pair_sites]
    mov esi, [rcx + rax*8 + 4]
    call append_uint
    lea rsi, [crips_home_msg]
    mov edx, crips_home_msg_len
    call append_bytes
    mov esi, [home]
    call append_uint
    cmp dword [player_on], 0
    je .pr_no_player
    lea rsi, [you_msg1]           ; "; you: kills 5, deaths 2" (10.05)
    mov edx, you_msg1_len
    call append_bytes
    mov esi, [player_kills]
    call append_uint
    lea rsi, [you_msg2]
    mov edx, you_msg2_len
    call append_bytes
    mov esi, [player_deaths]
    call append_uint
.pr_no_player:
    cmp dword [show_seed], 0
    je .pr_no_seed
    lea rsi, [seed_msg]
    mov edx, seed_msg_len
    call append_bytes
    mov rsi, [game_seed]
    call append_hex64
.pr_no_seed:
    lea rsi, [ff_msg6]
    mov edx, ff_msg6_len
    call append_bytes

    lea rsi, [msg_buf]
    mov rdx, rdi
    sub rdx, rsi                    ; length = end - start
    mov eax, 1                      ; write(stdout, msg_buf, len)
    mov edi, 1
    syscall
    pop rbx
    ret

; append_hex64(dst: rdi, n: rsi) -> rdi = past the digits
; "0x" and all 16 hex digits, most significant first: rotate the next
; nibble into the bottom 4 bits, then look it up.
append_hex64:
    mov word [rdi], '0x'
    add rdi, 2
    mov ecx, 16
.ah_loop:
    rol rsi, 4
    mov eax, esi
    and eax, 0xF
    lea rdx, [hex_digits]
    mov al, [rdx + rax]
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .ah_loop
    ret

; append_bytes(dst: rdi, src: rsi, len: edx) -> rdi = dst + len
append_bytes:
    mov ecx, edx
    cld
    rep movsb
    ret

; append_uint(dst: rdi, n: esi) -> rdi = past the last digit
;
; Divides by 10 repeatedly, which gives the digits last-first, so they
; are written backwards into scratch space below rsp and then copied
; forwards. It's a leaf function, so the 128 bytes below rsp (the
; System V "red zone") are ours to use without moving rsp. 10 digits
; is the most a 32-bit number needs.
append_uint:
    mov eax, esi
    lea r9, [rsp - 8]               ; one past the last digit
    mov r8, r9
    mov ecx, 10
.au_loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec r8
    mov [r8], dl
    test eax, eax
    jnz .au_loop
    mov rsi, r8
    mov rcx, r9
    sub rcx, r8
    rep movsb
    ret
