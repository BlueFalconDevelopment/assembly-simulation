; ai.asm -- targets, weapons, the blockmap, line of sight, update_soldiers, first_in_line
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; void build_title(void)
; title_buf = "Stage 7.13 - Neighborhood", 0-terminated for SDL.
build_title:
    lea rdi, [title_buf]
    lea rsi, [title_prefix]
    mov edx, title_prefix_len
    call append_bytes
    call append_arena_name
    mov byte [rdi], 0
    ret


; append_arena_name(dst: rdi) -> rdi = past the name
append_arena_name:
    lea rsi, [map_name]
    mov edx, map_name_len
    jmp append_bytes


; int find_nearest_enemy(int self_index: edi) -> eax (index, or -1)
FNE_SELF     equ -8
FNE_MY_X     equ -16
FNE_MY_Y     equ -24
FNE_MY_TEAM  equ -32
FNE_BEST_IDX equ -40
FNE_BEST_DIST equ -48
FNE_J        equ -56

find_nearest_enemy:
    push rbp
    mov rbp, rsp
    sub rsp, 64

    mov [rbp + FNE_SELF], edi

    mov eax, edi
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    mov [rbp + FNE_MY_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + FNE_MY_Y], eax
    mov eax, [r10 + Soldier.team]
    mov [rbp + FNE_MY_TEAM], eax

    mov dword [rbp + FNE_BEST_IDX], -1
    mov dword [rbp + FNE_BEST_DIST], 0x7FFFFFFF

    mov dword [rbp + FNE_J], 0
.scan_loop:
    mov eax, [rbp + FNE_J]
    cmp eax, TOTAL_SOLDIERS
    jge .scan_done

    cmp eax, [rbp + FNE_SELF]
    je .scan_next

    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    cmp dword [r10 + Soldier.health], 0
    jle .scan_next

    mov eax, [rbp + FNE_MY_TEAM]
    mov ecx, [r10 + Soldier.team]
    HOSTILE rax, rax, rcx          ; only factions we fight (10.02)
    jz .scan_next

    mov eax, [r10 + Soldier.x]
    sub eax, [rbp + FNE_MY_X]
    imul eax, eax
    mov ecx, eax

    mov eax, [r10 + Soldier.y]
    sub eax, [rbp + FNE_MY_Y]
    imul eax, eax
    add ecx, eax

    cmp ecx, [rbp + FNE_BEST_DIST]
    jge .scan_next
    mov [rbp + FNE_BEST_DIST], ecx
    mov eax, [rbp + FNE_J]
    mov [rbp + FNE_BEST_IDX], eax

.scan_next:
    mov eax, [rbp + FNE_J]
    inc eax
    mov [rbp + FNE_J], eax
    jmp .scan_loop
.scan_done:
    mov eax, [rbp + FNE_BEST_IDX]
    mov rsp, rbp
    pop rbp
    ret


; int find_nearest_pickup(int self_index: edi) -> eax (index, or -1)
FNP_MY_X      equ -8
FNP_MY_Y      equ -16
FNP_BEST_IDX  equ -24
FNP_BEST_DIST equ -32
FNP_J         equ -40

find_nearest_pickup:
    push rbp
    mov rbp, rsp
    sub rsp, 48

    mov eax, edi
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    mov [rbp + FNP_MY_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + FNP_MY_Y], eax

    mov dword [rbp + FNP_BEST_IDX], -1
    mov dword [rbp + FNP_BEST_DIST], 0x7FFFFFFF

    mov dword [rbp + FNP_J], 0
.scan_loop:
    mov eax, [rbp + FNP_J]
    cmp eax, MAX_PICKUPS
    jge .scan_done

    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax

    cmp dword [r10 + Pickup.active], 0
    je .scan_next

    mov eax, [r10 + Pickup.x]
    sub eax, [rbp + FNP_MY_X]
    imul eax, eax
    mov ecx, eax
    mov eax, [r10 + Pickup.y]
    sub eax, [rbp + FNP_MY_Y]
    imul eax, eax
    add ecx, eax

    cmp ecx, [rbp + FNP_BEST_DIST]
    jge .scan_next
    mov [rbp + FNP_BEST_DIST], ecx
    mov eax, [rbp + FNP_J]
    mov [rbp + FNP_BEST_IDX], eax

.scan_next:
    mov eax, [rbp + FNP_J]
    inc eax
    mov [rbp + FNP_J], eax
    jmp .scan_loop
.scan_done:
    mov eax, [rbp + FNP_BEST_IDX]
    mov rsp, rbp
    pop rbp
    ret


; int get_weapon_range_sq(int weapon: edi) -> eax
get_weapon_range_sq:
    cmp edi, WEAPON_KNIFE
    jne .not_knife
    mov eax, CONTACT_RANGE * CONTACT_RANGE
    ret
.not_knife:
    cmp edi, WEAPON_PISTOL
    jne .not_pistol
    mov eax, PISTOL_RANGE * PISTOL_RANGE
    ret
.not_pistol:
    mov eax, SHOTGUN_RANGE * SHOTGUN_RANGE
    ret


; void drop_weapon(int x: edi, int y: esi, int type: edx)
drop_weapon:
    push rbx
    xor ebx, ebx
.dw_loop:
    cmp ebx, MAX_PICKUPS
    jge .dw_done

    mov eax, ebx
    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax
    cmp dword [r10 + Pickup.active], 0
    jne .dw_next

    mov [r10 + Pickup.x], edi
    mov [r10 + Pickup.y], esi
    mov [r10 + Pickup.type], edx
    mov dword [r10 + Pickup.active], 1
    lea r10, [pickup_age]
    mov dword [r10 + rbx*4], 0    ; just dropped (10.04)
    jmp .dw_done
.dw_next:
    inc ebx
    jmp .dw_loop
