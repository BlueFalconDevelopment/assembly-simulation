; shop.asm -- the shop, between shifts (10.10)
;
; After the title and after every shift's summary, the game is in the
; shop (GS_SHOP, shifts.asm): a list of what money buys, your money,
; and ENTER to start the shift.
;
;   W / S (or the arrows)  choose
;   E (or SPACE)           buy the next level of it
;   ENTER                  start the shift
;
; Everything here is an upgrade you keep: a level from 0 up to the
; item's max, saved (bytes 28.. of the save file) and turned into
; numbers at the start of every shift (apply_gear) that every life in
; it uses. Dying costs cash, never gear. The
; list is data (shop_items): a new item is a row, plus the few lines
; that make its level do something.
;
; The prices are placeholders. The order (the user's, 10.07): tune the
; gangsters and the random encounters first, then the items and their
; price scaling (10.11), then the delivery pay.

GS_SHOP      equ 3
SCANCODE_SPACE equ 44
SCANCODE_UP    equ 82
SCANCODE_DOWN  equ 81
SHOP_MSG_TICKS equ 120        ; how long "BOUGHT" and co. stay up

; what each level does
ARMOR_PER_LEVEL   equ 15      ; % less damage taken
HEALTH_PER_LEVEL  equ 25      ; max health
AMMO_PER_LEVEL    equ 30      ; pistol rounds a life
SHELLS_PER_LEVEL  equ 12      ; shotgun shells a life
FRAME_PER_LEVEL   equ 30      ; bike health

struc ShopItem
    .name:  resq 1
    .desc:  resq 1
    .nlen:  resd 1
    .dlen:  resd 1
    .max:   resd 1
    .price: resd 3            ; for levels 1, 2, 3
endstruc

; SHOP_ITEM "name", "what it does", max level, price 1, 2, 3
; (the strings go to .rodata; the row stays in the table)
%macro SHOP_ITEM 6
    %if %3 > 3
        %error "a shop item has three prices, so at most 3 levels"
    %endif
    [section .rodata]
    %%name: db %1
    %%nlen equ $ - %%name
    %%desc: db %2
    %%dlen equ $ - %%desc
    __SECT__
    dq %%name, %%desc
    dd %%nlen, %%dlen, %3, %4, %5, %6
%endmacro

SHOP_ARMOR  equ 0
SHOP_HEALTH equ 1
SHOP_AMMO   equ 2
SHOP_SHELLS equ 3
SHOP_FRAME  equ 4
SHOP_PISTOL equ 5             ; (10.11; last, so older saves' bytes still line up)

section .data
    shop_items:
    SHOP_ITEM "BODY ARMOR",  "TAKE 15% LESS DAMAGE A LEVEL",   3, 150, 300, 500
    SHOP_ITEM "TOUGHNESS",   "+25 MAX HEALTH A LEVEL",         3, 100, 200, 350
    SHOP_ITEM "BIG MAGS",    "+30 PISTOL ROUNDS A LIFE",       3,  60, 120, 200
    SHOP_ITEM "SHOTGUN",     "START EACH LIFE WITH 12 MORE SHELLS", 2, 250, 200, 0
    SHOP_ITEM "BIKE FRAME",  "+30 BIKE HEALTH A LEVEL",        2, 120, 240, 0
    SHOP_ITEM "PISTOL UPGRADE", "HITS HARDER AND FIRES FASTER. LEVEL 3: ONE SHOT", 3, 200, 400, 800
    SHOP_COUNT equ ($ - shop_items) / ShopItem_size
    ; (a build-time check: the levels must fit the save file's spare bytes)
    times -(SAVE_GEAR + SHOP_COUNT > 60) db 0

    shop_levels  times SHOP_COUNT db 0   ; saved
    shop_pick    dd 0
    shop_keys_was dd 0                   ; last tick's keys, as SK_ bits
    shop_msg     dd 0                    ; 0, or which message
    shop_msg_left dd 0

    ; what the gear adds up to (apply_gear)
    player_max_hp  dd PLAYER_HEALTH
    player_armor   dd 100                ; % of damage that gets through
    player_rounds  dd PLAYER_AMMO
    player_shells  dd 0
    bike_bonus     dd 0
    player_pistol_dmg dd PLAYER_DAMAGE
    player_pistol_cd  dd PLAYER_COOLDOWN
    ; the pistol upgrade (10.11), by level: damage, and ticks between shots
    pistol_dmg_by_level dd PLAYER_DAMAGE, 66, 83, 100
    pistol_cd_by_level  dd PLAYER_COOLDOWN, 12, 11, 10

    t_shop      db "THE SHOP"
    t_shop_len  equ $ - t_shop
    t_shop_keys db "W S: CHOOSE   E: BUY   ENTER: START THE SHIFT"
    t_shop_keys_len equ $ - t_shop_keys
    t_max       db "MAX"
    t_bought    db "BOUGHT!"
    t_bought_len equ $ - t_bought
    t_broke     db "NOT ENOUGH MONEY"
    t_broke_len equ $ - t_broke
    t_maxed     db "YOU HAVE ALL OF IT"
    t_maxed_len equ $ - t_maxed
    COLOR_DIM   equ 0xFF8C8C8C

SK_UP   equ 1
SK_DOWN equ 2
SK_BUY  equ 4
MSG_BOUGHT  equ 1
MSG_BROKE   equ 2
MSG_MAXED   equ 3

section .text

; int armor_damage(int victim: edi, int damage: esi) -> eax: what gets
; through. You wear armor (player_armor % gets through), and so do the
; Bikers (BIKER_ARMOR %, 10.14); everyone else takes it all. Every hit on a soldier goes through here:
; update_soldiers' gunfire, and event_damage (the police, the dog,
; your own rams). Clobbers ecx, edx
armor_damage:
    mov eax, esi
    cmp edi, FIRST_BIKER
    jae .ad_biker
    cmp edi, PLAYER
    jne .ad_done
    imul eax, [player_armor]
    xor edx, edx
    mov ecx, 100
    div ecx                       ; (rounded down: in your favour)
.ad_done:
    ret
.ad_biker:
    imul eax, eax, BIKER_ARMOR    ; the Bikers' leathers and plates (10.14)
    xor edx, edx
    mov ecx, 100
    div ecx
    ret


; the row of item edx -> rax
%macro SHOP_ROW 0
    imul eax, edx, ShopItem_size
    lea rcx, [shop_items]
    add rax, rcx
%endmacro


; void apply_gear(void) -- the levels into what they do (shift_start:
; until then, player_max_hp and co. may be out of date)
apply_gear:
    movzx eax, byte [shop_levels + SHOP_ARMOR]
    imul eax, eax, ARMOR_PER_LEVEL
    mov ecx, 100
    sub ecx, eax
    mov [player_armor], ecx
    movzx eax, byte [shop_levels + SHOP_HEALTH]
    imul eax, eax, HEALTH_PER_LEVEL
    add eax, PLAYER_HEALTH
    mov [player_max_hp], eax
    movzx eax, byte [shop_levels + SHOP_AMMO]
    imul eax, eax, AMMO_PER_LEVEL
    add eax, PLAYER_AMMO
    mov [player_rounds], eax
    movzx eax, byte [shop_levels + SHOP_SHELLS]
    imul eax, eax, SHELLS_PER_LEVEL
    mov [player_shells], eax
    movzx eax, byte [shop_levels + SHOP_FRAME]
    imul eax, eax, FRAME_PER_LEVEL
    mov [bike_bonus], eax
    movzx eax, byte [shop_levels + SHOP_PISTOL]
    mov ecx, [pistol_dmg_by_level + rax*4]
    mov [player_pistol_dmg], ecx
    mov ecx, [pistol_cd_by_level + rax*4]
    mov [player_pistol_cd], ecx
    ret


; void shop_clamp(void) -- levels from a save, kept within each max
; (a save from a build with longer lists stays loadable)
shop_clamp:
    xor edx, edx
.sc_item:
    SHOP_ROW
    mov ecx, [rax + ShopItem.max]
    movzx eax, byte [shop_levels + rdx]
    cmp eax, ecx
    jbe .sc_ok
    mov [shop_levels + rdx], cl
.sc_ok:
    inc edx
    cmp edx, SHOP_COUNT
    jb .sc_item
    ret


; void shop_open(void) -- into the shop, from the title or a summary
shop_open:
    mov dword [game_state], GS_SHOP
    mov dword [shop_msg_left], 0
    mov dword [shop_keys_was], SK_UP | SK_DOWN | SK_BUY   ; held keys don't count
    ret


; void update_shop(void) -- once a tick in the shop: choosing, buying
; (ENTER is update_game_state's)
update_shop:
    push rbx
    mov r8, [key_state]
    xor ebx, ebx                  ; this tick's keys, as SK_ bits
    movzx eax, byte [r8 + SCANCODE_W]
    or al, [r8 + SCANCODE_UP]
    jz .us_down
    or ebx, SK_UP
.us_down:
    movzx eax, byte [r8 + SCANCODE_S]
    or al, [r8 + SCANCODE_DOWN]
    jz .us_buy
    or ebx, SK_DOWN
.us_buy:
    movzx eax, byte [r8 + SCANCODE_E]
    or al, [r8 + SCANCODE_SPACE]
    jz .us_keys
    or ebx, SK_BUY
.us_keys:
    mov eax, [shop_keys_was]
    mov [shop_keys_was], ebx
    not eax
    and ebx, eax                  ; pressed this tick, not held
    cmp dword [shop_msg_left], 0
    jle .us_up
    dec dword [shop_msg_left]
.us_up:
    test ebx, SK_UP
    jz .us_dn
    dec dword [shop_pick]
    jns .us_dn
    mov dword [shop_pick], SHOP_COUNT - 1
.us_dn:
    test ebx, SK_DOWN
    jz .us_try
    inc dword [shop_pick]
    cmp dword [shop_pick], SHOP_COUNT
    jb .us_try
    mov dword [shop_pick], 0
.us_try:
    test ebx, SK_BUY
    jz .us_done
    call shop_buy
    mov [shop_msg], eax
    mov dword [shop_msg_left], SHOP_MSG_TICKS
.us_done:
    pop rbx
    ret


; int shop_buy(void) -> eax, a MSG_: the next level of the chosen item,
; if there is one and you can pay for it. Saved at once
shop_buy:
    sub rsp, 8
    mov edx, [shop_pick]
    SHOP_ROW
    mov ecx, [rax + ShopItem.max]
    movzx r8d, byte [shop_levels + rdx]
    cmp r8d, ecx
    jae .sb_maxed
    mov ecx, [rax + ShopItem.price + r8*4]
    cmp [money], ecx
    jl .sb_broke
    sub [money], ecx
    inc byte [shop_levels + rdx]
    call write_save
    mov eax, MSG_BOUGHT
    jmp .sb_done
.sb_maxed:
    mov eax, MSG_MAXED
    jmp .sb_done
.sb_broke:
    mov eax, MSG_BROKE
.sb_done:
    add rsp, 8
    ret


; pad hud_buf out to column %1 with spaces (rdi: the end so far)
%macro PAD_TO 1
    lea rax, [hud_buf + %1]
%%pad:
    cmp rdi, rax
    jae %%done
    mov byte [rdi], ' '
    inc rdi
    jmp %%pad
%%done:
%endmacro

SHOP_TOP    equ -3            ; overlay lines: the shop starts high
SHOP_LIST   equ 0
SHOP_ROW_W  equ 34            ; every row the same width, so they line up

; void draw_shop(void) -- the shop, on the dimmed view (draw_overlay;
; drawing only). r12d the line, r13d the colour: overlay_buf's
draw_shop:
    push rbx
    push r12
    push r13
    push r14
    push r15
    TEXT_LINE t_shop, t_shop_len, SHOP_TOP, COLOR_TITLE
    ; "$1234"
    lea rdi, [hud_buf]
    mov byte [rdi], '$'
    inc rdi
    mov esi, [money]
    call append_uint
    mov r12d, SHOP_TOP + 1
    mov r13d, COLOR_MONEY
    call overlay_buf
    ; the list: "> BODY ARMOR    1/3    $300"
    xor ebx, ebx
.ds_row:
    mov edx, ebx
    SHOP_ROW
    mov r14, rax
    movzx r15d, byte [shop_levels + rbx]
    lea rdi, [hud_buf]
    mov byte [rdi], ' '
    cmp ebx, [shop_pick]
    jne .ds_mark
    mov byte [rdi], '>'
.ds_mark:
    mov byte [rdi + 1], ' '
    add rdi, 2
    mov rsi, [r14 + ShopItem.name]
    mov edx, [r14 + ShopItem.nlen]
    call append_bytes
    PAD_TO 18
    mov r13d, COLOR_DIM
    ; "1/3"
    mov esi, r15d
    call append_uint
    mov byte [rdi], '/'
    inc rdi
    mov esi, [r14 + ShopItem.max]
    call append_uint
    PAD_TO 25
    cmp r15d, [r14 + ShopItem.max]
    jae .ds_max
    ; the next level's price: white if you can pay it, red if not
    mov esi, [r14 + ShopItem.price + r15*4]
    mov r13d, COLOR_HUD_TEXT
    cmp [money], esi
    jge .ds_price
    mov r13d, COLOR_BAD
.ds_price:
    mov byte [rdi], '$'
    inc rdi
    call append_uint
    jmp .ds_line
.ds_max:
    lea rsi, [t_max]
    mov edx, 3
    call append_bytes
.ds_line:
    PAD_TO SHOP_ROW_W
    cmp ebx, [shop_pick]
    jne .ds_colour
    mov r13d, COLOR_TITLE         ; the one you're on
.ds_colour:
    lea r12d, [rbx + SHOP_LIST]
    call overlay_buf
    inc ebx
    cmp ebx, SHOP_COUNT
    jb .ds_row
    ; under the list: what it does, or how the last try went
    cmp dword [shop_msg_left], 0
    jg .ds_msg
    mov edx, [shop_pick]
    SHOP_ROW
    mov rsi, [rax + ShopItem.desc]
    mov edx, [rax + ShopItem.dlen]
    mov r8d, COLOR_HUD_TEXT
    jmp .ds_say
.ds_msg:
    mov eax, [shop_msg]
    lea rsi, [t_bought]
    mov edx, t_bought_len
    mov r8d, COLOR_MONEY
    cmp eax, MSG_BOUGHT
    je .ds_say
    mov r8d, COLOR_BAD
    lea rsi, [t_broke]
    mov edx, t_broke_len
    cmp eax, MSG_BROKE
    je .ds_say
    lea rsi, [t_maxed]
    mov edx, t_maxed_len
.ds_say:
    mov ecx, SHOP_LIST + SHOP_COUNT + 1
    call overlay_line
    TEXT_LINE t_shop_keys, t_shop_keys_len, SHOP_LIST + SHOP_COUNT + 3, COLOR_TITLE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
