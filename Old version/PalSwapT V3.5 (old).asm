; ============================================================================
; PalSwapT.ASM - CGA Palette Override TSR with Live Hotkeys
; Written for NASM - 8086 compatible (runs on any DOS PC)
; By Retro Erik - 2026 using VS Code with GitHub Copilot
; Version 3.5 - Removed ATC reprogramming from VGA path
; ============================================================================
;
; Combines the full palette engine of PalSwap.asm with a TSR that hooks
; both INT 10h (video mode change) and INT 09h (keyboard) so you can:
;   - Survive CGA mode resets (palette re-applied after every mode 4/5 set)
;   - Switch presets LIVE while a game is running (Ctrl+Alt + 0..9)
;   - Adjust brightness, saturation, pop on the fly (Ctrl+Alt + arrows/P/R)
;   - Generate random palettes from CGA/C64/Amstrad CPC/ZX Spectrum colors
;
; HOTKEY SYSTEM:
;   Hold Ctrl+Alt and press a hotkey to adjust the palette:
;     0..9         Load preset 1-9
;     P            Toggle Pop (saturation + contrast boost)
;     R            Reset to default CGA palette (high-intensity)
;     Up / Down    Brighten / Dim (+/-8 per step, max 3 steps)
;     Left / Right Less vivid / More vivid (saturation, max 3 steps)
;     Space        Random palette from 15 CGA colors
;     C            Random palette from C64 colors (Lospec)
;     A            Random palette from Amstrad CPC colors
;     Z            Random palette from ZX Spectrum colors
;   Release Ctrl+Alt to return to normal — all keys pass through.
;
; BUILT-IN PRESETS:
;     /1  Arcade Vibrant     /2  Sierra Natural     /3  C64-inspired
;     /4  CGA Red/Green      /5  CGA Red/Blue       /6  Amstrad CPC
;     /7  Pastel             /8  Mono Amber          /9  Mono Green
;
; HOW IT WORKS:
;   1. You run PalSwapT [/1..9 | file.txt | /c:... | /b:...] before the game.
;   2. PalSwapT loads the palette, hooks INT 09h + INT 10h, stays resident.
;   3. When the game calls INT 10h AH=00h AL=04h/05h (set CGA mode 4/5):
;        a. The original INT 10h handler runs first (sets the hardware mode).
;        b. Our hook immediately re-programs the VGA DAC or EGA ATC.
;   4. While running, hold Ctrl+Alt and press hotkeys to adjust live.
;   5. Re-run PalSwapT with new arguments to update the resident palette.
;   6. Run "PalSwapT /U" to uninstall.
;
; VGA path:
;   Table-driven DAC write using color_to_dac[] mapping.  Programs all 16
;   DAC entries so every CGA palette variant (pal0/pal1 × low/high) gets
;   the user's custom colors.  No ATC reprogramming, no BIOS palette disable
;   (1201h/31h) — the INT 10h hook re-applies after every mode 4/5 set,
;   and the BIOS reloads default DAC/ATC on mode 3, keeping text mode clean.
;
; EGA path:
;   Converts RGB to nearest EGA 6-bit values. Builds 16-entry atc_shadow[]
;   covering all CGA palette routing variants.  Re-applied via ATC ports.
;
; CGA mode 4 pixel -> DAC entry mapping (all 16 entries programmed):
;   DAC 0  = color 0 (background)
;   DAC 1  = color 1 (our ATC)     DAC 8  = color 2 (our ATC)
;   DAC 2  = color 1 (pal0 low)    DAC 9  = color 3 (our ATC)
;   DAC 3  = color 1 (pal1 low)    DAC 10 = color 1 (pal0 high)
;   DAC 4  = color 2 (pal0 low)    DAC 11 = color 1 (pal1 high)
;   DAC 5  = color 2 (pal1 low)    DAC 12 = color 2 (pal0 high)
;   DAC 6  = color 3 (pal0 low)    DAC 13 = color 2 (pal1 high)
;   DAC 7  = color 3 (pal1 low)    DAC 14 = color 3 (pal0 high)
;                                   DAC 15 = color 3 (pal1 high)
;
; IMPORTANT - far-pointer layout in resident data:
;   orig_int10_ofs MUST come before orig_int10_seg in memory because
;   "jmp/call far [mem]" reads offset then segment.
;   Same for orig_int09_ofs / orig_int09_seg.
;
; TSR SIZE:
;   Computed at runtime as  (offset_of_tsr_end + 15) / 16  paragraphs.
;   ORG 0x100 means label offsets already include the 256-byte PSP.
;
; Usage: PalSwapT [file.txt] [/1..9] [/c:c1,c2,c3] [/b:color]
;                 [/P] [/V:+|-] [/D:+|-] [/R] [/U] [/?]
;
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 8086

; ============================================================================
; Constants
; ============================================================================
VGA_DAC_WRITE_IDX   equ 0x3C8
VGA_DAC_DATA        equ 0x3C9
ATC_ADDR_DATA       equ 0x3C0
INPUT_STATUS_1      equ 0x3DA

CONFIG_SIZE         equ 12          ; 4 colors × 3 bytes (single palette)
PALETTE_ENTRIES     equ 4
MAX_PALETTES        equ 9           ; max palettes in a file
MULTI_CONFIG_SIZE   equ 108         ; 9 palettes × 12 bytes
TEXT_BUF_SIZE       equ 1024

; Keyboard scan codes
SCAN_1              equ 0x02
SCAN_5              equ 0x06
SCAN_9              equ 0x0A
SCAN_0              equ 0x0B
SCAN_P              equ 0x19
SCAN_R              equ 0x13
SCAN_UP             equ 0x48
SCAN_DOWN           equ 0x50
SCAN_LEFT           equ 0x4B
SCAN_RIGHT          equ 0x4D
SCAN_SPACE          equ 0x39
SCAN_C              equ 0x2E
SCAN_A              equ 0x1E
SCAN_Z              equ 0x2C

; BIOS keyboard flag bits at 0040:0017h
CTRL_BIT            equ 0x04        ; bit 2 = Ctrl key held
ALT_BIT             equ 0x08        ; bit 3 = Alt key held
CTRLALT_BITS        equ 0x0C        ; both Ctrl + Alt held

; Adjustment limits
MAX_BRIGHT_LEVEL    equ 3
MAX_VIVID_LEVEL     equ 3

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
tsr_sig:            db 'PalSwap'

; --- Original interrupt vectors (far pointers: offset THEN segment) ---
orig_int10_ofs:     dw 0
orig_int10_seg:     dw 0
orig_int09_ofs:     dw 0
orig_int09_seg:     dw 0

; --- Video adapter type: 0=none, 1=EGA, 2=VGA ---
video_type:         db 0

; --- Adjustment state ---
adj_brightness:     db 0            ; signed: -3..+3 (each step = ±8)
adj_vivid:          db 0            ; signed: -3..+3
adj_pop:            db 0            ; 0=off, 1=on (toggle)
palette_active:     db 1            ; 1=apply custom palette, 0=use defaults

; --- Random number generator seed ---
rng_seed:           dw 0

; --- Base palette: the original colors loaded from preset/file/cmdline.
;     Never modified by hotkeys. Adjustments are applied on top of this. ---
base_palette:
    db 0,  0,  0               ; color 0: Black
    db 0, 63, 63               ; color 1: Light Cyan (high intensity)
    db 63,  0, 63              ; color 2: Light Magenta (high intensity)
    db 63, 63, 63              ; color 3: White

; --- Active palette: recomputed from base + adjustments, written to HW ---
palette_rgb:
    db 0,  0,  0
    db 0, 63, 63
    db 63,  0, 63
    db 63, 63, 63

; --- EGA ATC shadow table (16 bytes, rebuilt on every adjustment) ---
atc_shadow:         times 16 db 0

; --- Resident lookup tables ---

; Maps DAC entry 0-15 to user color index 0-3 (conflict-free routing)
color_to_dac:
    db 0, 1, 1, 1, 2, 2, 3, 3, 2, 3, 1, 1, 2, 2, 3, 3

; ATC[0-3] = 0,1,8,9 (conflict-free), ATC[4-15] = standard text values
; (Kept for reference — no longer written to hardware in VGA mode)
; vga_atc_init:
;     db 0, 1, 8, 9, 4, 5, 0x14, 7, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F

; Default EGA ATC register values for the 16 CGA colors
cga_ega_default:
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
    db 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F

; 5 preset palettes + fallback (resident for hotkey switching)
res_preset_fallback:
    db 0,  0,  0,    0, 63, 63,   63,  0, 63,   63, 63, 63
res_preset_1:                       ; Arcade Vibrant
    db 0,  0,  0,    9, 27, 63,   63,  9,  9,   63, 45, 27
res_preset_2:                       ; Sierra Natural
    db 0,  0,  0,    9, 36, 36,   36, 18,  9,   63, 45, 36
res_preset_3:                       ; C64-inspired
    db 0,  0,  0,   18, 27, 63,   54, 27,  9,   63, 54, 36
res_preset_4:                       ; CGA Red/Green/White
    db 0,  0,  0,   63,  9,  9,    9, 63,  9,   63, 63, 63
