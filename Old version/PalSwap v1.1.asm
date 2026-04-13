; ============================================================================
; PalSwap.ASM - CGA Palette Override Utility for EGA and VGA cards
; Written for NASM - 8086 compatible (runs on any DOS PC)
; By Retro Erik - 2026 using VS Code with GitHub Copilot
; Idea is from PC1PAL.ASM (Olivetti PC1 / Yamaha V6355D version)
; Version 1.1
; ============================================================================
; Sets custom RGB palette entries before running a CGA game on an EGA or VGA
; card.
;   VGA: Palette persists through mode sets thanks to INT 10h AX=1201h BL=31h
;        which disables BIOS palette reload on mode change.
;   EGA: Palette persists only until the next mode set (no disable mechanism).
;
; EGA vs VGA — what changes:
;   EGA:  16 palette registers selecting from 64 fixed colors.  We remap the
;         16 Attribute Controller registers so the CGA pixel values 0-3 point
;         to our nearest-match colors among the 64 EGA colors.
;         Each 6-bit EGA color has 3 levels per channel: off, half, full.
;         (Bits: rR rG rB R G B — lowercase=half intensity, uppercase=full)
;   VGA:  Full 256-entry DAC with 6-bit-per-channel free RGB.
;         We write R,G,B (0-63) directly to DAC entries for all CGA slots.
;
; On startup the program auto-detects EGA or VGA and chooses the right path.
; If neither is present it prints an error and exits.
;
; In CGA 320x200 4-color mode, pixel values 0-3 map to DAC/palette entries:
;   Palette 1, High Intensity (most common): 0, 11, 13, 15
;   Palette 1, Low Intensity:                0,  3,  5,  7
;   Palette 0, High Intensity:               0, 10, 12, 14
;   Palette 0, Low Intensity:                0,  2,  4,  6
; We write user colors to ALL these positions (both palettes, both intensities)
; so the palette works regardless of which CGA mode the game sets.
;
; Usage: PalSwap [palette.txt] [/1..5] [/c:c1,c2,c3] [/b:color] [/P] [/V:+|-] [/D:+|-] [/R] [/?]
;
; Switches:
;   /1          Preset: Arcade Vibrant (action games)
;   /2          Preset: Sierra Natural (adventure games)
;   /3          Preset: C64-inspired (retro warm feel)
;   /4          Preset: CGA Red/Green/White
;   /5          Preset: CGA Red/Blue/White
;   /c:c1,c2,c3 Set colors 1,2,3 by name (e.g. /c:blue,red,white)
;   /b:color    Set background to any of the 16 CGA colors (e.g. /b:yellow)
;   /P          Pop - boost saturation and contrast for more vivid colors
;   /V:+        Increase color saturation (more vivid)
;   /V:-        Decrease color saturation (more muted/gray)
;   /D:+        Brighten all colors
;   /D:-        Dim all colors
;   /R          Reset to standard EGA/VGA CGA palette
;   /?          Show help
;
; If no file or switch specified, uses PALSWAP.TXT in current directory.
; If file missing/invalid, falls back to standard CGA palette 1:
;   Color 0: Black, Color 1: Cyan, Color 2: Magenta, Color 3: White
;
; Text file format (identical to PC1PAL.TXT):
;   One RGB triple per line: "R,G,B" or "R G B" (values 0-63)
;   Lines starting with ; or # are comments
;   Blank lines are ignored
;   Example:
;     ; My custom palette
;     0,0,0       ; Black
;     0,42,63     ; Sky Blue
;     63,21,0     ; Orange
;     63,63,63    ; White
;
; EGA note: 6-bit values (0-63) are converted to the nearest EGA color.
;   EGA has 3 intensity levels per channel: off (<16), half (16-31), full (>=32).
;   This gives 3^3 = 27 distinct colors out of the 64 possible 6-bit values.
;
; VGA note: 6-bit values (0-63) are written directly to the DAC — full range!
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 8086

; ============================================================================
; Constants
; ============================================================================

; --- VGA DAC Ports ---
VGA_DAC_WRITE_IDX   equ 0x3C8   ; Write index port
VGA_DAC_DATA        equ 0x3C9   ; RGB data port (R, then G, then B)

; --- EGA Attribute Controller Ports ---
ATC_ADDR_DATA       equ 0x3C0   ; Write address or data (toggle)
ATC_READ            equ 0x3C1   ; Read data
INPUT_STATUS_1      equ 0x3DA   ; Reading this resets the ATC flip-flop to ADDR

; --- BIOS display type codes (returned by INT 10h AX=1A00h) ---
DISPLAY_EGA_COLOR   equ 0x04    ; EGA with color display
DISPLAY_EGA_MONO    equ 0x05    ; EGA with mono display
DISPLAY_VGA_ANALOG_COLOR equ 0x08 ; VGA analog color
DISPLAY_VGA_ANALOG_MONO  equ 0x07 ; VGA analog mono

; --- File and Buffer Sizes ---
CONFIG_SIZE     equ 12          ; 4 colors × 3 bytes (RGB) = 12 bytes
PALETTE_ENTRIES equ 4
FULL_PALETTE    equ 16          ; 16 color entries
TEXT_BUF_SIZE   equ 512

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Display banner
    mov dx, msg_banner
    call print_string

    ; Detect EGA / VGA
    call detect_video
    ; video_type: 0=none/CGA, 1=EGA, 2=VGA
    cmp byte [video_type], 0
    je .no_adapter

    ; Check command line switches
    call check_switches
    push ax
    call parse_bg_color
    call parse_fg_colors
    pop ax
    cmp byte [parse_error], 0
    jne .exit
    cmp al, 1
    je .show_help
    cmp al, 2
    je .do_reset
    cmp al, 3
    je .preset_1
    cmp al, 4
    je .preset_2
    cmp al, 5
    je .preset_3
    cmp al, 6
    je .preset_4
    cmp al, 7
    je .preset_5

    jmp .load_palette

.no_adapter:
    mov dx, msg_no_adapter
    call print_string
    jmp .exit

.show_help:
    mov dx, msg_help
    call print_string
    ; Pause between pages — flush keyboard buffer first
    mov dx, msg_pause
    call print_string
