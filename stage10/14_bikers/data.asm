; data.asm -- initialised data: settings, messages, counters, event state, framebuffers, the font
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .data
    title_prefix db "Stage 10.14 - "
    title_prefix_len equ $ - title_prefix
    ; the game's name (10.10), the window's title in game mode. The
    ; typos are on purpose
    game_name db "MY CITY IS A WARZONE BUT I NEED MONEY!!!1:4thwall break: Help I need to fix my van."
    game_name_len equ $ - game_name
    homes_msg db "; homes "
    homes_msg_len equ $ - homes_msg
    crips_home_msg db "; crips home "
    crips_home_msg_len equ $ - crips_home_msg
    pair_env db "PAIR", 0
    pair     dd 0             ; this game's pair of sites (10.03)
    headless_env db "HEADLESS", 0
    seed_env db "SEED", 0
    respawns_env db "RESPAWNS", 0
    lives_env db "LIVES", 0
    score_env db "SCORE_LIMIT", 0
    score_msg db "; score "
    score_msg_len equ $ - score_msg
    tickets     times MAX_FACTIONS dd -1   ; respawns left per faction, -1 = unlimited
    score       times MAX_FACTIONS dd 0    ; kills per faction
    score_limit dd DEFAULT_SCORE_LIMIT
    score_winner dd 0         ; 1 or 2 once a team reaches score_limit
    hex_digits db "0123456789abcdef"
    seed_msg db "; seed "
    seed_msg_len equ $ - seed_msg
    show_seed dd 0            ; 1 = print_result adds the seed
    game_seed dq 0            ; rng_state right after seeding
    stalemate_msg db "Stalemate"
    stalemate_msg_len equ $ - stalemate_msg
    win_msg0 db "Team 0 (Crips) wins"
    win_msg0_len equ $ - win_msg0
    win_msg1 db "Team 1 (Bloods) wins"
    win_msg1_len equ $ - win_msg1
    on_msg db " on "
    on_msg_len equ $ - on_msg
    ff_msg1 db "! (friendly fire: "
    ff_msg1_len equ $ - ff_msg1
    ff_msg2 db " hits, "
    ff_msg2_len equ $ - ff_msg2
    ff_msg3 db " kills; held fire "
    ff_msg3_len equ $ - ff_msg3
    ff_msg4 db " times; "
    ff_msg4_len equ $ - ff_msg4
    ff_msg5 db " ticks"
    ff_msg5_len equ $ - ff_msg5
    ff_msg6 db ")", 10
    ff_msg6_len equ $ - ff_msg6
    ticks    dd 0             ; updates run so far
    ff_held  dd 0
    ff_hits  dd 0
    ff_kills dd 0
    game_over dd 0
    pass_reverse dd 0
    ; ---- random encounters ----
    cop_active   dd 0
    cop_rect     dd 0, 0, 0, 0    ; x, y, w, h
    cop_vel      dd 0, 0          ; dx, dy per tick
    cop_fire     dd 0             ; ticks until the officers fire again
    cop_wait     dd 0             ; ticks it's waited for you (10.09)
    cop_strip    dd 0, 0, 0, 0    ; the strip just ahead of its bumper
    COP_ROUTES equ cop_routes_count   ; the routes are in the map
    dog_state    dd DOG_NONE
    walker_x     dd 0
    walker_y     dd 0
    walker_dx    dd 0
    dog_x        dd 0
    dog_y        dd 0
    dog_timer    dd 0             ; loose: ticks left
    dog_bite     dd 0             ; ticks until it can bite again
    DOG_WALKS equ dog_walks_count     ; so are the walks
    text_fb      dq hud_fb        ; where draw_text draws (10.08: the overlays)
    fx_src       dd 0, 0          ; a stand-in "shooter" for spawn_effect
    fx_dst       dd 0, 0          ; ... and target (10.05: a missed shot's aim)
    ; ---- the player (10.05) ----
    player_on     dd 0            ; 1: game mode, in a window
    player_rng    dq 0
    player_ammo   dd 0, 0         ; pistol rounds, shotgun shells
    player_weapon dd 0            ; WEAPON_PISTOL or WEAPON_SHOTGUN
    player_kills  dd 0
    lock_target   dd -1           ; the soldier you're locked onto, or -1
    rmb_prev      dd 0            ; last tick's right button (a click = a change)
    q_prev        dd 0
    player_calm   dd 0            ; ticks since you were last hurt
    player_hp_was dd 0            ; your health last tick
    hud_pistol db "   PISTOL "
    hud_pistol_len equ $ - hud_pistol
    hud_shotgun db "   SHOTGUN "
    hud_shotgun_len equ $ - hud_shotgun
    you_msg1 db "; you: kills "
    you_msg1_len equ $ - you_msg1
    you_msg2 db ", deaths "
    you_msg2_len equ $ - you_msg2
    player_dead   dd 0            ; 1 once the respawn countdown's started
    player_timer  dd 0
    player_deaths dd 0
    mouse_buttons dd 0
    aim_x         dd 0            ; the cursor, in map pixels
    aim_y         dd 0
    hud_hp    db "HP "
    hud_hp_len equ $ - hud_hp
    hud_kills db "   KILLS "
    hud_kills_len equ $ - hud_kills
    hud_dead  db "YOU DIED"
    hud_dead_len equ $ - hud_dead
    arrests      dd 0
    cop_kills    dd 0
    dog_kills    dd 0
    ev_msg1 db "; arrests "
    ev_msg1_len equ $ - ev_msg1
    ev_msg2 db "; police kills "
    ev_msg2_len equ $ - ev_msg2
    ev_msg3 db "; dog kills "
    ev_msg3_len equ $ - ev_msg3
    hud_police db "POLICE!"
    hud_police_len equ $ - hud_police
    hud_dog db "DOG LOOSE!"
    hud_dog_len equ $ - hud_dog
    us_flee      dd 0             ; this soldier is running from the police
    us_field     dq 0             ; ... is a crew going back: its field (10.11)
    boss_env     db "BOSS_AT", 0
    boss_at      dd BOSS_TRIGGER_PCT
    boss_state   times MAX_FACTIONS dd 0   ; per gang: 0 waiting, 1 due, 2 out
    boss_count   times MAX_FACTIONS dd 0   ; per gang: times he's come out
    boss_base    times MAX_FACTIONS dd 0   ; game mode: the kill gap when he
                                           ; last died (10.04)
    mode_env     db "MODE", 0
    mode_game    db "game", 0
    mode_watch   db "watch", 0
    game_mode    dd 0             ; 1: the endless war, 0: last gang standing
    war_msg      db "Endless war"
    war_msg_len  equ $ - war_msg
    boss_alert   dd 0             ; scoreboard announcement ticks left
    boss_alert_team dd 0
    boss_tick    dd 0             ; when the first Big Homie came out
    boss_tick_msg db "; big homie at "
    boss_tick_msg_len equ $ - boss_tick_msg
    hud_boss db "BIG HOMIE!"
    hud_boss_len equ $ - hud_boss
    boss_msg db "; big homies "
    boss_msg_len equ $ - boss_msg

    home      dd 0, 1         ; site per gang (10.03: set by choose_sides)
              times MAX_FACTIONS - NUM_GANGS dd -1    ; (no home)
    fwd_sign  dd 1, -1        ; +1: the enemy's complex is to the east
              times MAX_FACTIONS - NUM_GANGS dd 0

    ; who fights whom (10.02): hostility[a * MAX_FACTIONS + b] = 1 if
    ; faction a attacks faction b. Read with the HOSTILE macro. For now
    ; just the two gangs, at war; the other rows fill in as factions
    ; arrive.
    hostility:
        ;   Cr Bl  P Po Bk  .  .  .
        db  0, 1, 1, 0, 1, 0, 0, 0      ; Crips
        db  1, 0, 1, 0, 1, 0, 0, 0      ; Bloods
        db  1, 1, 0, 0, 1, 0, 0, 0      ; the player (10.05)
        db  1, 1, 0, 0, 0, 0, 0, 0      ; the police: the gangs, not you (10.09)
        db  1, 1, 1, 0, 0, 0, 0, 0      ; the Bikers: gangs and you (10.14)
        times (MAX_FACTIONS - 5) * MAX_FACTIONS db 0
    rng_state    dq 0         ; xorshift64 state -- must never be 0


    ; the flow fields' searches (9.03): one per faction, toward
    ; everyone that faction fights (10.02), and one toward the pickups
    bfs_states:
    %assign f 0
    %rep MAX_FACTIONS
    istruc BfsState
        at BfsState.field, dq field_for + f * GRID_CELLS * 2
        at BfsState.queue, dq bfs_queues + f * GRID_CELLS * 4
    iend
    %assign f f + 1
    %endrep
    bfs_st_pk:
    istruc BfsState
        at BfsState.field, dq field_pk
        at BfsState.queue, dq bfs_queue_pk
    iend

    ; the view: w, h and the origin follow the camera, every frame
    back_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq back_buffer
        at FrameBuffer.pitch,  dd BB_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd SCREEN_H
        at FrameBuffer.ox,     dd 0
        at FrameBuffer.oy,     dd 0
    iend

    ; the whole map's look, drawn once (render_background)
    bg_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq bg_buffer
        at FrameBuffer.pitch,  dd WORLD_W * 4
        at FrameBuffer.w,      dd WORLD_W
        at FrameBuffer.h,      dd WORLD_H
        at FrameBuffer.ox,     dd 0
        at FrameBuffer.oy,     dd 0
    iend

    ; the scoreboard strip (9.01: its own buffer)
    hud_fb:
    istruc FrameBuffer
        at FrameBuffer.pixels, dq hud_buffer
        at FrameBuffer.pitch,  dd HUD_PITCH
        at FrameBuffer.w,      dd SCREEN_W
        at FrameBuffer.h,      dd HUD_H
        at FrameBuffer.ox,     dd 0
        at FrameBuffer.oy,     dd 0
    iend

    ; ---- the scoreboard font: 5x7, hand-made ----
    ; One glyph per ASCII code from ' ' (32) to 'Z' (90), 7 bytes each,
    ; one per row, top first. Bit 4 is the leftmost pixel, so each row
    ; reads like the picture it draws. Codes with no glyph are blank.
    ; GLYPH checks at build time that the table stays in ASCII order.
%macro GLYPH 8
    %if %1 != font_next
        %error "font glyphs out of order"
    %endif
    db %2, %3, %4, %5, %6, %7, %8
    %assign font_next font_next + 1
%endmacro
%macro GLYPH_BLANK 1
    %if %1 != font_next
        %error "font glyphs out of order"
    %endif
    times FONT_ROWS db 0
    %assign font_next font_next + 1
%endmacro
    %assign font_next FONT_FIRST
    font:
    GLYPH_BLANK 32        ; ' '
    GLYPH '!', 00100b, 00100b, 00100b, 00100b, 00100b, 00000b, 00100b
    GLYPH_BLANK 34
    GLYPH_BLANK 35
    GLYPH '$', 00100b, 01111b, 10100b, 01110b, 00101b, 11110b, 00100b   ; (10.07)
    GLYPH_BLANK 37
    GLYPH_BLANK 38
    GLYPH_BLANK 39
    GLYPH '(', 00010b, 00100b, 01000b, 01000b, 01000b, 00100b, 00010b   ; (10.12)
    GLYPH ')', 01000b, 00100b, 00010b, 00010b, 00010b, 00100b, 01000b   ; (10.07)
    GLYPH_BLANK 42
    GLYPH '+', 00000b, 00100b, 00100b, 11111b, 00100b, 00100b, 00000b   ; (10.07)
    GLYPH_BLANK 44
    GLYPH '-', 00000b, 00000b, 00000b, 11111b, 00000b, 00000b, 00000b
    GLYPH '.', 00000b, 00000b, 00000b, 00000b, 00000b, 01100b, 01100b
    GLYPH '/', 00001b, 00010b, 00010b, 00100b, 01000b, 01000b, 10000b
    GLYPH '0', 01110b, 10001b, 10011b, 10101b, 11001b, 10001b, 01110b
    GLYPH '1', 00100b, 01100b, 00100b, 00100b, 00100b, 00100b, 01110b
    GLYPH '2', 01110b, 10001b, 00001b, 00010b, 00100b, 01000b, 11111b
    GLYPH '3', 11111b, 00010b, 00100b, 00010b, 00001b, 10001b, 01110b
    GLYPH '4', 00010b, 00110b, 01010b, 10010b, 11111b, 00010b, 00010b
    GLYPH '5', 11111b, 10000b, 11110b, 00001b, 00001b, 10001b, 01110b
    GLYPH '6', 00110b, 01000b, 10000b, 11110b, 10001b, 10001b, 01110b
    GLYPH '7', 11111b, 00001b, 00010b, 00100b, 01000b, 01000b, 01000b
    GLYPH '8', 01110b, 10001b, 10001b, 01110b, 10001b, 10001b, 01110b
    GLYPH '9', 01110b, 10001b, 10001b, 01111b, 00001b, 00010b, 01100b
    GLYPH ':', 00000b, 01100b, 01100b, 00000b, 01100b, 01100b, 00000b
    GLYPH_BLANK 59
    GLYPH_BLANK 60
    GLYPH_BLANK 61
    GLYPH '>', 01000b, 00100b, 00010b, 00001b, 00010b, 00100b, 01000b   ; (10.07)
    GLYPH_BLANK 63
    GLYPH_BLANK 64
    GLYPH 'A', 01110b, 10001b, 10001b, 11111b, 10001b, 10001b, 10001b
    GLYPH 'B', 11110b, 10001b, 10001b, 11110b, 10001b, 10001b, 11110b
    GLYPH 'C', 01110b, 10001b, 10000b, 10000b, 10000b, 10001b, 01110b
    GLYPH 'D', 11100b, 10010b, 10001b, 10001b, 10001b, 10010b, 11100b
    GLYPH 'E', 11111b, 10000b, 10000b, 11110b, 10000b, 10000b, 11111b
    GLYPH 'F', 11111b, 10000b, 10000b, 11110b, 10000b, 10000b, 10000b
    GLYPH 'G', 01110b, 10001b, 10000b, 10111b, 10001b, 10001b, 01111b
    GLYPH 'H', 10001b, 10001b, 10001b, 11111b, 10001b, 10001b, 10001b
    GLYPH 'I', 01110b, 00100b, 00100b, 00100b, 00100b, 00100b, 01110b
    GLYPH 'J', 00111b, 00010b, 00010b, 00010b, 00010b, 10010b, 01100b
    GLYPH 'K', 10001b, 10010b, 10100b, 11000b, 10100b, 10010b, 10001b
    GLYPH 'L', 10000b, 10000b, 10000b, 10000b, 10000b, 10000b, 11111b
    GLYPH 'M', 10001b, 11011b, 10101b, 10101b, 10001b, 10001b, 10001b
    GLYPH 'N', 10001b, 10001b, 11001b, 10101b, 10011b, 10001b, 10001b
    GLYPH 'O', 01110b, 10001b, 10001b, 10001b, 10001b, 10001b, 01110b
    GLYPH 'P', 11110b, 10001b, 10001b, 11110b, 10000b, 10000b, 10000b
    GLYPH 'Q', 01110b, 10001b, 10001b, 10001b, 10101b, 10010b, 01101b
    GLYPH 'R', 11110b, 10001b, 10001b, 11110b, 10100b, 10010b, 10001b
    GLYPH 'S', 01111b, 10000b, 10000b, 01110b, 00001b, 00001b, 11110b
    GLYPH 'T', 11111b, 00100b, 00100b, 00100b, 00100b, 00100b, 00100b
    GLYPH 'U', 10001b, 10001b, 10001b, 10001b, 10001b, 10001b, 01110b
    GLYPH 'V', 10001b, 10001b, 10001b, 10001b, 10001b, 01010b, 00100b
    GLYPH 'W', 10001b, 10001b, 10001b, 10101b, 10101b, 10101b, 01010b
    GLYPH 'X', 10001b, 10001b, 01010b, 00100b, 01010b, 10001b, 10001b
    GLYPH 'Y', 10001b, 10001b, 10001b, 01010b, 00100b, 00100b, 00100b
    GLYPH 'Z', 11111b, 00001b, 00010b, 00100b, 01000b, 10000b, 11111b
    %if font_next != FONT_LAST + 1
        %error "font table doesn't end at FONT_LAST"
    %endif
    hud_blue db "CRIPS "
    hud_blue_len equ $ - hud_blue
    hud_red db "BLOODS "
    hud_red_len equ $ - hud_red
    hud_wins db " WIN"
    hud_wins_len equ $ - hud_wins
    hud_gap db "   "
    hud_gap_len equ $ - hud_gap
