; bikers.asm -- the Bikers and their clubhouse (10.14)
;
; A motorcycle club with a clubhouse in town: a building on a street
; corner picked at random each game, far from both gangs' homes, with
; a black roof and an orange winged wheel painted on it, and the pack's
; bikes parked out front. Now and then (game mode only) the pack rides:
;
;   - BIKERS riders in leather (FACTION_BIKERS: they fight both gangs
;     and you; the gangs and you fight them; the police leave them be).
;     Tough: BIKER_HEALTH, and only BIKER_ARMOR% of a hit gets through
;   - they pick a gang at random, and one of its members: that's where
;     they're going. A route on the road network's crossings
;     (road_join_nbrs, from the generator) by breadth-first search from
;     there, so every crossing knows its next hop
;   - a virtual leader rides crossing to crossing in the lane; the
;     riders follow its exact trail, BIKER_GAP ticks apart, pulling out
;     of the clubhouse one by one
;   - there, they ride round the neighbourhood for BIKER_RAID ticks --
;     random turns, but back toward the target whenever they stray
;     BIKER_ROAM away -- shooting whoever's nearest and theirs to hit
;   - then home, where each parks and goes inside as it arrives
;   - a rider killed stays dead for the raid (and drops his gun). If the
;     whole pack's killed, that's the end of the raid
;
; Watch mode has no Bikers: the same game as 10.13.

BIKER_HEALTH    equ 250
BIKER_ARMOR     equ 40          ; % of a hit that gets through (60: most packs wiped out)
BIKER_SPEED     equ 5           ; px a tick (you on the bike: 4)
BIKER_GAP       equ 9           ; ticks between riders: 45 px
BIKER_TRAIL     equ 64          ; the leader's last positions (>= BIKERS * GAP)
BIKER_RANGE     equ 260         ; they shoot this far
BIKER_FIRE_TICKS equ 30
BIKER_HIT       equ 55
BIKER_DAMAGE    equ 25
BIKER_FIRST     equ 3600        ; not in the first minute
BIKER_CHANCE    equ 5400        ; then a ride: 1 in this a tick (~90 s)
BIKER_RAID      equ 1500        ; 25 s round the target: hit and run
BIKER_ROAM      equ 500         ; px from it before they head back to it
BIKER_ALERT     equ 180
CLUB_HOME_DIST  equ 1400        ; the clubhouse: this far from both homes
CLUB_EDGE       equ 200
CLUB_TRIES      equ 400

BK_NONE    equ 0                ; at home
BK_OUT     equ 1                ; riding to the target
BK_RAID    equ 2                ; round it
BK_BACK    equ 3                ; riding home
BK_PARKING equ 4                ; home: the rest are pulling in

MAX_JOINS  equ road_joins_count

section .data
    bk_state   dd BK_NONE
    bk_home    dd -1            ; the clubhouse's crossing
    bk_goal    dd 0             ; where the route leads (a crossing)
    bk_cur     dd 0             ; the crossing the leader left
    bk_next    dd 0             ; ... and the one it's riding to
    bk_run     dd 0
    bk_ax      dd 0             ; its run's axis: 0 east-west, 1 north-south
    bk_dir     dd 0             ; +1 east / south, -1 west / north
    bk_along   dd 0             ; the leader, along its run
    bk_x       dd 0             ; ... its centre
    bk_y       dd 0
    bk_heading dd 0             ; 0 east, 64 south, 128 west, 192 north
    bk_tx      dd 0             ; the target
    bk_ty      dd 0
    bk_timer   dd 0             ; the raid's ticks left
    bk_t       dd 0             ; ticks since they rode out
    bk_parked_t dd 0            ; bk_t when the leader got home
    bk_out     dd 0             ; riders ridden out so far
    biker_alert dd 0            ; the scoreboard's "BIKERS" ticks left
    raids      dd 0             ; (for the tests)
    biker_kills dd 0
    ; the trail: x, y, heading, per tick
    bk_trail   times BIKER_TRAIL * 3 dd 0
    bk_pal     dd 0, 0xFF101010, 0xFF1E1EA0, 0xFFC8C8C8, 0xFF1E2A3C   ; tyres, a red tank (black was lost on the road), chrome, the seat
    hud_bikers db "BIKERS RIDING"
    hud_bikers_len equ $ - hud_bikers
    COLOR_CLUB      equ 0xFF1E78E6          ; orange
    COLOR_CLUB_ROOF equ 0xFF1C1C1C