.flush_kb:
    mov ah, 0x01            ; INT 16h AH=01 - check if key in buffer
    int 0x16
    jz .wait_key            ; ZF=1 means buffer empty
    mov ah, 0x00            ; consume the buffered keystroke
    int 0x16
    jmp .flush_kb
.wait_key:
    mov ah, 0x00            ; INT 16h AH=00 - wait for keypress
    int 0x16
    mov dx, msg_help2
    call print_string
    jmp .exit

.do_reset:
    mov dx, msg_resetting
    call print_string
    ; Re-enable default palette loading on mode set (undo our disable)
    cmp byte [video_type], 2
    jne .skip_reenable
    mov ax, 0x1200              ; AL=00 = enable
    mov bl, 0x31
    int 0x10
.skip_reenable:
    ; Force a mode re-set so the BIOS reloads the default DAC palette.
    ; Get current video mode, then set it again.
    mov ah, 0x0F                ; Get current video mode
    int 0x10                    ; AL = mode number
    xor ah, ah                  ; AH=0 = set video mode
    int 0x10                    ; Triggers full palette reload
    mov dx, msg_reset_done
    call print_string
    jmp .exit

.preset_1:
    mov dx, msg_preset1
    call print_string
    mov si, preset_arcade
    jmp .apply_preset

.preset_2:
    mov dx, msg_preset2
    call print_string
    mov si, preset_sierra
    jmp .apply_preset

.preset_3:
    mov dx, msg_preset3
    call print_string
    mov si, preset_c64
    jmp .apply_preset

.preset_4:
    mov dx, msg_preset4
    call print_string
    mov si, preset_cga_text
    jmp .apply_preset

.preset_5:
    mov dx, msg_preset5
    call print_string
    mov si, preset_cga_palette
    jmp .apply_preset

.apply_preset:
    ; Copy 12 bytes from preset to config_buffer
    mov di, config_buffer
    mov cx, 12
    cld
    rep movsb
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    call write_palette
    call print_colors
    mov dx, msg_success
    call print_string
    jmp .exit

.load_palette:
    call load_config
    jc .use_fallback

    call validate_palette
    jc .use_fallback

    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    call write_palette
    call print_colors
    mov dx, msg_success
    call print_string
    jmp .exit

.use_fallback:
    ; Only show fallback message if no /c: or /b: switch is doing the work
    cmp byte [explicit_file], 1
    jne .skip_fallback_msg
    mov dx, msg_fallback
    call print_string
.skip_fallback_msg:
    call load_fallback_palette
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    call write_palette
    call print_colors
    mov dx, msg_success
    call print_string

.exit:
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; detect_video - Detect EGA or VGA presence
; Output: [video_type] = 0 (none/CGA), 1 (EGA), 2 (VGA)
;         prints a line identifying the adapter
; ============================================================================
detect_video:
    push ax
    push bx
    push cx

    ; Try VGA first (INT 10h AX=1A00h — Get Display Combination Code)
    ; This is a VGA BIOS extension; returns BL=active display type
    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A                ; VGA BIOS returns 0x1A in AL if supported
    jne .try_ega

    ; BL has the active display type
    cmp bl, DISPLAY_VGA_ANALOG_COLOR
    je .is_vga
    cmp bl, DISPLAY_VGA_ANALOG_MONO
    je .is_vga
    ; Some VGA BIOSes return EGA codes even on VGA; if INT 1A was supported
    ; at all we can trust it and fall through to EGA check below

.try_ega:
    ; INT 10h AH=12h BL=10h — EGA/VGA Alternate Select (EGA info)
    mov ax, 0x1200
    mov bl, 0x10
    int 0x10
    ; If EGA/VGA BIOS is present, BH returns 0 (color) or 1 (mono)
    ; and BL is NO LONGER 0x10 (it gets overwritten with memory info)
    cmp bl, 0x10
    je .not_supported           ; BL unchanged → not EGA/VGA

    ; Distinguish EGA from VGA by checking INT 10h 1A00h again
    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A
    je .check_vga_again

    ; EGA confirmed
.is_ega:
    mov byte [video_type], 1
    mov dx, msg_detected_ega
    call print_string
    jmp .done

.check_vga_again:
    cmp bl, DISPLAY_VGA_ANALOG_COLOR
    je .is_vga
    cmp bl, DISPLAY_VGA_ANALOG_MONO
    je .is_vga
    ; VGA BIOS present but reporting EGA display — treat as VGA
    jmp .is_vga

.is_vga:
    mov byte [video_type], 2
    mov dx, msg_detected_vga
    call print_string
    jmp .done

.not_supported:
    mov byte [video_type], 0

.done:
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; write_palette - Dispatch to VGA or EGA palette writer
; Input:  config_buffer (4 × RGB, 0-63)
; ============================================================================
write_palette:
    cmp byte [video_type], 2
    je write_palette_vga
    jmp write_palette_ega

