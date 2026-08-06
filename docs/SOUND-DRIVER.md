# The overlay: sound and music driver

`RETAL.00` resource 15, 7,081 bytes packed and 7,839 unpacked. The only
executable resource in either archive. `X.EXE` loads it into segment table slot
8 at startup and calls it through `lcall [0xFC14]`.

```bash
python tools/re/overlay.py
```

## The mistake that made this look unresolvable

The overlay's dispatch table sits at offset `0xC5E`, and reading it in the
**packed** resource yields values that are not code pointers at all. That is
what stalled this for a while.

The packed stream happens to begin with bytes that contain no `0x26` escape, so
the first instructions decode correctly and there is nothing to suggest you are
looking at compressed data. Everything further in is shifted. Read the
decompressed resource and all 23 entries are valid.

## Calling convention

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

**`AH` selects the function, `AL` carries the parameter.** The table has 23
entries, `AH` = 0 to 22; entry 23 points outside the resource and bounds it.

## Hardware

Port constants across the whole overlay:

| Port | Device |
|---|---|
| `0x388` | AdLib / OPL2 address |
| `0x331` | MPU-401 status — the MT-32 path |
| `0x61` | PC speaker gate |
| `0x42`, `0x43` | PIT channel 2, the speaker's tone generator |

That matches the launcher shipped with the game, whose `run.bat` offers
"F29 Retaliator w/ SoundBlaster" and "w/ MT-32" and sets `mpu401` and
`mididevice` accordingly.

## Function table

| AH | Entry | Opening instructions |
|---:|---|---|
| 0 | `00D1` | `mov di,0x9B0 / test byte [di+4],0xC0` |
| 1 | `0049` | `mov bx,0x134D / mov dh,0xFF` |
| 2 | `0356` | clears `[0x148]`, `[0x755]`, `[0x1B0]` — reset |
| 3 | `0029` | `mov [0x14F],al / ret` |
| 4 | `0022` | `mov al,[0x148] / ret` |
| 5 | `002D` | `mov [0x207],al / mov di,0x9B0 / cli` |
| 6 | `040C` | `and al,0x30 / inc ax / call 0x356` |
| 7 | `0384` | `xor ah,ah / mov si,0x1E9E / add si,ax` |
| 8 | `03C4` | `call 0x3F9 / and byte [di+4],0x3F` |
| 9 | `03E0` | `call 0x3F9 / mov [di+8],dx` |
| 10 | `03D5` | `call 0x3F9 / mov al,[di+4]` |
| 11 | `03E7` | `mov ch,al / call 0x3F9 / mov [di+0xB],ch` |
| 12 | `1E9E` | `ret` — the table at `0x1E9E`, so an empty slot |
| 13 | `0C8C` | `push dx / call 0xD4A` |
| 14 | `0D0A` | `mov di,0xE2C / mov cx,2` |
| 15, 16 | `0C92` | `mov bl,dl / shl bl,1 / mov di,[bx+0xE5C]` |
| 17, 18 | `0E16` | same channel lookup |
| 19 | `0E26` | `mov [0xE63],al / ret` |
| 20 | `0D22` | `mov [0xE62],al / or al,al` |
| 21 | `0E83` | `mov bl,al / shl bl,1 / mov di,[bx+0xE5C]` |
| 22 | `0E64` | same, different entry |

Two subsystems are visible. Functions 0 to 11 work on a structure at `0x9B0`
with fields at `+4`, `+8`, `+0xB` and `+0x18`, reached through the helper at
`0x3F9`. Functions 13 to 22 index a pointer table at `0xE5C` by a channel
number. Function 1 walks a table at `0x134D`, function 7 one at `0x1E9E`.

## Calls from X.EXE

40 sites. 25 load `AX` from an immediate close enough to attribute statically:

| AH | Calls | AL values | Reading |
|---:|---:|---|---|
| 1 | 10 | `0x00`-`0x05` | six distinct tracks — **start music** |
| 5 | 6 | `0xA0`, `0xB4`, `0xC8`, `0xDC`, `0xF0` | **sound effect**, evenly spaced ids |
| 6 | 2 | `0x00`, `0xFF` | paired, and `0x06FF` is the very first call made at startup — **init and shutdown** |
| 16 | 2 | `0x00`, `0x04` | channel operation |
| 20 | 2 | `0x00`, `0xFF` | paired — enable and disable |
| 21 | 2 | `0x00` | channel operation |
| 22 | 1 | `0x01` | channel operation |