section .bss
    bk_hop     resd MAX_JOINS   ; the next crossing toward bk_goal (-1: none)
    bk_queue   resd MAX_JOINS

section .text

; the crossing %1 (a register)'s row -> r9
%macro JOIN_AT 1
    imul r9d, %1, JOIN_SIZE
    lea rax, [road_joins]
    add r9, rax
%endmacro


; void bk_route(goal: edi) -- bk_hop[] toward that crossing: a
; breadth-first search from it over road_join_nbrs. A leaf
bk_route:
    mov [bk_goal], edi
    xor ecx, ecx
.br_clear:
    mov dword [bk_hop + rcx*4], -1
    inc ecx
    cmp ecx, MAX_JOINS
    jb .br_clear
    mov [bk_hop + rdi*4], edi
    mov [bk_queue], edi
    xor r10d, r10d                ; head
    mov r11d, 1                   ; tail
.br_pop:
    cmp r10d, r11d
    jae .br_done
    mov eax, [bk_queue + r10*4]
    inc r10d
    imul r8d, eax, 16
    lea rcx, [road_join_nbrs]
    add r8, rcx
    xor ecx, ecx
.br_nbr:
    mov edx, [r8 + rcx*4]
    test edx, edx
    js .br_nbr_next
    cmp dword [bk_hop + rdx*4], -1
    jne .br_nbr_next
    mov [bk_hop + rdx*4], eax     ; from there, next is where we came from
    mov [bk_queue + r11*4], edx
    inc r11d
.br_nbr_next:
    inc ecx
    cmp ecx, 4
    jb .br_nbr
    jmp .br_pop
.br_done:
    ret


; int nearest_join(x: edi, y: esi) -> eax. A leaf
nearest_join:
    push rbx
    mov r10d, 0x7FFFFFFF
    xor eax, eax
    xor ecx, ecx
    lea r8, [road_joins]
.nj_loop:
    cmp ecx, MAX_JOINS
    jae .nj_done
    mov edx, [r8 + 8]
    sub edx, edi
    imul edx, edx
    mov ebx, [r8 + 12]
    sub ebx, esi
    imul ebx, ebx
    add edx, ebx
    cmp edx, r10d
    jae .nj_next
    mov r10d, edx
    mov eax, ecx
.nj_next:
    add r8, JOIN_SIZE
    inc ecx
    jmp .nj_loop
.nj_done:
    pop rbx
    ret


; void bk_set_leg(from: edi, to: esi) -- the leader at crossing `from`,
; heading along the run the two share toward `to`, in its lane. A leaf
bk_set_leg:
    mov [bk_cur], edi
    mov [bk_next], esi
    JOIN_AT edi
    mov r10, r9                   ; from
    JOIN_AT esi                   ; to (r9)
    mov eax, [r10]
    cmp eax, [r9]
    jne .sl_ns
    ; east-west: their shared first run
    mov [bk_run], eax
    mov dword [bk_ax], 0
    mov ecx, [r10 + 8]
    mov [bk_along], ecx
    mov edx, 1
    cmp [r9 + 8], ecx
    jge .sl_ew_dir
    mov edx, -1
.sl_ew_dir:
    mov [bk_dir], edx
    jmp .sl_place
.sl_ns:
    mov eax, [r10 + 4]
    mov [bk_run], eax
    mov dword [bk_ax], 1
    mov ecx, [r10 + 12]
    mov [bk_along], ecx
    mov edx, 1
    cmp [r9 + 12], ecx
    jge .sl_ns_dir
    mov edx, -1
.sl_ns_dir:
    mov [bk_dir], edx
.sl_place:
    ; fall through


; void bk_place(void) -- bk_x, bk_y, bk_heading from the run, the way
; and bk_along: the middle of the lane for that way. A leaf
bk_place:
    mov ecx, [bk_run]
    RUN_AT ecx
    mov ecx, [r8 + 4]             ; the centre line
    mov edx, [r8 + 16]
    sub edx, 10                   ; the lane's middle, off the line
    cmp dword [bk_ax], 0
    jne .bp_ns
    mov eax, [bk_along]
    mov [bk_x], eax
    mov eax, ecx
    add eax, edx                  ; east: south of the line
    mov dword [bk_heading], 0
    cmp dword [bk_dir], 0
    jg .bp_ew
    mov eax, ecx
    sub eax, edx
    mov dword [bk_heading], 128
