; events.asm -- random encounters: police, the dog
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; Random encounters: the police and the pitbull (see the header)
; ============================================================

; int chance(int n: edi) -> eax: 1 with probability 1/n
chance:
    call rand_range
    cmp eax, 1
    setb al
    movzx eax, al
    ret


; int event_damage(int victim: edi, int damage: esi) -> eax (1 = killed)
; Damage from the police or the dog. Spawn protection still holds.
; A kill scores for nobody, but otherwise goes like any other: the
; weapon drops, and a respawn is booked if lives and the team's pool
; allow.
event_damage:
    push rbx
    mov ebx, edi
    lea rcx, [protect_timer]
    cmp dword [rcx + rbx*4], 0
    jg .ed_alive
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    cmp dword [r10 + Soldier.health], 0
    jle .ed_alive                 ; already down this tick
    mov edi, ebx
    call armor_damage             ; your body armor (10.10)
    sub [r10 + Soldier.health], eax
    cmp dword [r10 + Soldier.health], 0
    jg .ed_alive
    mov dword [r10 + Soldier.health], 0
    mov edi, ebx
    call drop_and_book
    mov eax, 1
    pop rbx
    ret
.ed_alive:
    xor eax, eax
    pop rbx
    ret

; drop_and_book(int i: edi): a soldier just died -- drop its gun and
; book a respawn, exactly as the kill code in update_soldiers does
drop_and_book:
    push rbx
    mov ebx, edi
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov edx, [r10 + Soldier.weapon]
    cmp edx, WEAPON_KNIFE
    je .db_book
    cmp ebx, PLAYER
    je .db_book                   ; your pistol goes with you (10.05)
    mov edi, [r10 + Soldier.x]
    mov esi, [r10 + Soldier.y]
    call drop_weapon
.db_book:
    lea rcx, [lives_left]
    cmp dword [rcx + rbx*4], 0
    je .db_done
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    mov edx, [r10 + rax + Soldier.team]
    cmp dword [tickets + rdx*4], 0
    je .db_done
    jl .db_pool_ok
    dec dword [tickets + rdx*4]
.db_pool_ok:
    cmp dword [rcx + rbx*4], 0
    jl .db_timer
    dec dword [rcx + rbx*4]
.db_timer:
    lea rcx, [respawn_timer]
    mov dword [rcx + rbx*4], RESPAWN_TICKS
.db_done:
    pop rbx
    ret


; CLAMP_DOG reg: reg = min(max(reg, -DOG_SPEED), DOG_SPEED)
%macro CLAMP_DOG 1
    cmp %1, DOG_SPEED
    jle %%hi_ok
    mov %1, DOG_SPEED
%%hi_ok:
    cmp %1, -DOG_SPEED
    jge %%lo_ok
    mov %1, -DOG_SPEED
%%lo_ok:
%endmacro

; void update_events(void) -- once per tick, before the soldiers move
update_events:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call update_bosses
    call update_police
    call update_dog
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ---- the police ----
update_police:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [cop_active], 0
    jne .up_drive
    cmp dword [ticks], COP_FIRST_DELAY
    jb .up_done
    mov edi, COP_CHANCE
    call chance
    test eax, eax
    jz .up_done
    ; a car arrives on a random route
    mov edi, COP_ROUTES
    call rand_range
    imul eax, eax, 24
    lea rsi, [cop_routes]
    add rsi, rax
    lea rdi, [cop_rect]
    mov ecx, 6                    ; rect + velocity, which follows it
    cld
    rep movsd
    mov dword [cop_fire], COP_FIRE_TICKS
    mov dword [cop_wait], 0
    mov dword [cop_active], 1

.up_drive:
    ; anyone the police won't hurt (you) just ahead: the car waits
    ; rather than run you over -- for COP_WAIT_MAX ticks, then it turns
    ; round and goes back the way it came (10.09)
    call cop_blocked
    test eax, eax
    jz .up_move
    inc dword [cop_wait]
    cmp dword [cop_wait], COP_WAIT_MAX
    jl .up_moved
    neg dword [cop_vel]
    neg dword [cop_vel + 4]
    mov dword [cop_wait], 0
    jmp .up_moved
.up_move:
    mov dword [cop_wait], 0
    mov eax, [cop_vel]
    add [cop_rect], eax
    mov eax, [cop_vel + 4]
    add [cop_rect + 4], eax
