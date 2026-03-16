# VEGAPal — CGA Palette Override TSR for EGA and VGA cards

**Version 2.1** — By Retro Erik, 2026

A DOS TSR (Terminate and Stay Resident) that lets you run CGA games in 4-colour mode with completely custom colours on any EGA or VGA card.

Compatible with the palette text file format used by **PC1PAL** (Olivetti PC1 palette loader) — the same `.TXT` files work on both tools.

---

## The Problem

CGA games call `INT 10h AH=00h AL=04h` at startup to set CGA mode 4. This resets the entire VGA DAC (or EGA ATC) back to hardware defaults, wiping any palette you programmed before launching the game. A simple one-shot palette writer cannot survive this.

## The Solution

VEGAPal installs as a TSR and hooks `INT 10h`. Every time a game sets CGA mode 4 or 5, the hook:

1. Lets the original handler run (sets the hardware mode normally).
2. Immediately reprograms the VGA DAC or EGA ATC with your saved colours.

The game sees its expected CGA mode, but with your custom palette — invisibly and transparently.

---

## Requirements

- DOS (real or emulated, e.g. DOSBox)
- EGA or VGA graphics card (auto-detected)
- NASM (to reassemble from source)

---

## Usage

```
VEGAPal [file.txt] [/1..5] [/R] [/U] [/?]
```

| Switch    | Effect |
|-----------|--------|
| *(none)*  | Load colours from `VEGAPal.TXT` in the current directory |
| `file.txt`| Load colours from the named text file |
| `/1`      | Preset: Arcade Vibrant — Black, Blue, Red, Skin |
| `/2`      | Preset: Sierra Natural — Black, Teal, Brown, Skin |
| `/3`      | Preset: C64-inspired  — Black, Blue, Orange, Skin |
| `/4`      | Preset: CGA Red/Green — Black, Red, Green, White |
| `/5`      | Preset: CGA Red/Blue  — Black, Red, Blue, White |
| `/R`      | Reset to default CGA palette (TSR still installs) |
| `/U`      | Uninstall the TSR and restore the original `INT 10h` |
| `/?`      | Show help |

### Typical workflow

```dos
VEGAPal /3          ; install TSR with C64 preset
ZAXXON              ; run the game — colours are applied automatically
VEGAPal /U          ; uninstall when done
```

To reinstall with a different palette, uninstall first:

```dos
VEGAPal /U
VEGAPal /2
```

---

## Palette Text File Format

Four lines of `R,G,B` values in the range `0–63` (6-bit, same scale as the VGA DAC):

```
; My custom CGA palette
0,0,0
0,42,63
42,0,42
63,63,63
```

- Lines beginning with `;` or `#` are comments.
- **100% compatible** with PC1PAL `.TXT` files — copy them straight across.

### Colour mapping

The four colours correspond to CGA mode 4 pixels:

| Line | Pixel | DAC entries programmed |
|------|-------|------------------------|
| 1    | 0 — background | 0 |
| 2    | 1               | 2, 3, 10, 11 |
| 3    | 2               | 4, 5, 12, 13 |
| 4    | 3               | 6, 7, 14, 15 |

---

## How It Works (Technical)

### VGA (port 3C8h / 3C9h)
RGB values are written directly as 6-bit components (0–63) to the VGA DAC. All 13 CGA mode 4 DAC entries are programmed on every mode set.

### EGA (port 3C0h / 3DAh)
The program converts your RGB values to the nearest of the 64 fixed EGA colours at install time, building an `atc_shadow[]` table in the resident block. On every mode set, all 16 ATC registers are reprogrammed from this table.

### Far-pointer layout (important implementation note)
The saved `INT 10h` vector is stored as `orig_int10_ofs` followed by `orig_int10_seg` (offset first, segment second). This matches the memory layout required by `jmp far [mem]` / `call far [mem]` on x86. Reversing the order causes every non-mode-4 `INT 10h` call to jump to a garbage address and crash whatever is running.

### TSR size
Calculated at runtime as `(offset_of_end_marker + 15) / 16` paragraphs. Because NASM compiles this as a COM file with `ORG 0x100`, the label offsets already include the 256-byte PSP — no extra addition needed.

---

## Building from Source

```dos
nasm -f bin -o VEGAPal.COM VEGAPal.asm
```

Requires NASM. Produces a plain DOS `.COM` file (~3.9 KB).

---

## Files

| File | Description |
|------|-------------|
| `VEGAPal.ASM` | Full NASM source |
| `VEGAPal.COM` | Assembled binary, ready to run |
| `VEGAPal copy.asm` | Old v1.0 one-shot version (non-TSR, for reference) |

---

## Relation to PC1PAL

[PC1PAL](../PC1-Palette-Loader/) does the same job for the **Olivetti PC1**, which uses a Yamaha V6355D video chip with its own palette ports (0DDh/0DEh) and 3-bit colour channels. VEGAPal targets standard **EGA/VGA** cards using the standard VGA DAC and EGA ATC hardware instead. The palette text file format is identical between both tools.
