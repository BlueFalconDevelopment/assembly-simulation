; weapons.asm -- your guns, the bat and grenades (10.16)
;
; What you carry is a player weapon, PW_*: the pistol and the shotgun
; as before, and now the SMG, the rifle, grenades and a bat, each bought
; in the shop (its GUNS page). A table, pgun, says how each one fires --
; range, hit chance, damage, ticks between shots, and how it looks (the
; soldier weapon your sprite holds, and its attack effect). player_fire
; reads it; the shotgun's close-range blast and the bat's no-ammo swing
; are the only special cases. Q takes the next weapon you have: with
; ammo, or the bat.
;
; Grenades are thrown, not fired: at your lock, or the cursor, at most
; GRENADE_RANGE away. One flies in an arc for a tick per NADE_PACE px,
; then blows up: everyone within BLAST_RADIUS -- you too, at
; BLAST_SELF_PCT%, and the Bikers as well as the gangs -- takes
; BLAST_DAMAGE at the middle down to BLAST_EDGE at the edge (a gangster
; within about 64 px of it dies), and the ground's scorched. Kills of
; your enemies count as yours.
;
; Only in a shift, in a window; your RNG. Watch mode never gets here.

PW_PISTOL   equ WEAPON_PISTOL     ; 1
PW_SHOTGUN  equ WEAPON_SHOTGUN    ; 2
PW_SMG      equ 3
PW_RIFLE    equ 4
PW_GRENADE  equ 5
PW_BAT      equ 6
PW_COUNT    equ 6

SMG_PER_LEVEL     equ 60        ; rounds a life
RIFLE_PER_LEVEL   equ 10
NADES_PER_LEVEL   equ 2
GRENADE_RANGE     equ 260
GRENADE_COOLDOWN  equ 40
NADE_PACE         equ 5         ; px a tick in the air
NADE_MIN_TICKS    equ 20
NADE_HEIGHT       equ 24        ; px at the top of the arc
BLAST_RADIUS      equ 90        ; (the play test: "a little more devastating";
BLAST_DAMAGE      equ 250       ; was 70 px, 150 to 10) at the middle ...
BLAST_EDGE        equ 40        ; ... and at the edge
BLAST_SELF_PCT    equ 50        ; what your own grenade does to you, %
BOOM_TICKS        equ 16
MAX_NADES         equ 4
BAT_RANGE         equ 30        ; centre to centre

struc PGun
    .range: resd 1              ; px
    .hit:   resd 1              ; %
    .dmg:   resd 1
    .cd:    resd 1              ; ticks between shots
    .looks: resd 1              ; the soldier weapon it looks like (sprite, effect)
endstruc

struc Nade
    .sx:  resd 1                ; thrown from (a centre)
    .sy:  resd 1
    .tx:  resd 1                ; ... to
    .ty:  resd 1
    .t:   resd 1                ; ticks in the air
    .T:   resd 1                ; ... until it lands; 0: no grenade
    .boom: resd 1               ; ticks since it blew (drawing): 0 none
    .pad: resd 1
endstruc

section .data
    ; by weapon, PW_PISTOL first. The pistol's damage and rate are the
    ; shop's (apply_gear writes them)
    pgun:
    istruc PGun
        at PGun.range, dd PISTOL_RANGE
        at PGun.hit,   dd PLAYER_HIT
        at PGun.dmg,   dd PLAYER_DAMAGE
        at PGun.cd,    dd PLAYER_COOLDOWN
        at PGun.looks, dd WEAPON_PISTOL
    iend
    istruc PGun                 ; the shotgun: far figures (close: player_fire)
        at PGun.range, dd SHOTGUN_RANGE
        at PGun.hit,   dd PLAYER_SG_FAR_HIT
        at PGun.dmg,   dd PLAYER_SG_FAR_DMG
        at PGun.cd,    dd PLAYER_SG_COOLDOWN
        at PGun.looks, dd WEAPON_SHOTGUN
    iend
    istruc PGun                 ; the SMG: fast, light
        at PGun.range, dd 280
        at PGun.hit,   dd 70
        at PGun.dmg,   dd 22
        at PGun.cd,    dd 5
        at PGun.looks, dd WEAPON_PISTOL
    iend
    istruc PGun                 ; the rifle: slow, far, one shot drops them
        at PGun.range, dd 600
        at PGun.hit,   dd 90
        at PGun.dmg,   dd 120
        at PGun.cd,    dd 45
        at PGun.looks, dd WEAPON_SHOTGUN
    iend
    istruc PGun                 ; grenades (thrown: player_throw)
        at PGun.range, dd GRENADE_RANGE
        at PGun.hit,   dd 100
        at PGun.dmg,   dd BLAST_DAMAGE
        at PGun.cd,    dd GRENADE_COOLDOWN
        at PGun.looks, dd WEAPON_PISTOL
    iend
    istruc PGun                 ; the bat: up close, no ammo
        at PGun.range, dd BAT_RANGE
        at PGun.hit,   dd 95
        at PGun.dmg,   dd 60
        at PGun.cd,    dd 30
        at PGun.looks, dd WEAPON_KNIFE
    iend
    times -(($ - pgun) / PGun_size != PW_COUNT) db 0   ; (a build check)

    ; the scoreboard's names, 10 bytes each
    pw_names db "   PISTOL "
             db "  SHOTGUN "
             db "      SMG "
             db "    RIFLE "
             db " GRENADES "
             db "      BAT "
    ; what a life starts with (apply_gear)
    player_smg     dd 0
    player_rifle   dd 0
    player_nades   dd 0
    player_bat     dd 0
    nades          times MAX_NADES * Nade_size db 0
    COLOR_NADE     equ 0xFF1E3C28
    COLOR_SHADOW_DOT equ 0xFF303030
    COLOR_BOOM1    equ 0xFF50F0FF       ; hot yellow
    COLOR_BOOM2    equ 0xFF1E8CFF       ; orange
    COLOR_BOOM3    equ 0xFF28283C       ; smoke

