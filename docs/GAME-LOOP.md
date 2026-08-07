# The game loop

What the per-frame update does, and the state it works on. This is the spine
the flight model and game logic hang off, and the thing the port has to
reproduce.

Found via the call graph rather than by hunting for anchors — see
[X86DISASSEMBLE.md](X86DISASSEMBLE.md) section 7 for why the anchor approach
failed twice first.

## Shape of a frame

The loop runs `0xEFB9` to `0xF273`, which jumps back to the top.

```
EFB9  call 0xCC8C          ; state dispatch, 18 callees in 0x3000-0x4900
EFBC  call 0x575D
EFBF  mov  al,[0xF895]     ; free-running timer
EFC2  mov  cl,al
EFC4  sub  al,[0x6327]     ;   minus its value last frame
EFC8  cmp  al,0x1A
EFCA  jb   .ok
EFCC  mov  al,0x19         ;   clamped to 25
EFCE  mov  [0x347C],al     ; -> the frame delta
EFD1  mov  [0x6327],cl
EFD5  call 0x2C37
EFDC  call 0x2BDA
EFDF  mov  al,0            ; self-modified flag
EFE3  je   .skip
EFE5  call 0x5571
EFE8  call 0x4EB6          ;   the aircraft update
.skip
EFF3  call 0x4198
EFF6  call 0xA71F
EFF9  call 0x1FF7
F00C  call 0xA2F0
F00F  call 0xA17C
F019  call 0x343E
...
F252  call 0xB1B8          ; conditional on bit 3 of [0xFB3A]
F255  call 0xB134
F25A  call 0xC3BB
F25D  mov  bx,[0xA720]
F261  shl  bl,1
F263  call [bx-0x5929]     ; per-state handler, table at 0xA6D7
F267  call 0x9460
F26A  call 0x9D4C
F26D  mov  al,0            ; self-modified flag
F271  jne  .not_looping
F273  jmp  0xEFB9          ; round again
```

## Timing

**`[0x347C]` is the frame delta**, and everything time-dependent scales by it.
It is the difference of a free-running timer at `[0xF895]` since the previous
frame, clamped to 25.

That clamp is the interesting part: it means the original was already written to
survive a slow frame without the simulation exploding, and the port inherits
both the property and the constant. Anything that consumes `[0x347C]` is
physics or animation.

Only three places read it: `0x505B`, `0x51FE` and `0xA8DC`. The first two are in
the region `0x4EB6` dispatches into, which is what identifies that region as the
flight model.

## Game state

**`[0xA720]` is the state variable.** It indexes the 13-entry table at `0xA6D7`
— resolved earlier as `call [bx-0x5929]` — so there are thirteen states, each
with its own per-frame handler. It is also compared against `0x0C` in several
places, consistent with twelve being the last valid state.

One of those handlers draws the in-flight HUD; its labels are inline strings, so
`ALTITUDE` sits at `0xA8FC` immediately after a `call 0x5B4C`. An earlier note
called the whole table "the HUD dispatcher" — it is the state dispatcher, and
the HUD is what one state happens to draw.

`[0xF3A2]` is a second, independent selector: the theatre. `0xCC8C` tests it
against `0x62` at its first instruction, the placement-list walker at `0x438D`
uses it to choose a group, and `0x75FC` indexes a per-theatre parameter table
with it. Three routines found separately all key off the same byte.

## `0xCC8C`, the way into the game code

`0xCC8C` is called from the main loop (`0xF2C9`, `0xF2E6`) and dispatches into
`0x3000`-`0x4900` and the `0xCF00`-`0xD200` range — the largest contiguous run
of reached code in the image, and structurally distinct from the flight model:
where `0x4EB6` is arithmetic on a handful of variables, this is closer to a
grab-bag of small utility subsystems, each used from several places.

Eighteen call targets, found the same way as `0x4EB6`'s: bound a routine by its
contiguously reached instructions and dedupe the `call` targets inside.

