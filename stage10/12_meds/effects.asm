; effects.asm -- attack effects
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text



; void spawn_effect(int weapon: edi, int shooter: esi, int target: edx,
;                   int hit: ecx)
;
; Records one attack in the effects ring buffer, overwriting the oldest
; slot. Everything is worked out here, once, so draw_effects only has
; to interpolate:
;   - both endpoints are box centres (x + SOLDIER_SIZE/2)
;   - (px, py) is perpendicular to the shot and about PELLET_SPREAD
;     long: (-dy, dx) * SPREAD / max(|dx|, |dy|). Dividing by the
;     larger axis instead of the true length skips the square root.
;     The result is 1x to 1.41x too long, depending on angle, which is
;     fine for a spread
;   - a miss moves the aim point MISS_OFFSET spreads sideways and 25%
;     further on, so the tracer visibly flies past. The side alternates
;     with the slot number. It's cosmetic, so it must not call rng_next
;     (that would change the game)
;   - a hit keeps the target drawn until its flash ends, in case this
;     attack killed it (death_linger)
spawn_effect:
    push rbx
    push r12
    push r13
    push r14

    mov r13d, esi               ; shooter
    mov r14d, ecx               ; hit

    mov eax, [fx_next]
    mov ebx, eax                ; slot number, for the miss side below
    lea ecx, [eax + 1]
    and ecx, MAX_EFFECTS - 1
    mov [fx_next], ecx
    imul eax, Effect_size
    lea r8, [effects]
    add r8, rax

    lea eax, [edi + 1]
    mov [r8 + Effect.type], eax
    mov dword [r8 + Effect.age], 0
    mov [r8 + Effect.target], edx
    mov [r8 + Effect.hit], r14d

    lea r9, [fx_src]            ; shooter -1: the police or the dog,
    cmp r13d, -1                ; at fx_src (laid out like Soldier.x/y)
    je .se_have_shooter
    mov eax, r13d
    imul eax, Soldier_size
    lea r9, [soldiers]
    add r9, rax
.se_have_shooter:
    lea r10, [fx_dst]           ; target -1: a point, at fx_dst (10.05:
    cmp edx, -1                 ; the player's miss)
    je .se_have_target
    mov eax, edx
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
.se_have_target:

    mov eax, [r9 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.x0], eax
    mov eax, [r9 + Soldier.y]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.y0], eax
    mov eax, [r10 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.x1], eax
    mov eax, [r10 + Soldier.y]
    add eax, SOLDIER_SIZE / 2
    mov [r8 + Effect.y1], eax

    ; r11d = dx, r12d = dy
    mov r11d, [r8 + Effect.x1]
    sub r11d, [r8 + Effect.x0]
    mov r12d, [r8 + Effect.y1]
    sub r12d, [r8 + Effect.y0]

    ; ecx = max(|dx|, |dy|)  (neg, then cmovs puts back the original
    ; if negating made it negative, i.e. if it was positive)
    mov eax, r11d
    neg eax
    cmovs eax, r11d
    mov ecx, r12d
    neg ecx
    cmovs ecx, r12d
    cmp ecx, eax
    cmovl ecx, eax

    mov dword [r8 + Effect.px], 0
    mov dword [r8 + Effect.py], 0
    test ecx, ecx
    jz .se_perp_done            ; same centre -- no direction to be perpendicular to
    mov eax, r12d
    neg eax
    imul eax, PELLET_SPREAD
    cdq
    idiv ecx
    mov [r8 + Effect.px], eax
    mov eax, r11d
    imul eax, PELLET_SPREAD
    cdq
    idiv ecx
    mov [r8 + Effect.py], eax
.se_perp_done:

    test r14d, r14d
    jnz .se_hit
    cmp edi, WEAPON_KNIFE
    je .se_done                 ; a missed stab looks the same, minus the flash

    mov ecx, MISS_OFFSET
    test ebx, 1
    jz .se_side_ok
    neg ecx
.se_side_ok:
    mov eax, [r8 + Effect.px]
    imul eax, ecx
    add [r8 + Effect.x1], eax
    sar r11d, 2
    add [r8 + Effect.x1], r11d
    mov eax, [r8 + Effect.py]
    imul eax, ecx
    add [r8 + Effect.y1], eax
    sar r12d, 2
    add [r8 + Effect.y1], r12d
    jmp .se_done

.se_hit:
    ; linger through arrival + flash, +1 because the soldier loop
    ; counts down in the frame before draw_effects starts the flash
    ; (8.04: plus DEATH_LIE, the fall, if this hit is the one that kills)
    mov ecx, BULLET_TRAVEL + FLASH_FRAMES + DEATH_LIE + 1
    cmp edi, WEAPON_KNIFE
    jne .se_have_linger
    mov ecx, KNIFE_PEAK + FLASH_FRAMES + DEATH_LIE + 1