.dw_done:
    pop rbx
    ret


; void refresh_pickups(void) -- once a tick, before build_fields, in
; game mode only (10.04). In the endless war, the guns of the dead pile
; up where the fighting is, between the two crowds, where nobody lives
; long enough to pick one up: 3,000 ticks in, 69 of the 80 guns were
; lying on the ground there and most of both gangs had knives. So a gun
; that has lain PICKUP_STALE ticks is "picked up by someone else" and
; turns up at one of the pair's pickup spots, at random. It's the same
; gun (the same type): every weapon is still in exactly one place.
;   ebx slot   r12 its Pickup   r13 the table spot
refresh_pickups:
    cmp dword [game_mode], 0
    je .rp_ret
    push rbx
    push r12
    push r13
    xor ebx, ebx
.rp_loop:
    imul eax, ebx, Pickup_size
    lea r12, [pickups]
    add r12, rax
    cmp dword [r12 + Pickup.active], 0
    je .rp_next
    lea rcx, [pickup_age]
    inc dword [rcx + rbx*4]
    cmp dword [rcx + rbx*4], PICKUP_STALE
    jl .rp_next
    mov dword [rcx + rbx*4], 0
    mov edi, PICKUPS_PER_PAIR
    call rand_range
    imul eax, eax, 12
    imul ecx, [pair], PICKUPS_PER_PAIR * 12
    add eax, ecx
    lea r13, [pair_pickups]
    add r13, rax
    mov eax, [r13]
    mov [r12 + Pickup.x], eax
    mov eax, [r13 + 4]
    mov [r12 + Pickup.y], eax
.rp_next:
    inc ebx
    cmp ebx, MAX_PICKUPS
    jb .rp_loop
    pop r13
    pop r12
    pop rbx
.rp_ret:
    ret


