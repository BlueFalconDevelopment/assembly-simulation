; win.asm -- check_win
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; int check_win(void) -> eax: 0 = still going, g + 1 = gang g won.
; A gang that reached the score limit wins. Otherwise a gang is out
; when nobody in it is alive AND nobody is waiting to respawn, and the
; last gang in play wins. (10.02: any number of gangs, factions 0 ..
; NUM_GANGS-1; the other factions don't count. If the last gangs all
; go out at once, the highest-numbered one is named, as 9.03's "team 0
; out: team 1 wins" did.)
;   ebx: bit g set = gang g has someone in play
check_win:
    xor eax, eax
    cmp dword [game_mode], 0
    jne .cw_ret                   ; the endless war: nobody wins (10.04)
    mov eax, [score_winner]
    test eax, eax
    jnz .cw_ret
    push rbx
    xor ebx, ebx
    lea r10, [soldiers]
    lea r11, [respawn_timer]
    xor ecx, ecx
.cw_loop:
    cmp dword [r10 + Soldier.health], 0
    jg .cw_in_play
    cmp dword [r11 + rcx*4], 0
    jle .cw_next
.cw_in_play:
    mov eax, [r10 + Soldier.team]
    cmp eax, NUM_GANGS
    jae .cw_next                  ; not a gang
    bts ebx, eax
.cw_next:
    add r10, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .cw_loop
    xor eax, eax
    lea ecx, [ebx - 1]
    test ecx, ebx
    jnz .cw_return                ; two or more gangs in play: going on
    mov eax, NUM_GANGS            ; none left at all
    test ebx, ebx
    jz .cw_return
    bsf eax, ebx                  ; exactly one: that gang
    inc eax
.cw_return:
    pop rbx
.cw_ret:
    ret
