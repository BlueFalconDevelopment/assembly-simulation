; meds.asm -- prescription weed, the dispensaries, and your health bar (10.12)
;
; The play test after 10.11: you need to see how many hits you can
; take, and a way to heal. So:
;
;   - a health bar over you (green, then yellow under half, red under a
;     quarter), and on the scoreboard "HP 120/150 (8 HITS)": how many
;     gang pistol hits you can take, after your body armor
;   - prescription weed: an orange pill bottle, white cap, a green leaf
;     on the label. Walk over it: +MED_HEAL health, up to your max (at
;     full health you leave it where it is). Gangsters don't want it
;   - MED_SHOPS medical marijuana dispensaries: businesses picked at
;     random each game, with a green cross painted on the roof and a
;     sign by the door. A bottle waits at the door; take it, and
;     another is in MED_RESTOCK ticks later
;   - a gangster killed or arrested drops one, MED_DROP_PCT% of the
;     time. A dropped bottle lasts MED_TTL ticks (it blinks at the end)
;
; All of it only in game mode, in a window (courier), and on your own
; RNG (player_rand): the soldiers' random numbers, and so the war, are
; what they'd be without it. Watch mode never gets here.

MED_SHOPS        equ 5
MAX_MEDS         equ 32         ; slots 0 .. MED_SHOPS-1: the shops' stock
MED_HEAL         equ 60
MED_DROP_PCT     equ 10         ; (20 left ~40 about: the war kills 3-4 a second)
MED_TTL          equ 2700       ; 45 s on the ground
MED_BLINK        equ 180        ; blinks for its last 3 s
MED_RESTOCK      equ 1800       ; 30 s
MED_REACH        equ 14         ; centre to centre, to pick it up
MED_W            equ 10
MED_H            equ 14
MED_SHOP_SPACING equ 500        ; px between dispensaries
MED_SHOP_TRIES   equ 400
MED_ROOF_FIND    equ 30         ; the building: a wall this close to the door

struc Med
    .x:    resd 1               ; the sprite's top left
    .y:    resd 1
    .ttl:  resd 1               ; 0: none; -1: a shop's, stays; else ticks left
    .pad:  resd 1
endstruc

section .data
    meds          times MAX_MEDS * Med_size db 0
    med_shops     dd 0                        ; how many there are
    med_shop_xy   times MED_SHOPS * 2 dd 0    ; their door spots
    med_restock   times MED_SHOPS dd 0        ; ticks until the next bottle
    hud_of        db "/"
    hud_hits      db " ("
    hud_hits_len  equ $ - hud_hits
    hud_hits2     db " HITS)"
    hud_hits2_len equ $ - hud_hits2
    COLOR_BAR_MID   equ 0xFF30E6FF          ; yellow
    COLOR_BAR_LOW   equ 0xFF3C3CE6          ; red
    COLOR_CROSS     equ 0xFF3CB43C          ; dispensary green
    COLOR_CROSS_BG  equ 0xFFF0F0F0
    COLOR_CROSS_RIM equ 0xFF303030

    ; the bottle, 10 x 14 (palette indices; 0 is clear)
    med_sprite:
    db 0, 1, 1, 1, 1, 1, 1, 1, 1, 0   ; .11111111.   the cap
    db 1, 2, 2, 2, 2, 2, 2, 2, 2, 1   ; 1222222221
    db 1, 2, 7, 7, 7, 7, 7, 7, 7, 1   ; 1277777771
    db 0, 1, 1, 1, 1, 1, 1, 1, 1, 0   ; .11111111.
    db 0, 1, 3, 3, 3, 3, 3, 6, 1, 0   ; .13333361.   orange
    db 0, 1, 4, 4, 4, 4, 4, 6, 1, 0   ; .14444461.   the label
    db 0, 1, 4, 4, 5, 4, 4, 6, 1, 0   ; .14454461.   ... and a leaf
    db 0, 1, 4, 5, 5, 5, 4, 6, 1, 0   ; .14555461.
    db 0, 1, 5, 5, 4, 5, 5, 6, 1, 0   ; .15545561.
    db 0, 1, 4, 4, 5, 4, 4, 6, 1, 0   ; .14454461.
    db 0, 1, 4, 4, 4, 4, 4, 6, 1, 0   ; .14444461.
    db 0, 1, 3, 3, 3, 3, 3, 6, 1, 0   ; .13333361.
    db 0, 1, 3, 3, 3, 3, 3, 6, 1, 0   ; .13333361.
    db 0, 0, 1, 1, 1, 1, 1, 1, 0, 0   ; ..111111..
    med_pal:
    dd 0, 0xFF1E1E1E, 0xFFF5F5F5, 0xFF1E8CE6, 0xFFE6F0F5, 0xFF2AA03C
    dd 0xFF146AB4, 0xFFC8C8C8