.se_have_linger:
    mov eax, [r8 + Effect.target]   ; not edx: cdq/idiv above clobbered it
    lea r9, [death_linger]
    cmp [r9 + rax*4], ecx
    jge .se_done                ; an earlier shot already set a longer one
    mov [r9 + rax*4], ecx

.se_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_effects(void)
;
; Draws every live effect into the back buffer, then ages it one
; frame. It runs once per rendered frame, not per update tick, so
; effects still finish after game_over stops the updates.
;
; Every line is "tail to head" along the path from (X0,Y0) to
; (X1,Y1), with both ends given as fractions TN/DEN and HN/DEN:
;   tracer: head = (age+1)/TRAVEL, tail TRACER_TAIL behind -> it flies
;   knife:  head = f/PEAK, f going 0..PEAK..0, tail KNIFE_BLADE behind
;           -> the blade slides out and back
; .emit_line and .set_endpoints are small subroutines that share this
; function's rbp frame, since they need its locals. (A `call` to a
; local label is just a call. rbp doesn't move, so [rbp + DE_*] still
; points at the same slots.)
DE_KMIN  equ -32     ; pellet range: k = KMIN..KMAX, aim = (x1,y1) + k*(px,py)
DE_KMAX  equ -40
DE_X0    equ -48
DE_Y0    equ -56
DE_X1    equ -64
DE_Y1    equ -72
DE_TN    equ -80
DE_HN    equ -88
DE_DEN   equ -96
DE_COLOR equ -104
DE_SIZE  equ -112
DE_TX    equ -120
DE_TY    equ -128
DE_HX    equ -136

draw_effects:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8 + 112            ; keeps rsp 16-byte aligned for calls

    xor ebx, ebx
.de_loop:
    cmp ebx, MAX_EFFECTS
    jge .de_done
    mov eax, ebx
    imul eax, Effect_size
    lea r12, [effects]
    add r12, rax

    mov eax, [r12 + Effect.type]
    test eax, eax
    jz .de_next
    cmp eax, FX_KNIFE
    je .de_knife

    ; ---- pistol: one tracer. shotgun: three, k = -1, 0, +1 ----
    mov dword [rbp + DE_KMIN], 0
    mov dword [rbp + DE_KMAX], 0
    mov dword [rbp + DE_COLOR], COLOR_TRACER
    cmp eax, FX_SHOTGUN
    jne .de_have_k
    mov dword [rbp + DE_KMIN], -1
    mov dword [rbp + DE_KMAX], 1
    mov dword [rbp + DE_COLOR], COLOR_PELLET
.de_have_k:

    ; the first frame of a shot: a casing by the shooter's feet (8.04)
    cmp dword [r12 + Effect.age], 0
    jne .de_no_casing
    mov edi, [r12 + Effect.x0]
    mov esi, [r12 + Effect.y0]
    mov edx, [r12 + Effect.type]
    call stamp_casing
.de_no_casing:

    mov eax, [r12 + Effect.age]
    cmp eax, BULLET_TRAVEL
    jge .de_impact

    lea ecx, [eax + 1]
    mov [rbp + DE_HN], ecx
    sub ecx, TRACER_TAIL
    jns .de_tail_ok
    xor ecx, ecx                ; tail can't start behind the shooter
.de_tail_ok:
    mov [rbp + DE_TN], ecx
    mov dword [rbp + DE_DEN], BULLET_TRAVEL

    mov r13d, [rbp + DE_KMIN]
.de_tracer_loop:
    call .set_endpoints
    call .emit_line
    inc r13d
    cmp r13d, [rbp + DE_KMAX]
    jle .de_tracer_loop
    jmp .de_age

.de_impact:
    cmp dword [r12 + Effect.hit], 0
    je .de_age                  ; a miss just flies off: no spark

    cmp eax, BULLET_TRAVEL
    jne .de_no_flash
    call .start_flash           ; the frame the tracer arrives
.de_no_flash:
    mov dword [rbp + DE_SIZE], 5
    cmp dword [r12 + Effect.age], BULLET_TRAVEL + IMPACT_FRAMES / 2
    jl .de_have_size
    mov dword [rbp + DE_SIZE], 3        ; spark shrinks for its second half
.de_have_size:
    mov r13d, [rbp + DE_KMIN]
.de_spark_loop:
    call .set_endpoints
    lea rdi, [back_fb]
    mov eax, [rbp + DE_SIZE]
    shr eax, 1
    mov esi, [rbp + DE_X1]
    sub esi, eax
    mov edx, [rbp + DE_Y1]
    sub edx, eax
    mov ecx, [rbp + DE_SIZE]
    mov r8d, ecx
    mov r9d, COLOR_SPARK
    call fill_rect
    inc r13d
    cmp r13d, [rbp + DE_KMAX]
    jle .de_spark_loop
    jmp .de_age

    ; ---- knife: f = age up to PEAK, then back down ----
