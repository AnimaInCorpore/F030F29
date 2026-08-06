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

## For the port

The Falcon side does not need any of this code. It needs the **interface**:
23 functions with `AH`/`AL` semantics, of which only seven are actually used
with static arguments. The Falcon replacement is a driver on the DSP56001 with
the same entry points, and the call sites in the translated game code keep their
shape.

The music and effect data is not in the overlay. Function 1 indexes a table at
`0x134D` inside it, but the tracks themselves are elsewhere — most likely among
the resources not yet identified. Finding them is what the audio work needs
next.
