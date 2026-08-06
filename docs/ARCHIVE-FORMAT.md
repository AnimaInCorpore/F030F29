# Archive format — RETAL.00 / RETAL.01

Fully decoded and verified. Extractor: `tools/re/unpack.py`.

```bash
python tools/re/unpack.py --dir /path/to/retal --extract
```

## Structure

The archives have **no header of their own**. The index lives inside `X.EXE`.

A word array at `0xD3A5` holds one pointer per archive file. It has exactly two
entries — `0xD3A9` is already the `int 21h` wrapper, and that bounds the table:

| Address | Value | Archive |
|---|---|---|
| `0xD3A5` | `0xFC4A` | `RETAL.00` |
| `0xD3A7` | `0xFC8E` | `RETAL.01` |

Each pointer leads to an array of **4-byte entries**:

```
byte 0..2   file offset, 24-bit little endian
byte 3      resource type
```

The **length** of a resource is `offset[i+1] - offset[i]`, so each array carries
one extra sentinel entry whose offset equals the file size — and only that
sentinel bounds the table, since the entry count is stored nowhere.

Both sentinels match exactly:

| Archive | Sentinel | File size | Resources |
|---|---:|---:|---:|
| `RETAL.00` | 239,200 | 239,200 | 16 |
| `RETAL.01` | 359,172 | 359,172 | 19 |

The resources sum to 598,372 bytes, the size of both files together. No gaps,
no overlaps.

## Resource numbers

The number the game uses is 16 bits wide (loader at `0xD2F0`):

```
D2F0  mov bx, <resnum>      ; immediate is written by 0xD20F
D2F3  mov si, 0x01FF
D2F6  and si, bx            ; si = resnum & 0x1FF        -> index
D2F8  xor bx, si            ; bx = resnum & 0xFE00
D2FA  xchg bl, bh           ; bx = (resnum & 0xFE00) >> 8 -> archive select
D2FC  shl si, 1
D2FE  shl si, 1             ; si = 4 * index
D300  add si, [bx-0x2C5B]   ; + pointer from the table at 0xD3A5
D304  lodsw / mov dx,ax     ; dx  = offset bits 0..15
D307  lodsw                 ; al  = offset bits 16..23
D30A  mov cl, al            ; cx:dx = 24-bit offset for LSEEK
D30C  mov [0xD2CF], ah      ; type byte -> immediate of `mov bx,imm` at 0xD2CE
```

- **Bits 0..8**: index within the archive, so up to 512 resources
- **Bits 9..15**: archive select — `0x0000` is `RETAL.00`, `0x0200` is `RETAL.01`

`AX = 0x000F` therefore means `RETAL.00`, resource 15.

## Resource type

The type byte is written at `0xD30C` **straight into the immediate** of
`mov bx,imm` at `0xD2CE`, masked there with `and bl,0x0F / shl bl,1`, and used
to dispatch through the 7-entry table at `0xD43A`. The type selects the
post-processing applied at load time — see
[RESOURCE-FORMATS.md](RESOURCE-FORMATS.md).

## The overlay: RETAL.00 resource 15

The only executable resource. It is loaded into segment table slot 8 at startup
(a 7,840 byte buffer for a 7,081 byte resource) and called at offset 0 through
`lcall [0xFC14]`. The entry point is a textbook driver prologue:

```
0000  pushf
0001  push ds / bx / bp / es / cx / si / di
0008  mov  bx, cs
000A  mov  ds, bx
000C  mov  es, bx              ; DS = ES = CS, self-contained
000E  sub  bh, bh
0010  mov  bl, ah              ; AH is the function code
0012  shl  bl, 1
0014  cld
0015  call word ptr [bx+0xC5E] ; dispatch
```

That confirms the convention inferred from the call sites: **`AH` selects the
function, `AL` carries the parameter.** Observed calls: `0x06FF`, `0x0100`,
`0x05A0`, `0x0101`.

**Open:** the jump table is not statically at offset `0xC5E` — the values there
are not valid code pointers, and searching for a run of plausible pointers turns
up only a repeating four-value data pattern at `0x18E4`. So the displacement is
adjusted at run time, or `DS` does not point at the start of the resource when
the dispatch happens. This needs settling before the 35 `lcall [0xFC14]` sites
can be resolved.

The other type-0 resources, in `RETAL.01`, are **not** executable — there is no
sensible code at their offset 0. Type 0 means "load verbatim", not "is code".
