; ============================================================================
; PalSwapT.ASM - CGA Palette Override TSR for EGA and VGA cards
; Written for NASM - 8086 compatible (runs on any DOS PC)
; By Retro Erik - 2026 using VS Code with GitHub Copilot
; Version 2.0 - TSR edition
; NOTE: Only tested in DOSBox, not on real hardware.
; ============================================================================
;
; PROBLEM SOLVED: CGA games reset the video mode (INT 10h AH=00h) at startup,
; which wipes any palette you set beforehand.  This TSR hooks INT 10h and
; re-applies your custom palette IMMEDIATELY after every CGA mode 4/5 set,
; so the game always sees your colors.
;
; HOW IT WORKS:
;   1. You run PalSwapT [/1..5 | file.txt] before the game.
;   2. PalSwapT loads the palette, hooks INT 10h, and stays resident (TSR).
;   3. When the game calls INT 10h AH=00h AL=04h (set CGA mode 4):
;        a. The original INT 10h handler runs first (sets the hardware mode).
;        b. Our hook then immediately programs the VGA DAC or EGA ATC
;           with your saved RGB values.
;   4. The game sees its expected CGA mode but with your custom colors.
;   5. Run "PalSwapT /U" to uninstall the TSR when done.
;
; VGA DAC (ports 3C8h/3C9h):
;   6-bit RGB per channel (0-63), written directly to hardware registers.
;   All 13 CGA DAC entries that CGA mode 4 uses are programmed.
;
; EGA ATC (port 3C0h, reset via 3DAh):
;   16 palette registers, each a 6-bit EGA colour index.
;   The program converts your RGB values to the nearest EGA colour at
;   install time and stores them in the resident atc_shadow[] table.
;
; CGA mode 4 pixel -> DAC entry mapping (all entries are programmed):
;   Pixel 0 (BG):  DAC entry  0
;   Pixel 1:       DAC entries  2,  3, 10, 11
;   Pixel 2:       DAC entries  4,  5, 12, 13
;   Pixel 3:       DAC entries  6,  7, 14, 15
;
; IMPORTANT - far-pointer layout in resident data:
;   orig_int10_ofs MUST come before orig_int10_seg in memory because
;   "jmp/call far [mem]" reads offset (low word) then segment (high word).
;   Getting this wrong causes every non-mode-4 INT 10h call to jump to a
;   garbage address and crash whatever is running.
;
; TSR SIZE:
;   Computed at runtime as  (offset_of_behind_tsr_end + 15) / 16  paragraphs.
;   ORG 0x100 means the label offsets already include the 256-byte PSP,
;   so no extra PSP addition is needed.
;
; Usage:  PalSwapT [file.txt] [/1] [/2] [/3] [/4] [/5] [/R] [/U] [/?]
;   /1 .. /5   Built-in colour presets (see list below)
;   /R         Reset: TSR installs but uses the default CGA palette
;   /U         Uninstall the resident TSR from memory
;   /?         Show help
;   file.txt   Load colours from a text file (default: PALSWAPT.TXT)
;
; Palette text file format (identical to PC1PAL.TXT - 100% cross-compatible):
;   R,G,B   one line per colour, 4 lines total, values 0-63
;   Lines starting with ; or # are treated as comments
;
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================
VGA_DAC_WRITE_IDX   equ 0x3C8
VGA_DAC_DATA        equ 0x3C9
ATC_ADDR_DATA       equ 0x3C0
INPUT_STATUS_1      equ 0x3DA

DISPLAY_EGA_COLOR   equ 0x04
DISPLAY_EGA_MONO    equ 0x05
DISPLAY_VGA_COLOR   equ 0x08
DISPLAY_VGA_MONO    equ 0x07

CONFIG_SIZE     equ 12
PALETTE_ENTRIES equ 4
TEXT_BUF_SIZE   equ 512

; ============================================================================
; Jump over resident data to installer main
; ============================================================================
jmp main

; ============================================================================
; RESIDENT DATA
; ============================================================================
tsr_sig:        db 'PalSwap'

orig_int10_ofs: dw 0            ; far-pointer layout: offset first...
orig_int10_seg: dw 0            ; ...segment second  (required for jmp/call far [mem])
video_type:     db 0            ; 1=EGA, 2=VGA

palette_rgb:
    db 0,  0,  0
    db 0, 42, 63
    db 42,  0, 42
    db 63, 63, 63

