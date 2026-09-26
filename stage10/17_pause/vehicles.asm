; vehicles.asm -- the player's vehicle (10.06: the bicycle)
;
; One set of physics for every vehicle, driven by a row of the vehicle
; table (vehicle_types): top speed, acceleration, braking, drag,
; reverse, turn rate, mass, health, capacity, whether you can shoot
; riding it and how much worse. The bicycle is row 0; the moped,
; motorcycle, car and van are rows 1-4 (10.15), with three more
; fields: the collision box (a car's is bigger than your 16 px), the
; sprite's size, and how much of what's shot at you the body stops
; (the car and the van: it comes off the vehicle's health instead).
;
; The vehicle's position is its centre in 1/16 px (so speeds like
; 5.3 px a tick work), its heading 0..255 (0 east, 64 south: the y axis
; points down), its speed signed, in 1/16 px a tick. Riding, you are
; where it is: the player's soldier box is centred on it, so the gangs
; still target you, shoot you and bump into you as before.
;
;   W A S D    point where you want to go (8 ways, like walking): the
;              vehicle turns toward it and pedals; no keys: it brakes
;   E          get on (within MOUNT_REACH) or off (beside it)
;
; Walls stop you and you slide along them. Soldiers don't: riding into
; one bumps him aside and slows you, and at speed it's a ram -- damage
; from your speed and the vehicle's mass, a little to you too, and
; some wear on the vehicle; worn out, it's a wreck until you respawn
; (on a new one).

struc VehicleType
    .top:     resd 1          ; top speed, 1/16 px a tick
    .accel:   resd 1          ; per tick, pedalling
    .brake:   resd 1          ; per tick, braking
    .drag:    resd 1          ; per tick, coasting
    .reverse: resd 1          ; top speed backing up
    .turn:    resd 1          ; heading units (of 256) a tick
    .mass:    resd 1          ; ramming damage per 1/16 px/tick of speed, x/8
    .health:  resd 1
    .capacity: resd 1         ; packages (10.07)
    .aim_penalty: resd 1      ; % off your hit chance while riding
    .sprites: resq 1          ; VEHICLE_FACINGS sprites, .size square
    .palette: resq 1
    .box:     resd 1          ; collision square, px (10.15; 16 to 32)
    .size:    resd 1          ; the sprites' square, px
    .body:    resd 1          ; % of hits on you it takes instead (0: you're out in the open)
    .label_len: resd 1
    .label:   resq 1          ; the scoreboard's name for it
endstruc

; VEH_ROW name, top, accel, brake, drag, turn, mass, health, capacity,
;         aim penalty, box, size, body, sprites, palette, "label"
%macro VEH_ROW 16
    [section .rodata]
    %%label: db %16
    %%label_len equ $ - %%label
    __SECT__
    istruc VehicleType
        at VehicleType.top,     dd %2
        at VehicleType.accel,   dd %3
        at VehicleType.brake,   dd %4
        at VehicleType.drag,    dd %5
        at VehicleType.reverse, dd 0
        at VehicleType.turn,    dd %6
        at VehicleType.mass,    dd %7
        at VehicleType.health,  dd %8
        at VehicleType.capacity, dd %9
        at VehicleType.aim_penalty, dd %10
        at VehicleType.sprites, dq %14
        at VehicleType.palette, dq %15
        at VehicleType.box,     dd %11
        at VehicleType.size,    dd %12
        at VehicleType.body,    dd %13
        at VehicleType.label_len, dd %%label_len
        at VehicleType.label,   dq %%label
    iend
%endmacro

VEH_BICYCLE   equ 0
VEH_MOPED     equ 1           ; (10.15)
VEH_MOTORCYCLE equ 2
VEH_CAR       equ 3
VEH_VAN       equ 4
VEH_TYPES     equ 5
MOUNT_REACH   equ 24          ; px, centre to centre
RAM_MIN       equ 32          ; ramming only counts from 2 px a tick
RAM_SELF      equ 5           ; what a ram costs you
RAM_WEAR      equ 6           ; ... and the vehicle
RAM_COOLDOWN  equ 15          ; ticks between bumps that hurt
BUMP_SHOVE    equ 12          ; px a bumped soldier is pushed aside
PEDAL_ANGLE   equ 40          ; pedal only when this close (of 256) to where the keys point
TURN_SPEED    equ 24          ; turning harder than that: slow to this

section .data
    ; speeds in 1/16 px a tick: the ladder goes up a px or so a rung
    ; (walking is 3 px), and tops out at 6 (the user, 10.06: "if the bike
    ; is this fast by the time you get a car the car is going to be going
    ; too fast"). Turn: heading units (of 256) a tick. Mass: a ram does
    ; speed * mass / 8 (the car's, at top speed, kills anyone). Aim: %
    ; off your hit chance while you shoot from it
    vehicle_types:
    ;       top acc brk drg trn mass  hp cap aim box size body
    VEH_ROW 0, 64,  3,  6,  4, 10,  2,  60, 1, 15, 16, VEHICLE_SPRITE,  0, bicycle_sprites, bicycle_pal, "BIKE"
    VEH_ROW 1, 80,  3,  6,  4,  9,  3,  90, 1, 15, 16, VEHICLE_SPRITE,  0, moped_sprites, moped_pal, "MOPED"
    VEH_ROW 2, 96,  5,  8,  5,  9,  5, 130, 1, 20, 16, VEHICLE_SPRITE,  0, motorcycle_sprites, moto_pal, "MOTORCYCLE"
    VEH_ROW 3, 96,  3,  8,  3,  7, 12, 300, 2, 30, 22, VEHICLE_BIG,    50, car_sprites, car_pal, "CAR"
    VEH_ROW 4, 80,  2,  7,  3,  6, 14, 400, 3, 35, 24, VEHICLE_BIG,    60, van_sprites, van_pal, "VAN"
    times -((($ - vehicle_types) / VehicleType_size) != VEH_TYPES) db 0   ; (a build check: VEH_TYPES rows)
    ; palette slots: 1 tyre, 2 frame, 3 metal, 4 saddle
    ; the heading the keys mean: [dy + 1][dx + 1] (0 east, 64 south)
    key_heading:  db 160, 192, 224,   128, 0, 0,   96, 64, 32
    bicycle_pal:   dd 0, 0xFF141414, 0xFF2828C8, 0xFFAFAAAA, 0xFF1E283C
    ; (10.15) mint green; the courier's yellow; a yellow car, a white van
    moped_pal:     dd 0, 0xFF141414, 0xFF96C83C, 0xFFAFAAAA, 0xFF1E283C
    moto_pal:      dd 0, 0xFF101010, 0xFF28C8F0, 0xFFC8C8C8, 0xFF1E283C
    car_pal:       dd 0, 0xFF141414, 0xFF28C8F0, 0xFF503C32, 0xFF1E9BC8
    van_pal:       dd 0, 0xFF141414, 0xFFE6E6E6, 0xFF503C32, 0xFFC8C8C8
    wreck_pal:     dd 0, 0xFF141414, 0xFF505050, 0xFF6E6E6E, 0xFF1E283C

    veh_type    dd VEH_BICYCLE
    veh_x       dd 0          ; centre, 1/16 px
    veh_y       dd 0
    veh_heading dd 0          ; 0..255
    veh_speed   dd 0          ; 1/16 px a tick, negative backing up
    veh_health  dd 0          ; 0: a wreck
    riding      dd 0
    ram_cool    dd 0
    e_prev      dd 0
    hud_bike  db "   BIKE "
    hud_bike_len equ $ - hud_bike
    hud_ride  db "   E: RIDE"
    hud_ride_len equ $ - hud_ride

section .text

; the corner box [rsp] of vehicle_try's square (0 .. 3: bit 0 right,
; bit 1 bottom) -> edi, esi. Inline in vehicle_try: its registers
%macro VT_CORNER 0
    mov edi, r13d
    mov esi, r14d
    mov eax, [rsp]
    test eax, 1
    jz %%left
    add edi, r15d
%%left:
    test eax, 2
    jz %%top
    add esi, r15d
%%top:
%endmacro

; rax = the VehicleType of veh_type
%macro VEH_TYPE 0
    imul eax, [veh_type], VehicleType_size
    lea rcx, [vehicle_types]
    add rax, rcx
%endmacro


; void vehicle_spawn(void) -- a new vehicle under the player, who's on
; it (player_spawn)
vehicle_spawn:
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov eax, [r10 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    shl eax, 4
    mov [veh_x], eax
    mov eax, [r10 + Soldier.y]
    add eax, SOLDIER_SIZE / 2
    shl eax, 4
    mov [veh_y], eax
    mov dword [veh_heading], 0
    mov dword [veh_speed], 0
    mov dword [ram_cool], 0
    VEH_TYPE
    mov eax, [rax + VehicleType.health]
    add eax, [bike_bonus]         ; the shop's bike frame (10.10)
    mov [veh_health], eax
    mov dword [riding], 1
    ret


; void vehicle_mount(void) -- E, pressed (not held): off if riding, on
; if close enough to a vehicle that isn't a wreck
vehicle_mount:
    push rbx
    push r12
    push r13
    mov r8, [key_state]
    movzx eax, byte [r8 + SCANCODE_E]
    mov ecx, [e_prev]
    mov [e_prev], eax
    test eax, eax
    jz .vm_done
    test ecx, ecx
    jnz .vm_done
    lea r12, [soldiers + PLAYER * Soldier_size]
    cmp dword [riding], 0
    jne .vm_off
    ; ---- on: near enough, and it's not a wreck ----
    cmp dword [veh_health], 0
    jle .vm_done
    mov eax, [veh_x]
    sar eax, 4
    sub eax, [r12 + Soldier.x]
    sub eax, SOLDIER_SIZE / 2
    imul eax, eax
    mov ecx, [veh_y]
    sar ecx, 4
    sub ecx, [r12 + Soldier.y]
    sub ecx, SOLDIER_SIZE / 2
    imul ecx, ecx
    add eax, ecx
    cmp eax, MOUNT_REACH * MOUNT_REACH
    jg .vm_done
    mov dword [riding], 1
    mov dword [veh_speed], 0
    call vehicle_carry
    jmp .vm_done
.vm_off:
    ; ---- off: stop, and step down beside it (the first clear side) ----
    mov dword [veh_speed], 0
    xor ebx, ebx
.vm_side:
    cmp ebx, 4
    jge .vm_done                  ; boxed in: stay on
    lea rcx, [dismount_offsets]
    mov r13d, [veh_x]
    sar r13d, 4
    sub r13d, SOLDIER_SIZE / 2
    add r13d, [rcx + rbx*8]       ; x
    mov edx, [veh_y]
    sar edx, 4
    sub edx, SOLDIER_SIZE / 2
    add edx, [rcx + rbx*8 + 4]    ; y
    mov edi, PLAYER
    mov esi, r13d
    call is_spot_blocked
    test eax, eax
    jnz .vm_next_side
    lea rcx, [dismount_offsets]   ; (y again: the call took edx)
    mov edx, [veh_y]
    sar edx, 4
    sub edx, SOLDIER_SIZE / 2
    add edx, [rcx + rbx*8 + 4]
    mov [r12 + Soldier.x], r13d
    mov [r12 + Soldier.y], edx
    mov dword [riding], 0
    jmp .vm_done
.vm_next_side:
    inc ebx
    jmp .vm_side
.vm_done:
    pop r13
    pop r12
    pop rbx
    ret


; void vehicle_carry(void) -- the player's box, centred on the vehicle
vehicle_carry:
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov eax, [veh_x]
    sar eax, 4
    sub eax, SOLDIER_SIZE / 2
    mov [r10 + Soldier.x], eax
    mov eax, [veh_y]
    sar eax, 4
    sub eax, SOLDIER_SIZE / 2
    mov [r10 + Soldier.y], eax
    ret


; int soldier_at(int x: edi, int y: esi) -> eax: a living soldier (not
; you) whose box overlaps a soldier's box with its corner at (x, y), or -1
soldier_at:
    lea r8, [soldiers]
    xor ecx, ecx
.sa_loop:
    cmp ecx, PLAYER
    je .sa_next
    cmp dword [r8 + Soldier.health], 0
    jle .sa_next
    mov eax, [r8 + Soldier.x]
    sub eax, edi
    cmp eax, -(SOLDIER_SIZE - 1)
    jl .sa_next
    cmp eax, SOLDIER_SIZE - 1
    jg .sa_next
    mov eax, [r8 + Soldier.y]
    sub eax, esi
    cmp eax, -(SOLDIER_SIZE - 1)
    jl .sa_next
    cmp eax, SOLDIER_SIZE - 1
    jg .sa_next
    mov eax, ecx
    ret
.sa_next:
    add r8, Soldier_size
    inc ecx
    cmp ecx, TOTAL_SOLDIERS
    jb .sa_loop
    mov eax, -1
    ret


; int vehicle_try(int cx: edi, int cy: esi) -> eax: move the vehicle's
; centre to (cx, cy) (1/16 px) if its box there is clear: 0 moved,
; 1 a wall or prop in the way, 2 + i soldier i in the way. (10.15) The
; box is the type's: a square up to 32 px is covered by four soldier-
; sized boxes, one in each corner (all the same one when it's 16)
;   ebx cx   r12d cy   r13d the box corner x   r14d y   r15d box - 16
;   (stack) which corner
vehicle_try:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov ebx, edi
    mov r12d, esi
    VEH_TYPE
    mov r15d, [rax + VehicleType.box]
    mov r13d, ebx
    sar r13d, 4
    mov eax, r15d
    shr eax, 1
    sub r13d, eax
    mov r14d, r12d
    sar r14d, 4
    sub r14d, eax
    sub r15d, SOLDIER_SIZE
    ; walls, each corner
    mov dword [rsp], 0
.vt_wall:
    VT_CORNER
    call is_box_blocked
    test eax, eax
    jz .vt_wall_next
    mov eax, 1
    jmp .vt_done
.vt_wall_next:
    inc dword [rsp]
    cmp dword [rsp], 4
    jb .vt_wall
    ; soldiers, each corner
    mov dword [rsp], 0
.vt_soldier:
    VT_CORNER
    call soldier_at
    cmp eax, -1
    je .vt_soldier_next
    add eax, 2
    jmp .vt_done
.vt_soldier_next:
    inc dword [rsp]
    cmp dword [rsp], 4
    jb .vt_soldier
.vt_clear:
    mov [veh_x], ebx
    mov [veh_y], r12d
    xor eax, eax
.vt_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void vehicle_ride(void) -- a tick of riding. W A S D point where you
; want to go (8 ways, like walking): the vehicle turns toward it at its
; turn rate, and pedals while it's pointing roughly that way (slowing
; for a sharp turn). No keys: it brakes to a stop. Then it moves,
; sliding along walls and bumping through soldiers, and carries you.
; (10.06, after the first ride: steering with A/D and pedalling with W
; was "insanely hard to control")
;   r12 the VehicleType   ebx dx   r13d dy   r14d what was hit
vehicle_ride:
    push rbx
    push r12
    push r13
    push r14
    push r15
    VEH_TYPE
    mov r12, rax
    cmp dword [ram_cool], 0
    jle .vr_cool
    dec dword [ram_cool]
.vr_cool:
    ; ---- where the keys point: (dx, dy) each -1, 0 or 1 ----
    mov r8, [key_state]
    xor ecx, ecx
    movzx eax, byte [r8 + SCANCODE_D]
    add ecx, eax
    movzx eax, byte [r8 + SCANCODE_A]
    sub ecx, eax
    xor edx, edx
    movzx eax, byte [r8 + SCANCODE_S]
    add edx, eax
    movzx eax, byte [r8 + SCANCODE_W]
    sub edx, eax
    mov eax, ecx
    or eax, edx
    jnz .vr_steer
    ; no keys: brake
    mov eax, [veh_speed]
    sub eax, [r12 + VehicleType.brake]
    jge .vr_speed
    xor eax, eax
    jmp .vr_speed
.vr_steer:
    ; the heading those keys mean (key_heading, 3 x 3: dy row, dx column)
    lea eax, [edx + 1]
    imul eax, eax, 3
    lea eax, [eax + ecx + 1]
    lea rcx, [key_heading]
    movzx eax, byte [rcx + rax]
    ; turn toward it by at most the turn rate, the short way round
    sub eax, [veh_heading]
    add eax, 128
    and eax, 255
    sub eax, 128                  ; -128 .. 127
    mov r9d, eax                  ; how far off we are
    mov ecx, [r12 + VehicleType.turn]
    cmp eax, ecx
    jle .vr_not_left
    mov eax, ecx
.vr_not_left:
    neg ecx
    cmp eax, ecx
    jge .vr_turned
    mov eax, ecx
.vr_turned:
    add [veh_heading], eax
    and dword [veh_heading], 255
    ; pedal if it's pointing roughly that way, else slow for the turn
    mov eax, r9d
    neg eax
    cmovs eax, r9d                ; |off|
    cmp eax, PEDAL_ANGLE
    jg .vr_turning
    mov eax, [veh_speed]
    add eax, [r12 + VehicleType.accel]
    cmp eax, [r12 + VehicleType.top]
    jle .vr_speed
    mov eax, [r12 + VehicleType.top]
    jmp .vr_speed
.vr_turning:
    mov eax, [veh_speed]
    sub eax, [r12 + VehicleType.drag]
    cmp eax, TURN_SPEED
    jge .vr_speed
    mov eax, [veh_speed]          ; already slow enough: hold it
.vr_speed:
    mov [veh_speed], eax
    ; ---- move: speed along the heading ----
    lea rcx, [sin_table]
    mov edx, [veh_heading]
    add edx, 64
    and edx, 255
    movsx eax, word [rcx + rdx*2]         ; cos
    imul eax, [veh_speed]
    sar eax, 8
    mov ebx, eax                          ; dx, 1/16 px
    mov edx, [veh_heading]
    movsx eax, word [rcx + rdx*2]         ; sin
    imul eax, [veh_speed]
    sar eax, 8
    mov r13d, eax                         ; dy
    mov eax, ebx
    or eax, r13d
    jz .vr_carry                          ; not moving
    mov edi, [veh_x]
    add edi, ebx
    mov esi, [veh_y]
    add esi, r13d
    call vehicle_try
    test eax, eax
    jz .vr_carry
    cmp eax, 2
    jl .vr_slide
    ; ---- a soldier in the way: bump him aside and ride on ----
    lea edi, [eax - 2]
    call vehicle_bump
    mov eax, [veh_x]
    add eax, ebx
    mov [veh_x], eax
    mov eax, [veh_y]
    add eax, r13d
    mov [veh_y], eax
    jmp .vr_carry
.vr_slide:
    ; a wall: try each axis alone, slower
    mov edi, [veh_x]
    add edi, ebx
    mov esi, [veh_y]
    call vehicle_try
    test eax, eax
    jz .vr_slid
    mov edi, [veh_x]
    mov esi, [veh_y]
    add esi, r13d
    call vehicle_try
    test eax, eax
    jz .vr_slid
    mov dword [veh_speed], 0              ; head on: stopped
    jmp .vr_carry
.vr_slid:
    mov eax, [veh_speed]
    imul eax, eax, 3
    sar eax, 2                            ; 3/4
    mov [veh_speed], eax
.vr_carry:
    call vehicle_carry
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void vehicle_bump(int victim: edi) -- r12 the VehicleType (vehicle_
; ride's). Riding into someone: at speed (RAM_MIN) and off cooldown, a
; ram -- damage |speed| * mass / 8 to him, RAM_SELF to you, RAM_WEAR to
; the vehicle, a third of the speed gone; slower, a quarter of the
; speed gone. Either way he's shoved BUMP_SHOVE px aside, off your
; line (if there's room), and you ride on through.
;   ebx victim   r13 his Soldier   r14d |speed|
vehicle_bump:
    push rbx
    push r13
    push r14
    mov ebx, edi
    imul eax, ebx, Soldier_size
    lea r13, [soldiers]
    add r13, rax
    mov eax, [veh_speed]
    mov r14d, eax
    neg r14d
    cmovs r14d, eax
    cmp dword [ram_cool], 0
    jg .vb_shove                  ; bumped him just now: just shove
    mov dword [ram_cool], RAM_COOLDOWN
    lea rcx, [hit_flash]
    mov dword [rcx + rbx*4], FLASH_FRAMES
    cmp r14d, RAM_MIN
    jl .vb_nudge
    ; ---- a ram ----
    mov esi, r14d
    imul esi, [r12 + VehicleType.mass]
    sar esi, 3
    mov edi, ebx
    call event_damage
    test eax, eax
    jz .vb_self
    mov ecx, [r13 + Soldier.team]
    mov eax, FACTION_PLAYER
    HOSTILE rax, rax, rcx
    jz .vb_self
    inc dword [score + FACTION_PLAYER * 4]
    inc dword [player_kills]
.vb_self:
    mov edi, PLAYER
    mov esi, RAM_SELF
    call event_damage
    mov eax, [veh_speed]
    imul eax, eax, 2
    cdq
    mov ecx, 3
    idiv ecx                      ; 2/3
    mov [veh_speed], eax
    sub dword [veh_health], RAM_WEAR
    jg .vb_shove
    mov dword [veh_health], 0     ; a wreck: you're off it
    mov dword [veh_speed], 0
    mov dword [riding], 0
    jmp .vb_shove
.vb_nudge:
    mov eax, [veh_speed]
    imul eax, eax, 3
    sar eax, 2                    ; 3/4
    mov [veh_speed], eax
.vb_shove:
    ; which side of our line is he? (cross product of the heading and
    ; the vector to him); push him that way, square to the heading
    lea rcx, [sin_table]
    mov edx, [veh_heading]
    movsx r8d, word [rcx + rdx*2]         ; sin
    add edx, 64
    and edx, 255
    movsx r9d, word [rcx + rdx*2]         ; cos
    mov eax, [r13 + Soldier.x]
    add eax, SOLDIER_SIZE / 2
    mov r10d, [veh_x]
    sar r10d, 4
    sub eax, r10d                         ; to him: x
    mov ecx, [r13 + Soldier.y]
    add ecx, SOLDIER_SIZE / 2
    mov r10d, [veh_y]
    sar r10d, 4
    sub ecx, r10d                         ; y
    imul ecx, r9d                         ; cos * dy
    imul eax, r8d                         ; sin * dx
    sub ecx, eax                          ; > 0: he's on our right
    ; the push: right is (-sin, cos), left is (sin, -cos)
    mov eax, r8d
    neg eax                               ; -sin
    mov edx, r9d                          ; cos
    test ecx, ecx
    jge .vb_side
    neg eax
    neg edx
.vb_side:
    imul eax, eax, BUMP_SHOVE
    sar eax, 8
    add eax, [r13 + Soldier.x]
    imul edx, edx, BUMP_SHOVE
    sar edx, 8
    add edx, [r13 + Soldier.y]
    mov r14d, eax
    push rdx
    mov edi, eax
    mov esi, edx
    call is_box_blocked
    pop rdx
    test eax, eax
    jnz .vb_done                  ; no room: he stays
    mov [r13 + Soldier.x], r14d
    mov [r13 + Soldier.y], edx
.vb_done:
    pop r14
    pop r13
    pop rbx
    ret


; void draw_vehicle(void) -- the vehicle, under its rider (drawing only)
;   r10d its sprites' size (10.15: the car's and the van's are bigger)
draw_vehicle:
    sub rsp, 8
    cmp dword [player_on], 0
    je .dv_done
    VEH_TYPE
    mov rdx, [rax + VehicleType.sprites]
    mov rcx, [rax + VehicleType.palette]
    mov r10d, [rax + VehicleType.size]
    cmp dword [veh_health], 0
    jg .dv_pal
    lea rcx, [wreck_pal]
.dv_pal:
    mov eax, [veh_heading]
    add eax, 128 / VEHICLE_FACINGS        ; round to the nearest facing
    shr eax, 4                            ; 256 / VEHICLE_FACINGS (16)
    and eax, VEHICLE_FACINGS - 1
    imul eax, r10d
    imul eax, r10d
    add rdx, rax
    mov r9d, r10d
    shr r10d, 1
    mov edi, [veh_x]
    sar edi, 4
    sub edi, r10d
    mov esi, [veh_y]
    sar esi, 4
    sub esi, r10d
    xor r8d, r8d
    mov [spr_h], r9d
    call draw_sprite_ex
.dv_done:
    add rsp, 8
    ret

section .data
    ; where to step off: left, right, above, below the vehicle's centre
    dismount_offsets: dd -20, 0,  20, 0,  0, -20,  0, 20