| Target | What it is |
|---|---|
| `0x1325` | pseudo-random generator — confirmed, see below |
| `0xCFB3` | CRC-16/CCITT — confirmed, see below |
| `0xCF81`, `0xCF9F` | an 8-byte record reader, feeding a wider working structure |
| `0xCF5D`, `0xCF79` | the matching writer, repacking that structure back down |
| `0xB1B8`, `0xD1D1` | a multi-slot countdown timer utility — see below |
| `0x42BD` | random-bucketed selector over three spawn-time flags — see below |
| `0x412C` | triggers `0x42A2` → `0x40AF`, the object-spawn-at-aircraft-position routine already known from the world-coordinate work above |
| `0x4188` | the sound gate — see [FLIGHT-MODEL.md](FLIGHT-MODEL.md) |
| `0x1F3A`, `0x314E`, `0x3160`, `0x3644`, `0x3F62`, `0x40A3`, `0x9811` | previewed only — first few instructions read, not yet worked out |

### `0x1325` is the PRNG, and it is never reseeded

```
1325  mov  ax, 0        ; <- [0x1326], the seed, an instruction immediate
1328  mov  dx, 0x4B
132B  inc  ax
132C  je   .skip
132E  mul  dx            ; dx:ax = (seed+1) * 75
.skip
1330  sub  ax, dx
1332  adc  ax, 0
1335  mov  [0x1326], ax
1338  ret
```

A multiplicative generator, self-modified in place like every other hot
variable in this codebase. Simulating it exactly finds a cycle of 32,381
values before it repeats, with a mean close to the theoretical uniform value
— a working generator, not a broken one.

`[0x1326]` has exactly one writer: itself. No timer, keystroke, or anything
else seeds it anywhere in the disassembled 44.6% — every playthrough draws the
same sequence, starting from the same compiled-in value, unless a seed write
is hiding in the unreached 55%.

### `0xCFB3` is a bitwise CRC-16/CCITT

```
CFB3  mov  bp, 0x1021    ; the CCITT polynomial
CFB6  lodsw               ; dx = the first two stream bytes, byte-swapped
...
loc_CFC3:
CFC3  rcl  dx, 1
CFC5  sbb  bx, bx
CFC7  and  bx, bp
CFC9  xor  dx, bx         ; conditionally XOR the polynomial, textbook CRC-16
CFCB  shl  al, 1
CFCD  jne  .CFC3
CFCF  loop .CFC0
loc_CFD1:
CFD3  shl  dx, 1 / sbb ax,ax / and ax,bp / xor dx,ax   ; 16 more flush steps
```

`0x1021` is unmistakable — this is the polynomial used by XMODEM/CCITT CRC-16,
computed bit by bit over a `cx`-byte stream at `si`, with a second loop that
flushes the last 16 bits through the same feedback. Called from `0xCCFD`
(early in `0xCC8C`'s own body), from `0xCF4C` (right after the record-codec
pair above), and from two sites elsewhere (`0xD91B`, `0xDBDA`). Something gets
checksum-verified on the way into or out of this dispatch; which structure is
still open.

### The timer utility, and a data-region correction

`0xB1D7` "arms" a slot with the current time plus an offset:

```
B1D7  sub  bh, bh
B1D9  add  ax, [0xF895]         ; the free-running timer
B1DD  mov  [bx - 0x4CEE], ax    ; store into a slot chosen by the caller's bx
```

`0xB1B8` cancels all of them at once:

```
B1B8  call 0xB1D7
B1BB  mov  bx, 0xFC2D
B1BE  mov  al, 0xFF
B1C0  mov  [bx], al
B1C2  mov  [bx+0xB], al
B1C5  mov  [bx+0x16], al
```

Three flag bytes, eleven apart — a 3-slot array. `0xB1D7` is the far more
common call (six sites: `0x344E`, `0x421D`, `0x4253`, `0xB1B8` itself,
`0xB1CE`, `0xEE64`, plus one more), so this reads as a small, general-purpose
"set a deadline in one of a few slots, or cancel them all" utility rather than
anything specific to one feature.

