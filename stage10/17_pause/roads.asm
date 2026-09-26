; roads.asm -- the police and the dog walker on the road network (10.13)
;
; The play tests: the city was easy to avoid, and the random encounters
; most of all. The police drove only roads that cross the whole map --
; the edges and three streets -- and the dog was walked along the top
; and bottom edges. Now, in game mode:
;
;   - the generator exports the road network (road_runs: every straight
;     east-west or north-south stretch of road with both lanes clear;
;     road_joins: where they cross)
;   - a police car turns up on a random run, out of your sight, and
;     patrols: at each crossing it turns COP_TURN_PCT% of the time;
;     where its road ends it turns onto the road it meets (a T), or
;     U-turns if there isn't one;
;     leaves the map if its road does, and after COP_LIFE ticks goes
;     off duty -- out of your sight
;   - a new car comes sooner (COP_CHANCE_GAME, against COP_CHANCE)
;   - a dog walker walks the sidewalk of a random east-west run, and
;     turns back at its end if you'd see them vanish; walks come sooner
;     (DOG_CHANCE_GAME)
;
; Watch mode keeps the old lanes and walks, so it's the same game as
; 10.12: the test harness doesn't move.

COP_TURN_PCT    equ 35
COP_LIFE        equ 5400        ; 90 s on patrol
COP_HIDE        equ 700         ; it turns up and leaves only this far from you
COP_CHANCE_GAME equ 300         ; a new car: 1 in this a tick (watch: COP_CHANCE)
DOG_CHANCE_GAME equ 450         ; a walk (watch: DOG_CHANCE)
DOG_RUN_MIN     equ 400         ; a walk's run: at least this long
ROAD_TRIES      equ 20
RUN_SIZE        equ 24          ; road_runs rows: ax, c, from, to, lane, half
JOIN_SIZE       equ 16          ; road_joins rows: run ew, run ns, x, y
CAR_ALONG       equ 40          ; the car, long way

section .data
    cop_run     dd 0
    cop_dir     dd 0            ; +1 east / south, -1 west / north
    cop_life    dd 0
    cop_moved   dd 0            ; it moved this tick (not waiting for you)
    walk_lo     dd 0            ; the walk's run: from, to
    walk_hi     dd 0
    jn_along    dd 0            ; join_on_run's answers
    jn_other    dd 0
    jn_at       dd 0

section .text

