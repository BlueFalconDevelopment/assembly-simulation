; pathfinding.asm -- the walkable grid and the flow fields (BFS, flow_waypoint)
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text


; int range_blocked(int x0: edi, int y0: esi, int x1: edx, int y1: ecx) -> eax
; Is any corner position in [x0, x1] x [y0, y1] walk-blocked in the
; blockmap? (All four are already inside the blockmap.)
range_blocked:
    lea r8, [blockmap]
    mov r9d, esi
.rb_row:
    cmp r9d, ecx
    jg .rb_clear
    imul r10d, r9d, BM_W
    add r10d, edi                 ; this row's first byte
    mov r11d, edx
    sub r11d, edi                 ; bytes to check after it
.rb_col:
    test byte [r8 + r10], BLOCK_WALK
    jnz .rb_blocked
    inc r10d
    dec r11d
    jns .rb_col
    inc r9d
    jmp .rb_row
.rb_blocked:
    mov eax, 1
    ret
.rb_clear:
    xor eax, eax
    ret


; CLAMP_TO reg, hi: reg = min(max(reg, 0), hi)
%macro CLAMP_TO 2
    test %1, %1
    jns %%lo_ok
    xor %1, %1
%%lo_ok:
    cmp %1, %2
    jle %%hi_ok
    mov %1, %2
%%hi_ok:
%endmacro

; void build_walkable(void)
; walkable[cell] = 1 if a soldier with its corner ANYWHERE in the cell
; would miss every wall and prop. With the blockmap that's just "no
; blocked byte in the cell's corner range". Being this strict means a
; soldier moving between walkable cells can never clip anything,
; whatever pixel it's on.
build_walkable:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [walkable]
    xor r12d, r12d                ; cy
.bw_row:
    cmp r12d, GRID_H
    jge .bw_done
    imul r14d, r12d, CELL         ; y_hi = min(CELL*cy, WORLD_H - SIZE)
    mov r15d, r14d
    sub r15d, CELL - 1            ; y_lo = max(CELL*cy - (CELL-1), 0)
    jns .bw_ylo_ok
    xor r15d, r15d
.bw_ylo_ok:
    cmp r14d, WORLD_H - SOLDIER_SIZE
    jle .bw_yhi_ok
    mov r14d, WORLD_H - SOLDIER_SIZE
.bw_yhi_ok:
    xor r13d, r13d                ; cx
.bw_col:
    cmp r13d, GRID_W
    jge .bw_row_next
    imul r8d, r13d, CELL          ; x_hi
    mov edi, r8d
    sub edi, CELL - 1             ; x_lo
    jns .bw_xlo_ok
    xor edi, edi
.bw_xlo_ok:
    cmp r8d, WORLD_W - SOLDIER_SIZE
    jle .bw_xhi_ok
    mov r8d, WORLD_W - SOLDIER_SIZE
.bw_xhi_ok:
    mov edx, r8d                  ; x_hi
    mov esi, r15d                 ; y_lo
    mov ecx, r14d                 ; y_hi
    call range_blocked
    xor eax, 1
    mov [rbx], al
    inc rbx
    inc r13d
    jmp .bw_col
.bw_row_next:
    inc r12d
    jmp .bw_row