; ============================================================================
; INT 10h HOOK
; ============================================================================
tsr_int10:
    cmp ah, 0x00
    jne .chain
    cmp al, 0x04
    je .cga_mode
    cmp al, 0x05
    je .cga_mode
    jmp .chain

.cga_mode:
    pushf
    call far [cs:orig_int10_ofs]
    cmp byte [cs:video_type], 2
    je .apply_vga
    cmp byte [cs:video_type], 1
    je .apply_ega
    iret

.apply_vga:
    call apply_palette_vga
    iret

.apply_ega:
    call apply_palette_ega
    iret

.chain:
    jmp far [cs:orig_int10_ofs]

; ============================================================================
; apply_palette_vga
; ============================================================================
apply_palette_vga:
    push ax
    push dx

    ; Entry 0: color 0
    mov dx, VGA_DAC_WRITE_IDX
    mov al, 0
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+0]
    out dx, al
    mov al, [cs:palette_rgb+1]
    out dx, al
    mov al, [cs:palette_rgb+2]
    out dx, al

    ; Color 1 -> entries 2, 3, 10, 11
    mov dx, VGA_DAC_WRITE_IDX
    mov al, 2
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+3]
    out dx, al
    mov al, [cs:palette_rgb+4]
    out dx, al
    mov al, [cs:palette_rgb+5]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 3
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+3]
    out dx, al
    mov al, [cs:palette_rgb+4]
    out dx, al
    mov al, [cs:palette_rgb+5]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 10
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+3]
    out dx, al
    mov al, [cs:palette_rgb+4]
    out dx, al
    mov al, [cs:palette_rgb+5]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 11
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+3]
    out dx, al
    mov al, [cs:palette_rgb+4]
    out dx, al
    mov al, [cs:palette_rgb+5]
    out dx, al

    ; Color 2 -> entries 4, 5, 12, 13
    mov dx, VGA_DAC_WRITE_IDX
    mov al, 4
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+6]
    out dx, al
    mov al, [cs:palette_rgb+7]
    out dx, al
    mov al, [cs:palette_rgb+8]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 5
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+6]
    out dx, al
    mov al, [cs:palette_rgb+7]
    out dx, al
    mov al, [cs:palette_rgb+8]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 12
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+6]
    out dx, al
    mov al, [cs:palette_rgb+7]
    out dx, al
    mov al, [cs:palette_rgb+8]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 13
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+6]
    out dx, al
    mov al, [cs:palette_rgb+7]
    out dx, al
    mov al, [cs:palette_rgb+8]
    out dx, al

    ; Color 3 -> entries 6, 7, 14, 15
    mov dx, VGA_DAC_WRITE_IDX
    mov al, 6
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+9]
    out dx, al
    mov al, [cs:palette_rgb+10]
    out dx, al
    mov al, [cs:palette_rgb+11]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 7
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+9]
    out dx, al
    mov al, [cs:palette_rgb+10]
    out dx, al
    mov al, [cs:palette_rgb+11]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 14
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+9]
    out dx, al
    mov al, [cs:palette_rgb+10]
    out dx, al
    mov al, [cs:palette_rgb+11]
    out dx, al

    mov dx, VGA_DAC_WRITE_IDX
    mov al, 15
    out dx, al
    mov dx, VGA_DAC_DATA
    mov al, [cs:palette_rgb+9]
    out dx, al
    mov al, [cs:palette_rgb+10]
    out dx, al
    mov al, [cs:palette_rgb+11]
    out dx, al

    pop dx
    pop ax
    ret

; ============================================================================
; apply_palette_ega
; ============================================================================
apply_palette_ega:
    push ax
    push bx
    push dx

    cli
    mov dx, INPUT_STATUS_1
    in al, dx

    mov bx, 0

.ega_loop:
    mov dx, ATC_ADDR_DATA
    mov al, bl
    out dx, al
    jmp short $+2
    mov al, [cs:atc_shadow + bx]
    out dx, al
    jmp short $+2
    inc bx
    cmp bx, 16
    jb .ega_loop

    mov al, 0x20
    out dx, al
    sti

    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; RESIDENT AREA END - everything above stays resident
; ============================================================================
atc_shadow:     times 16 db 0
behind_tsr_end: db 0            ; dummy byte so NASM knows the address