This also settles something worth recording precisely: `0xFC2D` sits *outside*
the segment table documented in [RE-NOTES.md](RE-NOTES.md), which is nine
words starting at `0xFC16` — 18 bytes, ending at `0xFC27`. The gap between
that and the archive index at `0xFC4A` is 34 unaccounted bytes, and this
3-slot, 11-byte-stride array (33 bytes) accounts for nearly all of it. No
correction to the data guard was needed; the boundary was never claimed to
reach that far, but the gap now has a name.

### `0x42BD`: a bucketed random pick over the same three spawn flags

```
42BD  call 0x1325            ; al = a fresh random byte
42C0  cmp  al, 0x60
42C2  jae  .noop              ; 160 times in 256: do nothing at all
42C4  sub  al, 0x20
42C6  mov  bx, 0xB3F4
42C9  jb   .mask
42CB  cmp  al, 0x20
42CD  mov  bx, 0xB3E6
42D0  jb   .mask
42D2  mov  bx, 0xB3D8
42D5  or   al, 4
.mask
42D7  and  byte [bx], 0x80    ; keep only the top bit of whichever flag
```

`0xB3D8`, `0xB3E6` and `0xB3F4` are the same three bytes that get initialised
to `1` at spawn alongside `[0x418D]`, the sound gate's comparison target (see
[FLIGHT-MODEL.md](FLIGHT-MODEL.md)) — all five written from the same
instruction block at `0xEEE0`-`0xEEE9`. What this routine does is mask one of
the three, chosen by which sixteenth-wide bucket the random draw fell into,
down to just its top bit — and better than a third of the time (96 in 256), it
does nothing. What reads these three flags afterward is not yet found.

## Hot variables live inside instructions

Before anything else in this region: **the program keeps its working state in
the immediate operands of the instructions that read it.** Eight are confirmed:

| Address | Instruction that holds it | Quantity |
|---|---|---|
| `0xAE68` | `mov bx, imm` at `0xAE67` | airspeed |
| `0x3984` | `mov word [bp+0x12], imm` at `0x3981` | vertical position |
| `0x5084` | `mov ax, imm` at `0x5083` | pitch attitude |
| `0x4FCC` | `mov ax, imm` at `0x4FCB` | bank angle |
| `0x4FDB` | `mov ax, imm` at `0x4FDA` | pitch command |
| `0x5119` | `mov ax, imm` at `0x5118` | heading accumulator |
| `0x510F` | `add ax, imm` at `0x510E` | altitude fraction |
| `0x5115` | `adc dx, imm` at `0x5113` | altitude |

This is not obfuscation, it is an 8086 optimisation: `mov ax, imm` is
appreciably faster than `mov ax, [mem]`, since the immediate is already in the
prefetch queue. Writing the value into the instruction that consumes it saves a
memory fetch on every read.

**For the port this is a decision point.** On the 68030 the trick buys nothing
and costs a great deal: self-modifying code needs the instruction cache
invalidated after every write, and a missed invalidation produces a bug that
appears only when the line happens to be cached. Every one of these becomes a
plain variable. See the note in [ARCHITECTURE.md](ARCHITECTURE.md).

It also means an address that looks like a variable may not be one, which cost
real time here — the airspeed had twenty accesses and no consumer that displayed
anything until it turned out to *be* the consumer.

## The flight model

`0x4EB6` is the aircraft update, called from the loop when a self-modified flag
is set, and it dispatches into `0x5000`-`0x5500`. It has its own document:
[FLIGHT-MODEL.md](FLIGHT-MODEL.md) — units, load factor, the speed equation,
attitude and position integration, ground handling and the throttle.

What stays here is how each piece of state was *identified*, since that is a
story about reading the binary rather than about flying.

### `[0xAE68]` is the airspeed

Established, from five independent uses across twenty accesses.

**It is integrated into position.** At `0x5123`:

```
5123  mov  ax,[0x347B]      ; the word whose high byte is the frame delta
5126  imul word ptr [0xAE68]
512A  mov  cx, dx           ; keep the high word of the product
512C  mov  ax,[di+0x143A]   ; sin of the pitch angle
5130  imul cx
5132  add  ax, bp           ; accumulate into a 32-bit position
5135  adc  dx, bp
```

Speed times time times direction, summed into a position. That alone settles
what the quantity is.

