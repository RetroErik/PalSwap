; ============================================================================
; CGASwap.ASM - CGA Palette Override TSR for Real CGA Cards
; Written for NASM - 8088 compatible (runs on any DOS PC with CGA)
; By Retro Erik - 2026 using VS Code with GitHub Copilot
; Version 1.0
; ============================================================================
;
; A tiny TSR that forces a specific CGA palette combination in mode 4/5.
; Unlike PalSwapT (which needs EGA/VGA), this works on a REAL CGA card.
;
; CGA mode 4/5 palette control is limited to:
;   - Background color: any of 16 RGBI colors (port 3D9h bits 0-3)
;   - Intensity: low or high (port 3D9h bit 4)
;   - Palette select: 0 or 1 (port 3D9h bit 5)
;   - Color burst: on or off (port 3D8h bit 2) — off gives mode 5 variant
;
; This gives 6 possible foreground-color combinations:
;   /1  Palette 1, High intensity:  Light Cyan, Light Magenta, White
;   /2  Palette 1, Low intensity:   Cyan, Magenta, Light Gray
;   /3  Palette 0, High intensity:  Light Green, Light Red, Yellow
;   /4  Palette 0, Low intensity:   Green, Red, Brown
;   /5  Mode 5, High intensity:     Light Cyan, Light Red, White
;   /6  Mode 5, Low intensity:      Cyan, Red, Light Gray
;
; Background color can be any of the 16 CGA colors:
;   /b:0..15  or  /b:name  (black, blue, green, cyan, red, magenta,
;     brown, lightgray, darkgray, lightblue, lightgreen, lightcyan,
;     lightred, lightmagenta, yellow, white)
;
; Interrupt hooks:
;
;   INT 10h — Video BIOS override:
;     AH=00h: If setting mode 4 or 5, lets it happen then re-applies our
;             palette/intensity/background to ports 3D8h/3D9h.
;             Also tracks graphics mode state for safe timer operation.
;     AH=0Bh: Suppresses game palette changes by overriding with ours.
;
;   INT 09h — Keyboard hotkeys:
;     Ctrl+Alt + 1..6 — Switch palette combination on the fly.
;     Uses BIOS keyboard flags at 0040:0017h for modifier detection.
;     Works with games that chain INT 09h to the original handler.
;
;   INT 08h — Timer polling + palette enforcement (always hooked):
;     Polls port 60h scan codes to track Ctrl/Alt state independently
;     of BIOS flags (for games that replace INT 09h entirely).
;     When Ctrl+Alt + 1-6 detected via polling, applies preset.
;     Re-applies palette every tick (~18.2 Hz) by default.
;     /T disables the timer enforcement (hotkey polling still active).
;     Only active in CGA mode 4/5 (tracked via in_gfx_mode flag).
;
; Compatibility notes:
;   CGA has no palette indirection — ports 3D8h/3D9h are write-only
;   with no readback. Games that continuously write to port 3D9h in
;   their main loop will override our palette faster than the timer
;   can re-apply it. These games are fundamentally incompatible.
;
; Tested games (on real CGA hardware):
;   Works:  Montezuma's Revenge, Ms. Pac-Man, IK, Bruce Lee, Popcorn,
;           Last Ninja, The Secret of Monkey Island (CGA version),
;           Galaxian
;   Hotkeys only on title screen:  Fallen Angel, Rick Dangerous
;     (these games replace INT 08h+09h during gameplay without chaining)
;   Set palette before launch:  Fallen Angel (in-game)
;     (writes 3D9h directly in game loop)
;
; Usage: CGASWAP [/1..6] [/b:color] [/T] [/U] [/?]
;   /1../6    Select palette combination (default: /1)
;   /b:N      Set background color (0-15 or name, default: 0 = black)
;   /T        Disable timer enforcement (default: timer ON)
;   /U        Uninstall TSR
;   /?        Show help
;
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 8086

; ============================================================================
; Constants
; ============================================================================
CGA_MODE_CTRL       equ 0x3D8      ; MC6845 Mode Control Register
CGA_COLOR_SEL       equ 0x3D9      ; CGA Color Select Register

; Keyboard scan codes for Ctrl+Alt hotkeys
SCAN_1              equ 0x02        ; scan code for '1' key
SCAN_6              equ 0x07        ; scan code for '6' key

; BIOS keyboard flag bits at 0040:0017h
CTRLALT_BITS        equ 0x0C        ; bits 2+3 = Ctrl + Alt held

; ============================================================================
; Jump over resident section to installer
; ============================================================================
jmp main