; ============================================================================
; INSTALLER (discarded after TSR install)
; ============================================================================
main:
    mov dx, msg_banner
    call print_string

    call detect_video
    cmp byte [video_type], 0
    je .no_adapter

    call check_uninstall
    cmp al, 1
    je .do_uninstall

    call check_switches
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

    jmp .load_file

.no_adapter:
    mov dx, msg_no_adapter
    call print_string
    jmp .exit_no_tsr

.show_help:
    mov dx, msg_help
    call print_string
    jmp .exit_no_tsr

.do_reset:
    mov dx, msg_resetting
    call print_string
    jmp .install

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
    mov di, palette_rgb
    mov cx, 12
    cld
    rep movsb
    jmp .install

.load_file:
    call load_config
    jc .use_fallback
    call validate_palette
    jc .use_fallback
    jmp .install

.use_fallback:
    mov dx, msg_fallback
    call print_string

.install:
    call print_colors

    cmp byte [video_type], 1
    jne .skip_ega_init
    call build_ega_atc_shadow
.skip_ega_init:

    ; Apply palette immediately for the preview/text mode
    cmp byte [video_type], 2
    je .apply_vga_now
    call apply_palette_ega
    jmp .check_installed
.apply_vga_now:
    call apply_palette_vga

.check_installed:
    call check_already_loaded
    cmp al, 1
    je .already_loaded

    ; Save original INT 10h
    mov ax, 0x3510
    int 0x21
    mov [orig_int10_seg], es
    mov [orig_int10_ofs], bx

    ; Install hook
    mov ax, 0x2510
    mov dx, tsr_int10
    int 0x21

    mov dx, msg_installed
    call print_string

    ; Go resident
    ; Compute resident size in paragraphs at runtime
    ; DX = (offset_of_behind_tsr_end + 256 + 15) / 16
    ; 256 = PSP size, +15 for rounding up
    mov dx, behind_tsr_end      ; offset already includes PSP (ORG 0x100)
    add dx, 15                  ; round up to paragraph boundary
    mov cl, 4
    shr dx, cl                  ; divide by 16 to get paragraphs
    mov ax, 0x3100
    int 0x21

.already_loaded:
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
; detect_video
; ============================================================================
detect_video:
    push ax
    push bx

    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A
    je .is_vga

    mov ax, 0x1200
    mov bl, 0x10
    int 0x10
    cmp bl, 0x10
    je .not_found

.is_ega:
    mov byte [video_type], 1
    mov dx, msg_detected_ega
    call print_string
    jmp .dv_done

.is_vga:
    mov byte [video_type], 2
    mov dx, msg_detected_vga
    call print_string
    jmp .dv_done

.not_found:
    mov byte [video_type], 0

.dv_done:
    pop bx
    pop ax
    ret

; ============================================================================
; check_already_loaded
; ============================================================================
check_already_loaded:
    push bx
    push cx
    push si
    push di
    push es

    mov ax, 0x3510
    int 0x21

    mov di, tsr_sig
    mov si, tsr_sig
    mov cx, 7
    push ds
    push cs
    pop ds
    repe cmpsb
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
; uninstall_tsr
; ============================================================================
uninstall_tsr:
    push ax
    push bx
    push dx
    push ds
    push es

    mov ax, 0x3510
    int 0x21

    mov di, tsr_sig
    mov si, tsr_sig
    mov cx, 7
    push ds
    push cs
    pop ds
    repe cmpsb
    pop ds
    jne .not_us

    mov ax, 0x2510
    push es
    push word [es:orig_int10_seg]
    pop ds
    mov dx, [es:orig_int10_ofs]
    int 0x21
    pop es

    mov ah, 0x49
    int 0x21

    mov dx, msg_unloaded
    jmp .ui_msg

.not_us:
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
; build_ega_atc_shadow
; ============================================================================
build_ega_atc_shadow:
    push ax
    push bx
    push cx
    push si
    push di

    mov si, cga_ega_default
    mov di, atc_shadow
    mov cx, 16
    cld
    rep movsb

    ; Convert 4 RGB colors to EGA 6-bit values, store in ega_tmp
    mov si, palette_rgb
    mov di, ega_tmp
    mov cx, 4

.conv_loop:
    xor bl, bl
    lodsb                       ; Red
    cmp al, 32
    jb .r_half
    or bl, 0x04
    jmp .r_done
