; game.asm -- main (the loop), the RNG, spawning, reading settings
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .text
main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    sub rsp, STACK_LOCALS_SIZE

    ; seed FIRST -- the spawn functions below draw random numbers
    call rng_seed
    call seed_from_env
    mov rax, [rng_state]
    mov [game_seed], rax

    call read_rules
    call choose_sides
    call build_blockmap
    call build_walkable
    call build_nbrs
    call spawn_soldiers
    call spawn_pickups
    call crews_setup               ; game mode: the turf crews (10.11)
    call bikers_setup              ; ... and the Bikers' clubhouse (10.14)

    call is_headless
    test eax, eax
    jz .windowed

    ; ---- headless: update until someone wins or MAX_TICKS ----
.hl_loop:
    call update_soldiers
    inc dword [ticks]
    call check_win
    test eax, eax
    jnz .hl_won
    cmp dword [ticks], MAX_TICKS
    jb .hl_loop
    mov dword [show_seed], 1       ; so the stalemate can be replayed
    lea rsi, [stalemate_msg]
    mov edx, stalemate_msg_len
    cmp dword [game_mode], 0
    je .hl_end
    lea rsi, [war_msg]             ; game mode: that's the whole war (10.04)
    mov edx, war_msg_len
.hl_end:
    call print_result
    jmp .cleanup_none
.hl_won:
    call print_winner
    jmp .cleanup_none

.windowed:
    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    test eax, eax
    js .cleanup_none

    call build_title
    lea rdi, [title_buf]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, SCREEN_W
    mov r8d, WINDOW_H
    mov r9d, SDL_WINDOW_SHOWN
    call SDL_CreateWindow
    mov r12, rax
    test r12, r12
    jz .cleanup_sdl

    mov rdi, r12
    mov esi, -1
    mov edx, SDL_RENDERER_ACCELERATED
    call SDL_CreateRenderer
    mov r13, rax
    test r13, r13
    jz .cleanup_window

    ; the view (as big as it gets), and the scoreboard strip
    mov rdi, r13
    mov esi, SDL_PIXELFORMAT_RGBA32
    mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, VIEW_MAX_W
    mov r8d, VIEW_MAX_H
    call SDL_CreateTexture
    mov r14, rax
    test r14, r14
    jz .cleanup_renderer
    mov rdi, r13
    mov esi, SDL_PIXELFORMAT_RGBA32
    mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, SCREEN_W
    mov r8d, HUD_H
    call SDL_CreateTexture
    mov r15, rax
    test r15, r15
    jz .cleanup_view_tex

    call render_background         ; once: the whole map
    call camera_start              ; between the homes (10.03)
    call player_start              ; game mode: you (10.05)
    xor edi, edi
    call SDL_GetKeyboardState      ; SDL keeps this array up to date
    mov [key_state], rax
    call init_lighting             ; kernels, and the starting time

.loop:
    call SDL_GetTicks
    mov ebx, eax

.poll_events:
    lea rdi, [rsp + EVENT_OFF]
    call SDL_PollEvent
    test eax, eax
    jz .update
    mov eax, [rsp + EVENT_OFF]
    cmp eax, SDL_QUIT_EVENT
    je .quit
    cmp eax, SDL_MOUSEWHEEL_EVENT
    jne .poll_events
    mov edi, [rsp + EVENT_OFF + WHEEL_Y_OFF]
    call screen_wheel              ; (10.10: camera_wheel, within limits)
    jmp .poll_events

.update:
    cmp dword [game_over], 0
    jne .render

    call update_game_state         ; title, shift, summary (10.08)
    cmp dword [paused], 0          ; (10.17) everything waits
    jne .render
    call update_player             ; you first (10.05; nothing outside a shift)
    call update_soldiers
    inc dword [ticks]
    call check_win
    test eax, eax
    jz .render
    mov [game_over], eax
    call print_winner