At the remaining 15 sites `AX` is computed rather than loaded as a constant, so
the function varies at run time.

The startup sequence at `0x009C` onwards reads cleanly with this: `AH=6 AL=0xFF`
to initialise, then `AH=1 AL=0x00` to start the title music, then a run of
`AH=5` effect calls during the intro.

## The music data

It is inside the overlay, not somewhere else as first assumed. Function AH=1
starts at `mov bx, 0x134D`, and the way it skips to track *N* pins the layout
down exactly:

```
0049  mov  bx, 0x134D
004C  mov  dh, 0xFF
004E  jmp  0x59
0050  inc  bx           ; step over the header byte
0051  add  bx, 4        ; step over one voice entry
0054  cmp  [bx], dh     ; terminator?
0056  jne  0x51
0058  inc  bx           ; step over the terminator
0059  dec  al           ; one track skipped
005B  jns  0x50
```

So a track is a header byte, then four-byte voice entries, then `0xFF`. Each
voice entry is `(count, pointer)`, and the pointer leads to `count` words, each
of which is the address of a pattern. That is the usual tracker arrangement:
song, voices, sequence, patterns.

| Track | Header | Voices | Sequence steps |
|---:|---|---:|---:|
| 0 | `0x2A` | 5 | 5 |
| 1 | `0x2A` | 8 | 32 |
| 2 | `0x2A` | 9 | 34 |
| 3 | `0x2A` | 9 | 26 |
| 4 | `0x48` | 9 | 9 |
| 5 | `0x2A` | 9 | 9 |

Six tracks, matching the `AL` values `0x00` to `0x05` seen at the call sites
exactly. Track 4 carries a different header byte — a different tempo, most
likely.

### Layout of the overlay

| Range | Contents |
|---|---|
| `0x0000`-`0x0C5D` | code |
| `0x0C5E`-`0x0C8A` | dispatch table, 23 functions |
| `0x0C8B`-`0x1266` | code and driver state |
| `0x1267`-`0x134C` | sequence lists, 49 voices |
| `0x134D`-`0x141C` | track table, 6 tracks |
| `0x141D`-`0x1E9E` | pattern data, 74 distinct patterns, 2,690 bytes |

The music occupies `0x1267`-`0x1E9E`, about 3.1 KB — roughly 40 % of the
overlay.

### The pattern command stream

```bash
python tools/re/patterns.py                 # decode and validate all 74
python tools/re/patterns.py --pattern 141d  # one pattern
```

The interpreter is at `0x01D0`:

```
01D0  lodsb                     ; token
01D1  cmp  al, 0x41
01D3  jl   0x1DD                ; SIGNED - so 0x80..0xFF go here too
01D5  shl  al, 1
01D7  mov  bl, al
01D9  jmp  word ptr [bx+0x8F8]  ; command dispatch
```

and the sub-`0x41` path splits again on the unsigned comparison:

```
01DD  jae  0x1E4
01DF  mov  [di+0x1C], al        ; 0x00..0x40 - duration
01E2  jmp  bp
01E4  mov  [di+0x20], al        ; 0x80..0xFF - note
01E7  mov  [di+0x12], si
01FC  call word ptr [0xBCD]     ;   and trigger note-on
```

So a token is one of three things:

| Range | Meaning |
|---|---|
| `0x00`-`0x40` | duration |
| `0x41`-`0x5B` | command — the mnemonic is the ASCII letter |
| `0x80`-`0xFF` | note, triggers note-on |

The command table ends at `0x5B` because entry `0x5C` would land on `0x9B0`,
where the channel structures begin.

