; draw_sprites.asm -- drawing sprites, soldiers, the walker
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; Sprites (drawing only)
; ============================================================

; void draw_sprite(int x: edi, int y: esi, u8 *sprite: rdx,
;                  u32 *palette: rcx, int flags: r8d)
; A 16x16 sprite: draw_sprite_ex with the size filled in.
draw_sprite:
    mov r9d, SPRITE_SIZE
    mov dword [spr_h], SPRITE_SIZE
; void draw_sprite_ex(x: edi, y: esi, sprite: rdx, palette: rcx,
;                     flags: r8d, width: r9d; height in spr_h)
; Palette indices (one byte a pixel, row by row) -> back_buffer,
; skipping index 0 and any colour that's 0 (a hidden weapon), clipped
; to the view. x, y are map coordinates (9.01). SPR_MIRROR reads each row right to left; SPR_FLIP
; reads the rows bottom to top.
;   r10d row   r11d col   ebx pixel x   r12d pixel y   r13d src index
draw_sprite_ex:
    push rbx
    push r12
    push r13
    push r14
    sub edi, [back_fb + FrameBuffer.ox]
    sub esi, [back_fb + FrameBuffer.oy]
    xor r10d, r10d
.ds_row:
    cmp r10d, [spr_h]
    jge .ds_done
    lea r12d, [esi + r10d]
    cmp r12d, [back_fb + FrameBuffer.h]
    jae .ds_next_row              ; unsigned: above the top too
    mov r14d, r10d                ; source row
    test r8d, SPR_FLIP
    jz .ds_row_ok
    mov r14d, [spr_h]
    dec r14d
    sub r14d, r10d
.ds_row_ok:
    imul r14d, r9d                ; its first byte
    xor r11d, r11d
.ds_col:
    cmp r11d, r9d
    jge .ds_next_row
    mov r13d, r11d                ; source column
    test r8d, SPR_MIRROR
    jz .ds_col_ok
    mov r13d, r9d
    dec r13d
    sub r13d, r11d
.ds_col_ok:
    add r13d, r14d
    movzx eax, byte [rdx + r13]
    test eax, eax
    jz .ds_next_col
    mov eax, [rcx + rax*4]
    test eax, eax
    jz .ds_next_col
    lea ebx, [edi + r11d]
    cmp ebx, [back_fb + FrameBuffer.w]
    jae .ds_next_col
    imul r13d, r12d, VIEW_MAX_W
    add r13d, ebx
    push rdx
    lea rdx, [back_buffer]
    mov [rdx + r13*4], eax
    pop rdx
.ds_next_col:
    inc r11d
    jmp .ds_col
.ds_next_row:
    inc r10d
    jmp .ds_row
.ds_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_soldier(int i: edi)
; Turn to face the way this soldier moved since the last frame, count
; the pixels walked (they pick the walk frame), build its palette,
; and draw it.
draw_soldier:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    imul eax, ebx, Soldier_size
    lea r12, [soldiers]
    add r12, rax

    ; ---- facing and walk ----
    lea r8, [sprite_seen]
    cmp dword [r8 + rbx*4], 0
    jne .dsol_seen
    mov dword [r8 + rbx*4], 1
    mov eax, [r12 + Soldier.team] ; first sight: face the enemy's home
    mov eax, [fwd_sign + rax*4]
    mov ecx, 2                    ; E
    test eax, eax
    jg .dsol_face0
    mov ecx, 6                    ; W
.dsol_face0:
    lea r8, [sprite_facing]
    mov [r8 + rbx*4], ecx
    jmp .dsol_store
.dsol_seen:
    lea r8, [sprite_last_x]
    mov r13d, [r12 + Soldier.x]
    sub r13d, [r8 + rbx*4]        ; dx
    lea r8, [sprite_last_y]
    mov r14d, [r12 + Soldier.y]
    sub r14d, [r8 + rbx*4]        ; dy
    mov eax, r13d
    neg eax
    cmovs eax, r13d               ; |dx|
    mov r15d, r14d
    neg r15d
    cmovs r15d, r14d              ; |dy|
    cmp eax, TELEPORT
    jg .dsol_store                ; respawned: no step to face
    cmp r15d, TELEPORT
    jg .dsol_store
    mov ecx, eax
    add ecx, r15d
    jz .dsol_store                ; didn't move: keep facing, frame
    lea r8, [sprite_walk]
    add [r8 + rbx*4], ecx
    ; octant: mostly sideways, mostly up/down, or diagonal
    lea ecx, [r15d * 2]
    cmp eax, ecx
    jle .dsol_not_x
    mov ecx, 2                    ; E
    test r13d, r13d
    jg .dsol_set
    mov ecx, 6                    ; W
    jmp .dsol_set
.dsol_not_x:
    lea ecx, [eax * 2]
    cmp r15d, ecx
    jle .dsol_diag
    mov ecx, 4                    ; S
    test r14d, r14d
    jg .dsol_set
    xor ecx, ecx                  ; N
    jmp .dsol_set
.dsol_diag:
    test r13d, r13d
    jle .dsol_diag_w
    mov ecx, 3                    ; SE
    test r14d, r14d
    jg .dsol_set
    mov ecx, 1                    ; NE
    jmp .dsol_set
.dsol_diag_w:
    mov ecx, 5                    ; SW
    test r14d, r14d
    jg .dsol_set
    mov ecx, 7                    ; NW
.dsol_set:
    lea r8, [sprite_facing]
    mov [r8 + rbx*4], ecx
