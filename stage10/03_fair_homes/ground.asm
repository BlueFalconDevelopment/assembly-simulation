; ground.asm -- blood, casings, pools: stamped into the background
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; Ground effects (drawing only)
; ============================================================

; u32 deco_hash(int a: edi, int b: esi) -> eax
; Scrambles two numbers (with the frame count) into pseudo-random bits
; for the look: which splat, where a casing lands. Never the game's
; RNG, so drawing can't change the fight.
deco_hash:
    imul eax, edi, 0x9E3779B1
    imul ecx, esi, 0x85EBCA77
    xor eax, ecx
    add eax, [ticks]
    mov ecx, eax
    shr ecx, 15
    xor eax, ecx
    imul eax, eax, 0x2C1B3C6D
    mov ecx, eax
    shr ecx, 13
    xor eax, ecx
    ret


; void stamp_blend(int x: edi, int y: esi, u8 *sprite: rdx,
;                  u32 *palette: rcx, int w: r8d, int h: r9d)
; Mixes a sprite 50/50 into bg_buffer, so it stays for the rest of the
; game and the ground shows through: half of each channel of both,
; added (the masks drop the bit that slid down from the next channel).
stamp_blend:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r10d, r10d                ; row
.sb_row:
    cmp r10d, r9d
    jge .sb_done
    lea r12d, [esi + r10d]
    cmp r12d, WORLD_H
    jae .sb_next_row
    xor r11d, r11d                ; col
.sb_col:
    cmp r11d, r8d
    jge .sb_next_row
    movzx eax, byte [rdx + r11]
    test eax, eax
    jz .sb_next_col
    mov eax, [rcx + rax*4]
    lea ebx, [edi + r11d]
    cmp ebx, WORLD_W
    jae .sb_next_col
    imul r13d, r12d, WORLD_W
    add r13d, ebx
    lea r14, [bg_buffer]
    mov r15d, [r14 + r13*4]
    shr r15d, 1
    and r15d, 0x7F7F7F
    shr eax, 1
    and eax, 0x7F7F7F
    add eax, r15d
    or eax, 0xFF000000
    mov [r14 + r13*4], eax
.sb_next_col:
    inc r11d
    jmp .sb_col
.sb_next_row:
    add rdx, r8
    inc r10d
    jmp .sb_row
.sb_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void stamp_splat(int cx: edi, int cy: esi) -- blood where a hit landed
stamp_splat:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    mov r12d, esi
    call deco_hash
    and eax, 3                    ; one of four shapes
    imul eax, eax, 12 * 12
    lea rdx, [splat_sprites]
    add rdx, rax
    lea edi, [ebx - 6]
    lea esi, [r12d - 6]
    lea rcx, [blood_pal]
    mov r8d, 12
    mov r9d, 12
    call stamp_blend
    add rsp, 8
    pop r12
    pop rbx
    ret


; void stamp_pool(int i: edi) -- a pool under a soldier whose fall ended
stamp_pool:
    push rbx
    push r12
    sub rsp, 8
    imul eax, edi, Soldier_size
    lea r12, [soldiers]
    add r12, rax
    mov esi, [r12 + Soldier.y]
    mov edi, [r12 + Soldier.x]
    call deco_hash
    and eax, 1
    shl eax, 8                    ; 16 * 16
    lea rdx, [pool_sprites]
    add rdx, rax
    mov edi, [r12 + Soldier.x]
    mov esi, [r12 + Soldier.y]
    add esi, 2
    lea rcx, [blood_pal]
    mov r8d, SPRITE_SIZE
    mov r9d, SPRITE_SIZE
    call stamp_blend
    add rsp, 8
    pop r12
    pop rbx
    ret


; void stamp_casing(int cx: edi, int cy: esi, int fx: edx)
; A spent casing near the shooter's feet: two brass pixels for a
; pistol, a red shell with a brass base for a shotgun. Scattered a
; few pixels by deco_hash, and drawn solid (it's metal).
stamp_casing:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    call deco_hash
    mov ecx, eax
    and ecx, 7
    sub ecx, 3
    add ebx, ecx                  ; x: -3..+4
    shr eax, 3
    and eax, 3
    add r12d, eax
    add r12d, 5                   ; y: at the feet, +5..+8
    mov eax, ebx
    cmp eax, WORLD_W - 2
    jae .sc_done
    cmp r12d, WORLD_H
    jae .sc_done
    imul ecx, r12d, WORLD_W
    add ecx, ebx
    lea rdx, [bg_buffer]
    mov eax, COLOR_BRASS
    cmp r13d, FX_SHOTGUN
    jne .sc_first
    mov eax, COLOR_SHELL
.sc_first:
    mov [rdx + rcx*4], eax
    mov eax, COLOR_BRASS_DARK
    cmp r13d, FX_SHOTGUN
    jne .sc_second
    mov eax, COLOR_BRASS
.sc_second:
    mov [rdx + rcx*4 + 4], eax
.sc_done:
    pop r13
    pop r12
    pop rbx
    ret