; int is_box_blocked(int x: edi, int y: esi) -> eax (1 or 0)
; Could a soldier's box stand with its corner at (x, y)? Not if any of
; it is off the field (see 06's README for why the edges count), and
; not if it overlaps a wall or a prop: one blockmap byte, precomputed
; by build_blockmap. 06-12 looped over every wall here; the
; neighborhood has 54 walls and props, and line_blocked calls this
; for every point on every line.
is_box_blocked:
    mov dword [lb_mask], BLOCK_WALK
; int box_mask_blocked(int x: edi, int y: esi) -> eax: the same test,
; for whichever bit lb_mask holds (line_blocked's sight mode uses it)
box_mask_blocked:
    cmp edi, WORLD_W - SOLDIER_SIZE
    ja .bmb_blocked               ; unsigned: negative x too
    cmp esi, WORLD_H - SOLDIER_SIZE
    ja .bmb_blocked
    imul eax, esi, BM_W
    add eax, edi
    lea rcx, [blockmap]
    movzx eax, byte [rcx + rax]
    and eax, [lb_mask]
    setnz al
    movzx eax, al
    ret
.bmb_blocked:
    mov eax, 1
    ret


; void build_blockmap(void)
; blockmap[y * BM_W + x] gets BLOCK_WALK | BLOCK_SIGHT for every corner
; position whose soldier box would overlap a wall, and BLOCK_WALK for
; every one that would overlap a prop. A box at corner cx overlaps a
; rectangle starting at wx, wx+ww wide, when wx - 15 <= cx <= wx+ww-1,
; so each rectangle just marks a slightly bigger rectangle of bytes.
build_blockmap:
    push rbx
    push r12
    sub rsp, 8
    lea rbx, [map_walls]
    mov r12d, map_walls_count
.bbm_wall:
    mov r8d, BLOCK_WALK | BLOCK_SIGHT
    call mark_rect
    add rbx, 16
    dec r12d
    jnz .bbm_wall
    lea rbx, [map_props]
    mov r12d, map_props_count
.bbm_prop:
    mov r8d, BLOCK_WALK
    call mark_rect
    add rbx, 16
    dec r12d
    jnz .bbm_prop
    ; the sites nobody lives in this game: their doorways are walls
    ; (10.03), so the pathfinding grid never goes in. [rsp]: the site
    mov dword [rsp], 0
.bbm_site:
    mov eax, [rsp]
    cmp eax, [home]
    je .bbm_site_next
    cmp eax, [home + 4]
    je .bbm_site_next
    lea rcx, [site_door_idx]
    mov edx, [rcx + rax*8]
    mov r12d, [rcx + rax*8 + 4]
    shl edx, 4
    lea rbx, [site_doors]
    add rbx, rdx
.bbm_plug:
    mov r8d, BLOCK_WALK | BLOCK_SIGHT
    call mark_rect
    add rbx, 16
    dec r12d
    jnz .bbm_plug
.bbm_site_next:
    inc dword [rsp]
    cmp dword [rsp], NUM_SITES
    jb .bbm_site
    add rsp, 8
    pop r12
    pop rbx
    ret

; mark_rect: OR bits r8b into the blockmap for the rectangle at [rbx]
; (x, y, w, h). Clobbers eax, ecx, edx, esi, edi, r9-r11.
mark_rect:
    mov eax, [rbx]
    sub eax, SOLDIER_SIZE - 1
    CLAMP_TO eax, BM_W - 1
    mov edi, eax                  ; x0
    mov eax, [rbx]
    add eax, [rbx + 8]
    dec eax
    CLAMP_TO eax, BM_W - 1
    mov edx, eax                  ; x1
    mov eax, [rbx + 4]
    sub eax, SOLDIER_SIZE - 1
    CLAMP_TO eax, BM_H - 1
    mov esi, eax                  ; y0
    mov eax, [rbx + 4]
    add eax, [rbx + 12]
    dec eax
    CLAMP_TO eax, BM_H - 1
    mov ecx, eax                  ; y1
    lea r9, [blockmap]
.mr_row:
    cmp esi, ecx
    jg .mr_done
    imul r10d, esi, BM_W
    add r10d, edi
    mov r11d, edx
    sub r11d, edi
.mr_col:
    or [r9 + r10], r8b
    inc r10d
    dec r11d
    jns .mr_col
    inc esi
    jmp .mr_row
.mr_done:
    ret


;
; int is_spot_blocked(int self: edi, int x: esi, int y: edx) -> eax (1 or 0)
;
; Could soldier `self` stand with its box anchored at (x, y)? No if
; is_box_blocked says so (wall or screen edge), and no if the box would
; overlap any OTHER living soldier's box. Two SOLDIER_SIZE boxes overlap
; exactly when both |dx| and |dy| between their corners are under
; SOLDIER_SIZE -- the same AABB test as is_box_blocked, simplified
; because both boxes are the same size.
;
; Every move in update_soldiers goes through this, and spawns never
; overlap, so "no two living soldiers overlap" stays true for the whole
; game. That matters: a soldier that somehow started out overlapping a
; neighbour would find every single candidate step blocked by it.
; Dead soldiers are skipped, so a body never blocks anyone.
;
; Not used by line_blocked: sight lines and wall-routing only care
; about walls (see the note at the top of update_soldiers' .do_move).
is_spot_blocked:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8                   ; keep the stack 16-byte aligned for the call

    mov r12d, edi                ; self
    mov r13d, esi                ; x
    mov r14d, edx                ; y

    mov edi, r13d
    mov esi, r14d
    call is_box_blocked
    test eax, eax
    jnz .isb_done                ; eax is already 1

    xor ebx, ebx
.isb_loop:
    cmp ebx, TOTAL_SOLDIERS
    jge .isb_clear
    cmp ebx, r12d
    je .isb_next

    mov eax, ebx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .isb_next

    mov eax, [r10 + Soldier.x]
    sub eax, r13d
    jns .isb_dx_ok
    neg eax
.isb_dx_ok:
    cmp eax, SOLDIER_SIZE
    jge .isb_next                ; far enough apart horizontally

    mov eax, [r10 + Soldier.y]
    sub eax, r14d
    jns .isb_dy_ok
    neg eax
.isb_dy_ok:
    cmp eax, SOLDIER_SIZE
    jge .isb_next                ; far enough apart vertically

    mov eax, 1                   ; overlaps soldier ebx
    jmp .isb_done
.isb_next:
    inc ebx
    jmp .isb_loop
.isb_clear:
    xor eax, eax
.isb_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int line_blocked(int x0: edi, int y0: esi, int x1: edx, int y1: ecx) -> eax (1 or 0)
; Stage3's draw_line, Bresenham step for Bresenham step -- set_pixel
; is replaced with a call to is_box_blocked, and the walk exits
; the moment any step is blocked instead of always visiting every
; point on the line.
LB_X0  equ -8
LB_Y0  equ -16
LB_X1  equ -24
LB_Y1  equ -32
LB_SX  equ -40
LB_SY  equ -48
LB_DX  equ -56
LB_DY  equ -64
LB_ERR equ -72

; int sight_blocked(same arguments) -> eax: line_blocked for bullets
; and line of sight. Only walls count: you can shoot over a car.
sight_blocked:
    mov dword [lb_mask], BLOCK_SIGHT
    jmp line_blocked_core
line_blocked:
    mov dword [lb_mask], BLOCK_WALK
line_blocked_core:
    push rbp
    mov rbp, rsp
    sub rsp, 80

    mov [rbp + LB_X0], edi
    mov [rbp + LB_Y0], esi
    mov [rbp + LB_X1], edx
    mov [rbp + LB_Y1], ecx

    mov eax, [rbp + LB_X1]
    sub eax, [rbp + LB_X0]
    jns .dx_nonneg
    neg eax
.dx_nonneg:
    mov [rbp + LB_DX], eax

    mov eax, [rbp + LB_X0]
    cmp eax, [rbp + LB_X1]
    mov eax, 1
    jl .sx_done
    mov eax, -1
.sx_done:
    mov [rbp + LB_SX], eax

    mov eax, [rbp + LB_Y1]
    sub eax, [rbp + LB_Y0]
    jns .dy_nonneg
    neg eax
.dy_nonneg:
    neg eax
    mov [rbp + LB_DY], eax

    mov eax, [rbp + LB_Y0]
    cmp eax, [rbp + LB_Y1]
    mov eax, 1
    jl .sy_done
    mov eax, -1
.sy_done:
    mov [rbp + LB_SY], eax

    mov eax, [rbp + LB_DX]
    add eax, [rbp + LB_DY]
    mov [rbp + LB_ERR], eax

.step_loop:
    mov edi, [rbp + LB_X0]
    mov esi, [rbp + LB_Y0]
    call box_mask_blocked
    test eax, eax
    jz .not_blocked_here
    mov eax, 1
    mov rsp, rbp
    pop rbp
    ret
.not_blocked_here:
    mov eax, [rbp + LB_X0]
    cmp eax, [rbp + LB_X1]
    jne .continue_step
    mov eax, [rbp + LB_Y0]
    cmp eax, [rbp + LB_Y1]
    je .lb_clear
.continue_step:
    mov eax, [rbp + LB_ERR]
    add eax, eax

    cmp eax, [rbp + LB_DY]
    jl .skip_x
    mov ecx, [rbp + LB_ERR]
    add ecx, [rbp + LB_DY]
    mov [rbp + LB_ERR], ecx
    mov ecx, [rbp + LB_X0]
    add ecx, [rbp + LB_SX]
    mov [rbp + LB_X0], ecx
.skip_x:
    cmp eax, [rbp + LB_DX]
    jg .skip_y
    mov ecx, [rbp + LB_ERR]
    add ecx, [rbp + LB_DX]
    mov [rbp + LB_ERR], ecx
    mov ecx, [rbp + LB_Y0]
    add ecx, [rbp + LB_SY]
    mov [rbp + LB_Y0], ecx
.skip_y:
    jmp .step_loop
.lb_clear:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret


; void update_soldiers(void)
; Same as stage6c/01 except `.do_move`: every candidate position is now
; checked with is_spot_blocked (walls AND other soldiers), and a step
; blocked by a soldier falls back to main-axis-only, then to the same
; sticky side-step that already routes around walls.
US_I         equ -32
US_ACTUAL    equ -40
US_SELF_X    equ -48
US_SELF_Y    equ -56
US_WEAPON    equ -64
US_GOAL_X    equ -72
US_GOAL_Y    equ -80
US_IS_PICKUP equ -88
US_PICKUP_IDX equ -96
US_TARGET    equ -104
US_DIST_SQ   equ -112
US_NEG_BLOCKED equ -120
US_POS_BLOCKED equ -128
US_FWD_STEP  equ -136
US_STEP_X    equ -144
US_STEP_Y    equ -152
US_HIT       equ -160    ; this attack's hit roll, 1 = hit (for spawn_effect)

update_soldiers:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8
    sub rsp, 128                ; 96 in stage6b, +16 for US_FWD_STEP (6c),
                                ; +16 for US_STEP_X/Y. (US_HIT at -160 is the
                                ; last slot this leaves: rbp-24 pushes, 8 pad)

    call rng_next              ; per-tick random processing direction (03_combat.asm's
    and eax, 1                    ; fair-turn-order fix) -- was missing here too, carried
    mov [pass_reverse], eax          ; over from stage6a/04_weapons.asm's same regression

    call refresh_pickups             ; game mode: stale guns move on (10.04)
    call build_fields                ; one snapshot per tick, before anyone moves
    call update_events               ; police and dog move, shoot, bite

    mov dword [rbp + US_I], 0
.update_loop:
    mov eax, [rbp + US_I]
    cmp eax, TOTAL_SOLDIERS
    jge .update_done

    cmp dword [pass_reverse], 0
    je .use_forward
    mov ecx, TOTAL_SOLDIERS - 1
    sub ecx, eax
    jmp .have_actual
.use_forward:
    mov ecx, eax
.have_actual:
    mov [rbp + US_ACTUAL], ecx

    mov eax, ecx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .update_next

    cmp dword [r10 + Soldier.cooldown], 0
    jle .cooldown_done
    dec dword [r10 + Soldier.cooldown]
.cooldown_done:

    mov eax, [r10 + Soldier.x]
    mov [rbp + US_SELF_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + US_SELF_Y], eax
    mov eax, [r10 + Soldier.weapon]
    mov [rbp + US_WEAPON], eax
    mov dword [rbp + US_IS_PICKUP], 0

    ; ---- police nearby? run: the goal becomes a point away from the car ----
    mov dword [us_flee], 0
    cmp dword [cop_active], 0
    je .no_fear
    cmp dword [rbp + US_ACTUAL], SQUAD
    jae .no_fear                  ; the Big Homie doesn't run
    mov ecx, [rbp + US_SELF_X]
    mov eax, [cop_rect + 8]
    shr eax, 1
    add eax, [cop_rect]
    sub eax, SOLDIER_SIZE / 2     ; car centre, as a soldier corner
    sub ecx, eax                  ; dx: from the car to us
    mov edx, [rbp + US_SELF_Y]
    mov eax, [cop_rect + 12]
    shr eax, 1
    add eax, [cop_rect + 4]
    sub eax, SOLDIER_SIZE / 2
    sub edx, eax                  ; dy
    mov eax, ecx
    imul eax, eax
    mov r8d, edx
    imul r8d, r8d
    add eax, r8d
    cmp eax, FEAR_RADIUS * FEAR_RADIUS
    jg .no_fear
    mov dword [us_flee], 1
    ; Run OFF THE ROAD: across the car's direction of travel, plus a
    ; little further away along it. 14/15 ran straight away from the
    ; car, which for anyone ahead of it in its lane meant running down
    ; the road in front of it -- at 2 px a tick, from a car doing 3.
    ; (dx, dy: from the car's centre to this soldier)
    cmp dword [cop_vel], 0
    je .flee_car_vertical
    ; car going left/right: get off sideways, up or down
    mov eax, FLEE_DIST
    test edx, edx
    jns .flee_y_sign
    neg eax
.flee_y_sign:
    add eax, [rbp + US_SELF_Y]
    CLAMP_TO eax, WORLD_H - SOLDIER_SIZE
    mov [rbp + US_GOAL_Y], eax
    mov eax, ecx
    add eax, [rbp + US_SELF_X]
    CLAMP_TO eax, WORLD_W - SOLDIER_SIZE
    mov [rbp + US_GOAL_X], eax
    jmp .do_move                  ; no fighting, no pickups: just go
.flee_car_vertical:
    ; car going up/down: get off sideways, left or right
    mov eax, FLEE_DIST
    test ecx, ecx
    jns .flee_x_sign
    neg eax
.flee_x_sign:
    add eax, [rbp + US_SELF_X]
    CLAMP_TO eax, WORLD_W - SOLDIER_SIZE
    mov [rbp + US_GOAL_X], eax
    mov eax, edx
    add eax, [rbp + US_SELF_Y]
    CLAMP_TO eax, WORLD_H - SOLDIER_SIZE
    mov [rbp + US_GOAL_Y], eax
    jmp .do_move
.no_fear:

    cmp dword [rbp + US_WEAPON], WEAPON_KNIFE
    jne .have_enemy_only

    mov edi, [rbp + US_ACTUAL]
    call find_nearest_pickup
    mov [rbp + US_PICKUP_IDX], eax

    mov edi, [rbp + US_ACTUAL]
    call find_nearest_enemy
    mov [rbp + US_TARGET], eax

    cmp dword [rbp + US_PICKUP_IDX], -1
    je .no_pickup_candidate

    mov eax, [rbp + US_PICKUP_IDX]
    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax
    mov eax, [r10 + Pickup.x]
    sub eax, [rbp + US_SELF_X]
    imul eax, eax
    mov ecx, eax
    mov eax, [r10 + Pickup.y]
    sub eax, [rbp + US_SELF_Y]
    imul eax, eax
    add ecx, eax

    cmp dword [rbp + US_TARGET], -1
    je .use_pickup_goal

    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    sub eax, [rbp + US_SELF_X]
    imul eax, eax
    mov edx, eax
    mov eax, [r10 + Soldier.y]
    sub eax, [rbp + US_SELF_Y]
    imul eax, eax
    add edx, eax

    cmp ecx, edx
    jl .use_pickup_goal
    jmp .use_enemy_goal

.no_pickup_candidate:
    cmp dword [rbp + US_TARGET], -1
    je .update_next
    jmp .use_enemy_goal

.use_pickup_goal:
    mov dword [rbp + US_IS_PICKUP], 1
    mov eax, [rbp + US_PICKUP_IDX]
    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax
    mov eax, [r10 + Pickup.x]
    mov [rbp + US_GOAL_X], eax
    mov eax, [r10 + Pickup.y]
    mov [rbp + US_GOAL_Y], eax
    jmp .goal_decided

.have_enemy_only:
    mov edi, [rbp + US_ACTUAL]
    call find_nearest_enemy
    mov [rbp + US_TARGET], eax
    cmp eax, -1
    je .update_next

.use_enemy_goal:
    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    mov [rbp + US_GOAL_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rbp + US_GOAL_Y], eax

.goal_decided:
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]
    imul eax, eax
    mov ecx, eax
    mov eax, [rbp + US_GOAL_Y]
    sub eax, [rbp + US_SELF_Y]
    imul eax, eax
    add ecx, eax
    mov [rbp + US_DIST_SQ], ecx

    cmp dword [rbp + US_IS_PICKUP], 0
    jne .handle_pickup_goal
    jmp .handle_enemy_goal

.handle_pickup_goal:
    mov eax, [rbp + US_DIST_SQ]
    cmp eax, PICKUP_RADIUS * PICKUP_RADIUS
    jg .do_move

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    mov eax, [rbp + US_PICKUP_IDX]
    imul eax, Pickup_size
    lea r11, [pickups]
    add r11, rax

    mov eax, [r11 + Pickup.type]
    mov [r10 + Soldier.weapon], eax
    mov dword [r11 + Pickup.active], 0
    jmp .update_next

.handle_enemy_goal:
    mov edi, [rbp + US_WEAPON]
    call get_weapon_range_sq
    cmp dword [rbp + US_DIST_SQ], eax
    jg .do_move

    ; ranged weapons need line of sight to actually fire; knife is
    ; contact-range only, and an obstacle blocking contact would
    ; already have blocked the movement that got here, so skip the
    ; check for it entirely
    mov eax, [rbp + US_WEAPON]
    cmp eax, WEAPON_KNIFE
    je .los_ok

    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    mov edx, [rbp + US_GOAL_X]
    mov ecx, [rbp + US_GOAL_Y]
    call sight_blocked             ; walls only: you can shoot over a car
    test eax, eax
    jnz .do_move                   ; blocked -- can't fire, try to reposition instead
.los_ok:

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.cooldown], 0
    jg .update_next

    ; ---- ready to fire: who would the shot hit? ----
    ; (knife: contact range, so the target is the only one it can reach)
    cmp dword [rbp + US_WEAPON], WEAPON_KNIFE
    je .victim_ok
    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_TARGET]
    call first_in_line

    ; someone we don't fight first in the line (a teammate) -> hold
    ; fire and side-step for a clear shot. .side_step steps
    ; perpendicular to US_GOAL, which here is the target, so it moves
    ; the soldier across the line of fire
    mov ecx, eax
    imul ecx, Soldier_size
    lea rdx, [soldiers]
    mov ecx, [rdx + rcx + Soldier.team]
    mov r8d, [rbp + US_ACTUAL]
    imul r8d, Soldier_size
    mov r8d, [rdx + r8 + Soldier.team]
    HOSTILE rcx, r8, rcx
    jnz .fire_clear
    inc dword [ff_held]
    jmp .side_step
.fire_clear:
    mov [rbp + US_TARGET], eax     ; from here on, "target" = whoever gets hit

    ; first_in_line used r10 as scratch -- point it back at the shooter
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
.victim_ok:

    mov eax, [rbp + US_WEAPON]
    cmp eax, WEAPON_KNIFE
    jne .not_atk_knife
    mov r12d, KNIFE_DAMAGE
    mov r13d, KNIFE_HIT_CHANCE
    mov r14d, KNIFE_COOLDOWN_TICKS
    jmp .have_atk_stats
.not_atk_knife:
    cmp eax, WEAPON_PISTOL
    jne .atk_shotgun
    mov r12d, PISTOL_DAMAGE
    mov r13d, PISTOL_HIT_CHANCE
    mov r14d, PISTOL_COOLDOWN_TICKS
    jmp .have_atk_stats
.atk_shotgun:
    mov eax, [rbp + US_DIST_SQ]
    cmp eax, SHOTGUN_CLOSE_RANGE * SHOTGUN_CLOSE_RANGE
    jg .shotgun_far
    mov r12d, SHOTGUN_CLOSE_DAMAGE
    mov r13d, SHOTGUN_CLOSE_HIT
    jmp .shotgun_cd
.shotgun_far:
    mov r12d, SHOTGUN_FAR_DAMAGE
    mov r13d, SHOTGUN_FAR_HIT
.shotgun_cd:
    mov r14d, SHOTGUN_COOLDOWN_TICKS
.have_atk_stats:
    cmp dword [rbp + US_ACTUAL], SQUAD
    jb .not_boss_attack
    shl r12d, 1                   ; the Big Homie: double damage,
    add r13d, BOSS_HIT_BONUS      ; and harder to miss
    cmp r13d, BOSS_HIT_CAP
    jle .not_boss_attack
    mov r13d, BOSS_HIT_CAP
.not_boss_attack:
    mov [r10 + Soldier.cooldown], r14d

    call rng_next
    xor edx, edx
    mov ecx, 100
    div ecx
    xor eax, eax
    cmp edx, r13d
    setl al                        ; same roll as before, just kept
    mov [rbp + US_HIT], eax

    ; record the attack for the renderer -- hit or miss. Drawing only:
    ; no RNG, no soldier state, so the fight is unchanged
    mov edi, [rbp + US_WEAPON]
    mov esi, [rbp + US_ACTUAL]
    mov edx, [rbp + US_TARGET]
    mov ecx, eax
    call spawn_effect

    cmp dword [rbp + US_HIT], 0
    je .update_next

    ; spawn protection: the hit lands (and shows) but does nothing
    mov eax, [rbp + US_TARGET]
    lea rcx, [protect_timer]
    cmp dword [rcx + rax*4], 0
    jg .update_next

    mov eax, [rbp + US_TARGET]
    imul eax, Soldier_size
    lea r11, [soldiers]
    add r11, rax

    ; tally friendly fire (a hit on someone we don't fight). r13d (the
    ; hit chance) is free after the roll, so it holds "friendly"
    ; through the kill check below
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea rcx, [soldiers]
    mov eax, [rcx + rax + Soldier.team]
    mov edx, [r11 + Soldier.team]
    xor r13d, r13d
    HOSTILE rax, rax, rdx
    jnz .ff_tallied
    mov r13d, 1
    inc dword [ff_hits]
.ff_tallied:

    sub dword [r11 + Soldier.health], r12d
    cmp dword [r11 + Soldier.health], 0
    jg .update_next
    mov dword [r11 + Soldier.health], 0
    add [ff_kills], r13d

    ; ---- a kill: score it, and book the victim's respawn ----
    ; (r11 still points at the victim for the weapon drop below)
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea rcx, [soldiers]
    mov ecx, [rcx + rax + Soldier.team]  ; killer's faction
    mov edx, [r11 + Soldier.team]
    HOSTILE rax, rcx, rdx
    jz .scored                     ; friendly kills score nothing
    inc dword [score + rcx*4]
    mov eax, [score_limit]
    test eax, eax
    jle .scored                    ; no limit
    cmp [score + rcx*4], eax
    jne .scored
    cmp dword [score_winner], 0
    jne .scored                    ; the other team got there first
    inc ecx
    mov [score_winner], ecx
.scored:
    ; a respawn needs one from the soldier's own lives (LIVES) AND one
    ; from the team's pool (RESPAWNS); either can be unlimited (-1)
    mov eax, [rbp + US_TARGET]
    lea rcx, [lives_left]
    cmp dword [rcx + rax*4], 0
    je .no_respawn                 ; last life: dead for good
    mov edx, [r11 + Soldier.team]
    cmp dword [tickets + rdx*4], 0
    je .no_respawn                 ; team pool empty: dead for good
    jl .pool_ok                    ; unlimited
    dec dword [tickets + rdx*4]
.pool_ok:
    cmp dword [rcx + rax*4], 0
    jl .book_respawn               ; unlimited
    dec dword [rcx + rax*4]
.book_respawn:
    lea rcx, [respawn_timer]
    mov dword [rcx + rax*4], RESPAWN_TICKS
.no_respawn:

    mov eax, [r11 + Soldier.weapon]
    cmp eax, WEAPON_KNIFE
    je .update_next

    mov edi, [r11 + Soldier.x]
    mov esi, [r11 + Soldier.y]
    mov edx, eax
    call drop_weapon
    jmp .update_next

.do_move:
    ; ---- is the direct path to the goal clear of WALLS? ----
    ; (line_blocked deliberately ignores soldiers: it also answers the
    ; line-of-sight question, and a teammate standing in the line would
    ; otherwise block every shot -- including the target itself, which
    ; sits right at the end of the line)
    mov edi, [rbp + US_SELF_X]
    mov esi, [rbp + US_SELF_Y]
    mov edx, [rbp + US_GOAL_X]
    mov ecx, [rbp + US_GOAL_Y]
    call line_blocked
    test eax, eax
    jnz .follow_field

.clear_step:
    ; ---- clear of walls: the usual step, clamped to MOVE_SPEED per axis ----
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]
    cmp eax, MOVE_SPEED
    jle .sx_hi_ok
    mov eax, MOVE_SPEED
