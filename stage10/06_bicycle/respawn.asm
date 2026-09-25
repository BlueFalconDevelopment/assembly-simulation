; respawn.asm -- rules from the environment, respawns
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; Respawns (see the header)
; ============================================================

; void read_mode(void) -- MODE=game or MODE=watch (10.04). Game: the
; endless war -- unlimited lives and respawns, no score limit, nobody
; wins, and a dead Big Homie can come back. Watch: last gang standing,
; as before, for batches and replays. Unset: watch when HEADLESS, game
; in a window. Called first thing by read_rules.
read_mode:
    sub rsp, 8
    lea rdi, [mode_env]
    call getenv
    test rax, rax
    jz .rm_default
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [mode_game]
    call strcmp
    test eax, eax
    jz .rm_game
    mov rdi, [rsp]
    lea rsi, [mode_watch]
    call strcmp
    test eax, eax
    jz .rm_done                   ; watch (game_mode stays 0)
.rm_default:
    call is_headless
    test eax, eax
    jnz .rm_done
.rm_game:
    mov dword [game_mode], 1
.rm_done:
    add rsp, 8
    ret


; void read_rules(void) -- RESPAWNS, LIVES and SCORE_LIMIT from the
; environment
read_rules:
    sub rsp, 8                    ; align the stack for the libc calls
    call read_mode
    ; LIVES=n: every soldier gets n-1 respawns. Unset: DEFAULT_LIVES.
    ; LIVES=0 (or less): no limit. The default goes in AFTER getenv:
    ; ecx is caller-saved, and getenv is free to change it (it did:
    ; the first version of this set ecx first, and every soldier got
    ; 68 respawns instead of the default)
    lea rdi, [lives_env]
    call getenv
    mov ecx, DEFAULT_LIVES - 1
    test rax, rax
    jz .rr_fill
    mov rdi, rax
    call atoi
    mov ecx, -1
    test eax, eax
    jle .rr_fill                  ; LIVES=0: unlimited
    lea ecx, [eax - 1]            ; lives -> respawns
.rr_fill:
    lea rdx, [lives_left]
    xor eax, eax
.rr_fill_loop:
    mov [rdx + rax*4], ecx
    inc eax
    cmp eax, TOTAL_SOLDIERS
    jl .rr_fill_loop

    lea rdi, [respawns_env]
    call getenv
    test rax, rax
    jz .rr_score                  ; unset: unlimited (tickets stay -1)
    mov rdi, rax
    call atoi
    mov [tickets], eax            ; negative also means unlimited
    mov [tickets + 4], eax
.rr_score:
    lea rdi, [boss_env]
    call getenv
    test rax, rax
    jz .rr_score2
    mov rdi, rax
    call atoi
    mov [boss_at], eax
.rr_score2:
    lea rdi, [time_env]           ; TIME=h: the game starts at h:00
    call getenv
    test rax, rax
    jz .rr_time_done
    mov rdi, rax
    call atoi
    cmp eax, 23
    ja .rr_time_done
    imul eax, eax, 60
    mov [tod_start], eax
.rr_time_done:
    lea rdi, [score_env]
    call getenv
    test rax, rax
    jz .rr_done
    mov rdi, rax
    call atoi
    mov [score_limit], eax        ; 0 or less: no limit
.rr_done:
    ; game mode: the endless war (10.04), whatever LIVES, RESPAWNS and
    ; SCORE_LIMIT said -- unlimited lives and respawns, no score limit
    cmp dword [game_mode], 0
    je .rr_out
    lea rdx, [lives_left]
    xor eax, eax
.rr_endless:
    mov dword [rdx + rax*4], -1
    inc eax
    cmp eax, TOTAL_SOLDIERS
    jl .rr_endless
    lea rdx, [tickets]
    xor eax, eax
.rr_endless_tickets:
    mov dword [rdx + rax*4], -1
    inc eax
    cmp eax, MAX_FACTIONS
    jl .rr_endless_tickets
    mov dword [score_limit], 0
.rr_out:
    add rsp, 8
    ret


; append_score(dst: rdi, n: esi) -> rdi: "n", or "n/limit" if there is one
append_score:
    call append_uint
    mov esi, [score_limit]
    test esi, esi
    jle .as_done
    mov byte [rdi], '/'
    inc rdi
    call append_uint
.as_done:
    ret


; void process_respawns(void) -- once per tick, after everyone moved.
; Counts down spawn protection, and respawn timers; a timer that
; reaches 1 tries to respawn its soldier every tick until it works.
; Same processing direction as this tick's update_soldiers
; (pass_reverse), so neither team always gets first pick.
process_respawns:
    push rbx
    push r12
    sub rsp, 8
    xor ebx, ebx