.dsol_store:
    lea r8, [sprite_last_x]
    mov eax, [r12 + Soldier.x]
    mov [r8 + rbx*4], eax
    lea r8, [sprite_last_y]
    mov eax, [r12 + Soldier.y]
    mov [r8 + rbx*4], eax

    ; ---- palette ----
    lea rdi, [pal_buf]
    lea rcx, [hit_flash]
    cmp dword [rcx + rbx*4], 0
    jle .dsol_colours
    ; hit: a white silhouette
    mov dword [rdi], 0
    mov eax, COLOR_FLASH
    mov ecx, 1
.dsol_white:
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, PAL_SIZE
    jb .dsol_white
    jmp .dsol_draw
.dsol_colours:
    mov dword [rdi], 0
    mov dword [rdi + PAL_HAIR*4], COLOR_HAIR
    mov eax, [r12 + Soldier.team]
    imul eax, eax, 12
    lea rcx, [gang_colours]
    add rcx, rax
    mov eax, [rcx]
    mov [rdi + PAL_SHIRT*4], eax
    mov [rdi + PAL_CHAIN*4], eax  ; no chain: it's just shirt
    mov eax, [rcx + 4]
    mov [rdi + PAL_SHADE*4], eax
    mov eax, [rcx + 8]
    mov [rdi + PAL_BAND*4], eax
    cmp ebx, SQUAD
    jb .dsol_regular
    cmp ebx, PLAYER
    ja .dsol_regular              ; (10.14: the Bikers wear their own)
    mov dword [rdi + PAL_BAND*4], COLOR_GOLD    ; the Big Homie
    mov dword [rdi + PAL_CHAIN*4], COLOR_GOLD
.dsol_regular:
    mov eax, ebx
    xor edx, edx
    mov ecx, 3
    div ecx
    lea rcx, [skin_tones]
    mov eax, [rcx + rdx*4]
    mov [rdi + PAL_SKIN*4], eax
    mov dword [rdi + PAL_PANTS*4], COLOR_PANTS
    mov dword [rdi + PAL_SHOES*4], COLOR_SHOES
    ; the weapon in hand: only its pixels get a colour
    mov dword [rdi + PAL_GUN*4], 0
    mov dword [rdi + PAL_BARREL*4], 0
    mov dword [rdi + PAL_KNIFE*4], 0
    mov eax, [r12 + Soldier.weapon]
    cmp eax, WEAPON_KNIFE
    jne .dsol_gun
    mov dword [rdi + PAL_KNIFE*4], COLOR_KNIFE
    jmp .dsol_draw
.dsol_gun:
    mov dword [rdi + PAL_GUN*4], COLOR_GUN
    cmp eax, WEAPON_SHOTGUN
    jne .dsol_draw
    mov dword [rdi + PAL_BARREL*4], COLOR_BARREL

.dsol_draw:
    ; fallen (and the hit flash is over): lying on the ground (8.04)
    cmp dword [r12 + Soldier.health], 0
    jg .dsol_standing
    lea r8, [hit_flash]
    cmp dword [r8 + rbx*4], 0
    jg .dsol_standing
    lea rdx, [dead_sprite]
    mov r8d, ebx
    and r8d, SPR_MIRROR           ; half of them fall the other way
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    lea rcx, [pal_buf]
    call draw_sprite
    jmp .dsol_done
.dsol_standing:
    lea r8, [sprite_facing]
    mov eax, [r8 + rbx*4]
    lea r8, [facing_pose]
    movzx ecx, byte [r8 + rax*2]      ; pose
    movzx r13d, byte [r8 + rax*2 + 1] ; mirrored?
    lea r8, [sprite_walk]
    mov eax, [r8 + rbx*4]
    shr eax, 3                    ; a new walk frame every 8 px
    and eax, 1
    lea eax, [rcx*2 + rax]        ; sprite number
    shl eax, 8                    ; x 256 bytes
    lea rdx, [soldier_sprites]
    add rdx, rax
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    lea rcx, [pal_buf]
    mov r8d, r13d
    call draw_sprite
.dsol_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_walker(void) -- the dog walker, as a sprite: facing the
; way they walk, a walk frame every 8 px, no bandana, no weapon
draw_walker:
    lea rdi, [pal_buf]
    mov dword [rdi], 0
    mov dword [rdi + PAL_HAIR*4], COLOR_HAIR
    mov dword [rdi + PAL_BAND*4], COLOR_HAIR
    mov dword [rdi + PAL_SKIN*4], 0xFFA0C3EB
    mov dword [rdi + PAL_SHIRT*4], COLOR_WALKER
    mov dword [rdi + PAL_CHAIN*4], COLOR_WALKER
    mov dword [rdi + PAL_SHADE*4], COLOR_WALKER_SHADE
    mov dword [rdi + PAL_PANTS*4], COLOR_PANTS
    mov dword [rdi + PAL_SHOES*4], COLOR_SHOES
    mov dword [rdi + PAL_GUN*4], 0
    mov dword [rdi + PAL_BARREL*4], 0
    mov dword [rdi + PAL_KNIFE*4], 0
    mov eax, [walker_x]
    shr eax, 3
    and eax, 1
    add eax, 2 * 2                ; pose E (2), walk frame
    shl eax, 8
    lea rdx, [soldier_sprites]
    add rdx, rax
    xor r8d, r8d
    cmp dword [walker_dx], 0
    jg .dw_dir
    mov r8d, 1                    ; walking west: mirrored
.dw_dir:
    mov edi, [walker_x]
    sub edi, (SPRITE_SIZE - WALKER_SIZE) / 2
    mov esi, [walker_y]
    sub esi, SPRITE_SIZE - WALKER_SIZE
    lea rcx, [pal_buf]
    sub rsp, 8
    call draw_sprite
    add rsp, 8
    ret