**Things are divided by it.** At `0x5000`:

```
5002  sar  dx,1 / rcr ax,1   ; a 32-bit value, halved
5006  mov  cx,[0xAE68]
500A  cmp  cx,0x7D0          ; floored at 2000
5010  mov  cx,0x7D0
5013  shl  cx,1 / shl cx,1   ; times four
5017  idiv cx
```

Dividing by speed, with a floor so it cannot blow up at a standstill, is how a
flight model scales control authority — the faster you go, the less angular
change a given input buys per unit of distance.

**It is updated every frame by `0x5260`**, which integrates thrust against
drag directly into it — not a separate rate-limited approach to a target. A
second, independent mechanism caps it against a g/altitude-dependent ceiling
computed by `0x52FF`; see [FLIGHT-MODEL.md](FLIGHT-MODEL.md) for both.

**It gates discrete bands** at `0x4EB6`, against 1936, 2080 and 2920 combined
with flag bits.

**It drives a low-speed animation.** At `0x94D6` it is clamped to 880, shifted
right four and accumulated into a phase that wraps at 8 — a cycle whose rate
follows speed, with a separate floor of 40 below which it stops. Ground roll,
by the look of it: wheels or runway markings.

It is initialised to `0x0C80`, 3200, at `0xEF92`.

### The unit: eight per knot

`0xAE68` is not a variable at all. It is the **immediate operand of an
instruction**, and that is why searching for readers of it found none that
displayed anything.

The instrument routine at `0xAE4C` supplies three numbers, printed by `0x58B6`
at three screen positions:

```
AE4C  mov  ax,[0xA81E]     ; heading source
AE4F  mov  cx, 0x2D00
AE52  mul  cx
AE54  or   dx, dx
AE56  je   .keep
AE58  neg  dx
AE5A  add  dx, 0x168       ;   wrapped into 0..359
.keep
AE5E  mov  si, dx          ; -> printed at 0xC8, degrees
AE60  mov  ax, 0xFFEC      ; -20
AE63  sub  ax,[0x3984]     ; altitude source
AE67  mov  bx, 0           ; <- the immediate here IS 0xAE68
AE6A  shr  bx, 1
AE6C  shr  bx, 1
AE6E  shr  bx, 1           ; -> printed at 0x20, speed / 8
AE70  shl  ax, 1
AE72  shl  ax, 1           ; -> printed at 0x7C, altitude * 4
AE74  ret
```

`mov bx, 0` at `0xAE67` assembles as `bb 00 00`, so its immediate occupies
`0xAE68` and `0xAE69`. The flight model's `mov [0xAE68], dx` at `0x52FA` writes
the speed straight into the instruction that will load it, every frame. The
instrument routine then shifts right three and prints it.

**So the display is `speed / 8`, and the internal unit is eight per knot.**
Every constant falls into place:

| Internal | Displayed | What it is |
|---:|---:|---|
| 3200 | **400 kt** | initial speed |
| 2920 | 365 kt | top band |
| 2080 | 260 kt | middle band |
| 2000 | 250 kt | floor for control authority |
| 1936 | 242 kt | bottom band |
| 880 | 110 kt | ground animation cap |
| 40 | 5 kt | below this the ground animation stops |

400 knots to start, bands in the 240 to 365 range where gear and flap limits
belong, ground roll animating below 110 knots and stopping at 5. The READ.ME's
"maintain a speed of 270 to 300 knots" on approach sits exactly between the
bands.

### `[0xA81E]` is the heading, 2048 to the circle

```
AE4C  mov  ax,[0xA81E]
AE4F  mov  cx, 0x2D00      ; 11520
AE52  mul  cx              ; dx:ax, keep the high word
```

`mul` by 11520 and taking the high word is a division by 65536/11520, and the
constant is chosen so that **2048 units come out as exactly 360**:

| Value | Degrees |
|---:|---:|
| 0 | 0 |
| 256 | 45 |
| 512 | 90 |
| 1024 | 180 |
| 1536 | 270 |
| 2047 | 359 |

So the heading is an 11-bit angle, 2048 to the full circle — the same
representation the display-list interpreter uses, where the angle accumulator
is masked with `and ah,7` to eleven bits.