.r_half:
    cmp al, 16
    jb .r_done
    or bl, 0x20
.r_done:
    lodsb                       ; Green
    cmp al, 32
    jb .g_half
    or bl, 0x02
    jmp .g_done
.g_half:
    cmp al, 16
    jb .g_done
    or bl, 0x10
.g_done:
    lodsb                       ; Blue
    cmp al, 32
    jb .b_half
    or bl, 0x01
    jmp .b_done
.b_half:
    cmp al, 16
    jb .b_done
    or bl, 0x08
.b_done:
    mov [di], bl
    inc di
    loop .conv_loop

    ; Place EGA values into atc_shadow at CGA mode 4 positions
    mov al, [ega_tmp+0]
    mov [atc_shadow+0], al

    mov al, [ega_tmp+1]
    mov [atc_shadow+2], al
    mov [atc_shadow+3], al
    mov [atc_shadow+10], al
    mov [atc_shadow+11], al

    mov al, [ega_tmp+2]
    mov [atc_shadow+4], al
    mov [atc_shadow+5], al
    mov [atc_shadow+12], al
    mov [atc_shadow+13], al

    mov al, [ega_tmp+3]
    mov [atc_shadow+6], al
    mov [atc_shadow+7], al
    mov [atc_shadow+14], al
    mov [atc_shadow+15], al

    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; check_uninstall -> AL=1 if /U on cmdline
; ============================================================================
check_uninstall:
    push si
    mov si, 0x81
.cu_skip:
    lodsb
    cmp al, ' '
    je .cu_skip
    cmp al, 0x0D
    je .cu_none
    cmp al, '/'
    je .cu_slash
    cmp al, '-'
    je .cu_slash
    jmp .cu_none
.cu_slash:
    lodsb
    cmp al, 'U'
    je .cu_yes
    cmp al, 'u'
    je .cu_yes
.cu_none:
    xor al, al
    jmp .cu_done
.cu_yes:
    mov al, 1
.cu_done:
    pop si
    ret

; ============================================================================
; check_switches -> AL: 0=none/file, 1=help, 2=reset, 3-7=presets
; ============================================================================
check_switches:
    push si
    mov si, 0x81
.cs_skip:
    lodsb
    cmp al, ' '
    je .cs_skip
    cmp al, 0x0D
    je .cs_none
    cmp al, '/'
    je .cs_char
    cmp al, '-'
    je .cs_char
    jmp .cs_none
.cs_char:
    lodsb
    cmp al, '?'
    je .cs_help
    cmp al, 'H'
    je .cs_help
    cmp al, 'h'
    je .cs_help
    cmp al, 'R'
    je .cs_reset
    cmp al, 'r'
    je .cs_reset
    cmp al, '1'
    je .cs_p1
    cmp al, '2'
    je .cs_p2
    cmp al, '3'
    je .cs_p3
    cmp al, '4'
    je .cs_p4
    cmp al, '5'
    je .cs_p5
    jmp .cs_none
.cs_help:  mov al, 1
    jmp .cs_done
.cs_reset: mov al, 2
    jmp .cs_done
.cs_p1:    mov al, 3
    jmp .cs_done
.cs_p2:    mov al, 4
    jmp .cs_done
.cs_p3:    mov al, 5
    jmp .cs_done
.cs_p4:    mov al, 6
    jmp .cs_done
.cs_p5:    mov al, 7
    jmp .cs_done
.cs_none:  xor al, al
.cs_done:
    pop si
    ret

; ============================================================================
; load_config
; ============================================================================
load_config:
    push ax
    push bx
    push cx
    push dx

    call get_filename
    jc .use_default
    jmp .open_file
.use_default:
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
    mov dx, msg_file_error
    call print_string
    stc
.lc_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_text_palette
; ============================================================================
parse_text_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov si, text_buffer
    mov di, palette_rgb
    mov cx, [bytes_read]
    xor bx, bx
.ptp_next:
    cmp bl, 4
    jae .ptp_done
    or cx, cx
    jz .ptp_check
