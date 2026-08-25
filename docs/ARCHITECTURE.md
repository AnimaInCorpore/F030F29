# Architecture

## Fidelity boundary and provenance

The DOS authority for behavioural work is `X.EXE`, SHA-256
`e47717e4dc5f3903a45aa305a1839e21be0e030439984230513cac5ddd259b2c`. The
simulation side must preserve the original widths and tables: the flight model
uses 8.8 frame timing, a 1024-entry signed sine table, and 10-bit angles
pre-doubled when indexing that table (see [FLIGHT-MODEL.md](FLIGHT-MODEL.md)).
Those conventions are not interchangeable with the renderer's convenient
fixed-point representation.

The geometry path currently in `src/` is explicitly a **Target artefact**. It
is a Falcon implementation adapted from the sibling reference
`f030dsp3d/src/3d.asm`, SHA-256
`3caaca03b21171667b2cda33c65cdc813b9d8c4d6d1df049ce620d4a372e2ec0`, not a
translation of DOS `0x1F3A`'s rotation builder or `0x3160`'s object sorter.
The CPU path uses Q1.23 values and tenth-degree angles; the DSP path uses its
own 24-bit fixed-point representation. Neither claims DOS simulation
fidelity. The preserved observable contract is the logical span list consumed
by the Falcon filler:

| Path | Classification | DOS canonical range | Contract / evidence |
|---|---|---|---|
| `src/cpu3d.s` | Target artefact | N/A - platform replacement | transformed, clipped, projected span data; checked against the sibling geometry design |
| `src/dsp/3d.asm` | Target artefact | N/A - platform replacement | same span-list contract; adapted for 320x240; sibling design reference above |
| `src/dp_hc.s` | Target artefact | N/A - platform replacement | span list to RGB565 framebuffer; verified by the golden-frame hash in [ENGINE.md](ENGINE.md) |

The flight-state seam now sits beside this renderer boundary in `src/flight.s`.
It preserves the DOS-width fields and 8.8/clamped frame timing, uses the exact
DOS sine and manoeuvre tables copied into `src/flight_tables.s`, and ports the
scalar thrust/drag, attitude and 16.16 position updates. Active flight state is
also converted into the renderer's camera position and orientation. The speed
reference/ceiling tables, device flags and stall/departure side effects remain
open; a renderer match is not evidence that those parts of the numeric model
are original.

## Splitting work between the 68030 and the DSP56001

The sibling project [`f030dsp3d`](../../f030dsp3d) contains a complete, working
3D engine for the Falcon — own code, originally from 1994. It is the basis for
this port. Its division of labour suits a flight simulator almost perfectly,
because nearly the whole geometry pipeline sits on the DSP and the 68030 is left
with nothing but filling.

### DSP56001 (32 MHz, 24-bit fixed point)

From `f030dsp3d/src/3d.asm` (2,591 lines), in pipeline order:

| Stage | Line | Task |
|---|---|---|
| Rotation matrices | 2371 | camera, object and combined matrix from a sin/cos table |
| Rotate and translate | 2546 | transform the point array |
| 3D clipping | 2002 | clip polygons against the z plane |
| Perspective projection | 1936 | 3D to 2D |
| BSP sorting | 2201 | face ordering via a BSP tree |
| 2D clipping | 1108 | Sutherland-Hodgman, ring buffer must live at `x:$0` |
| Polygon conversion | 1882 | prepare the polygon structure for the filler |
| Left/right table | 583 | edge table per scanline — the 68030 receives finished spans |
| Texture gradients | 884 | gradients of a face in screen space |

The DSP therefore hands the 68030 **finished span lists**. The CPU does no
geometry, no sorting, no clipping.

The original DOS game, having no DSP, does the first and fifth of these on its
8086: `0x1F3A` builds a 3x3 rotation matrix from three angles against the same
kind of sin/cos table (verified numerically — orthonormal, determinant 1 for
arbitrary angles), and `0x3160` sorts objects into a binary search tree keyed
on position, a coarser whole-object counterpart to the DSP's per-face BSP.
See [GAME-LOOP.md](GAME-LOOP.md).

Memory layout (DSP SRAM, 32K words of 24 bit):

```
p:$0       reset vector -> main
p:$22      host transmit data empty interrupt
x:$0       2D clipping ring buffer (30*2 words) - address is fixed in hardware
x:$200     clip bounds, object matrix, position vectors
           array_2d_point / array_vector_point   (MAX_POINTS   = 2000, x3)
           array_polygon_sorted                  (MAX_POLYGONS = 1000, x7)
y:$800     clip edges, screen offsets, light vector, camera, viewer,
           object header, sin/cos table
```

These budgets need checking for F29: terrain with a long view distance produces
considerably more polygons than the single object in `f030dsp3d`. The model
libraries extracted so far total 233 models with 4,826 vertices and 1,855 faces
(see [MODEL-FORMAT.md](MODEL-FORMAT.md)), and a mission places several hundred
object instances (see [WORLD-FORMAT.md](WORLD-FORMAT.md)).

