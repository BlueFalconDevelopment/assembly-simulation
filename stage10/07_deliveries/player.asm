; player.asm -- you, on foot (10.05)
;
; The player is a soldier: the slot after the two Big Homies (PLAYER),
; in its own faction (FACTION_PLAYER), which the gangs fight and which
; fights them (the hostility table). So the rest of the game handles
; you for free: gangs pick you as a target (find_nearest_enemy), their
; flow fields lead to you (you're a source for every faction hostile to
; you), their shots hit you if you're first in the line of fire, you
; collide like a soldier, you're drawn and shadowed like one, the
; police arrest you and the loose dog bites you. What's different:
;
;   - update_soldiers skips you: your moves come from the keyboard and
;     the mouse, here, once a tick, before the soldiers move
;   - you're only there in game mode, in a window (player_on). In
;     watch mode, or headless, your slot is never alive, so the game
;     is byte for byte what it was
;   - no generic respawn (your lives_left is 0), and you drop no gun
;     when you die: PLAYER_RESPAWN_TICKS later you're back, somewhere
;     safe, with a fresh pistol
;   - your own RNG (player_rng): nothing you do moves the soldiers'
;     random numbers, which keeps replays and batch results meaning
;     what they meant
;
; Controls (10.05, after the first play test):
;   W A S D    walk (sliding along walls); the camera follows you
;   right-click  lock onto the enemy nearest the cursor (within
;              LOCK_RADIUS); yellow brackets mark him. Right-click
;              nobody to unlock. The lock breaks when he dies or gets
;              LOCK_KEEP away
;   left button  fire: at the lock (only when he's in range and in
;              sight: no ammo wasted), else at the enemy nearest the
;              cursor (within AIM_RADIUS), else a miss toward the
;              cursor. Whoever is first in the line of fire takes it
;   Q          swap pistol and shotgun (an empty gun swaps itself)
;   walk over a gun on the ground: take its ammo
;   wheel      zoom (game mode starts at 2x)
;
; You're tougher than a gang member (PLAYER_HEALTH, PLAYER_HIT,
; PLAYER_DAMAGE, faster fire) and heal when left alone a while. And
; they only come after you up close (PLAYER_AGGRO, find_nearest_enemy):
; you're not a source of their flow fields, so gangs across the map
; don't converge on you. Stray bullets are another matter.

section .text

; u32 player_rand(int n: edi) -> eax in [0, n): the player's own
; xorshift64 (seeded in player_start), not the game's rng_state
player_rand:
    mov rax, [player_rng]
    mov rcx, rax
    shl rcx, 13
    xor rax, rcx
    mov rcx, rax
    shr rcx, 7
    xor rax, rcx
    mov rcx, rax
    shl rcx, 17
    xor rax, rcx
    mov [player_rng], rax
    shr rax, 32                   ; the high half: the best bits
    xor edx, edx
    div edi
    mov eax, edx
    ret


; void player_start(void) -- once, when the window opens, in game mode
player_start:
    sub rsp, 8
    cmp dword [game_mode], 0
    je .ps_done
    mov dword [player_on], 1
    ; the player's RNG: the game's seed, scrambled, never 0
    mov rax, [game_seed]
    mov rcx, 0x9E3779B97F4A7C15
    xor rax, rcx
    jnz .ps_seeded
    mov rax, rcx