.sx_hi_ok:
    cmp eax, -MOVE_SPEED
    jge .sx_lo_ok
    mov eax, -MOVE_SPEED
.sx_lo_ok:
    mov [rbp + US_STEP_X], eax

    mov eax, [rbp + US_GOAL_Y]
    sub eax, [rbp + US_SELF_Y]
    cmp eax, MOVE_SPEED
    jle .sy_hi_ok
    mov eax, MOVE_SPEED
.sy_hi_ok:
    cmp eax, -MOVE_SPEED
    jge .sy_lo_ok
    mov eax, -MOVE_SPEED
.sy_lo_ok:
    mov [rbp + US_STEP_Y], eax

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    add esi, [rbp + US_STEP_X]
    mov edx, [rbp + US_SELF_Y]
    add edx, [rbp + US_STEP_Y]
    call is_spot_blocked
    test eax, eax
    jz .apply_step

    ; ---- another soldier is in the way: try the MAIN axis alone ----
    ; Only the main axis (whichever of |dx|, |dy| is larger), never the
    ; minor one. Sliding along the minor axis is what a side-step around
    ; the blocker would immediately undo: step up to get around someone,
    ; then next tick the minor-axis slide pulls you straight back down
    ; into line behind them -- stage6b's bug #5 oscillation all over
    ; again. If the main axis is blocked too, hand off to the sticky
    ; side-step below, which exists precisely to commit to one way round.
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]
    jns .mx_abs_ok
    neg eax
