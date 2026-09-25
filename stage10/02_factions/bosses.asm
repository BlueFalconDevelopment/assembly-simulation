; bosses.asm -- the Big Homie
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; The Big Homie (see the header)
; ============================================================

; int team_strength(int team: edi) -> eax
; Everything a gang has left: each soldier alive or waiting to
; respawn counts 1, plus every life it still has in reserve. -1 if
; any of them has unlimited lives (then there's nothing to count).
team_strength:
    xor eax, eax
    lea r8, [soldiers]
    lea r9, [respawn_timer]
    lea r10, [lives_left]
    xor ecx, ecx
.ts_loop:
    cmp [r8 + Soldier.team], edi
    jne .ts_next
    cmp dword [r8 + Soldier.health], 0
    jg .ts_in_play
    cmp dword [r9 + rcx*4], 0
    jle .ts_next                  ; out for good (lives are 0 too)
.ts_in_play:
    inc eax
    mov edx, [r10 + rcx*4]
    test edx, edx
    js .ts_unlimited
    add eax, edx
.ts_next:
    add r8, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .ts_loop
    ret
.ts_unlimited:
    mov eax, -1
    ret


; void update_bosses(void) -- once per tick. Decides when each gang's
; Big Homie is due, and sends him out of the lobby once there's room.
update_bosses:
    push rbx
    push r12
    push r13
    cmp dword [boss_alert], 0
    jle .ub_alert_done
    dec dword [boss_alert]
.ub_alert_done:
    xor ebx, ebx                  ; gang
.ub_team:
    cmp dword [boss_state + rbx*4], 0
    jne .ub_due
    cmp dword [boss_at], 0
    jle .ub_next                  ; BOSS_AT=0: no Big Homies
    ; (the Big Homie is between the two gangs, 0 and 1: "the other
    ; gang" is gang xor 1 below)
    ; not while the other gang's Big Homie is out and alive: otherwise
    ; the side he's beating just gets its own and cancels him out
    mov eax, ebx
    xor eax, 1
    imul eax, eax, Soldier_size
    lea r10, [soldiers + BOSS0 * Soldier_size]
    cmp dword [r10 + rax + Soldier.health], 0
    jg .ub_next
    mov edi, ebx
    call team_strength
    mov r12d, eax                 ; ours
    mov edi, ebx
    xor edi, 1
    call team_strength
    mov r13d, eax                 ; theirs
    test r12d, r12d
    jz .ub_next                   ; already beaten
    js .ub_by_kills
    test r13d, r13d
    js .ub_by_kills
    ; ours * 100 < BOSS_AT * theirs ?
    imul r12d, r12d, 100
    imul r13d, [boss_at]
    cmp r12d, r13d
    jge .ub_next
    jmp .ub_trigger
.ub_by_kills:
    ; unlimited lives: BOSS_KILL_GAP kills behind
    mov eax, ebx
    xor eax, 1
    mov eax, [score + rax*4]
    sub eax, [score + rbx*4]
    cmp eax, BOSS_KILL_GAP
    jl .ub_next
.ub_trigger:
    mov dword [boss_state + rbx*4], 1
.ub_due:
    cmp dword [boss_state + rbx*4], 1
    jne .ub_next
    lea edi, [ebx + BOSS0]
    call respawn_soldier          ; a safe spot in the lobby, protection
    test eax, eax
    jz .ub_next                   ; lobby full: try again next tick
    imul eax, ebx, Soldier_size
    lea r10, [soldiers + BOSS0 * Soldier_size]
    add r10, rax
    mov dword [r10 + Soldier.health], BOSS_HEALTH
    mov dword [r10 + Soldier.weapon], WEAPON_PISTOL
    mov dword [boss_state + rbx*4], 2
    cmp dword [boss_tick], 0
    jne .ub_tick_kept
    mov eax, [ticks]
    mov [boss_tick], eax
.ub_tick_kept:
    mov dword [boss_alert], BOSS_ALERT_TICKS
    mov [boss_alert_team], ebx
.ub_next:
    inc ebx
    cmp ebx, 2
    jb .ub_team
    pop r13
    pop r12
    pop rbx
    ret


; void draw_bosses(void) -- a health bar over each Big Homie who's out
; (drawing only; his gold bandana and chain are in draw_soldier)
draw_bosses:
    push rbx
    push r12
    push r13
    xor ebx, ebx
.db_loop:
    lea r12, [soldiers + BOSS0 * Soldier_size]
    imul eax, ebx, Soldier_size
    add r12, rax
    cmp dword [r12 + Soldier.health], 0
    jle .db_next
    ; health bar above him: SOLDIER_SIZE + 4 wide at full health
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    sub esi, 2
    mov edx, [r12 + Soldier.y]
    sub edx, 7
    mov ecx, SOLDIER_SIZE + 4
    mov r8d, 3
    mov r9d, COLOR_BAR_BACK
    call fill_rect
    mov eax, [r12 + Soldier.health]
    imul eax, SOLDIER_SIZE + 4
    xor edx, edx
    mov ecx, BOSS_HEALTH
    div ecx
    mov r13d, eax
    test r13d, r13d
    jz .db_next
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    sub esi, 2
    mov edx, [r12 + Soldier.y]
    sub edx, 7
    mov ecx, r13d
    mov r8d, 3
    mov r9d, COLOR_BAR
    call fill_rect
.db_next:
    inc ebx
    cmp ebx, 2
    jb .db_loop
    pop r13
    pop r12
    pop rbx
    ret
