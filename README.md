# F030F29 — F29 Retaliator for the Atari Falcon030

A port of the DOS game *F29 Retaliator* (Digital Image Design / Ocean, 1990) to
the Atari Falcon030.

## Project decisions

| Topic | Decision |
|---|---|
| Approach | 1:1 port via reverse engineering — `X.EXE` is disassembled and its x86 real-mode logic translated function by function to 68030 |
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
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the port divides work between the 68030 and the DSP |
| [RE-NOTES.md](docs/RE-NOTES.md) | `X.EXE` memory layout, resolved indirect dispatchers, inline-string idiom |
| [ARCHIVE-FORMAT.md](docs/ARCHIVE-FORMAT.md) | container format of `RETAL.00` / `RETAL.01` |
| [RESOURCE-FORMATS.md](docs/RESOURCE-FORMATS.md) | RLE compression and the seven resource type handlers |
| [MODEL-FORMAT.md](docs/MODEL-FORMAT.md) | 3D model libraries |
| [WORLD-FORMAT.md](docs/WORLD-FORMAT.md) | world object placement lists |

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

`re/seeds.txt` records every resolved indirect jump target together with the
evidence for it; `disasm.py` reads it automatically.

## Building

```bash
./tools/build-run.sh      # 68030 side  -> release/f29.tos
./tools/build-dsp.sh      # DSP side    -> release/3d.lod
./tools/run.sh            # launch in Hatari
```

`make` is not required; the build is plain bash.

### Toolchain

The scripts default to paths on the original development machine but every one
of them can be overridden by an environment variable:

| Variable | Tool |
|---|---|
| `VASM` | vasm, m68k, Motorola syntax |
| `VLINK` | vlink |
| `ASM56K` | directory holding `ASM56000.EXE`, `CLDLOD.EXE`, `DOS4GW.EXE` |
| `DOSBOX` | DOSBox, needed because ASM56000 is a DOS4GW program |
| `HATARI` | Hatari |
| `TOS` | TOS 4.02 ROM image |

vasm is invoked as `-Felf -m68030`, vlink as `-tos-fastload -b ataritos -e start`.

## Layout

```
docs/       architecture and format documentation
re/         seeds.txt; generated listings and resources land here (ignored)
src/        68030 assembly
src/dsp/    DSP56001 assembly
tools/re/   reverse-engineering tools
tools/      build and runner scripts
```