res_preset_5:                       ; CGA Red/Blue/White
    db 0,  0,  0,   63,  0,  0,    0,  0, 63,   63, 63, 63
res_preset_6:                       ; Amstrad CPC
    db 0,  0,  0,    0, 42, 42,   42, 42,  0,   63, 63, 63
res_preset_7:                       ; Pastel
    db 0,  0,  0,   27, 36, 63,   63, 36, 45,   54, 54, 63
res_preset_8:                       ; Monochrome Amber
    db 0,  0,  0,   21, 14,  0,   42, 28,  0,   63, 42,  0
res_preset_9:                       ; Monochrome Green
    db 0,  0,  0,    0, 21,  0,    0, 42,  0,    0, 63,  0
res_preset_0:                       ; Monochrome Gray
    db 0,  0,  0,   21, 21, 21,   36, 36, 36,   63, 63, 63

; DAC table workspace for VGA (16 entries × 3 bytes = 48 bytes)
dac_table:          times 48 db 0

; Standard VGA text mode DAC (16 entries × 3 bytes = 48 bytes)
; Used by restore_default_palette to reset to boot-time colors.
default_text_dac:
    db  0,  0,  0              ; 0  Black
    db  0,  0, 42              ; 1  Blue
    db  0, 42,  0              ; 2  Green
    db  0, 42, 42              ; 3  Cyan
    db 42,  0,  0              ; 4  Red
    db 42,  0, 42              ; 5  Magenta
    db 42, 21,  0              ; 6  Brown
    db 42, 42, 42              ; 7  Light Gray
    db 21, 21, 21              ; 8  Dark Gray
    db 21, 21, 63              ; 9  Light Blue
    db 21, 63, 21              ; 10 Light Green
    db 21, 63, 63              ; 11 Light Cyan
    db 63, 21, 21              ; 12 Light Red
    db 63, 21, 63              ; 13 Light Magenta
    db 63, 63, 21              ; 14 Yellow
    db 63, 63, 63              ; 15 White

; C64 palette (15 non-black, 6-bit VGA RGB)
; Source: Lospec.com - Commodore 64 palette
c64_colors:
    db 63, 63, 63              ; White
    db 39, 19, 17              ; Red
    db 26, 47, 49              ; Cyan
    db 40, 21, 40              ; Purple
    db 23, 42, 23              ; Green
    db 20, 17, 38              ; Blue
    db 50, 52, 33              ; Yellow
    db 40, 26, 15              ; Orange
    db 27, 21,  4              ; Brown
    db 50, 31, 29              ; Light Red
    db 24, 24, 24              ; Dark Gray
    db 34, 34, 34              ; Medium Gray
    db 38, 56, 38              ; Light Green
    db 34, 31, 50              ; Light Blue
    db 43, 43, 43              ; Light Gray
C64_COUNT           equ 15

; Amstrad CPC hardware palette (26 non-black, 3 levels per channel)
; Source: Lospec.com - Amstrad CPC palette
cpc_colors:
    db  0,  0, 31              ; Dark Blue
    db  0,  0, 63              ; Bright Blue
    db  0, 32,  0              ; Dark Green
    db  0, 32, 32              ; Dark Cyan
    db  0, 32, 63              ; Sky Blue
    db  0, 63,  0              ; Bright Green
    db  0, 63, 32              ; Sea Green
    db  0, 63, 63              ; Bright Cyan
    db 32,  0,  0              ; Dark Red
    db 32,  0, 32              ; Dark Magenta
    db 31,  0, 63              ; Mauve
    db 32, 32,  0              ; Dark Yellow
    db 32, 32, 32              ; Gray
    db 32, 32, 63              ; Pastel Blue
    db 32, 63,  0              ; Lime
    db 32, 63, 32              ; Pastel Green
    db 32, 63, 63              ; Pastel Cyan
    db 63,  0,  0              ; Bright Red
    db 63,  0, 32              ; Purple
    db 63,  0, 63              ; Bright Magenta
    db 63, 31,  0              ; Orange
    db 63, 32, 32              ; Pastel Red
    db 63, 32, 63              ; Pastel Magenta
    db 63, 63,  0              ; Bright Yellow
    db 63, 63, 32              ; Pastel Yellow
    db 63, 63, 63              ; White
CPC_COUNT           equ 26

; ZX Spectrum palette (14 non-black: 7 normal + 7 bright)
; Source: Lospec.com - ZX Spectrum palette
zx_colors:
    db  0,  0, 53              ; Blue
    db 53,  0,  0              ; Red
    db 53,  0, 53              ; Magenta
    db  0, 53,  0              ; Green
    db  0, 53, 53              ; Cyan
    db 53, 53,  0              ; Yellow
    db 53, 53, 53              ; White
    db  0,  0, 63              ; Bright Blue
    db 63,  0,  0              ; Bright Red
    db 63,  0, 63              ; Bright Magenta
    db  0, 63,  0              ; Bright Green
    db  0, 63, 63              ; Bright Cyan
    db 63, 63,  0              ; Bright Yellow
    db 63, 63, 63              ; Bright White
ZX_COUNT            equ 14

; EGA temporary workspace (4 bytes)
ega_tmp:            times 4 db 0

; ============================================================================
; INT 10h HOOK — Re-apply palette after CGA mode 4/5 set
; ============================================================================
tsr_int10:
    cmp ah, 0x00
    jne .chain
    cmp al, 0x04
    je .cga_mode
    cmp al, 0x05
    je .cga_mode

.chain:
    jmp far [cs:orig_int10_ofs]

.cga_mode:
    ; Let the original handler set the mode first
    pushf
    call far [cs:orig_int10_ofs]
    ; Only re-apply if custom palette is active
    cmp byte [cs:palette_active], 0
    je .no_apply
    cmp byte [cs:video_type], 2
    je .do_vga
    cmp byte [cs:video_type], 1
    je .do_ega
.no_apply:
    iret
.do_vga:
    call apply_palette_vga
    iret
.do_ega:
    call apply_palette_ega
    iret

; ============================================================================
; INT 09h HOOK — Ctrl+Alt-gated hotkeys for live palette adjustment
; ============================================================================
tsr_int09:
    push ax
    push bp
    push ds

    ; Read scan code from keyboard controller
    in al, 0x60

    ; Check if it's a key release (bit 7 set) — ignore releases
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
    jne .chain_kb              ; Ctrl+Alt not both held → pass through

    ; Ctrl+Alt held — check for our hotkeys
    mov ah, al                 ; save scan code in AH

    ; Preset keys 1-9, 0
    cmp ah, SCAN_1
    jb .check_special
    cmp ah, SCAN_0
    ja .check_special
    ; AH = 02h..0Bh → preset 1..9, 0
    sub ah, SCAN_1             ; AH = 0..9 = preset index
    call hotkey_load_preset
    jmp .swallow

.check_special:
    cmp ah, SCAN_P
    je .do_pop
    cmp ah, SCAN_R
    je .do_reset
    cmp ah, SCAN_UP
    je .do_bright_up
    cmp ah, SCAN_DOWN
    je .do_bright_dn
    cmp ah, SCAN_RIGHT
    je .do_vivid_up
    cmp ah, SCAN_LEFT
    je .do_vivid_dn
    cmp ah, SCAN_SPACE
    je .do_random
    cmp ah, SCAN_C
    je .do_random_c64
    cmp ah, SCAN_A
    je .do_random_cpc
    cmp ah, SCAN_Z
    je .do_random_zx
    jmp .chain_kb              ; not our key → pass through

.do_pop:
    xor byte [cs:adj_pop], 1  ; toggle 0↔1
    call recompute_and_apply
    jmp .swallow

.do_reset:
    ; Load fallback palette, reset all adjustments
    mov ah, 0                  ; preset index for fallback = special
    call hotkey_load_fallback
    jmp .swallow

.do_bright_up:
    cmp byte [cs:adj_brightness], MAX_BRIGHT_LEVEL
    jge .swallow               ; already at max
    inc byte [cs:adj_brightness]
    call recompute_and_apply
    jmp .swallow

.do_bright_dn:
    cmp byte [cs:adj_brightness], -MAX_BRIGHT_LEVEL
    jle .swallow               ; already at min
    dec byte [cs:adj_brightness]
    call recompute_and_apply
    jmp .swallow

.do_vivid_up:
    cmp byte [cs:adj_vivid], MAX_VIVID_LEVEL
    jge .swallow
    inc byte [cs:adj_vivid]
    call recompute_and_apply
    jmp .swallow

.do_vivid_dn:
    cmp byte [cs:adj_vivid], -MAX_VIVID_LEVEL
    jle .swallow
    dec byte [cs:adj_vivid]
    call recompute_and_apply
    jmp .swallow

.do_random:
    mov si, default_text_dac + 3
    mov bp, 15
    call hotkey_random
    jmp .swallow

.do_random_c64:
    mov si, c64_colors
    mov bp, C64_COUNT
    call hotkey_random
    jmp .swallow

.do_random_cpc:
    mov si, cpc_colors
    mov bp, CPC_COUNT
    call hotkey_random
    jmp .swallow

.do_random_zx:
    mov si, zx_colors
    mov bp, ZX_COUNT
    call hotkey_random
    jmp .swallow

