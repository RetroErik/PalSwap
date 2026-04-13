# PalSwap — CGA Palette Override for EGA and VGA cards

A DOS TSR (Terminate and Stay Resident) utility that lets you run CGA games with completely custom 4-colour palettes on any EGA or VGA card. It hooks INT 10h to survive game mode resets and INT 09h for live palette hotkeys via Ctrl+Alt.

Also includes **CGASwap** — a companion TSR for **real CGA cards** that overrides the built-in CGA palette combinations (see below).

By **Retro Erik** — [YouTube: Retro Hardware and Software](https://www.youtube.com/@RetroErik)

![IBM PC / Compatible](https://img.shields.io/badge/Platform-IBM%20PC%20%2F%20Compatible-blue)
![CGA/EGA/VGA](https://img.shields.io/badge/Platform-CGA%20%2F%20EGA%20%2F%20VGA-blue)
![License](https://img.shields.io/badge/License-CC%20BY--NC%204.0-green)

### ▶️ [Watch the PalSwapT video on YouTube](https://youtu.be/c2lrBGcd43Q)
### ▶️ [Watch the PalSwap video on YouTube](https://youtu.be/M94z11cK5FQ)

### 📥 [Download PALSwap.zip — includes both COM files, and palette files](PALSwap.zip)

Compatible with the palette text file format used by **PC1PAL** (Olivetti PC1 palette loader) — the same `.TXT` files work on both tools.

Also includes **PalSwap** (non-TSR version) for one-shot palette changes.

---

## PalSwap (Non-TSR Version)

A simpler one-shot tool that sets the palette and exits immediately — no TSR, no hotkeys.

```
PALSWAP [file.txt] [/1..9] [/0] [/c:c1,c2,c3] [/b:color] [/P] [/V:+|-] [/D:+|-] [/R] [/?]
```

All 10 built-in presets (`/1`–`/9`, `/0`) are identical to PalSwapT. Supports the same palette file format, colour names, and adjustment switches (`/P`, `/V`, `/D`). Does not stay resident — the palette persists until the next video mode set.

---

## The Problem

CGA games are limited to fixed 4-colour palettes (cyan/magenta/white or red/green/yellow). EGA and VGA cards can display far more colours, but games written for CGA don't take advantage of this.

## The Solution

PalSwapT installs as a TSR and reprograms the palette registers to map CGA pixel values to your custom colours. It hooks INT 10h so the palette is re-applied every time a game sets CGA mode 4/5, and hooks INT 09h so you can change palettes on the fly while a game is running.

- **On VGA:** Programs the DAC with full 18-bit RGB colour (262,144 colours available).
- **On EGA:** Programs the ATC registers with 6-bit RGB (64 colours available on the card), though real EGA monitors may limit this to 16 colours in CGA-compatible 200-line modes depending on monitor sync-frequency decoding. PalSwap still provides custom palette remapping within the monitor's constraints.

---

## Requirements

- DOS (real mode — tested on 286 with Trident TVGA9000i-3, and 486 with VGA)
- EGA or VGA graphics card (auto-detected)
- NASM (to reassemble from source)

---

## Usage

```
PALSWAPT [file.txt] [/1..9] [/0] [/c:c1,c2,c3] [/b:color] [/P] [/V:+|-] [/D:+|-] [/R] [/U] [/?]
```

| Switch         | Effect |
|----------------|--------|
| *(none)*       | Load colours from `PALSWAPT.TXT` in the current directory |
| `file.txt`     | Load palette file (1–9 palettes, 4 lines each) |
| `/1`           | Preset: Arcade Vibrant |
| `/2`           | Preset: Sierra Natural |
| `/3`           | Preset: C64-inspired |
| `/4`           | Preset: CGA Red/Green/White |
| `/5`           | Preset: CGA Red/Blue/White |
| `/6`           | Preset: Amstrad CPC |
| `/7`           | Preset: Pastel |
| `/8`           | Preset: Monochrome Amber |
| `/9`           | Preset: Monochrome Green |
| `/0`           | Preset: Monochrome Gray |
| `/c:c1,c2,c3`  | Set colours 1, 2, 3 by name (see colour list below) |
| `/b:color`     | Set background colour by name |
| `/P`           | Pop — boost saturation + contrast |
| `/V:+`  `/V:-` | Increase / decrease saturation |
| `/D:+`  `/D:-` | Brighten / dim colours |
| `/R`           | Install with default CGA palette (high-intensity) |
| `/U`           | Uninstall TSR from memory |
| `/?`           | Show help |

> **Note:** `/P`, `/V`, and `/D` are modifiers — combine them with a preset, file, or `/c:` switch.

---

## Live Hotkeys

While the TSR is installed, hold **Ctrl+Alt** and press:

| Key | Action |
|-----|--------|
| `1`..`9`, `0` | Switch to preset 1–9 or 0 instantly |
| `P` | Toggle Pop (saturation + contrast boost) |
| `R` | Reset to default CGA palette (high-intensity cyan/magenta/white) |
| `Up` / `Down` | Brighten / Dim (±8 per step, max 3 steps) |
| `Left` / `Right` | Less / More vivid saturation (max 3 steps) |
| `Space` | Random palette from 15 CGA colours |
| `C` | Random palette from C64 colours (Pepto palette) |
| `A` | Random palette from Amstrad CPC colours (27-colour hardware palette) |
| `Z` | Random palette from ZX Spectrum colours (14 colours, normal + bright) |

Release Ctrl+Alt to return to normal keyboard operation.

The random hotkeys pick 3 unique colours from the selected palette for CGA colour slots 1–3. Background (slot 0) is unchanged. Press the same key again for a different combination. All adjustments (brightness/vivid/pop) are reset on each random pick.

---

## Colour Names for /c: and /b:

All 16 standard CGA colours (case-insensitive):

> black, blue, green, cyan, red, magenta, brown, lightgray,
> darkgray, lightblue, lightgreen, lightcyan, lightred, lightmagenta, yellow, white

### Examples

```dos
PALSWAPT /1 /P                       ; Arcade Vibrant with pop (more vivid)
PALSWAPT /2 /V:+ /D:+                ; Sierra Natural, boosted + brightened
PALSWAPT /c:blue,red,white           ; custom colours by name
PALSWAPT /c:cyan,magenta,yellow /b:darkgray  ; custom colours + background
PALSWAPT /8                          ; Monochrome Amber preset
PALSWAPT mypalette.txt               ; load from file
PALSWAPT /R                          ; install with default CGA palette
PALSWAPT /U                          ; uninstall TSR
```

### Typical Workflow

```dos
PALSWAPT /3         ; install with C64 preset
ZAXXON              ; run the game — colours applied, survive mode resets
                    ; press Ctrl+Alt+Space for random CGA colours
                    ; press Ctrl+Alt+C for random C64 colours
                    ; press Ctrl+Alt+1..9 to switch presets
PALSWAPT /R         ; reset to default CGA (no uninstall needed)
PALSWAPT /1         ; switch to Arcade Vibrant (updates resident TSR)
PALSWAPT /U         ; uninstall when done
```

### Using Platform Palette Files

```dos
PALSWAPT C64.TXT    ; load 9 Commodore 64 palettes — overwrites presets 1–9
LODERUN             ; Ctrl+Alt+1..9 switches between C64 palette combos
PALSWAPT /U         ; uninstall

PALSWAPT ZX.TXT     ; load 9 ZX Spectrum palettes
PALSWAPT CPC.TXT    ; ...or 9 Amstrad CPC palettes
```

---

## Palette Text File Format

A palette file contains `R,G,B` values in the range `0–63` (6-bit, same scale as the VGA DAC).

### Single palette (4 lines — works like before):

```
; My custom CGA palette
0,0,0        ; Black (background)
0,42,63      ; Sky Blue (colour 1)
42,0,42      ; Purple (colour 2)
63,63,63     ; White (colour 3)
```

### Multi-palette file (up to 9 palettes — overwrites presets 1–9):

A file can contain up to 9 palettes (4 colour lines each = 36 lines of RGB). When a multi-palette file is loaded, the palettes overwrite the built-in presets 1–9, so you can switch between them with `Ctrl+Alt+1`..`9` during gameplay.

The first palette in the file becomes the active palette on install and preset 1. The second becomes preset 2, and so on.

```
; GAMEPACK.TXT - 3 palettes for my favourite games
; Palette 1: Sunset
0,0,0
42,0,21
63,21,0
63,63,0
; Palette 2: Ocean
0,0,0
0,21,42
0,42,63
42,63,63
; Palette 3: Forest
0,0,0
21,42,0
0,42,0
42,63,21
```

- Lines beginning with `;` or `#` are comments.
- Blank lines are ignored.
- Values can be separated by commas or spaces.
- Single-palette files are **100% compatible** with PC1PAL `.TXT` files.

### Included Platform Palette Files

Three ready-made 9-palette files are included, each built from verified colours sourced from [Lospec.com](https://lospec.com/palette-list):

| File | Platform | Colours available | Description |
|------|----------|-------------------|-------------|
| `C64.TXT` | Commodore 64 | 16 (15 non-black) | Classic 8-bit home computer palette |
| `ZX.TXT` | ZX Spectrum | 15 (14 non-black) | Bold pure-RGB + BRIGHT variants |
| `CPC.TXT` | Amstrad CPC | 27 (26 non-black) | 3 intensity levels per channel |

Each file contains 9 curated palettes designed for different game genres (action, sci-fi, terrain, UI, etc.). Load with e.g. `PALSWAPT C64.TXT` then use `Ctrl+Alt+1`..`9` to switch palettes in-game.

---

## CGASwap — CGA Palette Override for Real CGA Cards

A companion TSR for systems with a **real CGA card** (IBM 5153 or compatible). Unlike PalSwapT, which requires EGA or VGA, CGASwap works by directly programming the CGA hardware registers (ports 3D8h and 3D9h).

CGA has no palette indirection — the hardware provides 6 fixed foreground palette combinations plus a selectable background colour. CGASwap forces your chosen combination and fights to keep it applied when games try to set their own.

### Usage

```
CGASWAP [/1..6] [/b:color] [/T] [/U] [/?]
```

| Switch     | Effect |
|------------|--------|
| `/1`       | Palette 1, High intensity: Light Cyan, Light Magenta, White |
| `/2`       | Palette 1, Low intensity: Cyan, Magenta, Light Gray |
| `/3`       | Palette 0, High intensity: Light Green, Light Red, Yellow |
| `/4`       | Palette 0, Low intensity: Green, Red, Brown |
| `/5`       | Mode 5, High intensity: Light Cyan, Light Red, White |
| `/6`       | Mode 5, Low intensity: Cyan, Red, Light Gray |
| `/b:color` | Set background (0–15 or name, e.g. `/b:blue`) |
| `/T`       | Disable timer enforcement (default: timer ON) |
| `/U`       | Uninstall TSR |
| `/?`       | Show help |

### Live Hotkeys

**Ctrl+Alt + 1..6** — Switch palette combination on the fly.

The hotkeys work through two mechanisms:
- **INT 09h hook**: Instant response when the game chains to the original keyboard handler.
- **INT 08h polling fallback**: Tracks Ctrl/Alt state from port 60h scan codes (~18× per second). Works even when games replace INT 09h without chaining.

### Timer Enforcement (Default: ON)

By default, CGASwap re-applies the palette every timer tick (~18.2 Hz) while in CGA mode 4/5. This handles games that write directly to port 3D9h, bypassing INT 10h. Text mode is never disturbed.

Use `/T` to **disable** the timer if it causes issues with a specific game. Hotkey polling in INT 08h remains active even with `/T`.

Games that continuously write to 3D9h in their main loop will outpace the 18 Hz timer. For those, set the palette before launching the game.

### How It Works

1. **INT 10h hook**: Intercepts mode set (AH=00h) — lets the BIOS set the mode, then re-applies palette to ports 3D8h/3D9h. Also intercepts palette set (AH=0Bh) — overrides with our settings. Tracks mode 4/5 vs. other modes for safe timer operation.
2. **INT 09h hook**: Watches for Ctrl+Alt + 1-6 via BIOS keyboard flags (0040:0017h). Swallows the keystroke and applies the preset immediately.
3. **INT 08h hook**: Polls port 60h to self-track Ctrl/Alt modifier state (independent of BIOS flags). Detects hotkeys even when games replace INT 09h. By default, also reapplies palette every tick (~18.2 Hz). `/T` disables the palette enforcement but keeps hotkey polling active.

### Game Compatibility (Tested on Real CGA Hardware)

| Game | Palette | Hotkeys | Notes |
|------|---------|---------|-------|
| Montezuma's Revenge | ✅ Works | ✅ Works | |
| Ms. Pac-Man | ✅ Works | ✅ Works | |
| International Karate (IK) | ✅ Works | ✅ Works | Sound OK |
| Bruce Lee | ✅ Works | ✅ Works | Sound OK |
| Popcorn | ✅ Works | ✅ Works | Sound OK |
| Last Ninja | ✅ Works | ✅ Works | |
| Monkey Island (CGA) | ✅ Works | ✅ Works | |
| Galaxian | ✅ Works | ✅ Works | |
| Rick Dangerous | ✅ Title screen | ⚠️ Title only | Game replaces INT 08h+09h during gameplay |
| Fallen Angel | ⚠️ Set before launch | ⚠️ Title only | Writes 3D9h directly; replaces INT 08h+09h in-game |

**Tip:** For games marked "Set before launch", run `CGASWAP /3` (or your preferred preset) before starting the game. The palette applies at mode set and persists until the game overrides it.

### Building

```dos
nasm -f bin -o CGASwap.com "Asm Source/CGASwap.asm"
```

---

## How It Works (Technical)

### TSR Architecture

1. PalSwapT loads the palette and hooks INT 09h (keyboard) and INT 10h (video).
2. When a game calls INT 10h AH=00h to set CGA mode 4/5, the original handler runs first, then our hook re-programs the palette.
3. INT 09h hook checks BIOS flags at 0040:0017h for Ctrl+Alt. If both are held, scan codes are compared against hotkey table. Non-hotkey keys pass through to the original handler.
4. A `palette_active` flag controls whether the INT 10h hook applies custom colours. Default install with `/R` sets this to 0 (dormant) so text mode colours aren't disturbed.
5. **Live reload:** If the TSR is already resident, re-running PalSwapT with new arguments (e.g. a different file, preset, or `/R`) updates the resident copy’s palette, presets, and adjustment state without needing to uninstall first.

### VGA Path (video_type = 2)

1. Writes all 16 DAC entries (0–15) using the `color_to_dac[]` mapping table, so every CGA palette variant (palette 0/1, low/high intensity, mode 4/5) gets the user's custom colours.
2. Programs ATC[0–15] using `vga_atc_init[]` for conflict-free routing — ATC[0–3] = 0, 1, 8, 9 ensures both low and high intensity CGA pixel values map through our controlled DAC entries. ATC[4–15] retain standard text mode values.
3. Writes custom colours to DAC 59/61/63 so text mode attributes 11/13/15 (light cyan, light magenta, white) display a preview of the current palette colours in DOS.
4. No BIOS palette reload disable (1201h/31h) — the INT 10h hook re-applies after every mode 4/5 set, and the BIOS reloads default DAC/ATC on mode 3, keeping text mode completely clean after exiting a game.

> **Note:** The non-TSR version (PalSwap) also programs ATC and DAC, and additionally calls `INT 10h AX=1201h BL=31h` to disable BIOS palette reload, since it has no hook to re-apply after a mode set.

### EGA Path (video_type = 1)

1. Converts each user RGB (0–63) to the nearest EGA 6-bit colour value.
2. Builds a full 16-register ATC table, overriding all CGA-active entries.
3. Programs all 16 ATC registers via port 3C0h.

### EGA Hardware Monitor Considerations

**Important distinction:** On real EGA hardware (e.g., IBM 5154 monitor), the monitor itself plays a critical role in colour interpretation:

- The **EGA card outputs 6 bits** (RrGgBb) for the ATC colours in all modes, giving access to 64 distinct colours in theory.
- However, **standard EGA monitors physically switch decoding modes based on sync frequency**: in 200-line CGA-compatible modes (70.86 Hz), the IBM 5154 switches from 6-bit interpretation to 4-bit RGBI (Red, Green, Blue, Intensity binary signals), even though the EGA card is still outputting all 6 bits.
- This limitation is **hardware-side on the monitor itself**, not the card — the card cannot force the monitor to interpret 6-bit values if the monitor's pin decoding is sync-frequency-dependent.
- **Practical impact:** On a real IBM 5154 in CGA mode 4 you are limited to 16 displayed colours (the 16-colour RGBI set), not 64. However, PalSwap still provides significant value: you can remap those 4 CGA colour slots **to any of the 16 RGBI colours instead of the fixed CGA palette sets** (cyan/magenta/white OR red/green/yellow).

**Multi-frequency monitors and hardware switches:**
- Some multi-frequency monitors (e.g., NEC MultiSync) may interpret the 6 inputs identically across all sync frequencies, potentially allowing 64-colour access in 200-line modes. This has not been tested on actual hardware.
- Some games (e.g., *Ivan 'Ironman' Stewart's Super Off Road*, *Rambo 3*) supported hardware switch modes that allowed users to manually override this monitor behaviour on specific systems.

**Bottom line:** PalSwap's primary target is **VGA systems**, where the full 262,144-colour DAC is available with no monitor-side restrictions. On real EGA hardware, PalSwap provides a practical improvement within the 16-colour RGBI constraint rather than full 64-colour freedom.

### CGA Mode 4 DAC Routing

In CGA mode 4, the 2-bit pixel value (0–3) selects ATC register [0]–[3], which points to a DAC entry. Games can select different CGA palette variants, which reprograms ATC[1–3]:

| CGA Palette Variant | ATC[1] → DAC | ATC[2] → DAC | ATC[3] → DAC |
|---------------------|--------------|--------------|--------------|
| Palette 1 High      | 11           | 13           | 15           |
| Palette 1 Low       | 3            | 5            | 7            |
| Palette 0 High      | 10           | 12           | 14           |
| Palette 0 Low       | 2            | 4            | 6            |

PalSwapT fills **all 16** DAC entries with the correct user colour for every possible routing, so there are zero conflicts regardless of which CGA palette variant the game selects.

### Random Palette Generation

A 16-bit LCG PRNG (seed × 25173 + 13849) seeded from the BIOS timer tick at 0040:006Ch. A generic `hotkey_random` routine accepts a colour table pointer and count, picks 3 unique colours (no duplicates), writes them to `base_palette` slots 1–3, resets all adjustments, and calls `recompute_and_apply`.

Colour tables in resident memory (sourced from [Lospec.com](https://lospec.com/palette-list)):
- **CGA**: 15 standard colours from `default_text_dac` (entries 1–15)
- **C64**: 15 Commodore 64 palette colours
- **Amstrad CPC**: 26 non-black hardware colours (3 intensity levels per channel)
- **ZX Spectrum**: 14 colours (7 normal + 7 bright)

---

## Building from Source

```dos
nasm -f bin -o PalSwapT.COM "Asm Source/PalSwapT.asm"
nasm -f bin -o palswap.com "Asm Source/PalSwap.asm"
nasm -f bin -o CGASwap.com "Asm Source/CGASwap.asm"
```

Requires NASM. Produces plain DOS `.COM` files.

---

## Files

| File | Description |
|------|-------------|
| `Asm Source/PalSwapT.asm` | TSR version — NASM source (main tool, EGA/VGA) |
| `Asm Source/PalSwap.asm`  | Non-TSR version — one-shot palette setter (EGA/VGA) |
| `Asm Source/CGASwap.asm`  | CGA TSR version — palette override for real CGA cards |
| `PalSwapT.COM` | Assembled TSR binary, ready to run |
| `palswap.com`  | Assembled non-TSR binary |
| `CGASwap.com`  | Assembled CGA TSR binary |
| `C64.TXT`      | 9 mini-palettes using Commodore 64 colours (Lospec) |
| `ZX.TXT`       | 9 mini-palettes using ZX Spectrum colours (Lospec) |
| `CPC.TXT`      | 9 mini-palettes using Amstrad CPC colours (Lospec) |
| `Illustrations/` | SVG/PNG palette diagrams and DAC routing maps |
| `README.md`    | This file |

---

## Relation to PC1PAL

[PC1PAL](../PC1-Palette-Loader/) does the same job for the **Olivetti PC1**, which uses a Yamaha V6355D video chip with its own palette ports (0DDh/0DEh) and 3-bit colour channels. PalSwap targets standard **EGA/VGA** cards using the standard VGA DAC and EGA ATC hardware instead. The palette text file format is identical between both tools.

---

## YouTube

For more retro computing content, visit my YouTube channel **Retro Hardware and Software**:
[https://www.youtube.com/@RetroErik](https://www.youtube.com/@RetroErik)