.ps_seeded:
    mov [player_rng], rax
    ; start zoomed in 2x (at 1x you're 16 px on a 1280 px screen); the
    ; wheel still changes it
    mov dword [zoom_step], PLAYER_ZOOM
    lea rcx, [zoom_view_w]
    mov eax, [rcx + PLAYER_ZOOM * 4]
    mov [cam_src + 8], eax
    imul eax, eax, SCREEN_H
    xor edx, edx
    mov ecx, SCREEN_W
    div ecx
    mov [cam_src + 12], eax
    call player_spawn
    call make_offers              ; the job board (10.07)
.ps_done:
    add rsp, 8
    ret


; void player_spawn(void) -- somewhere safe: a walkable cell, outside
; every site (closed ones are walled-in pockets), at least
; PLAYER_SAFE_HOME from both homes' lobbies and PLAYER_SAFE_ENEMY from
; every living soldier. A fresh pistol, full health, spawn protection.
; (The depot comes with deliveries, 10.07.)
;   ebx x   r12d y   r13d tries left
player_spawn:
    push rbx
    push r12
    push r13
    mov r13d, 2000
.psp_try:
    dec r13d
    jz .psp_take                  ; (it always finds one long before)
    ; (at least PLAYER_EDGE in from the map's edges: past the four
    ; boundary roads there's only a strip of grass)
    mov edi, WORLD_W - SOLDIER_SIZE - 2 * PLAYER_EDGE
    call player_rand
    lea ebx, [eax + PLAYER_EDGE]
    mov edi, WORLD_H - SOLDIER_SIZE - 2 * PLAYER_EDGE
    call player_rand
    lea r12d, [eax + PLAYER_EDGE]
    ; a walkable cell
    mov eax, r12d
    CELL_OF eax
    imul eax, eax, GRID_W
    mov r8d, eax
    mov eax, ebx
    CELL_OF eax
    add eax, r8d
    lea rcx, [walkable]
    cmp byte [rcx + rax], 0
    je .psp_try
    ; outside every site
    lea rcx, [site_rects]
    xor edx, edx
.psp_site:
    mov eax, [rcx]
    sub eax, SOLDIER_SIZE
    cmp ebx, eax
    jl .psp_site_next
    add eax, [rcx + 8]
    add eax, SOLDIER_SIZE
    cmp ebx, eax
    jg .psp_site_next
    mov eax, [rcx + 4]
    sub eax, SOLDIER_SIZE
    cmp r12d, eax
    jl .psp_site_next
    add eax, [rcx + 12]
    add eax, SOLDIER_SIZE
    cmp r12d, eax
    jle .psp_try                  ; inside this one
.psp_site_next:
    add rcx, 16
    inc edx
    cmp edx, NUM_SITES
    jb .psp_site
    ; far from both homes' lobbies
    xor edx, edx
.psp_home:
    mov eax, [home + rdx*4]
    shl eax, 4
    lea rcx, [site_lobbies]
    mov r8d, [rcx + rax]
    mov r9d, [rcx + rax + 8]
    shr r9d, 1
    add r8d, r9d                  ; its centre x
    mov r9d, [rcx + rax + 4]
    mov r10d, [rcx + rax + 12]
    shr r10d, 1
    add r9d, r10d                 ; its centre y
    sub r8d, ebx
    imul r8d, r8d
    sub r9d, r12d
    imul r9d, r9d
    add r8d, r9d
    cmp r8d, PLAYER_SAFE_HOME * PLAYER_SAFE_HOME
    jl .psp_try
    inc edx
    cmp edx, NUM_GANGS
    jb .psp_home
    ; far from everyone alive
    lea rcx, [soldiers]
    xor edx, edx
.psp_soldier:
    cmp edx, PLAYER
    je .psp_soldier_next
    cmp dword [rcx + Soldier.health], 0
    jle .psp_soldier_next
    mov r8d, [rcx + Soldier.x]
    sub r8d, ebx
    imul r8d, r8d
    mov r9d, [rcx + Soldier.y]
    sub r9d, r12d
    imul r9d, r9d
    add r8d, r9d
    cmp r8d, PLAYER_SAFE_ENEMY * PLAYER_SAFE_ENEMY
    jl .psp_try
.psp_soldier_next:
    add rcx, Soldier_size
    inc edx
    cmp edx, TOTAL_SOLDIERS
    jb .psp_soldier
    ; and the box itself clear (the cell test is strict, but be sure)
    mov edi, PLAYER
    mov esi, ebx
    mov edx, r12d
    call is_spot_blocked
    test eax, eax
    jnz .psp_try
.psp_take:
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov [r10 + Soldier.x], ebx
    mov [r10 + Soldier.y], r12d
    mov dword [r10 + Soldier.health], PLAYER_HEALTH
    mov dword [r10 + Soldier.weapon], WEAPON_PISTOL
    mov dword [r10 + Soldier.cooldown], 0
    mov dword [r10 + Soldier.team], FACTION_PLAYER
    mov dword [player_weapon], WEAPON_PISTOL
    mov dword [player_ammo], PLAYER_AMMO
    mov dword [player_ammo + 4], 0
    mov dword [player_dead], 0
    mov dword [player_hp_was], PLAYER_HEALTH
    mov dword [player_calm], 0
    mov dword [lock_target], -1
    lea rcx, [protect_timer]
    mov dword [rcx + PLAYER * 4], PROTECT_TICKS
    lea rcx, [sprite_seen]
    mov dword [rcx + PLAYER * 4], 0   ; a new place: don't "walk" there
    call vehicle_spawn            ; ... on a new bike (10.06)
    pop r13
    pop r12
    pop rbx
    ret


; void mouse_world(void) -- the cursor, in map pixels, into aim_x/aim_y
; (and the buttons into mouse_buttons). The field fills the window
; above the scoreboard, and shows the camera's view.
mouse_world:
    sub rsp, 8
    lea rdi, [mouse_x]
    lea rsi, [mouse_y]
    call SDL_GetMouseState
    mov [mouse_buttons], eax
    mov eax, [mouse_x]
    CLAMP_TO eax, SCREEN_W - 1
    imul eax, [cam_src + 8]
    xor edx, edx
    mov ecx, SCREEN_W
    div ecx
    add eax, [cam_src]
    mov [aim_x], eax
    mov eax, [mouse_y]
    CLAMP_TO eax, SCREEN_H - 1
    imul eax, [cam_src + 12]
    xor edx, edx
    mov ecx, SCREEN_H
    div ecx
    add eax, [cam_src + 4]
    mov [aim_y], eax
    add rsp, 8
    ret


; void update_player(void) -- once a tick in a window, before the
; soldiers move. Dead: count down to a respawn. Alive: lock on, swap,
; walk, pick up, heal, shoot.
;   r12 the player's Soldier   ebx, r13d the step
update_player:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [player_on], 0
    je .up_ret
    lea r12, [soldiers + PLAYER * Soldier_size]
    call mouse_world
    call update_jobs              ; the delivery (10.07)
    ; ---- dead? ----
    cmp dword [r12 + Soldier.health], 0
    jg .up_alive
    mov dword [lock_target], -1
    mov dword [riding], 0         ; the bike stays where you fell (10.06)
    cmp dword [player_dead], 0
    jne .up_counting
    mov dword [player_dead], 1
    mov dword [player_timer], PLAYER_RESPAWN_TICKS
    inc dword [player_deaths]
.up_counting:
    dec dword [player_timer]
    jg .up_ret
    call player_spawn
    jmp .up_ret
.up_alive:
    cmp dword [r12 + Soldier.cooldown], 0
    jle .up_cooled
    dec dword [r12 + Soldier.cooldown]
.up_cooled:
    call player_lock
    call player_swap
    call vehicle_mount            ; E: on or off (10.06)
    cmp dword [riding], 0
    je .up_walk
    call vehicle_ride             ; riding: the vehicle moves you
    jmp .up_walked
.up_walk:
    ; ---- walk: x then y, each on its own, so walls slide past ----
    mov r8, [key_state]
    xor ebx, ebx
    cmp byte [r8 + SCANCODE_A], 0
    je .up_no_a
    sub ebx, PLAYER_SPEED
.up_no_a:
    cmp byte [r8 + SCANCODE_D], 0
    je .up_no_d
    add ebx, PLAYER_SPEED
.up_no_d:
    xor r13d, r13d
    cmp byte [r8 + SCANCODE_W], 0
    je .up_no_w
    sub r13d, PLAYER_SPEED
.up_no_w:
    cmp byte [r8 + SCANCODE_S], 0
    je .up_no_s
    add r13d, PLAYER_SPEED
.up_no_s:
    test ebx, ebx
    jz .up_y
    mov esi, [r12 + Soldier.x]
    add esi, ebx
    CLAMP_TO esi, WORLD_W - SOLDIER_SIZE
    mov r14d, esi
    mov edi, PLAYER
    mov edx, [r12 + Soldier.y]
    call is_spot_blocked
    test eax, eax
    jnz .up_y
    mov [r12 + Soldier.x], r14d
.up_y:
    test r13d, r13d
    jz .up_walked
    mov edx, [r12 + Soldier.y]
    add edx, r13d
    CLAMP_TO edx, WORLD_H - SOLDIER_SIZE
    mov r14d, edx
    mov edi, PLAYER
    mov esi, [r12 + Soldier.x]
    call is_spot_blocked
    test eax, eax
    jnz .up_walked
    mov [r12 + Soldier.y], r14d
.up_walked:
    call player_pickups
    ; ---- heal: REGEN_DELAY ticks unhurt, then a point every REGEN_EVERY ----
    mov eax, [r12 + Soldier.health]
    cmp eax, [player_hp_was]
    jge .up_not_hurt
    mov dword [player_calm], 0
.up_not_hurt:
    inc dword [player_calm]
    cmp dword [player_calm], REGEN_DELAY
    jl .up_healed
    mov eax, [player_calm]
    xor edx, edx
    mov ecx, REGEN_EVERY
    div ecx
    test edx, edx
    jnz .up_healed
    cmp dword [r12 + Soldier.health], PLAYER_HEALTH
    jge .up_healed
    inc dword [r12 + Soldier.health]
.up_healed:
    mov eax, [r12 + Soldier.health]
    mov [player_hp_was], eax
    ; ---- shoot: the left button, cooled down, loaded ----
    test dword [mouse_buttons], SDL_BUTTON_LMASK
    jz .up_ret
    cmp dword [r12 + Soldier.cooldown], 0
    jg .up_ret
    mov eax, [player_weapon]
    lea rcx, [player_ammo]
    cmp dword [rcx + rax*4 - 4], 0
    jle .up_ret
    call player_fire
.up_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int enemy_near(int x: edi, int y: esi, int r: edx) -> eax: the living
; enemy (of yours) whose centre is nearest (x, y), within r; or -1
;   r8d best distance^2   r9 a soldier   r10d its index
enemy_near:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov r8d, edx                  ; (imul r8d, edx, edx isn't an
    imul r8d, edx                 ; instruction: NASM took it anyway)
    inc r8d
    mov ebx, -1
    lea r9, [soldiers]
    xor r10d, r10d
.en_scan:
    cmp r10d, PLAYER
    je .en_next
    cmp dword [r9 + Soldier.health], 0
    jle .en_next
    mov eax, FACTION_PLAYER
    mov ecx, [r9 + Soldier.team]
    HOSTILE rax, rax, rcx
    jz .en_next
    mov eax, [r9 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    sub eax, r12d
    imul eax, eax
    mov ecx, [r9 + Soldier.y]
    add ecx, SOLDIER_SIZE / 2
    sub ecx, r13d
    imul ecx, ecx
    add eax, ecx
    cmp eax, r8d
    jae .en_next
    mov r8d, eax
    mov ebx, r10d
.en_next:
    add r9, Soldier_size
    inc r10d
    cmp r10d, TOTAL_SOLDIERS
    jb .en_scan
    mov eax, ebx
    pop r13
    pop r12
    pop rbx
    ret


; void player_lock(void) -- a right click locks onto the enemy nearest
; the cursor, within LOCK_RADIUS (on nobody: unlocks). The lock breaks
; when the target dies, turns out not to be an enemy, or gets farther
; than LOCK_KEEP from you.
player_lock:
    sub rsp, 8
    mov eax, [mouse_buttons]
    and eax, SDL_BUTTON_RMASK
    mov ecx, [rmb_prev]
    mov [rmb_prev], eax
    test eax, eax
    jz .pl_check
    test ecx, ecx
    jnz .pl_check                 ; held, not a new click
    mov edi, [aim_x]
    mov esi, [aim_y]
    mov edx, LOCK_RADIUS
    call enemy_near
    mov [lock_target], eax
.pl_check:
    mov eax, [lock_target]
    cmp eax, -1
    je .pl_done
    imul eax, eax, Soldier_size
    lea r9, [soldiers]
    add r9, rax
    cmp dword [r9 + Soldier.health], 0
    jle .pl_break
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov eax, [r9 + Soldier.x]
    sub eax, [r10 + Soldier.x]
    imul eax, eax
    mov ecx, [r9 + Soldier.y]
    sub ecx, [r10 + Soldier.y]
    imul ecx, ecx
    add eax, ecx
    cmp eax, LOCK_KEEP * LOCK_KEEP
    jbe .pl_done
.pl_break:
    mov dword [lock_target], -1
.pl_done:
    add rsp, 8
    ret


; void player_swap(void) -- Q swaps pistol and shotgun (if the other has
; ammo); an empty gun swaps itself for a loaded one
player_swap:
    mov r8, [key_state]
    movzx eax, byte [r8 + SCANCODE_Q]
    mov ecx, [q_prev]
    mov [q_prev], eax
    lea rdx, [player_ammo]
    mov r9d, [player_weapon]
    test eax, eax
    jz .pw_empty
    test ecx, ecx
    jnz .pw_empty                 ; held
    jmp .pw_other
.pw_empty:
    cmp dword [rdx + r9*4 - 4], 0
    jg .pw_done                   ; loaded: keep it
.pw_other:
    mov eax, WEAPON_PISTOL + WEAPON_SHOTGUN
    sub eax, r9d                  ; the other one
    cmp dword [rdx + rax*4 - 4], 0
    jle .pw_done
    mov [player_weapon], eax
    mov [soldiers + PLAYER * Soldier_size + Soldier.weapon], eax
.pw_done:
    ret


; void player_pickups(void) -- walking over a gun on the ground takes
; its ammo (PICKUP_PISTOL_AMMO rounds or PICKUP_SHOTGUN_AMMO shells;
; the same reach as a soldier's, PICKUP_RADIUS). The empty gun turns up
; again at one of the pair's pickup spots (the player's RNG), so the
; gangs' guns never run short because of you.
;   rbx a Pickup   r12d slot
player_pickups:
    push rbx
    push r12
    push r13
    lea r13, [soldiers + PLAYER * Soldier_size]
    lea rbx, [pickups]
    xor r12d, r12d
.pp_loop:
    cmp dword [rbx + Pickup.active], 0
    je .pp_next
    mov eax, [rbx + Pickup.x]
    sub eax, [r13 + Soldier.x]
    imul eax, eax
    mov ecx, [rbx + Pickup.y]
    sub ecx, [r13 + Soldier.y]
    imul ecx, ecx
    add eax, ecx
    cmp eax, PICKUP_RADIUS * PICKUP_RADIUS
    jg .pp_next
    ; its ammo
    lea rcx, [player_ammo]
    cmp dword [rbx + Pickup.type], WEAPON_SHOTGUN
    je .pp_shells
    add dword [rcx], PICKUP_PISTOL_AMMO
    jmp .pp_moved
.pp_shells:
    add dword [rcx + 4], PICKUP_SHOTGUN_AMMO
.pp_moved:
    ; the gun itself: somewhere else
    mov edi, PICKUPS_PER_PAIR
    call player_rand
    imul eax, eax, 12
    imul ecx, [pair], PICKUPS_PER_PAIR * 12
    add eax, ecx
    lea rcx, [pair_pickups]
    mov edx, [rcx + rax]
    mov [rbx + Pickup.x], edx
    mov edx, [rcx + rax + 4]
    mov [rbx + Pickup.y], edx
    lea rcx, [pickup_age]
    mov dword [rcx + r12*4], 0
.pp_next:
    add rbx, Pickup_size
    inc r12d
    cmp r12d, MAX_PICKUPS
    jb .pp_loop
    pop r13
    pop r12
    pop rbx
    ret


; void player_fire(void) -- one shot. At the lock if there is one (in
; range and in sight, or the button does nothing: no ammo wasted); else
; at the enemy nearest the cursor, within AIM_RADIUS; else a miss, a
; tracer toward the cursor. Whoever is first in the line of fire takes
; it. Pistol: PLAYER_HIT, PLAYER_DAMAGE. Shotgun: SHOTGUN_RANGE, better
; close up.
;   ebx target   r12d hit   r13d damage   r14d range^2   r15 the player
player_fire:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r15, [soldiers + PLAYER * Soldier_size]
    mov r14d, PISTOL_RANGE * PISTOL_RANGE
    cmp dword [player_weapon], WEAPON_SHOTGUN
    jne .pf_range
    mov r14d, SHOTGUN_RANGE * SHOTGUN_RANGE
.pf_range:
    mov ebx, [lock_target]
    cmp ebx, -1
    jne .pf_have_target
    mov edi, [aim_x]
    mov esi, [aim_y]
    mov edx, AIM_RADIUS
    call enemy_near
    mov ebx, eax
    cmp ebx, -1
    je .pf_miss
.pf_have_target:
    ; in range, in sight?
    imul eax, ebx, Soldier_size
    lea r13, [soldiers]
    add r13, rax
    mov eax, [r13 + Soldier.x]
    sub eax, [r15 + Soldier.x]
    imul eax, eax
    mov ecx, [r13 + Soldier.y]
    sub ecx, [r15 + Soldier.y]
    imul ecx, ecx
    add eax, ecx
    mov r12d, eax                 ; (the distance^2, for the shotgun)
    cmp eax, r14d
    ja .pf_out
    mov edi, [r15 + Soldier.x]
    mov esi, [r15 + Soldier.y]
    mov edx, [r13 + Soldier.x]
    mov ecx, [r13 + Soldier.y]
    call sight_blocked
    test eax, eax
    jnz .pf_out
    ; the odds and the damage
    mov r13d, PLAYER_DAMAGE
    mov r14d, PLAYER_HIT
    mov r15d, PLAYER_COOLDOWN
    cmp dword [player_weapon], WEAPON_SHOTGUN
    jne .pf_odds
    mov r13d, PLAYER_SG_FAR_DMG
    mov r14d, PLAYER_SG_FAR_HIT
    mov r15d, PLAYER_SG_COOLDOWN
    cmp r12d, SHOTGUN_CLOSE_RANGE * SHOTGUN_CLOSE_RANGE
    ja .pf_odds
    mov r13d, PLAYER_SG_CLOSE_DMG
    mov r14d, PLAYER_SG_CLOSE_HIT
.pf_odds:
    ; riding: one hand on the bars (10.06)
    cmp dword [riding], 0
    je .pf_steady
    VEH_TYPE
    sub r14d, [rax + VehicleType.aim_penalty]
.pf_steady:
    call pf_spend                 ; a round, and the cooldown (r15d)
    mov edi, PLAYER
    mov esi, ebx
    call first_in_line            ; whoever's first in the line takes it
    mov ebx, eax
    mov edi, 100
    call player_rand
    xor r12d, r12d
    cmp eax, r14d
    jae .pf_rolled
    mov r12d, 1
.pf_rolled:
    mov edi, [player_weapon]
    mov esi, PLAYER
    mov edx, ebx
    mov ecx, r12d
    call spawn_effect
    test r12d, r12d
    jz .pf_done
    mov edi, ebx
    mov esi, r13d
    call event_damage
    test eax, eax
    jz .pf_done
    ; a kill: it counts if it was an enemy
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    mov ecx, [rcx + rax + Soldier.team]
    mov eax, FACTION_PLAYER
    HOSTILE rax, rax, rcx
    jz .pf_done
    inc dword [score + FACTION_PLAYER * 4]
    inc dword [player_kills]
    jmp .pf_done
.pf_out:
    ; out of range or sight: locked on, hold fire; else fire anyway
    cmp dword [lock_target], -1
    jne .pf_done
.pf_miss:
    ; nobody there: a tracer toward the cursor (fx_dst is laid out like
    ; a soldier's corner; spawn_effect aims at its centre)
    mov r15d, PLAYER_COOLDOWN
    cmp dword [player_weapon], WEAPON_SHOTGUN
    jne .pf_miss_cd
    mov r15d, PLAYER_SG_COOLDOWN
.pf_miss_cd:
    call pf_spend
    mov eax, [aim_x]
    sub eax, SOLDIER_SIZE / 2
    mov [fx_dst], eax
    mov eax, [aim_y]
    sub eax, SOLDIER_SIZE / 2
    mov [fx_dst + 4], eax
    mov edi, [player_weapon]
    mov esi, PLAYER
    mov edx, -1
    xor ecx, ecx
    call spawn_effect
.pf_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pf_spend: one round of the weapon in hand, and cooldown r15d
pf_spend:
    mov eax, [player_weapon]
    lea rcx, [player_ammo]
    dec dword [rcx + rax*4 - 4]
    mov [soldiers + PLAYER * Soldier_size + Soldier.cooldown], r15d
    ret


; void draw_lock(void) -- yellow corner brackets round the soldier
; you're locked onto (drawing only)
;   rbx the target
draw_lock:
    push rbx
    push r12
    push r13
    mov eax, [lock_target]
    cmp eax, -1
    je .dl_done
    cmp dword [player_on], 0
    je .dl_done
    imul eax, eax, Soldier_size
    lea rbx, [soldiers]
    add rbx, rax
    mov r12d, [rbx + Soldier.x]
    sub r12d, 3                   ; the box: 3 px round the sprite
    mov r13d, [rbx + Soldier.y]
    sub r13d, 3
    %macro LOCK_BAR 4             ; x offset, y offset, w, h
        lea rdi, [back_fb]
        lea esi, [r12d + %1]
        lea edx, [r13d + %2]
        mov ecx, %3
        mov r8d, %4
        mov r9d, COLOR_LOCK
        call fill_rect
    %endmacro
    LOCK_BAR 0, 0, 6, 2           ; top left
    LOCK_BAR 0, 0, 2, 6
    LOCK_BAR 16, 0, 6, 2          ; top right
    LOCK_BAR 20, 0, 2, 6
    LOCK_BAR 0, 20, 6, 2          ; bottom left
    LOCK_BAR 0, 16, 2, 6
    LOCK_BAR 16, 20, 6, 2         ; bottom right
    LOCK_BAR 20, 16, 2, 6
.dl_done:
    pop r13
    pop r12
    pop rbx
    ret


; void camera_follow(void) -- the view centred on the player (game
; mode, instead of W A S D panning: those keys walk now)
camera_follow:
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov eax, [r10 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    mov ecx, [cam_src + 8]
    shr ecx, 1
    sub eax, ecx
    mov [cam_src], eax
    mov eax, [r10 + Soldier.y]
    add eax, SOLDIER_SIZE / 2
    mov ecx, [cam_src + 12]
    shr ecx, 1
    sub eax, ecx
    mov [cam_src + 4], eax
    jmp camera_clamp
