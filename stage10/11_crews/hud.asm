; hud.asm -- the font and the scoreboard
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text

draw_text:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                   ; 5 pushes + 32: rsp stays 16-aligned
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
.dt_char:
    test r12d, r12d
    jz .dt_done
    movzx eax, byte [rbx]
    cmp eax, 'a'
    jb .dt_upper
    cmp eax, 'z'
    ja .dt_upper
    sub eax, 'a' - 'A'
.dt_upper:
    sub eax, FONT_FIRST
    cmp eax, FONT_LAST - FONT_FIRST
    ja .dt_next_char              ; unsigned: below ' ' wraps round too
    imul eax, eax, FONT_ROWS
    lea rcx, [font]
    add rax, rcx
    mov [rsp + DT_GLYPH], rax
    mov dword [rsp + DT_ROW], 0
.dt_row:
    mov eax, [rsp + DT_ROW]
    cmp eax, FONT_ROWS
    jge .dt_next_char
    mov rcx, [rsp + DT_GLYPH]
    movzx ecx, byte [rcx + rax]
    mov [rsp + DT_BITS], ecx
    mov dword [rsp + DT_COL], 0
.dt_col:
    mov ecx, [rsp + DT_COL]
    cmp ecx, FONT_COLS
    jge .dt_next_row
    mov eax, 1 << (FONT_COLS - 1)
    shr eax, cl                   ; this column's bit
    test [rsp + DT_BITS], eax
    jz .dt_next_col
    mov rdi, [text_fb]            ; the scoreboard, or the view (10.08)
    imul esi, ecx, FONT_SCALE
    add esi, r13d
    imul edx, [rsp + DT_ROW], FONT_SCALE
    add edx, r14d
    mov ecx, FONT_SCALE
    mov r8d, FONT_SCALE
    mov r9d, r15d
    call fill_rect
.dt_next_col:
    inc dword [rsp + DT_COL]
    jmp .dt_col
.dt_next_row:
    inc dword [rsp + DT_ROW]
    jmp .dt_row
.dt_next_char:
    inc rbx
    dec r12d
    add r13d, CHAR_ADV
    jmp .dt_char
.dt_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; DRAW_HUD_BUF align, color: draw hud_buf[0 .. rdi) at y HUD_TEXT_Y,
; aligned HUD_LEFT, HUD_RIGHT or HUD_CENTRE.
HUD_LEFT   equ 0
HUD_RIGHT  equ 1
HUD_CENTRE equ 2
%macro DRAW_HUD_BUF 2-3 HUD_TEXT_Y   ; (10.07: the row, optionally)
    mov rsi, rdi
    lea rdi, [hud_buf]
    sub rsi, rdi                  ; length
    imul eax, esi, CHAR_ADV
    sub eax, FONT_SCALE           ; width: no spacing after the last char
    %if %1 == HUD_LEFT
        mov edx, HUD_MARGIN
    %elif %1 == HUD_RIGHT
        mov edx, SCREEN_W - HUD_MARGIN
        sub edx, eax
    %else
        mov edx, SCREEN_W
        sub edx, eax
        shr edx, 1
    %endif
    mov ecx, %3
    mov r8d, %2
    call draw_text
%endmacro

; void draw_hud(void)
;   BLUE 120/200      PILLARS   0:12      RED 97/200
; (kills, and the score limit if there is one)
; The middle shows the winner once the game is over.
draw_hud:
    push rbx
    push r12
    sub rsp, 8                    ; keep the stack 16-byte aligned

    lea rdi, [hud_fb]
    xor esi, esi
    xor edx, edx
    mov ecx, SCREEN_W
    mov r8d, HUD_H
    mov r9d, COLOR_HUD
    call fill_rect

    ; living soldiers per team -> ebx (team 0), r12d (team 1)
    xor ebx, ebx
    xor r12d, r12d
    lea r10, [soldiers]
    xor ecx, ecx
.dh_count:
    cmp dword [r10 + Soldier.health], 0
    jle .dh_count_next
    cmp dword [r10 + Soldier.team], 0
    jne .dh_count_t1
    inc ebx
    jmp .dh_count_next
.dh_count_t1:
    inc r12d
.dh_count_next:
    add r10, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jl .dh_count

    ; ---- left: BLUE n ----
    lea rdi, [hud_buf]
    lea rsi, [hud_blue]
    mov edx, hud_blue_len
    call append_bytes
    mov esi, [score]
    call append_score
    DRAW_HUD_BUF HUD_LEFT, COLOR_TEAM0

    ; ---- right: RED n, right-aligned ----
    lea rdi, [hud_buf]
    lea rsi, [hud_red]
    mov edx, hud_red_len
    call append_bytes
    mov esi, [score + 4]
    call append_score
    DRAW_HUD_BUF HUD_RIGHT, COLOR_TEAM1

    ; ---- middle ----
    lea rdi, [hud_buf]
    mov eax, [game_over]
    test eax, eax
    jz .dh_playing
    mov r12d, COLOR_TEAM0
    lea rsi, [hud_blue]
    mov edx, hud_blue_len - 1     ; no trailing space
    cmp eax, 1
    je .dh_winner
    mov r12d, COLOR_TEAM1
    lea rsi, [hud_red]
    mov edx, hud_red_len - 1