.pr_loop:
    cmp ebx, TOTAL_SOLDIERS
    jge .pr_done
    mov r12d, ebx
    cmp dword [pass_reverse], 0
    je .pr_have
    mov r12d, TOTAL_SOLDIERS - 1
    sub r12d, ebx
.pr_have:
    lea rcx, [protect_timer]
    cmp dword [rcx + r12*4], 0
    jle .pr_no_protect
    dec dword [rcx + r12*4]
.pr_no_protect:
    lea rcx, [respawn_timer]
    mov eax, [rcx + r12*4]
    test eax, eax
    jle .pr_next                  ; alive, or dead for good
    cmp eax, 1
    je .pr_try
    dec dword [rcx + r12*4]
    jmp .pr_next
.pr_try:
    mov edi, r12d
    call respawn_soldier
    test eax, eax
    jz .pr_next                   ; no free spot: try again next tick
    lea rcx, [respawn_timer]
    mov dword [rcx + r12*4], 0
.pr_next:
    inc ebx
    jmp .pr_loop
.pr_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; int respawn_soldier(int i: edi) -> eax (1 = done, 0 = no free spot)
; RESPAWN_TRIES random spots in the soldier's home lobby. Skips spots another soldier
; blocks; of the rest, takes the one whose nearest living enemy is
; farthest away. Then resets the soldier as if new, with spawn
; protection.
;   ebx soldier   r12d tries left   r13d/r14d candidate x/y
;   r15d its nearest-enemy distance^2   stack: best x, y, distance
RS_BEST_X equ 0
RS_BEST_Y equ 4
RS_BEST_D equ 8
respawn_soldier:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                   ; 5 pushes + 16: 16-byte aligned
    mov ebx, edi
    mov dword [rsp + RS_BEST_D], -1
    mov r12d, RESPAWN_TRIES
.rs_try:
    ; a random spot in this soldier's home lobby (r15 is free until
    ; the distance below)
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    mov eax, [rcx + rax + Soldier.team]
    mov eax, [home + rax*4]
    shl eax, 4
    lea r15, [site_lobbies]
    add r15, rax
    mov edi, [r15 + 8]
    sub edi, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    call rand_range
    add eax, [r15]
    lea r13d, [eax + LOBBY_MARGIN]
    mov edi, [r15 + 12]
    sub edi, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    call rand_range
    add eax, [r15 + 4]
    lea r14d, [eax + LOBBY_MARGIN]
    mov edi, ebx
    mov esi, r13d
    mov edx, r14d
    call is_spot_blocked
    test eax, eax
    jnz .rs_next_try

    ; distance^2 to the nearest living enemy
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    mov r8d, [rcx + rax + Soldier.team]
    mov r15d, 0x7FFFFFFF
    xor edx, edx
.rs_enemy:
    cmp dword [rcx + Soldier.health], 0
    jle .rs_enemy_next
    mov eax, [rcx + Soldier.team]
    HOSTILE rax, r8, rax           ; an enemy of ours? (10.02)
    jz .rs_enemy_next
    mov eax, [rcx + Soldier.x]
    sub eax, r13d
    imul eax, eax
    mov r9d, [rcx + Soldier.y]
    sub r9d, r14d
    imul r9d, r9d
    add eax, r9d
    cmp eax, r15d
    jae .rs_enemy_next
    mov r15d, eax
.rs_enemy_next:
    add rcx, Soldier_size
    inc edx
    cmp edx, TOTAL_SOLDIERS
    jl .rs_enemy

    cmp r15d, [rsp + RS_BEST_D]   ; best starts at -1, so compare signed:
    jle .rs_next_try              ; any real distance beats "none yet"
    mov [rsp + RS_BEST_D], r15d
    mov [rsp + RS_BEST_X], r13d
    mov [rsp + RS_BEST_Y], r14d
.rs_next_try:
    dec r12d
    jnz .rs_try

    xor eax, eax
    cmp dword [rsp + RS_BEST_D], -1
    je .rs_ret                    ; every spot was blocked

    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [rsp + RS_BEST_X]
    mov [r10 + Soldier.x], eax
    mov eax, [rsp + RS_BEST_Y]
    mov [r10 + Soldier.y], eax
    mov dword [r10 + Soldier.health], 100
    mov dword [r10 + Soldier.weapon], WEAPON_KNIFE
    mov dword [r10 + Soldier.state], STATE_SEEK_ENEMY
    mov dword [r10 + Soldier.target], -1
    mov dword [r10 + Soldier.cooldown], 0
    mov dword [r10 + Soldier.avoid_dir], 0
    lea rcx, [protect_timer]
    mov dword [rcx + rbx*4], PROTECT_TICKS
    lea rcx, [death_linger]       ; drawing state: don't draw the old body
    mov dword [rcx + rbx*4], 0
    lea rcx, [hit_flash]
    mov dword [rcx + rbx*4], 0
    mov eax, 1
.rs_ret:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
