; lighting.asm -- day and night
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; Day and night (drawing only)
; ============================================================

; int tod_minute(void) -> eax: minute of the day now, 0..1439
tod_minute:
    mov eax, [ticks]
    xor edx, edx
    mov ecx, MIN_TICKS
    div ecx
    add eax, [tod_start]
    xor edx, edx
    mov ecx, 1440
    div ecx
    mov eax, edx
    ret


; append_time_of_day(dst: rdi) -> rdi: "9:40 PM"
append_time_of_day:
    push rbx
    push r12
    sub rsp, 8
    call tod_minute
    xor edx, edx
    mov ecx, 60
    div ecx                       ; eax = hour, edx = minute
    mov r12d, edx
    mov ebx, eax                  ; 0..23
    xor edx, edx
    mov ecx, 12
    div ecx                       ; edx = hour % 12
    mov esi, edx
    test esi, esi
    jnz .at_h
    mov esi, 12
.at_h:
    call append_uint
    mov byte [rdi], ':'
    inc rdi
    cmp r12d, 10
    jae .at_mm
    mov byte [rdi], '0'
    inc rdi
.at_mm:
    mov esi, r12d
    call append_uint
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [am_pm]
    cmp ebx, 12
    jb .at_ampm
    add rsi, 2
.at_ampm:
    mov edx, 2
    call append_bytes
    add rsp, 8
    pop r12
    pop rbx
    ret


; make_kernel(u8 *out: rdi, int r: esi, int peak: edx)
; A round light: peak * (1 - d^2 / r^2) for d < r, else 0, over a
; (2r+1)^2 square. Smooth falloff, no square root.
make_kernel:
    push rbx
    push r12
    push r13
    mov r8d, esi
    imul r8d, esi                 ; r^2
    mov r9d, esi
    neg r9d                       ; dy
.mk_row:
    cmp r9d, esi
    jg .mk_done
    mov r10d, esi
    neg r10d                      ; dx
.mk_col:
    cmp r10d, esi
    jg .mk_next_row
    mov eax, r9d
    imul eax, r9d
    mov ecx, r10d
    imul ecx, r10d
    add eax, ecx                  ; d^2
    xor ebx, ebx
    cmp eax, r8d
    jge .mk_store
    mov ebx, r8d
    sub ebx, eax
    imul ebx, edx
    mov eax, ebx
    push rdx
    xor edx, edx
    div r8d
    pop rdx
    mov ebx, eax
.mk_store:
    mov [rdi], bl
    inc rdi
    inc r10d
    jmp .mk_col
.mk_next_row:
    inc r9d
    jmp .mk_row
.mk_done:
    pop r13
    pop r12
    pop rbx
    ret


; void init_lighting(void) -- once, when the window opens
init_lighting:
    sub rsp, 8
    cmp dword [tod_start], 0
    jge .il_kernels
    ; no TIME=: start at a minute scrambled from the game's seed
    mov rax, [game_seed]
    mov edi, eax
    shr rax, 32
    mov esi, eax
    call deco_hash
    xor edx, edx
    mov ecx, 1440
    div ecx
    mov [tod_start], edx
.il_kernels:
    lea rdi, [kern_lamp]
    mov esi, LAMP_R
    mov edx, 230
    call make_kernel
    lea rdi, [kern_mid]
    mov esi, MID_R
    mov edx, 200
    call make_kernel
    lea rdi, [kern_small]
    mov esi, SMALL_R
    mov edx, 240
    call make_kernel
    add rsp, 8
    ret