section .text

; the Med at slot %1 (a register) -> r10
%macro MED_AT 1
    imul r10d, %1, Med_size
    lea rax, [meds]
    add r10, rax
%endmacro


; void bg_rect(x: edi, y: esi, w: edx, h: ecx, colour: r8d) -- a solid
; rectangle painted into bg_buffer, clipped to the map (drawing only)
bg_rect:
    push rbx
    lea r9d, [esi + ecx]          ; bottom
    lea r10d, [edi + edx]         ; right
.br_row:
    cmp esi, r9d
    jge .br_done
    cmp esi, WORLD_H
    jae .br_next_row              ; unsigned: above the top too
    mov r11d, edi
.br_col:
    cmp r11d, r10d
    jge .br_next_row
    cmp r11d, WORLD_W
    jae .br_next_col
    imul eax, esi, WORLD_W
    add eax, r11d
    lea rbx, [bg_buffer]
    mov [rbx + rax*4], r8d
.br_next_col:
    inc r11d
    jmp .br_col
.br_next_row:
    inc esi
    jmp .br_row
.br_done:
    pop rbx
    ret


; void paint_cross(cx: edi, cy: esi, size: edx) -- a green cross on a
; white square with a dark rim, centred on (cx, cy), into bg_buffer
paint_cross:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx                 ; size
    mov r15d, edx
    shr r15d, 1                   ; half
    ; the rim, then the white inside it
    mov edi, r12d
    sub edi, r15d
    mov esi, r13d
    sub esi, r15d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, COLOR_CROSS_RIM
    call bg_rect
    mov edi, r12d
    sub edi, r15d
    inc edi
    mov esi, r13d
    sub esi, r15d
    inc esi
    lea edx, [r14d - 2]
    lea ecx, [r14d - 2]
    mov r8d, COLOR_CROSS_BG
    call bg_rect
    ; the cross: arms a third of the size thick, 2 px in from the rim
    mov eax, r14d
    xor edx, edx
    mov ecx, 3
    div ecx
    mov ebx, eax                  ; thickness
    mov edi, r12d
    sub edi, r15d
    add edi, 2
    mov esi, ebx
    shr esi, 1
    neg esi
    add esi, r13d
    lea edx, [r14d - 4]
    mov ecx, ebx
    mov r8d, COLOR_CROSS
    call bg_rect                  ; across
    mov edi, ebx
    shr edi, 1
    neg edi
    add edi, r12d
    mov esi, r13d
    sub esi, r15d
    add esi, 2
    mov edx, ebx
    lea ecx, [r14d - 4]
    mov r8d, COLOR_CROSS
    call bg_rect                  ; down
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void decorate_shop(door x: edi, door y: esi) -- a cross on the roof of
; the building this door belongs to (the wall at least 14 x 14 nearest
; the door, if it's within MED_ROOF_FIND), and a small one by the door
;   r12d/r13d the door's centre   r14 best wall   r15d its distance^2
decorate_shop:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r12d, [edi + SOLDIER_SIZE / 2]
    lea r13d, [esi + SOLDIER_SIZE / 2]
    ; the sign by the door, first
    lea edi, [r12d + 12]
    lea esi, [r13d - 6]
    mov edx, 10
    call paint_cross
    xor r14d, r14d
    mov r15d, MED_ROOF_FIND * MED_ROOF_FIND + 1
    lea rbx, [map_walls]
    xor ecx, ecx
.ds_wall:
    cmp ecx, map_walls_count
    jae .ds_found
    cmp dword [rbx + Obstacle.w], 14
    jl .ds_next
    cmp dword [rbx + Obstacle.h], 14
    jl .ds_next
    ; distance from the door's centre to the rectangle
    xor eax, eax
    mov edx, [rbx + Obstacle.x]
    sub edx, r12d
    cmovg eax, edx                ; left of it
    mov edx, r12d
    sub edx, [rbx + Obstacle.x]
    sub edx, [rbx + Obstacle.w]
    cmp edx, eax
    cmovg eax, edx                ; right of it
    imul eax, eax
    xor r8d, r8d
    mov edx, [rbx + Obstacle.y]
    sub edx, r13d
    cmovg r8d, edx
    mov edx, r13d
    sub edx, [rbx + Obstacle.y]
    sub edx, [rbx + Obstacle.h]
    cmp edx, r8d
    cmovg r8d, edx
    imul r8d, r8d
    add eax, r8d
    cmp eax, r15d
    jge .ds_next
    mov r15d, eax
    mov r14, rbx
.ds_next:
    add rbx, Obstacle_size
    inc ecx
    jmp .ds_wall
.ds_found:
    test r14, r14
    jz .ds_done                   ; no building close enough: the sign only
    ; the roof cross: 6/10 of the short side, 10 .. 28 px
    mov eax, [r14 + Obstacle.w]
    mov ecx, [r14 + Obstacle.h]
    cmp ecx, eax
    cmovl eax, ecx
    imul eax, eax, 6
    xor edx, edx
    mov ecx, 10
    div ecx
    CLAMP_TO_RANGE eax, 10, 28
    mov edx, eax
    mov edi, [r14 + Obstacle.w]
    shr edi, 1
    add edi, [r14 + Obstacle.x]
    mov esi, [r14 + Obstacle.h]
    shr esi, 1
    add esi, [r14 + Obstacle.y]
    call paint_cross
.ds_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void meds_start(void) -- game mode, in a window, once (player_start):
; the dispensaries, picked on your RNG, and painted
;   ebx shops so far   r12d tries left   r13d/r14d the door
meds_start:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor ebx, ebx
.ms_shop:
    cmp ebx, MED_SHOPS
    jae .ms_paint
    mov r12d, MED_SHOP_TRIES
.ms_try:
    dec r12d
    js .ms_paint                  ; no room for more
    mov edi, biz_points_count
    call player_rand
    lea rcx, [biz_points]
    mov r13d, [rcx + rax*8]
    mov r14d, [rcx + rax*8 + 4]
    xor ecx, ecx
.ms_spacing:
    cmp ecx, ebx
    jae .ms_take
    mov eax, [med_shop_xy + rcx*8]
    sub eax, r13d
    imul eax, eax
    mov edx, [med_shop_xy + rcx*8 + 4]
    sub edx, r14d
    imul edx, edx
    add eax, edx
    cmp eax, MED_SHOP_SPACING * MED_SHOP_SPACING
    jl .ms_try
    inc ecx
    jmp .ms_spacing
.ms_take:
    mov [med_shop_xy + rbx*8], r13d
    mov [med_shop_xy + rbx*8 + 4], r14d
    inc ebx
    jmp .ms_shop
.ms_paint:
    mov [med_shops], ebx
    xor r15d, r15d
.ms_deco:
    cmp r15d, ebx
    jae .ms_done
    mov edi, [med_shop_xy + r15*8]
    mov esi, [med_shop_xy + r15*8 + 4]
    call decorate_shop
    inc r15d
    jmp .ms_deco
.ms_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void meds_shift(void) -- a new shift: the dropped bottles are gone,
; and every dispensary has one at the door
meds_shift:
    lea rdi, [meds]
    xor eax, eax
    mov ecx, MAX_MEDS * Med_size / 4
    cld
    rep stosd
    xor ecx, ecx
.mf_shop:
    cmp ecx, [med_shops]
    jae .mf_done
    MED_AT ecx
    mov eax, [med_shop_xy + rcx*8]
    add eax, (SOLDIER_SIZE - MED_W) / 2
    mov [r10 + Med.x], eax
    mov eax, [med_shop_xy + rcx*8 + 4]
    add eax, (SOLDIER_SIZE - MED_H) / 2
    mov [r10 + Med.y], eax
    mov dword [r10 + Med.ttl], -1
    mov dword [med_restock + rcx*4], 0
    inc ecx
    jmp .mf_shop
.mf_done:
    ret


; void med_drop(int soldier: edi) -- he was killed or arrested: now
; and then, a bottle where he fell (on your RNG; only in a shift)
med_drop:
    push rbx
    mov ebx, edi
    cmp dword [player_on], 0
    je .md_done
    cmp ebx, PLAYER
    je .md_done
    mov edi, 100
    call player_rand
    cmp eax, MED_DROP_PCT
    jae .md_done
    ; a free slot, after the shops'
    mov ecx, MED_SHOPS
.md_slot:
    cmp ecx, MAX_MEDS
    jae .md_done                  ; the street's full of them already
    MED_AT ecx
    cmp dword [r10 + Med.ttl], 0
    je .md_take
    inc ecx
    jmp .md_slot
.md_take:
    imul eax, ebx, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    mov eax, [rcx + Soldier.x]
    add eax, (SOLDIER_SIZE - MED_W) / 2
    mov [r10 + Med.x], eax
    mov eax, [rcx + Soldier.y]
    add eax, (SOLDIER_SIZE - MED_H) / 2
    mov [r10 + Med.y], eax
    mov dword [r10 + Med.ttl], MED_TTL
.md_done:
    pop rbx
    ret


; void update_meds(void) -- once a tick in a shift (update_player):
; bottles age, dispensaries restock, and you pick them up
;   ebx slot   r12 you
update_meds:
    push rbx
    push r12
    sub rsp, 8
    lea r12, [soldiers + PLAYER * Soldier_size]
    xor ebx, ebx
.um_slot:
    cmp ebx, MAX_MEDS
    jae .um_done
    MED_AT ebx
    mov eax, [r10 + Med.ttl]
    test eax, eax
    jnz .um_there
    ; none: a dispensary restocks
    cmp ebx, [med_shops]
    jae .um_next
    dec dword [med_restock + rbx*4]
    jg .um_next
    mov dword [r10 + Med.ttl], -1
    jmp .um_reach
.um_there:
    jl .um_reach                  ; a shop's: it stays (the flags: test eax)
    dec dword [r10 + Med.ttl]
    jz .um_next                   ; gone
.um_reach:
    ; you, alive, close enough, and not at full health
    cmp dword [r12 + Soldier.health], 0
    jle .um_next
    mov eax, [r12 + Soldier.health]
    cmp eax, [player_max_hp]
    jge .um_next
    mov eax, [r10 + Med.x]
    add eax, MED_W / 2 - SOLDIER_SIZE / 2
    sub eax, [r12 + Soldier.x]
    imul eax, eax
    mov ecx, [r10 + Med.y]
    add ecx, MED_H / 2 - SOLDIER_SIZE / 2
    sub ecx, [r12 + Soldier.y]
    imul ecx, ecx
    add eax, ecx
    cmp eax, MED_REACH * MED_REACH
    jg .um_next
    ; healed
    mov eax, [r12 + Soldier.health]
    add eax, MED_HEAL
    cmp eax, [player_max_hp]
    cmovg eax, [player_max_hp]
    mov [r12 + Soldier.health], eax
    mov dword [r10 + Med.ttl], 0
    cmp ebx, [med_shops]
    jae .um_next
    mov dword [med_restock + rbx*4], MED_RESTOCK
.um_next:
    inc ebx
    jmp .um_slot
.um_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void draw_meds(void) -- the bottles (drawing only; a dropped one blinks
; for its last MED_BLINK ticks)
draw_meds:
    push rbx
    push r12
    sub rsp, 8
    cmp dword [courier], 0
    je .dm_done
    xor ebx, ebx
.dm_slot:
    cmp ebx, MAX_MEDS
    jae .dm_done
    MED_AT ebx
    mov eax, [r10 + Med.ttl]
    test eax, eax
    jz .dm_next
    jl .dm_draw
    cmp eax, MED_BLINK
    jg .dm_draw
    test dword [ticks], 8
    jnz .dm_next
.dm_draw:
    mov edi, [r10 + Med.x]
    mov esi, [r10 + Med.y]
    lea rdx, [med_sprite]
    lea rcx, [med_pal]
    xor r8d, r8d
    mov r9d, MED_W
    mov dword [spr_h], MED_H
    call draw_sprite_ex
.dm_next:
    inc ebx
    jmp .dm_slot
.dm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void draw_player_bar(void) -- your health, over your head, in a shift
; (drawing only): green, yellow under half, red under a quarter
draw_player_bar:
    push rbx
    push r12
    sub rsp, 8
    cmp dword [player_on], 0
    je .pb_done
    lea r12, [soldiers + PLAYER * Soldier_size]
    cmp dword [r12 + Soldier.health], 0
    jle .pb_done
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
    imul eax, eax, SOLDIER_SIZE + 4
    xor edx, edx
    div dword [player_max_hp]
    mov ebx, eax                  ; the bar's length
    test ebx, ebx
    jz .pb_done
    ; its colour, from health * 4 against the max
    mov eax, [r12 + Soldier.health]
    shl eax, 2
    mov r9d, COLOR_BAR_LOW
    cmp eax, [player_max_hp]
    jl .pb_colour
    mov r9d, COLOR_BAR_MID
    shr eax, 1
    cmp eax, [player_max_hp]
    jl .pb_colour
    mov r9d, COLOR_BAR
.pb_colour:
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    sub esi, 2
    mov edx, [r12 + Soldier.y]
    sub edx, 7
    mov ecx, ebx
    mov r8d, 3
    call fill_rect
.pb_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; append_hp(dst: rdi) -> rdi: "120/150 (8 HITS)" -- your health, your
; max, and how many gang pistol hits (PISTOL_DAMAGE, after your armor)
; that is, rounded up
append_hp:
    push rbx
    mov esi, [soldiers + PLAYER * Soldier_size + Soldier.health]
    mov ebx, esi
    call append_uint
    mov byte [rdi], '/'
    inc rdi
    mov esi, [player_max_hp]
    call append_uint
    lea rsi, [hud_hits]
    mov edx, hud_hits_len
    call append_bytes
    mov eax, PISTOL_DAMAGE
    imul eax, [player_armor]
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, eax
    test ecx, ecx
    jnz .ah_hit
    mov ecx, 1
.ah_hit:
    lea eax, [ebx + ecx - 1]
    xor edx, edx
    div ecx
    mov esi, eax
    call append_uint
    lea rsi, [hud_hits2]
    mov edx, hud_hits2_len
    call append_bytes
    pop rbx
    ret