.ptp_skip_ws:
    or cx, cx
    jz .ptp_check
    lodsb
    dec cx
    cmp al, ' '
    je .ptp_skip_ws
    cmp al, 9
    je .ptp_skip_ws
    cmp al, 13
    je .ptp_skip_ws
    cmp al, 10
    je .ptp_next
    cmp al, ';'
    je .ptp_eol
    cmp al, '#'
    je .ptp_eol
    dec si
    inc cx
    call parse_number
    jc .ptp_fail
    mov [di], al
    call skip_separator
    jc .ptp_fail
    call parse_number
    jc .ptp_fail
    mov [di+1], al
    call skip_separator
    jc .ptp_fail
    call parse_number
    jc .ptp_fail
    mov [di+2], al
    add di, 3
    inc bl
.ptp_eol:
    or cx, cx
    jz .ptp_check
    lodsb
    dec cx
    cmp al, 10
    jne .ptp_eol
    jmp .ptp_next
.ptp_check:
    cmp bl, 4
    jb .ptp_fail
.ptp_done:
    clc
    jmp .ptp_exit
.ptp_fail:
    stc
.ptp_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_number
; ============================================================================
parse_number:
    push bx
    push dx
    xor ax, ax
    xor bx, bx
.pn_loop:
    or cx, cx
    jz .pn_check
    mov dl, [si]
    cmp dl, '0'
    jb .pn_check
    cmp dl, '9'
    ja .pn_check
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
    jmp .pn_loop
.pn_check:
    or bx, bx
    jz .pn_err
    cmp ax, 64
    jae .pn_err
    clc
    jmp .pn_done
.pn_err:
    stc
.pn_done:
    pop dx
    pop bx
    ret

; ============================================================================
; skip_separator
; ============================================================================
skip_separator:
    push ax
    or cx, cx
    jz .ss_err
.ss_loop:
    lodsb
    dec cx
    cmp al, ','
    je .ss_more
    cmp al, ' '
    je .ss_more
    cmp al, 9
    je .ss_more
    cmp al, 10
    je .ss_err
    cmp al, 13
    je .ss_err
    dec si
    inc cx
    clc
    jmp .ss_done
.ss_more:
    or cx, cx
    jz .ss_err
    jmp .ss_loop
.ss_err:
    stc
.ss_done:
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
.gf_skip:
    lodsb
    cmp al, ' '
    je .gf_skip
    cmp al, 0x0D
    je .gf_none
    cmp al, 0x0A
    je .gf_none
    cmp al, '/'
    je .gf_none
    cmp al, '-'
    je .gf_none
.gf_copy:
    cmp al, ' '
    je .gf_end
    cmp al, 0x0D
    je .gf_end
    cmp al, 0x0A
    je .gf_end
    stosb
    lodsb
    jmp .gf_copy
.gf_end:
    xor al, al
    stosb
    mov dx, filename_buffer
    clc
    jmp .gf_done
.gf_none:
    stc
.gf_done:
    pop di
    pop si
    ret

; ============================================================================
; validate_palette
; ============================================================================
validate_palette:
    push cx
    push si
    mov si, palette_rgb
    mov cx, CONFIG_SIZE
.vp_loop:
    lodsb
    cmp al, 64
    jae .vp_bad
    loop .vp_loop
    clc
    jmp .vp_done
.vp_bad:
    mov dx, msg_invalid
    call print_string
    stc
.vp_done:
    pop si
    pop cx
    ret

; ============================================================================
; print_colors
; ============================================================================
print_colors:
    push ax
    push bx
    push cx
    push si
    mov dx, msg_colors
    call print_string
    mov si, palette_rgb
    mov cl, 0
.pc_loop:
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
    jb .pc_loop
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_color_block
; ============================================================================
print_color_block:
    push ax
    push bx
    push cx
    mov bl, al
    or al, al
    jz .pcc_attr
    shl bl, 1
    add bl, 9
.pcc_attr:
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
; print_number, print_char, print_string
; ============================================================================
print_number:
    push ax
    push bx
    push dx
    xor ah, ah
    mov bl, 10
    div bl
    or al, al
    jz .pn2_ones
    add al, '0'
    call print_char
.pn2_ones:
    mov al, ah
    add al, '0'
    call print_char
    pop dx
    pop bx
    pop ax
    ret

print_char:
    push ax
    push dx
    mov dl, al
    mov ah, 0x02
    int 0x21
    pop dx
    pop ax
    ret

