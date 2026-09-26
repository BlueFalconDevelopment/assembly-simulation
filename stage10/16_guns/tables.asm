; tables.asm -- palettes, camera, day-and-night keys, gang colours, facing and flow tables
; (10.01: split out of 9.03 in its original order; main.asm includes it)


    ; ---- palettes for the object sprites (gen_sprites.py's letters) ----
    ; the police car: . K k W w R L X U r b -- two, the light bar swapped
    cop_pal_a:
        dd 0, 0xFF141414, 0xFF3C3C3C, 0xFF6E503C, 0xFF826450, 0xFF1E1EC8
        dd 0xFFB4F0FF, 0xFF0A0A0A, 0xFFF0F0F0, 0xFF1E1EE6, 0xFFFF5028, 0
    cop_pal_b:
        dd 0, 0xFF141414, 0xFF3C3C3C, 0xFF6E503C, 0xFF826450, 0xFF1E1EC8
        dd 0xFFB4F0FF, 0xFF0A0A0A, 0xFFF0F0F0, 0xFFFF5028, 0xFF1E1EE6, 0
    ; the dog: . D E N T L C
    dog_pal_leashed:
        dd 0, 0xFF3C64A0, 0xFF28416E, 0xFF141414, 0xFF3C64A0, 0xFF28416E, 0xFF1E1EC8, 0
    dog_pal_loose:
        dd 0, 0xFF5AB4E6, 0xFF3C82B4, 0xFF141414, 0xFF5AB4E6, 0xFF3C82B4, 0xFF1E1EC8, 0
    ; pickups: . o G g W -- pistol outline yellow, shotgun magenta
    pickup_pal_pistol:
        dd 0, COLOR_PICKUP_PISTOL, 0xFF373232, 0xFF736E6E, 0xFF285082, 0
    pickup_pal_shotgun:
        dd 0, COLOR_PICKUP_SHOTGUN, 0xFF373232, 0xFF736E6E, 0xFF285082, 0

    ; ---- the camera ----
    ; how much of the map each zoom step shows (width; height is 9/16).
    ; 9.01: two steps out, past 1x (back_buffer is sized for the first)
    zoom_view_w dd VIEW_MAX_W, 1920, 1280, 1024, 853, 640, 480, 320
    ZOOM_START  equ 2                            ; 1x
    zoom_step   dd ZOOM_START
    ; the view, in map pixels: starts at 1x, where the map says (9.02:
    ; between the homes)
    cam_src     dd 0, 0, SCREEN_W, SCREEN_H     ; (camera_start: between the homes)
    tex_src     dd 0, 0, SCREEN_W, SCREEN_H     ; SDL_Rect: the drawn part
    field_dst   dd 0, 0, SCREEN_W, SCREEN_H
    hud_src     dd 0, 0, SCREEN_W, HUD_H
    hud_rect    dd 0, SCREEN_H, SCREEN_W, HUD_H
    key_state   dq 0              ; SDL's keyboard array
    mouse_x     dd 0
    mouse_y     dd 0

    ; ---- day and night ----
    time_env    db "TIME", 0
    tod_start   dd -1             ; minute of the day at tick 0 (-1: from the seed)
    ; ambient keyframes: minute of the day, then R, G, B scales (x/256)
    tod_keys:
        dd    0,  64,  74, 128    ; night
        dd  300,  64,  74, 128    ; 5:00, still night
        dd  390, 200, 160, 150    ; 6:30, dawn
        dd  480, 256, 256, 256    ; 8:00, day
        dd 1050, 256, 256, 256    ; 5:30 PM, still day
        dd 1140, 236, 160, 116    ; 7:00 PM, dusk
        dd 1230,  64,  74, 128    ; 8:30 PM, night
        dd 1440,  64,  74, 128    ; (wraps to midnight)
    TOD_KEYS equ ($ - tod_keys) / 16
    am_pm       db "AMPM"

    ; blood: . r R d
    blood_pal:
        dd 0, 0xFF1E1E8C, 0xFF2828B4, 0xFF14145A

    ; per gang: shirt, shirt shadow, bandana
    gang_colours:
        dd 0xFFDC783C, 0xFF963C1E, 0xFFFF965A     ; Crips: blues
        dd 0xFF3C3CDC, 0xFF1E1E96, 0xFF5050FF     ; Bloods: reds
        dd 0xFF28C8F0, 0xFF148CB4, 0xFF28466E     ; the player: a courier's yellow, brown cap (10.05)
        dd 0xFF8C8C8C, 0xFF6E6E6E, 0xFF8C8C8C     ; (the police: never drawn as soldiers)
        dd 0xFF2A2A2A, 0xFF161616, 0xFF1E78E6     ; the Bikers: black leather, an orange bandana (10.14)
        times (MAX_FACTIONS - 5) * 3 dd 0xFF8C8C8C   ; (factions to come)
    skin_tones:
        dd 0xFFA0C3EB, 0xFF648CBE, 0xFF375078
    ; facing (0 N, 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W, 7 NW) -> pose, mirrored
    facing_pose:
        db 0, 0,  1, 0,  2, 0,  3, 0,  4, 0,  3, 1,  2, 1,  1, 1

    ; flow_waypoint's neighbour order: dx (times the team's forward
    ; sign), dy. Orthogonal first, so on a tie a straight step wins
    flow_dirs:
        db  1,  0,   0, -1,   0,  1,  -1,  0
        db  1, -1,   1,  1,  -1, -1,  -1,  1