; ============================================================================
; write_palette_vga - Write 4 user colors to VGA DAC + program ATC
;
; In CGA mode 4 (320x200 4-color), the 2-bit pixel value (0-3) directly
; selects ATC register [0], [1], [2], or [3].  The ATC register value
; is used as the DAC index.  That's the ONLY hardware path.
;
; When a game calls INT 10h AH=0Bh to select a CGA palette, the BIOS
; reprograms ATC[1-3] to point to the standard CGA DAC entries:
;   Pal 1 high: ATC[1]=11, ATC[2]=13, ATC[3]=15
;   Pal 1 low:  ATC[1]=3,  ATC[2]=5,  ATC[3]=7
;   Pal 0 high: ATC[1]=10, ATC[2]=12, ATC[3]=14
;   Pal 0 low:  ATC[1]=2,  ATC[2]=4,  ATC[3]=6
;
; Games that DON'T call AH=0Bh keep whatever ATC was set before mode
; change (preserved by our 1201h/31h disable-palette-reload flag).
;
; PROBLEM: DAC entries 2 and 3 are needed by BOTH:
;   - Identity/text-mode ATC games (pixel 2→DAC 2=color 2, pixel 3→DAC 3=color 3)
;   - CGA palette 0/1 low (pixel 1→DAC 2 or 3 = color 1)
;   We can't put two different colors in the same DAC entry.
;
; SOLUTION: Use DAC entries 8 and 9 for our ATC pixel 2 and pixel 3.
;   These entries are NEVER used by any standard CGA palette routing.
;   Set ATC[0]=0, ATC[1]=1, ATC[2]=8, ATC[3]=9.
;   Then fill ALL 16 DAC entries for every CGA palette variant:
;
;   DAC 0  = color 0 (background, all modes)
;   DAC 1  = color 1 (our ATC pixel 1, never used by CGA palettes)
;   DAC 2  = color 1 (CGA pal 0 low, pixel 1)
;   DAC 3  = color 1 (CGA pal 1 low, pixel 1 — e.g. Zaxxon)
;   DAC 4  = color 2 (CGA pal 0 low, pixel 2)
;   DAC 5  = color 2 (CGA pal 1 low, pixel 2)
;   DAC 6  = color 3 (CGA pal 0 low, pixel 3)
;   DAC 7  = color 3 (CGA pal 1 low, pixel 3)
;   DAC 8  = color 2 (our ATC pixel 2, never used by CGA palettes)
;   DAC 9  = color 3 (our ATC pixel 3, never used by CGA palettes)
;   DAC 10 = color 1 (CGA pal 0 high, pixel 1)
;   DAC 11 = color 1 (CGA pal 1 high, pixel 1)
;   DAC 12 = color 2 (CGA pal 0 high, pixel 2)
;   DAC 13 = color 2 (CGA pal 1 high, pixel 2)
;   DAC 14 = color 3 (CGA pal 0 high, pixel 3)
;   DAC 15 = color 3 (CGA pal 1 high, pixel 3)
;
;   ZERO conflicts.  Every scenario gets the right color:
;   - Our ATC stays (game doesn't call AH=0Bh): pixel 1→1→c1, 2→8→c2, 3→9→c3
;   - Game sets pal 1 high: pixel 1→11→c1, 2→13→c2, 3→15→c3
;   - Game sets pal 1 low:  pixel 1→3→c1,  2→5→c2,  3→7→c3
;   - Game sets pal 0 high: pixel 1→10→c1, 2→12→c2, 3→14→c3
;   - Game sets pal 0 low:  pixel 1→2→c1,  2→4→c2,  3→6→c3
;
; Input:  config_buffer (4 × RGB, 0-63 each)
; ============================================================================
write_palette_vga:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; Disable default palette loading on mode set (preserves ATC + DAC)
    mov ax, 0x1201
    mov bl, 0x31
    int 0x10

    ; --- Step 1: Build 16-entry DAC table and write to hardware ---
    ; Use color_to_dac lookup: maps each DAC index to user color 0-3
    mov si, color_to_dac
    mov di, dac_table
    mov cx, 16
    cld
.build_dac:
    lodsb                       ; AL = user color index (0-3)
    ; Multiply by 3 for config_buffer offset
    mov bl, al
    shl bl, 1
    add bl, al                  ; BL = color_index * 3
    xor bh, bh
    mov al, [config_buffer + bx]
    stosb
    mov al, [config_buffer + bx + 1]
    stosb
    mov al, [config_buffer + bx + 2]
    stosb
    loop .build_dac

    ; Write all 16 DAC entries starting at index 0 (auto-increment)
    mov dx, VGA_DAC_WRITE_IDX
    xor al, al
    out dx, al
    mov si, dac_table
    mov cx, 48                  ; 16 entries × 3 bytes
    mov dx, VGA_DAC_DATA
.write_dac:
    lodsb
    out dx, al
    loop .write_dac

    ; --- Step 2: Program ATC[0-3] for conflict-free routing ---
    ; ATC[0]=0, ATC[1]=1, ATC[2]=8, ATC[3]=9
    ; ATC[4-15] = standard text mode values (unaffected by CGA mode 4)
    cli
    mov dx, INPUT_STATUS_1
    in al, dx                   ; Reset ATC flip-flop to ADDR state

    xor bx, bx
.write_atc:
    mov dx, ATC_ADDR_DATA
    mov al, bl                  ; Index (bit 5=0: palette locked)
    out dx, al
    jmp short $+2               ; I/O delay
    mov al, [vga_atc_init + bx]
    out dx, al
    jmp short $+2
    inc bx
    cmp bx, 16
    jb .write_atc

    ; Re-enable screen: write 0x20 (bit 5 = palette enable)
    mov al, 0x20
    out dx, al
    sti

    ; --- Step 3: Write colors to DAC entries used by text mode display ---
    ; In text mode, attributes 11/13/15 go through ATC[11]=0x3B, ATC[13]=0x3D,
    ; ATC[15]=0x3F, routing to DAC 59, 61, 63 (standard VGA text palette).
    ; Write our custom colors there so the color preview in DOS shows correctly.
    ; DAC entries 59/61/63 are far above the CGA range (0-15) — no conflict.
    mov dx, VGA_DAC_WRITE_IDX
    mov al, 59                  ; DAC 59 = text attr 11 (light cyan slot)
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [config_buffer+3]   ; color 1 R
    out dx, al
    mov al, [config_buffer+4]   ; color 1 G
    out dx, al
    mov al, [config_buffer+5]   ; color 1 B
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 61                  ; DAC 61 = text attr 13 (light magenta slot)
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [config_buffer+6]   ; color 2 R
    out dx, al
    mov al, [config_buffer+7]   ; color 2 G
    out dx, al
    mov al, [config_buffer+8]   ; color 2 B
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 63                  ; DAC 63 = text attr 15 (white slot)
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [config_buffer+9]   ; color 3 R
    out dx, al
    mov al, [config_buffer+10]  ; color 3 G
    out dx, al
    mov al, [config_buffer+11]  ; color 3 B
    out dx, al

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; write_palette_ega - Set EGA Attribute Controller palette registers
;
; EGA does NOT have a free RGB DAC — it has 16 Attribute Controller registers
; that each select one of 64 fixed EGA colors (6 binary bits: R,G,B,r,g,b).
; The 64 colors are combinations of: full-R, full-G, full-B (bright primaries)
; and half-R, half-G, half-B (dark primaries = "iRGB" bits).
;
; Mapping strategy:
;   We convert each user RGB (0-63) to the nearest EGA color by:
;   - R >= 32 → set bit R (full red,   bit 2)
;   - G >= 32 → set bit G (full green, bit 1)
;   - B >= 32 → set bit B (full blue,  bit 0)
;   - R >= 16 AND < 32 → set bit r (half red,   bit 5)  [iR]
;   - G >= 16 AND < 32 → set bit g (half green, bit 4)  [iG]
;   - B >= 16 AND < 32 → set bit b (half blue,  bit 3)  [iB]
;   This gives values 0-63 suitable for EGA ATC registers.
;   (In practice most game palettes use 0,63 values so the approximation is fine.)
;
; ATC register write protocol:
;   1. Read port 3DAh to reset ATC address/data flip-flop to ADDR state
;   2. Write attribute index (with bit 5 = 0 to lock palette) to 3C0h
;   3. Write data byte to 3C0h
;   4. Repeat steps 2-3 for each register
;   5. Write 0x20 to 3C0h to re-enable palette (bit 5 = 1)
;
; We update all 16 ATC registers just like with VGA, covering all CGA slots.
; ============================================================================
write_palette_ega:
    push ax
    push bx
    push cx
    push dx

    ; Convert user's 4 colors (0-63 RGB) to EGA 6-bit palette values
    call convert_rgb_to_ega     ; fills ega_colors[0..3]

    ; Build full 16-register ATC table from default CGA + user overrides
    ; Start with standard CGA defaults
    mov si, cga_ega_default
    mov di, atc_table
    mov cx, 16
    cld
    rep movsb

    ; Override the 13 CGA-active entries with user colors
    ; Entry 0 = background (user color 0)
    mov al, [ega_colors]
    mov [atc_table + 0], al

    ; Low-intensity palette 1: entries 3, 5, 7 = colors 1, 2, 3
    mov al, [ega_colors + 1]
    mov [atc_table + 3], al
    mov al, [ega_colors + 2]
    mov [atc_table + 5], al
    mov al, [ega_colors + 3]
    mov [atc_table + 7], al

    ; High-intensity palette 1: entries 11, 13, 15 = colors 1, 2, 3
    mov al, [ega_colors + 1]
    mov [atc_table + 11], al
    mov al, [ega_colors + 2]
    mov [atc_table + 13], al
    mov al, [ega_colors + 3]
    mov [atc_table + 15], al

    ; Low-intensity palette 0: entries 2, 4, 6 = colors 1, 2, 3
    mov al, [ega_colors + 1]
    mov [atc_table + 2], al
    mov al, [ega_colors + 2]
    mov [atc_table + 4], al
    mov al, [ega_colors + 3]
    mov [atc_table + 6], al

    ; High-intensity palette 0: entries 10, 12, 14 = colors 1, 2, 3
    mov al, [ega_colors + 1]
    mov [atc_table + 10], al
    mov al, [ega_colors + 2]
    mov [atc_table + 12], al
    mov al, [ega_colors + 3]
    mov [atc_table + 14], al

    ; Write all 16 ATC registers via port 3C0h
    ; Reset ATC flip-flop to ADDR state by reading INput Status Register 1
    cli
    mov dx, INPUT_STATUS_1
    in al, dx                   ; Resets ATC to ADDR state

    mov bx, 0                   ; BX = register index 0-15

.ega_write_loop:
    mov dx, ATC_ADDR_DATA
    mov al, bl                  ; Index (bit 5=0 = palette locked during write)
    out dx, al
    jmp short $+2               ; I/O delay
    mov al, [atc_table + bx]    ; Data
    out dx, al
    jmp short $+2
    inc bx
    cmp bx, 16
    jb .ega_write_loop

    ; Re-enable screen output: write 0x20 to ATC (bit 5 = palette enable)
    mov al, 0x20
    out dx, al
    sti

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; convert_rgb_to_ega - Convert 4 user RGB colors (0-63) to EGA 6-bit values
; Input:  config_buffer (12 bytes: 4 × R,G,B, values 0-63)
; Output: ega_colors[0..3] (4 bytes, EGA palette values 0-63)
;
; EGA 6-bit color bit layout:
;   Bit: 5=rR  4=rG  3=rB  2=R  1=G  0=B
;   (lowercase = half-intensity "iRGB" bits, uppercase = full-intensity)
;   Full intensity: R>=32, G>=32, B>=32
;   Half intensity: 16<=R<32, 16<=G<32, 16<=B<32
; ============================================================================
convert_rgb_to_ega:
    push ax
    push bx
    push cx
    push si
    push di

    mov si, config_buffer
    mov di, ega_colors
    mov cx, PALETTE_ENTRIES

.ega_convert_loop:
    xor bl, bl                  ; BL = EGA value being built

    ; --- Red channel ---
    lodsb                       ; AL = Red (0-63)
    cmp al, 32
    jb .red_half
    or bl, 0x04                 ; Set bit 2 (full Red)
    jmp .check_green
.red_half:
    cmp al, 16
    jb .check_green
    or bl, 0x20                 ; Set bit 5 (half Red = iR)

.check_green:
    ; --- Green channel ---
    lodsb                       ; AL = Green (0-63)
    cmp al, 32
    jb .green_half
    or bl, 0x02                 ; Set bit 1 (full Green)
    jmp .check_blue
.green_half:
    cmp al, 16
    jb .check_blue
    or bl, 0x10                 ; Set bit 4 (half Green = iG)

.check_blue:
    ; --- Blue channel ---
    lodsb                       ; AL = Blue (0-63)
    cmp al, 32
    jb .blue_half
    or bl, 0x01                 ; Set bit 0 (full Blue)
    jmp .store_ega
.blue_half:
    cmp al, 16
    jb .store_ega
    or bl, 0x08                 ; Set bit 3 (half Blue = iB)

.store_ega:
    mov [di], bl
    inc di
    loop .ega_convert_loop

    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; load_config - Load palette from file
; Output: CF clear = success, config_buffer filled
;         CF set   = error
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
    jmp .done

.parse_error:
    mov dx, msg_parse_error
    call print_string
    stc
    jmp .done

.close_error:
    mov ah, 0x3E
    mov bx, [file_handle]
    int 0x21

.file_error:
    cmp byte [explicit_file], 0
    je .silent_fail             ; don't warn when default file missing
    mov dx, msg_file_error
    call print_string
.silent_fail:
    stc

.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_text_palette - Parse text format palette file
; Input:  text_buffer, bytes_read
; Output: config_buffer (12 bytes), CF clear/set
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
    xor bx, bx                  ; BL = colors parsed

.next_line:
    cmp bl, 4
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
    jb .parse_fail

.parse_done:
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
; parse_number - Parse decimal number 0-63 from SI/CX
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
; get_filename
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

    ; Skip tokens that start with / or - (switches, not filenames)
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
; check_switches
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
    jmp .bad_switch

.skip_bg_switch:
.skip_c_switch:
    ; Skip /b:... or /c:... — handled by parse_bg_color / parse_fg_colors
    lodsb
    cmp al, ':'
    jne .bad_switch              ; no colon — unknown switch
.skip_switch_arg:
    lodsb
    cmp al, ' '
    je .skip_spaces             ; continue scanning for more switches
    cmp al, 0x0D
    je .no_switch               ; end of command line
    jmp .skip_switch_arg

.parse_dim_switch:
    ; Expect /D:+ or /D:-
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
    mov byte [brightness_adj], 1
    jmp .after_modifier
.dim_minus:
    mov byte [brightness_adj], 2
    jmp .after_modifier

.parse_vivid_switch:
    ; Expect /V:+ or /V:-
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
    mov byte [vivid_adj], 1
    jmp .after_modifier
.vivid_minus:
    mov byte [vivid_adj], 2
    jmp .after_modifier

.is_pop:
    mov byte [pop_flag], 1
    ; fall through to .after_modifier

.after_modifier:
    ; Check if more switches follow
    lodsb
    cmp al, ' '
    je .skip_spaces             ; continue scanning
    cmp al, 0x0D
    je .no_switch               ; end of command line
    ; Character right after modifier — could be part of next token
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
; parse_bg_color - Scan command line for /b:colorname
; Sets [bg_specified] = 1 and [bg_color] = R,G,B if found
; ============================================================================
parse_bg_color:
    push si
    push di
    push cx
    push bx

    mov byte [bg_specified], 0
    xor ch, ch
    mov cl, [0x80]              ; command line length
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
    jb .pb_done                 ; need at least 'b' and ':'
    lodsb
    dec cx
    or al, 0x20                 ; to lowercase
    cmp al, 'b'
    jne .pb_scan
    lodsb
    dec cx
    cmp al, ':'
    jne .pb_scan

    ; SI now points to start of color name, CX = remaining chars
    ; Try to match against each entry in bg_color_names
    mov bx, bg_color_names

.pb_try_entry:
    cmp byte [bx], 0           ; end of table?
    je .pb_not_found
    ; Save SI and CX for retry
    push si
    push cx

.pb_match_char:
    cmp byte [bx], 0           ; end of name in table?
    je .pb_check_end
    cmp cx, 0
    je .pb_no_match_pop         ; input too short
    lodsb
    dec cx
    or al, 0x20                 ; to lowercase
    cmp al, [bx]
    jne .pb_no_match_pop
    inc bx
    jmp .pb_match_char

.pb_check_end:
    ; Table name ended. Check if user input also ended (space/CR/end)
    cmp cx, 0
    je .pb_found                ; end of command line = match
    mov al, [si]
    cmp al, ' '
    je .pb_found
    cmp al, 0x0D
    je .pb_found
    ; Not a delimiter — partial match, not a real match

.pb_no_match_pop:
    pop cx
    pop si
    ; Skip to end of this entry's name (find null)
.pb_skip_name:
    cmp byte [bx], 0
    je .pb_skip_rgb
    inc bx
    jmp .pb_skip_name
.pb_skip_rgb:
    inc bx                      ; skip null terminator
    add bx, 3                   ; skip RGB bytes
    jmp .pb_try_entry

.pb_found:
    pop cx                      ; discard saved CX
    pop cx                      ; discard saved SI
    ; BX points to the null terminator, RGB starts at BX+1
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
; apply_bg_override - Override color 0 (background) if /b:color was specified
; Input:  [bg_specified], [bg_color], config_buffer
; Output: config_buffer[0..2] overwritten with bg_color if bg_specified=1
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
; parse_fg_colors - Scan command line for /c:name1,name2,name3
; Sets [fg_specified] = 1 and [fg_colors] = 9 bytes (3 × R,G,B) if found
; ============================================================================
parse_fg_colors:
    push si
    push di
    push cx
    push bx

    mov byte [fg_specified], 0
    xor ch, ch
    mov cl, [0x80]              ; command line length
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
    jb .pf_done                 ; need at least 'c' and ':'
    lodsb
    dec cx
    or al, 0x20                 ; to lowercase
    cmp al, 'c'
    jne .pf_scan
    lodsb
    dec cx
    cmp al, ':'
    jne .pf_scan

    ; SI now points to first color name, CX = remaining chars
    ; Parse 3 comma-separated color names
    mov di, fg_colors           ; destination for RGB triples
    mov byte [fg_count], 0

.pf_next_color:
    ; Look up color name starting at SI
    call .pf_lookup_color
    jc .pf_error                ; lookup failed
    ; RGB was written to [DI], advance DI by 3
    add di, 3
    inc byte [fg_count]
    cmp byte [fg_count], 3
    je .pf_all_found
    ; Expect comma separator
    cmp cx, 0
    je .pf_error                ; input ended too early
    lodsb
    dec cx
    cmp al, ','
    jne .pf_error               ; not a comma
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
; Input:  SI = start of name in command line, CX = remaining chars
; Output: SI advanced past name, CX updated, [DI..DI+2] = RGB
;         CF clear on success, CF set on failure
.pf_lookup_color:
    mov bx, bg_color_names      ; reuse same color table

.pf_try_entry:
    cmp byte [bx], 0           ; end of table?
    je .pf_not_found
    push si
    push cx

.pf_match_char:
    cmp byte [bx], 0           ; end of name in table?
    je .pf_check_delim
    cmp cx, 0
    je .pf_no_match_pop
    lodsb
    dec cx
    or al, 0x20                 ; to lowercase
    cmp al, [bx]
    jne .pf_no_match_pop
    inc bx
    jmp .pf_match_char

.pf_check_delim:
    ; Name matched. Next char must be comma, space, CR, or end
    cmp cx, 0
    je .pf_color_found          ; end of input = OK
    mov al, [si]
    cmp al, ','
    je .pf_color_found
    cmp al, ' '
    je .pf_color_found
    cmp al, 0x0D
    je .pf_color_found
    ; Not a delimiter — partial match

.pf_no_match_pop:
    pop cx
    pop si
.pf_skip_entry:
    cmp byte [bx], 0
    je .pf_skip_entry_rgb
    inc bx
    jmp .pf_skip_entry
.pf_skip_entry_rgb:
    inc bx                      ; skip null
    add bx, 3                   ; skip RGB
    jmp .pf_try_entry

.pf_color_found:
    pop cx                      ; discard saved CX (use current)
    pop cx                      ; discard saved SI (use current)
    ; BX points to null terminator, RGB at BX+1
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
; apply_fg_override - Override colors 1-3 if /c:color,color,color was specified
; Input:  [fg_specified], [fg_colors], config_buffer
; Output: config_buffer[3..11] overwritten with fg_colors if fg_specified=1
; ============================================================================
apply_fg_override:
    cmp byte [fg_specified], 0
    je .afg_done
    mov si, fg_colors
    mov di, config_buffer + 3   ; color 1 starts at offset 3
    mov cx, 9                   ; 3 colors × 3 bytes
    cld
    rep movsb
.afg_done:
    ret

; ============================================================================
; validate_palette
; ============================================================================
validate_palette:
    push cx
    push si
    mov si, config_buffer
    mov cx, CONFIG_SIZE

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
    ret

; ============================================================================
; load_fallback_palette - Load standard CGA palette 1 (cyan/magenta/white)
; ============================================================================
load_fallback_palette:
    push si
    push di
    push cx
    mov si, fallback_palette
    mov di, config_buffer
    mov cx, CONFIG_SIZE
    cld
    rep movsb
    pop cx
    pop di
    pop si
    ret

; ============================================================================
; print_colors - Print the 4 loaded colors with color blocks
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

    ; Color block using text attribute
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
; print_color_block - Print 4 solid block chars in the specified color
; Input: AL = color index 0-3
; Maps: 0→attr 0, 1→attr 11, 2→attr 13, 3→attr 15
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
; print_number - Print AL as decimal (0-99)
; ============================================================================
print_number:
    push ax
    push bx
    push dx
    xor ah, ah
    mov bl, 10
    div bl
    or al, al
    jz .print_ones
    add al, '0'
    call print_char
.print_ones:
    mov al, ah
    add al, '0'
    call print_char
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; print_char - Print AL
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
; print_string - Print $-terminated string at DX
; ============================================================================
print_string:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; apply_adjustments - Apply /V, /P, /D post-processing to config_buffer
; Order: saturation (/V) first, then pop (/P), then brightness (/D)
; Modifies config_buffer in place (12 bytes = 4 colors × 3 RGB)
; ============================================================================
apply_adjustments:
    push ax

    ; Step 1: Vivid / saturation (/V:+ or /V:-)
    cmp byte [vivid_adj], 0
    je .adj_check_pop
    cmp byte [vivid_adj], 1
    je .adj_vivid_boost
    call adjust_saturation_mute
    jmp .adj_check_pop
.adj_vivid_boost:
    call adjust_saturation_boost

.adj_check_pop:
    ; Step 2: Pop (/P) = saturation boost + contrast boost
    cmp byte [pop_flag], 0
    je .adj_check_bright
    call adjust_saturation_boost
    call adjust_contrast_boost

.adj_check_bright:
    ; Step 3: Brightness (/D:+ or /D:-)
    cmp byte [brightness_adj], 0
    je .adj_done
    cmp byte [brightness_adj], 1
    je .adj_brighten
    call adjust_dim
    jmp .adj_done
.adj_brighten:
    call adjust_brighten

.adj_done:
    pop ax
    ret

; ============================================================================
; adjust_brighten - Add 8 to each RGB value in config_buffer, clamp at 63
; ============================================================================
adjust_brighten:
    push cx
    push si
    mov si, config_buffer + 3   ; skip color 0 (background)
    mov cx, 9                   ; 3 colors × 3 bytes
.bright_loop:
    mov al, [si]
    add al, 8
    cmp al, 63
    jbe .bright_ok
    mov al, 63
.bright_ok:
    mov [si], al
    inc si
    loop .bright_loop
    pop si
    pop cx
    ret

; ============================================================================
; adjust_dim - Subtract 8 from each RGB value in config_buffer, clamp at 0
; ============================================================================
adjust_dim:
    push cx
    push si
    mov si, config_buffer + 3   ; skip color 0 (background)
    mov cx, 9                   ; 3 colors × 3 bytes
.dim_loop:
    mov al, [si]
    sub al, 8
    jnc .dim_ok                 ; CF clear = no underflow
    xor al, al
.dim_ok:
    mov [si], al
    inc si
    loop .dim_loop
    pop si
    pop cx
    ret

; ============================================================================
; adjust_saturation_boost - Increase color saturation
; For each color triple: gray = (R+G+B)/3, new = ch + (ch - gray) / 2
; Clamp each channel to 0-63
; ============================================================================
adjust_saturation_boost:
    push bx
    push cx
    push si
    mov si, config_buffer + 3   ; skip color 0 (background)
    mov cx, 3                   ; 3 color triples
.sat_boost_color:
    ; Calculate gray = (R + G + B) / 3
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]             ; AL = R+G+B (max 189, fits in byte)
    mov bl, 3
    div bl                      ; AL = gray, AH = remainder
    mov bl, al                  ; BL = gray

    ; Adjust each of the 3 channels
    push cx
    mov cx, 3
