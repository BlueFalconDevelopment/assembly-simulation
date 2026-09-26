; shifts.asm -- the title screen, shifts and the summary (10.08)
;
; In game mode, in a window, the game is in one of four states:
;
;   TITLE    the war goes on behind a dimmed overlay: the name, your
;            money and shifts from the save, the controls, and ENTER
;            to start. W A S D pan the camera, as in watch mode
;   SHIFT    you, on your bike, with the job board and SHIFT_TICKS on
;            the clock (the scoreboard's second row, on the right).
;            player_on is 1 only now, so everything the player does
;            (player.asm, deliveries.asm, the bike) runs only now
;   SUMMARY  the clock ran out, or you died: what the shift made, and
;            ENTER for the shop
;   SHOP     (10.10, shop.asm) spend it; ENTER starts the next shift.
;            The title's ENTER goes here too
;
; Dying ends the shift: the package is lost (deliveries.asm) and so is
; DEATH_CASH_PCT% of the money you have; your gear stays. The save is
; written at the end of every shift.

GS_TITLE    equ 0
GS_SHIFT    equ 1
GS_SUMMARY  equ 2
SHIFT_TICKS equ 10800         ; 3 minutes
DEATH_CASH_PCT equ 20
SCANCODE_ENTER equ 40
LINE_H      equ 24            ; overlay text lines, in view pixels

section .data
    courier     dd 0          ; game mode, in a window
    game_state  dd GS_TITLE
    shift_left  dd 0
    shift_died  dd 0          ; how the last shift ended
    shift_money dd 0          ; money at the start of the shift
    shift_jobs  dd 0          ; deliveries at the start
    shift_kills dd 0          ; kills at the start
    shift_lost  dd 0          ; the death penalty, $
    enter_prev  dd 1          ; (1: an ENTER held at start isn't a press)
    ; the name (10.10). The typos are on purpose: a nod to "I MAED A
    ; GAM3 W1TH ZOMB1ES 1N IT!!!1". The font has capitals only; the
    ; window title (game_name, data.asm) has it as written
    t_title     db "MY CITY IS A WARZONE BUT I NEED MONEY!!!1"
    t_title_len equ $ - t_title
    t_title2    db ":4THWALL BREAK: HELP I NEED TO FIX MY VAN."
    t_title2_len equ $ - t_title2
    t_new       db "A NEW SAVE"
    t_new_len   equ $ - t_new
    t_loaded    db "WELCOME BACK"
    t_loaded_len equ $ - t_loaded
    t_damaged   db "YOUR SAVE WAS DAMAGED: STARTING OVER"
    t_damaged_len equ $ - t_damaged
    t_money     db "$"
    t_shifts    db "   SHIFTS "
    t_shifts_len equ $ - t_shifts
    t_start     db "PRESS ENTER"
    t_start_len equ $ - t_start
    ; (lines fit the view at 2x: 640 px, 53 characters)
    t_keys1     db "W A S D: RIDE OR WALK   E: BIKE ON/OFF"
    t_keys1_len equ $ - t_keys1
    t_keys2     db "MOUSE: AIM AND SHOOT   RIGHT-CLICK: LOCK ON"
    t_keys2_len equ $ - t_keys2
    t_keys3     db "Q: SWAP GUNS   1 2 3: TAKE A JOB   X: DROP IT"
    t_keys3_len equ $ - t_keys3
    t_over      db "SHIFT OVER"
    t_over_len  equ $ - t_over
    t_died      db "YOU DIED: SHIFT OVER"
    t_died_len  equ $ - t_died
    t_sdeliv    db "DELIVERIES "
    t_sdeliv_len equ $ - t_sdeliv
    t_searned   db "   EARNED $"
    t_searned_len equ $ - t_searned
    t_skills    db "KILLS "
    t_skills_len equ $ - t_skills
    t_slost     db "   LOST $"
    t_slost_len equ $ - t_slost
    t_total     db "TOTAL $"
    t_total_len equ $ - t_total
    t_next      db "PRESS ENTER FOR THE SHOP"
    t_next_len  equ $ - t_next
    t_shift     db "SHIFT "
    t_shift_len equ $ - t_shift
    COLOR_TITLE equ 0xFF30E6FF    ; yellow
    COLOR_BAD   equ 0xFF3C3CE6
    COLOR_4TH_WALL equ 0xFFE6A0C8 ; lilac

section .text

; void update_game_state(void) -- once a tick, before update_player
update_game_state:
    sub rsp, 8
    cmp dword [courier], 0
    je .ug_done
    mov r8, [key_state]
    movzx eax, byte [r8 + SCANCODE_ENTER]
    mov ecx, [enter_prev]
    mov [enter_prev], eax
    cmp dword [game_state], GS_SHIFT
    je .ug_shift
    mov dword [pause_prev], 1     ; (an ESC held into a shift isn't a press)
    ; ENTER (pressed, not held): the title and the summary open the
    ; shop, the shop starts a shift
    test eax, eax
    jz .ug_no_enter
    test ecx, ecx
    jnz .ug_no_enter
    cmp dword [game_state], GS_SHOP
    je .ug_start
    call shop_open
    jmp .ug_done
.ug_start:
    call shift_start
    jmp .ug_done
.ug_no_enter:
    cmp dword [game_state], GS_SHOP
    jne .ug_done
    call update_shop
    jmp .ug_done
.ug_shift:
    ; ESC or P (pressed, not held) pauses; while paused, the menu runs
    ; instead of the clock, and the same press goes back (10.17,
    ; pause.asm). Not while you're dead: that's the end of the shift
    mov r8, [key_state]
    movzx edi, byte [r8 + SCANCODE_ESC]
    or dil, [r8 + SCANCODE_P]
    mov ecx, [pause_prev]
    mov [pause_prev], edi
    not ecx
    and edi, ecx                  ; 1: pressed this tick
    cmp dword [paused], 0
    je .ug_running
    call update_pause
    jmp .ug_done
.ug_running:
    test edi, edi
    jz .ug_clock
    cmp dword [player_dead], 0
    jne .ug_clock
    call pause_open
    jmp .ug_done
.ug_clock:
    dec dword [shift_left]
    jg .ug_done
    xor edi, edi                  ; the clock ran out
    mov esi, GS_SUMMARY
    call shift_end
.ug_done:
    add rsp, 8
    ret


; void screen_wheel(int dy: edi) -- the mouse wheel. On the title, the
; summary and the shop, it zooms out as usual but not in past the 2x
; view (PLAYER_ZOOM) that their text is laid out for (10.10)
screen_wheel:
    cmp dword [courier], 0
    je camera_wheel
    cmp dword [game_state], GS_SHIFT
    jne .sw_overlay
    cmp dword [paused], 0         ; (10.17: the pause menu is an overlay)
    je camera_wheel
.sw_overlay:
    mov eax, PLAYER_ZOOM
    sub eax, [zoom_step]          ; steps left before 2x
    cmp edi, eax
    jle camera_wheel
    mov edi, eax
    jmp camera_wheel              ; (0 steps: camera_wheel does nothing)


; void shift_start(void)
shift_start:
    sub rsp, 8
    mov dword [game_state], GS_SHIFT
    mov dword [shift_left], SHIFT_TICKS
    mov eax, [money]
    mov [shift_money], eax
    mov eax, [jobs_done]
    mov [shift_jobs], eax
    mov eax, [player_kills]
    mov [shift_kills], eax
    mov dword [shift_lost], 0
    mov dword [shift_died], 0
    mov dword [player_on], 1
    mov dword [job_state], 0
    mov dword [e_prev], 1         ; an E held from the shop (it buys there)
                                  ; isn't a press: you stay on the bike
    call apply_gear               ; what the shop sold you (10.10)
    call meds_shift               ; a bottle at every dispensary (10.12)
    call player_spawn
    call make_offers
    add rsp, 8
    ret


; void shift_end(int died: edi, int next: esi) -- the clock ran out
; or you quit (0), or you died (1): out of the war, the save, and the
; next state (GS_SUMMARY; GS_TITLE when you quit, 10.17). A shift that
; ends while you're down, waiting to respawn, ends as a death however
; it ends: quitting or closing the window doesn't dodge the penalty
shift_end:
    push rbx
    mov ebx, esi
    cmp dword [player_dead], 0
    je .se_how
    mov edi, 1
.se_how:
    mov [shift_died], edi
    test edi, edi
    jz .se_paid
    ; the death penalty: DEATH_CASH_PCT% of what you have
    mov eax, [money]
    imul eax, eax, DEATH_CASH_PCT
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [shift_lost], eax
    sub [money], eax
.se_paid:
    ; out of the war
    mov dword [player_on], 0
    mov dword [job_state], 0
    mov dword [riding], 0
    mov dword [lock_target], -1
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov dword [r10 + Soldier.health], 0
    ; the totals
    inc dword [shifts_done]
    mov eax, [jobs_done]
    sub eax, [shift_jobs]
    add [total_deliveries], eax
    mov eax, [player_kills]
    sub eax, [shift_kills]
    add [total_kills], eax
    mov eax, [money]
    sub eax, [shift_money]
    add eax, [shift_lost]         ; earned, before any penalty
    cmp eax, [best_shift]
    jle .se_best_kept
    mov [best_shift], eax
.se_best_kept:
    mov [game_state], ebx
    call overlay_zoom
    call write_save
    mov dword [save_status], SAVE_LOADED   ; (the title: WELCOME BACK, 10.17)
    pop rbx
    ret


; void overlay_zoom(void) -- the overlays are laid out for the 2x
; view: zoomed in closer than that, come back out to it (10.10; a
; routine since 10.17, for the pause menu too)
overlay_zoom:
    sub rsp, 8
    mov edi, PLAYER_ZOOM
    sub edi, [zoom_step]
    jns .oz_done
    call camera_wheel
.oz_done:
    add rsp, 8
    ret


; ---- the overlay: text on the view, centred ----
; TEXT_LINE string, length, line number (from the top), colour
%macro TEXT_LINE 4
    lea rsi, [%1]
    mov edx, %2
    mov ecx, %3
    mov r8d, %4
    call overlay_line
%endmacro

; overlay_line(rsi text, edx length, ecx line, r8d colour): copies the
; text to hud_buf and draws it centred on the view, LINE_H apart,
; starting a quarter of the way down
overlay_line:
    push rbx
    push r12
    push r13
    mov ebx, edx
    mov r12d, ecx
    mov r13d, r8d
    lea rdi, [hud_buf]
    call append_bytes
    call overlay_buf
    pop r13
    pop r12
    pop rbx
    ret

; overlay_buf: hud_buf up to rdi, centred on line r12d, colour r13d
; (overlay_line's registers)
overlay_buf:
    sub rsp, 8
    mov rsi, rdi
    lea rdi, [hud_buf]
    sub rsi, rdi                  ; length
    imul eax, esi, CHAR_ADV
    sub eax, FONT_SCALE
    mov edx, [back_fb + FrameBuffer.w]
    sub edx, eax
    sar edx, 1
    add edx, [back_fb + FrameBuffer.ox]
    mov ecx, [back_fb + FrameBuffer.h]
    shr ecx, 2
    imul eax, r12d, LINE_H
    add ecx, eax
    add ecx, [back_fb + FrameBuffer.oy]
    mov r8d, r13d
    lea rax, [back_fb]
    mov [text_fb], rax
    call draw_text
    lea rax, [hud_fb]
    mov [text_fb], rax
    add rsp, 8
    ret


; void draw_overlay(void) -- the title or the summary, on a dimmed view
; (drawing only)
;   r12d the line   r13d the colour (overlay_buf's)
draw_overlay:
    push rbx
    push r12
    push r13
    cmp dword [courier], 0
    je .do_done
    cmp dword [game_state], GS_SHIFT
    jne .do_dim
    cmp dword [paused], 0         ; (10.17)
    je .do_done
.do_dim:
    %rep 2                        ; twice: 25/64 of the brightness
    lea rdi, [back_fb]
    mov esi, [back_fb + FrameBuffer.ox]
    mov edx, [back_fb + FrameBuffer.oy]
    mov ecx, [back_fb + FrameBuffer.w]
    mov r8d, [back_fb + FrameBuffer.h]
    call shade_rect
    %endrep
    cmp dword [paused], 0
    je .do_not_paused
    call draw_pause
    jmp .do_done
.do_not_paused:
    cmp dword [game_state], GS_SHOP
    jne .do_not_shop
    call draw_shop
    jmp .do_done
.do_not_shop:
    cmp dword [game_state], GS_TITLE
    jne .do_summary
    ; ---- the title ----
    TEXT_LINE t_title, t_title_len, 0, COLOR_TITLE
    TEXT_LINE t_title2, t_title2_len, 1, COLOR_4TH_WALL
    lea rsi, [t_new]
    mov edx, t_new_len
    mov r8d, COLOR_HUD_TEXT
    cmp dword [save_status], SAVE_LOADED
    jne .do_not_loaded
    lea rsi, [t_loaded]
    mov edx, t_loaded_len
.do_not_loaded:
    cmp dword [save_status], SAVE_DAMAGED
    jne .do_status
    lea rsi, [t_damaged]
    mov edx, t_damaged_len
    mov r8d, COLOR_BAD
.do_status:
    mov ecx, 2
    call overlay_line
    ; "$120   SHIFTS 3"
    lea rdi, [hud_buf]
    mov byte [rdi], '$'
    inc rdi
    mov esi, [money]
    call append_uint
    lea rsi, [t_shifts]
    mov edx, t_shifts_len
    call append_bytes
    mov esi, [shifts_done]
    call append_uint
    mov r12d, 3
    mov r13d, COLOR_MONEY
    call overlay_buf
    TEXT_LINE t_start, t_start_len, 5, COLOR_TITLE
    TEXT_LINE t_keys1, t_keys1_len, 7, COLOR_HUD_TEXT
    TEXT_LINE t_keys2, t_keys2_len, 8, COLOR_HUD_TEXT
    TEXT_LINE t_keys3, t_keys3_len, 9, COLOR_HUD_TEXT
    jmp .do_done
.do_summary:
    ; ---- the summary ----
    lea rsi, [t_over]
    mov edx, t_over_len
    mov r8d, COLOR_TITLE
    cmp dword [shift_died], 0
    je .do_over
    lea rsi, [t_died]
    mov edx, t_died_len
    mov r8d, COLOR_BAD
.do_over:
    xor ecx, ecx
    call overlay_line
    ; "DELIVERIES 4   EARNED $187"
    lea rdi, [hud_buf]
    lea rsi, [t_sdeliv]
    mov edx, t_sdeliv_len
    call append_bytes
    mov esi, [jobs_done]
    sub esi, [shift_jobs]
    call append_uint
    lea rsi, [t_searned]
    mov edx, t_searned_len
    call append_bytes
    mov esi, [money]
    sub esi, [shift_money]
    add esi, [shift_lost]
    call append_uint
    mov r12d, 2
    mov r13d, COLOR_HUD_TEXT
    call overlay_buf
    ; "KILLS 2   LOST $40"
    lea rdi, [hud_buf]
    lea rsi, [t_skills]
    mov edx, t_skills_len
    call append_bytes
    mov esi, [player_kills]
    sub esi, [shift_kills]
    call append_uint
    cmp dword [shift_lost], 0
    je .do_no_loss
    lea rsi, [t_slost]
    mov edx, t_slost_len
    call append_bytes
    mov esi, [shift_lost]
    call append_uint
.do_no_loss:
    mov r12d, 3
    call overlay_buf
    ; "TOTAL $227"
    lea rdi, [hud_buf]
    lea rsi, [t_total]
    mov edx, t_total_len
    call append_bytes
    mov esi, [money]
    call append_uint
    mov r12d, 4
    mov r13d, COLOR_MONEY
    call overlay_buf
    TEXT_LINE t_next, t_next_len, 6, COLOR_TITLE
.do_done:
    pop r13
    pop r12
    pop rbx
    ret


; append_shift_clock(dst: rdi) -> rdi: "SHIFT 2:13"
append_shift_clock:
    push rbx
    lea rsi, [t_shift]
    mov edx, t_shift_len
    call append_bytes
    mov eax, [shift_left]
    xor edx, edx
    mov ecx, 60
    div ecx
    xor edx, edx
    div ecx
    mov ebx, edx
    mov esi, eax
    call append_uint
    mov byte [rdi], ':'
    inc rdi
    cmp ebx, 10
    jae .asc_two
    mov byte [rdi], '0'
    inc rdi
.asc_two:
    mov esi, ebx
    call append_uint
    pop rbx
    ret
