# The Falcon engine

The renderer is not written from scratch. It is the engine from the sibling
project [`f030dsp3d`](../../f030dsp3d) — own code, originally from 1994 —
brought into `src/` and simplified from a demo into something a game can use.
[ARCHITECTURE.md](ARCHITECTURE.md) covers why that division of labour suits a
flight simulator; this file covers what is actually in the tree and how to run
it.

## State

It builds and runs. A headless frame grab in Hatari shows the 3D model
rendering at 320x240 true colour with the generated ground gradient beneath it.

Not yet done: the sky half of the backdrop is wrong (task 14), and **the frame
rate has not been measured**. The bandwidth question that shaped the whole
video-mode decision is therefore still arithmetic rather than evidence.

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