.sat_boost_ch:
    mov al, [si]               ; AL = channel value
    sub al, bl                  ; AL = ch - gray (signed, -63..+63)
    sar al, 1                  ; AL = (ch - gray) / 2 (signed)
    add al, [si]               ; AL = ch + (ch - gray) / 2
    ; Clamp to 0-63
    test al, al
    jns .sat_boost_not_neg
    xor al, al                 ; clamp to 0
    jmp .sat_boost_store
.sat_boost_not_neg:
    cmp al, 63
    jbe .sat_boost_store
    mov al, 63                 ; clamp to 63
.sat_boost_store:
    mov [si], al
    inc si
    loop .sat_boost_ch
    pop cx
    loop .sat_boost_color
    pop si
    pop cx
    pop bx
    ret

; ============================================================================
; adjust_saturation_mute - Decrease color saturation (move toward gray)
; For each color triple: gray = (R+G+B)/3, new = (ch + gray) / 2
; ============================================================================
adjust_saturation_mute:
    push bx
    push cx
    push si
    mov si, config_buffer + 3   ; skip color 0 (background)
    mov cx, 3
.sat_mute_color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]
    mov bl, 3
    div bl
    mov bl, al                  ; BL = gray

    push cx
    mov cx, 3
.sat_mute_ch:
    mov al, [si]               ; AL = channel
    add al, bl                  ; AL = ch + gray
    shr al, 1                  ; AL = (ch + gray) / 2
    ; Result is always 0-63, no clamping needed
    mov [si], al
    inc si
    loop .sat_mute_ch
    pop cx
    loop .sat_mute_color
    pop si
    pop cx
    pop bx
    ret

