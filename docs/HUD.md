# The flight HUD

The first piece of task 7 (HUD, cockpit, menu system). `src/hud.s` draws three
numeric fields — airspeed, altitude, heading — straight into `work_screen`
once a frame, using the same 4x5 hex-digit font `f29.s` already had for its
debug readout.

## What it draws, and why there are no labels

Airspeed bottom left, altitude bottom right, heading top centre as a compass
bearing — no text labels. That is a real HUD convention, not a shortcut: a
pilot learns the fixed positions and doesn't need to read "SPD" every time,
and it sidesteps a genuine constraint here, which is that the only font in
the tree is hex digits. Extending it to letters is possible later if a labelled
layout turns out to matter more than screen space.

None of the cockpit artwork, icon set or exact panel layout documented in
[GAME-LOOP.md](GAME-LOOP.md) from the reverse-engineering side is reproduced
here — that work exists to understand what the original shows and where the
values come from, not to be redrawn pixel for pixel. This HUD is a fresh
design against the same underlying data.

## The numbers are placeholders

`hud_airspeed`, `hud_altitude` and `hud_heading` are driven by `frame_count`
in `hud_draw`, not by a flight model — there isn't one in 68k yet (task 6).
The formulas exist only to produce visibly live, independently checkable
numbers:

```
airspeed = 3200 + frame_count            (then displayed >> 3)
altitude = 3000 + (frame_count >> 2)     (then displayed << 2)
heading  = (1024 + frame_count) & $7FF   (then converted to a bearing)
```

Wiring these to the real simulation is follow-on work once task 6 lands —
`hud_airspeed`/`hud_altitude`/`hud_heading` are the integration point, and
their units already match, see below.

## What is faithful to the original already

Three things carry over from the disassembly work directly, because they cost
nothing to get right immediately and having the port match now avoids a
conversion step later:

- **The units.** Airspeed 8 per knot, altitude 4 ft per unit, heading 2048
  units to the circle — all established in
  [FLIGHT-MODEL.md](FLIGHT-MODEL.md).
- **The starting values.** 3200 (400 kt), 3000, 1024 (due south) are the
  same numbers the original initialises to (`0xEF92`, `0x4E97`, `0xEF06`).
- **The heading-to-bearing conversion.** The original's instrument routine
  (`[0xAE4C]` in [GAME-LOOP.md](GAME-LOOP.md)) multiplies the 11-bit heading
  by `0x2D00` and takes the high word — since `2048 * 0x2D00 / 65536 = 360`
  exactly, that turns the angle into degrees in one multiply — then negates
  and adds 360, except zero stays zero, to turn a mathematical angle into a
  compass bearing. `hud_draw` does the same multiply and the same
  zero-guarded negate.

## `print_value_dec`

`f29.s`'s existing `print_value` prints hexadecimal, which is fine for a
debug tool but wrong for a cockpit readout. `hud.s` adds a decimal
equivalent, same shape: `divu #10` in place of a nibble mask, building digits
least-significant-first and drawing right to left back to the caller's
anchor (the field's leftmost pixel).

One real bug surfaced building this, worth recording: `neg`/`add`/`tst`
without an explicit size default to a word in this assembler, which is what
was wanted here since the heading-to-degrees value sits in `d0`'s low word
after a `swap` — but it is exactly the kind of thing that silently does the
wrong size on a different assembler or a copy-pasted instruction elsewhere,
so the working version spells `.w` on all three regardless. Two apparent
follow-on bugs after that turned out not to be bugs at all — "913" and
"12352" were misreadings of "013" and "12952" in a 4-pixel-tall font at
thumbnail scale; cropping and upscaling the actual PNG output settled it.
Worth remembering before chasing a discrepancy in anything this font prints.

## Verifying it

```bash
./tools/build-run.sh
bash tools/grab-frame.sh 1500 build/frame.png
```

The three fields should be mutually consistent — each can be inverted back to
a `frame_count` value, and all three should agree — which is a cheap
correctness check that does not depend on reading the tiny font precisely
(crop and upscale the PNG for that, given the misreadings above). At VBL 1500
in the build this was written against: airspeed 456, altitude 12452, heading
101, all consistent with `frame_count` in the low 450s.

## Open

- Cockpit panel (gauges, icons, static artwork) and the menu system are the
  rest of task 7, not started.
- No line primitive exists yet ([ENGINE.md](ENGINE.md), task 16), which the
  cockpit panel's bezel work will likely want — the original's own panel
  renderer is vector-based, see `0x0A72` in [GAME-LOOP.md](GAME-LOOP.md).
- The font is hex-digit-only, 4x5 pixels. Fine for numbers, not for labels if
  a labelled layout is wanted later.
- `hud_draw` runs every frame unconditionally; the original gates its HUD
  behind game state 12 ([GAME-LOOP.md](GAME-LOOP.md)) and view-mode states
  4-9 show it alongside a camera label. There is only one state here so far.
