# F030F29 — F29 Retaliator for the Atari Falcon030

A port of the DOS game *F29 Retaliator* (Digital Image Design / Ocean, 1990) to
the Atari Falcon030.

## Project decisions

| Topic | Decision |
|---|---|
| Approach | Behaviour-faithful port via reverse engineering — `X.EXE` is the authority, while Falcon implementations may adapt mechanisms without changing observable contracts |
| Language | Pure 68030 assembly (vasm, Motorola syntax) plus DSP56001 assembly |
| Video mode | 320x240, True Color (16 bit, 2 bytes per pixel) |
| Target | Stock Falcon030, 16 MHz, 4 MB, no FPU |

The rasterizer is structured so that a later switch to 8 bit plus C2P stays a
localised change — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Game data

**This repository contains no game data.** Neither the original files nor
anything extracted, decompressed or rendered from them. *F29 Retaliator* is
copyright Ocean Software / Digital Image Design; you need your own copy.

Point the tools at your own installation:

```bash
python tools/re/unpack.py --dir /path/to/retal --extract
python tools/re/decompress.py --write
```

The engine will load `RETAL.00` / `RETAL.01` at runtime, the same arrangement
OpenTTD and Devilution use.

## Reverse engineering

The original is ~51 KB of x86 real-mode code in `X.EXE` (roughly 23,000
instructions) plus 598 KB of data in two resource archives. Everything found so
far is written up in `docs/`:

| Document | Contents |
|---|---|
| [ENGINE.md](docs/ENGINE.md) | what is in `src/`, how to build it and how to check it |
| [HUD.md](docs/HUD.md) | the flight HUD readout — units, placeholder data, verifying it |
| [MENU.md](docs/MENU.md) | the start menu — font, navigation, verifying input headlessly |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the port divides work between the 68030 and the DSP |
| [GAME-LOOP.md](docs/GAME-LOOP.md) | the per-frame update, the timing, the state variables |
| [FLIGHT-MODEL.md](docs/FLIGHT-MODEL.md) | units, thrust against drag, the turn-rate table, ground handling |
| [DOS-ORACLE.md](docs/DOS-ORACLE.md) | running the *original* DOS game headless in QEMU, to check the port against |
| [X86DISASSEMBLE.md](docs/X86DISASSEMBLE.md) | how to go about disassembling a DOS binary, from what this one cost |
| [RE-WORKFLOW.md](docs/RE-WORKFLOW.md) | picking this up cold — tools, the session workflow, patterns and traps |
| [CROSS-PROJECT.md](docs/CROSS-PROJECT.md) | techniques shared by the eleven projects in `../F030Method/README.md` — generated from the parent repository |
| [RE-NOTES.md](docs/RE-NOTES.md) | `X.EXE` memory layout, resolved indirect dispatchers, inline-string idiom |
| [ARCHIVE-FORMAT.md](docs/ARCHIVE-FORMAT.md) | container format of `RETAL.00` / `RETAL.01` |
| [RESOURCE-FORMATS.md](docs/RESOURCE-FORMATS.md) | RLE compression and the seven resource type handlers |
| [MODEL-FORMAT.md](docs/MODEL-FORMAT.md) | 3D model libraries |
| [WORLD-FORMAT.md](docs/WORLD-FORMAT.md) | world object placement lists |
| [SOUND-DRIVER.md](docs/SOUND-DRIVER.md) | the overlay driver, its API and the music data |
| [ADLIB-BACKEND.md](docs/ADLIB-BACKEND.md) | OPL2 emission, instruments, the pitch table |
| [MPU401-BACKEND.md](docs/MPU401-BACKEND.md) | the MIDI / MT-32 path |
| [DISPLAY-LIST.md](docs/DISPLAY-LIST.md) | a vector interpreter, and what it is not |

### Tools

