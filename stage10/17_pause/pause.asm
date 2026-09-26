; pause.asm -- the pause menu (10.17)
;
; ESC or P, in a shift, pauses everything: the war, the shift clock,
; the job's clock, the Bikers' raids, the time of day. The main loop
; skips update_player, update_soldiers and ticks while `paused` isn't
; 0, and update_game_state skips the shift clock. The frame is still
; drawn (you can zoom), but nothing it draws moves on: the render pass
; doesn't age attack effects, count down hit flashes and falls, or
; stamp blood and casings while paused.
;
; The menu: W/S (or the arrows) choose, E, SPACE or ENTER picks, and
; ESC or P goes back (from the menu: resumes).
;
;   RESUME         back to the shift
;   CONTROLS       every key
;   OPTIONS        a placeholder until the music (volume)
;   QUIT TO TITLE  the shift ends now: you keep what it earned, the
;                  package you carry is lost unpaid, and there's no
;                  death penalty. It counts as a shift, and it's saved
;
; Watch mode never pauses: `paused` stays 0 and the sim is unchanged.

PAUSE_MENU     equ 1          ; paused: which page
PAUSE_CONTROLS equ 2
PAUSE_OPTIONS  equ 3
PM_RESUME      equ 0          ; the menu's rows
PM_CONTROLS    equ 1
PM_OPTIONS     equ 2
PM_QUIT        equ 3
PM_COUNT       equ 4
SCANCODE_P     equ 19
SCANCODE_ESC   equ 41
PK_UP     equ 1               ; the menu's keys, as bits
PK_DOWN   equ 2
PK_PICK   equ 4
PK_BACK   equ 8
PAUSE_TOP equ 1               ; the first line

section .data
    paused      dd 0          ; 0, or the page: PAUSE_MENU ...
    pause_pick  dd 0
    pause_prev  dd 1          ; last tick's ESC or P (update_game_state)
    pause_keys_was dd 0       ; last tick's other keys, as PK_ bits
    pause_zoom  dd 0          ; the zoom step to come back to
    t_paused    db "PAUSED"
    t_paused_len equ $ - t_paused
    ; the rows, each padded to the same width so the marks line up
    PM_ROW_LEN  equ 16
    %macro PM_ROW 1
        %%row: db %1
        times PM_ROW_LEN - ($ - %%row) db ' '
    %endmacro
    t_pm_rows:
    PM_ROW "   RESUME"
    PM_ROW "   CONTROLS"
    PM_ROW "   OPTIONS"
    PM_ROW "   QUIT TO TITLE"
    t_pm_hint   db "YOU KEEP YOUR PAY BUT LOSE THE PACKAGE"
    t_pm_hint_len equ $ - t_pm_hint
    t_pm_keys   db "W S: CHOOSE   E: PICK   ESC: RESUME"
    t_pm_keys_len equ $ - t_pm_keys
    t_back      db "E OR ESC: BACK"
    t_back_len  equ $ - t_back
    t_controls  db "CONTROLS"
    t_controls_len equ $ - t_controls
    ; (53 characters at most: the view at 2x.) Each line is centred on
    ; its own, so they're padded to CK_W to keep the columns
    CK_W        equ 34
    t_ck1       db "W A S D    RIDE OR WALK"
                times CK_W - ($ - t_ck1) db ' '
    t_ck1_len   equ $ - t_ck1
    t_ck2       db "E          GET ON OR OFF"
                times CK_W - ($ - t_ck2) db ' '
    t_ck2_len   equ $ - t_ck2
    t_ck3       db "MOUSE      AIM"
                times CK_W - ($ - t_ck3) db ' '
    t_ck3_len   equ $ - t_ck3
    t_ck4       db "LEFT       FIRE OR THROW A GRENADE"
                times CK_W - ($ - t_ck4) db ' '
    t_ck4_len   equ $ - t_ck4
    t_ck5       db "RIGHT      LOCK ON"
                times CK_W - ($ - t_ck5) db ' '
    t_ck5_len   equ $ - t_ck5
    t_ck6       db "Q          NEXT WEAPON"
                times CK_W - ($ - t_ck6) db ' '
    t_ck6_len   equ $ - t_ck6
    t_ck7       db "1 2 3      TAKE A JOB   X: DROP IT"
                times CK_W - ($ - t_ck7) db ' '
    t_ck7_len   equ $ - t_ck7
    t_ck8       db "WHEEL      ZOOM   ESC OR P: PAUSE"
                times CK_W - ($ - t_ck8) db ' '
    t_ck8_len   equ $ - t_ck8
    t_options   db "OPTIONS"
    t_options_len equ $ - t_options
    t_opt1      db "VOLUME: COMES WITH THE MUSIC"
    t_opt1_len  equ $ - t_opt1