.bp_ew:
    mov [bk_y], eax
    ret
.bp_ns:
    mov eax, [bk_along]
    mov [bk_y], eax
    mov eax, ecx
    sub eax, edx                  ; south: west of the line
    mov dword [bk_heading], 64
    cmp dword [bk_dir], 0
    jg .bp_ns_lane
    mov eax, ecx
    add eax, edx
    mov dword [bk_heading], 192
.bp_ns_lane:
    mov [bk_x], eax
    ret


; void bikers_setup(void) -- game mode, once: the clubhouse's crossing,
; far from both homes and the map's edges, with more than one way out
;   ebx tries left   r12d the crossing   r13 its row
bikers_setup:
    push rbx
    push r12
    push r13
    cmp dword [game_mode], 0
    je .bs_done
    mov ebx, CLUB_TRIES
.bs_try:
    dec ebx
    js .bs_done                   ; nowhere: no Bikers this game
    mov edi, MAX_JOINS
    call rand_range
    mov r12d, eax
    JOIN_AT r12d
    mov r13, r9
    mov edi, [r13 + 8]
    mov esi, [r13 + 12]
    cmp edi, CLUB_EDGE
    jl .bs_try
    cmp edi, WORLD_W - CLUB_EDGE
    jg .bs_try
    cmp esi, CLUB_EDGE
    jl .bs_try
    cmp esi, WORLD_H - CLUB_EDGE
    jg .bs_try
    xor edx, edx
    call lobby_dist_sq
    cmp eax, CLUB_HOME_DIST * CLUB_HOME_DIST
    jl .bs_try
    mov edi, [r13 + 8]
    mov esi, [r13 + 12]
    mov edx, 1
    call lobby_dist_sq
    cmp eax, CLUB_HOME_DIST * CLUB_HOME_DIST
    jl .bs_try
    ; at least two ways out
    imul eax, r12d, 16
    lea rcx, [road_join_nbrs]
    add rcx, rax
    xor edx, edx
    xor r8d, r8d
.bs_ways:
    cmp dword [rcx + r8*4], 0
    jl .bs_way_next
    inc edx
.bs_way_next:
    inc r8d
    cmp r8d, 4
    jb .bs_ways
    cmp edx, 2
    jl .bs_try
    mov [bk_home], r12d
.bs_done:
    pop r13
    pop r12
    pop rbx
    ret


; void paint_clubhouse(void) -- in a window, once (player_start): the
; biggest building within 160 px of the clubhouse's crossing (a wall
; 24 x 24 or more) gets a black roof and an orange winged wheel. (The
; nearest one was often a small house)
;   r12d/r13d the crossing   r14 best wall   r15d its area
paint_clubhouse:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, [bk_home]
    test eax, eax
    js .pc_done
    JOIN_AT eax
    mov r12d, [r9 + 8]
    mov r13d, [r9 + 12]
    xor r14d, r14d
    xor r15d, r15d
    lea rbx, [map_walls]
    xor ecx, ecx
.pc_wall:
    cmp ecx, map_walls_count
    jae .pc_found
    cmp dword [rbx + Obstacle.w], 24
    jl .pc_next
    cmp dword [rbx + Obstacle.h], 24
    jl .pc_next
    xor eax, eax
    mov edx, [rbx + Obstacle.x]
    sub edx, r12d
    cmovg eax, edx
    mov edx, r12d
    sub edx, [rbx + Obstacle.x]
    sub edx, [rbx + Obstacle.w]
    cmp edx, eax
    cmovg eax, edx
    imul eax, eax
    xor r8d, r8d
    mov edx, [rbx + Obstacle.y]
    sub edx, r13d
    cmovg r8d, edx
    mov edx, r13d
    sub edx, [rbx + Obstacle.y]
    sub edx, [rbx + Obstacle.h]
    cmp edx, r8d
    cmovg r8d, edx
    imul r8d, r8d
    add eax, r8d
    cmp eax, 160 * 160
    jg .pc_next
    mov eax, [rbx + Obstacle.w]
    imul eax, [rbx + Obstacle.h]
    cmp eax, r15d
    jle .pc_next
    mov r15d, eax
    mov r14, rbx