.mx_abs_ok:
    mov ecx, [rbp + US_GOAL_Y]
    sub ecx, [rbp + US_SELF_Y]
    jns .my_abs_ok
    neg ecx
.my_abs_ok:
    cmp eax, ecx
    jl .main_axis_y
    mov dword [rbp + US_STEP_Y], 0
    jmp .try_main_axis
.main_axis_y:
    mov dword [rbp + US_STEP_X], 0
.try_main_axis:
    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    add esi, [rbp + US_STEP_X]
    mov edx, [rbp + US_SELF_Y]
    add edx, [rbp + US_STEP_Y]
    call is_spot_blocked
    test eax, eax
    jnz .side_step

.apply_step:
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [rbp + US_STEP_X]
    add [r10 + Soldier.x], eax
    mov eax, [rbp + US_STEP_Y]
    add [r10 + Soldier.y], eax
    jmp .update_next

.follow_field:
    ; running from the police: there's no field for "away", so the old
    ; side-step it is
    cmp dword [us_flee], 0
    jne .side_step
    ; ---- a wall is in the way: head for the next cell on the flow field ----
    ; Which field: pickups if that's the goal, else this soldier's
    ; faction's (toward everyone it fights, 10.02).
    ; The waypoint replaces the goal, and .clear_step walks to it, with
    ; the usual fallbacks if a soldier is standing there
    lea rsi, [field_pk]
    cmp dword [rbp + US_IS_PICKUP], 0
    jne .have_field
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea rcx, [soldiers]
    mov eax, [rcx + rax + Soldier.team]
    imul eax, eax, GRID_CELLS * 2
    lea rsi, [field_for]
    add rsi, rax