; int far_from_you(x: edi, y: esi) -> eax: 1 if you'd not see something
; there (no shift, or you're more than COP_HIDE away). A leaf
far_from_you:
    mov eax, 1
    cmp dword [player_on], 0
    je .ff_done
    lea r8, [soldiers + PLAYER * Soldier_size]
    mov ecx, [r8 + Soldier.x]
    sub ecx, edi
    imul ecx, ecx
    mov edx, [r8 + Soldier.y]
    sub edx, esi
    imul edx, edx
    add ecx, edx
    xor eax, eax
    cmp ecx, COP_HIDE * COP_HIDE
    setg al
.ff_done:
    ret


; the run edi's row -> r8
%macro RUN_AT 1
    imul r8d, %1, RUN_SIZE
    lea rax, [road_runs]
    add r8, rax
%endmacro


; void cop_place(run: edi, dir: esi, centre along the run: edx) -- the
; car on that run, in the lane for that way, heading that way. A leaf
cop_place:
    RUN_AT edi
    mov [cop_run], edi
    mov [cop_dir], esi
    mov ecx, [r8 + 4]             ; the centre line
    mov r9d, [r8 + 16]            ; the lane's offset from it
    cmp dword [r8], 0
    jne .cp_ns
    ; east-west: 40 x 20; east in the lane south of the line
    lea eax, [edx - CAR_ALONG / 2]
    mov [cop_rect], eax
    mov dword [cop_rect + 8], CAR_ALONG
    mov dword [cop_rect + 12], CAR_ALONG / 2
    lea eax, [ecx + r9d - CAR_ALONG / 2]
    test esi, esi
    jns .cp_ew_lane
    mov eax, ecx
    sub eax, r9d
.cp_ew_lane:
    mov [cop_rect + 4], eax
    imul eax, esi, COP_SPEED
    mov [cop_vel], eax
    mov dword [cop_vel + 4], 0
    ret
.cp_ns:
    ; north-south: 20 x 40; south in the lane west of the line
    lea eax, [edx - CAR_ALONG / 2]
    mov [cop_rect + 4], eax
    mov dword [cop_rect + 8], CAR_ALONG / 2
    mov dword [cop_rect + 12], CAR_ALONG
    mov eax, ecx
    sub eax, r9d
    test esi, esi
    jns .cp_ns_lane
    lea eax, [ecx + r9d - CAR_ALONG / 2]
.cp_ns_lane:
    mov [cop_rect], eax
    mov dword [cop_vel], 0
    imul eax, esi, COP_SPEED
    mov [cop_vel + 4], eax
    ret


; int cop_along(void) -> eax: the car's centre, along its run. A leaf
cop_along:
    mov ecx, [cop_run]
    RUN_AT ecx
    mov eax, [cop_rect]
    cmp dword [r8], 0
    je .ca_have
    mov eax, [cop_rect + 4]
.ca_have:
    add eax, CAR_ALONG / 2
    ret


; void cop_centre -> edi, esi: the car's centre. A leaf
%macro COP_CENTRE 0
    mov edi, [cop_rect + 8]
    shr edi, 1
    add edi, [cop_rect]
    mov esi, [cop_rect + 12]
    shr esi, 1
    add esi, [cop_rect + 4]
%endmacro


; int cop_spawn_road(void) -> eax (1: a car is out): a random run, way
; and place, out of your sight
;   ebx tries left   r12d run   r13d dir
cop_spawn_road:
    push rbx
    push r12
    push r13
    mov ebx, ROAD_TRIES
.cs_try:
    dec ebx
    js .cs_none
    mov edi, road_runs_count
    call rand_range
    mov r12d, eax
    mov edi, 2
    call rand_range
    lea r13d, [eax * 2 - 1]
    RUN_AT r12d
    mov edi, [r8 + 12]
    sub edi, [r8 + 8]
    sub edi, CAR_ALONG
    jle .cs_try                   ; (runs are 200 px or more: never)
    call rand_range
    lea edx, [eax + CAR_ALONG / 2]  ; (before RUN_AT: it uses rax)
    RUN_AT r12d
    add edx, [r8 + 8]
    mov edi, r12d
    mov esi, r13d
    call cop_place
    COP_CENTRE
    call far_from_you
    test eax, eax
    jz .cs_try
    mov dword [cop_life], COP_LIFE
    mov eax, 1
    jmp .cs_ret
.cs_none:
    xor eax, eax
.cs_ret:
    pop r13
    pop r12
    pop rbx
    ret


; void cop_uturn(void) -- back the way it came, in the other lane
cop_uturn:
    sub rsp, 8
    call cop_along
    mov edx, eax
    mov edi, [cop_run]
    mov esi, [cop_dir]
    neg esi
    call cop_place
    add rsp, 8
    ret


; int join_on_run(join: edi) -> eax: 1 if that crossing is on the car's
; run, with jn_along (where it is along ours), jn_other (the other run)
; and jn_at (where it is along theirs). A leaf
join_on_run:
    imul eax, edi, JOIN_SIZE
    lea rcx, [road_joins]
    add rcx, rax
    mov edx, [cop_run]
    mov r8d, [cop_run]
    RUN_AT r8d
    xor eax, eax
    cmp dword [r8], 0
    jne .jr_ns
    cmp [rcx], edx                ; east-west: ours is the first
    jne .jr_done
    mov edx, [rcx + 4]
    mov [jn_other], edx
    mov edx, [rcx + 8]
    mov [jn_along], edx
    mov edx, [rcx + 12]
    mov [jn_at], edx
    mov eax, 1
    ret
.jr_ns:
    cmp [rcx + 4], edx
    jne .jr_done
    mov edx, [rcx]
    mov [jn_other], edx
    mov edx, [rcx + 12]
    mov [jn_along], edx
    mov edx, [rcx + 8]
    mov [jn_at], edx
    mov eax, 1
.jr_done:
    ret


; int cop_turn_onto(run: edi, at: esi) -> eax (1: turned): onto that
; run, there, a random way -- else the other way -- whichever has 60 px
; or more to drive
;   ebx the way   r12d the run   r13d where
cop_turn_onto:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov edi, 2
    call rand_range
    lea ebx, [eax * 2 - 1]
    mov ecx, 2
.ct_way:
    RUN_AT r12d
    mov eax, [r8 + 12]
    sub eax, r13d
    test ebx, ebx
    jg .ct_room
    mov eax, r13d
    sub eax, [r8 + 8]
.ct_room:
    cmp eax, 60
    jge .ct_go
    neg ebx
    dec ecx
    jnz .ct_way
    xor eax, eax
    jmp .ct_ret
.ct_go:
    mov edi, r12d
    mov esi, ebx
    mov edx, r13d
    call cop_place
    mov eax, 1
.ct_ret:
    pop r13
    pop r12
    pop rbx
    ret


; int cop_road_step(void) -> eax (1: off duty, gone): after the car
; moves -- maybe a turn at a crossing it just passed; at a dead end, a
; turn at a crossing right there (a T), else a U-turn; and the end of
; its shift
;   ebx join   r12d along   r13d prev   r15 this run's row
cop_road_step:
    push rbx
    push r12
    push r13
    push r14
    push r15
    dec dword [cop_life]
    call cop_along
    mov r12d, eax
    imul ecx, [cop_dir], COP_SPEED
    mov r13d, r12d
    sub r13d, ecx                 ; where it was a tick ago
    mov ecx, [cop_run]
    RUN_AT ecx
    mov r15, r8
    cmp dword [cop_moved], 0
    je .rs_end                    ; waiting for you: no new crossings
    ; ---- a crossing passed this tick: prev < J <= along heading +,
    ; prev > J >= along heading - ----
    xor ebx, ebx
.rs_join:
    cmp ebx, road_joins_count
    jae .rs_end
    mov edi, ebx
    call join_on_run
    test eax, eax
    jz .rs_join_next
    mov edx, [jn_along]
    cmp dword [cop_dir], 0
    jl .rs_join_neg
    cmp r13d, edx
    jge .rs_join_next
    cmp edx, r12d
    jg .rs_join_next
    jmp .rs_crossing
.rs_join_neg:
    cmp r13d, edx
    jle .rs_join_next
    cmp edx, r12d
    jl .rs_join_next
.rs_crossing:
    mov edi, 100
    call rand_range
    cmp eax, COP_TURN_PCT
    jae .rs_join_next
    mov edi, [jn_other]
    mov esi, [jn_at]
    call cop_turn_onto
    test eax, eax
    jnz .rs_stay                  ; turned
.rs_join_next:
    inc ebx
    jmp .rs_join
.rs_end:
    ; ---- the end of the run? ----
    cmp dword [cop_dir], 0
    jl .rs_end_neg
    lea eax, [r12d + CAR_ALONG / 2]
    cmp eax, [r15 + 12]
    jle .rs_life
    mov ecx, WORLD_W
    cmp dword [r15], 0
    je .rs_edge
    mov ecx, WORLD_H
.rs_edge:
    cmp [r15 + 12], ecx
    jge .rs_life                  ; it runs off the map: drive off
    jmp .rs_dead_end
.rs_end_neg:
    lea eax, [r12d - CAR_ALONG / 2]
    cmp eax, [r15 + 8]
    jge .rs_life
    cmp dword [r15 + 8], 0
    jle .rs_life
.rs_dead_end:
    ; a crossing within a car's length: turn there (a T); else U-turn
    xor ebx, ebx
.rs_t:
    cmp ebx, road_joins_count
    jae .rs_uturn
    mov edi, ebx
    call join_on_run
    test eax, eax
    jz .rs_t_next
    mov eax, [jn_along]
    sub eax, r12d
    cdq
    xor eax, edx
    sub eax, edx                  ; |J - along|
    cmp eax, CAR_ALONG
    jg .rs_t_next
    mov edi, [jn_other]
    mov esi, [jn_at]
    call cop_turn_onto
    test eax, eax
    jnz .rs_stay
.rs_t_next:
    inc ebx
    jmp .rs_t
.rs_uturn:
    call cop_uturn
.rs_life:
    ; ---- off duty, where you can't see it go ----
    xor eax, eax
    cmp dword [cop_life], 0
    jg .rs_ret
    COP_CENTRE
    call far_from_you
    jmp .rs_ret
.rs_stay:
    xor eax, eax
.rs_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int dog_spawn_road(void) -> eax (1: a walk starts): a sidewalk of a
; random east-west run DOG_RUN_MIN or longer, from an end you can't see
;   ebx tries left   r12 the run's row
dog_spawn_road:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, ROAD_TRIES
.ds_try:
    dec ebx
    js .ds_none
    mov edi, road_runs_count
    call rand_range
    RUN_AT eax
    mov r12, r8
    cmp dword [r12], 0
    jne .ds_try
    mov eax, [r12 + 12]
    sub eax, [r12 + 8]
    cmp eax, DOG_RUN_MIN
    jl .ds_try
    ; which sidewalk: north of the road, or south
    mov edi, 2
    call rand_range
    mov ecx, [r12 + 4]
    test eax, eax
    jz .ds_north
    add ecx, [r12 + 20]
    jmp .ds_side
.ds_north:
    sub ecx, [r12 + 20]
    sub ecx, WALKER_SIZE
.ds_side:
    mov [walker_y], ecx
    ; from which end
    mov edi, 2
    call rand_range
    mov edi, [r12 + 8]
    mov edx, 1
    test eax, eax
    jz .ds_end
    mov edi, [r12 + 12]
    mov edx, -1
.ds_end:
    mov [walker_x], edi
    mov [walker_dx], edx
    mov esi, [walker_y]
    call far_from_you
    test eax, eax
    jz .ds_try
    mov eax, [r12 + 8]
    mov [walk_lo], eax
    mov eax, [r12 + 12]
    mov [walk_hi], eax
    mov eax, 1
    jmp .ds_ret
.ds_none:
    xor eax, eax
.ds_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret


; int dog_walk_over(void) -> eax (1: the encounter's over): game mode's
; walks end at their run's ends -- unless you'd see them vanish, when
; they turn back
dog_walk_over:
    sub rsp, 8
    xor eax, eax
    mov edi, [walker_x]
    cmp edi, [walk_lo]
    jl .do_end
    cmp edi, [walk_hi]
    jle .do_done
.do_end:
    mov esi, [walker_y]
    call far_from_you
    test eax, eax
    jnz .do_done
    neg dword [walker_dx]         ; you're watching: back they go
.do_done:
    add rsp, 8
    ret
