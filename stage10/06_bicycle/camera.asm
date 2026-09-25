; camera.asm -- the view: copying it, zoom, pan
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; ============================================================
; The camera: which part of the map is drawn, and shown
; ============================================================

; void view_begin(void) -- once a frame, before any drawing. back_fb
; takes the camera's view (its size, and its origin: the drawing
; routines subtract that from map coordinates), and the background
; under the view is copied into back_buffer, row by row.
view_begin:
    push rbx
    mov eax, [cam_src]
    mov [back_fb + FrameBuffer.ox], eax
    mov eax, [cam_src + 4]
    mov [back_fb + FrameBuffer.oy], eax
    mov edx, [cam_src + 8]
    mov [back_fb + FrameBuffer.w], edx
    mov [tex_src + 8], edx
    mov ebx, [cam_src + 12]
    mov [back_fb + FrameBuffer.h], ebx
    mov [tex_src + 12], ebx
    mov eax, [cam_src + 4]
    imul eax, eax, WORLD_W
    add eax, [cam_src]
    lea r8, [bg_buffer]
    lea r8, [r8 + rax*4]          ; the view's top left in bg_buffer
    lea r9, [back_buffer]
.vb_row:
    mov rsi, r8
    mov rdi, r9
    mov ecx, edx                  ; the view's width, in pixels
    rep movsd
    add r8, WORLD_W * 4
    add r9, BB_PITCH
    dec ebx
    jnz .vb_row
    pop rbx
    ret


; void camera_start(void) -- the view at 1x, centred halfway between
; the two gangs' lobbies (10.03: the homes change from game to game)
camera_start:
    lea rcx, [site_lobbies]
    xor r8d, r8d                  ; x total
    xor r9d, r9d                  ; y total
    xor edx, edx
.cs_gang:
    mov eax, [home + rdx*4]
    shl eax, 4
    mov r10d, [rcx + rax + 8]
    shr r10d, 1
    add r10d, [rcx + rax]
    add r8d, r10d                 ; + its centre x
    mov r10d, [rcx + rax + 12]
    shr r10d, 1
    add r10d, [rcx + rax + 4]
    add r9d, r10d                 ; + its centre y
    inc edx
    cmp edx, NUM_GANGS
    jb .cs_gang
    shr r8d, 1                    ; (two gangs: the average)
    shr r9d, 1
    sub r8d, SCREEN_W / 2
    sub r9d, SCREEN_H / 2
    mov [cam_src], r8d
    mov [cam_src + 4], r9d
    jmp camera_clamp


; void camera_clamp(void) -- keep the view inside the map
camera_clamp:
    mov eax, [cam_src]
    mov ecx, WORLD_W
    sub ecx, [cam_src + 8]
    CLAMP_TO eax, ecx
    mov [cam_src], eax
    mov eax, [cam_src + 4]
    mov ecx, WORLD_H
    sub ecx, [cam_src + 12]
    CLAMP_TO eax, ecx
    mov [cam_src + 4], eax
    ret


; void camera_wheel(int clicks: edi) -- zoom in (positive) or out,
; keeping the field point under the mouse where it is on screen
camera_wheel:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, [zoom_step]
    add ebx, edi
    CLAMP_TO ebx, ZOOM_STEPS - 1
    cmp ebx, [zoom_step]
    je .cw_done
    lea rdi, [mouse_x]
    lea rsi, [mouse_y]
    call SDL_GetMouseState
    ; the mouse in the field (the window is the frame's size), clamped
    mov r12d, [mouse_x]
    CLAMP_TO r12d, SCREEN_W - 1
    mov r13d, [mouse_y]
    CLAMP_TO r13d, SCREEN_H - 1
    ; the field point under it now: cam + mouse * view / screen
    mov eax, r12d
    imul eax, [cam_src + 8]
    xor edx, edx
    mov ecx, SCREEN_W
    div ecx
    add eax, [cam_src]
    mov r14d, eax                 ; field x
    mov eax, r13d
    imul eax, [cam_src + 12]
    xor edx, edx
    mov ecx, SCREEN_H
    div ecx
    add eax, [cam_src + 4]
    mov r15d, eax                 ; field y
    ; the new view size
    mov [zoom_step], ebx
    lea rcx, [zoom_view_w]
    mov eax, [rcx + rbx*4]
    mov [cam_src + 8], eax
    imul eax, eax, SCREEN_H
    xor edx, edx
    mov ecx, SCREEN_W
    div ecx
    mov [cam_src + 12], eax
    ; and the camera that puts (field x, y) back under the mouse
    mov eax, r12d
    imul eax, [cam_src + 8]
    xor edx, edx
    mov ecx, SCREEN_W
    div ecx
    sub r14d, eax
    mov [cam_src], r14d
    mov eax, r13d
    imul eax, [cam_src + 12]
    xor edx, edx
    mov ecx, SCREEN_H
    div ecx
    sub r15d, eax
    mov [cam_src + 4], r15d
    call camera_clamp
.cw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void camera_pan(void) -- W A S D, once a frame. The step is
; PAN_SPEED screen pixels, so view / screen of that in field pixels
; (at least 1).
camera_pan:
    mov r8, [key_state]
    test r8, r8
    jz .cp_done
    mov eax, [cam_src + 8]
    imul eax, eax, PAN_SPEED
    xor edx, edx
    mov ecx, SCREEN_W
    div ecx
    mov ecx, eax
    test ecx, ecx
    jnz .cp_step
    mov ecx, 1
.cp_step:
    cmp byte [r8 + SCANCODE_A], 0
    je .cp_d
    sub [cam_src], ecx
.cp_d:
    cmp byte [r8 + SCANCODE_D], 0
    je .cp_w
    add [cam_src], ecx
.cp_w:
    cmp byte [r8 + SCANCODE_W], 0
    je .cp_s
    sub [cam_src + 4], ecx
.cp_s:
    cmp byte [r8 + SCANCODE_S], 0
    je .cp_clamp
    add [cam_src + 4], ecx
.cp_clamp:
    call camera_clamp
.cp_done:
    ret