.have_field:
    mov edi, [rbp + US_ACTUAL]
    call flow_waypoint
    test eax, eax
    jz .side_step                  ; no closer neighbour: old behaviour
    mov eax, [flow_wx]
    mov [rbp + US_GOAL_X], eax
    mov eax, [flow_wy]
    mov [rbp + US_GOAL_Y], eax
    jmp .clear_step

.side_step:
    ; ---- blocked (by a wall or a soldier): step perpendicular to the goal ----
    mov eax, [rbp + US_GOAL_X]
    sub eax, [rbp + US_SELF_X]           ; dx
    mov ecx, [rbp + US_GOAL_Y]
    sub ecx, [rbp + US_SELF_Y]              ; dy

    mov edx, eax
    cmp edx, 0
    jns .dx_abs_ok
    neg edx
.dx_abs_ok:
    mov r8d, ecx
    cmp r8d, 0
    jns .dy_abs_ok
    neg r8d
.dy_abs_ok:
    cmp edx, r8d
    jl .try_horizontal

    ; goal is mostly sideways, so try stepping vertically around
    ; whatever's in the way. Which side to try FIRST is "sticky": prefer
    ; whichever side (up/negative or down/positive) actually worked last
    ; time for this soldier -- see stage6b's README, bug #5, for the
    ; permanent 2-tick oscillation that always defaulting to "up" caused.
    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    mov edx, [rbp + US_SELF_Y]
    sub edx, MOVE_SPEED
    call is_spot_blocked
    mov [rbp + US_NEG_BLOCKED], eax          ; "up" blocked?

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    mov edx, [rbp + US_SELF_Y]
    add edx, MOVE_SPEED
    call is_spot_blocked
    mov [rbp + US_POS_BLOCKED], eax          ; "down" blocked?

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.avoid_dir]
    test eax, eax
    jnz .prefer_down

    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .fallback_down
    mov dword [r10 + Soldier.avoid_dir], 0      ; up worked again -- keep preferring it
    sub dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.fallback_down:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .update_next                               ; both blocked -- hold position
    mov dword [r10 + Soldier.avoid_dir], 1            ; up failed, down worked -- switch preference
    add dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.prefer_down:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .fallback_up
    mov dword [r10 + Soldier.avoid_dir], 1
    add dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next