.swallow:
    ; Acknowledge keystroke: toggle port 61h bit 7 + send EOI to PIC
    in al, 0x61
    or al, 0x80
    out 0x61, al
    and al, 0x7F
    out 0x61, al
    mov al, 0x20
    out 0x20, al
    pop ds
    pop bp
    pop ax
    iret

.chain_kb:
    pop ds
    pop bp
    pop ax
    jmp far [cs:orig_int09_ofs]

; ============================================================================
; hotkey_load_preset — Load preset by index (AH = 0..9)
; AH 0..8 = presets 1..9, AH 9 = preset 0 (Mono Gray).
; Resets adjustments and recomputes.
; ============================================================================
hotkey_load_preset:
    push ax
    push cx
    push si
    push di
    push es

    push cs
    pop es

    ; Calculate source: res_preset_1 + AH * 12
    mov al, ah
    xor ah, ah
    mov cl, 12
    mul cl                     ; AX = preset_index * 12
    mov si, res_preset_1
    add si, ax

    ; Copy 12 bytes to base_palette
    mov di, base_palette
    mov cx, 12
.copy:
    mov al, [cs:si]
    mov [cs:di], al
    inc si
    inc di
    loop .copy

    ; Reset adjustments
    mov byte [cs:adj_brightness], 0
    mov byte [cs:adj_vivid], 0
    mov byte [cs:adj_pop], 0

    pop es
    pop di
    pop si
    pop cx
    pop ax
    call recompute_and_apply
    ret

; ============================================================================
; hotkey_load_fallback — Reset to default CGA palette
; In CGA mode 4/5: applies standard high-intensity CGA through our routing.
; In text mode: restores full 16-color DAC/ATC and goes dormant.
; ============================================================================
hotkey_load_fallback:
    push cx
    push si
    push di
    push es

    push cs
    pop es

    mov si, res_preset_fallback
    mov di, base_palette
    mov cx, 12
.copy:
    mov al, [cs:si]
    mov [cs:di], al
    inc si
    inc di
    loop .copy

    mov byte [cs:adj_brightness], 0
    mov byte [cs:adj_vivid], 0
    mov byte [cs:adj_pop], 0

    pop es
    pop di
    pop si
    pop cx

    ; Check current video mode to decide reset strategy
    push ax
    push ds
    mov ax, 0x0040
    mov ds, ax
    mov al, [0x0049]           ; BIOS current video mode
    pop ds
    cmp al, 4
    je .cga_mode_reset
    cmp al, 5
    je .cga_mode_reset

    ; Text mode: full DAC/ATC restore, go dormant
    mov byte [cs:palette_active], 0
    pop ax
    call restore_default_palette
    ret

.cga_mode_reset:
    ; CGA mode: apply standard CGA through our routing
    mov byte [cs:palette_active], 1
    pop ax
    call recompute_and_apply
    ret

; ============================================================================
; recompute_and_apply — Rebuild palette_rgb from base + adjustments, then
;                       write to hardware (VGA DAC or EGA ATC).
;
; Pipeline:  base → copy to palette_rgb
;            → apply vivid (N times boost or mute)
;            → if pop: saturation_boost + contrast_boost
;            → apply brightness (adj × 8, clamped)
;            → rebuild EGA atc_shadow if needed
;            → write to hardware
; ============================================================================
recompute_and_apply:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    push cs
    pop es

    mov byte [cs:palette_active], 1

    ; Step 1: Copy base_palette → palette_rgb
    mov si, base_palette
    mov di, palette_rgb
    mov cx, 12
.rc_copy:
    mov al, [cs:si]
    mov [cs:di], al
    inc si
    inc di
    loop .rc_copy

    ; Step 2: Vivid adjustment (-3..+3 steps of saturation boost/mute)
    mov al, [cs:adj_vivid]
    test al, al
    jz .rc_pop_check
    js .rc_vivid_mute
    ; Positive: apply saturation boost N times
    mov cl, al
    xor ch, ch
.rc_vivid_boost_loop:
    call res_saturation_boost
    loop .rc_vivid_boost_loop
    jmp .rc_pop_check
.rc_vivid_mute:
    ; Negative: apply saturation mute N times
    neg al
    mov cl, al
    xor ch, ch
.rc_vivid_mute_loop:
    call res_saturation_mute
    loop .rc_vivid_mute_loop

.rc_pop_check:
    ; Step 3: Pop = saturation boost + contrast boost
    cmp byte [cs:adj_pop], 0
    je .rc_brightness
    call res_saturation_boost
    call res_contrast_boost

.rc_brightness:
    ; Step 4: Brightness (-3..+3 steps, each step = ±8)
    mov al, [cs:adj_brightness]
    test al, al
    jz .rc_apply
    js .rc_dim
    ; Positive: brighten
    mov cl, al
    xor ch, ch
.rc_bright_loop:
    call res_brighten
    loop .rc_bright_loop
    jmp .rc_apply
.rc_dim:
    neg al
    mov cl, al
    xor ch, ch
.rc_dim_loop:
    call res_dim
    loop .rc_dim_loop

.rc_apply:
    ; Step 5: Rebuild EGA shadow if needed, then write to hardware
    cmp byte [cs:video_type], 2
    je .rc_vga
    cmp byte [cs:video_type], 1
    je .rc_ega
    jmp .rc_done

.rc_vga:
    call apply_palette_vga
    jmp .rc_done

.rc_ega:
    call res_build_ega_shadow
    call apply_palette_ega

.rc_done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; apply_palette_vga — Table-driven VGA DAC write
; Reads from palette_rgb[], uses color_to_dac[] for mapping.
; Programs all 16 DAC entries so every CGA palette variant works.
; No ATC reprogramming — BIOS ATC routes correctly to our DAC entries.
; All addresses via CS: since this runs from the TSR.
; ============================================================================
apply_palette_vga:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; Build 48-byte DAC table from palette_rgb using color_to_dac mapping
    mov si, color_to_dac
    mov di, dac_table
    mov cx, 16
.build_dac:
    mov al, [cs:si]            ; AL = user color index (0-3)
    inc si
    ; Multiply by 3 for palette_rgb offset
    mov bl, al
    shl bl, 1
    add bl, al                 ; BL = index * 3
    xor bh, bh
    mov al, [cs:palette_rgb + bx]
    mov [cs:di], al
    mov al, [cs:palette_rgb + bx + 1]
    mov [cs:di + 1], al
    mov al, [cs:palette_rgb + bx + 2]
    mov [cs:di + 2], al
    add di, 3
    loop .build_dac

    ; Write all 16 DAC entries starting at index 0
    mov dx, VGA_DAC_WRITE_IDX
    xor al, al
    out dx, al
    mov si, dac_table
    mov cx, 48
    mov dx, VGA_DAC_DATA
.write_dac:
    mov al, [cs:si]
    inc si
    out dx, al
    loop .write_dac

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; res_build_ega_shadow — Convert palette_rgb to EGA ATC shadow table
; Copies cga_ega_default to atc_shadow, then converts 4 RGB colors to
; nearest EGA 6-bit values and places them at all CGA mode 4 positions.
; ============================================================================
res_build_ega_shadow:
    push ax
    push bx
    push cx
    push si
    push di

    ; Copy 16 ATC defaults to shadow
    mov si, cga_ega_default
    mov di, atc_shadow
    mov cx, 16
.copy_defaults:
    mov al, [cs:si]
    mov [cs:di], al
    inc si
    inc di
    loop .copy_defaults

    ; Convert 4 RGB colors to EGA 6-bit values in ega_tmp
    mov si, palette_rgb
    mov di, ega_tmp
    mov cx, 4
.conv_loop:
    xor bl, bl
    mov al, [cs:si]            ; Red
    inc si
    cmp al, 32
    jb .r_half
    or bl, 0x04
    jmp .r_done
.r_half:
    cmp al, 16
    jb .r_done
    or bl, 0x20
.r_done:
    mov al, [cs:si]            ; Green
    inc si
    cmp al, 32
    jb .g_half
    or bl, 0x02
    jmp .g_done
.g_half:
    cmp al, 16
    jb .g_done
    or bl, 0x10
.g_done:
    mov al, [cs:si]            ; Blue
    inc si
    cmp al, 32
    jb .b_half
    or bl, 0x01
    jmp .b_done
.b_half:
    cmp al, 16
    jb .b_done
    or bl, 0x08
.b_done:
    mov [cs:di], bl
    inc di
    loop .conv_loop

    ; Place EGA values into atc_shadow at all CGA mode 4 positions
    mov al, [cs:ega_tmp+0]
    mov [cs:atc_shadow+0], al

    mov al, [cs:ega_tmp+1]
    mov [cs:atc_shadow+2], al
    mov [cs:atc_shadow+3], al
    mov [cs:atc_shadow+10], al
    mov [cs:atc_shadow+11], al

    mov al, [cs:ega_tmp+2]
    mov [cs:atc_shadow+4], al
    mov [cs:atc_shadow+5], al
    mov [cs:atc_shadow+12], al
    mov [cs:atc_shadow+13], al

    mov al, [cs:ega_tmp+3]
    mov [cs:atc_shadow+6], al
    mov [cs:atc_shadow+7], al
    mov [cs:atc_shadow+14], al
    mov [cs:atc_shadow+15], al

    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; apply_palette_ega — Write atc_shadow[0-15] to ATC registers
