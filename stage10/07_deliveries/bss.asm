; bss.asm -- uninitialised data: grids, fields, buffers, soldiers, pickups
; (10.01: split out of 9.03 in its original order; main.asm includes it)

section .bss
    walkable    resb GRID_CELLS         ; 1 = a soldier fits anywhere in the cell
    bfs_nbrs    resb GRID_CELLS         ; NB_* bits: which neighbours bfs_run visits
    field_for   resw GRID_CELLS * MAX_FACTIONS   ; per faction: distance to
                                        ; its nearest enemy, UNREACHED = none
    field_pk    resw GRID_CELLS
    bfs_queues  resd GRID_CELLS * MAX_FACTIONS  ; one queue per field (9.03: a
    bfs_queue_pk resd GRID_CELLS        ; search stops part way, and carries
                                        ; on later where it left off)
    bfs_cur     resq 1                  ; the BfsState bfs_seed works on
    flow_wx     resd 1                  ; flow_waypoint's answer
    flow_wy     resd 1
    back_buffer resb VIEW_MAX_W * VIEW_MAX_H * 4   ; the view (9.01)
    hud_buffer  resb SCREEN_W * HUD_H * 4
    hud_buf     resb 64                 ; one scoreboard string at a time
    ; ---- sprite drawing state (drawing only) ----
    sprite_seen   resd TOTAL_SOLDIERS   ; 1 once drawn: last_x/y are valid
    sprite_last_x resd TOTAL_SOLDIERS
    sprite_last_y resd TOTAL_SOLDIERS
    sprite_facing resd TOTAL_SOLDIERS   ; 0 N .. 7 NW, clockwise
    sprite_walk   resd TOTAL_SOLDIERS   ; pixels walked: picks the frame
    pal_buf       resd PAL_SIZE         ; this sprite's colours
    spr_h         resd 1                ; draw_sprite_ex's height
    ; ---- day and night (drawing only) ----
    lightmap      resb LM_W * LM_H      ; light per 2x2 pixels, 0..255
    light_tab     resd 256 * 3          ; per light level: R, G, B scales
    ambient       resd 3                ; this frame's R, G, B scales
    lamps_on      resd 1
    kern_lamp     resb (2 * LAMP_R + 1) * (2 * LAMP_R + 1)
    kern_mid      resb (2 * MID_R + 1) * (2 * MID_R + 1)
    kern_small    resb (2 * SMALL_R + 1) * (2 * SMALL_R + 1)
    dog_last_x    resd 1                ; drawing only: which way it ran
    dog_face      resd 1                ; SPR_MIRROR when facing west
    respawn_timer resd TOTAL_SOLDIERS   ; >0: dead, back when it counts
                                        ; down (stays at 1 until a spot
                                        ; is free)
    protect_timer resd TOTAL_SOLDIERS   ; >0: hits do no damage
    lives_left    resd TOTAL_SOLDIERS   ; respawns this soldier has
                                        ; left, -1 = unlimited
    soldiers    resb TOTAL_SOLDIERS * Soldier_size
    pickups     resb MAX_PICKUPS * Pickup_size
    pickup_age  resd MAX_PICKUPS        ; ticks each has lain there (10.04)
    bg_buffer   resb WORLD_W * WORLD_H * 4      ; the whole map (59 MB)
    blockmap    resb BM_W * BM_H        ; BLOCK_* bits per corner position
    lb_mask     resd 1                  ; which blockmap bit line_blocked tests
    effects     resb MAX_EFFECTS * Effect_size
    fx_next     resd 1                  ; next ring-buffer slot to fill
    hit_flash    resd TOTAL_SOLDIERS    ; frames left drawn white
    death_linger resd TOTAL_SOLDIERS    ; frames a dead soldier stays drawn
    msg_buf      resb 512               ; the win line, built by print_result
                                        ; (10.07: 160 was too small since 10.03:
                                        ; the line runs past 200 now)
    title_buf    resb 64                ; window title, built by build_title