; ============================================================================
; adjust_contrast_boost - Push values away from midpoint (31)
; new = ch + (ch - 31) / 2, clamp 0-63
; ============================================================================
adjust_contrast_boost:
    push cx
    push si
    mov si, config_buffer + 3   ; skip color 0 (background)
    mov cx, 9                   ; 3 colors × 3 bytes
.contrast_loop:
    mov al, [si]
    sub al, 31                  ; AL = ch - 31 (signed)
    sar al, 1                  ; AL = (ch - 31) / 2 (signed)
    add al, [si]               ; AL = ch + (ch - 31) / 2
    ; Clamp to 0-63
    test al, al
    jns .con_not_neg
    xor al, al
    jmp .con_store
.con_not_neg:
    cmp al, 63
    jbe .con_store
    mov al, 63
.con_store:
    mov [si], al
    inc si
    loop .contrast_loop
    pop si
    pop cx
    ret

; ============================================================================
; Data Section
; ============================================================================

msg_banner:
    db 'PalSwap v1.1 - CGA Palette Override for EGA/VGA', 13, 10
    db 'By Retro Erik - 2026 - EGA ATC / VGA DAC Programmer', 13, 10
    db 'Type: PALSWAP /? for help', 13, 10, '$'

msg_detected_ega:
    db 'Adapter: EGA detected. Using Attribute Controller.', 13, 10, '$'

