# Resource content formats

Builds on [ARCHIVE-FORMAT.md](ARCHIVE-FORMAT.md). Tool chain:

```bash
python tools/re/unpack.py --dir /path/to/retal --extract   # archive -> re/resources/
python tools/re/decompress.py --write                      # RLE     -> re/unpacked/
python tools/re/render.py re/unpacked/RETAL_00_01_t1.raw
```

## RLE compression

**Every** resource is compressed. The decompressor at `0xD409` runs in the
loader ahead of the type handler.

| Token | Meaning |
|---|---|
| `bb` (not `0x26`) | literal byte |
| `26 00` | literal `0x26` |
| `26 nn`, bit 7 clear, then `vv` | `(nn & 0x7F) + 2` copies of `vv`, and remember `vv` |
| `26 nn`, bit 7 set | `(nn & 0x7F) + 2` copies of the **last remembered** value |

The remembered value starts at 0, because the routine loads `bx` with `0x0026`
to get the escape byte into `bl` and initialises `bh` as a side effect.

Two traps that are easy to fall into when reimplementing this:

**The run length is `+2`, not `+1`.** The run path writes `cl` bytes via
`rep stosb` (`0xD429`), one more at `0xD42B`, and then falls through the
flag-setting `cmp` into the literal store at `0xD430`, which writes a third.

**`26 00` is a jump into the middle of an instruction.** `cmp ax, 0xC38A` at
`0xD42D` is the bytes `3d 8a c3`; entering at `0xD42E` executes `8a c3`, that
is `mov al, bl`, which puts the escape byte back in place to be stored.

Verification: with the `+2` correction, ten resources decompress to **exactly
32,000 bytes** = 320 x 200 x 4 bit. With `+1` they came out 300 to 600 bytes
short.

## Type handlers

The type from the index entry selects the post-processing (table at `0xD43A`).
Every handler tests `cs:[0xD5C8]`, the graphics adapter class, against 4.

| Type | Handler | Effect |
|---|---|---|
| 0 | `0xD524` = `ret` | none |
| 1 | `0xD448` | 4-plane interleaved -> chunky 4 bpp |
| 2 | `0xD456` | as type 1, different entry |
| 3 | `0xD496` | chunky 4 bpp -> bit-interleaved, word at a time |
| 4 | `0xD4C7` | `0xD4F2` plus a plane reorder |
| 5 | `0xD4F2` | type 1 or a plane reorder, depending on adapter |
| 6 | `0xD525` | composite resource, four sections |

### Type 1 — the main case

`0xD45E` reads **four consecutive bytes** and shifts them into pixels:

```
lodsw / xchg bx,ax      ; bl = byte0, bh = byte1
lodsw / mov dl,al       ; dl = byte2, ah = byte3
rol ax,1                ; byte3 MSB -> pixel bit 3
shl dl,1 / rcl al,1     ; byte2 MSB -> pixel bit 2
shl bh,1 / rcl al,1     ; byte1 MSB -> pixel bit 1
shl bl,1 / rcl al,1     ; byte0 MSB -> pixel bit 0
```

So four consecutive bytes are the four bitplanes of **the same eight pixels** —
byte-interleaved planar, exactly the arrangement the Atari ST uses. The pixel
value is `byte3<<3 | byte2<<2 | byte1<<1 | byte0`, MSB first.

Resolution **320 x 200, 16 colours** = 32,000 bytes, confirmed by the video
setup at `0x6388`:

```
6388  cmp byte [0xD5C8], 4
638D  jbe 0x63B8         ; adapter <= 4 -> mov ax,9  (Tandy 320x200x16)
638F  mov ax, 0x000D     ; otherwise BIOS mode 0Dh = EGA 320x200x16
6392  int 0x10
```

Verified by rendering: `RETAL.00` resource 1 is the title screen, resource 2 a
pilot portrait with helmet and oxygen mask.

### Palette

The table at `0xFC00` is `00 01 02 ... 0f` — the **identity palette**. `0x626D`
writes it as 20 registers to port `0x3C0`, the attribute controller, adding `ch`
to values of 8 and above (the EGA intensity bit).

There are **no** writes to the VGA DAC (`0x3C8`/`0x3C9`) anywhere in the code
reached so far, so the images use the stock EGA 16-colour palette. Further
register tables: `0xFBF0` (sequencer, port `0x3C4`) and `0xFBF6` (graphics
controller, port `0x3CE`).

### Type 3

`0xD496` reads **one word and writes one word**. It forms `dx = ax << 4` and
then interleaves the MSBs of `al`, `dl`, `ah` and `dh` into `bx` over four
passes; the loop ends when the sentinel bit `0x8000` falls out of `bx`, that is
after 16 shifts.

The source format is therefore **chunky 4 bpp**, two pixels per byte, not
planar.

### Type 6 — composite

`0xD525` calls four handlers with fixed lengths:

| Section | Length | Handler | Format |
|---:|---:|---|---|
| 1 | `0x2000` = 8,192 | `0xD448` | 4-plane interleaved |
| 2 | `0x2880` = 10,368 | `0xD456` | 4-plane interleaved |
| 3 | `0x0800` = 2,048 | `0xD448` | 4-plane interleaved |
| 4 | `0x3C00` = 15,360 | `0xD496` | chunky 4 bpp |
| | **35,968** | | |

`RETAL.01` resources 2 and 3 decompress to **exactly 35,968 bytes**. Resources
0 and 1 are shorter at 18,560 and 25,728; 18,560 is precisely sections 1 + 2, so
they evidently do not use every section.

The raw bytes bear the assignment out. Section 1 shows the pattern `X ff X 00`
throughout — four planes, two of them identical and one constant. Section 4
shows byte pairs such as `1f 1f`, `c0 c0`, `07 07`, matching the word
interleave.

## Resource inventory after decompression

| Resource | Type | Unpacked | Reading |
|---|---:|---:|---|
| `RETAL.00` 1, 2, 4, 5, 6, 7 | 1 | **32,000** | full screens, 320x200 |
| `RETAL.01` 4, 5, 6, 7 | 1 | **32,000** | full screens, 320x200 |
| `RETAL.01` 16, 17, 18 | 1 | 21,760 | 320x136 |
| `RETAL.00` 0 | 1 | 9,120 | 320x57 |
| `RETAL.00` 9 | 1 | 13,312 | 256x104 |
| `RETAL.00` 8 | 1 | 50,048 | more than one screen |
| `RETAL.01` 2, 3 | 6 | 35,968 | composite, all four sections |
| `RETAL.01` 0, 1 | 6 | 18,560 / 25,728 | composite, subset |
| `RETAL.01` 8-11 | 0 | 13,520-41,075 | model libraries, see [MODEL-FORMAT.md](MODEL-FORMAT.md) |
| `RETAL.01` 12-15 | 0 | 2,359-5,538 | object placement, see [WORLD-FORMAT.md](WORLD-FORMAT.md) |
| `RETAL.00` 15 | 0 | 7,839 | overlay code |

The type-0 resources come to 105,032 bytes unpacked and are the actual game
content.

## Open

- The sections of the type-6 resources do not form an image at 320 pixels wide.
  Correlation analysis gives 16 bytes per row (90.4 %), so 32-pixel tiles, but
  laying them out as a contact sheet produces no recognisable subject. Probably
  sprites with a header of their own.
- The odd type-1 sizes (9,120, 13,312, 50,048, 10,760) are not yet confidently
  matched to a resolution.
