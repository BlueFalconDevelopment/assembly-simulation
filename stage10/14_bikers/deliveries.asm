; deliveries.asm -- the job: pick up at a business, deliver to a house,
; get paid (10.07)
;
; The map lists every business's door (biz_points: the real buildings)
; and every house's (house_points: the generated ones), each a spot a
; soldier's box can stand on, reachable whichever pair of homes is in
; play (tools/gen_southside.py). The scoreboard's second row is the job
; board:
;
;   no job     three offers, each a business and a house at least
;              MIN_JOB apart: pay and distance, and a ! for each level of
;              danger. 1, 2 or 3 takes one
;   pick up    a yellow marker at the business (and a pip at the edge of
;              the screen pointing to it when it's off-screen). Get there
;   deliver    a green marker at the house, and a clock: it started when
;              you picked the package up. On time, the full pay; late,
;              half
;
; X drops the job (and the package). Dying loses it. Either way, three
; new offers. Pay: JOB_BASE + a dollar every JOB_PER_PX, plus JOB_DANGER
; for each level of danger -- gang members alive near the straight line
; from the business to the house when the offer was made. Time: JOB_TIME
; + JOB_TIME_PER px. Everything random here uses the player's RNG.

; CLAMP_TO_RANGE reg, lo, hi
%macro CLAMP_TO_RANGE 3
    cmp %1, %2
    jge %%lo_ok
    mov %1, %2
%%lo_ok:
    cmp %1, %3
    jle %%hi_ok
    mov %1, %3
%%hi_ok:
%endmacro

JOB_BASE      equ 10
JOB_PER_PX    equ 60          ; px of straight line per dollar
JOB_DANGER    equ 6           ; dollars per level of danger
DANGER_MAX    equ 5
DANGER_R      equ 200         ; px from the line that counts as near it
JOB_TIME      equ 300         ; ticks, plus...
JOB_TIME_PER  equ 3           ; ... this / 4 ticks per px of straight line
JOB_REACH     equ 20          ; px (corner to corner): you're there
MSG_TICKS     equ 180
PX_PER_KM     equ 1564        ; the map's scale (1.56 px a metre)

struc Offer
    .biz:    resd 1
    .house:  resd 1
    .pay:    resd 1
    .time:   resd 1
    .danger: resd 1
    .km10:   resd 1           ; distance, tenths of a km
endstruc

MSG_DELIVERED equ 1
MSG_LATE      equ 2
MSG_LOST      equ 3
MSG_DROPPED   equ 4

section .data
    money       dd 0
    job_state   dd 0          ; 0 the board, 1 to the business, 2 to the house
    job_left    dd 0          ; delivering: ticks left (0 or less: late)
    jobs_done   dd 0
    x_prev      dd 0
    msg_kind    dd 0
    msg_timer   dd 0
    msg_amount  dd 0
    txt_jobs    db "JOBS: "
    txt_jobs_len equ $ - txt_jobs
    txt_pickup  db "PICK UP AT THE YELLOW MARKER, THEN "
    txt_pickup_len equ $ - txt_pickup
    txt_deliver db "DELIVER TO THE GREEN MARKER  "
    txt_deliver_len equ $ - txt_deliver
    txt_late    db "LATE  HALF PAY "
    txt_late_len equ $ - txt_late
    txt_km      db "KM "
    txt_km_len  equ $ - txt_km
    txt_drop    db "   X: DROP IT"
    txt_drop_len equ $ - txt_drop
    txt_done    db "DELIVERED +$"
    txt_done_len equ $ - txt_done
    txt_done_late db "DELIVERED LATE +$"
    txt_done_late_len equ $ - txt_done_late
    txt_lost    db "PACKAGE LOST"
    txt_lost_len equ $ - txt_lost
    txt_dropped db "JOB DROPPED"
    txt_dropped_len equ $ - txt_dropped
    txt_gap     db "   "
    txt_gap_len equ $ - txt_gap
    you_msg3 db ", deliveries "
    you_msg3_len equ $ - you_msg3
    you_msg4 db ", $"
    you_msg4_len equ $ - you_msg4
    COLOR_PICKUP_MARK equ 0xFF30E6FF   ; yellow
    COLOR_DROP_MARK   equ 0xFF50DC50   ; green
    COLOR_MONEY       equ 0xFF78DC78

section .bss
    offers      resb 3 * Offer_size
    job         resb Offer_size

section .text

; int isqrt(int n: edi) -> eax
isqrt:
    cvtsi2sd xmm0, edi
    sqrtsd xmm0, xmm0
    cvttsd2si eax, xmm0
    ret


; void make_offers(void) -- three new jobs on the board
;   rbx the Offer   r12d which   r13, r14 the business's and house's points
;   r15d the distance
make_offers:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                   ; [rsp]: tries left (5 pushes + 16: aligned)
    lea rbx, [offers]
    xor r12d, r12d
.mo_offer:
    mov dword [rsp], 50
.mo_try:
    mov edi, biz_points_count
    call player_rand
    mov [rbx + Offer.biz], eax
    lea r13, [biz_points]
    lea r13, [r13 + rax*8]
    mov edi, house_points_count
    call player_rand
    mov [rbx + Offer.house], eax
    lea r14, [house_points]
    lea r14, [r14 + rax*8]
    mov eax, [r14]
    sub eax, [r13]
    imul eax, eax
    mov ecx, [r14 + 4]
    sub ecx, [r13 + 4]
    imul ecx, ecx
    lea edi, [eax + ecx]
    call isqrt
    mov r15d, eax
    cmp r15d, MIN_JOB
    jge .mo_far_enough
    dec dword [rsp]
    jnz .mo_try
.mo_far_enough:
    ; danger: gang members alive near the line, at 8 points along it
    call offer_danger
    mov [rbx + Offer.danger], eax
    ; pay, time, distance in tenths of a km
    imul ecx, eax, JOB_DANGER
    mov eax, r15d
    xor edx, edx
    mov r8d, JOB_PER_PX
    div r8d
    lea eax, [eax + ecx + JOB_BASE]
    mov [rbx + Offer.pay], eax
    imul eax, r15d, JOB_TIME_PER
    shr eax, 2
    add eax, JOB_TIME
    mov [rbx + Offer.time], eax
    imul eax, r15d, 10
    xor edx, edx
    mov r8d, PX_PER_KM
    div r8d
    mov [rbx + Offer.km10], eax
    add rbx, Offer_size
    inc r12d
    cmp r12d, 3
    jb .mo_offer
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int offer_danger(void) -> eax, 0..DANGER_MAX: gang members alive
; within DANGER_R of 8 points on the line from r13 (business) to r14
; (house) -- make_offers's registers -- halved
;   r8d the point   r9d x   r10d y   r11 a soldier   ecx count
offer_danger:
    xor ecx, ecx
    mov r8d, 1
.od_point:
    ; x = bx + (hx - bx) * k / 9
    mov eax, [r14]
    sub eax, [r13]
    imul eax, r8d
    cdq
    push rcx
    mov ecx, 9
    idiv ecx
    pop rcx
    add eax, [r13]
    mov r9d, eax
    mov eax, [r14 + 4]
    sub eax, [r13 + 4]
    imul eax, r8d
    cdq
    push rcx
    mov ecx, 9
    idiv ecx
    pop rcx
    add eax, [r13 + 4]
    mov r10d, eax
    lea r11, [soldiers]
    xor edx, edx
.od_soldier:
    cmp dword [r11 + Soldier.health], 0
    jle .od_next
    cmp dword [r11 + Soldier.team], NUM_GANGS
    jae .od_next
    mov eax, [r11 + Soldier.x]
    sub eax, r9d
    imul eax, eax
    push rdx
    mov edx, [r11 + Soldier.y]
    sub edx, r10d
    imul edx, edx
    add eax, edx
    pop rdx
    cmp eax, DANGER_R * DANGER_R
    ja .od_next
    inc ecx
.od_next:
    add r11, Soldier_size
    inc edx
    cmp edx, TOTAL_SOLDIERS
    jb .od_soldier
    inc r8d
    cmp r8d, 9
    jb .od_point
    mov eax, ecx
    shr eax, 1
    cmp eax, DANGER_MAX
    jbe .od_done
    mov eax, DANGER_MAX
.od_done:
    ret


; int near_point(int *point: rdi) -> eax: 1 if the player's corner is
; within JOB_REACH of it on both axes
near_point:
    lea r10, [soldiers + PLAYER * Soldier_size]
    xor eax, eax
    mov ecx, [r10 + Soldier.x]
    sub ecx, [rdi]
    cmp ecx, -JOB_REACH
    jl .np_done
    cmp ecx, JOB_REACH
    jg .np_done
    mov ecx, [r10 + Soldier.y]
    sub ecx, [rdi + 4]
    cmp ecx, -JOB_REACH
    jl .np_done
    cmp ecx, JOB_REACH
    jg .np_done
    mov eax, 1
.np_done:
    ret


; void job_message(int kind: edi, int amount: esi)
job_message:
    mov [msg_kind], edi
    mov [msg_amount], esi
    mov dword [msg_timer], MSG_TICKS
    ret


; void update_jobs(void) -- once a tick in game mode (update_player)
;   rbx scratch
update_jobs:
    push rbx
    cmp dword [msg_timer], 0
    jle .uj_msg_done
    dec dword [msg_timer]
.uj_msg_done:
    ; dead: the package is lost
    cmp dword [soldiers + PLAYER * Soldier_size + Soldier.health], 0
    jg .uj_alive
    cmp dword [job_state], 0
    je .uj_done
    mov dword [job_state], 0
    mov edi, MSG_LOST
    xor esi, esi
    call job_message
    call make_offers
    jmp .uj_done
.uj_alive:
    mov r8, [key_state]
    cmp dword [job_state], 0
    jne .uj_have_job
    ; ---- the board: 1, 2 or 3 takes an offer ----
    xor ebx, ebx
.uj_key:
    cmp byte [r8 + SCANCODE_1 + rbx], 0
    jne .uj_take
    inc ebx
    cmp ebx, 3
    jb .uj_key
    jmp .uj_done
.uj_take:
    imul eax, ebx, Offer_size
    lea rsi, [offers]
    add rsi, rax
    lea rdi, [job]
    mov ecx, Offer_size / 4
    cld
    rep movsd
    mov dword [job_state], 1
    jmp .uj_done
.uj_have_job:
    ; X drops it
    movzx eax, byte [r8 + SCANCODE_X]
    mov ecx, [x_prev]
    mov [x_prev], eax
    test eax, eax
    jz .uj_no_drop
    test ecx, ecx
    jnz .uj_no_drop
    mov dword [job_state], 0
    mov edi, MSG_DROPPED
    xor esi, esi
    call job_message
    call make_offers
    jmp .uj_done
.uj_no_drop:
    cmp dword [job_state], 1
    jne .uj_delivering
    ; ---- to the business ----
    mov eax, [job + Offer.biz]
    lea rdi, [biz_points]
    lea rdi, [rdi + rax*8]
    call near_point
    test eax, eax
    jz .uj_done
    mov dword [job_state], 2      ; got it: the clock starts
    mov eax, [job + Offer.time]
    mov [job_left], eax
    jmp .uj_done
.uj_delivering:
    ; ---- to the house ----
    dec dword [job_left]
    mov eax, [job + Offer.house]
    lea rdi, [house_points]
    lea rdi, [rdi + rax*8]
    call near_point
    test eax, eax
    jz .uj_done
    mov esi, [job + Offer.pay]
    mov edi, MSG_DELIVERED
    cmp dword [job_left], 0
    jg .uj_paid
    shr esi, 1                    ; late: half
    mov edi, MSG_LATE
.uj_paid:
    add [money], esi
    inc dword [jobs_done]
    call job_message
    mov dword [job_state], 0
    call make_offers
.uj_done:
    pop rbx
    ret


; append_offer(dst: rdi, Offer*: rsi) -> rdi: "$34 1.8KM !!"
append_offer:
    push rbx
    mov rbx, rsi
    mov byte [rdi], '$'
    inc rdi
    mov esi, [rbx + Offer.pay]
    call append_uint
    mov byte [rdi], ' '
    inc rdi
    call append_km
    mov ecx, [rbx + Offer.danger]
.ao_bang:
    test ecx, ecx
    jz .ao_done
    mov byte [rdi], '!'
    inc rdi
    dec ecx
    jmp .ao_bang
.ao_done:
    pop rbx
    ret

; append_km(dst: rdi; rbx the Offer) -> rdi: "1.8KM "
append_km:
    mov eax, [rbx + Offer.km10]
    xor edx, edx
    mov ecx, 10
    div ecx
    push rdx
    mov esi, eax
    call append_uint
    mov byte [rdi], '.'
    inc rdi
    pop rsi
    call append_uint
    lea rsi, [txt_km]
    mov edx, txt_km_len
    jmp append_bytes


; void draw_jobs(void) -- the scoreboard's second row, in game mode:
; your money, then the board, the job, or the last thing that happened
;   r12d the colour
draw_jobs:
    push rbx
    push r12
    sub rsp, 8
    cmp dword [player_on], 0
    je .dj_ret
    ; money, on the left
    lea rdi, [hud_buf]
    mov byte [rdi], '$'
    inc rdi
    mov esi, [money]
    call append_uint
    DRAW_HUD_BUF HUD_LEFT, COLOR_MONEY, HUD_TEXT_Y2
    ; the shift's clock, on the right (10.08)
    lea rdi, [hud_buf]
    call append_shift_clock
    DRAW_HUD_BUF HUD_RIGHT, COLOR_HUD_TEXT, HUD_TEXT_Y2
    ; the rest, in the middle
    lea rdi, [hud_buf]
    mov r12d, COLOR_HUD_TEXT
    cmp dword [msg_timer], 0
    jle .dj_state
    mov eax, [msg_kind]
    cmp eax, MSG_LOST
    je .dj_lost
    cmp eax, MSG_DROPPED
    je .dj_dropped
    mov r12d, COLOR_DROP_MARK
    lea rsi, [txt_done]
    mov edx, txt_done_len
    cmp eax, MSG_LATE
    jne .dj_done_msg
    mov r12d, COLOR_PICKUP_MARK
    lea rsi, [txt_done_late]
    mov edx, txt_done_late_len
.dj_done_msg:
    call append_bytes
    mov esi, [msg_amount]
    call append_uint
    jmp .dj_draw
.dj_lost:
    mov r12d, COLOR_SIREN_R
    lea rsi, [txt_lost]
    mov edx, txt_lost_len
    call append_bytes
    jmp .dj_draw
.dj_dropped:
    lea rsi, [txt_dropped]
    mov edx, txt_dropped_len
    call append_bytes
    jmp .dj_draw
.dj_state:
    mov eax, [job_state]
    cmp eax, 1
    je .dj_pickup
    cmp eax, 2
    je .dj_deliver
    ; the board: "JOBS: 1) $34 1.8KM !!   2) ..."
    lea rsi, [txt_jobs]
    mov edx, txt_jobs_len
    call append_bytes
    xor ebx, ebx
.dj_offer:
    lea eax, [ebx + '1']
    mov [rdi], al
    mov byte [rdi + 1], ')'
    mov byte [rdi + 2], ' '
    add rdi, 3
    imul eax, ebx, Offer_size
    lea rsi, [offers]
    add rsi, rax
    call append_offer
    lea rsi, [txt_gap]
    mov edx, txt_gap_len
    call append_bytes
    inc ebx
    cmp ebx, 3
    jb .dj_offer
    jmp .dj_draw
.dj_pickup:
    mov r12d, COLOR_PICKUP_MARK
    lea rsi, [txt_pickup]
    mov edx, txt_pickup_len
    call append_bytes
    lea rsi, [job]
    call append_offer
    lea rsi, [txt_drop]
    mov edx, txt_drop_len
    call append_bytes
    jmp .dj_draw
.dj_deliver:
    mov r12d, COLOR_DROP_MARK
    cmp dword [job_left], 0
    jg .dj_on_time
    mov r12d, COLOR_PICKUP_MARK
    lea rsi, [txt_late]
    mov edx, txt_late_len
    call append_bytes
    jmp .dj_pay
.dj_on_time:
    lea rsi, [txt_deliver]
    mov edx, txt_deliver_len
    call append_bytes
    ; m:ss left
    mov eax, [job_left]
    xor edx, edx
    mov ecx, 60
    div ecx
    xor edx, edx
    div ecx
    push rdx
    mov esi, eax
    call append_uint
    mov byte [rdi], ':'
    inc rdi
    pop rbx
    cmp ebx, 10
    jae .dj_secs
    mov byte [rdi], '0'
    inc rdi
.dj_secs:
    mov esi, ebx
    call append_uint
    mov byte [rdi], ' '
    inc rdi
    mov byte [rdi], ' '
    inc rdi
.dj_pay:
    mov byte [rdi], '$'
    inc rdi
    mov esi, [job + Offer.pay]
    cmp dword [job_left], 0
    jg .dj_full
    shr esi, 1
.dj_full:
    call append_uint
    lea rsi, [txt_drop]
    mov edx, txt_drop_len
    call append_bytes
.dj_draw:
    DRAW_HUD_BUF HUD_CENTRE, r12d, HUD_TEXT_Y2
.dj_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void draw_job_marker(void) -- the job's target: a pulsing square round
; the spot, and, if it's off the screen, a pip at the edge of the view
; pointing to it (drawing only)
;   ebx x   r12d y   r13d colour
draw_job_marker:
    push rbx
    push r12
    push r13
    cmp dword [player_on], 0
    je .dm_done
    mov eax, [job_state]
    lea rcx, [biz_points]
    mov r13d, COLOR_PICKUP_MARK
    mov edx, [job + Offer.biz]
    cmp eax, 1
    je .dm_have
    lea rcx, [house_points]
    mov r13d, COLOR_DROP_MARK
    mov edx, [job + Offer.house]
    cmp eax, 2
    jne .dm_done
.dm_have:
    mov ebx, [rcx + rdx*8]        ; the spot's corner
    mov r12d, [rcx + rdx*8 + 4]
    ; the square: 28 px round the spot, 2 px thick
    %macro MARK_BAR 4
        lea rdi, [back_fb]
        lea esi, [ebx + %1]
        lea edx, [r12d + %2]
        mov ecx, %3
        mov r8d, %4
        mov r9d, r13d
        call fill_rect
    %endmacro
    MARK_BAR -6, -6, 28, 2
    MARK_BAR -6, 20, 28, 2
    MARK_BAR -6, -6, 2, 28
    MARK_BAR 20, -6, 2, 28
    ; off the screen? a pip at the edge, toward it
    mov eax, [back_fb + FrameBuffer.ox]
    mov ecx, [back_fb + FrameBuffer.w]
    lea r8d, [eax + 10]
    lea r9d, [eax + ecx - 20]
    mov esi, ebx
    CLAMP_TO_RANGE esi, r8d, r9d
    mov eax, [back_fb + FrameBuffer.oy]
    mov ecx, [back_fb + FrameBuffer.h]
    lea r8d, [eax + 10]
    lea r9d, [eax + ecx - 20]
    mov edx, r12d
    CLAMP_TO_RANGE edx, r8d, r9d
    cmp esi, ebx
    jne .dm_pip
    cmp edx, r12d
    je .dm_done
.dm_pip:
    lea rdi, [back_fb]
    mov ecx, 10
    mov r8d, 10
    mov r9d, r13d
    call fill_rect
.dm_done:
    pop r13
    pop r12
    pop rbx
    ret