The `neg dx / add dx,0x168` that follows turns it into a compass bearing by
computing `360 - degrees`, guarded by a `je` so that zero stays zero rather than
becoming 360.

`0xEF06` initialises it to `0x400` — **1024, due south**. The flight model
rewrites it every frame at `0x511E`, immediately before using it to index the
direction table for the position integration.

### `[0x3984]` is the vertical position, negative upward

Displayed as `(-20 - value) * 4`, so the axis points **down**: the aircraft is
at a *negative* value when airborne, and the reading is zero at value -20.

| Value | Displayed |
|---:|---:|
| -20 | 0 |
| -40 | 80 |
| -100 | 320 |
| -500 | 1920 |
| -2520 | 10000 |

The flight model writes it at `0x4EA0` and swaps it at `0x5165`. A ground
proximity test sits at `0x3F01`:

```
3F01  cmp  word ptr [0x3984], -0x4B     ; -75, so 220 on the display
3F06  jae  0x3F5E
```

Note the *unsigned* `jae` on a signed quantity. It works only because the value
is negative whenever the aircraft is airborne: a large unsigned value means
close to the ground, and the branch is taken when within 220 of it. Falling
through means high.

#### It is an instruction immediate too

Like the airspeed. At `0x3981`:

```
3972  c7 46 0c c8 00   mov word ptr [bp+0x0c], 0xC8
3977  c7 46 0e c8 00   mov word ptr [bp+0x0e], 0xC8
397C  c7 46 10 c8 00   mov word ptr [bp+0x10], 0xC8
3981  c7 46 12 c8 00   mov word ptr [bp+0x12], 0xC8
                 ^^^^^ this immediate is 0x3984
3986  c7 46 14 c8 00   mov word ptr [bp+0x14], 0xC8
398B  c7 46 16 c8 00   mov word ptr [bp+0x16], 0xC8
```

The other init targets fall out of the same block: `0x3975`, `0x397F`, `0x3989`
and `0x398E` are the immediates of the neighbouring instructions.

#### World coordinates are 16.16 fixed point

That block, and `0x40AF` which does the same thing with live values, writes a
structure with fields at `+0x0C` through `+0x16` — **three 32-bit coordinates**:

```
40B7  mov  [bp+0x0e], ax     ; X high
40BA  sub  ax, ax
40BC  mov  [bp+0x0c], ax     ; X low, zero
40BF  mov  [bp+0x12], bx     ; Y high  <- bx is [0x3984]
40C2  mov  [bp+0x10], ax     ; Y low, zero
40C5  mov  [bp+0x16], dx     ; Z high
40C8  mov  [bp+0x14], ax     ; Z low, zero
40D4  add  bp, 0x35          ; 53 bytes per entry
40D7  cmp  bp, 0xF8E
```

The coordinate goes into the **high** word and the low word is cleared, so the
world is 16.16 fixed point and `[0x3984]` is the integer part of the aircraft's
Y. The same routine spawns entries into a 53-byte-per-entry table, so this is
where objects are created at the aircraft's position — a weapon release or
similar.

#### The unit: four feet

Aircraft altitude and world object coordinates go into the *same structure
fields*, so they share a scale. With that, everything is consistent at **four
feet per unit**:

| Value | Display | What |
|---:|---:|---|
| -3000 | 11,920 | the starting altitude, set at `0x4E97` |
| -75 | 220 | ground proximity test at `0x3F01` |
| -20 | 0 | ground level, and the value `0x946C` compares against |

The manual's numbers line up: it gives around 4,000 ft on approach and 300 to
400 ft over the runway, against a mission start at 11,920 and a ground check at
220.

An earlier note left this open on the grounds that models run 40 to 1300 units
across, so a 260-unit control tower would be over a thousand feet. **That
objection was wrong**: it assumed model space and world space share a scale, and
they do not. The original's own converter normalises every model to a fixed
extent when building its object file, which is only sensible if model
coordinates are arbitrary and get scaled at instancing time.

## State found so far

