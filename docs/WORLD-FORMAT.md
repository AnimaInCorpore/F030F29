# World object placement — RETAL.01 resources 12-15

```bash
python tools/re/objects.py                       # summarise all four
python tools/re/objects.py --resource 12 --dump 20
```

## Record layout

The walker at `0x438D` in `X.EXE` steps `add si, 7` and tests each record's
first byte against `0xFF`, which gives the layout directly:

```
byte    object type - selects a model from the model libraries
word    X, signed 16-bit little endian
word    Y, signed 16-bit little endian  (altitude)
word    Z, signed 16-bit little endian
```

A `0xFF` byte where a type would be terminates the current group.

## Why this alignment is right

If the stride were wrong the altitude column would be uniformly spread over the
full 16-bit range. It is not — it collapses onto a handful of small values:

| Resource | Y = 0 | Y = -10 | Y = -25 | Y = -50 |
|---|---:|---:|---:|---:|
| 12 | 272 | 30 | — | 106 |
| 13 | 64 | 21 | 54 | 29 |
| 14 | 264 | 146 | 18 | — |
| 15 | 285 | 164 | — | 65 |

In resource 12 that is 272 of 530 records at exactly zero. X and Z do span the
full range, which is what world coordinates on a wrapping map look like.

## Structure

Each resource holds one large group followed by many small ones:

| Resource | Bytes | Records | Groups | First group | Remaining groups |
|---|---:|---:|---:|---:|---|
| 12 | 3.718 | 530 | 8 | 441 | 2-47 records |
| 13 | 2.359 | 335 | 14 | 185 | 2-59 records |
| 14 | 4.489 | 637 | 30 | 381 | 2-26 records |
| 15 | 5.538 | 785 | 43 | 459 | 2-28 records |

The reading that fits: **group 0 is the permanent scenery of a theatre, and each
later group is one mission's own objects.** That matches how `0x438D` selects a
group, indexing with `[0xF3A2]` and `[0xE993]` rather than reading sequentially,
and it matches the game having four theatres with differing mission counts —
the base lists at `0x734A` in `X.EXE` name `GROOM LAKE` / `MONUMENT VALLEY`,
`USAF ST. MARTIN` / `TER-HAD-A-DAR`, `USAF RAMSTEIN` / `RAF BINDER` / `BRESDEN`
and so on.

Each resource ends with one trailing byte that is not part of a record.

## Object types

75 to 83 distinct type bytes per resource. The common ones split into two bands:
small values (`0x00`, `0x02`, `0x03`, `0x04`, `0x0D`) and a higher band
(`0x4B`, `0x4D`, `0x52`, `0x53`, `0x63`). Which band indexes which of the four
model libraries in resources 8-11 is not yet established.

The first records of resource 12 show the pattern clearly:

```
type 63  X= -11767  Y=     0  Z=  20659
type 63  X= -11317  Y=     0  Z=  20664
type 63  X=  21559  Y=     0  Z= -30477
type 63  X=  21106  Y=     0  Z= -30475
type 52  X=   3956  Y=   -50  Z=  28298
type 52  X=   3204  Y=   -50  Z=  30058
```

Type `0x63` appears in pairs a few hundred units apart at ground level — runway
ends, most likely. Type `0x52` runs as a long chain at a constant -50.

## Open

- The mapping from type byte to model library and model index.
- Whether groups are indexed by mission number directly or through a table.
- Resources 13-15 have not been cross-checked against the theatre they belong
  to; the assignment of resource to theatre is still a guess.