.bw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void bfs_begin(BfsState *st: rdi) -- all cells UNREACHED, queue
; empty. The first time, the whole field is cleared; after that only
; the cells the last search reached (they're all in its queue), which
; is usually far fewer (9.03).
bfs_begin:
    mov [bfs_cur], rdi
    mov r8, [rdi + BfsState.field]
    cmp dword [rdi + BfsState.ready], 0
    jne .bb_queued
    mov dword [rdi + BfsState.ready], 1
    push rdi
    mov rdi, r8
    mov ecx, GRID_CELLS
    mov ax, UNREACHED
    cld
    rep stosw
    pop rdi
    jmp .bb_empty
.bb_queued:
    mov r9, [rdi + BfsState.queue]
    mov ecx, [rdi + BfsState.tail]
.bb_clear:
    test ecx, ecx
    jz .bb_empty
    dec ecx
    mov eax, [r9 + rcx*4]
    mov word [r8 + rax*2], UNREACHED
    jmp .bb_clear
.bb_empty:
    mov dword [rdi + BfsState.head], 0
    mov dword [rdi + BfsState.tail], 0
    ret


; void bfs_seed(int x: edi, int y: esi) -- the cell holding corner
; (x, y) is a source: distance 0. A source cell doesn't have to be
; walkable (a soldier can stand in a cell that isn't fully clear).
bfs_seed:
    CELL_OF esi
    CELL_OF edi
    imul esi, esi, GRID_W
    add esi, edi                  ; cell index
    mov rdi, [bfs_cur]
    mov r8, [rdi + BfsState.field]
    cmp word [r8 + rsi*2], 0
    je .bs_done                   ; already a source
    mov word [r8 + rsi*2], 0
    mov eax, [rdi + BfsState.tail]
    mov r9, [rdi + BfsState.queue]
    mov [r9 + rax*4], esi
    inc dword [rdi + BfsState.tail]
.bs_done:
    ret


; bfs_nbrs bits: this neighbour is inside the grid and walkable
NB_RIGHT equ 1
NB_LEFT  equ 2
NB_DOWN  equ 4
NB_UP    equ 8

; void build_nbrs(void) -- once, after build_walkable: bfs_nbrs[cell]
; gets an NB_* bit for each neighbour inside the grid that's walkable.
; (Whether the cell itself is walkable doesn't matter: a source can be
; a cell that isn't, as bfs_seed says.)
;   ecx cy   edx cx   rax cell   r10d bits
build_nbrs:
    lea r8, [walkable]
    lea r9, [bfs_nbrs]
    xor ecx, ecx
.bn_row:
    cmp ecx, GRID_H
    jge .bn_done
    xor edx, edx
.bn_col:
    cmp edx, GRID_W
    jge .bn_row_next
    imul eax, ecx, GRID_W
    add eax, edx
    xor r10d, r10d
    cmp edx, GRID_W - 1
    jge .bn_no_right
    cmp byte [r8 + rax + 1], 0
    je .bn_no_right
    or r10d, NB_RIGHT
.bn_no_right:
    test edx, edx
    jz .bn_no_left
    cmp byte [r8 + rax - 1], 0
    je .bn_no_left
    or r10d, NB_LEFT
.bn_no_left:
    cmp ecx, GRID_H - 1
    jge .bn_no_down
    cmp byte [r8 + rax + GRID_W], 0
    je .bn_no_down
    or r10d, NB_DOWN
.bn_no_down:
    test ecx, ecx
    jz .bn_no_up
    cmp byte [r8 + rax - GRID_W], 0
    je .bn_no_up
    or r10d, NB_UP
.bn_no_up:
    mov [r9 + rax], r10b
    inc edx
    jmp .bn_col
.bn_row_next:
    inc ecx
    jmp .bn_row
.bn_done:
    ret


; BFS_VISIT offset, bit: visit neighbour n = cell + offset, if the
; cell's bfs_nbrs has that bit (inside the grid, walkable) and n is
; unvisited. Registers as in bfs_run.
%macro BFS_VISIT 2
    test r13d, %2
    jz %%skip
    lea eax, [ebx + %1]
    cmp word [r8 + rax*2], UNREACHED
    jne %%skip
    mov [r8 + rax*2], r12w
    mov [r9 + r11*4], eax
    inc r11d
%%skip:
%endmacro

; void bfs_until(BfsState *st: rdi, int target: esi)
; Breadth-first from the seeded sources, over 4-connected walkable
; cells, carrying on from where this field's search last stopped, until
; the target cell has its distance or the search is done. Each cell is
; queued at most once, so the queue never needs to wrap. The
; neighbours go right, left, down, up, as they always have.
;
; Stopping and carrying on changes nothing about the answers: the cells
; are reached in the same order, with the same distances, as one search
; run to the end. And when a cell gets its distance d, every cell
; closer than d already has its own -- which is all flow_waypoint
; needs (9.03).
;   r8 field   r9 queue   r10 bfs_nbrs   r11d tail   r14d head
;   rsi target   ebx cell   r12w its distance + 1   r13d its NB_* bits
bfs_until:
    push rbx
    push r12
    push r13
    push r14
    mov r8, [rdi + BfsState.field]
    mov r9, [rdi + BfsState.queue]
    lea r10, [bfs_nbrs]
    mov r11d, [rdi + BfsState.tail]
    mov r14d, [rdi + BfsState.head]
.bu_loop:
    cmp word [r8 + rsi*2], UNREACHED
    jne .bu_stop                  ; the target has its distance
    cmp r14d, r11d
    jge .bu_stop                  ; nothing left: it never will
    mov ebx, [r9 + r14*4]
    inc r14d
    movzx r12d, word [r8 + rbx*2]
    inc r12d
    movzx r13d, byte [r10 + rbx]
    BFS_VISIT 1, NB_RIGHT
    BFS_VISIT -1, NB_LEFT
    BFS_VISIT GRID_W, NB_DOWN
    BFS_VISIT -GRID_W, NB_UP
    jmp .bu_loop
.bu_stop:
    mov [rdi + BfsState.head], r14d
    mov [rdi + BfsState.tail], r11d
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void bfs_ensure(uint16 *field: rsi, int cell: edi)
; Search this field far enough that flow_waypoint, standing in cell,
; reads the same distances it would from a finished search: the cell's
; own distance (then every closer cell has its own too) -- or, for a
; cell that isn't walkable and isn't a source (it never gets one), the
; distances of its walkable neighbours, all 8.
;   rbx state   r12d cell   r13d cx   r14d cy   r15d direction
bfs_ensure:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [bfs_st_pk]
    lea rax, [field_pk]
    cmp rsi, rax
    je .be_have
    ; a faction's field: which one, from where it lies in field_for
    mov rax, rsi
    lea rcx, [field_for]
    sub rax, rcx
    xor edx, edx
    mov ecx, GRID_CELLS * 2
    div rcx                       ; rax = faction
    imul rax, rax, BfsState_size
    lea rbx, [bfs_states]
    add rbx, rax
.be_have:
    mov r12d, edi
    cmp word [rsi + r12*2], UNREACHED
    jne .be_done                  ; already has its distance
    lea rax, [walkable]
    cmp byte [rax + r12], 0
    je .be_neighbours
    mov rdi, rbx
    mov esi, r12d
    call bfs_until
    jmp .be_done
.be_neighbours:
    mov eax, r12d
    xor edx, edx
    mov ecx, GRID_W
    div ecx
    mov r13d, edx                 ; cx
    mov r14d, eax                 ; cy
    xor r15d, r15d
.be_dir:
    cmp r15d, 8
    jge .be_done
    lea rax, [flow_dirs]
    movsx ecx, byte [rax + r15*2]
    movsx edx, byte [rax + r15*2 + 1]
    add ecx, r13d                 ; nx
    add edx, r14d                 ; ny
    cmp ecx, GRID_W
    jae .be_next                  ; unsigned: catches -1 too
    cmp edx, GRID_H
    jae .be_next
    imul edx, edx, GRID_W
    add edx, ecx
    lea rax, [walkable]
    cmp byte [rax + rdx], 0
    je .be_next
    mov rdi, rbx
    mov esi, edx
    call bfs_until
.be_next:
    inc r15d
    jmp .be_dir
.be_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void build_fields(void) -- the distance fields for this tick: one per
; faction, whose sources are everyone that faction fights (10.02: with
; two gangs, the Crips' field is the old "toward the Bloods"), and one
; toward the pickups.
; 9.03: only their sources. Each search runs as far as it's needed, when
; it's needed: flow_waypoint calls bfs_ensure.
build_fields:
    push rbx
    push r12
    push r13
    lea r13, [bfs_states]
    xor r12d, r12d                ; faction
.bf_faction:
    mov rdi, r13
    call bfs_begin
    lea rbx, [soldiers]
.bf_soldier:
    cmp dword [rbx + Soldier.health], 0
    jle .bf_soldier_next
    mov eax, [rbx + Soldier.team]
    HOSTILE rax, r12, rax         ; does this faction fight them?
    jz .bf_soldier_next
    mov edi, [rbx + Soldier.x]
    mov esi, [rbx + Soldier.y]
    call bfs_seed
.bf_soldier_next:
    add rbx, Soldier_size
    lea rax, [soldiers + TOTAL_SOLDIERS * Soldier_size]
    cmp rbx, rax
    jb .bf_soldier
    add r13, BfsState_size
    inc r12d
    cmp r12d, MAX_FACTIONS
    jb .bf_faction

    lea rdi, [bfs_st_pk]
    call bfs_begin
    lea rbx, [pickups]
.bf_pickup:
    cmp dword [rbx + Pickup.active], 0
    je .bf_pickup_next
    mov edi, [rbx + Pickup.x]
    mov esi, [rbx + Pickup.y]
    call bfs_seed
.bf_pickup_next:
    add rbx, Pickup_size
    lea rax, [pickups + MAX_PICKUPS * Pickup_size]
    cmp rbx, rax
    jb .bf_pickup
    pop r13
    pop r12
    pop rbx
    ret


; int flow_waypoint(int self: edi, uint16 *field: rsi) -> eax (1 or 0)
; Where to walk next on the field. Returns a cell centre in
; flow_wx/flow_wy, or 0 if no neighbour is closer to the goal.
;
; Pass 1 collects every neighbour (of the 8 around the soldier's own
; cell) that is walkable and strictly closer than the soldier's own
; cell. A diagonal only counts if both cells it cuts past are walkable
; too, so the step can't clip a wall's corner.
;
; Pass 2 tries them closest first, and takes the first one whose next
; step (the same MOVE_SPEED-clamped step .clear_step will take) isn't
; blocked by another soldier. 09 only ever returned the single best
; cell, so two teammates whose best steps crossed blocked each other
; forever, even when one had an equally good way round (10's README).
; If every candidate is blocked, it returns the best one anyway, and
; .clear_step's usual fallbacks take over.
;
; Ties (in both passes) go to the first in flow_dirs, with dx flipped
; for team 1: "forward" first, for both teams.
FW_CAND   equ 0          ; 8 x (dword distance, dword cell)
FW_SELF   equ 64
FW_X      equ 68
FW_Y      equ 72
FW_FIRST  equ 76         ; the closest candidate's cell, for the fallback
FW_FIELD  equ 80         ; the field, across bfs_ensure
FW_LOCALS equ 96         ; 5 pushes + 96 keeps rsp 16-byte aligned

; FW_CENTRE cell_reg: flow_wx/flow_wy = that cell's centre. Clobbers
; eax, ecx, edx.
%macro FW_CENTRE 1
    mov eax, %1
    xor edx, edx
    mov ecx, GRID_W
    div ecx                       ; eax = cy, edx = cx
    imul edx, edx, CELL
    sub edx, CELL / 2             ; centre of [CELL*k - (CELL-1), CELL*k]
    imul eax, eax, CELL
    sub eax, CELL / 2
    CLAMP_TO edx, WORLD_W - SOLDIER_SIZE
    CLAMP_TO eax, WORLD_H - SOLDIER_SIZE
    mov [flow_wx], edx
    mov [flow_wy], eax
%endmacro

; CLAMP_STEP reg: reg = min(max(reg, -MOVE_SPEED), MOVE_SPEED)
%macro CLAMP_STEP 1
    cmp %1, MOVE_SPEED
    jle %%hi_ok
    mov %1, MOVE_SPEED
%%hi_ok:
    cmp %1, -MOVE_SPEED
    jge %%lo_ok
    mov %1, -MOVE_SPEED
%%lo_ok:
%endmacro

flow_waypoint:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FW_LOCALS
    mov [rsp + FW_SELF], edi
    imul eax, edi, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.team]
    mov r14d, [fwd_sign + rax*4]  ; "forward": toward the enemy's home
    mov eax, [r10 + Soldier.x]
    mov [rsp + FW_X], eax
    mov eax, [r10 + Soldier.y]
    mov [rsp + FW_Y], eax
    mov r12d, [r10 + Soldier.x]
    CELL_OF r12d
    mov r13d, [r10 + Soldier.y]
    CELL_OF r13d
    imul eax, r13d, GRID_W
    add eax, r12d
    ; search the field as far as this needs (9.03)
    mov [rsp + FW_FIELD], rsi
    mov edi, eax
    call bfs_ensure
    mov rsi, [rsp + FW_FIELD]
    imul eax, r13d, GRID_W
    add eax, r12d
    movzx r15d, word [rsi + rax*2]   ; own cell's distance
    xor ebx, ebx                  ; candidates found

    ; ---- pass 1: collect the closer neighbours ----
    ;   r12d cx   r13d cy   r14d forward sign   r15d own distance
    ;   ebx count   rdi dir index   rsi field
    lea r10, [walkable]
    lea r11, [flow_dirs]
    xor edi, edi
.fw_dir:
    cmp edi, 8
    jge .fw_collected
    movsx r8d, byte [r11 + rdi*2]
    imul r8d, r14d                ; dx, forward-adjusted
    movsx r9d, byte [r11 + rdi*2 + 1]
    add r8d, r12d                 ; nx
    add r9d, r13d                 ; ny
    cmp r8d, GRID_W
    jae .fw_next                  ; unsigned: catches -1 too
    cmp r9d, GRID_H
    jae .fw_next
    imul eax, r9d, GRID_W
    add eax, r8d                  ; n
    cmp byte [r10 + rax], 0
    je .fw_next
    cmp r8d, r12d
    je .fw_straight
    cmp r9d, r13d
    je .fw_straight
    imul ecx, r13d, GRID_W        ; diagonal: (nx, cy) and (cx, ny) too
    add ecx, r8d
    cmp byte [r10 + rcx], 0
    je .fw_next
    imul ecx, r9d, GRID_W
    add ecx, r12d
    cmp byte [r10 + rcx], 0
    je .fw_next
.fw_straight:
    movzx ecx, word [rsi + rax*2]
    cmp ecx, r15d
    jae .fw_next                  ; not closer than where we are
    mov [rsp + FW_CAND + rbx*8], ecx
    mov [rsp + FW_CAND + rbx*8 + 4], eax
    inc ebx
.fw_next:
    inc edi
    jmp .fw_dir

.fw_collected:
    xor eax, eax
    test ebx, ebx
    jz .fw_ret                    ; nothing closer: caller side-steps
    mov dword [rsp + FW_FIRST], -1

    ; ---- pass 2: closest first, skipping steps another soldier blocks ----
    ;   ebx count   r12d best index this round   r13d its distance
.fw_pick:
    mov r12d, -1
    mov r13d, 0xFFFFFFFF
    xor ecx, ecx
.fw_scan:
    cmp ecx, ebx
    jge .fw_scanned
    mov eax, [rsp + FW_CAND + rcx*8]
    cmp eax, r13d
    jae .fw_scan_next             ; strictly closer: ties keep dir order
    mov r13d, eax
    mov r12d, ecx
.fw_scan_next:
    inc ecx
    jmp .fw_scan
.fw_scanned:
    cmp r12d, -1
    je .fw_all_blocked
    mov dword [rsp + FW_CAND + r12*8], 0xFFFFFFFF   ; used up
    mov r15d, [rsp + FW_CAND + r12*8 + 4]           ; its cell
    cmp dword [rsp + FW_FIRST], -1
    jne .fw_have_first
    mov [rsp + FW_FIRST], r15d
.fw_have_first:
    FW_CENTRE r15d
    mov esi, [flow_wx]
    sub esi, [rsp + FW_X]
    CLAMP_STEP esi
    add esi, [rsp + FW_X]
    mov edx, [flow_wy]
    sub edx, [rsp + FW_Y]
    CLAMP_STEP edx
    add edx, [rsp + FW_Y]
    mov edi, [rsp + FW_SELF]
    call is_spot_blocked
    test eax, eax
    jnz .fw_pick                  ; someone's there: try the next closest
    mov eax, 1
    jmp .fw_ret

.fw_all_blocked:
    mov r15d, [rsp + FW_FIRST]
    FW_CENTRE r15d
    mov eax, 1
.fw_ret:
    add rsp, FW_LOCALS
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================
; Scoreboard (drawing only: reads the game state, never writes it,
; never draws a random number)
; ============================================================

; void draw_text(char *s: rdi, int len: esi, int x: edx, int y: ecx,
;                uint32 color: r8d)
; Each font pixel that's set becomes a FONT_SCALE square, via
; fill_rect. Lowercase is drawn as uppercase; anything outside
; ' '..'Z' as a blank.
;   rbx string   r12d chars left   r13d x   r14d y   r15d color
;   stack: glyph pointer, row, col, row bits
DT_GLYPH equ 0
DT_ROW   equ 8
DT_COL   equ 12
DT_BITS  equ 16
