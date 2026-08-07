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
at two breakpoints, so the interval between them excludes startup.

| Backdrop | Frames, VBL 1500→3000 | VBLs/frame | fps at 50 Hz |
|---|---:|---:|---:|
| copied from a stored image | 293 | 5.12 | 9.8 |
| **drawn as horizon runs** | **348** | **4.31** | **11.6** |

**+18.8 %**, and 153 KB of RAM back — the stored backdrop was
`SCREEN_WIDTH*SCREEN_HEIGHT` words of BSS, the run table is 512 bytes. On a
4 MB machine that matters as much as the frame rate.

The reasoning that led here: copying reads 153,600 bytes and writes as many
again, while drawing only writes.

**A correction to an earlier claim.** An isolation run with the model disabled
was used to put the full-screen copy at "roughly four VBLs a frame on its own".
That number was wrong. It divided a frame count by an interval that had a
startup offset estimated from a *different* build, and the estimate did not
transfer. Later two-point measurements show a whole frame — horizon, sixteen
objects and all — costing 2.00 VBLs, so the horizon cannot be costing three.
Only the paired measurements in the table above are sound, because both ends
come from the same build.

The lesson is the same one as the VBL 250 grab: a measurement is only as good
as the thing it is compared against.

## Scene rendering

| Scene | Frames, VBL 1500→3000 | VBLs/frame | fps |
|---|---:|---:|---:|
| one large model filling the screen | 348 | 4.31 | 11.6 |
| sixteen small distant objects | 750 | 2.00 | **25.0** |

Sixteen objects, each its own DSP round trip, run at more than twice the rate
of one large one. **Fill cost dominates, not object count.** The DSP handles
geometry for sixteen models in less time than the blitter takes to fill one
screen-sized silhouette, which is a useful thing to know before optimising the
wrong end.

Caveat: this is Hatari, not hardware. It runs with `--cpu-exact` and
`--compatible`, but Falcon bus contention and blitter timing are
approximations. Treat the numbers as relative, not absolute.

### How the horizon is drawn

Every gradient divides by a power of two, so the colour changes every fourth
scanline at most. The table built at startup therefore holds *runs*, not lines:
each entry is a word count and a colour, and one blitter run covers four
scanlines of 320 pixels at once. That is about sixty blits a frame rather than
240.

The blit itself uses the same trick as the polygon filler: `Dst_Xinc` of 0 with
`X_Count` of 1 turns `Y_Count` into a pixel count, so a run fills that many
consecutive words from the halftone register. The halftone is loaded as eight
longwords rather than sixteen words.

`background`, `clear_screen`, `clear_screen2`, `clear_screen3` and
`clear_screen4` are all gone with it — 142 lines removed.

## The scene

The engine inherited a one-object file: header, points, normals, polygons, one
BSP tree. A flight simulator needs a library of models and a few hundred
instances placed across the world, so `tools/re/scene2f29.py` builds a scene
file and `src/scene.s` draws it.

```bash
python tools/re/scene2f29.py            # -> release/scene.f29
```

**The DSP is unchanged, and deliberately so.** It already transforms, clips,
projects and BSP-sorts one object per call, and its memory is nowhere near
large enough for a library of 299 models. The scene work therefore sits on the
68030: select the instances in view, order them back to front, hand them to the
DSP one at a time. The per-object BSP orders faces within an object, the
distance sort orders the objects among themselves.

Per frame `scene_render` culls to a 12,000-unit box and a ceiling of sixteen
objects, sorts by squared horizontal distance — comparing squares avoids a root
and orders identically — and then does one round trip each: send geometry and
transform, take the span lists back, fill them.

The camera start position is stored in the file, as the centroid of the
instances. Without it the viewer begins at the origin, and since a theatre's
scenery sits tens of thousands of units away the first render is an empty
horizon — which is exactly what the first attempt produced.

If `scene.f29` is absent the loop falls back to the inherited single-object
path, which is still how one model gets looked at on its own.

## F29 models on the Falcon

`tools/re/model2o3d.py` converts a model out of the decoded libraries into the
`.o3d` file the engine loads, computing face normals and building the BSP tree
the DSP walks. That closes the loop from original game data to the target
screen.

```bash
python tools/re/model2o3d.py --list
python tools/re/model2o3d.py --index 2 -o release/model.o3d
```

Two things came out of getting the first model to render.

**F29 winds its faces the other way round.** With the normals as computed from
the vertex order, every face is back-facing and the model is invisible bar the
odd stray polygon — the first render was an empty horizon with a single white
speck. Reversing them is therefore the default; `--keep-winding` turns it off.

**Line primitives do not render.** The `0x1C` face marker means two corners,
which is a line, and the flat-shaded filler has nothing to fill — a two-corner
face has no area. Across the four libraries that is 397 of 3,593 faces, and 27
of 299 models are mostly lines; those come out as a thin streak. Runway
markings and antennae are the likely subjects. Drawing them needs a line
routine the engine does not have.

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
