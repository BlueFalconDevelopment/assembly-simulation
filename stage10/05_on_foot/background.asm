; background.asm -- the pre-drawn map, shadows
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; The neighborhood's look (drawing only)
; ============================================================

; void render_background(void)
; Draws the three generated layers into bg_buffer (ground, shadows,
; objects: see the header), then each site's walls in the colour of
; the gang that lives there this game (grey, and roofed over, if
; nobody does: 10.03). Once per game; every
; frame after that starts with a copy of bg_buffer.
render_background:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; layer 1: the ground
    lea rbx, [bg_ground]
    mov r12d, bg_ground_count
.rbg_ground:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, [rbx + 16]
    call fill_rect
    add rbx, 20
    dec r12d
    jnz .rbg_ground
    ; layer 2: shadows darken the ground under where things will stand
    lea rbx, [bg_shadows]
    mov r12d, bg_shadows_count
.rbg_shadow:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    call shade_rect
    add rbx, 16
    dec r12d
    jnz .rbg_shadow
    ; layer 3: the things themselves
    lea rbx, [bg_objects]
    mov r12d, bg_objects_count
.rbg_object:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, [rbx + 16]
    call fill_rect
    add rbx, 20
    dec r12d
    jnz .rbg_object
    ; the sites (10.03): each complex's walls in the colour of the gang
    ; living there this game. Nobody lives in the others: grey walls,
    ; the doorways walled up too (build_blockmap does the same), and a
    ; roof over the lobby
    ;   r13d site   r14d its colour   r15d walls or doors left
    xor r13d, r13d
.rbg_site:
    mov r14d, COLOR_TEAM0
    cmp [home], r13d
    je .rbg_walls
    mov r14d, COLOR_TEAM1
    cmp [home + 4], r13d
    je .rbg_walls
    mov r14d, COLOR_CLOSED
.rbg_walls:
    lea rax, [site_wall_idx]
    mov ecx, [rax + r13*8]
    mov r15d, [rax + r13*8 + 4]
    shl ecx, 4
    lea rbx, [site_walls]
    add rbx, rcx
.rbg_wall:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, r14d
    call fill_rect
    add rbx, 16
    dec r15d
    jnz .rbg_wall
    cmp r14d, COLOR_CLOSED
    jne .rbg_next
    ; closed: its doorways...
    lea rax, [site_door_idx]
    mov ecx, [rax + r13*8]
    mov r15d, [rax + r13*8 + 4]
    shl ecx, 4
    lea rbx, [site_doors]
    add rbx, rcx
.rbg_door:
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, COLOR_CLOSED
    call fill_rect
    add rbx, 16
    dec r15d
    jnz .rbg_door
    ; ...and a flat roof over the lobby, with a border
    mov eax, r13d
    shl eax, 4
    lea rbx, [site_lobbies]
    add rbx, rax
    lea rdi, [bg_fb]
    mov esi, [rbx]
    mov edx, [rbx + 4]
    mov ecx, [rbx + 8]
    mov r8d, [rbx + 12]
    mov r9d, COLOR_CLOSED_BORDER
    call fill_rect
    lea rdi, [bg_fb]
    mov esi, [rbx]
    add esi, 3
    mov edx, [rbx + 4]
    add edx, 3
    mov ecx, [rbx + 8]
    sub ecx, 6
    mov r8d, [rbx + 12]
    sub r8d, 6
    mov r9d, COLOR_CLOSED_ROOF
    call fill_rect
.rbg_next:
    inc r13d
    cmp r13d, NUM_SITES
    jb .rbg_site
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void shade_rect(FrameBuffer* fb: rdi, int x: esi, int y: edx,
;                 int w: ecx, int h: r8d)
; Darkens a rectangle to 5/8 of its brightness: a shadow. All three
; channels at once: (p >> 1) & 0x7F7F7F is half of each, and
; (p >> 3) & 0x1F1F1F an eighth -- the masks drop the bits that slid
; in from the channel above. Alpha is put back to 0xFF. Clipped like
; fill_rect.
shade_rect:
    push rbx
    push r12
    sub esi, [rdi + FrameBuffer.ox]   ; map -> buffer (9.01)
    sub edx, [rdi + FrameBuffer.oy]
    mov r10, [rdi + FrameBuffer.pixels]
    mov r11d, [rdi + FrameBuffer.pitch]
    lea ebx, [esi + ecx]          ; x end
    cmp ebx, [rdi + FrameBuffer.w]
    jle .sr_xe
    mov ebx, [rdi + FrameBuffer.w]