msg_detected_vga:
    db 'Adapter: VGA detected. Using DAC registers (full RGB).', 13, 10, '$'

msg_no_adapter:
    db 'Error: No EGA or VGA adapter detected. Use PC1Pal for the Olivetti PC1.', 13, 10, '$'

msg_help:
    db 13, 10
    db 'Usage: PALSWAP [file.txt] [/1..5] [/c:c1,c2,c3] [/b:color]', 13, 10
    db '               [/P] [/V:+|-] [/D:+|-] [/R] [/?]', 13, 10
    db 13, 10
    db '  file.txt       Load palette from text file (default: PALSWAP.TXT)', 13, 10
    db '  /c:c1,c2,c3    Set colors 1,2,3 by name (see list below)', 13, 10
    db '  /b:color       Set background color by name', 13, 10
    db '  /P             Pop - boost saturation + contrast (more vivid)', 13, 10
    db '  /V:+  /V:-     Increase / decrease color saturation', 13, 10
    db '  /D:+  /D:-     Brighten / dim all colors', 13, 10
    db '                 (Combine /P /V /D with a preset, file, or /c:)', 13, 10
    db '  /R             Reset to standard CGA palette (re-enables BIOS reload)', 13, 10
    db '  /?             Show this help', 13, 10
    db '$'

