# 3D model format — RETAL.01 resources 8-11

```bash
python tools/re/models.py                                     # resource 9
python tools/re/models.py --input re/unpacked/RETAL_01_10_t0.raw --start 0
python tools/re/models.py --obj re/unpacked/m0.obj             # export one model
```

## How these resources are loaded

The type-0 resources in `RETAL.01` are not loaded through
`mov ax,imm / call 0xD20B` the way the `RETAL.00` ones are, but through the
entry point `0xD20F`, where the caller sets `es` and `dx` itself. The sequence
sits at `0xECF1`-`0xED8C`:

| Resource | Load site | Parser | Content |
|---|---|---|---|
| 8 | `mov ax,0x208` at `0xECF1` | — | model library |
| 9 | `mov ax,0x209` at `0xED5B` | `0x431A` | model library |
| 10 | `mov ax,0x20A` at `0xED6F` | `0x438D` | model library |
| 11 | `mov ax,0x20B` at `0xED80` | `0x4490` | model library |
| 12 | `mov ax,0x20C` at `0xECE0` | — | object placement, see [WORLD-FORMAT.md](WORLD-FORMAT.md) |

`0x75FC`, the call that follows loading resource 8, is *not* a parser — it is a
per-theatre parameter lookup over a table of 6-byte records indexed through
`[0xE993]`. Resource 8's parser has not been identified.

All four of 8-11 parse with the same grammar, so the differing parsers are
about where the models are filed, not how they are encoded. `0x431A` in
particular is not the geometry reader: it builds a linked structure per entry
and writes three words to `[bp+0x0E]`, `[bp+0x12]`, `[bp+0x16]` — that is
object *instancing* with a position. `0x451A`, which it calls per entry, clears
`0x33` = 51 bytes, so the runtime object structure is 51 bytes wide. `0x446A`
is the walker for the 7-byte placement records and builds a lookup at
`ss:[type*2]`.