; void light_tables(void)
; The ambient colour for this minute (interpolated between keyframes),
; and per light level L: scale = ambient + (lamp - ambient) * L / 255,
; never darker than ambient (so daylight isn't dimmed by "lamps").
light_tables:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    call tod_minute
    mov r12d, eax
    lea rbx, [tod_keys]
.lt_find:
    cmp r12d, [rbx + 16]          ; before the next key?
    jl .lt_found
    add rbx, 16
    jmp .lt_find
.lt_found:
    ; t = (m - m0) * 256 / (m1 - m0)
    mov eax, r12d
    sub eax, [rbx]
    shl eax, 8
    mov ecx, [rbx + 16]
    sub ecx, [rbx]
    xor edx, edx
    div ecx
    mov r13d, eax                 ; 0..255
    xor ecx, ecx
.lt_chan:
    mov eax, [rbx + 20 + rcx*4]   ; next key's channel
    sub eax, [rbx + 4 + rcx*4]
    imul eax, r13d
    sar eax, 8
    add eax, [rbx + 4 + rcx*4]
    lea rdx, [ambient]
    mov [rdx + rcx*4], eax
    inc ecx
    cmp ecx, 3
    jb .lt_chan
    ; lamps come on when it gets darker than about 3/4 daylight
    mov eax, [ambient]
    add eax, [ambient + 4]
    add eax, [ambient + 8]
    xor ecx, ecx
    cmp eax, 580
    setl cl
    mov [lamps_on], ecx
    ; the tables
    lea rdi, [light_tab]
    xor r8d, r8d                  ; level
.lt_level:
    xor r9d, r9d                  ; channel
.lt_tab_chan:
    lea rdx, [ambient]
    mov eax, [rdx + r9*4]         ; ambient
    mov r10d, LIT_R
    cmp r9d, 1
    jb .lt_lit
    mov r10d, LIT_G
    je .lt_lit
    mov r10d, LIT_B
.lt_lit:
    sub r10d, eax                 ; lamp - ambient
    jle .lt_store                 ; lamps no brighter: ambient
    imul r10d, r8d
    mov r11d, eax
    mov eax, r10d
    xor edx, edx
    mov ecx, 255
    div ecx
    add eax, r11d
.lt_store:
    mov [rdi], eax
    add rdi, 4
    inc r9d
    cmp r9d, 3
    jb .lt_tab_chan
    inc r8d
    cmp r8d, 256
    jb .lt_level
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; stamp_light(int x: edi, int y: esi, u8 *kernel: rdx, int r: ecx)
; Adds a kernel to the light map, centred on pixel (x, y), saturating
; at 255.
stamp_light:
    push rbx
    push r12
    push r13
    push r14
    sub edi, [back_fb + FrameBuffer.ox]   ; map -> view (9.01)
    sub esi, [back_fb + FrameBuffer.oy]
    sar edi, 1                    ; pixels -> light-map cells
    sar esi, 1
    lea r8d, [ecx * 2 + 1]        ; kernel side
    mov r9d, esi
    sub r9d, ecx                  ; first row
    xor r10d, r10d                ; kernel row
.sl_row:
    cmp r10d, r8d
    jge .sl_done
    lea r11d, [r9d + r10d]        ; map row
    cmp r11d, LM_H
    jae .sl_next_row
    imul r12d, r11d, LM_W
    xor r13d, r13d                ; kernel col
.sl_col:
    cmp r13d, r8d
    jge .sl_next_row
    lea ebx, [edi + r13d]
    sub ebx, ecx                  ; map col
    cmp ebx, LM_W
    jae .sl_next_col
    movzx eax, byte [rdx + r13]
    test eax, eax
    jz .sl_next_col
    lea r14, [lightmap]
    add ebx, r12d
    movzx r11d, byte [r14 + rbx]
    add eax, r11d
    cmp eax, 255
    jbe .sl_store
    mov eax, 255
.sl_store:
    mov [r14 + rbx], al
    lea r11d, [r9d + r10d]        ; (restore the map row)
.sl_next_col:
    inc r13d
    jmp .sl_col
.sl_next_row:
    add rdx, r8
    inc r10d
    jmp .sl_row
.sl_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; light_rect(int x: edi, int y: esi, int w: edx, int h: ecx, int v: r8d)
; Adds v to a rectangle of the light map (a lit room), saturating.
; Map coordinates; the parts outside the view are skipped (9.01).
;   ebx row   r12d col   r13 this row's first cell
light_rect:
    push rbx
    push r12
    push r13
    sub edi, [back_fb + FrameBuffer.ox]   ; map -> view
    sub esi, [back_fb + FrameBuffer.oy]
    sar edi, 1                    ; pixels -> cells
    sar esi, 1
    sar edx, 1
    sar ecx, 1
    xor ebx, ebx
.lr_row:
    cmp ebx, ecx
    jge .lr_done
    lea eax, [esi + ebx]
    cmp eax, LM_H
    jae .lr_next_row              ; unsigned: above the top too
    imul eax, eax, LM_W
    lea r13, [lightmap]
    add r13, rax
    xor r12d, r12d
.lr_col:
    cmp r12d, edx
    jge .lr_next_row
    lea eax, [edi + r12d]
    cmp eax, LM_W
    jae .lr_next_col
    movzx eax, byte [r13 + rax]
    add eax, r8d
    cmp eax, 255
    jbe .lr_store
    mov eax, 255
.lr_store:
    lea r9d, [edi + r12d]
    mov [r13 + r9], al
.lr_next_col:
    inc r12d
    jmp .lr_col
.lr_next_row:
    inc ebx
    jmp .lr_row
.lr_done:
    pop r13
    pop r12
    pop rbx
    ret


; void light_scene(void) -- the whole lighting pass for this frame
light_scene:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call light_tables
    ; full daylight: nothing to do
    cmp dword [ambient], 256
    jl .ls_go
    cmp dword [ambient + 4], 256
    jl .ls_go
    cmp dword [ambient + 8], 256
    jge .ls_done
.ls_go:
    ; ---- the light map ----
    lea rdi, [lightmap]
    mov ecx, LM_W * LM_H
    xor eax, eax
    cld
    rep stosb
    cmp dword [lamps_on], 0
    je .ls_dynamic
    ; streetlights
    lea rbx, [street_lamps]
    mov r12d, street_lamps_count
.ls_lamp:
    mov edi, [rbx]
    add edi, 4
    mov esi, [rbx + 4]
    add esi, 4
    lea rdx, [kern_lamp]
    mov ecx, LAMP_R
    call stamp_light
    add rbx, 8
    dec r12d
    jnz .ls_lamp
    ; the lobbies are lit, and it spills out of the doors
    lea rbx, [lobbies]
    mov r12d, 2
.ls_lobby:
    mov edi, [rbx]
    mov esi, [rbx + 4]
    mov edx, [rbx + 8]
    mov ecx, [rbx + 12]
    mov r8d, LOBBY_LIGHT
    call light_rect
    add rbx, 16
    dec r12d
    jnz .ls_lobby
    lea rbx, [door_lights]
    mov r12d, door_lights_count
.ls_door:
    mov edi, [rbx]
    mov esi, [rbx + 4]
    lea rdx, [kern_mid]
    mov ecx, MID_R
    call stamp_light
    add rbx, 8
    dec r12d
    jnz .ls_door
.ls_dynamic:
    ; the police car: headlights ahead of it, and the light bar
    cmp dword [cop_active], 0
    je .ls_flashes
    mov r13d, [cop_rect + 8]
    shr r13d, 1
    add r13d, [cop_rect]          ; centre x
    mov r14d, [cop_rect + 12]
    shr r14d, 1
    add r14d, [cop_rect + 4]      ; centre y
    mov edi, r13d
    mov esi, r14d
    lea rdx, [kern_small]
    mov ecx, SMALL_R
    call stamp_light
    ; beams: two pools ahead, 40 and 75 px (the direction is the
    ; velocity's sign, times the distance)
    mov r15d, 40
.ls_beam:
    mov eax, [cop_vel]
    cdq
    xor eax, edx
    sub eax, edx                  ; |vx|
    mov ecx, [cop_vel]
    mov edi, r13d
    test ecx, ecx
    jz .ls_beam_y
    mov eax, r15d
    test ecx, ecx
    jg .ls_bx
    neg eax
.ls_bx:
    add edi, eax
.ls_beam_y:
    mov esi, r14d
    mov ecx, [cop_vel + 4]
    test ecx, ecx
    jz .ls_beam_stamp
    mov eax, r15d
    test ecx, ecx
    jg .ls_by
    neg eax
.ls_by:
    add esi, eax
.ls_beam_stamp:
    lea rdx, [kern_mid]
    mov ecx, MID_R
    call stamp_light
    add r15d, 35
    cmp r15d, 75
    jle .ls_beam
.ls_flashes:
    ; muzzle flashes: the first frames of every shot
    lea rbx, [effects]
    mov r12d, MAX_EFFECTS
.ls_fx:
    mov eax, [rbx + Effect.type]
    cmp eax, FX_PISTOL
    je .ls_fx_gun
    cmp eax, FX_SHOTGUN
    jne .ls_fx_next
.ls_fx_gun:
    cmp dword [rbx + Effect.age], 2
    jae .ls_fx_next
    mov edi, [rbx + Effect.x0]
    mov esi, [rbx + Effect.y0]
    lea rdx, [kern_small]
    mov ecx, SMALL_R
    call stamp_light
.ls_fx_next:
    add rbx, Effect_size
    dec r12d
    jnz .ls_fx

    ; ---- every pixel of the view through the tables ----
    lea r9, [light_tab]
    xor r10d, r10d                ; y
.ls_row:
    cmp r10d, [back_fb + FrameBuffer.h]
    jge .ls_done
    imul eax, r10d, BB_PITCH
    lea r8, [back_buffer]
    add r8, rax                   ; this row's pixels
    mov eax, r10d
    shr eax, 1
    imul eax, eax, LM_W
    lea r11, [lightmap]
    add r11, rax                  ; this row's light cells
    xor ecx, ecx                  ; x
.ls_px:
    mov eax, ecx
    shr eax, 1
    movzx eax, byte [r11 + rax]   ; light level
    lea rax, [rax + rax*2]        ; x3 (R, G, B)
    lea rbx, [r9 + rax*4]         ; this level's scales
    mov edx, [r8]
    movzx r12d, dl
    imul r12d, [rbx]
    shr r12d, 8                   ; R
    mov r13d, edx
    shr r13d, 8
    and r13d, 0xFF
    imul r13d, [rbx + 4]
    shr r13d, 8                   ; G
    shr edx, 16
    movzx r14d, dl
    imul r14d, [rbx + 8]
    shr r14d, 8                   ; B
    shl r13d, 8
    shl r14d, 16
    or r12d, r13d
    or r12d, r14d
    or r12d, 0xFF000000
    mov [r8], r12d
    add r8, 4
    inc ecx
    cmp ecx, [back_fb + FrameBuffer.w]
    jb .ls_px
    inc r10d
    jmp .ls_row
.ls_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
