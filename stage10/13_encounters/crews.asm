; crews.asm -- turf crews (10.11)
;
; Before this, every gang member went for the nearest enemy anywhere,
; so all a hundred of them fought in the one strip between the homes,
; and most of the city was empty: 20-50% of houses had a gangster
; within 450 px, and the west third and the south never had one. Easy
; to ride round.
;
; Now, in game mode, each gang posts CREWS_PER_GANG crews of CREW_SIZE
; round the city: a spot in front of a house, picked at random each
; game, at least CREW_HOME_DIST from both homes and CREW_SPACING from
; every other post -- on its own side of the city (nearer its home than
; the other's) if it can, anywhere if not. (Some home pairs leave one
; gang a small side: sides only, only 2 of the 10 crews fitted.) A crew
; member:
;
;   - starts at the post with a pistol, and stands there
;   - fights anyone hostile who comes within CREW_GUARD of the post
;     (you as well: gangsters still only go after you within
;     PLAYER_AGGRO of themselves), then walks back to its spot. The way
;     back is a flow field of its own, toward the post: a post never
;     moves, so each crew's field is searched once, whole, at the start
;     (without one, a member that ran from the police to the far side
;     of the expressway fence paced along it for the rest of the game)
;   - never goes for guns on the ground, and never joins the war
;   - dead: a replacement turns up at the post CREW_RESPAWN ticks
;     later, but not while you're within CREW_HIDE of it (no popping in
;     in front of you)
;
; The members are the last CREWS_PER_GANG * CREW_SIZE soldiers of each
; gang, so the war goes on with the rest. The gangs take turns picking
; posts, so they always have the same number of crews.
;
; Watch mode has no crews (soldier_crew is all -1), so it's the same
; game as before, byte for byte.

CREWS_PER_GANG equ 5
CREW_SIZE      equ 3
MAX_CREWS      equ CREWS_PER_GANG * NUM_GANGS
CREW_GUARD     equ 400        ; px from the post: their turf
CREW_IDLE      equ 4          ; this close to its spot: stand
CREW_HOME_DIST equ 700        ; posts this far from both homes' lobbies
CREW_SPACING   equ 700        ; ... and from each other
CREW_EDGE      equ 100        ; ... and in from the map's edges
CREW_RESPAWN   equ 1800       ; 30 s to a replacement
CREW_HIDE      equ 500        ; not while you're this close
CREW_TRIES     equ 1000       ; random house spots tried for each post
CREW_SPOTS     equ 6          ; places round the post to stand

%if CREWS_PER_GANG * CREW_SIZE >= NUM_PER_TEAM
    %error "the crews would leave nobody for the war"
%endif

section .data
    crew_count   dd 0
    crew_post    times MAX_CREWS * 2 dd 0      ; x, y
    soldier_crew times TOTAL_SOLDIERS db -1    ; which crew, or -1
    crew_spot_x  times TOTAL_SOLDIERS dd 0     ; where each member stands
    crew_spot_y  times TOTAL_SOLDIERS dd 0
    crew_back    times TOTAL_SOLDIERS dd 0     ; the tick a replacement is due
    crew_x       dd 0                          ; crew_free_spot's answer
    crew_y       dd 0
    crew_gx      dd 0                          ; crew_think's goal
    crew_gy      dd 0
    ; round the post: offsets tried in order
    crew_offsets dd 0, 0,  20, 0,  0, 20,  20, 20,  -20, 0,  0, -20

section .bss
    ; a field per crew, toward its post. One word more than the grid:
    ; bfs_until runs until a target cell has its distance, and this
    ; one never gets one, so the search runs to the end
    CREW_FIELD_WORDS equ GRID_CELLS + 1
    field_crew     resw CREW_FIELD_WORDS * MAX_CREWS
    field_crew_end:
    bfs_queue_crew resd GRID_CELLS          ; shared: one search at a time
    bfs_st_crew    resb BfsState_size

section .data
    crew_field     dq 0                     ; crew_think's field, walking back

section .text

; int lobby_dist_sq(int x: edi, int y: esi, int gang: edx) -> eax: the
; distance^2 from (x, y) to the middle of that gang's home lobby
lobby_dist_sq:
    mov eax, [home + rdx*4]
    shl eax, 4
    lea rcx, [site_lobbies]
    add rcx, rax
    mov eax, [rcx + 8]
    shr eax, 1
    add eax, [rcx]
    sub eax, edi
    imul eax, eax
    mov edx, [rcx + 12]
    shr edx, 1
    add edx, [rcx + 4]
    sub edx, esi
    imul edx, edx
    add eax, edx
    ret