; ============================================================================
; =====================  RESIDENT SECTION  ===================================
; ============================================================================
; Everything from here to tsr_end stays in memory after going TSR.
; ============================================================================

; --- TSR Signature (7 bytes) - used for detection/uninstall ---
tsr_sig:            db 'CGASwap'

; --- Original INT 10h vector (far pointer: offset THEN segment) ---
orig_int10_ofs:     dw 0
orig_int10_seg:     dw 0

; --- Original INT 09h vector (keyboard) ---
orig_int09_ofs:     dw 0
orig_int09_seg:     dw 0

; --- Original INT 08h vector (timer) ---
orig_int08_ofs:     dw 0
orig_int08_seg:     dw 0

; --- Timer enforcement flag (0 = off, 1 = active) ---
timer_active:       db 0

; --- Graphics mode flag (1 = in mode 4 or 5, 0 = other mode) ---
in_gfx_mode:        db 0

; --- Last scan code seen by INT 08h polling (to avoid repeated triggers) ---
last_poll_scan:     db 0

; --- Self-tracked modifier state for hotkey polling ---
; (Games that replace INT 09h don't update BIOS flags, so we track ourselves)
poll_ctrl_held:     db 0            ; 1 = Ctrl is held
poll_alt_held:      db 0            ; 1 = Alt is held

; --- Forced palette settings ---
; These two bytes are the complete palette state we force.
; The mode_ctrl_bits byte has only the bits we override (bit 2: burst).
; The color_sel byte is the full value for port 3D9h.
force_color_sel:    db 0x20 | 0x10  ; default: pal1 high, bg=0 (bits 5,4,3-0)
force_burst_off:    db 0            ; 0 = burst on (normal), 1 = burst off (mode 5)

; ============================================================================
; INT 10h HOOK — Override palette after mode set, suppress AH=0Bh
; ============================================================================
tsr_int10:
    cmp ah, 0x00
    je .mode_set
    cmp ah, 0x0B
    je .palette_set
    jmp far [cs:orig_int10_ofs]     ; not our business — chain

.mode_set:
    ; Track ALL mode changes for timer safety
    cmp al, 0x04
    je .cga_mode
    cmp al, 0x05
    je .cga_mode

    ; Not mode 4 or 5 — clear graphics flag, chain normally
    mov byte [cs:in_gfx_mode], 0
    jmp far [cs:orig_int10_ofs]

.cga_mode:
    ; Let the original handler set the mode first
    pushf
    call far [cs:orig_int10_ofs]

    ; Mark that we're in graphics mode (safe for timer)
    mov byte [cs:in_gfx_mode], 1

    ; Now override the palette
    call apply_cga_palette
    iret

.palette_set:
    ; AH=0Bh — game is trying to change palette
    ; BH=0: set background/border color (BL = color 0-15)
    ; BH=1: set palette (BL = 0 or 1)
    ; We suppress BOTH and re-apply our forced palette.

    ; Let the original handler run first (some games depend on side effects)
    pushf
    call far [cs:orig_int10_ofs]

    ; Then override with our settings
    call apply_cga_palette
    iret

; ============================================================================
; apply_cga_palette — Write our forced palette to CGA hardware
; Called from the INT 10h hook (CS = resident segment).
; ============================================================================
apply_cga_palette:
    push ax
    push dx

    ; Write Color Select Register (port 3D9h)
    ; This sets background color (bits 0-3), intensity (bit 4), palette (bit 5)
    mov dx, CGA_COLOR_SEL
    mov al, [cs:force_color_sel]
    out dx, al

    ; Handle color burst (port 3D8h)
    ; We need to read-modify-write: set or clear bit 2 (color burst disable)
    ; But 3D8h is write-only on real CGA! We must reconstruct the value.
    ; In mode 4: 3D8h = 0x0A (graphics, burst on) or 0x0E (burst off)
    ; In mode 5: 3D8h = 0x0E (burst off by definition)
    ; Mode 4 base: bit 1=1 (graphics), bit 3=1 (video enable) = 0x0A
    ; Mode 5 base: same + bit 2=1 (color burst off = mode 5)   = 0x0E
    cmp byte [cs:force_burst_off], 0
    je .burst_on
    ; Burst off: write 0x1E (320x200 graphics, video on, burst off, for mode 4)
    ; Actually: bit 0=0, bit 1=1 (graphics), bit 2=1 (burst off),
    ;           bit 3=1 (video enable), bit 4=0 (mode 4 = 320x200)
    mov al, 0x0E
    jmp short .write_mode
.burst_on:
    mov al, 0x0A               ; mode 4: graphics, video on, burst on
.write_mode:
    mov dx, CGA_MODE_CTRL
    out dx, al

    pop dx
    pop ax
    ret

; ============================================================================
; Preset table (resident — needed by INT 09h hotkey handler)
; 2 bytes per entry: [color_sel_template, burst_off]
; color_sel_template: bits 5=palette, 4=intensity, 3-0 = 0 (bg added later)
; ============================================================================
preset_table:
    db 0x30, 0     ; /1: pal 1, high intensity, burst on
    db 0x20, 0     ; /2: pal 1, low intensity, burst on
    db 0x10, 0     ; /3: pal 0, high intensity, burst on
    db 0x00, 0     ; /4: pal 0, low intensity, burst on
    db 0x30, 1     ; /5: pal 1, high intensity, burst off (mode 5)
    db 0x20, 1     ; /6: pal 1, low intensity, burst off (mode 5)

; ============================================================================
; INT 09h HOOK — Ctrl+Alt + 1..6 to switch palette live
; ============================================================================
tsr_int09:
    push ax
    push ds

    ; Read scan code from keyboard controller
    in al, 0x60

    ; Ignore key releases (bit 7 set)
    test al, 0x80
    jnz .chain_kb

    ; Check if both Ctrl and Alt are held (BIOS keyboard flags)
    push ax
    mov ax, 0x0040
    mov ds, ax
    mov al, [0x0017]
    and al, CTRLALT_BITS
    cmp al, CTRLALT_BITS
    pop ax
    jne .chain_kb              ; Ctrl+Alt not both held — pass through

    ; Ctrl+Alt held — check for 1..6
    cmp al, SCAN_1
    jb .chain_kb
    cmp al, SCAN_6
    ja .chain_kb

    ; AL = 0x02..0x07 → preset index 0..5
    sub al, SCAN_1
    call hotkey_apply_preset

    ; Swallow the keystroke: toggle port 61h bit 7 + send EOI to PIC
    in al, 0x61
    or al, 0x80
    out 0x61, al
    and al, 0x7F
    out 0x61, al
    mov al, 0x20
    out 0x20, al

    pop ds
    pop ax
    iret

.chain_kb:
    pop ds
    pop ax
    jmp far [cs:orig_int09_ofs]

; ============================================================================
; hotkey_apply_preset — Apply preset AL (0..5) and update CGA hardware
; Called from INT 09h hook. Uses CS: overrides (DS is unknown).
; ============================================================================
hotkey_apply_preset:
    push bx
    push si

    ; Look up from preset table (2 bytes per entry)
    xor ah, ah
    shl ax, 1                  ; AX = index * 2
    mov bx, ax
    mov si, preset_table

    ; Get new color_sel template, merge with current background
    mov al, [cs:bx + si]      ; color_sel template
    mov ah, [cs:force_color_sel]
    and ah, 0x0F               ; keep current bg color
    and al, 0xF0               ; keep preset intensity+palette bits
    or  al, ah
    mov [cs:force_color_sel], al

    mov al, [cs:bx + si + 1]  ; burst_off flag
    mov [cs:force_burst_off], al

    ; Apply to hardware immediately
    call apply_cga_palette

    pop si
    pop bx
    ret

; ============================================================================
; INT 08h HOOK — Timer palette enforcement (~18.2 Hz) + hotkey polling
; Applies palette when timer_active=1 AND in_gfx_mode=1.
; Also polls keyboard for Ctrl+Alt+1-6 as fallback for games that
; replace INT 09h without chaining.
; Tracks Ctrl/Alt state itself (port 60h) since BIOS flags may not be updated.
; Always chains to original INT 08h to keep DOS clock and game timers working.
; ============================================================================
tsr_int08:
    push ax
    push ds

    ; --- Hotkey polling (works even if game replaced INT 09h) ---
    in al, 0x60                ; read last scan code from keyboard controller
    cmp al, [cs:last_poll_scan]
    je .poll_done              ; same as last tick — skip (avoid repeat)
    mov [cs:last_poll_scan], al

    ; Track Ctrl make/break (scan 1Dh / 9Dh)
    cmp al, 0x1D               ; Ctrl make
    jne .not_ctrl_make
    mov byte [cs:poll_ctrl_held], 1
    jmp .poll_done
.not_ctrl_make:
    cmp al, 0x9D               ; Ctrl break
    jne .not_ctrl_break
    mov byte [cs:poll_ctrl_held], 0
    jmp .poll_done
.not_ctrl_break:

    ; Track Alt make/break (scan 38h / B8h)
    cmp al, 0x38               ; Alt make
    jne .not_alt_make
    mov byte [cs:poll_alt_held], 1
    jmp .poll_done
.not_alt_make:
    cmp al, 0xB8               ; Alt break
    jne .not_alt_break
    mov byte [cs:poll_alt_held], 0
    jmp .poll_done
.not_alt_break:

    ; Only react to key presses (ignore releases)
    test al, 0x80
    jnz .poll_done

    ; Check scan code range 02h..07h (keys 1..6)
    cmp al, SCAN_1
    jb .poll_done
    cmp al, SCAN_6
    ja .poll_done

    ; Check our self-tracked Ctrl+Alt state first
    cmp byte [cs:poll_ctrl_held], 1
    jne .try_bios_flags
    cmp byte [cs:poll_alt_held], 1
    je .poll_hotkey_detected

.try_bios_flags:
    ; Fallback: check BIOS keyboard flags (works when game chains INT 09h)
    ; This covers the case where we missed Ctrl/Alt make codes in polling
    push ax
    push ds
    push bx
    mov bx, 0x0040
    mov ds, bx
    mov bl, [0x0017]
    and bl, CTRLALT_BITS
    cmp bl, CTRLALT_BITS
    pop bx
    pop ds
    pop ax
    jne .poll_done

.poll_hotkey_detected:
    ; Ctrl+Alt + 1-6 detected — apply preset
    sub al, SCAN_1             ; AL = 0..5
    call hotkey_apply_preset

.poll_done:
    ; --- Timer palette enforcement ---
    cmp byte [cs:timer_active], 1
    jne .timer_chain
    cmp byte [cs:in_gfx_mode], 1
    jne .timer_chain
    call apply_cga_palette

.timer_chain:
    pop ds
    pop ax
    jmp far [cs:orig_int08_ofs]

; ============================================================================
; End of resident section
; ============================================================================
tsr_end:

; ============================================================================
; =====================  TRANSIENT SECTION  ==================================
; ============================================================================
; Everything below is discarded after going TSR.
; ============================================================================

; ============================================================================
; Main installer entry point
; ============================================================================
main:
    mov dx, msg_banner
    call print_string

    ; Parse command line
    call parse_cmdline
    cmp byte [show_help], 1
    je .do_help
    cmp byte [do_uninstall], 1
    je .do_uninstall_tsr
    cmp byte [parse_error], 1
    je .exit

    ; Print what we're installing
    call print_config

    ; Check if already loaded
    call check_already_loaded
    cmp al, 1
    je .already_loaded

    ; Save original INT 10h vector
    mov ax, 0x3510
    int 0x21
    mov [orig_int10_seg], es
    mov [orig_int10_ofs], bx

    ; Install INT 10h hook
    mov ax, 0x2510
    mov dx, tsr_int10
    int 0x21

    ; Save original INT 09h vector (keyboard)
    mov ax, 0x3509
    int 0x21
    mov [orig_int09_seg], es
    mov [orig_int09_ofs], bx

    ; Install INT 09h hook (Ctrl+Alt hotkeys)
    mov ax, 0x2509
    mov dx, tsr_int09
    int 0x21

    ; Save original INT 08h vector (timer)
    mov ax, 0x3508
    int 0x21
    mov [orig_int08_seg], es
    mov [orig_int08_ofs], bx

    ; Install INT 08h hook (timer enforcement)
    mov ax, 0x2508
    mov dx, tsr_int08
    int 0x21

    ; Copy timer flag to resident data (timer_mode: 0=ON, 1=OFF)
    cmp byte [timer_mode], 1
    je .timer_off
    mov byte [timer_active], 1
    jmp .timer_set
.timer_off:
    mov byte [timer_active], 0
.timer_set:

    mov dx, msg_installed
    call print_string

    ; Print timer status
    cmp byte [timer_mode], 1
    je .timer_disabled_msg
    mov dx, msg_timer_on
    call print_string
    jmp .no_timer_msg
.timer_disabled_msg:
    mov dx, msg_timer_off
    call print_string
.no_timer_msg:

    ; Go resident — compute TSR size in paragraphs
    mov dx, tsr_end
    add dx, 15
    mov cl, 4
    shr dx, cl
    mov ax, 0x3100             ; DOS: terminate and stay resident
    int 0x21                   ; AL=00 = exit code 0

.already_loaded:
    ; TSR is already resident — update its palette data
    ; ES = resident segment (from check_already_loaded / get_tsr_seg)
    mov ax, 0x3510
    int 0x21
    ; ES = resident TSR segment

    ; Copy force_color_sel to resident
    mov al, [force_color_sel]
    mov [es:force_color_sel], al
    mov al, [force_burst_off]
    mov [es:force_burst_off], al

    ; Update timer flag in resident copy (timer_mode: 0=ON, 1=OFF)
    cmp byte [timer_mode], 1
    je .update_timer_off
    mov byte [es:timer_active], 1
    jmp .update_timer_set
.update_timer_off:
    mov byte [es:timer_active], 0
.update_timer_set:

    mov dx, msg_updated
    call print_string

    ; Print timer status
    cmp byte [timer_mode], 1
    je .update_timer_disabled_msg
    mov dx, msg_timer_on
    call print_string
    jmp .no_update_timer_msg
.update_timer_disabled_msg:
    mov dx, msg_timer_off
    call print_string
.no_update_timer_msg:
    jmp .exit

.do_help:
    mov dx, msg_help
    call print_string
    jmp .exit

.do_uninstall_tsr:
    call uninstall_tsr
    jmp .exit

.exit:
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; parse_cmdline — Parse /1../6, /b:N, /U, /? from command line at PSP:80h
; ============================================================================
parse_cmdline:
    push ax
    push bx
    push si

    mov si, 0x81               ; command tail starts at PSP offset 81h

.scan:
    lodsb
    cmp al, 0x0D               ; end of command line
    je .done
    cmp al, '/'
    je .switch
    cmp al, ' '
    je .scan
    cmp al, 0x09               ; tab
    je .scan
    jmp .scan                  ; skip other characters

.switch:
    lodsb                      ; character after /
    cmp al, 0x0D
    je .done

    ; /? — help
    cmp al, '?'
    je .set_help

    ; /U or /u — uninstall
    cmp al, 'U'
    je .set_uninstall
    cmp al, 'u'
    je .set_uninstall

    ; /1../6 — palette preset
    cmp al, '1'
    jb .check_t
    cmp al, '6'
    ja .check_t
    sub al, '1'               ; AL = 0..5 = preset index
    call apply_preset
    jmp .scan

.check_t:
    ; /T or /t — timer enforcement mode
    cmp al, 'T'
    je .set_timer
    cmp al, 't'
    je .set_timer
    jmp .check_b

.set_timer:
    mov byte [timer_mode], 1   ; 1 = user wants timer OFF
    jmp .scan

.check_b:
    ; /b: or /B: — background color
    cmp al, 'b'
    je .parse_bg
    cmp al, 'B'
    je .parse_bg

    ; Unknown switch
    mov dx, msg_bad_switch
    call print_string
    mov byte [parse_error], 1
    jmp .done

.set_help:
    mov byte [show_help], 1
    jmp .done

.set_uninstall:
    mov byte [do_uninstall], 1
    jmp .done

.parse_bg:
    ; Expect ':' next
    lodsb
    cmp al, ':'
    jne .bg_error

    ; Try to parse a number (0-15) first
    lodsb
    cmp al, '0'
    jb .try_name
    cmp al, '9'
    ja .try_name

    ; It's a digit — parse 1 or 2 digit number
    sub al, '0'
    mov ah, al                 ; save first digit
    mov al, [si]               ; peek next char
    cmp al, '0'
    jb .single_digit
    cmp al, '9'
    ja .single_digit
    ; Two-digit number
    inc si                     ; consume second digit
    sub al, '0'
    xchg al, ah                ; AL = first digit, AH = second digit
    ; AL * 10 + AH
    mov bl, 10
    mul bl
    add al, ah
    cmp al, 15
    ja .bg_error
    jmp .set_bg

.single_digit:
    mov al, ah                 ; restore single digit
.set_bg:
    ; Set background color (bits 0-3 of force_color_sel)
    and byte [force_color_sel], 0xF0   ; clear bg bits
    or  [force_color_sel], al          ; set new bg color
    jmp .scan

.try_name:
    ; Back up to start of name
    dec si
    call parse_bg_name
    cmp al, 0xFF
    je .bg_error
    and byte [force_color_sel], 0xF0
    or  [force_color_sel], al
    jmp .scan

.bg_error:
    mov dx, msg_bad_bg
    call print_string
    mov byte [parse_error], 1
    jmp .done

.done:
    pop si
    pop bx
    pop ax
    ret

; ============================================================================
; apply_preset — Set force_color_sel and force_burst_off for preset index AL
; Input: AL = 0..5 (preset index)
; ============================================================================
apply_preset:
    push bx
    push si

    ; Look up from preset table (2 bytes per entry: color_sel, burst_off)
    xor ah, ah
    shl ax, 1                  ; AX = index × 2
    mov bx, ax
    mov si, preset_table

    mov al, [si + bx]         ; color_sel template
    ; Merge with current background color (preserve bits 0-3)
    mov ah, [force_color_sel]
    and ah, 0x0F               ; keep current bg
    and al, 0xF0               ; keep preset's intensity+palette bits
    or  al, ah                 ; combine
    mov [force_color_sel], al

    mov al, [si + bx + 1]     ; burst_off
    mov [force_burst_off], al

    pop si
    pop bx
    ret

; ============================================================================
; parse_bg_name — Match color name at [SI] against name table
; Input:  SI → start of name in command line
; Output: AL = color index (0-15), or 0xFF if not found
;         SI advanced past the name
; ============================================================================
parse_bg_name:
    push bx
    push cx
    push di
    push es

    push cs
    pop es                     ; ES = CS for name table

    mov di, color_names
    xor bx, bx                ; BX = color index counter

.next_name:
    cmp byte [di], 0           ; end of table?
    je .not_found

    ; Compare name at [DI] with command line at [SI]
    push si                    ; save start position
.cmp_char:
    mov al, [di]
    cmp al, 0                  ; end of name string?
    je .name_end

    ; Get command line character, convert to lowercase
    mov cl, [si]
    cmp cl, 'A'
    jb .cmp_raw
    cmp cl, 'Z'
    ja .cmp_raw
    add cl, 0x20               ; to lowercase
.cmp_raw:
    cmp al, cl
    jne .mismatch
    inc si
    inc di
    jmp .cmp_char

.name_end:
    ; Full name matched — check that next char is a delimiter
    mov cl, [si]
    cmp cl, ' '
    je .matched
    cmp cl, '/'
    je .matched
    cmp cl, 0x0D
    je .matched
    cmp cl, 0x09
    je .matched

.mismatch:
    pop si                     ; restore SI
    ; Skip to end of this name entry (find the null terminator)
.skip_name:
    cmp byte [di], 0
    je .skip_done
    inc di
    jmp .skip_name
.skip_done:
    inc di                     ; skip the null
    inc bx                     ; next color index
    cmp bx, 16
    jb .next_name

.not_found:
    pop si                     ; restore SI (or balance stack)
    mov al, 0xFF
    jmp .bg_done

.matched:
    add sp, 2                  ; discard saved SI (we want to keep advanced SI)
    mov al, bl                 ; AL = color index

.bg_done:
    pop es
    pop di
    pop cx
    pop bx
    ret

; ============================================================================
; check_already_loaded — AL=1 if TSR signature found at INT 10h handler
; ============================================================================
check_already_loaded:
    push bx
    push cx
    push si
    push di
    push es

    ; Get current INT 10h vector
    mov ax, 0x3510
    int 0x21
    ; ES:BX → current INT 10h handler
    ; Compare signature at known offset in the TSR segment
    mov di, tsr_sig            ; offset of signature in TSR code
    mov si, tsr_sig            ; compare against our own copy
    mov cx, 7                  ; length of 'CGASwap'
    push ds
    push cs
    pop ds                     ; DS:SI = CS:tsr_sig
    repe cmpsb                 ; compare ES:DI vs DS:SI
    pop ds
    jne .not_loaded

    mov al, 1
    jmp .cal_done

.not_loaded:
    xor al, al

.cal_done:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    ret

; ============================================================================
; uninstall_tsr — Restore original INT 10h, free TSR memory
; ============================================================================
uninstall_tsr:
    push ax
    push bx
    push dx
    push ds
    push es

    ; Get current INT 10h vector to find our TSR segment
    mov ax, 0x3510
    int 0x21
    ; ES:BX → current handler; verify signature
    mov di, tsr_sig
    mov si, tsr_sig
    mov cx, 7
    push ds
    push cs
    pop ds
    repe cmpsb
    pop ds
    jne .not_us

    ; ES = TSR segment. Restore original INT 10h.
    mov ax, 0x2510
    push word [es:orig_int10_seg]
    pop ds
    mov dx, [es:orig_int10_ofs]
    int 0x21

    ; Restore original INT 09h (keyboard)
    mov ax, 0x2509
    push word [es:orig_int09_seg]
    pop ds
    mov dx, [es:orig_int09_ofs]
    int 0x21

    ; Restore original INT 08h (timer)
    mov ax, 0x2508
    push word [es:orig_int08_seg]
    pop ds
    mov dx, [es:orig_int08_ofs]
    int 0x21

    ; Free TSR's environment block (segment at PSP offset 2Ch)
    push es
    mov ax, [es:0x2C]          ; environment segment from PSP
    or ax, ax
    jz .no_env
    mov es, ax
    mov ah, 0x49
    int 0x21
.no_env:
    pop es

    ; Free TSR memory block (ES = TSR PSP segment)
    mov ah, 0x49
    int 0x21

    push cs
    pop ds

    mov dx, msg_unloaded
    jmp .ui_msg

.not_us:
    push cs
    pop ds
    mov dx, msg_unload_error

.ui_msg:
    call print_string

    pop es
    pop ds
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; print_config — Print the selected palette name and background info
; ============================================================================
print_config:
    push ax
    push bx
    push dx

    ; Print palette combo name based on current force_color_sel and burst
    mov al, [force_color_sel]
    mov ah, [force_burst_off]

    ; Determine which combo is selected
    test ah, ah
    jnz .burst_off

    ; Burst on — check palette and intensity bits
    test al, 0x20              ; bit 5 = palette select
    jz .pal0
    test al, 0x10              ; bit 4 = intensity
    jz .pal1_low
    mov dx, msg_combo1         ; Pal 1, high
    jmp .print_combo
.pal1_low:
    mov dx, msg_combo2         ; Pal 1, low
    jmp .print_combo
.pal0:
    test al, 0x10
    jz .pal0_low
    mov dx, msg_combo3         ; Pal 0, high
    jmp .print_combo
.pal0_low:
    mov dx, msg_combo4         ; Pal 0, low
    jmp .print_combo

.burst_off:
    test al, 0x10
    jz .mode5_low
    mov dx, msg_combo5         ; Mode 5, high
    jmp .print_combo
.mode5_low:
    mov dx, msg_combo6         ; Mode 5, low

.print_combo:
    call print_string

    ; Print background color
    mov dx, msg_bg_prefix
    call print_string
    mov al, [force_color_sel]
    and al, 0x0F               ; background color index
    xor ah, ah
    call print_decimal
    mov dx, msg_bg_suffix
    call print_string

    ; Look up and print background color name
    mov al, [force_color_sel]
    and al, 0x0F
    xor ah, ah
    ; AL = bg color index (0-15)
    ; Walk color_name_ptrs to find name
    shl ax, 1                  ; word table offset
    mov bx, ax
    mov dx, [color_name_ptrs + bx]
    call print_string
    mov dx, msg_crlf
    call print_string

    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; print_decimal — Print AL as decimal (0-255) to stdout
; ============================================================================
print_decimal:
    push ax
    push bx
    push cx
    push dx

    xor ah, ah
    mov bl, 100
    div bl                     ; AL = hundreds, AH = remainder
    or al, al
    jz .skip_hundreds
    add al, '0'
    call print_char
    mov al, ah
    jmp .do_tens

.skip_hundreds:
    mov al, ah                 ; AL = remainder

.do_tens:
    xor ah, ah
    mov bl, 10
    div bl                     ; AL = tens, AH = ones
    or al, al
    jz .skip_tens
    add al, '0'
    call print_char
    jmp .do_ones

.skip_tens:
    ; Only skip leading zero if hundreds was also zero
    ; Since we're here, hundreds was zero. Check original value.
    ; If ones digit only, just print it
.do_ones:
    mov al, ah
    add al, '0'
    call print_char

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_char — Print character in AL via DOS
; ============================================================================
print_char:
    push ax
    push dx
    mov dl, al
    mov ah, 0x02
    int 0x21
    pop dx
    pop ax
    ret

; ============================================================================
; print_string — Print $-terminated string at DX via DOS
; ============================================================================
print_string:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; Data section (transient — discarded after TSR)
; ============================================================================

msg_banner:
    db 'CGASwap v1.0 - CGA Palette Override TSR for Real CGA', 13, 10
    db 'By Retro Erik - 2026 - Hooks INT 10h/09h/08h', 13, 10, '$'

msg_help:
    db 13, 10
    db 'Usage: CGASWAP [/1..6] [/b:color] [/T] [/U] [/?]', 13, 10
    db 13, 10
    db '  /1  Pal 1 High: Lt.Cyan, Lt.Magenta, White  (default)', 13, 10
    db '  /2  Pal 1 Low:  Cyan, Magenta, Lt.Gray', 13, 10
    db '  /3  Pal 0 High: Lt.Green, Lt.Red, Yellow', 13, 10
    db '  /4  Pal 0 Low:  Green, Red, Brown', 13, 10
    db '  /5  Mode 5 High: Lt.Cyan, Lt.Red, White', 13, 10
    db '  /6  Mode 5 Low:  Cyan, Red, Lt.Gray', 13, 10
    db 13, 10
    db '  /b:N    Background color (0-15 or name)', 13, 10
    db '  /T      Disable timer enforcement (default: ON)', 13, 10
    db '  /U      Uninstall TSR', 13, 10
    db '  /?      Show this help', 13, 10
    db 13, 10
    db 'Hotkeys:  Ctrl+Alt + 1..6  Switch palette live', 13, 10
    db 13, 10
    db 'Colors: black blue green cyan red magenta brown lightgray', 13, 10
    db '  darkgray lightblue lightgreen lightcyan lightred', 13, 10
    db '  lightmagenta yellow white', 13, 10
    db '$'

msg_combo1: db 'Palette: /1 - Pal 1 High: Lt.Cyan, Lt.Magenta, White', 13, 10, '$'
msg_combo2: db 'Palette: /2 - Pal 1 Low:  Cyan, Magenta, Lt.Gray', 13, 10, '$'
msg_combo3: db 'Palette: /3 - Pal 0 High: Lt.Green, Lt.Red, Yellow', 13, 10, '$'
msg_combo4: db 'Palette: /4 - Pal 0 Low:  Green, Red, Brown', 13, 10, '$'
msg_combo5: db 'Palette: /5 - Mode 5 High: Lt.Cyan, Lt.Red, White', 13, 10, '$'
msg_combo6: db 'Palette: /6 - Mode 5 Low:  Cyan, Red, Lt.Gray', 13, 10, '$'

msg_bg_prefix:    db 'Background: $'
msg_bg_suffix:    db ' = $'
msg_crlf:         db 13, 10, '$'

msg_installed:
    db 'TSR installed. Ctrl+Alt+1..6 to switch live.', 13, 10
    db 'Run CGASWAP /U to uninstall.', 13, 10, '$'
msg_timer_on:
    db 'Timer enforcement ON (~18 Hz, mode 4/5 only).', 13, 10, '$'
msg_timer_off:
    db 'Timer enforcement OFF.', 13, 10, '$'
msg_updated:
    db 'CGASwap already resident - palette updated.', 13, 10, '$'
msg_unloaded:
    db 'CGASwap uninstalled. All interrupts restored.', 13, 10, '$'
msg_unload_error:
    db 'Error: CGASwap not found in interrupt chain.', 13, 10, '$'
msg_bad_switch:
    db 'Error: Unknown switch. Use /? for help.', 13, 10, '$'
msg_bad_bg:
    db 'Error: Bad background color. Use 0-15 or a color name.', 13, 10, '$'

; Color name table (lowercase, null-terminated, sequential)
color_names:
    db 'black', 0
    db 'blue', 0
    db 'green', 0
    db 'cyan', 0
    db 'red', 0
    db 'magenta', 0
    db 'brown', 0
    db 'lightgray', 0
    db 'darkgray', 0
    db 'lightblue', 0
    db 'lightgreen', 0
    db 'lightcyan', 0
    db 'lightred', 0
    db 'lightmagenta', 0
    db 'yellow', 0
    db 'white', 0
    db 0                       ; end of table

; Pointers to $-terminated color name strings for printing
color_name_ptrs:
    dw cn_black, cn_blue, cn_green, cn_cyan
    dw cn_red, cn_magenta, cn_brown, cn_lightgray
    dw cn_darkgray, cn_lightblue, cn_lightgreen, cn_lightcyan
    dw cn_lightred, cn_lightmagenta, cn_yellow, cn_white

cn_black:        db 'Black$'
cn_blue:         db 'Blue$'
cn_green:        db 'Green$'
cn_cyan:         db 'Cyan$'
cn_red:          db 'Red$'
cn_magenta:      db 'Magenta$'
cn_brown:        db 'Brown$'
cn_lightgray:    db 'Light Gray$'
cn_darkgray:     db 'Dark Gray$'
cn_lightblue:    db 'Light Blue$'
cn_lightgreen:   db 'Light Green$'
cn_lightcyan:    db 'Light Cyan$'
cn_lightred:     db 'Light Red$'
cn_lightmagenta: db 'Light Magenta$'
cn_yellow:       db 'Yellow$'
cn_white:        db 'White$'

; Installer state variables
show_help:        db 0
do_uninstall:     db 0
parse_error:      db 0
timer_mode:       db 0            ; 0 = timer ON (default), 1 = timer OFF (/T)