section .text

; the PGun row of weapon %1 (a register, 1..) -> rax
%macro PGUN_AT 1
    lea eax, [%1 - 1]
    imul eax, eax, PGun_size
    lea rcx, [pgun]
    add rax, rcx
%endmacro


; void player_arm(weapon: edi) -- take it in hand: its look on your
; sprite. A leaf
player_arm:
    mov [player_weapon], edi
    PGUN_AT edi
    mov eax, [rax + PGun.looks]
    mov [soldiers + PLAYER * Soldier_size + Soldier.weapon], eax
    ret


; void player_swap(void) -- Q (pressed, not held): the next weapon you
; have, round the list. And an empty one swaps itself the same way
player_swap:
    sub rsp, 8
    mov r8, [key_state]
    movzx eax, byte [r8 + SCANCODE_Q]
    mov ecx, [q_prev]
    mov [q_prev], eax
    mov edx, [player_weapon]
    test eax, eax
    jz .pw_empty
    test ecx, ecx
    jz .pw_next                   ; pressed
.pw_empty:
    lea rcx, [player_ammo]
    cmp dword [rcx + rdx*4 - 4], 0
    jg .pw_done                   ; loaded: keep it
.pw_next:
    mov ecx, PW_COUNT - 1         ; every other one, in turn
.pw_try:
    inc edx
    cmp edx, PW_COUNT
    jbe .pw_in
    mov edx, 1
.pw_in:
    lea rax, [player_ammo]
    cmp dword [rax + rdx*4 - 4], 0
    jg .pw_take
    dec ecx
    jnz .pw_try
    jmp .pw_done                  ; nothing else
.pw_take:
    mov edi, edx
    call player_arm
.pw_done:
    add rsp, 8
    ret


; void player_loadout(void) -- a new life's weapons (player_spawn): the
; pistol in hand; the rest as the shop says
player_loadout:
    sub rsp, 8
    lea rcx, [player_ammo]
    mov eax, [player_rounds]
    mov [rcx + (PW_PISTOL - 1) * 4], eax
    mov eax, [player_shells]
    mov [rcx + (PW_SHOTGUN - 1) * 4], eax
    mov eax, [player_smg]
    mov [rcx + (PW_SMG - 1) * 4], eax
    mov eax, [player_rifle]
    mov [rcx + (PW_RIFLE - 1) * 4], eax
    mov eax, [player_nades]
    mov [rcx + (PW_GRENADE - 1) * 4], eax
    mov eax, [player_bat]
    mov [rcx + (PW_BAT - 1) * 4], eax     ; (1: yours; never spent)
    mov edi, PW_PISTOL
    call player_arm
    add rsp, 8
    ret


; append_weapon(dst: rdi) -> rdi: "   RIFLE 10" (the bat: no count)
append_weapon:
    mov eax, [player_weapon]
    lea esi, [eax - 1]
    imul esi, esi, 10
    lea rcx, [pw_names]
    add rsi, rcx
    ; the name, without its leading spaces beyond three
    mov edx, 10