.up_moved:
    ; gone off the far edge?
    mov eax, [cop_rect]
    cmp eax, WORLD_W
    jg .up_leave
    add eax, [cop_rect + 8]
    cmp eax, 0
    jl .up_leave
    mov eax, [cop_rect + 4]
    cmp eax, WORLD_H
    jg .up_leave
    add eax, [cop_rect + 12]
    cmp eax, 0
    jl .up_leave

    ; ---- anyone the car touches is arrested ----
    lea r12, [soldiers]
    xor ebx, ebx
.up_touch:
    cmp dword [r12 + Soldier.health], 0
    jle .up_touch_next
    mov eax, [r12 + Soldier.team]
    mov ecx, FACTION_POLICE
    HOSTILE rcx, rcx, rax         ; only those the police go after (10.09)
    jz .up_touch_next
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    mov edx, SOLDIER_SIZE
    mov ecx, SOLDIER_SIZE
    lea r8, [cop_rect]
    call rect_hit
    test eax, eax
    jz .up_touch_next
    ; arrested: out of the game for good
    mov dword [r12 + Soldier.health], 0
    mov edx, [r12 + Soldier.weapon]
    cmp edx, WEAPON_KNIFE
    je .up_no_drop
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    call drop_weapon
.up_no_drop:
    lea rcx, [respawn_timer]
    mov dword [rcx + rbx*4], 0
    lea rcx, [lives_left]
    mov dword [rcx + rbx*4], 0
    inc dword [arrests]
.up_touch_next:
    add r12, Soldier_size
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .up_touch

    ; ---- the officers shoot ----
    dec dword [cop_fire]
    jg .up_done
    mov dword [cop_fire], COP_FIRE_TICKS
    ; from the car's centre, as a soldier corner
    mov r13d, [cop_rect + 8]
    shr r13d, 1
    add r13d, [cop_rect]
    sub r13d, SOLDIER_SIZE / 2
    mov r14d, [cop_rect + 12]
    shr r14d, 1
    add r14d, [cop_rect + 4]
    sub r14d, SOLDIER_SIZE / 2
    ; nearest living soldier in range with a clear line
    mov r15d, -1                  ; best index
    mov r12d, COP_RANGE * COP_RANGE + 1
    xor ebx, ebx
.up_aim:
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    cmp dword [rcx + Soldier.health], 0
    jle .up_aim_next
    mov eax, [rcx + Soldier.team]
    mov edx, FACTION_POLICE
    HOSTILE rdx, rdx, rax         ; only those the police go after (10.09)
    jz .up_aim_next
    mov eax, [rcx + Soldier.x]
    sub eax, r13d
    imul eax, eax
    mov edx, [rcx + Soldier.y]
    sub edx, r14d
    imul edx, edx
    add eax, edx
    cmp eax, r12d
    jae .up_aim_next
    push rax
    push rcx
    mov edi, r13d
    mov esi, r14d
    mov edx, [rcx + Soldier.x]
    mov ecx, [rcx + Soldier.y]
    call sight_blocked
    pop rcx
    mov edx, eax
    pop rax
    test edx, edx
    jnz .up_aim_next
    mov r12d, eax
    mov r15d, ebx
.up_aim_next:
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .up_aim
    cmp r15d, -1
    je .up_done
    mov edi, 100
    call rand_range
    xor ebx, ebx
    cmp eax, COP_HIT_CHANCE
    setb bl                       ; hit?
    mov [fx_src], r13d
    mov [fx_src + 4], r14d
    mov edi, WEAPON_PISTOL
    mov esi, -1
    mov edx, r15d
    mov ecx, ebx
    call spawn_effect
    test ebx, ebx
    jz .up_done
    mov edi, r15d
    mov esi, COP_DAMAGE
    call event_damage
    add [cop_kills], eax
    jmp .up_done
.up_leave:
    mov dword [cop_active], 0
