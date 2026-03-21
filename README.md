# PalSwap — CGA Palette Override for EGA and VGA cards

**Version 1.1** — By Retro Erik, 2026

A DOS utility that lets you run CGA games in 4-colour mode with completely custom colours on any EGA or VGA card. Run it once before launching a game — no TSR needed.

Compatible with the palette text file format used by **PC1PAL** (Olivetti PC1 palette loader) — the same `.TXT` files work on both tools.

---

## The Problem

CGA games are limited to fixed 4-colour palettes (cyan/magenta/white or red/green/yellow). EGA and VGA cards can display far more colours, but games written for CGA don't take advantage of this.

## The Solution

PalSwap reprograms the VGA DAC or EGA ATC registers to map the CGA pixel values to your custom colours.

On **VGA**, it also calls `INT 10h AX=1201h BL=31h` to disable the BIOS default palette reload on mode set. This means your custom palette persists even when games call `INT 10h AH=00h` to set CGA mode — the mode is set normally but the palette is preserved.

On **EGA**, there is no equivalent mechanism, so the palette persists only until the next mode set. Some games that don't re-set the video mode will still work.

### How VGA palette persistence works

In CGA mode 4, the 2-bit pixel value (0–3) selects ATC register [0]–[3], which points to a DAC entry. Games can call `INT 10h AH=0Bh` to select different CGA palette variants, which reprograms ATC[1–3] to point to different DAC entries:

| CGA Palette Variant | ATC[1] → DAC | ATC[2] → DAC | ATC[3] → DAC |
|---------------------|--------------|--------------|--------------|
| Palette 1 High      | 11           | 13           | 15           |
| Palette 1 Low       | 3            | 5            | 7            |
| Palette 0 High      | 10           | 12           | 14           |
| Palette 0 Low       | 2            | 4            | 6            |

PalSwap fills **all 16** DAC entries (0–15) with the correct user colour for every possible routing. It also programs ATC[0–3] to use conflict-free DAC entries (0, 1, 8, 9) for games that don't call `AH=0Bh` at all. This means zero conflicts regardless of which CGA palette variant the game selects.

---

## Requirements

- DOS (real mode — tested on 286 with Trident TVGA9000i-3, and 486 with VGA)
- EGA or VGA graphics card (auto-detected)
- NASM (to reassemble from source)

---

## Usage

```
PALSWAP [file.txt] [/1..5] [/c:c1,c2,c3] [/b:color] [/P] [/V:+|-] [/D:+|-] [/R] [/?]
```

| Switch         | Effect |
|----------------|--------|
| *(none)*       | Load colours from `PALSWAP.TXT` in the current directory |
| `file.txt`     | Load colours from the named text file |
| `/1`           | Preset: Arcade Vibrant — Black, Blue, Red, Skin |
| `/2`           | Preset: Sierra Natural — Black, Teal, Brown, Skin |
| `/3`           | Preset: C64-inspired  — Black, Blue, Orange, Skin |
| `/4`           | Preset: CGA Red/Green — Black, Red, Green, White |
| `/5`           | Preset: CGA Red/Blue  — Black, Red, Blue, White |
| `/c:c1,c2,c3`  | Set colours 1, 2, 3 by name (see colour list below) |
| `/b:color`     | Set background colour by name |
| `/P`           | Pop — boost saturation + contrast (more vivid colours) |
| `/V:+`         | Increase colour saturation (more vivid) |
| `/V:-`         | Decrease colour saturation (more muted/gray) |
| `/D:+`         | Brighten colours 1–3 |
| `/D:-`         | Dim colours 1–3 |
| `/R`           | Reset to default CGA palette (re-enables BIOS palette reload) |
| `/?`           | Show help |

> **Note:** `/P`, `/V`, and `/D` are modifiers — combine them with a preset, file, or `/c:` switch.

### Colour names for /c: and /b:

All 16 standard CGA colours are available (case-insensitive):

> black, blue, green, cyan, red, magenta, brown, lightgray,
> darkgray, lightblue, lightgreen, lightcyan, lightred, lightmagenta, yellow, white

### Examples

```dos
PALSWAP /1 /P                       ; Arcade Vibrant with pop (more vivid)
PALSWAP /2 /V:+ /D:+                ; Sierra Natural, boosted + brightened
PALSWAP /c:blue,red,white           ; custom colours by name
PALSWAP /c:cyan,magenta,yellow /b:darkgray  ; custom colours + background
PALSWAP /1 /b:blue                  ; preset with background override
PALSWAP /1 /c:green,red,white       ; preset background + custom foreground
PALSWAP mypalette.txt               ; load from file
PALSWAP /R                          ; reset to defaults
```

### Typical workflow

```dos
PALSWAP /3          ; set C64 preset
ZAXXON              ; run the game — colours are already applied
PALSWAP /R          ; reset when done
```

---

## Palette Text File Format

Four lines of `R,G,B` values in the range `0–63` (6-bit, same scale as the VGA DAC):

```
; My custom CGA palette
0,0,0        ; Black (background)
0,42,63      ; Sky Blue (colour 1)
42,0,42      ; Purple (colour 2)
63,63,63     ; White (colour 3)
```

- Lines beginning with `;` or `#` are comments.
- Blank lines are ignored.
- Values can be separated by commas or spaces.
- **100% compatible** with PC1PAL `.TXT` files — copy them straight across.

---

## How It Works (Technical)

### VGA path (video_type = 2)

1. Calls `INT 10h AX=1201h BL=31h` to disable default palette loading on mode set.
2. Programs ATC[0–3] = 0, 1, 8, 9 (conflict-free DAC routing — entries 8, 9 are never used by any standard CGA palette).
3. Writes all 16 DAC entries (0–15) with the correct user colour for every CGA palette variant.
4. Also writes DAC entries 59, 61, 63 so that DOS text mode shows a colour preview using text attributes 11, 13, 15.

### EGA path (video_type = 1)

1. Converts each user RGB (0–63) to the nearest EGA 6-bit colour value.
   - EGA has 3 intensity levels per channel: off (value < 16), half (16–31), full (≥ 32).
   - The 6-bit value uses bits `rR rG rB R G B` (lowercase = half, uppercase = full).
2. Builds a full 16-register ATC table, overriding all CGA-active entries.
3. Programs all 16 ATC registers via port 3C0h.

### Reset (/R)

1. If VGA: calls `INT 10h AX=1200h BL=31h` to re-enable default palette loading.
2. Reads the current video mode and re-sets it, triggering a full BIOS palette reload.

---

## Building from Source

```dos
nasm -f bin -o palswap.com PalSwap.asm
```

Requires NASM. Produces a plain DOS `.COM` file.

---

## Files

| File | Description |
|------|-------------|
| `PalSwap.asm`  | Non-TSR version — NASM source (this tool) |
| `palswap.com`  | Assembled binary, ready to run |
| `PalSwapT.asm` | TSR version (hooks INT 10h, for DOSBox use) |
| `README.md`    | This file |

---

## Relation to PC1PAL

[PC1PAL](../PC1-Palette-Loader/) does the same job for the **Olivetti PC1**, which uses a Yamaha V6355D video chip with its own palette ports (0DDh/0DEh) and 3-bit colour channels. PalSwap targets standard **EGA/VGA** cards using the standard VGA DAC and EGA ATC hardware instead. The palette text file format is identical between both tools.