| Cmd | | Operand | Handler does |
|---|---|---:|---|
| `0x41` | `A` | 0 | restore duration from `[di+0x1C]` |
| `0x42` | `B` | 0 | reload si from `[di+0x14]` — advance the sequence |
| `0x43` | `C` | 0 | test `[di]`, end when zero |
| `0x44` | `D` | 1 | set `[di+0x21]` |
| `0x45` | `E` | 1 | set global `[0x236]` |
| `0x46` | `F` | 1 | set global `[0x156]` |
| `0x47` | `G` | 0 | loop start, count 2 |
| `0x48` | `H` | 1 | loop start, count from operand |
| `0x49` | `I` | 0 | loop end, decrement `[di+0x25]` |
| `0x4A` | `J` | 1 | set `[di+0x1D]` |
| `0x4B` | `K` | 0 | clear `[di+0x1D]` |
| `0x4C` | `L` | 1 | device call through `[0xBBF]` |
| `0x4D` | `M` | 1 | set global `[0x1A8]` |
| `0x4E` | `N` | 1 | set `[di+0x0C]`, `[di+0x0D]` |
| `0x4F` | `O` | 2 | same, from a word |
| `0x50` | `P` | 2 | set `[di+0x10]` |
| `0x51` | `Q` | 1 | set global `[0x755]` |
| `0x52` | `R` | 2 | set `[di+0x0C]`, `[di+0x0D]` |
| `0x53` | `S` | 0 | set flag `0x20` in `[di+4]` |
| `0x54` | `T` | 0 | set flag `0x10` in `[di+4]` |
| `0x55` | `U` | 1 | set `[di+0x1A]` |
| `0x56` | `V` | 1 | set `[di+0x0F]` |
| `0x57` | `W` | 0 | no operation |
| `0x58` | `X` | 0 | `jmp si` |
| `0x59` | `Y` | 2 | conditional on bit 0 |
| `0x5A` | `Z` | 1 | relative branch, signed |
| `0x5B` | `[` | 1 | set global `[0x5CA]` |

### Patterns are not self-terminating

There is no terminator byte. A pattern's extent comes from the sequence table:
sorting every referenced pattern address gives the boundaries, and each pattern
runs up to the next one. The most common last token is `B` (43 of 74), which
reloads si and so means "finished, advance the sequence"; the rest end on `C`,
`Z`, a note, or simply run to the boundary.

**This is what validates the operand sizes.** All 74 patterns tokenise to land
*exactly* on their boundary — a single wrong operand size anywhere would
desynchronise the stream and overshoot. Totals across the region: 1,020 notes,
726 durations, 659 commands in 2,690 bytes.

Nine commands never occur in the data: `F K S T U V W X [`.

A pattern reads cleanly:

```
pattern 0x141d..0x1428  6 tokens
  51 00     Q 0x00     set global [0x755]
  4f ff01   O 0xff01   set [di+0x0C], [di+0x0D] from word
  59 0b10   Y 0x0b10   conditional on bit 0
  0a        duration 10
  ab        note 0xab
  43        C          test [di]; end when zero
```

## Sound effects

Function AH=5 does not index a table at all:

```
002D  mov  [0x207], al          ; remember the parameter
0030  mov  cl, al
0032  mov  di, 0x9B0            ; first channel structure
0035  cli
0036  test byte [di+4], 0x88    ; channel in use?
003A  jne  0x40
003C  call word ptr [0xBC5]     ; free - start it here
0040  add  di, 0x3A             ; next channel, stride 58 bytes
0043  cmp  byte [di], 0
0046  jne  0x36
0048  ret
```

It walks the channel structures at `0x9B0`, stride 58 bytes, and starts the
effect on the first free one through the device vector at `[0xBC5]`. The `AL`
values used by the game are `0xA0`, `0xB4`, `0xC8`, `0xDC` and `0xF0` — evenly
spaced by 20, which suggests a pitch or period rather than an index into a
sample bank. There are no samples in the overlay to index anyway.

## For the port

The Falcon side does not need any of this code. It needs the **interface**:
23 functions with `AH`/`AL` semantics, of which seven are used with static
arguments. The replacement is a DSP56001 driver with the same entry points, and
the call sites in the translated game code keep their shape.

The music data does need converting, and it now can be: six tracks, 49 voices,
74 patterns, a 27-command instruction set, all decoded and validated. The DSP
sequencer needs to implement the eighteen commands that actually occur —
`A B C D E G H I J L M N O P Q R Y Z` — plus notes and durations. `A`, `O`, `I`
and `B` together account for more than three quarters of all commands.

What the commands *mean* musically is still only partly known. They are
identified by which channel field they write, not by their effect: `[di+0x0C]`
and `[di+0x0D]` (written by `N`, `O` and `R`, 84 times) is most likely the
pitch or frequency divisor, and `[di+0x21]`, `[di+0x1A]`, `[di+0x1D]` are
envelope or instrument parameters. Pinning those down means following the
device vectors `[0xBBF]`, `[0xBCD]` into the AdLib and MPU-401 back ends.