print_string:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; Data
; ============================================================================
msg_banner:
    db 'PalSwapT v2.1 - CGA Palette TSR for EGA/VGA', 13, 10
    db 'By Retro Erik - 2026 - Hooks INT 10h to survive game mode resets', 13, 10
    db 'Compatible with PC1PAL palette text files.', 13, 10, '$'

msg_detected_ega:
    db 'Adapter: EGA detected.', 13, 10, '$'
msg_detected_vga:
    db 'Adapter: VGA detected.', 13, 10, '$'
msg_no_adapter:
    db 'Error: No EGA or VGA adapter found.', 13, 10, '$'

msg_installed:
    db 'TSR installed. INT 10h hooked.', 13, 10
    db 'Run your CGA game now. Use PalSwapT /U to uninstall.', 13, 10, '$'
msg_already_loaded:
    db 'PalSwapT TSR already installed.', 13, 10
    db 'Use PalSwapT /U to uninstall first, then reinstall with new palette.', 13, 10, '$'
msg_unloaded:
    db 'PalSwapT TSR uninstalled. INT 10h restored.', 13, 10, '$'
msg_unload_error:
    db 'Error: PalSwapT TSR not found in INT 10h chain.', 13, 10, '$'

msg_help:
    db 13, 10
    db 'Usage: PalSwapT [file.txt] [/1..5] [/R] [/U] [/?]', 13, 10, 13, 10
    db '  Installs as TSR. Hooks INT 10h and re-applies palette after', 13, 10
    db '  every CGA mode 4/5 set. Palette survives game mode resets.', 13, 10, 13, 10
    db '  /R  Default palette   /U  Uninstall TSR   /?  Help', 13, 10
    db '  /1  Arcade Vibrant  Black, Blue(9,27,63), Red(63,9,9), Skin', 13, 10
    db '  /2  Sierra Natural  Black, Teal(9,36,36), Brown, Skin', 13, 10
    db '  /3  C64-inspired    Black, Blue(18,27,63), Orange(54,27,9), Skin', 13, 10
    db '  /4  CGA Red/Green   Black, Red, Green, White', 13, 10
    db '  /5  CGA Red/Blue    Black, Red, Blue, White', 13, 10, 13, 10
    db '  Text file: R,G,B per line (0-63), compatible with PC1PAL.TXT', 13, 10
    db '  Default file: PALSWAPT.TXT', 13, 10
    db '$'

msg_preset1:     db 'Preset: Arcade Vibrant', 13, 10, '$'
msg_preset2:     db 'Preset: Sierra Natural', 13, 10, '$'
msg_preset3:     db 'Preset: C64-inspired', 13, 10, '$'
msg_preset4:     db 'Preset: CGA Red/Green/White', 13, 10, '$'
msg_preset5:     db 'Preset: CGA Red/Blue/White', 13, 10, '$'
msg_resetting:   db 'Using default CGA palette.', 13, 10, '$'
msg_colors:      db 'Colors (R,G,B):', 13, 10, '$'
msg_color_prefix:db '  Color $'
msg_color_sep:   db ': $'
msg_crlf:        db 13, 10, '$'
msg_fallback:    db 'Warning: palette load failed, using default.', 13, 10, '$'
msg_file_error:  db 'Warning: Cannot open palette file.', 13, 10, '$'
msg_parse_error: db 'Warning: Cannot parse palette file.', 13, 10, '$'
msg_invalid:     db 'Warning: Value out of range (must be 0-63).', 13, 10, '$'

default_filename: db 'PALSWAPT.TXT', 0

cga_ega_default:
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
    db 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F

preset_arcade:
    db 0, 0, 0,   9, 27, 63,  63, 9, 9,   63, 45, 27

preset_sierra:
    db 0, 0, 0,   9, 36, 36,  36, 18, 9,  63, 45, 36

preset_c64:
    db 0, 0, 0,  18, 27, 63,  54, 27, 9,  63, 54, 36

preset_cga_text:
    db 0, 0, 0,  63, 9, 9,   9, 63, 9,   63, 63, 63

preset_cga_palette:
    db 0, 0, 0,  63, 0, 0,   0, 0, 63,   63, 63, 63

; Installer-only variables
file_handle:  dw 0
bytes_read:   dw 0
ega_tmp:      times 4 db 0

filename_buffer: times 128 db 0
text_buffer:     times TEXT_BUF_SIZE db 0

; ============================================================================
; End of PalSwapT.ASM
; ============================================================================