.dh_winner:
    call append_bytes
    lea rsi, [hud_wins]
    mov edx, hud_wins_len
    call append_bytes
    jmp .dh_middle

.dh_playing:
    cmp dword [boss_alert], 0
    je .dh_no_boss
    mov r12d, COLOR_TEAM0
    lea rsi, [hud_blue]
    mov edx, hud_blue_len
    cmp dword [boss_alert_team], 0
    je .dh_boss_gang
    mov r12d, COLOR_TEAM1
    lea rsi, [hud_red]
    mov edx, hud_red_len
.dh_boss_gang:
    call append_bytes
    lea rsi, [hud_boss]
    mov edx, hud_boss_len
    call append_bytes
    jmp .dh_middle
.dh_no_boss:
    cmp dword [cop_active], 0
    je .dh_no_police
    mov r12d, COLOR_SIREN_B
    test dword [ticks], 16
    jz .dh_siren
    mov r12d, COLOR_SIREN_R
.dh_siren:
    lea rsi, [hud_police]
    mov edx, hud_police_len
    call append_bytes
    jmp .dh_middle
.dh_no_police:
    cmp dword [dog_state], DOG_LOOSE
    jne .dh_normal
    mov r12d, COLOR_DOG_MAD
    lea rsi, [hud_dog]
    mov edx, hud_dog_len
    call append_bytes
    jmp .dh_middle
.dh_normal:
    mov r12d, COLOR_HUD_TEXT
    ; game mode (10.05): you -- HP, ammo, kills; or YOU DIED
    cmp dword [player_on], 0
    je .dh_arena
    cmp dword [soldiers + PLAYER * Soldier_size + Soldier.health], 0
    jg .dh_you
    mov r12d, COLOR_SIREN_R
    lea rsi, [hud_dead]
    mov edx, hud_dead_len
    call append_bytes
    jmp .dh_middle
.dh_you:
    lea rsi, [hud_hp]
    mov edx, hud_hp_len
    call append_bytes
    mov esi, [soldiers + PLAYER * Soldier_size + Soldier.health]
    call append_uint
    mov eax, [player_weapon]
    lea rsi, [hud_pistol]
    mov edx, hud_pistol_len
    cmp eax, WEAPON_SHOTGUN
    jne .dh_gun
    lea rsi, [hud_shotgun]
    mov edx, hud_shotgun_len
.dh_gun:
    call append_bytes
    mov eax, [player_weapon]
    lea rcx, [player_ammo]
    mov esi, [rcx + rax*4 - 4]    ; WEAPON_PISTOL is 1
    call append_uint
    lea rsi, [hud_kills]
    mov edx, hud_kills_len
    call append_bytes
    mov esi, [player_kills]
    call append_uint
    ; the bike (10.06): its health while riding; a hint when it's near
    cmp dword [riding], 0
    je .dh_off_bike
    lea rsi, [hud_bike]
    mov edx, hud_bike_len
    call append_bytes
    mov esi, [veh_health]
    call append_uint
    jmp .dh_middle
.dh_off_bike:
    cmp dword [veh_health], 0
    jle .dh_middle
    mov eax, [veh_x]
    sar eax, 4
    sub eax, [soldiers + PLAYER * Soldier_size + Soldier.x]
    sub eax, SOLDIER_SIZE / 2
    imul eax, eax
    mov ecx, [veh_y]
    sar ecx, 4
    sub ecx, [soldiers + PLAYER * Soldier_size + Soldier.y]
    sub ecx, SOLDIER_SIZE / 2
    imul ecx, ecx
    add eax, ecx
    cmp eax, MOUNT_REACH * MOUNT_REACH
    jg .dh_middle
    lea rsi, [hud_ride]
    mov edx, hud_ride_len
    call append_bytes
    jmp .dh_middle
.dh_arena:
    call append_arena_name
    lea rsi, [hud_gap]
    mov edx, hud_gap_len
    call append_bytes
    ; m:ss from ticks, 60 per second
    mov eax, [ticks]
    xor edx, edx
    mov ecx, 60
    div ecx                       ; eax = seconds
    xor edx, edx
    div ecx                       ; eax = minutes, edx = seconds
    mov ebx, edx
    mov esi, eax
    call append_uint
    mov byte [rdi], ':'
    inc rdi
    cmp ebx, 10
    jae .dh_two_digits
    mov byte [rdi], '0'
    inc rdi
.dh_two_digits:
    mov esi, ebx
    call append_uint
    ; and the time of day (8.05)
    lea rsi, [hud_gap]
    mov edx, 2
    call append_bytes
    call append_time_of_day
.dh_middle:
    DRAW_HUD_BUF HUD_CENTRE, r12d
    call draw_jobs                ; row 2: money and the job (10.07)

    add rsp, 8
    pop r12
    pop rbx
    ret