.fallback_up:
    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .update_next
    mov dword [r10 + Soldier.avoid_dir], 0
    sub dword [r10 + Soldier.y], MOVE_SPEED
    jmp .update_next

.try_horizontal:
    ; Left/right is NOT the same choice for both teams the way up/down
    ; is, so "first choice" here means FORWARD, toward the enemy's home
    ; complex (fwd_sign, set by choose_sides). See stage6c's README, bug #1 -- a
    ; plain "left first" gave the team on the right 39 of 48 games.
    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.team]
    imul eax, [fwd_sign + rax*4], MOVE_SPEED   ; toward the enemy's home
    mov [rbp + US_FWD_STEP], eax

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    add esi, [rbp + US_FWD_STEP]
    mov edx, [rbp + US_SELF_Y]
    call is_spot_blocked
    mov [rbp + US_NEG_BLOCKED], eax          ; "forward" blocked?

    mov edi, [rbp + US_ACTUAL]
    mov esi, [rbp + US_SELF_X]
    sub esi, [rbp + US_FWD_STEP]
    mov edx, [rbp + US_SELF_Y]
    call is_spot_blocked
    mov [rbp + US_POS_BLOCKED], eax          ; "back" blocked?

    mov eax, [rbp + US_ACTUAL]
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov ecx, [rbp + US_FWD_STEP]
    mov eax, [r10 + Soldier.avoid_dir]
    test eax, eax
    jnz .prefer_back

    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .fallback_back
    mov dword [r10 + Soldier.avoid_dir], 0
    add [r10 + Soldier.x], ecx
    jmp .update_next