.aw_trim:
    cmp byte [rsi + 3], ' '
    jne .aw_have
    inc rsi
    dec edx
    jmp .aw_trim
.aw_have:
    push rax
    call append_bytes
    pop rax
    cmp eax, PW_BAT
    je .aw_done
    lea rcx, [player_ammo]
    mov esi, [rcx + rax*4 - 4]
    jmp append_uint
.aw_done:
    ret


; void player_throw(void) -- a grenade: at your lock, else the cursor,
; no further than GRENADE_RANGE; into a free slot (all four in the air:
; nothing)
;   rbx the slot   r12d/r13d from   r14d/r15d to
player_throw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor ecx, ecx
.pt_slot:
    cmp ecx, MAX_NADES
    jae .pt_done
    imul eax, ecx, Nade_size
    lea rbx, [nades]
    add rbx, rax
    cmp dword [rbx + Nade.T], 0
    jne .pt_next
    cmp dword [rbx + Nade.boom], 0
    je .pt_have
.pt_next:
    inc ecx
    jmp .pt_slot
.pt_have:
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov r12d, [r10 + Soldier.x]
    add r12d, SOLDIER_SIZE / 2
    mov r13d, [r10 + Soldier.y]
    add r13d, SOLDIER_SIZE / 2
    mov r14d, [aim_x]
    mov r15d, [aim_y]
    mov eax, [lock_target]
    cmp eax, -1
    je .pt_aimed
    imul eax, eax, Soldier_size
    lea rcx, [soldiers]
    mov r14d, [rcx + rax + Soldier.x]
    add r14d, SOLDIER_SIZE / 2
    mov r15d, [rcx + rax + Soldier.y]
    add r15d, SOLDIER_SIZE / 2
.pt_aimed:
    ; how far: clamp to GRENADE_RANGE (scaled along the line)
    mov eax, r14d
    sub eax, r12d
    imul eax, eax
    mov ecx, r15d
    sub ecx, r13d
    imul ecx, ecx
    add eax, ecx
    cvtsi2sd xmm0, eax
    sqrtsd xmm0, xmm0
    cvttsd2si eax, xmm0           ; the distance
    cmp eax, GRENADE_RANGE
    jle .pt_near
    ; to = from + (to - from) * RANGE / d
    mov ecx, eax
    mov eax, r14d
    sub eax, r12d
    imul eax, eax, GRENADE_RANGE
    cdq
    idiv ecx
    lea r14d, [r12d + eax]
    mov eax, r15d
    sub eax, r13d
    imul eax, eax, GRENADE_RANGE
    cdq
    idiv ecx
    lea r15d, [r13d + eax]
    mov eax, GRENADE_RANGE
.pt_near:
    xor edx, edx
    mov ecx, NADE_PACE
    div ecx
    cmp eax, NADE_MIN_TICKS
    jge .pt_ticks
    mov eax, NADE_MIN_TICKS
.pt_ticks:
    mov [rbx + Nade.T], eax
    mov dword [rbx + Nade.t], 0
    mov [rbx + Nade.sx], r12d
    mov [rbx + Nade.sy], r13d
    mov [rbx + Nade.tx], r14d
    mov [rbx + Nade.ty], r15d
    lea rcx, [player_ammo]
    dec dword [rcx + (PW_GRENADE - 1) * 4]
    mov dword [soldiers + PLAYER * Soldier_size + Soldier.cooldown], GRENADE_COOLDOWN
.pt_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void update_nades(void) -- once a tick, in a shift: grenades fly and
; land; blasts age (for the drawing)
;   rbx the slot   r12d its index
update_nades:
    push rbx
    push r12
    sub rsp, 8
    xor r12d, r12d
.un_slot:
    cmp r12d, MAX_NADES
    jae .un_done
    imul eax, r12d, Nade_size
    lea rbx, [nades]
    add rbx, rax
    cmp dword [rbx + Nade.boom], 0
    je .un_flying
    inc dword [rbx + Nade.boom]
    cmp dword [rbx + Nade.boom], BOOM_TICKS
    jbe .un_next
    mov dword [rbx + Nade.boom], 0
    jmp .un_next
.un_flying:
    cmp dword [rbx + Nade.T], 0
    je .un_next
    inc dword [rbx + Nade.t]
    mov eax, [rbx + Nade.t]
    cmp eax, [rbx + Nade.T]
    jb .un_next
    mov dword [rbx + Nade.T], 0
    mov dword [rbx + Nade.boom], 1
    mov edi, [rbx + Nade.tx]
    mov esi, [rbx + Nade.ty]
    call nade_blast