.pc_next:
    add rbx, Obstacle_size
    inc ecx
    jmp .pc_wall
.pc_found:
    test r14, r14
    jz .pc_done
    ; the roof, black, 2 px in from its edge
    mov edi, [r14 + Obstacle.x]
    add edi, 2
    mov esi, [r14 + Obstacle.y]
    add esi, 2
    mov edx, [r14 + Obstacle.w]
    sub edx, 4
    mov ecx, [r14 + Obstacle.h]
    sub ecx, 4
    mov r8d, COLOR_CLUB_ROOF
    call bg_rect
    ; the wheel: an orange ring, a third of the short side (10 .. 24 px)
    mov eax, [r14 + Obstacle.w]
    mov ecx, [r14 + Obstacle.h]
    cmp ecx, eax
    cmovl eax, ecx
    xor edx, edx
    mov ecx, 3
    div ecx
    CLAMP_TO_RANGE eax, 10, 24
    mov ebx, eax                  ; its size
    mov r12d, [r14 + Obstacle.w]
    shr r12d, 1
    add r12d, [r14 + Obstacle.x]  ; the roof's centre
    mov r13d, [r14 + Obstacle.h]
    shr r13d, 1
    add r13d, [r14 + Obstacle.y]
    ; the wings first, either side, as long as the wheel and a fifth as tall
    mov edi, r12d
    sub edi, ebx
    mov eax, ebx
    xor edx, edx
    mov ecx, 5
    div ecx
    inc eax
    mov r15d, eax                 ; wing thickness
    mov esi, r13d
    sub esi, r15d
    lea edx, [ebx * 2]
    mov ecx, r15d
    add ecx, r15d
    mov r8d, COLOR_CLUB
    call bg_rect
    ; the ring over them: orange, then black inside
    mov edi, r12d
    mov eax, ebx
    shr eax, 1
    sub edi, eax
    mov esi, r13d
    sub esi, eax
    mov edx, ebx
    mov ecx, ebx
    mov r8d, COLOR_CLUB
    call bg_rect
    mov edi, r12d
    mov eax, ebx
    shr eax, 1
    sub edi, eax
    add edi, 3
    mov esi, r13d
    sub esi, eax
    add esi, 3
    lea edx, [ebx - 6]
    lea ecx, [ebx - 6]
    mov r8d, COLOR_CLUB_ROOF
    call bg_rect
.pc_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void bikers_ride(void) -- a raid starts: a gang, one of its members as
; the target, the route, and the leader on its first leg
;   ebx tries   r12d the gang
bikers_ride:
    push rbx
    push r12
    sub rsp, 8
    mov edi, NUM_GANGS
    call rand_range
    mov r12d, eax
    mov ebx, 50
.bw_pick:
    dec ebx
    js .bw_ret                    ; nobody alive to go after
    mov edi, NUM_PER_TEAM
    call rand_range
    imul ecx, r12d, NUM_PER_TEAM
    add eax, ecx
    imul eax, eax, Soldier_size
    lea rcx, [soldiers]
    add rcx, rax
    cmp dword [rcx + Soldier.health], 0
    jle .bw_pick
    mov edi, [rcx + Soldier.x]
    add edi, SOLDIER_SIZE / 2
    mov esi, [rcx + Soldier.y]
    add esi, SOLDIER_SIZE / 2
    mov [bk_tx], edi
    mov [bk_ty], esi
    call nearest_join
    mov edi, eax
    call bk_route
    mov eax, [bk_home]
    mov esi, [bk_hop + rax*4]
    test esi, esi
    js .bw_ret                    ; no way there from home
    cmp esi, eax
    je .bw_ret                    ; it's right here: not worth the ride
    mov edi, eax
    call bk_set_leg
    mov dword [bk_state], BK_OUT
    mov dword [bk_t], 0
    mov dword [bk_out], 0
    mov dword [biker_alert], BIKER_ALERT
    inc dword [raids]
.bw_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void bk_arrive(void) -- the leader's at bk_next: what now
;   ebx the crossing
bk_arrive:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, [bk_next]
    mov eax, [bk_state]
    cmp eax, BK_BACK
    jne .ba_not_back
    cmp ebx, [bk_home]
    jne .ba_hop
    ; home: the leader's parked; the rest pull in behind
    mov dword [bk_state], BK_PARKING
    mov eax, [bk_t]
    mov [bk_parked_t], eax
    jmp .ba_ret