.up_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int rect_hit(int x: edi, int y: esi, int w: edx, int h: ecx,
;              Rect *r: r8) -> eax: 1 if [x, x+w) x [y, y+h) overlaps
; the rectangle at r8 (x, y, w, h). A leaf (10.09)
rect_hit:
    xor eax, eax
    lea r9d, [edi + edx]
    cmp r9d, [r8]
    jle .rh_done
    mov r9d, [r8]
    add r9d, [r8 + 8]
    cmp edi, r9d
    jge .rh_done
    lea r9d, [esi + ecx]
    cmp r9d, [r8 + 4]
    jle .rh_done
    mov r9d, [r8 + 4]
    add r9d, [r8 + 12]
    cmp esi, r9d
    jge .rh_done
    mov eax, 1
.rh_done:
    ret


; int cop_blocked(void) -> eax: 1 if anything the police won't hurt is
; in the strip just ahead of the car's bumper (as far as it moves in a
; tick, plus COP_GAP): a living soldier the police aren't hostile to --
; you; riding, the whole bike -- or your parked bike. Only ahead: from
; behind or the side, you don't stop it (10.09)
;   rbx a soldier   r12d its index
cop_blocked:
    push rbx
    push r12
    sub rsp, 8
    ; the strip: the car's width, from its front edge forward
    mov eax, [cop_rect]
    mov ecx, [cop_rect + 4]
    mov edx, [cop_rect + 8]
    mov r8d, [cop_rect + 12]
    mov r9d, [cop_vel]
    test r9d, r9d
    jz .cb_vertical
    jl .cb_west
    add eax, edx                  ; east: from the right edge
    lea edx, [r9d + COP_GAP]
    jmp .cb_strip
.cb_west:
    neg r9d
    lea edx, [r9d + COP_GAP]
    sub eax, edx
    jmp .cb_strip
.cb_vertical:
    mov r9d, [cop_vel + 4]
    test r9d, r9d
    jl .cb_north
    add ecx, r8d                  ; south: from the bottom edge
    lea r8d, [r9d + COP_GAP]
    jmp .cb_strip
.cb_north:
    neg r9d
    lea r8d, [r9d + COP_GAP]
    sub ecx, r8d
.cb_strip:
    mov [cop_strip], eax
    mov [cop_strip + 4], ecx
    mov [cop_strip + 8], edx
    mov [cop_strip + 12], r8d
    ; the living the police won't hurt
    lea rbx, [soldiers]
    xor r12d, r12d
.cb_soldier:
    cmp dword [rbx + Soldier.health], 0
    jle .cb_next
    mov eax, [rbx + Soldier.team]
    mov ecx, FACTION_POLICE
    HOSTILE rcx, rcx, rax
    jnz .cb_next                  ; theirs to hit: no waiting
    mov edi, [rbx + Soldier.x]
    mov esi, [rbx + Soldier.y]
    mov edx, SOLDIER_SIZE
    mov ecx, SOLDIER_SIZE
    cmp r12d, PLAYER
    jne .cb_box
    cmp dword [riding], 0
    je .cb_box
    call bike_box                 ; riding: the bike's size, not yours
.cb_box:
    lea r8, [cop_strip]
    call rect_hit
    test eax, eax
    jnz .cb_done
.cb_next:
    add rbx, Soldier_size
    inc r12d
    cmp r12d, TOTAL_SOLDIERS
    jb .cb_soldier
    ; your parked bike
    xor eax, eax
    cmp dword [player_on], 0
    je .cb_done
    cmp dword [riding], 0
    jne .cb_done
    cmp dword [veh_health], 0
    jle .cb_done
    call bike_box
    lea r8, [cop_strip]
    call rect_hit
.cb_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

; bike_box -> edi, esi, edx, ecx: the bike's sprite square (a leaf)
bike_box:
    mov edi, [veh_x]
    sar edi, 4
    sub edi, VEHICLE_SPRITE / 2
    mov esi, [veh_y]
    sar esi, 4
    sub esi, VEHICLE_SPRITE / 2
    mov edx, VEHICLE_SPRITE
    mov ecx, VEHICLE_SPRITE
    ret


; ---- the pitbull ----
update_dog:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, [dog_state]
    cmp eax, DOG_NONE
    jne .ud_walking
    cmp dword [ticks], DOG_FIRST_DELAY
    jb .ud_done
    mov edi, DOG_CHANCE
    call chance
    test eax, eax
    jz .ud_done
    mov edi, DOG_WALKS
    call rand_range
    imul eax, eax, 12
    lea rsi, [dog_walks]
    add rsi, rax
    mov eax, [rsi]
    mov [walker_x], eax
    mov eax, [rsi + 4]
    mov [walker_y], eax
    mov eax, [rsi + 8]
    mov [walker_dx], eax
    mov dword [dog_state], DOG_LEASHED

