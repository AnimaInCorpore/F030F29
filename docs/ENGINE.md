# The Falcon engine

The renderer is not written from scratch. It is the engine from the sibling
project [`f030dsp3d`](../../f030dsp3d) — own code, originally from 1994 —
brought into `src/` and simplified from a demo into something a game can use.
[ARCHITECTURE.md](ARCHITECTURE.md) covers why that division of labour suits a
flight simulator; this file covers what is actually in the tree and how to run
it.

## State

It builds and runs. A headless frame grab in Hatari shows a flat-shaded model
over a generated sky-and-ground horizon at 320x240 true colour.

**Flat shading, not textured.** The engine came from `f030dsp3d`, and the
version taken is commit `ee77bf2` — the one *before* texture mapping was added.
F29 Retaliator is a flat-shaded game, so the textured pipeline is complexity
with no purpose, and it is not cheap: `dp_hc.s` is 220 lines in the flat
version against 1037 in the textured one, and the DSP source 2301 lines against
2591.

## Measured frame rate

A frame counter is incremented once per main-loop pass and read out of memory
at two breakpoints, so the interval between them excludes startup:

| | Frames | VBLs | VBLs/frame | fps at 50 Hz |
|---|---:|---:|---:|---:|
| VBL 1500 to 3000, model drawn | 293 | 1500 | 5.12 | **9.8** |
| background restore only | 603 | ~2386 | ~3.96 | ~12.6 |

The second row is not a clean isolation — with the model disabled nothing sets
the dirty range, so `clear_screen4` falls through to a *full* background copy
every frame, while the first row only restores the range the model touched. It
is still the number that matters, because it bounds the whole approach:

**Copying the 153,600-byte backdrop over the screen once per frame costs about
four VBLs on its own, capping the frame rate near 12 fps before a single
polygon is drawn.**

That is the bandwidth argument from [ARCHITECTURE.md](ARCHITECTURE.md) showing
up as evidence rather than arithmetic, and it points at a fix that is specific
to this game: a flight simulator does not need a *stored* backdrop. The horizon
is two gradient bands that move with pitch and roll, and drawing them directly —
blitter fills, one span per scanline — replaces a 153 KB copy with a few hundred
register writes. That should be done before any judgement is made about whether
true colour is affordable.

Caveat: this is Hatari, not hardware. It runs with `--cpu-exact` and
`--compatible`, but Falcon bus contention and blitter timing are approximations.
Treat the numbers as relative, not absolute.

## Files

| File | Lines | Purpose |
|---|---:|---|
| `src/start.s` | ~250 | entry, Videl and interrupt setup, teardown |
| `src/f29.s` | ~1200 | main loop, backdrop generation, screen clears, debug readout |
| `src/dp_hc.s` | 1037 | blitter span filler and textured polygon routines |
| `src/sincos.s` | 1787 | sine and cosine tables |
| `src/keyboard.s` | 159 | keyboard interrupt handler |
| `src/rot_vbl.s` | 80 | VBL handler |
| `src/dsp/3d.asm` | 2591 | the DSP56001 geometry pipeline |
| `src/inc/` | | `bios.s`, `xbios.s`, `gemdos.s`, `colours.s` — included, not assembled separately |

The includes live in `src/inc/` for a practical reason: `tools/build-run.sh`
globs `src/*.s` and assembles each file it finds, so anything meant to be
included has to sit outside that glob.

## Changes from the original

- **320x240 instead of 300x224.** Constants in `f29.s`, `dp_hc.s` and
  `src/dsp/3d.asm`.
- **Videl setup replaced.** The original wrote a fixed 300x224 RGB/TV mode. It
  now detects the monitor through bit 6 of `$ffff8006` and programs 320x240
  true colour either way — VGA needs doubled scan lines to reach 240 visible
  lines. The register values come from the F030Arcade ports, which run this
  mode on real hardware.
- **The TGA backdrop is gone.** A flight simulator wants a horizon, not a
  photograph, so sky and ground are generated procedurally at startup. That
  costs no asset, no binary space and no load time.

  The colour packing is worth reading before changing: RGB565 is assembled as
  two separate bytes, `high = (r << 3) | (g >> 3)` and
  `low = ((g & 7) << 5) | b`, which keeps every shift inside the 68k limit of
  eight and is easy to verify by hand. The gradients divide by powers of two so
  the interpolation is a shift. A first attempt that packed the word directly
  produced green stripes across the sky while the ground came out correct;
  rewriting it this way fixed it outright.
- **The demo's info screen and its wait for SPACE are gone.** A game starts.
- **Unused Videl tables dropped**, and the screen BSS corrected from `ds.l` to
  `ds.b` — the original allocated four times what it needed.

## Video mode

320x240, 16 bits per pixel, RGB565: red in bits 15..11, green 10..5, blue 4..0.
Two buffers of 153,600 bytes each, swapped every frame, with no virtual stride —
the line width register holds 320 words and the line offset is zero.

## Building and checking

```bash
./tools/build-run.sh      # 68030 side -> release/f29.tos
./tools/build-dsp.sh      # DSP side   -> release/3d.lod
./tools/run.sh            # interactive, in Hatari
./tools/grab-frame.sh 1500 build/frame.png   # headless screenshot
```

`grab-frame.sh` runs Hatari with video disabled, breaks at a VBL count, reads
the displayed buffer address out of the Videl base registers and dumps it. Two
passes are needed because Hatari's `savebin` cannot dereference a pointer. The
address is stable for a given build but moves whenever the BSS layout changes,
so it is never hard-coded.

## Two traps worth remembering

**68k shift and `addq` immediates only go up to 8.** Placing the five red bits
at 15..11 with a literal `lsl #11` does not assemble. `ror #5` does the job
exactly, because the rest of the word is zero. Same for `addq #12` — that needs
a plain `add`.

**The Hatari build is MSYS2 UCRT64.** Without its DLLs on `PATH` it exits
silently with status 0 and writes no log at all, which looks exactly like a
program that failed to start. `grab-frame.sh` exports the path itself.

## A debugging note

Grabbing a frame at VBL 250 shows the TOS desktop, not the program: DSP
reservation, the `.lod` load and initialisation all have to finish first. Four
builds in a row produced identical garbage before the obvious control
experiment settled it — running the *unmodified* original through the same
pipeline, which produced the same garbage at 250 and rendered correctly at
1500.

When a change appears to have no effect, check that the harness is measuring
what you think it is before changing the code again.