; ============================================================================
apply_palette_ega:
    push ax
    push bx
    push dx

    cli
    mov dx, INPUT_STATUS_1
    in al, dx                  ; Reset ATC flip-flop

    xor bx, bx
.write_atc:
    mov dx, ATC_ADDR_DATA
    mov al, bl
    out dx, al
    jmp short $+2
    mov al, [cs:atc_shadow + bx]
    out dx, al
    jmp short $+2
    inc bx
    cmp bx, 16
    jb .write_atc

    mov al, 0x20               ; Re-enable screen
    out dx, al
    sti

    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; RESIDENT ADJUSTMENT ROUTINES
; These operate on palette_rgb (colors 1-3 only, skip background at offset 0).
; All use CS: segment override since they run from the TSR.
; ============================================================================

; --- res_brighten: Add 8 to each RGB channel, clamp at 63 ---
res_brighten:
    push cx
    push si
    mov si, palette_rgb + 3    ; skip color 0
    mov cx, 9
.loop:
    mov al, [cs:si]
    add al, 8
    cmp al, 63
    jbe .ok
    mov al, 63
.ok:
    mov [cs:si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; --- res_dim: Subtract 8 from each RGB channel, clamp at 0 ---
res_dim:
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 9
.loop:
    mov al, [cs:si]
    sub al, 8
    jnc .ok
    xor al, al
.ok:
    mov [cs:si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; --- res_saturation_boost: ch + (ch - gray) / 2, clamp 0-63 ---
res_saturation_boost:
    push bx
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 3                  ; 3 color triples
.color:
    xor ax, ax
    mov al, [cs:si]
    add al, [cs:si+1]
    add al, [cs:si+2]         ; AL = R+G+B
    mov bl, 3
    div bl                     ; AL = gray
    mov bl, al                 ; BL = gray

    push cx
    mov cx, 3
.ch:
    mov al, [cs:si]
    sub al, bl                 ; AL = ch - gray (signed)
    sar al, 1                 ; AL = (ch - gray) / 2
    add al, [cs:si]           ; AL = ch + (ch - gray) / 2
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [cs:si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

; --- res_saturation_mute: (ch + gray) / 2 ---
res_saturation_mute:
    push bx
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 3
.color:
    xor ax, ax
    mov al, [cs:si]
    add al, [cs:si+1]
    add al, [cs:si+2]
    mov bl, 3
    div bl
    mov bl, al                 ; BL = gray

    push cx
    mov cx, 3
.ch:
    mov al, [cs:si]
    add al, bl
    shr al, 1                 ; (ch + gray) / 2
    mov [cs:si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

; --- res_contrast_boost: ch + (ch - 31) / 2, clamp 0-63 ---
res_contrast_boost:
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 9
.loop:
    mov al, [cs:si]
    sub al, 31                 ; signed
    sar al, 1
    add al, [cs:si]
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [cs:si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; ============================================================================
; restore_default_palette — Write boot-time 16-color DAC + default ATC
; Called by Ctrl+Alt+R hotkey and default install.
; VGA: writes 16 default DAC entries (no ATC touch — BIOS handles it).
; EGA: restores default ATC[0-15].
; ============================================================================
restore_default_palette:
    push ax
    push bx
    push cx
    push dx
    push si

    cmp byte [cs:video_type], 2
    jne .restore_atc_only

    ; Write 16 default DAC entries (VGA only)
    mov dx, VGA_DAC_WRITE_IDX
    xor al, al
    out dx, al
    mov si, default_text_dac
    mov cx, 48
    mov dx, VGA_DAC_DATA
.write_dac:
    mov al, [cs:si]
    inc si
    out dx, al
    loop .write_dac

    jmp .done

.restore_atc_only:
    ; Restore default ATC[0-15] (EGA only)
    cli
    mov dx, INPUT_STATUS_1
    in al, dx
    xor bx, bx
.write_atc:
    mov dx, ATC_ADDR_DATA
    mov al, bl
    out dx, al
    jmp short $+2
    mov al, [cs:cga_ega_default + bx]
    out dx, al
    jmp short $+2
    inc bx
    cmp bx, 16
    jb .write_atc
    mov al, 0x20
    out dx, al
    sti

.done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; hotkey_random — Pick 3 unique random colors from a palette table
; Input: SI = color table (N entries × 3 bytes), BP = color count
; ============================================================================
hotkey_random:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds

    ; Save table pointer in DI
    mov di, si

    ; Seed from BIOS timer tick
    mov ax, 0x0040
    mov ds, ax
    mov ax, [0x006C]
    add [cs:rng_seed], ax

    ; Pick color 1
    mov bx, bp
    call get_random_n
    mov cl, dl                  ; CL = index1
    mov si, di
    add si, bx
    mov al, [cs:si]
    mov [cs:base_palette+3], al
    mov al, [cs:si+1]
    mov [cs:base_palette+4], al
    mov al, [cs:si+2]
    mov [cs:base_palette+5], al

    ; Pick color 2 (must differ from color 1)
.pick2:
    mov bx, bp
    call get_random_n
    cmp dl, cl
    je .pick2
    mov ch, dl                  ; CH = index2
    mov si, di
    add si, bx
    mov al, [cs:si]
    mov [cs:base_palette+6], al
    mov al, [cs:si+1]
    mov [cs:base_palette+7], al
    mov al, [cs:si+2]
    mov [cs:base_palette+8], al

    ; Pick color 3 (must differ from color 1 and 2)
.pick3:
    mov bx, bp
    call get_random_n
    cmp dl, cl
    je .pick3
    cmp dl, ch
    je .pick3
    mov si, di
    add si, bx
    mov al, [cs:si]
    mov [cs:base_palette+9], al
    mov al, [cs:si+1]
    mov [cs:base_palette+10], al
    mov al, [cs:si+2]
    mov [cs:base_palette+11], al

    ; Reset adjustments, activate palette
    mov byte [cs:adj_brightness], 0
    mov byte [cs:adj_vivid], 0
    mov byte [cs:adj_pop], 0
    mov byte [cs:palette_active], 1

    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    call recompute_and_apply
    ret

; ============================================================================
; get_random_n — Return random index into N-color table
; Input: BX = color count (modulus N)
; Output: BX = (0..N-1) * 3  (byte offset), DL = raw index (0..N-1)
; Trashes: AX, DX
; ============================================================================
get_random_n:
    push cx
    mov cx, bx                  ; save count
    mov ax, [cs:rng_seed]
    mov bx, 25173
    mul bx                      ; DX:AX = seed * 25173
    add ax, 13849
    mov [cs:rng_seed], ax       ; store new seed
    xor dx, dx
    mov bx, cx                  ; BX = count
    div bx                      ; DX = remainder 0..N-1
    mov bx, dx
    mov ax, bx
    shl bx, 1
    add bx, ax                  ; BX = index * 3
    pop cx
    ret

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

    ; Detect EGA/VGA
    call detect_video
    cmp byte [video_type], 0
    je .no_adapter

    ; Check for /U (uninstall) first
    call check_uninstall
    cmp al, 1
    je .do_uninstall

    ; Parse all command-line switches
    call check_switches
    push ax                    ; save switch result
    call parse_bg_color
    call parse_fg_colors
    pop ax
    cmp byte [parse_error], 0
    jne .exit_no_tsr
    cmp al, 1
    je .show_help
    ; AL=2..12: preset/reset dispatch via data tables
    cmp al, 2
    jb .load_file
    cmp al, 12
    ja .load_file
    push bx
    sub al, 2                  ; AL = 0..10 (index into tables)
    xor ah, ah
    shl ax, 1                  ; AX = index × 2 (word offset)
    mov bx, ax
    mov dx, [.msg_table + bx]
    call print_string
    mov si, [.preset_table + bx]
    pop bx
    ; /R (index 0) sets default install flag
    cmp si, res_preset_fallback
    jne .apply_preset
    mov byte [is_default_install], 1
    jmp .apply_preset

.msg_table:
    dw msg_resetting, msg_preset1, msg_preset2, msg_preset3, msg_preset4
    dw msg_preset5, msg_preset6, msg_preset7, msg_preset8, msg_preset9
    dw msg_preset0

.preset_table:
    dw res_preset_fallback, res_preset_1, res_preset_2, res_preset_3
    dw res_preset_4, res_preset_5, res_preset_6, res_preset_7
    dw res_preset_8, res_preset_9, res_preset_0

.no_adapter:
    mov dx, msg_no_adapter
    call print_string
    jmp .exit_no_tsr

.show_help:
    mov dx, msg_help
    call print_string
    mov dx, msg_pause
    call print_string
.flush_kb:
    mov ah, 0x01
    int 0x16
    jz .wait_key
    mov ah, 0x00
    int 0x16
    jmp .flush_kb
.wait_key:
    mov ah, 0x00
    int 0x16
    mov dx, msg_help2
    call print_string
    jmp .exit_no_tsr

.apply_preset:
    ; Copy 12 bytes from preset to config_buffer
    mov di, config_buffer
    mov cx, 6
    cld
    rep movsw
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    jmp .do_install

.load_file:
    call load_config
    jc .use_fallback
    call validate_palette
    jc .use_fallback

    ; If file had multiple palettes, copy them over resident presets
    cmp byte [palettes_loaded], 1
    jbe .single_palette
    call copy_file_palettes_to_presets
    mov dx, msg_multi_loaded
    call print_string
.single_palette:
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    jmp .do_install

.use_fallback:
    ; Only show message if user explicitly specified a file
    cmp byte [explicit_file], 1
    jne .skip_fallback_msg
    mov dx, msg_fallback
    call print_string
.skip_fallback_msg:
    call load_fallback_to_config
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    ; Default install if no customization flags set
    cmp byte [bg_specified], 0
    jne .do_install
    cmp byte [fg_specified], 0
    jne .do_install
    cmp byte [pop_flag_cmd], 0
    jne .do_install
    cmp byte [brightness_adj_cmd], 0
    jne .do_install
    cmp byte [vivid_adj_cmd], 0
    jne .do_install
    mov byte [is_default_install], 1

.do_install:
    ; Copy final config_buffer → base_palette AND palette_rgb
    mov si, config_buffer
    mov di, base_palette
    mov cx, 6
    cld
    rep movsw
    mov si, config_buffer
    mov di, palette_rgb
    mov cx, 6
    cld
    rep movsw

    ; Reset adjustment state
    mov byte [adj_brightness], 0
    mov byte [adj_vivid], 0
    mov byte [adj_pop], 0

    ; Build EGA shadow if needed
    cmp byte [video_type], 1
    jne .skip_ega_init
    call res_build_ega_shadow
.skip_ega_init:

    ; Check if this is a default install (no custom palette)
    cmp byte [is_default_install], 0
    jne .skip_hw_apply

    ; Apply palette now (before printing preview so colors are visible)
    mov byte [palette_active], 1
    cmp byte [video_type], 2
    je .apply_vga_now
    call apply_palette_ega
    jmp .palette_applied
.apply_vga_now:
    ; No 1201h/31h call — the INT 10h hook re-applies the palette after
    ; every mode 4/5 set, so the BIOS disable flag is redundant. Letting
    ; the BIOS reload default DAC on mode 3 keeps text mode clean.
    call apply_palette_vga
    jmp .palette_applied

.skip_hw_apply:
    ; Default install: don't touch hardware, let INT 10h hook handle it
    mov byte [palette_active], 0

.palette_applied:
    ; Print loaded colors
    call print_colors

.check_installed:
    call check_already_loaded
    cmp al, 1
    je .already_loaded

    ; Save original INT 10h
    mov ax, 0x3510
    int 0x21
    mov [orig_int10_seg], es
    mov [orig_int10_ofs], bx

    ; Save original INT 09h
    mov ax, 0x3509
    int 0x21
    mov [orig_int09_seg], es
    mov [orig_int09_ofs], bx

    ; Install INT 10h hook
    mov ax, 0x2510
    mov dx, tsr_int10
    int 0x21

    ; Install INT 09h hook
    mov ax, 0x2509
    mov dx, tsr_int09
    int 0x21

    mov dx, msg_installed
    call print_string

    ; Go resident — compute size in paragraphs
    mov dx, tsr_end
    add dx, 15
    mov cl, 4
    shr dx, cl
    mov ax, 0x3100
    int 0x21

.already_loaded:
    ; TSR is already resident — update its data via the resident segment.
    ; Get resident segment from INT 10h vector (ES = resident code segment)
    mov ax, 0x3510
    int 0x21
    ; ES now points to the resident TSR segment

    ; Copy base_palette to resident
    push ds
    push cs
    pop ds
    mov si, base_palette
    mov di, base_palette
    mov cx, 6
    cld
    rep movsw

    ; Copy palette_rgb to resident
    mov si, palette_rgb
    mov di, palette_rgb
    mov cx, 6
    cld
    rep movsw

    ; Copy adjustments to resident
    mov al, [adj_brightness]
    mov [es:adj_brightness], al
    mov al, [adj_vivid]
    mov [es:adj_vivid], al
    mov al, [adj_pop]
    mov [es:adj_pop], al
    mov al, [palette_active]
    mov [es:palette_active], al
    pop ds

    ; If multi-palette file was loaded, copy presets to resident
    cmp byte [palettes_loaded], 1
    jbe .no_preset_update
    push ds
    push cs
    pop ds
    mov si, res_preset_1
    mov di, res_preset_1
    mov al, [palettes_loaded]
    xor ah, ah
    mov cl, 6
    mul cl
    mov cx, ax
    cld
    rep movsw
    pop ds
.no_preset_update:

    ; If default install (/R), restore built-in presets and text-mode hardware
    cmp byte [is_default_install], 0
    je .reload_done
    ; Copy all 9 original built-in presets from transient → resident
    push ds
    push cs
    pop ds
    mov si, res_preset_1
    mov di, res_preset_1
    mov cx, 9 * 6              ; 9 presets × 6 words each
    cld
    rep movsw
    pop ds
    call restore_default_palette
.reload_done:

    mov dx, msg_already_loaded
    call print_string
    jmp .exit_no_tsr

.do_uninstall:
    call uninstall_tsr
    jmp .exit_no_tsr

.exit_no_tsr:
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; detect_video — Set [video_type]: 0=none, 1=EGA, 2=VGA
; ============================================================================
detect_video:
    push ax
    push bx
    push cx

    ; Try VGA first (INT 10h AX=1A00h)
    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A
    jne .try_ega
    cmp bl, 0x08               ; VGA analog color
    je .is_vga
    cmp bl, 0x07               ; VGA analog mono
    je .is_vga

.try_ega:
    mov ax, 0x1200
    mov bl, 0x10
    int 0x10
    cmp bl, 0x10
    je .not_found

    ; Distinguish EGA from VGA
    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A
    je .check_vga_again

.is_ega:
    mov byte [video_type], 1
    mov dx, msg_detected_ega
    call print_string
    jmp .done

.check_vga_again:
    cmp bl, 0x08
    je .is_vga
    cmp bl, 0x07
    je .is_vga
    jmp .is_vga                ; VGA BIOS present, treat as VGA

.is_vga:
    mov byte [video_type], 2
    mov dx, msg_detected_vga
    call print_string
    jmp .done

.not_found:
    mov byte [video_type], 0

.done:
    pop cx
    pop bx
    pop ax
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
    ; Check if it points to our signature
    ; Our TSR has: jmp main, then tsr_sig at known offset
    ; The signature 'PalSwap' is at tsr_sig in seg pointed to by ES
    mov di, tsr_sig             ; offset of signature in our code
    mov si, tsr_sig             ; compare against our own copy
    mov cx, 7
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
; uninstall_tsr — Restore original INT 09h + INT 10h, free TSR memory
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

    ; ES = TSR segment. Restore original INT 10h from TSR's saved values.
    mov ax, 0x2510
    push word [es:orig_int10_seg]
    pop ds
    mov dx, [es:orig_int10_ofs]
    int 0x21

    ; Restore original INT 09h
    push cs
    pop ds                     ; restore DS for later
    mov ax, 0x2509
    push word [es:orig_int09_seg]
    pop ds
    mov dx, [es:orig_int09_ofs]
    int 0x21

    ; Free TSR's environment block first (segment at PSP offset 2Ch)
    ; ES still points to the TSR's PSP segment
    push es
    mov bx, es
    dec bx                     ; MCB is 1 paragraph before PSP
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
    pop ds                     ; ensure DS = CS for print_string

    mov dx, msg_unloaded
    jmp .ui_msg

.not_us:
    mov dx, msg_unload_error

.ui_msg:
    push cs
    pop ds
    call print_string

    pop es
    pop ds
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; check_uninstall — AL=1 if /U found on command line
; ============================================================================
check_uninstall:
    push si
    mov si, 0x81
.skip:
    lodsb
    cmp al, ' '
    je .skip
    cmp al, 0x0D
    je .none
    cmp al, '/'
    je .slash
    cmp al, '-'
    je .slash
    jmp .none
.slash:
    lodsb
    cmp al, 'U'
    je .yes
    cmp al, 'u'
    je .yes
.none:
    xor al, al
    jmp .done
.yes:
    mov al, 1
.done:
    pop si
    ret

; ============================================================================
; check_switches — Multi-pass scanner. Returns AL:
;   0=none/file, 1=help, 2=reset, 3-7=presets
; Also sets [brightness_adj], [vivid_adj], [pop_flag] from modifiers.
; ============================================================================
check_switches:
    push si
    mov si, 0x81

.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch

    cmp al, '/'
    je .check_char
    cmp al, '-'
    je .check_char
    jmp .no_switch

.check_char:
    lodsb
    cmp al, '?'
    je .is_help
    cmp al, 'H'
    je .is_help
    cmp al, 'h'
    je .is_help
    cmp al, 'R'
    je .is_reset
    cmp al, 'r'
    je .is_reset
    cmp al, 'U'
    je .skip_token              ; /U handled separately
    cmp al, 'u'
    je .skip_token
    cmp al, 'b'
    je .skip_bg_switch
    cmp al, 'B'
    je .skip_bg_switch
    cmp al, 'c'
    je .skip_c_switch
    cmp al, 'C'
    je .skip_c_switch
    cmp al, 'd'
    je .parse_dim_switch
    cmp al, 'D'
    je .parse_dim_switch
    cmp al, 'v'
    je .parse_vivid_switch
    cmp al, 'V'
    je .parse_vivid_switch
    cmp al, 'p'
    je .is_pop
    cmp al, 'P'
    je .is_pop
    cmp al, '1'
    je .is_preset1
    cmp al, '2'
    je .is_preset2
    cmp al, '3'
    je .is_preset3
    cmp al, '4'
    je .is_preset4
    cmp al, '5'
    je .is_preset5
    cmp al, '6'
    je .is_preset6
    cmp al, '7'
    je .is_preset7
    cmp al, '8'
    je .is_preset8
    cmp al, '9'
    je .is_preset9
    cmp al, '0'
    je .is_preset0
    jmp .bad_switch

.skip_token:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch
    jmp .skip_token

.skip_bg_switch:
.skip_c_switch:
    lodsb
    cmp al, ':'
    jne .bad_switch
.skip_switch_arg:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch
    jmp .skip_switch_arg

.parse_dim_switch:
    lodsb
    cmp al, ':'
    jne .bad_switch
    lodsb
    cmp al, '+'
    je .dim_plus
    cmp al, '-'
    je .dim_minus
    jmp .bad_switch
.dim_plus:
    mov byte [brightness_adj_cmd], 1
    jmp .after_modifier
.dim_minus:
    mov byte [brightness_adj_cmd], 2
    jmp .after_modifier

.parse_vivid_switch:
    lodsb
    cmp al, ':'
    jne .bad_switch
    lodsb
    cmp al, '+'
    je .vivid_plus
    cmp al, '-'
    je .vivid_minus
    jmp .bad_switch
.vivid_plus:
    mov byte [vivid_adj_cmd], 1
    jmp .after_modifier
.vivid_minus:
    mov byte [vivid_adj_cmd], 2
    jmp .after_modifier

.is_pop:
    mov byte [pop_flag_cmd], 1

.after_modifier:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch
    dec si
    jmp .skip_spaces

.is_help:     mov byte [switch_result], 1
    jmp .sw_done
.is_reset:    mov byte [switch_result], 2
    jmp .sw_done
.is_preset1:  mov byte [switch_result], 3
    jmp .after_modifier
.is_preset2:  mov byte [switch_result], 4
    jmp .after_modifier
.is_preset3:  mov byte [switch_result], 5
    jmp .after_modifier
.is_preset4:  mov byte [switch_result], 6
    jmp .after_modifier
.is_preset5:  mov byte [switch_result], 7
    jmp .after_modifier
.is_preset6:  mov byte [switch_result], 8
    jmp .after_modifier
.is_preset7:  mov byte [switch_result], 9
    jmp .after_modifier
.is_preset8:  mov byte [switch_result], 10
    jmp .after_modifier
.is_preset9:  mov byte [switch_result], 11
    jmp .after_modifier
.is_preset0:  mov byte [switch_result], 12
    jmp .after_modifier

.bad_switch:
    mov dx, msg_bad_switch
    call print_string
    mov byte [parse_error], 1
    xor al, al
    jmp .sw_done

.no_switch:
.sw_done:
    mov al, [switch_result]
    pop si
    ret

; ============================================================================
; parse_bg_color — Scan for /b:colorname, set bg_specified + bg_color
; ============================================================================
parse_bg_color:
    push si
    push di
    push cx
    push bx

    mov byte [bg_specified], 0
    xor ch, ch
    mov cl, [0x80]
    or cx, cx
    jz .pb_done
    mov si, 0x81

.pb_scan:
    cmp cx, 0
    je .pb_done
    lodsb
    dec cx
    cmp al, '/'
    je .pb_check_b
    cmp al, '-'
    je .pb_check_b
    jmp .pb_scan

.pb_check_b:
    cmp cx, 2
    jb .pb_done
    lodsb
    dec cx
    or al, 0x20
    cmp al, 'b'
    jne .pb_scan
    lodsb
    dec cx
    cmp al, ':'
    jne .pb_scan

    mov bx, bg_color_names

.pb_try_entry:
    cmp byte [bx], 0
    je .pb_not_found
    push si
    push cx

.pb_match_char:
    cmp byte [bx], 0
    je .pb_check_end
    cmp cx, 0
    je .pb_no_match_pop
    lodsb
    dec cx
    or al, 0x20
    cmp al, [bx]
    jne .pb_no_match_pop
    inc bx
    jmp .pb_match_char

.pb_check_end:
    cmp cx, 0
    je .pb_found
    mov al, [si]
    cmp al, ' '
    je .pb_found
    cmp al, 0x0D
    je .pb_found

.pb_no_match_pop:
    pop cx
    pop si
.pb_skip_name:
    cmp byte [bx], 0
    je .pb_skip_rgb
    inc bx
    jmp .pb_skip_name
.pb_skip_rgb:
    inc bx
    add bx, 3
    jmp .pb_try_entry

.pb_found:
    pop cx
    pop cx
    inc bx
    mov al, [bx]
    mov [bg_color], al
    mov al, [bx+1]
    mov [bg_color+1], al
    mov al, [bx+2]
    mov [bg_color+2], al
    mov byte [bg_specified], 1
    jmp .pb_done

.pb_not_found:
    mov dx, msg_bad_bg
    call print_string
    mov byte [parse_error], 1

.pb_done:
    pop bx
    pop cx
    pop di
    pop si
    ret

; ============================================================================
; parse_fg_colors — Scan for /c:name1,name2,name3
; ============================================================================
parse_fg_colors:
    push si
    push di
    push cx
    push bx

    mov byte [fg_specified], 0
    xor ch, ch
    mov cl, [0x80]
    or cx, cx
    jz .pf_done
    mov si, 0x81

.pf_scan:
    cmp cx, 0
    je .pf_done
    lodsb
    dec cx
    cmp al, '/'
    je .pf_check_c
    cmp al, '-'
    je .pf_check_c
    jmp .pf_scan

.pf_check_c:
    cmp cx, 2
    jb .pf_done
    lodsb
    dec cx
    or al, 0x20
    cmp al, 'c'
    jne .pf_scan
    lodsb
    dec cx
    cmp al, ':'
    jne .pf_scan

    mov di, fg_colors
    mov byte [fg_count], 0

.pf_next_color:
    call .pf_lookup_color
    jc .pf_error
    add di, 3
    inc byte [fg_count]
    cmp byte [fg_count], 3
    je .pf_all_found
    cmp cx, 0
    je .pf_error
    lodsb
    dec cx
    cmp al, ','
    jne .pf_error
    jmp .pf_next_color

.pf_all_found:
    mov byte [fg_specified], 1
    jmp .pf_done

.pf_error:
    mov dx, msg_bad_fg
    call print_string
    mov byte [parse_error], 1

.pf_done:
    pop bx
    pop cx
    pop di
    pop si
    ret

; --- Internal: look up one color name at SI, write RGB to [DI] ---
.pf_lookup_color:
    mov bx, bg_color_names

.pf_try_entry:
    cmp byte [bx], 0
    je .pf_not_found
    push si
    push cx

.pf_match_char:
    cmp byte [bx], 0
    je .pf_check_delim
    cmp cx, 0
    je .pf_no_match_pop
    lodsb
    dec cx
    or al, 0x20
    cmp al, [bx]
    jne .pf_no_match_pop
    inc bx
    jmp .pf_match_char

.pf_check_delim:
    cmp cx, 0
    je .pf_color_found
    mov al, [si]
    cmp al, ','
    je .pf_color_found
    cmp al, ' '
    je .pf_color_found
    cmp al, 0x0D
    je .pf_color_found

.pf_no_match_pop:
    pop cx
    pop si
.pf_skip_entry:
    cmp byte [bx], 0
    je .pf_skip_entry_rgb
    inc bx
    jmp .pf_skip_entry
.pf_skip_entry_rgb:
    inc bx
    add bx, 3
    jmp .pf_try_entry

.pf_color_found:
    pop cx
    pop cx
    inc bx
    mov al, [bx]
    mov [di], al
    mov al, [bx+1]
    mov [di+1], al
    mov al, [bx+2]
    mov [di+2], al
    clc
    ret

.pf_not_found:
    stc
    ret

; ============================================================================
; apply_bg_override — Override config_buffer[0..2] if /b:color was given
; ============================================================================
apply_bg_override:
    cmp byte [bg_specified], 0
    je .abg_done
    mov al, [bg_color]
    mov [config_buffer], al
    mov al, [bg_color+1]
    mov [config_buffer+1], al
    mov al, [bg_color+2]
    mov [config_buffer+2], al
.abg_done:
    ret

; ============================================================================
; apply_fg_override — Override config_buffer[3..11] if /c:name,name,name
; ============================================================================
apply_fg_override:
    cmp byte [fg_specified], 0
    je .afg_done
    mov si, fg_colors
    mov di, config_buffer + 3
    mov cx, 9
    cld
    rep movsb
.afg_done:
    ret

; ============================================================================
; apply_adjustments — Apply /V, /P, /D from command line to config_buffer
; ============================================================================
apply_adjustments:
    push ax

    ; Vivid
    cmp byte [vivid_adj_cmd], 0
    je .adj_check_pop
    cmp byte [vivid_adj_cmd], 1
    je .adj_vivid_boost
    call inst_saturation_mute
    jmp .adj_check_pop
.adj_vivid_boost:
    call inst_saturation_boost

.adj_check_pop:
    ; Pop
    cmp byte [pop_flag_cmd], 0
    je .adj_check_bright
    call inst_saturation_boost
    call inst_contrast_boost

.adj_check_bright:
    ; Brightness
    cmp byte [brightness_adj_cmd], 0
    je .adj_done
    cmp byte [brightness_adj_cmd], 1
    je .adj_brighten
    call inst_dim
    jmp .adj_done
.adj_brighten:
    call inst_brighten

.adj_done:
    pop ax
    ret

; --- Installer adjustment routines (work on config_buffer, not palette_rgb) ---

inst_brighten:
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 9
.loop:
    mov al, [si]
    add al, 8
    cmp al, 63
    jbe .ok
    mov al, 63
.ok:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

inst_dim:
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 9
.loop:
    mov al, [si]
    sub al, 8
    jnc .ok
    xor al, al
.ok:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

inst_saturation_boost:
    push bx
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 3
.color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]
    mov bl, 3
    div bl
    mov bl, al
    push cx
    mov cx, 3
.ch:
    mov al, [si]
    sub al, bl
    sar al, 1
    add al, [si]
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

inst_saturation_mute:
    push bx
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 3
.color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]
    mov bl, 3
    div bl
    mov bl, al
    push cx
    mov cx, 3
.ch:
    mov al, [si]
    add al, bl
    shr al, 1
    mov [si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

inst_contrast_boost:
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 9
.loop:
    mov al, [si]
    sub al, 31
    sar al, 1
    add al, [si]
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; ============================================================================
; load_config — Load palette from file into config_buffer
; ============================================================================
load_config:
    push ax
    push bx
    push cx
    push dx

    call get_filename
    jc .use_default
    mov byte [explicit_file], 1
    jmp .open_file

.use_default:
    mov byte [explicit_file], 0
    mov dx, default_filename

.open_file:
    mov ax, 0x3D00
    int 0x21
    jc .file_error

    mov [file_handle], ax
    mov bx, ax
    mov ah, 0x3F
    mov cx, TEXT_BUF_SIZE
    mov dx, text_buffer
    int 0x21
    jc .close_error
    mov [bytes_read], ax
    mov ah, 0x3E
    mov bx, [file_handle]
    int 0x21
    mov ax, [bytes_read]
    or ax, ax
    jz .close_error
    call parse_text_palette
    jc .parse_error
    clc
    jmp .lc_done

.parse_error:
    mov dx, msg_parse_error
    call print_string
    stc
    jmp .lc_done

.close_error:
    mov ah, 0x3E
    mov bx, [file_handle]
    int 0x21

.file_error:
    cmp byte [explicit_file], 0
    je .silent_fail
    mov dx, msg_file_error
    call print_string
.silent_fail:
    stc

.lc_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_text_palette — Parse RGB text into config_buffer
; Parses up to 9 palettes (36 color lines). Sets [palettes_loaded] = 1..9.
; Returns: CF=0 success (at least 1 palette), CF=1 error
; ============================================================================
parse_text_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, text_buffer
    mov di, config_buffer
    mov cx, [bytes_read]
    xor bx, bx                 ; BL = total color lines parsed (0..36)

.next_line:
    cmp bl, MAX_PALETTES * 4   ; 36 color lines max
    jae .parse_done
    or cx, cx
    jz .check_count

.skip_ws:
    or cx, cx
    jz .check_count
    lodsb
    dec cx
    cmp al, ' '
    je .skip_ws
    cmp al, 9
    je .skip_ws
    cmp al, 13
    je .skip_ws
    cmp al, 10
    je .next_line
    cmp al, ';'
    je .skip_to_eol
    cmp al, '#'
    je .skip_to_eol

    dec si
    inc cx
    call parse_number
    jc .parse_fail
    mov [di], al
    call skip_separator
    jc .parse_fail
    call parse_number
    jc .parse_fail
    mov [di+1], al
    call skip_separator
    jc .parse_fail
    call parse_number
    jc .parse_fail
    mov [di+2], al
    add di, 3
    inc bl

.skip_to_eol:
    or cx, cx
    jz .check_count
    lodsb
    dec cx
    cmp al, 10
    jne .skip_to_eol
    jmp .next_line

.check_count:
    cmp bl, 4
    jb .parse_fail             ; need at least 1 full palette

.parse_done:
    ; Calculate number of complete palettes parsed
    mov al, bl
    xor ah, ah
    mov dl, 4
    div dl                      ; AL = palettes (BL / 4)
    mov [palettes_loaded], al
    clc
    jmp .parse_exit

.parse_fail:
    stc

.parse_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_number — Parse decimal 0-63 from SI/CX
; ============================================================================
parse_number:
    push bx
    push dx
    xor ax, ax
    xor bx, bx
.digit_loop:
    or cx, cx
    jz .check_digits
    mov dl, [si]
    cmp dl, '0'
    jb .check_digits
    cmp dl, '9'
    ja .check_digits
    push dx
    mov dx, 10
    mul dx
    pop dx
    sub dl, '0'
    xor dh, dh
    add ax, dx
    inc si
    dec cx
    inc bx
    jmp .digit_loop
.check_digits:
    or bx, bx
    jz .num_error
    cmp ax, 64
    jae .num_error
    clc
    jmp .num_done
.num_error:
    stc
.num_done:
    pop dx
    pop bx
    ret

; ============================================================================
; skip_separator
; ============================================================================
skip_separator:
    push ax
    or cx, cx
    jz .sep_error
.sep_loop:
    lodsb
    dec cx
    cmp al, ','
    je .sep_more
    cmp al, ' '
    je .sep_more
    cmp al, 9
    je .sep_more
    cmp al, 10
    je .sep_error
    cmp al, 13
    je .sep_error
    dec si
    inc cx
    clc
    jmp .sep_done
.sep_more:
    or cx, cx
    jz .sep_error
    jmp .sep_loop
.sep_error:
    stc
.sep_done:
    pop ax
    ret

; ============================================================================
; get_filename — Extract filename from command line (skip switches)
; ============================================================================
get_filename:
    push si
    push di
    mov si, 0x81
    mov di, filename_buffer

.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_filename
    cmp al, 0x0A
    je .no_filename
    cmp al, '/'
    je .skip_token
    cmp al, '-'
    je .skip_token
    jmp .copy_loop

.skip_token:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_filename
    cmp al, 0x0A
    je .no_filename
    jmp .skip_token

.copy_loop:
    cmp al, ' '
    je .end_filename
    cmp al, 0x0D
    je .end_filename
    cmp al, 0x0A
    je .end_filename
    stosb
    lodsb
    jmp .copy_loop

.end_filename:
    xor al, al
    stosb
    mov dx, filename_buffer
    clc
    jmp .gf_done

.no_filename:
    stc

.gf_done:
    pop di
    pop si
    ret

; ============================================================================
; validate_palette — Check all loaded bytes in config_buffer are 0-63
; Validates palettes_loaded × 12 bytes.
; ============================================================================
validate_palette:
    push ax
    push cx
    push si
    mov al, [palettes_loaded]
    xor ah, ah
    mov cl, 12
    mul cl                      ; AX = total bytes to check
    mov cx, ax
    mov si, config_buffer
.check_loop:
    lodsb
    cmp al, 64
    jae .invalid
    loop .check_loop
    clc
    jmp .vp_done
.invalid:
    mov dx, msg_invalid
    call print_string
    stc
.vp_done:
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; load_fallback_to_config — Copy fallback CGA palette to config_buffer
; ============================================================================
load_fallback_to_config:
    push si
    push di
    push cx
    mov si, res_preset_fallback
    mov di, config_buffer
    mov cx, CONFIG_SIZE / 2
    cld
    rep movsw
    mov byte [palettes_loaded], 1
    pop cx
    pop di
    pop si
    ret

; ============================================================================
; copy_file_palettes_to_presets — Copy palettes 2+ from config_buffer to
; resident presets. Palette 1 → res_preset_1, palette 2 → res_preset_2, etc.
; Only copies as many as palettes_loaded (up to 9).
; ============================================================================
copy_file_palettes_to_presets:
    push ax
    push cx
    push si
    push di

    mov al, [palettes_loaded]
    xor ah, ah
    or al, al
    jz .cpy_done

    ; Copy palette N from config_buffer + (N-1)*12 to res_preset_1 + (N-1)*12
    mov si, config_buffer       ; palette 1 starts at offset 0
    mov di, res_preset_1
    mov cl, 6
    mul cl                      ; AX = palettes_loaded × 6
    mov cx, ax
    cld
    rep movsw

.cpy_done:
    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; print_colors — Print loaded palette with color blocks
; ============================================================================
print_colors:
    push ax
    push bx
    push cx
    push si

    mov dx, msg_colors
    call print_string
    mov si, config_buffer
    mov cl, 0

.color_loop:
    mov dx, msg_color_prefix
    call print_string
    mov al, cl
    add al, '0'
    call print_char
    mov dx, msg_color_sep
    call print_string

    lodsb
    call print_number
    mov al, ','
    call print_char
    lodsb
    call print_number
    mov al, ','
    call print_char
    lodsb
    call print_number

    mov al, ' '
    call print_char
    mov al, cl
    call print_color_block

    mov dx, msg_crlf
    call print_string
    inc cl
    cmp cl, 4
    jb .color_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_color_block — 4 solid blocks in specified color attribute
; ============================================================================
print_color_block:
    push ax
    push bx
    push cx
    mov bl, al
    or al, al
    jz .have_attr
    shl bl, 1
    add bl, 9
.have_attr:
    mov bh, 0
    mov al, 219
    mov cx, 4
    mov ah, 0x09
    int 0x10
    mov ah, 0x03
    mov bh, 0
    int 0x10
    add dl, 4
    mov ah, 0x02
    int 0x10
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_number — Print AL as decimal (0-99)
; ============================================================================
print_number:
    push ax
    push bx
    push dx
    xor ah, ah
    mov bl, 10
    div bl
    or al, al
    jz .ones
    add al, '0'
    call print_char
.ones:
    mov al, ah
    add al, '0'
    call print_char
    pop dx
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
; Data Section (transient — discarded after TSR)
; ============================================================================

msg_banner:
    db 'PalSwapT v3.5 - CGA Palette TSR with Live Hotkeys', 13, 10
    db 'By Retro Erik - 2026 - Hooks INT 09h + INT 10h', 13, 10
    db 'Type: PALSWAPT /? for help', 13, 10, '$'

msg_detected_ega:
    db 'Adapter: EGA detected. Using Attribute Controller.', 13, 10, '$'
msg_detected_vga:
    db 'Adapter: VGA detected. Using DAC registers (full RGB).', 13, 10, '$'
msg_no_adapter:
    db 'Error: No EGA or VGA adapter detected.', 13, 10, '$'

msg_help:
    db 13, 10
    db 'Usage: PALSWAPT [file.txt] [/1..9] [/c:c1,c2,c3] [/b:color]', 13, 10
    db '                [/P] [/V:+|-] [/D:+|-] [/R] [/U] [/?]', 13, 10
    db 13, 10
    db '  Installs as TSR. Hooks INT 10h (survives game mode resets)', 13, 10
    db '  and INT 09h (live palette hotkeys via Ctrl+Alt).', 13, 10
    db 13, 10
    db '  file.txt       Load palette file (1-9 palettes, 4 lines each)', 13, 10
    db '  /c:c1,c2,c3    Set colors 1-3 by name (see list below)', 13, 10
    db '  /b:color        Set background color by name', 13, 10
    db '  /P              Pop - boost saturation + contrast', 13, 10
    db '  /V:+  /V:-      Increase / decrease saturation', 13, 10
    db '  /D:+  /D:-      Brighten / dim colors', 13, 10
    db '  /R              Install with default CGA palette', 13, 10
    db '  /U              Uninstall TSR from memory', 13, 10
    db '  /?              Show this help', 13, 10
    db '$'

msg_pause:
    db 13, 10, '--- Press any key for more ---', '$'

msg_help2:
    db 13, 10
    db 'Built-in presets:', 13, 10
    db '  /1  Arcade Vibrant   /2  Sierra Natural   /3  C64-inspired', 13, 10
    db '  /4  CGA Red/Green    /5  CGA Red/Blue     /6  Amstrad CPC', 13, 10
    db '  /7  Pastel   /8  Mono Amber   /9  Mono Green   /0  Mono Gray', 13, 10
    db 13, 10
    db 'Live hotkeys (hold Ctrl+Alt and press):', 13, 10
    db '  0..9       Switch preset instantly', 13, 10
    db '  P          Toggle Pop (saturation + contrast)', 13, 10
    db '  R          Reset to default CGA palette', 13, 10
    db '  Up/Down    Brighten / Dim', 13, 10
    db '  Left/Right Less / More vivid (saturation)', 13, 10
    db '  Space    Random from CGA 16 colors', 13, 10
    db '  C        Random from C64 palette', 13, 10
    db '  A        Random from Amstrad CPC palette', 13, 10
    db '  Z        Random from ZX Spectrum palette', 13, 10
    db '  Release Ctrl+Alt = normal keyboard', 13, 10
    db 13, 10
    db 'Color names for /c: and /b:', 13, 10
    db '  black, blue, green, cyan, red, magenta, brown, lightgray,', 13, 10
    db '  darkgray, lightblue, lightgreen, lightcyan, lightred,', 13, 10
    db '  lightmagenta, yellow, white', 13, 10
    db 13, 10
    db 'Text file: R,G,B per line (0-63). Up to 9 palettes (4 lines', 13, 10
    db 'each). Multi-palette files overwrite presets 1-9.', 13, 10
    db '$'

msg_preset1:     db 'Preset: Arcade Vibrant', 13, 10, '$'
msg_preset2:     db 'Preset: Sierra Natural', 13, 10, '$'
msg_preset3:     db 'Preset: C64-inspired', 13, 10, '$'
msg_preset4:     db 'Preset: CGA Red/Green/White', 13, 10, '$'
msg_preset5:     db 'Preset: CGA Red/Blue/White', 13, 10, '$'
msg_preset6:     db 'Preset: Amstrad CPC', 13, 10, '$'
msg_preset7:     db 'Preset: Pastel', 13, 10, '$'
msg_preset8:     db 'Preset: Monochrome Amber', 13, 10, '$'
msg_preset9:     db 'Preset: Monochrome Green', 13, 10, '$'
msg_preset0:     db 'Preset: Monochrome Gray', 13, 10, '$'
msg_resetting:   db 'Using default CGA palette.', 13, 10, '$'
msg_multi_loaded:
    db 'Multi-palette file: presets 1-9 overwritten.', 13, 10, '$'
msg_installed:
    db 'TSR installed. INT 09h + INT 10h hooked.', 13, 10
    db 'Ctrl+Alt + key = hotkeys (0-9/P/R/arrows/Space/C/A/Z).', 13, 10
    db 'Run your CGA game now. Use PALSWAPT /U to uninstall.', 13, 10, '$'
msg_already_loaded:
    db 'PalSwapT already resident - palette updated.', 13, 10, '$'
msg_unloaded:
    db 'PalSwapT uninstalled. INT 09h + INT 10h restored.', 13, 10, '$'
msg_unload_error:
    db 'Error: PalSwapT not found in interrupt chain.', 13, 10, '$'
msg_colors:      db 'Colors (R,G,B):', 13, 10, '$'
msg_color_prefix:db '  Color $'
msg_color_sep:   db ': $'
msg_crlf:        db 13, 10, '$'
msg_fallback:    db 'Warning: palette load failed, using default.', 13, 10, '$'
msg_file_error:  db 'Warning: Cannot open palette file.', 13, 10, '$'
msg_parse_error: db 'Warning: Cannot parse palette file.', 13, 10, '$'
msg_invalid:     db 'Warning: Value out of range (must be 0-63).', 13, 10, '$'
msg_bad_bg:      db 'Warning: Unknown background color name. Use /? for list.', 13, 10, '$'
msg_bad_fg:      db 'Warning: Bad /c: colors. Use /c:name,name,name (see /?).', 13, 10, '$'
msg_bad_switch:  db 'Error: Unknown switch. Use /? for help.', 13, 10, '$'

default_filename: db 'PALSWAPT.TXT', 0

; ============================================================================
; Color name table (shared by /b: and /c: parsers)
; ============================================================================
bg_color_names:
    db 'black', 0,          0,  0,  0
    db 'blue', 0,           0,  0, 42
    db 'green', 0,          0, 42,  0
    db 'cyan', 0,           0, 42, 42
    db 'red', 0,           42,  0,  0
    db 'magenta', 0,       42,  0, 42
    db 'brown', 0,         42, 21,  0
    db 'lightgray', 0,     42, 42, 42
    db 'darkgray', 0,      21, 21, 21
    db 'lightblue', 0,     21, 21, 63
    db 'lightgreen', 0,    21, 63, 21
    db 'lightcyan', 0,     21, 63, 63
    db 'lightred', 0,      63, 21, 21
    db 'lightmagenta', 0,  63, 21, 63
    db 'yellow', 0,        63, 63, 21
    db 'white', 0,         63, 63, 63
    db 0                    ; end of table

; ============================================================================
; Installer variables (transient)
; ============================================================================
explicit_file:      db 0
parse_error:        db 0
brightness_adj_cmd: db 0        ; 0=none, 1=brighten, 2=dim
vivid_adj_cmd:      db 0        ; 0=none, 1=boost, 2=mute
pop_flag_cmd:       db 0        ; 1=apply pop from command line
switch_result:      db 0
is_default_install: db 0
palettes_loaded:    db 1            ; number of palettes parsed from file (1-9)
bg_specified:       db 0
bg_color:           db 0, 0, 0
fg_specified:       db 0
fg_count:           db 0
fg_colors:          times 9 db 0
file_handle:        dw 0
bytes_read:         dw 0

filename_buffer:    times 128 db 0
config_buffer:      times MULTI_CONFIG_SIZE db 0
text_buffer:        times TEXT_BUF_SIZE db 0

; ============================================================================
; End of PalSwapT.ASM
; ============================================================================