.sr_xe:
    lea r12d, [edx + r8d]         ; y end
    cmp r12d, [rdi + FrameBuffer.h]
    jle .sr_ye
    mov r12d, [rdi + FrameBuffer.h]
.sr_ye:
    test esi, esi
    jns .sr_xs
    xor esi, esi
.sr_xs:
    test edx, edx
    jns .sr_row
    xor edx, edx
.sr_row:
    cmp edx, r12d
    jge .sr_done
    mov eax, edx
    imul eax, r11d
    lea r9, [r10 + rax]           ; this row
    mov ecx, esi
.sr_col:
    cmp ecx, ebx
    jge .sr_next_row
    mov eax, [r9 + rcx*4]
    mov r8d, eax
    shr eax, 1
    and eax, 0x7F7F7F
    shr r8d, 3
    and r8d, 0x1F1F1F
    add eax, r8d
    or eax, 0xFF000000
    mov [r9 + rcx*4], eax
    inc ecx
    jmp .sr_col
.sr_next_row:
    inc edx
    jmp .sr_row
.sr_done:
    pop r12
    pop rbx
    ret


; void draw_moving_shadows(void) -- a small shadow at each visible
; soldier's feet (down-right of it: light from the top left), and
; under the walker, the dog and the police car. Drawing only.
draw_moving_shadows:
    push rbx
    push r12
    sub rsp, 8
    xor ebx, ebx
.dms_soldier:
    imul eax, ebx, Soldier_size
    lea r12, [soldiers]
    add r12, rax
    cmp dword [r12 + Soldier.health], 0
    jle .dms_next                 ; the fallen lie flat: no shadow
.dms_draw:
    ; spawn protection blinks the soldier; its shadow blinks with it
    lea rcx, [protect_timer]
    cmp dword [rcx + rbx*4], 0
    jle .dms_oval
    test dword [ticks], 4
    jnz .dms_next
.dms_oval:
    ; a small oval: 7 wide, 11 wide twice, 7 wide
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    add esi, 6
    mov edx, [r12 + Soldier.y]
    add edx, 13
    mov ecx, 7
    mov r8d, 1
    call shade_rect
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    add esi, 4
    mov edx, [r12 + Soldier.y]
    add edx, 14
    mov ecx, 11
    mov r8d, 2
    call shade_rect
    lea rdi, [back_fb]
    mov esi, [r12 + Soldier.x]
    add esi, 6
    mov edx, [r12 + Soldier.y]
    add edx, 16
    mov ecx, 7
    mov r8d, 1
    call shade_rect
.dms_next:
    inc ebx
    cmp ebx, TOTAL_SOLDIERS
    jl .dms_soldier

    cmp dword [cop_active], 0
    je .dms_walker
    lea rdi, [back_fb]
    mov esi, [cop_rect]
    add esi, 3
    mov edx, [cop_rect + 4]
    add edx, 3
    mov ecx, [cop_rect + 8]
    mov r8d, [cop_rect + 12]
    call shade_rect
.dms_walker:
    cmp dword [dog_state], DOG_NONE
    je .dms_done
    lea rdi, [back_fb]
    mov esi, [walker_x]
    add esi, 1
    mov edx, [walker_y]
    add edx, 7
    mov ecx, 11
    mov r8d, 4
    call shade_rect
    cmp dword [dog_state], DOG_GONE
    je .dms_done
    lea rdi, [back_fb]
    mov esi, [dog_x]
    add esi, 1
    mov edx, [dog_y]
    add edx, 6
    mov ecx, DOG_W
    mov r8d, 3
    call shade_rect
.dms_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