.un_next:
    inc r12d
    jmp .un_slot
.un_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void nade_blast(x: edi, y: esi) -- everyone alive within BLAST_RADIUS
; of (x, y), centre to centre: BLAST_DAMAGE at the middle, down to
; BLAST_EDGE at the edge; you, BLAST_SELF_PCT% of that (event_damage:
; spawn protection and armor hold). Enemies of yours it kills count as
; yours. And a scorch on the ground
;   ebx soldier   r12d/r13d the blast   r14 his row
nade_blast:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    xor ebx, ebx
.nb_soldier:
    cmp ebx, TOTAL_SOLDIERS
    jae .nb_scorch
    imul eax, ebx, Soldier_size
    lea r14, [soldiers]
    add r14, rax
    cmp dword [r14 + Soldier.health], 0
    jle .nb_next
    mov eax, [r14 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    sub eax, r12d
    imul eax, eax
    mov ecx, [r14 + Soldier.y]
    add ecx, SOLDIER_SIZE / 2
    sub ecx, r13d
    imul ecx, ecx
    add eax, ecx
    cmp eax, BLAST_RADIUS * BLAST_RADIUS
    jge .nb_next
    cvtsi2sd xmm0, eax
    sqrtsd xmm0, xmm0
    cvttsd2si eax, xmm0
    ; damage: EDGE + (DAMAGE - EDGE) * (R - d) / R
    mov ecx, BLAST_RADIUS
    sub ecx, eax
    imul ecx, ecx, BLAST_DAMAGE - BLAST_EDGE
    mov eax, ecx
    xor edx, edx
    mov ecx, BLAST_RADIUS
    div ecx
    lea esi, [eax + BLAST_EDGE]
    cmp ebx, PLAYER
    jne .nb_hit
    imul esi, esi, BLAST_SELF_PCT ; yours: you knew it was coming
    mov eax, esi
    xor edx, edx
    mov ecx, 100
    div ecx
    mov esi, eax
.nb_hit:
    mov r15d, [r14 + Soldier.team]  ; (before he's hit)
    mov edi, ebx
    call event_damage
    test eax, eax
    jz .nb_next
    cmp ebx, PLAYER
    je .nb_next
    mov eax, FACTION_PLAYER
    HOSTILE rax, rax, r15
    jz .nb_next
    inc dword [score + FACTION_PLAYER * 4]
    inc dword [player_kills]
.nb_next:
    inc ebx
    jmp .nb_soldier
.nb_scorch:
    ; the ground: darkened, 60% of the blast's radius
    mov edi, r12d
    mov esi, r13d
    call scorch
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void scorch(x: edi, y: esi) -- a dark round mark in bg_buffer, there
; for the rest of the game (drawing only). A leaf
SCORCH_R equ BLAST_RADIUS * 6 / 10
scorch:
    push rbx
    mov r8d, -SCORCH_R            ; dy
.sc_row:
    cmp r8d, SCORCH_R
    jg .sc_done
    lea r10d, [esi + r8d]
    cmp r10d, WORLD_H
    jae .sc_next_row
    mov r9d, -SCORCH_R            ; dx
.sc_col:
    cmp r9d, SCORCH_R
    jg .sc_next_row
    mov eax, r9d
    imul eax, eax
    mov ecx, r8d
    imul ecx, ecx
    add eax, ecx
    cmp eax, SCORCH_R * SCORCH_R
    jg .sc_next_col
    lea r11d, [edi + r9d]
    cmp r11d, WORLD_W
    jae .sc_next_col
    imul eax, r10d, WORLD_W
    add eax, r11d
    lea rbx, [bg_buffer]
    mov ecx, [rbx + rax*4]
    shr ecx, 1
    and ecx, 0x7F7F7F             ; half as bright
    or ecx, 0xFF000000
    mov [rbx + rax*4], ecx
.sc_next_col:
    inc r9d
    jmp .sc_col
.sc_next_row:
    inc r8d
    jmp .sc_row
.sc_done:
    pop rbx
    ret


; void draw_nades(void) -- grenades in the air (a dark dot over its
; shadow, high in the middle of the arc) and blasts (a fireball that
; grows, then goes orange, then smoke). Drawing only
;   rbx the slot   r12d index   r13d/r14d where
draw_nades:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r12d, r12d
.dn_slot:
    cmp r12d, MAX_NADES
    jae .dn_done
    imul eax, r12d, Nade_size
    lea rbx, [nades]
    add rbx, rax
    cmp dword [rbx + Nade.boom], 0
    jne .dn_boom
    cmp dword [rbx + Nade.T], 0
    je .dn_next
    ; where: from + (to - from) * t / T
    mov eax, [rbx + Nade.tx]
    sub eax, [rbx + Nade.sx]
    imul eax, [rbx + Nade.t]
    cdq
    idiv dword [rbx + Nade.T]
    add eax, [rbx + Nade.sx]
    mov r13d, eax
    mov eax, [rbx + Nade.ty]
    sub eax, [rbx + Nade.sy]
    imul eax, [rbx + Nade.t]
    cdq
    idiv dword [rbx + Nade.T]
    add eax, [rbx + Nade.sy]
    mov r14d, eax
    ; the shadow
    lea rdi, [back_fb]
    lea esi, [r13d - 2]
    lea edx, [r14d - 1]
    mov ecx, 4
    mov r8d, 2
    mov r9d, COLOR_SHADOW_DOT
    call fill_rect
    ; up: 4 * H * t * (T - t) / T^2
    mov eax, [rbx + Nade.T]
    sub eax, [rbx + Nade.t]
    imul eax, [rbx + Nade.t]
    imul eax, eax, 4 * NADE_HEIGHT
    mov ecx, [rbx + Nade.T]
    imul ecx, ecx
    cdq
    idiv ecx
    lea rdi, [back_fb]
    lea esi, [r13d - 2]
    mov edx, r14d
    sub edx, eax
    sub edx, 2
    mov ecx, 4
    mov r8d, 4
    mov r9d, COLOR_NADE
    call fill_rect
    jmp .dn_next
.dn_boom:
    ; a disc: grows to the blast's radius over the first third, then
    ; holds, going orange (with a yellow core), then smoke that shrinks
    ; away
    mov eax, [rbx + Nade.boom]
    imul eax, eax, BLAST_RADIUS * 3
    xor edx, edx
    mov ecx, BOOM_TICKS
    div ecx
    cmp eax, BLAST_RADIUS
    jbe .dn_r
    mov eax, BLAST_RADIUS
.dn_r:
    ; the last third, smoke: shrinking away
    mov ecx, [rbx + Nade.boom]
    cmp ecx, BOOM_TICKS * 2 / 3
    jbe .dn_r_have
    mov eax, BOOM_TICKS
    sub eax, ecx
    imul eax, eax, BLAST_RADIUS * 3
    xor edx, edx
    mov ecx, BOOM_TICKS
    div ecx
.dn_r_have:
    mov r15d, eax                 ; radius
    mov r9d, COLOR_BOOM1
    mov eax, [rbx + Nade.boom]
    cmp eax, BOOM_TICKS / 3
    jbe .dn_colour
    mov r9d, COLOR_BOOM2
    cmp eax, BOOM_TICKS * 2 / 3
    jbe .dn_colour
    mov r9d, COLOR_BOOM3
.dn_colour:
    mov edi, [rbx + Nade.tx]
    mov esi, [rbx + Nade.ty]
    mov edx, r15d
    mov ecx, r9d
    call fill_disc
    ; still burning: a hot core, half as wide
    cmp dword [rbx + Nade.boom], BOOM_TICKS * 2 / 3
    ja .dn_next
    mov edi, [rbx + Nade.tx]
    mov esi, [rbx + Nade.ty]
    mov edx, r15d
    shr edx, 1
    mov ecx, COLOR_BOOM1
    call fill_disc
.dn_next:
    inc r12d
    jmp .dn_slot
.dn_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void fill_disc(cx: edi, cy: esi, r: edx, colour: ecx) -- a filled
; circle on the view, in map coordinates, row by row (drawing only)
;   r12d dy   r13d the row's half width   r14d/r15d the centre   ebx r
fill_disc:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r14d, edi
    mov r15d, esi
    mov ebx, edx
    mov [rsp], ecx
    mov r12d, ebx
    neg r12d
.fd_row:
    cmp r12d, ebx
    jg .fd_done
    ; half width: sqrt(r^2 - dy^2)
    mov eax, ebx
    imul eax, eax
    mov ecx, r12d
    imul ecx, ecx
    sub eax, ecx
    cvtsi2sd xmm0, eax
    sqrtsd xmm0, xmm0
    cvttsd2si r13d, xmm0
    lea rdi, [back_fb]
    mov esi, r14d
    sub esi, r13d
    lea edx, [r15d + r12d]
    lea ecx, [r13d * 2 + 1]
    mov r8d, 1
    mov r9d, [rsp]
    call fill_rect
    inc r12d
    jmp .fd_row
.fd_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