msg_pause:
    db 13, 10, '--- Press any key for more ---', '$'

msg_help2:
    db 13, 10
    db 13, 10
    db 'Built-in presets (RGB values 0-63):', 13, 10
    db '  /1  Arcade Vibrant - Black, Blue(9,27,63), Red(63,9,9), Skin(63,45,27)', 13, 10
    db '  /2  Sierra Natural - Black, Teal(9,36,36), Brown(36,18,9), Skin(63,45,36)', 13, 10
    db '  /3  C64-inspired   - Black, Blue(18,27,63), Orange(54,27,9), Skin(63,54,36)', 13, 10
    db '  /4  CGA Red/Green  - Black, Red(63,9,9), Green(9,63,9), White(63,63,63)', 13, 10
    db '  /5  CGA Red/Blue   - Black, Red(63,0,0), Blue(0,0,63), White(63,63,63)', 13, 10
    db 13, 10
    db 'Color names for /c: and /b: (example: PALSWAP /c:blue,red,white /b:yellow)', 13, 10
    db '  black, blue, green, cyan, red, magenta, brown, lightgray,', 13, 10
    db '  darkgray, lightblue, lightgreen, lightcyan, lightred,', 13, 10
    db '  lightmagenta, yellow, white', 13, 10
    db 13, 10
    db 'Text file format (one line per color, compatible with PC1PAL.TXT):', 13, 10
    db '  R,G,B     or  R G B   (values 0-63)', 13, 10
    db '  ; Lines starting with ; or # are comments', 13, 10
    db '$'

msg_preset1:    db 'Loading preset: Arcade Vibrant', 13, 10, '$'
msg_preset2:    db 'Loading preset: Sierra Natural', 13, 10, '$'
msg_preset3:    db 'Loading preset: C64-inspired', 13, 10, '$'
msg_preset4:    db 'Loading preset: CGA Red/Green/White', 13, 10, '$'
msg_preset5:    db 'Loading preset: CGA Red/Blue/White', 13, 10, '$'
msg_resetting:  db 'Resetting to standard CGA palette...', 13, 10, '$'
msg_reset_done: db 'CGA palette restored. Default palette loading re-enabled.', 13, 10, '$'
msg_colors:     db 'Colors (R,G,B):', 13, 10, '$'
msg_color_prefix: db '  Color $'
msg_color_sep:  db ': $'
msg_crlf:       db 13, 10, '$'
msg_success:
    db 'Palette written.', 13, 10
    db 'Ready to run CGA programs!', 13, 10, '$'
msg_fallback:   db 'Using fallback CGA palette.', 13, 10, '$'
msg_file_error: db 'Warning: Cannot open palette file.', 13, 10, '$'
msg_parse_error:db 'Warning: Cannot parse palette file.', 13, 10, '$'
msg_invalid:    db 'Warning: Invalid palette data (values must be 0-63).', 13, 10, '$'
msg_bad_bg:     db 'Warning: Unknown background color name. Use /? for list.', 13, 10, '$'
msg_bad_fg:     db 'Warning: Bad /c: colors. Use /c:name,name,name (see /?).', 13, 10, '$'
msg_bad_switch: db 'Error: Unknown switch. Use /? for help.', 13, 10, '$'