.de_knife:
    mov eax, [r12 + Effect.age]
    cmp eax, KNIFE_PEAK
    jle .de_have_f
    mov ecx, KNIFE_LIFE
    sub ecx, eax
    mov eax, ecx
.de_have_f:
    mov [rbp + DE_HN], eax
    sub eax, KNIFE_BLADE
    jns .de_blade_ok
    xor eax, eax
.de_blade_ok:
    mov [rbp + DE_TN], eax
    mov dword [rbp + DE_DEN], KNIFE_PEAK
    mov dword [rbp + DE_COLOR], COLOR_BLADE

    xor r13d, r13d
    call .set_endpoints
    call .emit_line

    ; draw it again 1px over to make it 2px thick: step across the
    ; blade, so y for a mostly-horizontal stab, x for a mostly-vertical one
    mov eax, [rbp + DE_X1]
    sub eax, [rbp + DE_X0]
    mov ecx, eax
    neg ecx
    cmovs ecx, eax              ; ecx = |dx|
    mov eax, [rbp + DE_Y1]
    sub eax, [rbp + DE_Y0]
    mov edx, eax
    neg edx
    cmovs edx, eax              ; edx = |dy|
    cmp ecx, edx
    jl .de_thick_x
    inc dword [rbp + DE_Y0]
    inc dword [rbp + DE_Y1]
    jmp .de_thick_draw
.de_thick_x:
    inc dword [rbp + DE_X0]
    inc dword [rbp + DE_X1]
.de_thick_draw:
    call .emit_line

    cmp dword [r12 + Effect.age], KNIFE_PEAK
    jne .de_age
    cmp dword [r12 + Effect.hit], 0
    je .de_age
    call .start_flash           ; the frame the blade reaches its target

.de_age:
    mov eax, [r12 + Effect.age]
    inc eax
    mov [r12 + Effect.age], eax
    mov ecx, BULLET_LIFE
    cmp dword [r12 + Effect.type], FX_KNIFE
    jne .de_have_life
    mov ecx, KNIFE_LIFE
.de_have_life:
    cmp eax, ecx
    jl .de_next
    mov dword [r12 + Effect.type], 0    ; done -- free the slot

.de_next:
    inc ebx
    jmp .de_loop

.de_done:
    add rsp, 8 + 112
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---- local subroutines, sharing draw_effects' frame ----

; X0,Y0 = attacker centre; X1,Y1 = aim point + k*(px,py), k in r13d
.set_endpoints:
    mov eax, [r12 + Effect.x0]
    mov [rbp + DE_X0], eax
    mov eax, [r12 + Effect.y0]
    mov [rbp + DE_Y0], eax
    mov eax, [r12 + Effect.px]
    imul eax, r13d
    add eax, [r12 + Effect.x1]
    mov [rbp + DE_X1], eax
    mov eax, [r12 + Effect.py]
    imul eax, r13d
    add eax, [r12 + Effect.y1]
    mov [rbp + DE_Y1], eax
    ret

.start_flash:
    mov eax, [r12 + Effect.target]
    lea rcx, [hit_flash]
    mov dword [rcx + rax*4], FLASH_FRAMES
    ; and blood on the ground where it landed (8.04)
    sub rsp, 8                  ; the call here pushed 8; realign
    mov edi, [r12 + Effect.x1]
    mov esi, [r12 + Effect.y1]
    call stamp_splat
    add rsp, 8
    ret

; line from TN/DEN to HN/DEN of the way along (X0,Y0)->(X1,Y1)
.emit_line:
    sub rsp, 8                  ; the call here pushed 8; realign
    mov edi, [rbp + DE_X0]
    mov esi, [rbp + DE_X1]
    mov edx, [rbp + DE_TN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov [rbp + DE_TX], eax
    mov edi, [rbp + DE_Y0]
    mov esi, [rbp + DE_Y1]
    mov edx, [rbp + DE_TN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov [rbp + DE_TY], eax
    mov edi, [rbp + DE_X0]
    mov esi, [rbp + DE_X1]
    mov edx, [rbp + DE_HN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov [rbp + DE_HX], eax
    mov edi, [rbp + DE_Y0]
    mov esi, [rbp + DE_Y1]
    mov edx, [rbp + DE_HN]
    mov ecx, [rbp + DE_DEN]
    call lerp
    mov r8d, eax                ; head y
    mov ecx, [rbp + DE_HX]
    mov edx, [rbp + DE_TY]
    mov esi, [rbp + DE_TX]
    lea rdi, [back_fb]
    mov r9d, [rbp + DE_COLOR]
    call draw_line
    add rsp, 8
    ret


; int lerp(int a: edi, int b: esi, int n: edx, int d: ecx)
;   -> eax = a + (b - a) * n / d   (signed, truncating)
lerp:
    mov eax, esi
    sub eax, edi
    imul eax, edx
    cdq
    idiv ecx
    add eax, edi
    ret