**Records can cross-reference each other.** `0x4490` (resource 11's loader)
reads a source record's own fields at `+0x1C` and `+0x22`; when either is
negative, it is a tagged index rather than a plain value, and the loader
resolves it into the record's own just-assigned load address, written into a
shared table at `0x2EB6`. A runtime scan (`0x9811` in
[GAME-LOOP.md](GAME-LOOP.md)) reads the same table back to follow a loaded
object's reference to another one. What the reference is *for* — attachment,
tracking, a chain of some kind — is not established, only that the mechanism
exists and where it lives.

## Format

```
byte          vertex count minus one
n * 6 byte    vertices: X, Y, Z as signed 16-bit little endian
face records  see below, terminated by a 0x00 byte
```

The words in a face record are **byte offsets** into the vertex array, not
indices — vertex *k* sits at offset `6k`.

## Face records

The marker is **not** an encoded corner count. Every marker observed is a
multiple of four and none relates arithmetically to the number of corners, so
it is a byte offset into a primitive-type dispatch table in the renderer, and
each primitive brings its own record layout.

| Marker | Corners | Colour | Refs from | Extra | Size |
|---|---:|---|---|---|---:|
| `0x04` | 3 | byte 1 | byte 2 | — | 8 |
| `0x14` | 3 | **none** | byte 1 | one trailing word | 9 |
| `0x1C` | 2 | byte 1 | byte 2 | — | 6 |
| `0x20` | 1 | byte 1 | byte 2 | one parameter word | 6 |
| `0x24` | 3 | byte 1 | byte 2 | — | 8 |
| `0x28` | 4 | byte 1 | byte 2 | — | 10 |
| `0x2C` | byte 1 | byte 2 | byte 3 | — | 3 + 2n |

`0x2C` is the escape for anything above four corners; counts of 5, 6, 7 and 8
occur.

None of this is guessed. Every layout was checked against every occurrence: the
refs come out as multiples of six lying inside the model's own vertex array,
and the byte following the record is always a valid marker or the `0x00`
terminator.

- `0x2C`: 24 of 24 sites in resource 9 check out.
- `0x20`: three consecutive records at `0x46e3` — `20 0b b4 00 c0 12`,
  `20 0c ba 00 c0 12`, `20 0d c0 00 c0 12` — with refs 180, 186 and 192, which
  are vertices 30 to 32 of a 33-vertex model, and an identical trailing value.
  One vertex plus a parameter is what a sphere, light or flare looks like.
- `0x14`: four consecutive records at `0x039d` in resource 8, refs 426/432/438
  twice then 462/468/474 and 444/450/456, all inside a 112-vertex model, with
  differing trailing words.
- `0x04`: at `0x10b7`, colour `0x02`, refs 522/528/534, followed by a valid
  `0x2C`.

## Evidence for the overall grammar

**Quad.** The first face record `28 10 30 00 36 00 3c 00 42 00` references
offsets 48, 54, 60 and 66, which are vertices 8 to 11 — exactly the four points
`(±100, 130, ±100)`, a square.

**Triangle.** `24 16 00 00 1e 00 12 00` is followed immediately by a record
starting `28 05`, which only works out if the `0x24` record carries exactly
three words.

**Vertex data.** The first eight vertices of the first model are
`(±50, ±130, ±45)` — an axis-aligned box, readable straight from the hex dump.

**Rendered.** Model 2 of resource 9 (40 vertices, 26 faces) is a tower on an
octagonal base with a ground plate; model 9 (94 vertices) is an airfield plan
with a long runway and taxiways. Both are fully coherent, and adding the new
primitives changed neither.

## Results

| Resource | Bytes | Models | Vertices | Faces | Unparsed |
|---|---:|---:|---:|---:|---:|
| 8 | 13,520 | 24 | 689 | 306 | 48.3 % |
| 9 | 41,075 | 184 | 3,011 | 1,902 | 13.1 % |
| 10 | 21,065 | 47 | 1,452 | 805 | 22.0 % |
| 11 | 13,268 | 44 | 1,079 | 580 | 9.1 % |
| **total** | 88,928 | **299** | **6,231** | **3,593** | **20.0 %** |

Corner counts across all four: 10 points, 397 lines, 825 triangles, 2,190
quads, 110 pentagons, 51 hexagons, 8 heptagons, 2 octagons.

Extents are plausible — `200x260x200` for buildings, `1200x0x2600` for flat
runways, `40x100x30` for small objects.

Resources 8, 10 and 11 have a header of roughly 42 bytes before the first
model; in resource 9 the first model starts at `0x28`. The header is not
decoded. It is not an offset table: reading it as words gives values well past
the end of the resource.

## Open

**20 % of the model data still does not parse**, and resource 8 is the worst at
48 %. The cause is now clear and it is not the grammar: further primitive types
exist whose record layout is unknown. `0x0C` is the most frequent — it stalls
the 112-vertex model at `0x00FC` in resource 8 after only four faces, and no
combination of header size and corner count produces valid refs for it.

Guessing further layouts from byte patterns has reached its limit. The way
forward is the renderer's dispatch table in `X.EXE`: since the marker is a byte
offset into it, finding that table yields every primitive's handler at once, and
each handler states its own record layout. Candidate indirect sites not yet
examined are `jmp word ptr [bx+si+5]` at `0xB398` and `call word ptr [bx+0xE]`
at `0xB08F`.

Also open:

- The ~42-byte header ahead of the first model in resources 8, 10 and 11.
- The mapping from an object type byte in the placement lists to a model
  library and an index within it.
- A handful of models abort on the reference check with refs that are valid
  multiples of six but point past the vertex count. These are false starts by
  the scanner rather than a format question — it walks byte by byte after a
  failure and can lock onto a wrong offset.
- Raising `COORD_LIMIT` from 20,000 to the full 16-bit range drops the gaps to
  about 3 % but cuts the model count roughly in half, because the scanner then
  swallows whole regions as single bogus models. That is a worse result, not a
  better one, so the limit stays.