default_filename: db 'PALSWAP.TXT', 0

; ============================================================================
; Fallback palette: standard CGA palette 1 high-intensity (black/cyan/mag/white)
; ============================================================================
fallback_palette:
    db 0,  0,  0    ; 0: Black
    db 0, 42, 63    ; 1: Cyan     (≈ 0,6,9 in 3-bit → 0,42,63 in 6-bit)
    db 42,  0, 42   ; 2: Magenta
    db 63, 63, 63   ; 3: White

; ============================================================================
; Preset Palettes (12 bytes each: 4 × R,G,B, values 0-63)
; Identical to PC1PAL presets — palette files are fully compatible.
; ============================================================================
preset_arcade:
    db 0,  0,  0    ; Black
    db 9, 27, 63    ; Blue
    db 63,  9,  9   ; Red
    db 63, 45, 27   ; Skin

preset_sierra:
    db 0,  0,  0    ; Black
    db 9, 36, 36    ; Teal
    db 36, 18,  9   ; Brown
    db 63, 45, 36   ; Skin

preset_c64:
    db 0,  0,  0    ; Black
    db 18, 27, 63   ; Blue
    db 54, 27,  9   ; Orange
    db 63, 54, 36   ; Skin

preset_cga_text:
    db 0,  0,  0    ; Black
    db 63,  9,  9   ; Red
    db 9, 63,  9    ; Green
    db 63, 63, 63   ; White

preset_cga_palette:
    db 0,  0,  0    ; Black
    db 63,  0,  0   ; Red
    db 0,  0, 63    ; Blue
    db 63, 63, 63   ; White



; ============================================================================
; Default EGA ATC register values for the 16 CGA colors
; These produce the standard CGA look on EGA (palette 1 high-intensity):
;   0=Black, 1=Blue, 2=Green, 3=Cyan, 4=Red, 5=Magenta,
;   6=Brown, 7=LtGray, 8=DkGray, 9=LtBlue, 10=LtGreen, 11=LtCyan,
;   12=LtRed, 13=LtMagenta, 14=Yellow, 15=White
; EGA 6-bit values (bit layout: 5=rR 4=rG 3=rB 2=R 1=G 0=B)
; ============================================================================
cga_ega_default:
    db 0x00   ; 0:  Black
    db 0x01   ; 1:  Blue         (B)
    db 0x02   ; 2:  Green        (G)
    db 0x03   ; 3:  Cyan         (G+B)
    db 0x04   ; 4:  Red          (R)
    db 0x05   ; 5:  Magenta      (R+B)
    db 0x14   ; 6:  Brown        (R + half-G = iG)
    db 0x07   ; 7:  Light Gray   (R+G+B)
    db 0x38   ; 8:  Dark Gray    (iR+iG+iB = half all three)
    db 0x39   ; 9:  Light Blue   (iR+iG+iB+B)
    db 0x3A   ; 10: Light Green  (iR+iG+iB+G)
    db 0x3B   ; 11: Light Cyan   (iR+iG+iB+G+B)
    db 0x3C   ; 12: Light Red    (iR+iG+iB+R)
    db 0x3D   ; 13: Light Magenta(iR+iG+iB+R+B)
    db 0x3E   ; 14: Yellow       (iR+iG+iB+R+G)
    db 0x3F   ; 15: White        (all six bits)

; ============================================================================
; VGA conflict-free DAC/ATC mapping tables
; ============================================================================

; Maps each DAC entry (0-15) to a user color index (0-3).
; Covers all CGA palette variants + our own ATC routing at entries 1, 8, 9.
;   0=bg, 1=our c1, 2=pal0low c1, 3=pal1low c1, 4=pal0low c2, 5=pal1low c2,
;   6=pal0low c3, 7=pal1low c3, 8=our c2, 9=our c3, 10=pal0hi c1, 11=pal1hi c1,
;   12=pal0hi c2, 13=pal1hi c2, 14=pal0hi c3, 15=pal1hi c3
color_to_dac:
    db 0, 1, 1, 1, 2, 2, 3, 3, 2, 3, 1, 1, 2, 2, 3, 3

; ATC register init values for VGA CGA-override mode.
; ATC[0-3] = 0, 1, 8, 9 — routes pixel values to conflict-free DAC entries.
; ATC[4-15] = standard text mode values (only ATC[0-3] matter in CGA mode 4).
vga_atc_init:
    db 0, 1, 8, 9, 4, 5, 0x14, 7, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F

; ============================================================================
; Background color name table for /b:color switch
; Each entry: null-terminated lowercase name, then 3 bytes R,G,B (0-63)
; Standard VGA BIOS default DAC values for the 16 CGA text mode colors.
; Table terminated by a lone null byte.
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
; Variables
; ============================================================================
explicit_file:  db 0            ; 1 if user specified a filename
parse_error:    db 0            ; 1 if /b: or /c: had bad color name
video_type:     db 0            ; 0=none, 1=EGA, 2=VGA
brightness_adj: db 0            ; 0=none, 1=brighten (+8), 2=dim (-8)
vivid_adj:      db 0            ; 0=none, 1=boost saturation, 2=mute
pop_flag:       db 0            ; 1=apply pop (saturation + contrast boost)
switch_result:  db 0            ; saved switch result for check_switches
bg_specified:   db 0            ; 1 if /b:color was given
bg_color:       db 0, 0, 0      ; Background RGB (0-63)
fg_specified:   db 0            ; 1 if /c:color,color,color was given
fg_count:       db 0            ; temp counter for parse_fg_colors
fg_colors:      times 9 db 0    ; 3 colors × 3 bytes (RGB)
file_handle:    dw 0
bytes_read:     dw 0

filename_buffer: times 128 db 0
config_buffer:   times CONFIG_SIZE db 0
ega_colors:      times 4 db 0   ; EGA 6-bit palette values for 4 user colors
atc_table:       times 16 db 0  ; Full 16-register ATC table
dac_table:       times 48 db 0  ; 16 DAC entries × 3 bytes (RGB)
text_buffer:     times TEXT_BUF_SIZE db 0

; ============================================================================
; End of PalSwap.ASM
; ============================================================================