.fallback_back:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .update_next
    mov dword [r10 + Soldier.avoid_dir], 1
    sub [r10 + Soldier.x], ecx
    jmp .update_next
.prefer_back:
    cmp dword [rbp + US_POS_BLOCKED], 0
    jne .fallback_fwd
    mov dword [r10 + Soldier.avoid_dir], 1
    sub [r10 + Soldier.x], ecx
    jmp .update_next
.fallback_fwd:
    cmp dword [rbp + US_NEG_BLOCKED], 0
    jne .update_next
    mov dword [r10 + Soldier.avoid_dir], 0
    add [r10 + Soldier.x], ecx
    jmp .update_next

.update_next:
    mov eax, [rbp + US_I]
    inc eax
    mov [rbp + US_I], eax
    jmp .update_loop
.update_done:
    call process_respawns
    lea rsp, [rbp - 24]
    pop r14
    pop r13
    pop r12
    pop rbp
    ret


; int first_in_line(int shooter: edi, int target: esi) -> eax
;
; Who actually takes this shot: the first living soldier (not the
; shooter) whose box contains a point on the line from the shooter's
; centre to the target's centre. Bresenham again, as in draw_line and
; line_blocked, but it checks every soldier's box at each point
; instead of plotting or checking walls.
;
; The walk is in HALF-PIXEL units (every coordinate doubled). In whole
; pixels, a 16px box at x has no centre pixel: x+8 is 8 pixels in from
; the left edge but 7 from the right. Under the left-right mirror that
; puts every team 1 line of fire 1px off the mirror image of team 0's,
; while the boxes themselves mirror exactly. In 06, which asks this
; ~3,300 times a game to decide whether to hold fire, team 1 won 259 of
; 480 games with the 1px and 142-146 over 288 without it. Doubled, the
; centre is exactly 2x + 15 and a box exactly [2x, 2x + 30], and both
; mirror exactly. (Bresenham's steps depend only on |dx| and |dy|, so
; the walk itself was already mirror-symmetric.)
;
; No calls, so the walk state lives in registers:
;   ebx shooter    r12d target
;   r8d/r9d  current x,y    r10d/r11d end x,y
;   r13d/r14d sx,sy   r15d dx   edi dy (<= 0)   esi err
; Cost: up to ~500 half-pixel points x 100 boxes per check, a few
; thousand checks per game. Nothing at this scale.
first_in_line:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov ebx, edi
    mov r12d, esi

    mov eax, ebx
    imul eax, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    ; half-pixel units: a box's true centre is 2x + SIZE - 1 (see above)
    mov r8d, [rcx + Soldier.x]
    lea r8d, [r8d * 2 + SOLDIER_SIZE - 1]
    mov r9d, [rcx + Soldier.y]
    lea r9d, [r9d * 2 + SOLDIER_SIZE - 1]
    mov eax, r12d
    imul eax, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    mov r10d, [rcx + Soldier.x]
    lea r10d, [r10d * 2 + SOLDIER_SIZE - 1]
    mov r11d, [rcx + Soldier.y]
    lea r11d, [r11d * 2 + SOLDIER_SIZE - 1]

    ; dx = |x1-x0|, sx = sign; dy = -|y1-y0|, sy = sign; err = dx + dy
    mov r13d, 1
    mov r15d, r10d
    sub r15d, r8d
    jns .fil_dx_ok
    neg r15d
    mov r13d, -1
.fil_dx_ok:
    mov r14d, 1
    mov edi, r11d
    sub edi, r9d
    jns .fil_dy_ok
    neg edi
    mov r14d, -1
.fil_dy_ok:
    neg edi
    mov esi, r15d
    add esi, edi

.fil_step:
    xor ecx, ecx
    lea rdx, [soldiers]
.fil_scan:
    cmp ecx, TOTAL_SOLDIERS
    jge .fil_nobody
    cmp ecx, ebx
    je .fil_scan_next               ; the line starts inside the shooter
    cmp dword [rdx + Soldier.health], 0
    jle .fil_scan_next
    ; inside the box when 0 <= X - 2*box.x <= 2*SIZE - 2 (half-pixel
    ; units). Compared unsigned, a negative difference becomes huge, so
    ; one jae covers both ends
    mov eax, [rdx + Soldier.x]
    add eax, eax
    neg eax
    add eax, r8d
    cmp eax, 2 * SOLDIER_SIZE - 1
    jae .fil_scan_next
    mov eax, [rdx + Soldier.y]
    add eax, eax
    neg eax
    add eax, r9d
    cmp eax, 2 * SOLDIER_SIZE - 1
    jae .fil_scan_next
    mov eax, ecx                    ; this soldier is in the way
    jmp .fil_done
.fil_scan_next:
    inc ecx
    add rdx, Soldier_size
    jmp .fil_scan

.fil_nobody:
    cmp r8d, r10d
    jne .fil_advance
    cmp r9d, r11d
    jne .fil_advance
    mov eax, r12d                   ; reached the end (can't really miss
    jmp .fil_done                   ; the target's box, but just in case)
.fil_advance:
    lea eax, [esi + esi]            ; 2*err
    cmp eax, edi
    jl .fil_skip_x
    add esi, edi
    add r8d, r13d
.fil_skip_x:
    cmp eax, r15d
    jg .fil_skip_y
    add esi, r15d
    add r9d, r14d
.fil_skip_y:
    jmp .fil_step

.fil_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