.ba_not_back:
    cmp eax, BK_OUT
    jne .ba_raid
    cmp ebx, [bk_goal]
    jne .ba_hop
    mov dword [bk_state], BK_RAID
    mov dword [bk_timer], BIKER_RAID
.ba_raid:
    ; the raid: over? home. Strayed? back toward the target. Else a
    ; random way on (not back where we came from, if there's another)
    cmp dword [bk_timer], 0
    jg .ba_roam
    mov dword [bk_state], BK_BACK
    mov edi, [bk_home]
    call bk_route
    jmp .ba_hop
.ba_roam:
    JOIN_AT ebx
    mov eax, [r9 + 8]
    sub eax, [bk_tx]
    imul eax, eax
    mov ecx, [r9 + 12]
    sub ecx, [bk_ty]
    imul ecx, ecx
    add eax, ecx
    cmp eax, BIKER_ROAM * BIKER_ROAM
    jg .ba_hop                    ; bk_hop still leads to the target
    imul eax, ebx, 16
    lea r12, [road_join_nbrs]
    add r12, rax
    mov edi, 4
    call rand_range
    mov ecx, 8                    ; two rounds of the four: any, then any
.ba_way:
    and eax, 3
    mov esi, [r12 + rax*4]
    test esi, esi
    js .ba_way_next
    cmp ecx, 4
    jle .ba_go                    ; second round: even back the way we came
    cmp esi, [bk_cur]
    jne .ba_go
.ba_way_next:
    inc eax
    dec ecx
    jnz .ba_way
    jmp .ba_ret                   ; (a crossing always has a neighbour)
.ba_hop:
    mov esi, [bk_hop + rbx*4]
    test esi, esi
    js .ba_lost
    cmp esi, ebx
    je .ba_lost                   ; (at the goal: handled above)
.ba_go:
    mov edi, ebx
    call bk_set_leg
    jmp .ba_ret
.ba_lost:
    ; no way on (it shouldn't happen): straight home, or park here
    mov dword [bk_state], BK_PARKING
    mov eax, [bk_t]
    mov [bk_parked_t], eax
.ba_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void bk_slot(rider k: edi) -> r10: his soldier
%macro BK_SOLDIER 1
    lea r10d, [%1 + FIRST_BIKER]
    imul r10d, r10d, Soldier_size
    lea rax, [soldiers]
    add r10, rax
%endmacro


; void update_bikers(void) -- once a tick, game mode (update_events)
;   ebx rider   r12d his trail tick   r13 trail entry
update_bikers:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [game_mode], 0
    je .ub_done
    cmp dword [biker_alert], 0
    jle .ub_alerted
    dec dword [biker_alert]
.ub_alerted:
    cmp dword [bk_state], BK_NONE
    jne .ub_riding
    cmp dword [bk_home], 0
    jl .ub_done
    cmp dword [ticks], BIKER_FIRST
    jb .ub_done
    mov edi, BIKER_CHANCE
    call chance
    test eax, eax
    jz .ub_done
    call bikers_ride
    cmp dword [bk_state], BK_NONE
    je .ub_done
.ub_riding:
    ; ---- the leader ----
    cmp dword [bk_state], BK_PARKING
    je .ub_trail
    cmp dword [bk_state], BK_RAID
    jne .ub_move
    dec dword [bk_timer]
.ub_move:
    imul edx, [bk_dir], BIKER_SPEED
    add edx, [bk_along]
    mov [bk_along], edx           ; (edx: JOIN_AT uses rax)
    ; at the next crossing yet?
    mov ecx, [bk_next]
    JOIN_AT ecx
    mov ecx, [r9 + 8]
    cmp dword [bk_ax], 0
    je .ub_have_j
    mov ecx, [r9 + 12]
.ub_have_j:
    cmp dword [bk_dir], 0
    jl .ub_neg
    cmp edx, ecx
    jl .ub_placed
    jmp .ub_there
.ub_neg:
    cmp edx, ecx
    jg .ub_placed
.ub_there:
    mov [bk_along], ecx
    call bk_place
    call bk_arrive
.ub_placed:
    call bk_place
.ub_trail:
    ; ---- this tick's trail entry ----
    mov eax, [bk_t]
    and eax, BIKER_TRAIL - 1
    imul eax, eax, 12
    lea r13, [bk_trail]
    add r13, rax
    mov eax, [bk_x]
    mov [r13], eax
    mov eax, [bk_y]
    mov [r13 + 4], eax
    mov eax, [bk_heading]
    mov [r13 + 8], eax
    ; ---- the riders: out of the clubhouse one by one, each where the
    ; leader was k * BIKER_GAP ticks ago ----
    xor ebx, ebx
    xor r15d, r15d                ; riders still out
.ub_rider:
    cmp ebx, BIKERS
    jae .ub_riders_done
    imul eax, ebx, BIKER_GAP
    mov r12d, [bk_t]
    sub r12d, eax                 ; his trail tick
    js .ub_rider_next             ; not out yet
    cmp ebx, [bk_out]
    jb .ub_rider_out
    ; his turn to ride out
    cmp dword [bk_state], BK_PARKING
    je .ub_rider_next             ; (they got home before he left: he stays in)
    inc dword [bk_out]
    BK_SOLDIER ebx
    mov dword [r10 + Soldier.health], BIKER_HEALTH
    mov dword [r10 + Soldier.team], FACTION_BIKERS
    mov dword [r10 + Soldier.weapon], WEAPON_PISTOL
    mov dword [r10 + Soldier.cooldown], BIKER_FIRE_TICKS
    mov dword [r10 + Soldier.target], -1
    lea eax, [ebx + FIRST_BIKER]
    lea rcx, [lives_left]
    mov dword [rcx + rax*4], 0    ; no coming back from the dead
    lea rcx, [respawn_timer]
    mov dword [rcx + rax*4], 0
    lea rcx, [sprite_seen]
    mov dword [rcx + rax*4], 0
.ub_rider_out:
    BK_SOLDIER ebx
    cmp dword [r10 + Soldier.health], 0
    jle .ub_rider_next
    ; home and in?
    cmp dword [bk_state], BK_PARKING
    jne .ub_rider_move
    cmp r12d, [bk_parked_t]
    jl .ub_rider_move
    mov dword [r10 + Soldier.health], 0
    lea eax, [ebx + FIRST_BIKER]
    lea rcx, [death_linger]
    mov dword [rcx + rax*4], 0    ; (not a death: nothing to draw)
    lea rcx, [hit_flash]
    mov dword [rcx + rax*4], 0
    jmp .ub_rider_next
.ub_rider_move:
    inc r15d
    and r12d, BIKER_TRAIL - 1
    imul r12d, r12d, 12
    lea rax, [bk_trail]
    mov ecx, [rax + r12 + 0]
    sub ecx, SOLDIER_SIZE / 2
    mov [r10 + Soldier.x], ecx
    mov ecx, [rax + r12 + 4]
    sub ecx, SOLDIER_SIZE / 2
    mov [r10 + Soldier.y], ecx
    lea eax, [ebx + FIRST_BIKER]
    mov edi, eax
    call biker_fire
.ub_rider_next:
    inc ebx
    jmp .ub_rider
.ub_riders_done:
    inc dword [bk_t]
    ; the raid's over when nobody's out any more: all home, or all dead
    test r15d, r15d
    jnz .ub_done
    mov eax, [bk_t]
    cmp eax, BIKERS * BIKER_GAP + 1
    jb .ub_done                   ; (still pulling out)
    mov dword [bk_state], BK_NONE
.ub_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void biker_fire(soldier: edi) -- cooled down: at whoever's nearest,
; theirs to hit, in range and in sight. The police's way of shooting
;   ebx him   r12 his soldier   r13d/r14d from   r15d best   (stack) best d^2
biker_fire:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov ebx, edi
    imul eax, ebx, Soldier_size
    lea r12, [soldiers]
    add r12, rax
    dec dword [r12 + Soldier.cooldown]
    jg .bf_done
    mov dword [r12 + Soldier.cooldown], BIKER_FIRE_TICKS
    mov r13d, [r12 + Soldier.x]
    mov r14d, [r12 + Soldier.y]
    mov r15d, -1
    mov dword [rsp], BIKER_RANGE * BIKER_RANGE + 1
    xor ecx, ecx
.bf_scan:
    cmp ecx, TOTAL_SOLDIERS
    jae .bf_scanned
    imul eax, ecx, Soldier_size
    lea rdx, [soldiers]
    add rdx, rax
    cmp dword [rdx + Soldier.health], 0
    jle .bf_next
    mov eax, [rdx + Soldier.team]
    mov r8d, FACTION_BIKERS
    HOSTILE r8, r8, rax
    jz .bf_next
    mov eax, [rdx + Soldier.x]
    sub eax, r13d
    imul eax, eax
    mov r8d, [rdx + Soldier.y]
    sub r8d, r14d
    imul r8d, r8d
    add eax, r8d
    cmp eax, [rsp]
    jae .bf_next
    mov [rsp + 4], ecx
    mov [rsp + 8], eax
    mov edi, r13d
    mov esi, r14d
    mov r8d, [rdx + Soldier.y]
    mov edx, [rdx + Soldier.x]
    mov ecx, r8d
    call sight_blocked
    mov ecx, [rsp + 4]
    test eax, eax
    jnz .bf_next
    mov eax, [rsp + 8]
    mov [rsp], eax
    mov r15d, ecx
.bf_next:
    inc ecx
    jmp .bf_scan
.bf_scanned:
    test r15d, r15d
    js .bf_done
    mov edi, 100
    call rand_range
    xor r12d, r12d
    cmp eax, BIKER_HIT
    setb r12b
    mov edi, WEAPON_PISTOL
    mov esi, ebx
    mov edx, r15d
    mov ecx, r12d
    call spawn_effect
    test r12d, r12d
    jz .bf_done
    mov edi, r15d
    mov esi, BIKER_DAMAGE
    call event_damage
    add [biker_kills], eax
.bf_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void draw_bikes(void) -- the motorcycles under their riders, facing
; the way each rode his last tick; at home, parked out front (drawing
; only)
;   ebx rider   r12d his trail tick
draw_bikes:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [bk_home], 0
    jl .db_done
    cmp dword [bk_state], BK_NONE
    je .db_parked
    xor ebx, ebx
.db_rider:
    cmp ebx, BIKERS
    jae .db_done
    lea eax, [ebx + FIRST_BIKER]
    imul eax, eax, Soldier_size
    lea rcx, [soldiers]
    cmp dword [rcx + rax + Soldier.health], 0
    jle .db_next
    mov r13d, [rcx + rax + Soldier.x]
    add r13d, SOLDIER_SIZE / 2
    mov r14d, [rcx + rax + Soldier.y]
    add r14d, SOLDIER_SIZE / 2
    imul eax, ebx, BIKER_GAP
    mov r12d, [bk_t]
    dec r12d
    sub r12d, eax
    and r12d, BIKER_TRAIL - 1
    imul r12d, r12d, 12
    lea rax, [bk_trail]
    mov edx, [rax + r12 + 8]      ; his heading
    mov edi, r13d
    mov esi, r14d
    call draw_motorcycle
.db_next:
    inc ebx
    jmp .db_rider
.db_parked:
    ; parked in a row by the clubhouse's corner, all facing east
    mov eax, [bk_home]
    JOIN_AT eax
    mov r13d, [r9 + 8]
    sub r13d, (BIKERS * 14) / 2
    mov r14d, [r9 + 12]
    add r14d, 34
    xor ebx, ebx
.db_park:
    cmp ebx, BIKERS
    jae .db_done
    imul edi, ebx, 14
    add edi, r13d
    mov esi, r14d
    mov edx, 64                   ; nose to the kerb
    call draw_motorcycle
    inc ebx
    jmp .db_park
.db_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; draw_motorcycle(cx: edi, cy: esi, heading: edx)
draw_motorcycle:
    sub rsp, 8
    add edx, 128 / VEHICLE_FACINGS
    shr edx, 4
    and edx, VEHICLE_FACINGS - 1
    imul edx, edx, VEHICLE_SPRITE * VEHICLE_SPRITE
    lea rax, [motorcycle_sprites]
    add rdx, rax
    sub edi, VEHICLE_SPRITE / 2
    sub esi, VEHICLE_SPRITE / 2
    lea rcx, [bk_pal]
    xor r8d, r8d
    mov r9d, VEHICLE_SPRITE
    mov dword [spr_h], VEHICLE_SPRITE
    call draw_sprite_ex
    add rsp, 8
    ret