All in `tools/re/`, Python 3 with [capstone](https://www.capstone-engine.org/):

| Tool | Purpose |
|---|---|
| `mzinfo.py` | MZ header, relocations, segment layout |
| `disasm.py` | recursive-descent disassembler with constant propagation and automatic inline-string detection |
| `codemap.py` | separates code from data by windowed analysis |
| `peek.py` | disassemble or dump an arbitrary address |
| `xref.py` | find callers of an address by scanning raw bytes |
| `unpack.py` | extract resources from the archives |
| `decompress.py` | RLE decompression |
| `render.py` | render image resources to PNG |
| `models.py` | parse the 3D model libraries |
| `objects.py` | parse the world object placement lists |
| `model2o3d.py` | convert an F29 model into the engine's `.o3d` format |
| `scene2f29.py` | build a scene file from a model library and a placement list |

`re/seeds.txt` records every resolved indirect jump target together with the
evidence for it; `disasm.py` reads it automatically.

The authoritative phase and fidelity policy is
[`../F030Method/METHOD.md`](../F030Method/METHOD.md); repository-specific rules,
source provenance and the closed substitution list are in [`AGENTS.md`](AGENTS.md).

## Building

```bash
./tools/build-run.sh                          # 68030 side -> release/f29.tos
./tools/build-dsp.sh                          # DSP side   -> release/3d.lod
./tools/run.sh                                # launch in Hatari
./tools/grab-frame.sh 1500 build/frame.png    # headless screenshot
```

The original DOS game can be run headless the same way, as a reference to
compare against — see [DOS-ORACLE.md](docs/DOS-ORACLE.md):

```bash
python tools/dos/build_dos_hdd.py             # -> img/f29.hdd (DOS 6.22 + game)
python tools/dos/run_qemu.py --timeout 60 --shot 12 --shot 25
```

`make` is not required; the build is plain bash.

Grab frames at 1500 VBLs or later. Earlier than that and the program has not
finished starting, so what you get is the TOS desktop — see
[ENGINE.md](docs/ENGINE.md).

### Toolchain

None of it lives in this repository. `tools/toolchain.sh` finds each tool in
the sibling checkouts, and every script sources it, so the build works from
wherever the family is checked out - macOS, Linux or an MSYS2 shell. The
search order per tool is:

1. the environment variable, if set - it wins, but must exist
2. the sibling checkouts, looked for next to this one first and then under
   the original development machine's `/c/Arbeit`
3. `$PATH`, by base name

Native and `.exe` names are both tried at every candidate, so the same script
picks up a Mach-O `vasmm68k_mot` and a Win32 `vasmm68k_mot.exe` alike.

| Variable | Tool | Usually found at |
|---|---|---|
| `VASM` | vasm, m68k, Motorola syntax | `../F030Arcade/third_party/vasm/` |
| `VLINK` | vlink | `../F030Arcade/third_party/vlink/` |
| `ASM56K` | directory holding `ASM56000.EXE`, `CLDLOD.EXE`, `DOS4GW.EXE` | `../f030dsp3d/tools/asm56k/` |
| `DOSBOX` | DOSBox, needed because ASM56000 is a DOS4GW program | `$PATH` (`dosbox-staging`) |
| `HATARI` | Hatari | `../F030Arcade/third_party/hatari/`, else `$PATH` |
| `TOS` | TOS 4.02 ROM image | `../f030dsp3d/tools/tos402.rom` |
| `MAGICK` | ImageMagick, only for the frame grab's PNG step | `$PATH` |
| `F29_ROOTS` | where to look for the sibling checkouts | this checkout's parent, `/c/Arbeit` |

Set `F29_ROOTS` if the siblings are not next to this checkout. The DSP build
still needs DOSBox, because ASM56000 is a DOS program with no native port.

vasm is invoked as `-Felf -m68030`, vlink as `-tos-fastload -b ataritos -e start`.

## Layout

```
docs/       architecture and format documentation
re/         seeds.txt; generated listings and resources land here (ignored)
src/        68030 assembly - the engine
src/dsp/    DSP56001 assembly - the geometry pipeline
src/inc/    included sources, deliberately outside the build glob
tools/re/   reverse-engineering tools
tools/dos/  DOS oracle: build and drive img/f29.hdd (shared with the sibling projects)
tools/      build, runner and frame-grab scripts; toolchain.sh locates the tools
img/        genuine DOS 6.22 floppies + the built f29.hdd (ignored, no game data in git)
```

## Status

The reverse engineering is broad: the archive, the compression, the image,
model and world formats and the sound driver are all decoded, and the
disassembly reaches 44.6 % of `X.EXE`.

The port itself has just started. The engine renders an F29 scene - a model
library plus placed instances, culled and depth-sorted on the 68030, one DSP
round trip each - over a drawn horizon at 320x240 true colour in Hatari,
measured at **25 fps** for sixteen distant objects and **11.6 fps** for one
that fills the screen. A HUD readout and a start menu exist (see
[HUD.md](docs/HUD.md), [MENU.md](docs/MENU.md)); the flight model, game logic
and cockpit panel are not written.

Measuring rather than calculating already paid for itself once. The first
bottleneck was not the video mode the arithmetic pointed at, but the fact that
the engine copied a stored 153 KB backdrop over the screen every frame.
Drawing the horizon instead gained 18.8 % and freed 153 KB of RAM. See
[ENGINE.md](docs/ENGINE.md).
