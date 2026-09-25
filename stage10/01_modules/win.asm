; win.asm -- check_win
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; int check_win(void) -> eax: 0 = still going, 1 = team 0 won,
; 2 = team 1 won.
; A team that reached the score limit wins. Otherwise a team is out
; when nobody on it is alive AND nobody is waiting to respawn.
check_win:
    mov eax, [score_winner]
    test eax, eax
    jnz .cw_ret
    push rbx
    push r12
    xor ebx, ebx                  ; team 0 in play
    xor r12d, r12d                ; team 1 in play
    lea r10, [soldiers]
    lea r11, [respawn_timer]
    xor ecx, ecx
.cw_loop:
    cmp dword [r10 + Soldier.health], 0
    jg .cw_in_play
    cmp dword [r11 + rcx*4], 0
    jle .cw_next
.cw_in_play:
    cmp dword [r10 + Soldier.team], 0
    jne .cw_team1
    inc ebx
    jmp .cw_next
.cw_team1:
    inc r12d
.cw_next:
    add r10, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .cw_loop
    xor eax, eax
    test ebx, ebx
    jnz .check_t1
    mov eax, 2
    jmp .cw_return
.check_t1:
    test r12d, r12d
    jnz .cw_return
    mov eax, 1
.cw_return:
    pop r12
    pop rbx
.cw_ret:
    ret