### 68030 (16 MHz)

From `f030dsp3d/src/dp_hc.s` (1,037 lines) and `dsp3d.s` (1,172 lines):

- **`draw_poly_hc_l`** — span filler driven by the **blitter**. The trick:
  `HOP=%01` (source is the halftone register), `OP=%0011` (destination is
  source), `Dst_Xinc=0`, `Dst_Yinc=2`, `X_Count=1`. That turns `Y_Count` into
  the span length and the blitter fills a horizontal run of 16-bit pixels, with
  the colour held in the halftone register. Up to 65,535 pixels per blit.
- **`draw_quad_tex` / `draw_poly_tex`** — textured faces, on the CPU.
- **Double buffering** — `work_screen` and `display_screen` are swapped.
- **Dirty-range clear** (`clear_screen4`) — `screen_low_high_work` records the
  touched min/max address and only that range is cleared. For a flight
  simulator with a sky/ground background this may well be moot, since the frame
  gets overwritten wholesale anyway. Measure it.
- Keyboard, VBL, object loader.

## Video mode

The target is **320x240 True Color**; `f030dsp3d` runs at 300x224 True Color.
The difference is constants in two places:

- `src/dsp/3d.asm`: `SCREEN_WIDTH` / `SCREEN_HEIGHT`
- `src/dp_hc.s`: `SCREEN_WIDTH` / `SCREEN_HEIGHT`

### Bandwidth

The main bottleneck on a 16 MHz Falcon is the 16-bit ST-RAM bus, shared between
CPU, blitter and VIDEL. Screen memory has to live in ST-RAM because VIDEL can
only DMA from there, and a 4 MB Falcon has no fast RAM anyway.

| Mode | Bytes per frame | VIDEL refresh at 60 Hz |
|---|---:|---|
| 320x240 True Color | 153,600 | ~9.2 MB/s |
| 300x224 True Color (f030dsp3d) | 134,400 | ~8.1 MB/s |
| 320x240, 8 bit | 76,800 | ~4.6 MB/s |

True Color costs roughly double the refresh bandwidth of 8 bit, but saves the
C2P conversion entirely and keeps the rasterizer linearly addressable.

### Falling back to 8 bit

If the frame rate does not hold up, the switch to 8 bit plus DSP C2P should stay
local. For that:

- Express pixel width only through a constant (`BYTES_PER_PIXEL`), never a
  literal `2` in the code.
- Route colour values through an indirection (`colour_table`) rather than
  putting RGB straight into the halftone register.
- The blitter span filler does not survive the switch unchanged — 8 bit is
  planar. The filler's interface (input: the left/right table from the DSP)
  stays the same though; only the implementation behind it is swapped.

## Source data

The original artwork is byte-interleaved planar, which is the Atari ST's native
arrangement, and the type-1 loader in the DOS version already demonstrates the
conversion to chunky — the direction this port needs. See
[RESOURCE-FORMATS.md](RESOURCE-FORMATS.md).

Conversion belongs in an offline asset build, not at run time, and has to be
field-aware: a blanket 16-bit byte swap would destroy bitmaps, text and RLE
streams, where byte order is structural rather than numeric. Alignment matters
as much as endianness — the 68000 traps on odd word accesses and the 68030 pays
in cycles. The 24-bit offsets in the archive index should widen to 32 bit;
`move.l` is one instruction instead of three.

Since converted assets may not be redistributed, the converter has to run on the
user's machine, at install time or first launch with a cache.

## Self-modifying code does not come across

The original keeps its hot state — airspeed, altitude, both control axes — in
the immediate operands of the instructions that read it. On an 8086 that is
faster than a memory operand. On the 68030 it is a liability: every write into
the instruction stream needs the instruction cache invalidated, and a missed
invalidation gives a fault that only appears when the line happens to be
cached.

So these do not get translated literally. Each becomes an ordinary variable,
and each patch becomes a normal store. That costs a few cycles per access and
saves the cache maintenance, which is more expensive, as well as keeping the
code debuggable. It is a deliberate departure from the 1:1 rule, and the
inventory of what has to be converted is in [GAME-LOOP.md](GAME-LOOP.md).

## Build

No `make` on the development machine. The build is bash scripts, as in
`f030dsp3d`:

- `tools/build-run.sh` — vasm per source file, then vlink to `.TOS`
- `tools/build-dsp.sh` — ASM56000 under DOSBox (DOS4GW, needs 8.3 names), then
  CLDLOD to `.LOD`
- `tools/run.sh` — Hatari with a Falcon machine and DSP emulation

vlink is invoked as `-tos-fastload -b ataritos -e start`, vasm as
`-Felf -m68030`. Every tool path can be overridden by an environment variable;
see the README.