| Address | Meaning | How it is known |
|---|---|---|
| `[0x347C]` | frame delta, clamped to 25 | computed at `0xEFCE`, read by the physics |
| `[0xF895]` | free-running timer | source of the delta |
| `[0x6327]` | the timer's value last frame | |
| `[0xA720]` | game state, 0..12 | indexes the table at `0xA6D7` |
| `[0xF3A2]` | theatre | tested at `0xCC8C`, `0x438D`, `0x75FC` |
| `[0xAE68]` | **airspeed**, eight per knot, 3200 = 400 kt at start | the immediate of `mov bx,imm` at `0xAE67`, integrated by `0x5260` at `0x52FA`, capped at `0x5211`, displayed as `>> 3` |
| `[0xA81E]` | **heading**, 2048 to the circle, starts at 1024 = due south | written each frame at `0x511E`, initialised at `0xEF06` |
| `[0x3984]` | **vertical position**, four feet per unit, negative upward, ground at -20, starts at -3000 | the immediate of `mov [bp+0x12],imm` at `0x3981`; written at `0x4EA0` |
| `[0x398E]` | the paired horizontal coordinate | the immediate at `0x398B`, read alongside `[0x3984]` |
| `[0xFF7E]` | two 3-bit device states, escalated by overspeed | `0x4EB6`, limits 260/365 and 242/325 kt |
| `[0x5115]` | altitude, positive form; `-[0x3984]` | init at `0x4E97`, airborne test at `0x4F22` |
| `[0x5084]` | **pitch attitude**, 16-bit angle, decays to level | integrated at `0x5071`, ground-limited at `0x53CD`, `0x5565` -> `[0xA81B]` |
| `[0x4FCC]` | **bank angle**, 16-bit angle, decays to level | `0x5565` -> `si` at `0x4FD1`, then `cos(si)` and `sec(si)` |
| `[0x4FDB]` | **pitch command** | `mov ax,imm` at `0x4FDA`; drives pitch rate and load factor |
| `[0x5119]` | **heading accumulator**, 16-bit angle | `0x50AD` onward, `0x5565` -> `[0xA81E]` |
| `[0x510F]` | altitude fraction, low word of the 16.16 pair with `[0x5115]` | `mov [0x510F],ax` at `0x5154` |
| `[0xAB64]` | **load factor**, tenths of g, 10 = 1 g, envelope -3..+9 g | target from `0x5416`, rate-limited at `0x5051`; divides thrust at `0x528A` |
| `[0xB43A]` | **throttle**, 0..500 with idle at 135 | integrated and clamped at `0x9E6B`, used at `0x5280` |
| `[0xAF81]` bit 3 | cleared by `0x52FF` and on ground contact at `0x513C` | |
| `[0xFF7D]` bit 1 | gated "flying" flag, sticky | updated at `0x4F29`/`0x4F36` only while `[0xFB32]` bit 7 and `[0xFF7C]` bit 1 hold; set above 80 ft and 16 kt |
| `[0xFB3A]` | flag byte, bit 3 gates `0xB1B8` | |

## Open

- The rest of the aircraft state block. `[0x347B]` holding the frame delta as
  the high byte of a word means it is used as 8.8 fixed point, which is likely
  the format the whole model works in.
- Seven of `0xCC8C`'s eighteen callees are only previewed, not read:
  `0x1F3A`, `0x314E`, `0x3160`, `0x3644`, `0x3F62`, `0x40A3`, `0x9811`.
- Which structure `0xCFB3`'s CRC-16 actually protects, and what the
  `0xCF81`/`0xCF5D` record codec pair's fields mean — both are mechanically
  understood but not tied to game data yet.
- What reads the three flags `0x42BD` masks (`0xB3D8`, `0xB3E6`, `0xB3F4`).
- The thirteen state handlers, of which only the in-flight one has been looked
  at at all.
- Two self-modified flags gate parts of the loop, at `0xEFE0` and `0xF26E`.
  `0xF288` writes both; `0xEFE0` is also set to `1` at spawn (`0xEEEC`, the
  same block that arms the three `0x42BD` flags and the sound gate). Whatever
  `0xF288` does thereafter still decides which paths run.
