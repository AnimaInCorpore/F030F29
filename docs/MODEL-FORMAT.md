# 3D model format — RETAL.01 resources 8-11

```bash
python tools/re/models.py                                    # resource 9
python tools/re/models.py --input re/unpacked/RETAL_01_10_t0.raw --start 0
python tools/re/models.py --obj re/unpacked/m0.obj            # export one model
```

## How these resources are loaded

The type-0 resources in `RETAL.01` are not loaded through
`mov ax,imm / call 0xD20B` the way the `RETAL.00` ones are, but through the
entry point `0xD20F`, where the caller sets `es` and `dx` itself. The sequence
sits at `0xECF1`-`0xED8C`:

| Resource | Load site | Parser | Content |
|---|---|---|---|
| 8 | `mov ax,0x208` at `0xECF1` | `0x75FC` | model library |
| 9 | `mov ax,0x209` at `0xED5B` | `0x431A` | model library |
| 10 | `mov ax,0x20A` at `0xED6F` | `0x438D` | model library |
| 11 | `mov ax,0x20B` at `0xED80` | `0x4490` | model library |
| 12 | `mov ax,0x20C` at `0xECE0` | — | object placement, see [WORLD-FORMAT.md](WORLD-FORMAT.md) |

All four of 8-11 parse with the same model grammar, so the differing parsers
are about where the models are filed, not how they are encoded. `0x431A` in
particular is not the geometry reader at all: it builds a linked structure per
entry and writes three words to `[bp+0x0E]`, `[bp+0x12]`, `[bp+0x16]` — that is
object *instancing* with a position.

## Format

```
byte          vertex count minus one
n * 6 byte    vertices: X, Y, Z as signed 16-bit little endian
face records  marker, colour byte, then one 16-bit word per corner
```

The **marker encodes the corner count** in steps of four, so
`corners = (marker >> 2) - 6` and a record is `2 + 2 * corners` bytes:

| Marker | Corners | Record length |
|---|---:|---:|
| `0x24` | 3 | 8 bytes |
| `0x28` | 4 | 10 bytes |
| `0x2C` | 5 ? | 12 bytes ? |

The words in a face record are **byte offsets** into the vertex array, not
indices — vertex *k* sits at offset `6k`.

## Evidence

**Quad.** The first face record `28 10 30 00 36 00 3c 00 42 00` references
offsets 48, 54, 60 and 66, which are vertices 8 to 11 — exactly the four points
`(±100, 130, ±100)`, a square.

**Triangle.** `24 16 00 00 1e 00 12 00` is followed immediately by a record
starting `28 05`. That only works out if the `0x24` record carries exactly
three words.

**Vertex data.** The first eight vertices of the first model are
`(±50, ±130, ±45)` — an axis-aligned box, readable as such straight from the
hex dump.

**Rendered.** Two wireframes were checked. Model 2 (40 vertices, 25 faces) is a
tower on an octagonal base with a ground plate; model 9 (94 vertices, 24 faces)
is an airfield plan with a long runway and taxiways. Both are fully coherent.

## Results

| Resource | Bytes | Models | Vertices | Faces |
|---|---:|---:|---:|---:|
| 8 | 13.520 | 18 | 401 | 164 |
| 9 | 41.075 | 140 | 2.492 | 1.137 |
| 10 | 21.065 | 43 | 978 | 275 |
| 11 | 13.268 | 32 | 955 | 279 |
| **total** | | **233** | **4.826** | **1.855** |

Across resource 9: 332 triangles, 804 quads, 28 distinct colour indices.
Extents are plausible — `200x260x200` for buildings, `1200x0x2600` for flat
runways, `40x100x30` for small objects.

Resources 8, 10 and 11 have a header of roughly 42 bytes before the first
model; in resource 9 the first model starts at `0x28`. The header is not
decoded. It is not an offset table: reading it as words gives values well past
the end of the resource.

## Open

**About 36 % of resource 9 (14,829 bytes in 139 gaps) is still not parsed.** The
markers that abort a model show why: besides `0x00` (95 times, the regular
terminator) there are `0x2C` (24), `0x1C` (14) and a few `0x28`, `0x24`, `0x20`.
Where the marker is one of the confirmed ones the abort comes from the
reference check instead, so some faces evidently point at vertices outside their
own array — shared points, presumably.

For `0x2C` and `0x1C` the formula `(marker >> 2) - 6` is extrapolated, not
proven. It would make `0x1C` a face with a single corner, which is meaningless,
so that is probably a different record type — a line, a normal vector, or an
object header.

The way in is the parser at `0x431A` and the routines it calls, `0x446A`,
`0x451A` and `0x44F8`, which have only been skimmed.
