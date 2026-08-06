# The MPU-401 / MT-32 back end

Device 5 of the sound driver, code at `0x059B`-`0x06F5` of the decompressed
overlay, instrument table at `0x1237`. See [SOUND-DRIVER.md](SOUND-DRIVER.md)
for the device layer and [ADLIB-BACKEND.md](ADLIB-BACKEND.md) for the other
back end.

## Byte sender

`0x0677`, the standard MPU-401 UART handshake:

```
0677  mov  dx, 0x331    ; status port
067A  in   al, dx
067B  shl  al, 1
067D  jae  0x686        ; DSR set - input pending, drain it first
067F  js   0x67A        ; DRR set - not ready, poll again
0681  dec  dx           ; 0x330, the data port
0682  mov  al, ah
0684  out  dx, al
0685  ret
0686  dec  dx
0687  in   al, dx       ; discard a pending input byte
0688  inc  dx
0689  jmp  0x67A
```

`0x0672` sits directly above it and sends **two** bytes, `ah` then `bl`, by
calling `0x0677` and falling into it.

This is why an earlier scan for port constants found three references to
`0x331` and none at all to `0x330`: the data port is never loaded as a
constant, only reached by `dec dx` from the status port.

## MIDI messages

| Address | Slot | Message |
|---|---:|---|
| `0x0657` | 7 | `0x90 \| ch` — **Note On**, then note number and velocity from `[di+0x0F]` |
| `0x0610` | 8 | `0x80 \| ch` — **Note Off**, velocity `0x40` |
| `0x0601` | 9 | `0xB0 \| ch`, controller `0x7B` — **All Notes Off** |
| `0x05AD` | 5 | `0xB0 \| ch`, controller `7` — **Channel Volume** |
| `0x05BE` | 3 | `0xB9`, controller `7` — volume on **channel 10**, the drum channel |

The channel number in `[di+0x01]` is added to a base of `0x81`, `0x91` or
`0xB1` rather than OR-ed with `0x80`/`0x90`/`0xB0`, so it is stored zero-based
and the driver works in MIDI channels 1 to 16.

`[di+0x0A]` caches the note number, exactly as the AdLib back end caches the
`0xB0` register value, so note-off does not need the sequencer to resend it.

## Inline byte strings

`0x0697` uses the same inline-data idiom that runs through the whole game:

```
0697  pop  ax          ; return address = pointer to the byte string
0698  push si
0699  mov  si, ax
069B  lodsb
069C  mov  ah, al
069E  call 0x677       ; send it
06A1  lodsb
06A2  cmp  al, 0xFF    ; terminator
06A4  jne  0x69C
06A6  pop  ax
06A7  xchg si, ax
06A8  jmp  ax          ; resume past the string
```

Callers write the MIDI bytes straight after the `call`, terminated by `0xFF`.
For an MT-32 that is how the initialisation and patch-select sequences are
issued. It is the third place this idiom appears — the text renderer in
`X.EXE` and the menu dispatcher being the others.

## Instruments

`0x0626` computes `0x1237 + index*2`, so entries are **two bytes**:

```
0626  mov  si, 0x1237
0629  sub  ah, ah
062B  shl  ax, 1
062D  add  si, ax
062F  test byte [di+3], 0xFF
0633  js   0x637
0635  mov  si, word ptr [si]   ; dereference only when bit 7 is clear
0637  ret
```

The table runs `0x1237`-`0x1266`, 24 entries, ending exactly where the
sequence lists begin at `0x1267`.

Note the conditional dereference. When bit 7 of `[di+3]` is clear the entry is
treated as a pointer; otherwise the two bytes are used directly. Read as
pointers most entries land outside the 7,839-byte overlay — `0x6278`, `0x536E`,
`0x5432` — so the direct-data path is the normal one and the entries are pairs
of MIDI data bytes, most likely patch number and a second parameter. Which one
is not established.

## Correction to earlier notes

Vector slot 8 (`0xBCD`) was previously described as note-on, on the grounds
that it is called from the note path at `0x01FC`. Both back ends implement it
as **note off**:

- MPU-401 `0x0610` sends `0x80 | ch`, the MIDI Note Off status.
- AdLib `0x0771` masks the cached `0xB0` value with `0x5F`, which has bit 5
  clear and therefore clears the OPL2 key-on bit.

The note actually sounds through **slot 7** (`0xBCB`): MIDI Note On at
`0x0657`, and the F-number emitter at `0x081C` on the AdLib side. The sequencer
releases the previous note before starting the next, which is required on OPL2
anyway, and slot 7 is the one that plays.

## Comparison of the two back ends

| Slot | AdLib | MPU-401 |
|---:|---|---|
| 0 | instrument table `0x115F` | instrument table `0x1237` |
| 1 | load instrument, 9-byte record | select patch, 2-byte entry |
| 3 | | drum channel volume |
| 4 | effect start, scaled into register `0x40` | effect start |
| 5 | | channel volume, CC 7 |
| 7 | F-number to registers `0xA0`/`0xB0` | Note On |
| 8 | clear key-on bit in `0xB0` | Note Off |
| 9 | `0xFF` to register `0x43`, full attenuation | All Notes Off, CC 123 |

The two are structurally the same driver with different emission. That is what
makes the Falcon port tractable: the sequencer, the pattern commands and the
channel structure are all above this line and identical either way.

## For the port

The MPU-401 back end is the better model for a DSP56001 driver, precisely
because it is thin. It sends *events* — note on, note off, volume, patch
select — while the AdLib one synthesises. A DSP driver that accepts the same
five or six events maps onto slot 7, 8, 9, 5 and 1 with no sequencer changes
at all.

The MT-32 patch data is not in the overlay; only the 24 two-byte table entries
are, and the actual timbres live in the MT-32 itself. So this back end offers
nothing to extract for the port's sound bank — for that the AdLib instrument
records at `0x115F` are the only source, being complete FM parameter sets.