section .text

; void pause_open(void) -- ESC or P in a shift
pause_open:
    sub rsp, 8
    mov dword [paused], PAUSE_MENU
    mov dword [pause_pick], PM_RESUME
    mov dword [pause_keys_was], PK_UP | PK_DOWN | PK_PICK ; held keys don't count
    mov eax, [zoom_step]
    mov [pause_zoom], eax
    call overlay_zoom             ; the text is laid out for the 2x view
    add rsp, 8
    ret


; void pause_close(void) -- back to the shift, at the zoom you had
pause_close:
    sub rsp, 8
    mov dword [paused], 0
    mov edi, [pause_zoom]
    sub edi, [zoom_step]
    call camera_wheel             ; (0 steps: does nothing)
    ; keys still down from the menu aren't presses in the shift: E
    ; would get you off the bike
    mov dword [e_prev], 1
    mov dword [q_prev], 1
    mov dword [x_prev], 1
    add rsp, 8
    ret


; void update_pause(int back: edi) -- once a tick while paused
; (update_game_state, which tracks ESC and P: edi 1 if one was pressed)
update_pause:
    push rbx
    push r12
    sub rsp, 8
    mov r12d, edi
    mov r8, [key_state]
    xor ebx, ebx                  ; this tick's keys, as PK_ bits
    movzx eax, byte [r8 + SCANCODE_W]
    or al, [r8 + SCANCODE_UP]
    jz .up_down
    or ebx, PK_UP
.up_down:
    movzx eax, byte [r8 + SCANCODE_S]
    or al, [r8 + SCANCODE_DOWN]
    jz .up_pick
    or ebx, PK_DOWN
.up_pick:
    movzx eax, byte [r8 + SCANCODE_E]
    or al, [r8 + SCANCODE_SPACE]
    or al, [r8 + SCANCODE_ENTER]
    jz .up_have_keys
    or ebx, PK_PICK
.up_have_keys:
    mov eax, [pause_keys_was]
    mov [pause_keys_was], ebx
    not eax
    and ebx, eax                  ; pressed this tick, not held
    test r12d, r12d
    jz .up_which
    or ebx, PK_BACK
.up_which:
    cmp dword [paused], PAUSE_MENU
    je .up_menu
    ; CONTROLS or OPTIONS: either key goes back to the menu
    test ebx, PK_PICK | PK_BACK
    jz .up_done
    mov dword [paused], PAUSE_MENU
    jmp .up_done
.up_menu:
    test ebx, PK_BACK
    jz .up_up
    call pause_close
    jmp .up_done
.up_up:
    test ebx, PK_UP
    jz .up_dn
    dec dword [pause_pick]
    jns .up_dn
    mov dword [pause_pick], PM_COUNT - 1
.up_dn:
    test ebx, PK_DOWN
    jz .up_chosen
    inc dword [pause_pick]
    cmp dword [pause_pick], PM_COUNT
    jb .up_chosen
    mov dword [pause_pick], 0
.up_chosen:
    test ebx, PK_PICK
    jz .up_done
    mov eax, [pause_pick]
    cmp eax, PM_RESUME
    jne .up_not_resume
    call pause_close
    jmp .up_done