.render:
    ; ---- the camera's part of the map: a copy of the pre-drawn
    ; background, and back_fb set to it (9.01) ----
    ; (10.05: in game mode the camera follows you, and W A S D walk;
    ; while you're dead it stays put)
    cmp dword [player_on], 0
    jne .follow
    cmp dword [game_state], GS_SHOP
    je .camera_set                ; (10.10: W and S choose in the shop)
    call camera_pan
    jmp .camera_set
.follow:
    cmp dword [soldiers + PLAYER * Soldier_size + Soldier.health], 0
    jle .camera_set
    call camera_follow
.camera_set:
    call view_begin

    ; ---- shadows of everything that moves, before any of it is drawn
    ; (so no shadow darkens a neighbour's sprite) ----
    call draw_moving_shadows

    ; ---- active weapon pickups ----
    mov dword [rsp + LOOP_I_OFF], 0
.pickup_draw_loop:
    mov eax, [rsp + LOOP_I_OFF]
    cmp eax, MAX_PICKUPS
    jge .pickup_draw_done

    imul eax, Pickup_size
    lea r10, [pickups]
    add r10, rax

    cmp dword [r10 + Pickup.active], 0
    je .pickup_draw_next

    ; a gun, centred where the old square was
    lea rdx, [pickup_sprites]
    lea rcx, [pickup_pal_pistol]
    cmp dword [r10 + Pickup.type], WEAPON_PISTOL
    je .pickup_have_sprite
    add rdx, SPRITE_SIZE * SPRITE_SIZE
    lea rcx, [pickup_pal_shotgun]
.pickup_have_sprite:
    mov edi, [r10 + Pickup.x]
    sub edi, (SPRITE_SIZE - PICKUP_SIZE) / 2
    mov esi, [r10 + Pickup.y]
    sub esi, (SPRITE_SIZE - PICKUP_SIZE) / 2
    xor r8d, r8d
    call draw_sprite

.pickup_draw_next:
    mov eax, [rsp + LOOP_I_OFF]
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .pickup_draw_loop
.pickup_draw_done:
    call draw_meds                 ; weed (10.12)
    call draw_vehicle              ; your bike, under you (10.06)
    call draw_bikes                ; the Bikers', under them (10.14)

    ; ---- soldiers ----
    mov dword [rsp + LOOP_I_OFF], 0
.draw_loop:
    mov eax, [rsp + LOOP_I_OFF]
    cmp eax, TOTAL_SOLDIERS
    jge .draw_done

    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax

    ; dead soldiers stay drawn while death_linger runs, so the shot
    ; that killed them has something to land on
    mov eax, [rsp + LOOP_I_OFF]
    cmp dword [r10 + Soldier.health], 0
    jg .draw_visible
    lea rcx, [death_linger]
    cmp dword [rcx + rax*4], 0
    jle .draw_next
.draw_visible:

    ; spawn protection: blink, 4 frames on, 4 off
    lea rcx, [protect_timer]
    cmp dword [rcx + rax*4], 0
    jle .no_blink
    test dword [ticks], 4
    jnz .draw_next
.no_blink:

    ; (10.15) you're inside a car or the van: it's drawn, you aren't
    cmp eax, PLAYER
    jne .draw_body
    cmp dword [riding], 0
    je .draw_body
    imul ecx, [veh_type], VehicleType_size
    lea rdx, [vehicle_types]
    cmp dword [rdx + rcx + VehicleType.body], 0
    jne .draw_next
.draw_body:
    mov edi, eax
    call draw_soldier

.draw_next:
    ; count down this soldier's flash and linger timers, once per frame
    ; (not while paused, 10.17)
    mov eax, [rsp + LOOP_I_OFF]
    cmp dword [paused], 0
    jne .linger_done
    lea rcx, [hit_flash]
    cmp dword [rcx + rax*4], 0
    jle .flash_done
    dec dword [rcx + rax*4]
.flash_done:
    lea rcx, [death_linger]
    cmp dword [rcx + rax*4], 0
    jle .linger_done
    dec dword [rcx + rax*4]
    jnz .linger_done
    ; the fall's over: if it was a death, it leaves a pool (8.04)
    imul ecx, eax, Soldier_size
    lea rdx, [soldiers]
    cmp dword [rdx + rcx + Soldier.health], 0
    jg .linger_done
    mov edi, eax
    call stamp_pool
    mov eax, [rsp + LOOP_I_OFF]
.linger_done:
    inc eax
    mov [rsp + LOOP_I_OFF], eax
    jmp .draw_loop
.draw_done:

    call draw_bosses               ; the Big Homies' health bars
    call draw_player_bar           ; yours (10.12)
    call draw_events               ; police car, walker, dog

    ; ---- the time of day: darken, tint, light (8.05) ----
    call light_scene

    ; ---- attack effects, on top of everything (bright in the dark) ----
    call draw_effects
    call draw_nades                ; grenades and blasts (10.16)
    call draw_lock                 ; your lock-on brackets (10.05)
    call draw_job_marker           ; where the job is (10.07)
    call draw_overlay              ; the title or the summary (10.08)

    ; ---- scoreboard, in its own strip ----
    call draw_hud

    ; the view, scaled to fill the field area, then the scoreboard
    ; strip, 1:1. Only the drawn part of back_buffer goes to SDL
    mov rdi, r14
    lea rsi, [tex_src]
    lea rdx, [back_buffer]
    mov ecx, BB_PITCH
    call SDL_UpdateTexture
    mov rdi, r13
    mov rsi, r14
    lea rdx, [tex_src]
    lea rcx, [field_dst]
    call SDL_RenderCopy
    mov rdi, r15
    xor esi, esi
    lea rdx, [hud_buffer]
    mov ecx, HUD_PITCH
    call SDL_UpdateTexture
    mov rdi, r13
    mov rsi, r15
    lea rdx, [hud_src]
    lea rcx, [hud_rect]
    call SDL_RenderCopy

    mov rdi, r13
    call SDL_RenderPresent

    call SDL_GetTicks
    sub eax, ebx
    cmp eax, FRAME_BUDGET_MS
    jge .loop
    mov ecx, FRAME_BUDGET_MS
    sub ecx, eax
    mov edi, ecx
    call SDL_Delay
    jmp .loop

.quit:
    ; the window closed: in game mode nobody won, so say how the war
    ; went (10.04). (A finished watch-mode game printed its line already)
    cmp dword [game_mode], 0
    je .cleanup_all
    cmp dword [courier], 0
    je .quit_line
    ; closing mid-shift ends the shift (its totals count; shift_end
    ; saves); otherwise just save (10.08)
    cmp dword [game_state], GS_SHIFT
    jne .quit_save
    xor edi, edi
    mov esi, GS_SUMMARY
    call shift_end
    jmp .quit_line
.quit_save:
    call write_save
.quit_line:
    lea rsi, [war_msg]
    mov edx, war_msg_len
    call print_result
.cleanup_all:
    mov rdi, r15
    call SDL_DestroyTexture
.cleanup_view_tex:
    mov rdi, r14
    call SDL_DestroyTexture
.cleanup_renderer:
    mov rdi, r13
    call SDL_DestroyRenderer
.cleanup_window:
    mov rdi, r12
    call SDL_DestroyWindow
.cleanup_sdl:
    call SDL_Quit
.cleanup_none:
    add rsp, STACK_LOCALS_SIZE
    add rsp, 8
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; void rng_seed(void)
;
; rdtsc puts the CPU's cycle counter in edx:eax. Using it raw would
; work, but xorshift is linear: two seeds that differ in a few low bits
; (two launches close together) produce early outputs that also differ
; in only a few bits. splitmix64's finalizer -- add a constant, then
; xor-shift/multiply three times -- scrambles every input bit across
; the whole 64-bit state first. It's the standard way to seed the
; xorshift family.
;
; xorshift has exactly one bad state: 0, which maps to 0 forever. The
; mix makes that astronomically unlikely, but it costs two instructions
; to rule it out entirely.
rng_seed:
    rdtsc
    shl rdx, 32
    or rax, rdx                          ; rax = full 64-bit timestamp

    mov rdx, 0x9E3779B97F4A7C15
    add rax, rdx
    mov rdx, rax
    shr rdx, 30
    xor rax, rdx
    mov rdx, 0xBF58476D1CE4E5B9
    imul rax, rdx
    mov rdx, rax
    shr rdx, 27
    xor rax, rdx
    mov rdx, 0x94D049BB133111EB
    imul rax, rdx
    mov rdx, rax
    shr rdx, 31
    xor rax, rdx

    test rax, rax
    jnz .seed_ok
    mov rax, 0x9E3779B97F4A7C15          ; any nonzero constant
.seed_ok:
    mov [rng_state], rax
    ret


; uint32 rng_next(void) -> eax
;
; Marsaglia's xorshift64: x ^= x << 13; x ^= x >> 7; x ^= x << 17.
; Three shift-and-xor steps, no multiply, no divide. Period 2^64 - 1:
; it visits every nonzero 64-bit value exactly once before repeating.
;
; Returns the HIGH 32 bits. The low bits of a plain xorshift are its
; weakest (they fail some statistical tests the high bits pass), and
; update_soldiers uses exactly one bit of every draw (`and eax, 1`)
; to pick the processing direction -- the same fairness fix whose
; accidental removal was stage6b's bug #2. Handing it the best bit we
; have costs one `shr`.
;
; Clobbers only rax and rdx (rand() was free to clobber every
; caller-saved register, so every call site already assumes worse).
rng_next:
    mov rax, [rng_state]
    mov rdx, rax
    shl rdx, 13
    xor rax, rdx
    mov rdx, rax
    shr rdx, 7
    xor rax, rdx
    mov rdx, rax
    shl rdx, 17
    xor rax, rdx
    mov [rng_state], rax
    shr rax, 32
    ret


; int rand_range(int n: edi) -> eax in [0, n)
; rng_next() % n. The modulo is very slightly biased toward small
; values (2^32 isn't a multiple of n), by at most n / 2^32 -- about
; one part in 8 million for the largest n used here (537).
rand_range:
    push rbx
    mov ebx, edi
    call rng_next
    xor edx, edx
    div ebx
    mov eax, edx
    pop rbx
    ret


; INIT_SOLDIER: set every field of one soldier. A macro rather than a
; function, just so both teams' soldiers are set up by literally the
; same lines.
%macro INIT_SOLDIER 4   ; %1 = soldier index reg, %2 = x reg, %3 = y reg, %4 = team
    mov eax, %1
    imul eax, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov [r10 + Soldier.x], %2
    mov [r10 + Soldier.y], %3
    mov [r10 + Soldier.team], %4
    mov dword [r10 + Soldier.health], 100
    mov dword [r10 + Soldier.weapon], WEAPON_KNIFE
    mov dword [r10 + Soldier.state], STATE_SEEK_ENEMY
    mov dword [r10 + Soldier.target], -1
    mov dword [r10 + Soldier.cooldown], 0
    mov dword [r10 + Soldier.avoid_dir], 0
%endmacro

; void spawn_soldiers(void)
; Each team starts inside its own complex's lobby (home[team]): for
; each soldier, a random spot in the lobby, tried again if it's within
; SPAWN_GAP (on both axes) of a teammate already placed. The teams
; can't touch, so only teammates need checking.
;
; The retry loop has no attempt limit. gen_neighborhood.py runs this
; same packing 300 times per lobby and fails the build of the map if
; it ever jams; the worst single soldier needed 76 tries.
;   r15d team   r12d soldier index   r13d/r14d x/y   ebx check index
;   stack: lobby x0, x range, y0, y range
SS_X0 equ 0
SS_XR equ 4
SS_Y0 equ 8
SS_YR equ 12
spawn_soldiers:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                   ; 5 pushes + 16: 16-byte aligned
    xor r15d, r15d
.ss_team:
    ; this team's lobby, shrunk by LOBBY_MARGIN, as corner ranges
    mov eax, [home + r15*4]
    shl eax, 4                    ; 16 bytes per lobby
    lea rcx, [site_lobbies]
    add rcx, rax
    mov eax, [rcx]
    add eax, LOBBY_MARGIN
    mov [rsp + SS_X0], eax
    mov eax, [rcx + 8]
    sub eax, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    mov [rsp + SS_XR], eax
    mov eax, [rcx + 4]
    add eax, LOBBY_MARGIN
    mov [rsp + SS_Y0], eax
    mov eax, [rcx + 12]
    sub eax, SOLDIER_SIZE + 2 * LOBBY_MARGIN - 1
    mov [rsp + SS_YR], eax

    imul r12d, r15d, NUM_PER_TEAM ; first index of this team
.ss_next:
    imul eax, r15d, NUM_PER_TEAM
    add eax, NUM_PER_TEAM
    cmp r12d, eax
    jge .ss_team_done
.ss_retry:
    mov edi, [rsp + SS_XR]
    call rand_range
    add eax, [rsp + SS_X0]
    mov r13d, eax
    mov edi, [rsp + SS_YR]
    call rand_range
    add eax, [rsp + SS_Y0]
    mov r14d, eax

    ; too close to a teammate already placed?
    imul ebx, r15d, NUM_PER_TEAM
.ss_check:
    cmp ebx, r12d
    jge .ss_place
    imul eax, ebx, Soldier_size
    lea r10, [soldiers]
    add r10, rax
    mov eax, [r10 + Soldier.x]
    sub eax, r13d
    jns .ss_dx_ok
    neg eax
.ss_dx_ok:
    cmp eax, SPAWN_GAP
    jge .ss_check_next
    mov eax, [r10 + Soldier.y]
    sub eax, r14d
    jns .ss_dy_ok
    neg eax
.ss_dy_ok:
    cmp eax, SPAWN_GAP
    jl .ss_retry                  ; too close on both axes
.ss_check_next:
    inc ebx
    jmp .ss_check
.ss_place:
    INIT_SOLDIER r12d, r13d, r14d, r15d
    inc r12d
    jmp .ss_next
.ss_team_done:
    inc r15d
    cmp r15d, 2
    jb .ss_team
    ; the Big Homies' slots: out of play (health 0, nothing booked)
    ; until update_bosses sends one out; one life each
    lea r10, [soldiers + BOSS0 * Soldier_size]
    mov dword [r10 + Soldier.team], 0
    mov dword [r10 + Soldier.health], 0
    lea r10, [soldiers + BOSS1 * Soldier_size]
    mov dword [r10 + Soldier.team], 1
    mov dword [r10 + Soldier.health], 0
    lea r10, [lives_left]
    mov dword [r10 + BOSS0 * 4], 0
    mov dword [r10 + BOSS1 * 4], 0
    ; the player's slot (10.05): out of play until player_start, and
    ; no generic respawn (update_player brings you back)
    lea r10, [soldiers + PLAYER * Soldier_size]
    mov dword [r10 + Soldier.team], FACTION_PLAYER
    mov dword [r10 + Soldier.health], 0
    lea r10, [lives_left]
    mov dword [r10 + PLAYER * 4], 0
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void choose_sides(void)
; Where the gangs live this game (10.03): a pair of sites from
; pair_sites -- the one PAIR= names, if it's a valid pair number, else
; a random one -- and then one random bit, which gang gets which.
; home[gang] is its site, and fwd_sign[gang] is +1 when the enemy's
; lobby is to the east. fwd_sign replaces 06-12's "team 0 goes +x":
; the side-step and flow_waypoint's tie-break still go "forward",
; toward the enemy's home.
;   ebx, r12d: the two sites
choose_sides:
    push rbx
    push r12
    sub rsp, 8
    lea rdi, [pair_env]
    call getenv
    test rax, rax
    jz .cs_random
    mov rdi, rax
    call atoi
    cmp eax, NUM_PAIRS
    jb .cs_have_pair              ; unsigned: a negative one isn't valid
.cs_random:
    mov edi, NUM_PAIRS
    call rand_range
.cs_have_pair:
    mov [pair], eax
    lea rcx, [pair_sites]
    mov ebx, [rcx + rax*8]
    mov r12d, [rcx + rax*8 + 4]
    call rng_next
    and eax, 1
    jz .cs_keep
    xchg ebx, r12d
.cs_keep:
    mov [home], ebx               ; the Crips
    mov [home + 4], r12d          ; the Bloods
    lea rcx, [site_lobbies]
    shl ebx, 4
    shl r12d, 4
    mov eax, [rcx + rbx]          ; the Crips' lobby x
    mov dword [fwd_sign], 1
    mov dword [fwd_sign + 4], -1
    cmp eax, [rcx + r12]
    jl .cs_done
    mov dword [fwd_sign], -1
    mov dword [fwd_sign + 4], 1
.cs_done:
    add rsp, 8
    pop r12
    pop rbx
    ret


; void spawn_pickups(void)
; This pair's pickups (pair_pickups, 10.03), each moved by a random
; offset in [-PICKUP_JITTER, +PICKUP_JITTER] on each axis. If that
; lands it where a soldier couldn't stand, it goes exactly on its table
; spot instead, which the generator checked is clear. The generator
; laid each pair's out mirrored between its two lobbies.
spawn_pickups:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r12, [pickups]
    imul eax, [pair], PICKUPS_PER_PAIR * 12
    lea r13, [pair_pickups]       ; this pair's (10.03)
    add r13, rax
    xor r14d, r14d
.sp_loop:
    cmp r14d, PICKUPS_PER_PAIR
    jge .sp_done
    mov edi, 2 * PICKUP_JITTER + 1
    call rand_range
    mov ebx, [r13]
    add ebx, eax
    sub ebx, PICKUP_JITTER                ; x
    mov edi, 2 * PICKUP_JITTER + 1
    call rand_range
    mov r15d, [r13 + 4]
    add r15d, eax
    sub r15d, PICKUP_JITTER               ; y
    mov edi, ebx
    mov esi, r15d
    call is_box_blocked
    test eax, eax
    jz .sp_place
    mov ebx, [r13]                        ; blocked: the table spot
    mov r15d, [r13 + 4]
.sp_place:
    mov [r12 + Pickup.x], ebx
    mov [r12 + Pickup.y], r15d
    mov eax, [r13 + 8]
    mov [r12 + Pickup.type], eax
    mov dword [r12 + Pickup.active], 1
    add r12, Pickup_size
    add r13, 12
    inc r14d
    jmp .sp_loop
.sp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; void seed_from_env(void)
; SEED=n (decimal, or 0x... hex) replaces the rdtsc seed, to replay a
; game exactly. A stalemate prints the seed it started from. SEED=0
; is ignored: xorshift can't use a zero state.
seed_from_env:
    sub rsp, 8                    ; align the stack for the libc calls
    lea rdi, [seed_env]
    call getenv
    test rax, rax
    jz .sfe_done
    mov rdi, rax
    xor esi, esi                  ; no end pointer
    xor edx, edx                  ; base 0: decimal, or 0x for hex
    call strtoull
    test rax, rax
    jz .sfe_done
    mov [rng_state], rax
.sfe_done:
    add rsp, 8
    ret


; int is_headless(void) -> eax: 1 if $HEADLESS is set and doesn't
; start with '0' (so HEADLESS=0 means windowed), else 0.
is_headless:
    sub rsp, 8                    ; align the stack for getenv
    lea rdi, [headless_env]
    call getenv
    add rsp, 8
    test rax, rax
    jz .ih_no
    cmp byte [rax], '0'
    je .ih_no
    cmp byte [rax], 0             ; HEADLESS= (empty) counts as no
    je .ih_no
    mov eax, 1
    ret
.ih_no:
    xor eax, eax
    ret


; void print_winner(int winner: eax) -- check_win's 1 = team 0, 2 = team 1
print_winner:
    lea rsi, [win_msg0]
    mov edx, win_msg0_len
    cmp eax, 1
    je .pw_have
    lea rsi, [win_msg1]
    mov edx, win_msg1_len
.pw_have:
    jmp print_result


; ============================================================
; Pathfinding (see the header). Cell k on either axis covers corner
; coordinates [CELL*k - (CELL-1), CELL*k], clipped to the field, so a
; coordinate v is in cell (v + CELL-1) / CELL.
; ============================================================

; CELL_OF reg: reg = (reg + CELL-1) / CELL. Clobbers eax, ecx, edx.
%macro CELL_OF 1
    lea eax, [%1 + CELL - 1]
    xor edx, edx
    mov ecx, CELL
    div ecx
    mov %1, eax
%endmacro