.ud_walking:
    ; the walker keeps walking, whatever the dog does
    mov eax, [walker_dx]
    add [walker_x], eax
    ; the dog, on its leash, trots a little ahead
    cmp dword [dog_state], DOG_LEASHED
    jne .ud_not_leashed
    imul eax, [walker_dx], 16
    add eax, [walker_x]
    mov [dog_x], eax
    mov eax, [walker_y]
    inc eax
    mov [dog_y], eax
    ; slips the leash? (only once it's on screen)
    mov eax, [dog_x]
    cmp eax, 0
    jl .ud_check_end
    cmp eax, WORLD_W - DOG_W
    jg .ud_check_end
    mov edi, DOG_BREAK_CHANCE
    call chance
    test eax, eax
    jz .ud_check_end
    mov dword [dog_state], DOG_LOOSE
    mov dword [dog_timer], DOG_RAGE_TICKS
    mov dword [dog_bite], 0
    jmp .ud_check_end

.ud_not_leashed:
    cmp dword [dog_state], DOG_LOOSE
    jne .ud_check_end
    dec dword [dog_timer]
    jg .ud_hunt
    mov dword [dog_state], DOG_GONE   ; animal control
    jmp .ud_check_end
.ud_hunt:
    cmp dword [dog_bite], 0
    jle .ud_bite_ready
    dec dword [dog_bite]
.ud_bite_ready:
    ; nearest living soldier, either gang
    mov r15d, -1
    mov r12d, 0x7FFFFFFF
    lea rcx, [soldiers]
    xor ebx, ebx
.ud_near:
    cmp dword [rcx + Soldier.health], 0
    jle .ud_near_next
    mov eax, [rcx + Soldier.x]
    sub eax, [dog_x]
    imul eax, eax
    mov edx, [rcx + Soldier.y]
    sub edx, [dog_y]
    imul edx, edx
    add eax, edx
    cmp eax, r12d
    jae .ud_near_next
    mov r12d, eax
    mov r15d, ebx
.ud_near_next:
    add rcx, Soldier_size
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .ud_near
    cmp r15d, -1
    je .ud_check_end
    imul eax, r15d, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    mov r13d, [rcx + Soldier.x]   ; target corner
    mov r14d, [rcx + Soldier.y]
    ; in reach? bite
    cmp r12d, CONTACT_RANGE * CONTACT_RANGE
    jg .ud_chase
    cmp dword [dog_bite], 0
    jg .ud_check_end
    mov dword [dog_bite], DOG_BITE_TICKS
    mov edi, 100
    call rand_range
    xor ebx, ebx
    cmp eax, DOG_BITE_CHANCE
    setb bl
    mov eax, [dog_x]
    mov [fx_src], eax
    mov eax, [dog_y]
    mov [fx_src + 4], eax
    mov edi, WEAPON_KNIFE         ; a lunge, drawn like a knife thrust
    mov esi, -1
    mov edx, r15d
    mov ecx, ebx
    call spawn_effect
    test ebx, ebx
    jz .ud_check_end
    mov edi, r15d
    mov esi, DOG_DAMAGE
    call event_damage
    add [dog_kills], eax
    jmp .ud_check_end
.ud_chase:
    ; step toward it; if that's blocked, try each axis alone
    mov r8d, r13d
    sub r8d, [dog_x]
    CLAMP_DOG r8d
    mov r9d, r14d
    sub r9d, [dog_y]
    CLAMP_DOG r9d
    mov r12d, r8d                 ; dx
    mov r13d, r9d                 ; dy
    mov edi, [dog_x]
    add edi, r12d
    mov esi, [dog_y]
    add esi, r13d
    call is_box_blocked
    test eax, eax
    jz .ud_move
    xor r13d, r13d                ; x only
    mov edi, [dog_x]
    add edi, r12d
    mov esi, [dog_y]
    call is_box_blocked
    test eax, eax
    jz .ud_move
    mov r8d, r14d                 ; y only
    sub r8d, [dog_y]
    CLAMP_DOG r8d
    mov r13d, r8d
    xor r12d, r12d
    mov edi, [dog_x]
    mov esi, [dog_y]
    add esi, r13d
    call is_box_blocked
    test eax, eax
    jnz .ud_check_end             ; boxed in: wait
.ud_move:
    add [dog_x], r12d
    add [dog_y], r13d

.ud_check_end:
    ; the encounter is over once the walker is off screen and the dog
    ; isn't loose (it left with them, or animal control has it)
    cmp dword [dog_state], DOG_LOOSE
    je .ud_done
    mov eax, [walker_x]
    cmp eax, -60
    jl .ud_over
    cmp eax, WORLD_W + 60
    jg .ud_over
    jmp .ud_done
.ud_over:
    mov dword [dog_state], DOG_NONE
.ud_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_events(void) -- the police car, the walker and the dog
draw_events:
    push rbx
    push r12
    sub rsp, 8
    cmp dword [cop_active], 0
    je .de_walker
    ; the car, facing the way it drives; the light bar's red and blue
    ; swap every 8 frames (two palettes)
    lea rcx, [cop_pal_a]
    test dword [ticks], 8
    jz .de_cop_pal
    lea rcx, [cop_pal_b]
.de_cop_pal:
    mov edi, [cop_rect]
    mov esi, [cop_rect + 4]
    xor r8d, r8d
    cmp dword [cop_vel], 0
    je .de_cop_vertical
    lea rdx, [cop_sprite_h]       ; drawn facing east
    jg .de_cop_h
    mov r8d, SPR_MIRROR           ; going west
.de_cop_h:
    mov r9d, COP_W
    mov dword [spr_h], COP_H
    call draw_sprite_ex
    jmp .de_walker
.de_cop_vertical:
    lea rdx, [cop_sprite_v]       ; drawn facing south
    cmp dword [cop_vel + 4], 0
    jg .de_cop_v
    mov r8d, SPR_FLIP             ; going north
.de_cop_v:
    mov r9d, COP_H
    mov dword [spr_h], COP_W
    call draw_sprite_ex

.de_walker:
    cmp dword [dog_state], DOG_NONE
    je .de_done
    call draw_walker
    cmp dword [dog_state], DOG_GONE
    je .de_done
    ; the leash, while it holds
    cmp dword [dog_state], DOG_LEASHED
    jne .de_dog
    lea rdi, [back_fb]
    mov esi, [walker_x]
    add esi, WALKER_SIZE / 2
    mov edx, [walker_y]
    add edx, WALKER_SIZE / 2
    mov ecx, [dog_x]
    add ecx, DOG_W / 2
    mov r8d, [dog_y]
    add r8d, DOG_H / 2
    mov r9d, COLOR_LEASH
    call draw_line
.de_dog:
    ; which way: on the leash, the walker's way; loose, the way it
    ; moved since the last frame (kept if it didn't move sideways)
    mov eax, [dog_x]
    mov ecx, eax
    sub ecx, [dog_last_x]
    mov [dog_last_x], eax
    cmp dword [dog_state], DOG_LOOSE
    je .de_dog_loose
    mov dword [dog_face], 0
    cmp dword [walker_dx], 0
    jg .de_dog_frame
    mov dword [dog_face], SPR_MIRROR
    jmp .de_dog_frame
.de_dog_loose:
    test ecx, ecx
    jz .de_dog_frame
    mov dword [dog_face], 0
    jg .de_dog_frame
    mov dword [dog_face], SPR_MIRROR
.de_dog_frame:
    ; running frame: every 4 frames when loose, every 8 px on the leash
    mov eax, [ticks]
    shr eax, 2
    cmp dword [dog_state], DOG_LOOSE
    je .de_dog_f
    mov eax, [dog_x]
    shr eax, 3
.de_dog_f:
    and eax, 1
    shl eax, 8
    lea rdx, [dog_sprites]
    add rdx, rax
    lea rcx, [dog_pal_leashed]
    cmp dword [dog_state], DOG_LOOSE
    jne .de_dog_pal
    lea rcx, [dog_pal_loose]
.de_dog_pal:
    mov edi, [dog_x]
    sub edi, (SPRITE_SIZE - DOG_W) / 2
    mov esi, [dog_y]
    sub esi, 5                    ; the art's body sits in rows 4-11
    mov r8d, [dog_face]
    call draw_sprite
.de_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