; int crew_free_spot(int crew: edi, int soldier: esi) -> eax (1: found,
; in crew_x/crew_y; 0: every place round the post is taken)
crew_free_spot:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    xor ebx, ebx
.cf_try:
    mov esi, [crew_post + r12*8]
    add esi, [crew_offsets + rbx*8]
    mov edx, [crew_post + r12*8 + 4]
    add edx, [crew_offsets + rbx*8 + 4]
    mov [crew_x], esi
    mov [crew_y], edx
    mov edi, r13d
    call is_spot_blocked
    test eax, eax
    jz .cf_found
    inc ebx
    cmp ebx, CREW_SPOTS
    jb .cf_try
    xor eax, eax
    jmp .cf_ret
.cf_found:
    mov eax, 1
.cf_ret:
    pop r13
    pop r12
    pop rbx
    ret


; void crews_setup(void) -- game mode, once, after the soldiers spawn:
; the posts, and the members moved to them
;   r15d crews placed   r14d tries left   r12d/r13d the spot
crews_setup:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [game_mode], 0
    je .cs_done
    xor r15d, r15d
.cs_crew:
    cmp r15d, MAX_CREWS
    jae .cs_members
    mov r14d, CREW_TRIES
.cs_try:
    dec r14d
    js .cs_out                    ; nowhere left for this gang
    mov edi, house_points_count
    call rand_range
    lea rcx, [house_points]
    mov r12d, [rcx + rax*8]
    mov r13d, [rcx + rax*8 + 4]
    cmp r12d, CREW_EDGE
    jl .cs_try
    cmp r12d, WORLD_W - CREW_EDGE
    jg .cs_try
    cmp r13d, CREW_EDGE
    jl .cs_try
    cmp r13d, WORLD_H - CREW_EDGE
    jg .cs_try
    ; far from both homes, and for the first half of the tries on this
    ; gang's side (nearer its home than the other's). The gangs take
    ; turns: crew c is gang c & 1
    mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    and edx, 1
    call lobby_dist_sq
    mov ebx, eax                  ; to our home
    mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    and edx, 1
    xor edx, 1
    call lobby_dist_sq            ; to theirs
    cmp eax, CREW_HOME_DIST * CREW_HOME_DIST
    jl .cs_try
    cmp ebx, CREW_HOME_DIST * CREW_HOME_DIST
    jl .cs_try
    cmp r14d, CREW_TRIES / 2
    jl .cs_any_side
    cmp ebx, eax
    jge .cs_try
.cs_any_side:
    ; far from every post so far
    xor ecx, ecx
.cs_spacing:
    cmp ecx, r15d
    jae .cs_take
    mov eax, [crew_post + rcx*8]
    sub eax, r12d
    imul eax, eax
    mov edx, [crew_post + rcx*8 + 4]
    sub edx, r13d
    imul edx, edx
    add eax, edx
    cmp eax, CREW_SPACING * CREW_SPACING
    jl .cs_try
    inc ecx
    jmp .cs_spacing
.cs_take:
    mov [crew_post + r15*8], r12d
    mov [crew_post + r15*8 + 4], r13d
    inc r15d
    jmp .cs_crew
.cs_out:
    and r15d, ~1                  ; the same number for each gang
.cs_members:
    mov [crew_count], r15d
    ; each crew's field, toward its post: searched whole, now
    xor r12d, r12d
.cs_field:
    cmp r12d, r15d
    jae .cs_fields_done
    lea rdi, [bfs_st_crew]
    imul rax, r12, CREW_FIELD_WORDS * 2
    lea rcx, [field_crew]
    add rax, rcx
    mov [rdi + BfsState.field], rax
    lea rcx, [bfs_queue_crew]
    mov [rdi + BfsState.queue], rcx
    mov dword [rdi + BfsState.ready], 0   ; a new field: clear all of it
    call bfs_begin
    lea rdi, [bfs_st_crew]
    mov rax, [rdi + BfsState.field]
    mov word [rax + GRID_CELLS * 2], UNREACHED   ; the target that never is
    mov edi, [crew_post + r12*8]
    mov esi, [crew_post + r12*8 + 4]
    call bfs_seed
    lea rdi, [bfs_st_crew]
    mov esi, GRID_CELLS
    call bfs_until
    inc r12d
    jmp .cs_field
