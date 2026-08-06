# The AdLib / OPL2 back end

Devices 2 and 4 of the sound driver, code at `0x06F6`-`0x0850` of the
decompressed overlay, instrument table at `0x115F`. See
[SOUND-DRIVER.md](SOUND-DRIVER.md) for the device layer above it.

This is the back end worth reading, because it is exercised far more than the
MPU-401 one (43 port accesses against 3) and OPL2 register semantics are well
documented — so it is what pins down the musical meaning of the channel fields.

## Register writer

`0x07E9`, textbook AdLib:

```
07E9  mov  dx, 0x388
07EC  out  dx, al        ; register number to the address port
07ED  in   al, dx        ; x6  - the ~3.3 us settling delay
07F3  mov  al, ah
07F5  inc  dx            ; 0x389
07F6  out  dx, al        ; value to the data port
07F7  dec  dx
07F8  in   al, dx        ; x36 - the ~23 us delay
081B  ret
```

The dummy reads of the status port are the standard way of meeting the OPL2
timing requirement on hardware without a cycle counter. Two extra entry points
sit above it: `0x07E7` adds the operator offset in `ch` to the register number
first, `0x07E5` also takes the value from `bl`.

Convention throughout: **`al` is the register, `ah` is the value.**

## Pitch

The F-number table is not in the file. It is generated at startup, at `0x0478`:

```
047A  mov  ch, 8         ; eight octaves
047C  push si            ; outer loop
047D  mov  dx, 0x0C      ; twelve semitones
0480  mov  cl, bl        ; shift for this octave
0488  lodsw              ; base F-number
0489  shr  ax, cl
048B  adc  ax, bp        ; round on the shifted-out bit
048D  stosw
048E  dec  dx / jne
0492  add  bl, bh        ; next octave
0494  dec  ch / jne
```

so **8 octaves x 12 semitones = 96 words at `0x88A`-`0x949`**, expanded from a
12-entry base table at `0x962`:

| | F-num | ratio |
|---|---:|---|
| C | 1017 | |
| C# | 960 | 0.9440 |
| D | 906 | 0.9437 |
| D# | 855 | 0.9437 |
| E | 807 | 0.9439 |
| F | 762 | 0.9442 |
| F# | 719 | 0.9436 |
| G | 679 | 0.9444 |
| G# | 641 | 0.9440 |
| A | 605 | 0.9438 |
| A# | 571 | 0.9438 |
| B | 539 | 0.9440 |

Descending, because the generator shifts right for lower octaves. The inverse
ratio is 1.0593 against the equal-tempered 2^(1/12) = 1.0595, so this is a
proper chromatic scale. The base table ends at `0x979` and the pattern command
table starts at `0x97A`, which corroborates both extents.

Emitting a note, `0x081C`:

```
081C  shl  bl, 1
081E  mov  ax, [bx+0x88A]   ; F-number for the note
0822  cmp  ah, 3
0827  add  cl, 4            ; block += 1, it sits in bits 2-4 of 0xB0
082A  shr  ax, 1            ; and halve the F-number
082F  jae  0x827            ; until it fits in ten bits
0831  or   cl, ah
0833  mov  [di+0x0A], cl    ; cache the 0xB0 value
0836  mov  ah, al
0838  mov  ch, [di+1]       ; channel
083B  mov  al, 0xA0
083D  call 0x7E7            ; F-number low
0840  mov  ax, 0x7FB0
0843  and  ah, cl
0845  jmp  0x7E7            ; block and F-number high
```

The octave normalisation loop is the usual one: while the F-number needs more
than ten bits, halve it and step the block up.

## Key on and off

`[di+0x0A]` caches the last value written to register `0xB0`, which is what
makes key-off cheap:

- **`0x0771`** (vector slot 8): `mov ax,0x5FB0 / and ah,[di+0x0A]` — `0x5F`
  has bit 5 clear, so this **clears the key-on bit** while leaving block and
  F-number intact.
- **`0x077F`** (slot 10): writes 0 to `0xB0 + channel` — everything off.
- **`0x0768`** (slot 9): writes `0xFF` to `0x43 + [di+2]`, maximum attenuation,
  so silence via the output level instead.

## Instruments

`0x0787` computes the record address as `0x115F + index*9`, so records are
**9 bytes**. `0x0797` onwards writes them out:

| Order | Register | Meaning |
|---:|---|---|
| 1 | `0xC0 + channel` | feedback and connection, low nibble of byte 0 |
| 2 | `0xE0 + op` | waveform, operator 1 |
| 3 | `0xE3 + op` | waveform, operator 2 |
| 4 | `0x40 + op` | KSL and output level, operator 1 |
| 5 | `0x20 + op` | AM/VIB/EG/KSR/MULT, operator 1 |
| 6 | `0x60 + op` | attack and decay |
| 7 | `0x80 + op` | sustain and release |
| 8 | | `add ch, 3` — switch to operator 2, repeat 5 to 7 |

The carrier's output level (`0x43 + channel`) is deliberately not part of the
instrument: it is the volume, written separately by the routines at `0x06F6`
and `0x071A`.

## Channel structure

Stride 58 bytes from `0x9B0`. Fields established from the code that uses them:

| Offset | Meaning | Established by |
|---|---|---|
| `+0x01` | channel number | added to registers `0xA0`, `0xB0`, `0xC0` |
| `+0x02` | operator offset | added to register `0x40` |
| `+0x04` | status flags | tested `0x88`, `0xC0`, `0xF0`; bits `0x10`/`0x20` set by commands `T`/`S` |
| `+0x0A` | cached `0xB0` value | written at `0x0833`, masked at `0x0771` |
| `+0x0B` | volume | read at `0x06F6`, scaled into register `0x40` |
| `+0x0C`-`+0x0E` | expression | written by commands `N`, `O`, `R`; read at `0x071A` and multiplied into the `0x40` computation |
| `+0x14` | sequence pointer | reloaded by command `B` |
| `+0x16` | loop mark | set by commands `G`, `H`; restored by `I` |
| `+0x18` | pattern pointer | saved at `0x0317` |
| `+0x1C` | duration | set by tokens `0x00`-`0x40`, restored by command `A` |
| `+0x20` | current note | set by tokens `0x80`-`0xFF` |
| `+0x21` | **transpose** | `add bl, [di+0x21]` at `0x0246`, immediately before the pitch lookup — and command `D` sets it |
| `+0x25` | loop counter | set by `G` (to 2) and `H`; decremented by `I` |
| `+0x26` | instrument pointer | read at `0x06F9` |

That settles several of the pattern commands musically: **`D` is transpose**,
`A` restores the last duration, `G`/`H`/`I` are a counted loop, `B` advances the
sequence, and `N`/`O`/`R` set expression feeding the output level.

## For the port

The DSP56001 has no FM synthesis, so the OPL2 register writes cannot be
translated — they have to be *emulated or replaced*. Two viable routes:

- **Reimplement 2-operator FM on the DSP.** Sixteen-bit phase accumulators,
  sine table, envelope generators. Well within a 32 MHz DSP56001 for nine
  channels, and the instrument records translate directly since they are just
  operator parameters.
- **Substitute samples.** Simpler, but the instrument definitions become
  useless and the character of the music changes.

Either way the layer above is unaffected: the sequencer, the pattern commands
and the note-to-F-number mapping are device-independent, and the frequency
table can be recomputed for whatever the DSP's sample rate demands from the
same twelve base values.