.up_not_resume:
    cmp eax, PM_QUIT
    je .up_quit
    mov dword [paused], PAUSE_CONTROLS
    cmp eax, PM_CONTROLS
    je .up_done
    mov dword [paused], PAUSE_OPTIONS
    jmp .up_done
.up_quit:
    ; the shift ends as if the clock ran out (no penalty; the package
    ; goes), then the title instead of the summary
    mov dword [paused], 0
    xor edi, edi
    mov esi, GS_TITLE
    call shift_end
.up_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void draw_pause(void) -- the page, on the dimmed view (draw_overlay;
; drawing only). r12d the line, r13d the colour: overlay_buf's
draw_pause:
    push rbx
    push r12
    push r13
    cmp dword [paused], PAUSE_CONTROLS
    je .dp_controls
    cmp dword [paused], PAUSE_OPTIONS
    je .dp_options
    ; ---- the menu ----
    TEXT_LINE t_paused, t_paused_len, PAUSE_TOP, COLOR_TITLE
    xor ebx, ebx
.dp_row:
    ; "> RESUME <" on the chosen row, yellow; the others dim
    lea rdi, [hud_buf]
    imul esi, ebx, PM_ROW_LEN
    lea rax, [t_pm_rows]
    add rsi, rax
    mov edx, PM_ROW_LEN
    call append_bytes
    mov r13d, COLOR_HUD_TEXT
    cmp ebx, [pause_pick]
    jne .dp_line
    mov byte [hud_buf + 1], '>'
    mov byte [rdi], ' '
    mov byte [rdi + 1], '<'
    add rdi, 2
    mov r13d, COLOR_TITLE
    jmp .dp_draw
.dp_line:
    mov word [rdi], '  '          ; the same width as a marked row
    add rdi, 2
.dp_draw:
    lea r12d, [ebx + PAUSE_TOP + 2]
    call overlay_buf
    inc ebx
    cmp ebx, PM_COUNT
    jb .dp_row
    cmp dword [pause_pick], PM_QUIT
    jne .dp_menu_keys
    TEXT_LINE t_pm_hint, t_pm_hint_len, PAUSE_TOP + 3 + PM_COUNT, COLOR_DIM
.dp_menu_keys:
    TEXT_LINE t_pm_keys, t_pm_keys_len, PAUSE_TOP + 5 + PM_COUNT, COLOR_DIM
    jmp .dp_done
.dp_controls:
    TEXT_LINE t_controls, t_controls_len, 0, COLOR_TITLE
    TEXT_LINE t_ck1, t_ck1_len, 1, COLOR_HUD_TEXT
    TEXT_LINE t_ck2, t_ck2_len, 2, COLOR_HUD_TEXT
    TEXT_LINE t_ck3, t_ck3_len, 3, COLOR_HUD_TEXT
    TEXT_LINE t_ck4, t_ck4_len, 4, COLOR_HUD_TEXT
    TEXT_LINE t_ck5, t_ck5_len, 5, COLOR_HUD_TEXT
    TEXT_LINE t_ck6, t_ck6_len, 6, COLOR_HUD_TEXT
    TEXT_LINE t_ck7, t_ck7_len, 7, COLOR_HUD_TEXT
    TEXT_LINE t_ck8, t_ck8_len, 8, COLOR_HUD_TEXT
    TEXT_LINE t_back, t_back_len, 10, COLOR_DIM
    jmp .dp_done
.dp_options:
    TEXT_LINE t_options, t_options_len, PAUSE_TOP, COLOR_TITLE
    TEXT_LINE t_opt1, t_opt1_len, PAUSE_TOP + 2, COLOR_HUD_TEXT
    TEXT_LINE t_back, t_back_len, PAUSE_TOP + 4, COLOR_DIM
.dp_done:
    pop r13
    pop r12
    pop rbx
    ret