.cs_fields_done:
    ; crew c (gang c & 1; that gang's (c >> 1)th) takes soldiers
    ; gang * NUM_PER_TEAM + NUM_PER_TEAM - ((c >> 1) + 1) * CREW_SIZE, on
    xor r12d, r12d
.cs_m_crew:
    cmp r12d, r15d
    jae .cs_done
    xor r13d, r13d
.cs_m_k:
    cmp r13d, CREW_SIZE
    jae .cs_m_next
    mov eax, r12d
    and eax, 1
    imul eax, eax, NUM_PER_TEAM
    add eax, NUM_PER_TEAM
    mov ecx, r12d
    shr ecx, 1
    inc ecx
    imul ecx, ecx, CREW_SIZE
    sub eax, ecx
    add eax, r13d
    mov ebx, eax                  ; the soldier
    mov [soldier_crew + rbx], r12b
    ; its spot: a free place round the post (else the post itself, and
    ; it starts at home and walks there)
    mov eax, [crew_post + r12*8]
    mov [crew_spot_x + rbx*4], eax
    mov eax, [crew_post + r12*8 + 4]
    mov [crew_spot_y + rbx*4], eax
    mov edi, r12d
    mov esi, ebx
    call crew_free_spot
    imul ecx, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rcx
    test eax, eax
    jz .cs_m_armed
    mov eax, [crew_x]
    mov [crew_spot_x + rbx*4], eax
    mov [r10 + Soldier.x], eax
    mov eax, [crew_y]
    mov [crew_spot_y + rbx*4], eax
    mov [r10 + Soldier.y], eax
.cs_m_armed:
    mov dword [r10 + Soldier.weapon], WEAPON_PISTOL
    inc r13d
    jmp .cs_m_k
.cs_m_next:
    inc r12d
    jmp .cs_m_crew
.cs_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; int crew_think(int soldier: edi) -> eax: a crew member's goal
;   >= 0  fight him (the nearest enemy, and he's on our turf)
;   -1    walk to crew_gx/crew_gy (its spot), round walls by crew_field
;   -2    at its spot: stand
crew_think:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    movsx r12d, byte [soldier_crew + rbx]
    call find_nearest_enemy
    cmp eax, -1
    je .ct_home
    imul ecx, eax, Soldier_size
    lea r10, [soldiers]
    mov edx, [r10 + rcx + Soldier.x]
    sub edx, [crew_post + r12*8]
    imul edx, edx
    mov r8d, [r10 + rcx + Soldier.y]
    sub r8d, [crew_post + r12*8 + 4]
    imul r8d, r8d
    add edx, r8d
    cmp edx, CREW_GUARD * CREW_GUARD
    jle .ct_ret                   ; on our turf: him
.ct_home:
    imul rax, r12, CREW_FIELD_WORDS * 2
    lea rcx, [field_crew]
    add rax, rcx
    mov [crew_field], rax
    mov eax, [crew_spot_x + rbx*4]
    mov [crew_gx], eax
    mov ecx, [crew_spot_y + rbx*4]
    mov [crew_gy], ecx
    imul edx, ebx, Soldier_size
    lea r10, [soldiers]
    sub eax, [r10 + rdx + Soldier.x]
    imul eax, eax
    sub ecx, [r10 + rdx + Soldier.y]
    imul ecx, ecx
    add eax, ecx
    cmp eax, CREW_IDLE * CREW_IDLE
    mov eax, -1                   ; (mov leaves the flags alone)
    jg .ct_ret
    mov eax, -2
.ct_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret


; int crew_respawn(int soldier: edi) -> eax (1: back, at crew_x/crew_y;
; 0: not yet). Called by respawn_soldier for a crew member: the first
; call books the replacement CREW_RESPAWN ticks on
crew_respawn:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, edi
    movsx r12d, byte [soldier_crew + rbx]
    mov eax, [crew_back + rbx*4]
    test eax, eax
    jnz .cr_booked
    mov eax, [ticks]
    add eax, CREW_RESPAWN
    mov [crew_back + rbx*4], eax
    jmp .cr_no
.cr_booked:
    cmp [ticks], eax
    jb .cr_no
    ; not while you're near enough to see it
    lea r10, [soldiers + PLAYER * Soldier_size]
    cmp dword [r10 + Soldier.health], 0
    jle .cr_place
    mov eax, [r10 + Soldier.x]
    sub eax, [crew_post + r12*8]
    imul eax, eax
    mov ecx, [r10 + Soldier.y]
    sub ecx, [crew_post + r12*8 + 4]
    imul ecx, ecx
    add eax, ecx
    cmp eax, CREW_HIDE * CREW_HIDE
    jl .cr_no
.cr_place:
    mov edi, r12d
    mov esi, ebx
    call crew_free_spot
    test eax, eax
    jz .cr_no
    mov eax, [crew_x]
    mov [crew_spot_x + rbx*4], eax
    mov eax, [crew_y]
    mov [crew_spot_y + rbx*4], eax
    mov dword [crew_back + rbx*4], 0
    mov eax, 1
    jmp .cr_ret
.cr_no:
    xor eax, eax
.cr_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret
