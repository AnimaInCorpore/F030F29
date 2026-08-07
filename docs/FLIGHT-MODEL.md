# The flight model

`0x4EB6` is the aircraft update. The game loop calls it when a self-modified
flag is set, and it dispatches into `0x5000`-`0x5500`, a region that holds
almost the whole model.

The variable inventory is in [GAME-LOOP.md](GAME-LOOP.md); the reading
techniques are in [X86DISASSEMBLE.md](X86DISASSEMBLE.md).

## Units and conventions

Everything is fixed point, and the scales were settled by finding the instrument
routine that displays each quantity.

| Quantity | Address | Unit | Start |
|---|---|---|---|
| Airspeed | `[0xAE68]` | 8 per knot | 3200 = 400 kt |
| Altitude | `[0x510F]`/`[0x5115]` | 16.16, 4 ft per unit, ground at 20 | 3000 = 11,920 ft |
| Altitude, negated | `[0x397F]`/`[0x3984]` | the same, axis down | -3000 |
| Heading | `[0x5119]` → `[0xA81E]` | 16-bit angle → table offset | 1024 = due south |
| Pitch | `[0x5084]` → `[0xA81B]` | likewise | |
| Bank | `[0x4FCC]` | 16-bit angle | |
| Pitch command | `[0x4FDB]` | | |
| Load factor | `[0xAB64]` | signed byte, **10 = 1 g** | 10 |
| Throttle | `[0xB43A]` | 0..500, idle at 135 | |
| Frame delta | `[0x347C]` | ticks, clamped to 25 | |
| | `[0x347B]` | the same as 8.8 fixed point | |

Every one of these except `[0xAB64]` and `[0xB43A]` is an instruction immediate,
patched in place — see [GAME-LOOP.md](GAME-LOOP.md).

### Angles: 16 bit internally, a byte offset for use

`0x5565`, called from four places, is six instructions:

```
5565  rol  ax, 1
5567  rol  ax, 1
5569  xchg al, ah
556B  shl  ax, 1
556D  and  ah, 7
5570  ret
```

Rotating left twice then swapping bytes is a rotate left by ten; the `shl` makes
it eleven, and the mask keeps eleven bits. Because `shl` shifts a zero into
bit 0, **the result is always even**:

```
result = ((ax >> 6) & 0x3FF) * 2
```

That is a **10-bit angle, 1024 steps to the circle, pre-doubled into a byte
offset** for the word tables below. The eleventh bit exists because the value is
an offset, not because the angle has 2048 steps.

### The trig table at `0x143A`

`imul word ptr [si+0x163A]` and `imul word ptr [di+0x143A]` read the same table.
Correlating the region against a sinusoid settles it outright:

```
0x143A words, 1024 entries:  max deviation from 32767*sin(2*pi*i/1024)  =  1
0x163A words, 1024 entries:  max deviation from 32767*cos(2*pi*i/1024)  =  1
```

One 1024-entry signed 16-bit **sine** table at `0x143A`, with the **cosine** as
the same table 512 bytes — a quarter circle — further on. The region spans
`0x143A`-`0x1E39`, 2560 bytes, and nothing writes to it.

The inverse is at `0x1401`: a seven-step binary search with a stride that halves
from 64, then `and bl, 0xFE` to make the result a word offset again. `0x1427`
and `0x1430` are its quadrant fixups, computing `0x1F3A - cx` and `0x203A - cx`
masked with `and bh, 7` — reflections about 135 and 180 degrees.

## Load factor

`[0xAB64]` is the centre of the model. **The unit is tenths of g: 10 is 1 g.**
Everything else hangs off it — induced drag, the speed envelope, and the
manoeuvre envelope.

### `0x5416` computes the target

The routine takes the pitch command in `ax` and the envelope limit in `cl`, and
returns the g the aircraft should be pulling:

```
5416  push cx
5417  sar  ax, 1
5419  cmp  ax, 0x2D00 / mov ax,0x2CFF    ; clamp to +-11519, so that
5421  cmp  ax, 0xD300 / mov ax,0xD301    ;   the byte divide cannot overflow
5429  mov  cl, 0x5A
542B  idiv cl                            ; pitch command / 90
542D  mov  bl, al
542F  call 0x5450                        ; al = the g needed to hold the bank
5432  pop  cx
5433  cmp  cl, al
5435  jge  .1
5437  add  al, cl / shr al, 1            ;   over the limit: average with it
.1
543B  add  al, bl                        ; plus the commanded part
543D  jo   .ovf
543F  cmp  al, 0xE2 / jl  .lo            ; -30
5443  cmp  al, 0x5A / jg  .hi            ; +90
```

`0x5450` is the piece that names the quantity:

```
5450  mov  cx,[si+0x163A]     ; cos(bank) * 32767
5454  cmp  cx, 0xA    / jb .out
5459  cmp  cx, 0xFFF6 / ja .out          ; reject |cos| near zero
545E  mov  ax, 0xFFFF
5461  mov  dx, 4
5464  idiv cx                            ; 327679 / (32767 * cos)  =  10 * sec
5466  abs
546C  cmp  ax, 0x64 / jae .out           ; bail above 100, which is 10 g
5471  mov  dl, al
5473  mov  al, 0x14
5475  imul ch                            ; 20 * high byte of the cosine
5477  add  ax, 0x80
547A  mov  al, 0xF6                      ; -10
547C  add  al, dl
547E  add  al, ah
```

`327679 / (32767 · cos φ)` is **`10 · sec φ`**, and `n = 1/cos φ` is the load
factor in a level turn. The rest is `-10` and `+10 · cos φ`, so:

```
0x5450  =  10*n - 10 + 10*cos(bank)
```

**At wings level that is exactly 10.** The reject above 100 is a 10 g cut-off,
and the reject at `|cos| < 10/32767` keeps `sec` from blowing up near 90 degrees
of bank.

So the answer to what `0x5416` returns is not an angle at all:

```
target = pitch_command/180 + 10*sec(bank) - 10 + 10*cos(bank)
```

soft-limited against the envelope in `cl`, and clamped to **-30 … +90, which is
-3 g to +9 g**. That is a fighter's structural envelope, and the asymmetry is
the giveaway — aircraft pull far harder than they push. The `/90` scaling the
pitch command is not a degree conversion; it is what turns the command's range
into tenths of g.

Four independent facts agree on the unit:

- wings level, no command, comes out at exactly **10**;
- on the ground below 70 knots the target is forced to **10** (`0x504F`);
- the induced-drag divisor in the speed equation floors at **10** (`0x529B`);
- the speed envelope table's buckets are ten wide with a dead zone of five, so
  they straddle whole g.

### It is rate limited into `[0xAB64]`

```
503A  mov  ax,[0x4FDB]           ; pitch command
503D  call 0x5416                ; -> the target
5040  cmp  word [0x5115], 0x14
5045  jg   .1
5047  cmp  word [0xAE68], 0x230  ; on the ground below 70 kt
504D  jae  .1
504F  mov  al, 0x0A              ;   pinned at 1 g
.1
5051  mov  ah, al
5053  sub  ah,[0xAB64]           ; difference from the current value
5057  jns  .2
5059  neg  ah
.2
505B  sub  ah,[0x347C]           ; minus one frame delta
505F  jbe  .3                    ;   within reach: snap
5061  cmp  al,[0xAB64]
5065  js   .4
5067  neg  ah
.4
5069  add  al, ah                ; else move by the delta
.3
506B  mov  [0xAB64], al
```

One tenth of a g per frame delta tick. Pinning it to 1 g on the runway is the
weight sitting on the undercarriage.

### The manoeuvre envelope at `0x5485`

`cl` comes from a table looked up just before the call:

```
501A  mov  al,[0x5116]      ; altitude >> 8
501D  and  al, 0x38         ;   bits 3..5
501F  mov  ah, al
5021  shr  ah,1 / shr ah,1
5025  add  ah, al           ; ah = 1.25 * al, so a row stride of 10
5027  mov  al,[0xAE69]      ; airspeed >> 8
502A  shr  al, 1            ;   >> 9
502C  mov  cl, 0x0F
502E  cmp  al, 0x0A
5030  jae  .out             ; above 640 kt the limit is a flat 1.5 g
5032  add  al, ah
5034  mov  bx, 0x5485
5037  xlatb
5038  mov  cl, al
```

Eight rows of ten, indexed by altitude in 8,192 ft steps and airspeed in 64 kt
steps — **80 bytes, filling `0x5485`-`0x54D4` exactly**, with the speed
envelope tables starting immediately after. The index arithmetic can produce 79
and no more, which is the kind of exact fit that settles a table's extent.

Its shape is a manoeuvre chart: it climbs with speed to a peak of 8.3 g at
around 256 knots at sea level, falls away at both ends, and decays monotonically
with altitude to the 1.5 g floor. The limit is *soft* — exceeding it averages
the demand with the limit rather than truncating, so the aircraft mushes instead
of hitting a wall.

## Airspeed

`0x5260` integrates thrust against drag directly into `[0xAE68]` every frame;
a second, independent block caps the result against a g/altitude ceiling.

### The target: thrust against drag

```
5260  mov  bl, 0x3F
5262  sub  bl, byte ptr [0x5116]   ; 63 minus the altitude's high byte
5266  mov  ax, 6
5269  mov  cx,[0xAE68]             ; airspeed
526D  cmp  cx, 0x1220              ; 4640, which is 580 kt
5271  jb   .below
5273  add  cx, 0x50                ;   above that, add 80 first
.below
5276  shr  cx, 1
5278  mul  cx                      ; 6 * speed/2
527C  add  bl, ah                  ;   the high byte, into the drag term
527E  rcl  bh, 1                   ;   carry out, so bx is nine bits

5280  mov  ax,[0xB43A]             ; throttle, 0..500
5283  sub  ax, 0x87                ;   minus 135
5286  jae  .1
5288  sub  ax, ax                  ;   clamped at zero
.1
528A  mov  cl,[0xAB64]             ; load factor
528E  or   cl, cl
5290  jns  .2
5292  neg  cl                      ;   magnitude
.2
5296  cmp  cl, 0xA
5299  jae  .3
529B  mov  cl, 0xA                 ;   floored at 1 g
.3
529D  shl  ax,1 (three times)      ; thrust * 8
52A3  cdq
52A4  idiv cx                      ;   / max(|n|, 1 g)
52A6  xchg dx, ax                  ; dx = the quotient
52A7  mov  al,[di+0x143B]          ; sin of the pitch angle, high byte
52AB  cwde
52AC  shl  ax, 1
52AE  sub  dx, ax                  ;   minus twice it
52B0  sub  dx, bx                  ; minus the drag term
52B2  shr  bx,1 / shr bx,1
52B6  sub  dx, bx                  ;   and a quarter more, so 1.25x

52B8  cmp  word [0x5115], 0x14     ; altitude at or below 20 units
52BD  jg   .1
52BF  sub  dx, 0x32                ;   on the ground: another 50 off
.1
52C2  test byte [0xFF7D], 2        ; the gated "flying" bit, see below
52C7  je   .2
52C9  sub  dx, 0x99                ;   flying: another 153 off
.2
52CD  mov  al,[0xFF7E]
52D0  xor  al, 2
52D2  test al, 3
52D4  jne  .3
52D6  sub  dx, 0xF                 ;   device deployed, not critical: another 15 off
.3
52D9  shl  dx, 1 (twice)           ; *4
52DD  mov  ax,[0x347B]             ; frame delta, 8.8
52E0  imul dx
52E2  shl  ax,1 / rcl dx,1         ; *2, so *8 total
52E6  add  word [0x4E84], ax       ; accumulate into a 32-bit pair,
52EA  adc  dx, word [0xAE68]       ;   high word is the airspeed itself
52EE  cmp  dh, 0x20 / clamp        ; ceiling ~0x1FFF (1023 kt) or floor 0
52FA  mov  [0xAE68], dx
52FE  ret
```

Written out, the target from thrust and drag is:

```
target = 8*(throttle - 135) / max(|n|, 10) - 2*sin(pitch) - 1.25*drag
         - 50*[on the ground] - 153*[flying] - 15*[device out, not critical]
```

Then the whole thing is multiplied by the frame delta and **added** to a
32-bit accumulator whose high word *is* `[0xAE68]` — this is the entire
airspeed update, done in one pass, clamped to roughly 0..1023 kt. There is no
separate rate limiter for it; `target` is a rate of change, not a value the
speed chases toward.

**Thrust is throttle above an idle offset of 135**, clamped so that closing the
throttle below idle gives zero rather than negative thrust.

**Pulling g costs speed.** Dividing thrust by the load factor is induced drag,
done in one instruction, and the floor at 1 g means level flight gets the full
value.

**Drag is linear in speed, with a break at 580 knots.** Above 4640 the speed is
bumped by 80 before the multiply, so the curve steepens — transonic drag rise,
one compare and one add.

**Thrust falls with altitude.** `[0x5116]` is the high byte of `[0x5115]`, so
the constant term is `63 - (altitude >> 8)`: 63 at sea level, 52 at the
3000-unit start. Air density, at the cost of one byte read.

**Climbing costs speed** through the `-2*sin(pitch)` term, which is gravity
along the flight path.

**Three flat penalties stack on top.** Ground rolling resistance (-50) is
straightforward. The device penalty (-15) uses the same field A tested in the
energy routine below, and fires under the same condition: deployed but not at
the worst overspeed stage. `[0xFF7D]` bit 1 is not simply "airborne" — the full
gate, at `0x4F14`-`0x4F36`, only updates it while `[0xFB32]` bit 7 and
`[0xFF7C]` bit 1 both hold, and it is *sticky* otherwise, keeping its last
value rather than resetting every frame. `[0xFF7C]` mirrors `[0xFF7E]`'s
two-field layout and is initialised the same way at `0xEEAC`, but which device
it tracks is not yet established. With that caveat, the -153 penalty reads as a
configuration-dependent drag term — a device that adds drag once the aircraft
is properly established in the air.

### The airspeed ceiling from the energy routine

The speed `0x4EB6` reads back and compares against its band thresholds is not
simply what `0x5260` just wrote. Right after it, at `0x51F1`, a second block
caps it:

```
51F1  call 0x5260
51F4  mov  ax,[0xAE68]
51F7  mov  dx, 0            ; patched by 0x52FF from the table at 0x551D
51FA  cmp  ax, dx
51FC  jle  .done             ; below the ceiling: leave it alone
51FE  mov  cl,[0x347C]
5202  sub  ch, ch
5204  shl  cx, 1
5206  sub  ax, cx (three times)   ; bleed off 6 units per frame delta
520C  cmp  ax, dx
520E  jge  .store
5210  xchg dx, ax                ; do not overshoot below the ceiling
.store
5211  mov  [0xAE68], ax
```

This only fires when the current speed **exceeds** a ceiling that `0x52FF`
computes fresh every frame from a second envelope table. It is a hard cap
layered on top of the thrust/drag equilibrium above, not a general-purpose
rate limiter — see the energy routine below for where the ceiling comes from.

### The throttle

`0x9E6B` is the integrator behind `[0xB43A]`:

```
9E6B  add  ax,[0xB43A]
9E6F  cmp  ax, 0x1F4        ; 500
9E72  jb   .store
9E74  mov  ax, 0x1F4        ;   clamp high
9E77  jns  .store
9E79  sub  ax, ax           ;   clamp low, if the sum went negative
.store
9E7B  mov  [0xB43A], ax
```

Accumulate a delta, clamp to 0..500, with idle at 135.

## Attitude and position

The order of operations in `0x4FCB`-`0x51A0` is the whole integration.

**Pitch rate** is the commanded pull resolved out of the bank and scaled by
speed:

```
4FCB  mov  ax, 0            ; <- [0x4FCC], the bank angle
4FCE  call 0x5565
4FD1  mov  si, ax           ; si = the bank's table offset
4FDA  mov  ax, 0            ; <- [0x4FDB], the pitch command
4FEA  imul word ptr [si+0x163A]        ; * cos(bank)
4FEE  clamp dx to +-0x1000
5002  sar  dx,1 / rcr ax,1
5006  mov  cx,[0xAE68]
500A  cmp  cx, 0x7D0 / mov cx, 0x7D0   ; floored at 250 kt
5013  shl  cx,1 / shl cx,1
5017  idiv cx                          ; / (4 * speed)
5019  xchg di, ax
```

`cos(bank)` is the share of the pull that raises the nose; the `sin(bank)` share
goes to the heading at `0x50CD`. Dividing by speed with a floor is the standard
way to scale control authority so it cannot blow up at a standstill.

That rate is integrated into the pitch attitude at `0x5071`, constrained by
`0x53CD`, and converted to a table offset:

```
5071  mov  ax, di
5073  imul word ptr [0x347B]
5077  shl/rcl three times              ; * 8
5083  mov  ax, 0                       ; <- [0x5084], the pitch attitude
5086  add  ax, dx
5098  call 0x53CD                      ;   ground constraint
509B  call 0x5565
509E  mov  [0xA81B], ax
```

**Heading** accumulates the bank, weighted by `cos(pitch)` so that pointing
straight up stops the turn, plus the `sin(bank)` share of the pull:

```
50AD  mov  cx,[0x5119]                 ; the heading accumulator
50B1  imul word ptr [di+0x163A]        ; bank * cos(pitch)
50B5  sar  dx,1 (five times)
50BF  add  cx, dx
50C8  mov  ax,[0x4FDB]
50CD  imul word ptr [si+0x143A]        ; pitch command * sin(bank)
50F7  xchg cx, ax / add ax, dx
50FA  mov  [0x5119], ax
511B  call 0x5565
511E  mov  [0xA81E], ax
```

**Position** is then the usual resolution of speed through pitch and heading,
into 16.16 accumulators — three of them, X, Y (altitude) and Z, each carrying
a fifth **overflow byte** beyond the 32-bit pair:

```
5123  mov  ax,[0x347B]
5126  imul word ptr [0xAE68]           ; speed * delta
512A  mov  cx, dx
512C  mov  ax,[di+0x143A]              ; sin(pitch)
5130  imul cx                          ;   -> the vertical share
5132  add  ax, bp / adc dx, bp         ;   bp:pushed-dx carry from the energy term, see below
5137  cmp  dx, 0x14 / clamp to 20      ;   ground contact
5146  cmp  dh, 0x40 / clamp to 0x3FFF  ;   ceiling
5154  mov  [0x510F], ax                ; Y low
5157  mov  [0x5115], dx                ; Y high
515B  not dx / neg ax / sbb dx,-1      ; negate, 32 bit
5162  mov  [0x397F], ax                ; the down-positive mirror, low
5165  xchg [0x3984], dx                ;   and high
516C  mov  ax,[di+0x163A]              ; cos(pitch) -> the horizontal share
5170  imul cx                          ;   cx is [0x347B]*[0xAE68]'s high word, from 512A
5172  shl ax,1 / rcl dx,1              ; *2
5176  mov  cx, dx                      ; cx = the horizontal magnitude
5178  mov  ax,[bx+0x143A] / neg ax     ; bx = heading offset; -sin(heading)
517E  imul cx                          ;   -> X
5180  add  [0x3975], ax                ; X low
5184  mov  ax,[0x397A]                 ; X high, with carry
518A  adc  ax, dx
518C  mov  [0x397A], ax
518F  mov  al, dh / cbw                ; sign of the high word, extended
5192  adc  byte [0x5245], ah           ;   -> X's overflow byte
5196  mov  ax,[bx+0x163A]              ; cos(heading) -> Z
519A  imul cx
519C  add  [0x3989], ax                ; Z low
51A0  mov  ax,[0x398E]                 ; Z high, with carry
51A6  adc  ax, dx
51A8  mov  [0x398E], ax
51AB  mov  al, dh / cbw
51AE  adc  byte [0x5246], ah           ;   -> Z's overflow byte
```

X and Z are 16.16 like Y, but each has an extra byte at `[0x5245]`/`[0x5246]`
that accumulates the sign-extended carry out of the 32-bit pair — the standard
way to widen a fixed-point accumulator by one more byte of range without
widening every intermediate operation. Altitude does not get this treatment,
which fits: a flight sim's vertical extent is naturally far smaller than its
horizontal one. With the extra byte, X/Z span roughly +-8 million units, or
about 6,300 miles at four feet each — continental scale, against the ~25 miles
a plain 16.16 pair alone would allow.

Ground contact clamps the altitude to 20 and clears bit 3 of `[0xAF81]`, which
is the same bit the energy routine below clears each frame.

## Energy: the speed envelope and stall departure

`0x52FF` does three things in one pass: it adds a term to the **altitude**
(not the heading — an earlier pass through this routine mislabelled it "turn
rate"), it sets the airspeed ceiling consumed at `0x51F7` above, and it can
force the aircraft out of a bank it cannot sustain.

### Two tables, one index

The row/column index is the same arithmetic documented for the manoeuvre
envelope — altitude in steps of 4,096 ft, load factor in buckets of one g —
and it is shared by two 9x8 tables:

```
52FF  and  byte [0xAF81], 0xF7    ; clear the flag bit
5304  mov  al,[0xAB64]            ; load factor
5307  abs
530D  sub  al, 5
530F  jae  .2
5311  sub  al, al                 ;   dead zone of half a g
.2
5313  aam  0x0A                   ; ah = al/10, al = al%10
5315  mov  al, 7
5317  cmp  ah, al / jg .3
531B  mov  al, ah                 ; column = min((|n|-5)/10, 7)
.3
531D  sub  bh, bh
531F  mov  bl,[0x5116]            ; altitude >> 8
5323  shl  bl, 1
5325  cmp  bl, 0x48 / mov bl,0x40
532C  and  bl, 0x78               ; row, a multiple of 8
532F  or   bl, al                 ; bx = the shared table offset
```

Dumping both tables by that index shows what they are:

```
0x54D5 (adjusted -23 when deployed, see below), row=altitude/4096ft, col=|n| bucket:
     0     23   44   57   68   78   88   98  109
  4096     27   47   61   74   85   95  105  115
  8192     30   54   71   85  146  163  180  187
 ...        (grows with both altitude and g)
 32768    173  187  204  221  238  255  255  255

0x551D, same index:
     0    153  149  146  143  139    0    0    0
  4096    173  166  160  149  143    0    0    0
  8192    197  194  180  156  126    0    0    0
 ...        (falls to 0 as g and altitude both climb)
 32768    190    0    0    0    0    0    0    0
```

Both, scaled by 32, are airspeed-sized quantities. Table `0x54D5` **grows**
with g and altitude — a minimum/reference speed, the way true stall speed
grows with load factor and, in true-airspeed terms, with altitude. Table
`0x551D` **shrinks** to zero as both climb — a structural ceiling, the rounded
top corner of a V-n diagram. Between the two lies the speed band the aircraft
can actually sustain at a given g and altitude; `0x551D` is exactly the ceiling
patched into `0x51F7`'s comparison above.

### The climb term and the stall/departure branch

```
5331  mov  al,[0xFF7E]
5334  xor  al, 2
5336  test al, 3
5338  mov  al,[bx+0x54D5]         ; table A, the reference speed
533C  mov  ah, bh
533E  jne  .5
5340  sub  ax, 0x17               ;   deployed, not critical: minus 23
.5
5343  shl  ax, 1 (five times)     ; *32, matching the table dump above
534D  xchg cx, ax                 ; cx = the reference speed
534E  mov  al,[bx+0x551D]         ; table B, the ceiling
5352  mov  ah, bh
5354  shl  ax, 1 (five times)     ; *32
535E  mov  [0x51F8], ax           ; -> the ceiling used at 0x51F7

5361  mov  ax,[si+0x163A]         ; cos(bank), si = bank's table offset
5365  mov  al,[di+0x163B]         ;   overwritten with cos(pitch)'s high byte
5369  imul ah                     ; K = coarse cos(pitch) * coarse cos(bank)
536B  shl  ax, 1
536D  mov  dx,[0xAE68]
5371  sub  dx, cx                 ; margin = speed — reference speed
5373  jae  .comfortable
```

`al` in `{2, 6}` — bit 1 set, bit 0 clear, deployed but not at the worst
escalation — is when the -23 adjustment fires, not when the device is stowed.
23 is the table's sea-level 1 g entry, so with the device out, clean, level,
sea-level flight reads zero; without this check, the reference speed is 23
higher — extending flaps or gear buys a lower minimum speed, which is what a
high-lift device does.

`K = cos(pitch)*cos(bank)`, coarse (byte-scale) versions of both, is a
wings-and-nose-level factor: maximal when flying straight and level, small or
negative in an extreme attitude.

**Comfortably above the reference speed** (`margin >= 0`):

```
.comfortable (5391)
5391  shl  dx, 1 (twice)          ; margin * 4, high byte in dh
5395  mov  al, dh
5397  imul ah                     ; al(margin) * ah(K)
loc_5399:
5399  sub  ah, 0xC
539C  ret
```

The returned value — margin above the reference speed, times the level-flight
factor K, less a fixed offset — is what the caller (`0x50FD`) scales by
`delta/16` and adds into the altitude accumulator. More excess speed and a
more level attitude convert to more climb.

**Short of the reference speed** (`margin < 0`), a partial recovery is tried
first — `dx += cx/4` — and if that is enough (`jae`), the same climb-term path
runs on the reduced margin. If it is *still* short:

```
539D  mov  ax,[0x347B] / shr x2 / neg      ; -delta/4
53A6  add  ax,[0x5084]                     ; compared against the pitch attitude
53AD  cmp  ax, 0xC001
53AF  jg   .keep_flying
53B1  sub  ax, ax
53B3  mov  si, ax                          ; si = 0 (bank's table offset for angle 0)
53B5  xchg [0x4FCC], ax                    ; bank <- 0, forced level
53B9  add  ax,[0x5119]                     ; the old bank folds into heading
53BD  mov  [0x5119], ax                    ;   -> an uncommanded yaw
53C1  call 0x53CD                          ; reclamp pitch
53C4  or   byte [0xAF81], 8                ; the departure flag
53C9  sub  ax, ax
53CB  jmp  loc_5399                        ; returns 0 — 0xC00, a fixed sink
```

Below a large enough deficit, the aircraft cannot hold the g it is being asked
for at this speed and altitude: the bank is forced to zero, the bank it *had*
is dumped into the heading accumulator as an uncommanded yaw, pitch is
reclamped, `[0xAF81]` bit 3 is set, and the altitude term becomes a fixed sink.
A wing drop that becomes a yaw, and a flag the rest of the code can key a
warning or a control lockout on — a stall/departure model, not a hard failure.

The milder deficit that doesn't reach this branch instead returns a term
derived from the margin alone via a plain division (`0x5381`), smaller than the
K-scaled climb term — an in-between case, still short of departure.

## Ground handling

`0x53CD` constrains the pitch attitude, and only near the ground:

```
53CD  cmp  word [0x5115], 0x14   ; altitude at or below 20 units
53D2  jg   .store                ;   airborne: no constraint at all
53D4  mov  dx,[0x347B]           ; frame delta, 8.8
53D8  shr  dx,1 / shr dx,1       ;   / 4
53DC  or   ax, ax
53DE  js   .neg
53E0  shr  dx,1 / shr dx,1       ;   / 16 for the nose-up side
53E4  sub  ax, dx
53E6  jmp  .clamp
.neg
53E8  add  ax, dx
.clamp
53EA  jae  .1
53EC  sub  ax, ax                ; do not cross zero
.1
53EE  mov  dx,[0xAE68]           ; airspeed
53F2  shl  dx, 1
53F4  cmp  dh, 8
53F7  jb   .2
53F9  mov  dx, 0x7FF             ;   upper limit = min(speed*2, 2047)
.2
53FC  cmp  ax, dx
53FE  jb   .store
5400  jg   .clamp_dx
5402  cmp  dh, 1
5405  jb   .3
5407  mov  dx, 0x100             ;   lower limit = -min(speed*2, 256)
.3
540A  neg  dx
540C  cmp  ax, dx
540E  jge  .store
.clamp_dx
5410  mov  ax, dx
.store
5412  mov  [0x5084], ax
5415  ret
```

Ground level is `[0x5115] = 20`, so the test selects **on the ground** and the
airborne case returns the input untouched.

On the ground the attitude bleeds toward level and is clamped to a
speed-dependent envelope:

| Side | Limit | As an angle |
|---|---|---|
| nose up | `min(speed * 2, 2047)` | up to 11 degrees |
| nose down | `-min(speed * 2, 256)` | 1.4 degrees |

**Rotation authority that grows with airspeed, eight times more of it up than
down.** That is the undercarriage: you cannot rotate until you have speed, and
the nose cannot go through the tarmac.

## Aerodynamic stability

Pitch and bank both decay toward level when nothing drives them:

```
4F49  mov  di, cx              ; delta
4F4B  shl  di,1  (five times)  ; di = delta * 32
4F55  mov  ax,[0x5084]
4F58  mov  bx, ax              ;   keep the sign
4F5C  jns  .positive
4F5E  neg  ax
.positive
4F60  sub  ax, di              ;   reduce by 32 * delta
4F62  jae  .ok
4F64  sub  ax, ax              ;   clamp at zero
.ok
4F68  jns  .done
4F6A  neg  ax                  ;   sign back
.done
4F6C  mov  [0x5084], ax
```

The same block then repeats for `[0x4FCC]`. Reduce the magnitude, clamp, restore
the sign — an aircraft returning to wings level and level flight at 32 units of
angle per frame delta.

## Device states

`0x4EB6` opens by escalating two independent three-bit fields packed into
`[0xFF7E]`, one per byte:

```
4EB6  mov  cx,[0xAE68]        ; airspeed
4EBA  mov  ax,[0xFF7E]
4EBD  and  ax, 0x303
4EC0  test al, 2
4EC4  cmp  cx, 0x820          ; 260 kt -> or al,4
4ECC  cmp  cx, 0xB68          ; 365 kt -> mov al,7
4ED4  test ah, 2
4ED9  cmp  cx, 0x790          ; 242 kt -> or ah,4
4EE2  cmp  cx, 0xA28          ; 325 kt -> mov ah,7
4EEA  mov  [0xFF7E], ax
```

At spawn (`0xEEAC`-`0xEEAF`) field A (the low byte) is 0, stowed, and field B
(the high byte) is 2, deployed — different starting states for what look like
different devices, consistent with undercarriage and flaps at the start of a
flight: one out, one not. Whatever pilot action sets field A to 2 has not been
found yet. Once deployed, a field escalates to 6 and then 7 as speed passes its
two limits, which is overspeed damage. Field A's deployed-not-critical state
(`2` or `6`) lowers the reference speed in the energy routine below, which is
what a high-lift device does.

## Data regions proven so far

All of these are in the disassembler's `KNOWN_DATA` guard, so no future attempt
to widen coverage can quietly turn them into code.

| Range | Bytes | What |
|---|---:|---|
| `0x143A`-`0x1E39` | 2560 | sine table, 1024 words, cosine 512 bytes on |
| `0x5485`-`0x54D4` | 80 | manoeuvre envelope (max g), 8 altitudes x 10 speeds |
| `0x54D5`-`0x551C` | 72 | speed envelope, reference/minimum, 9 altitudes x 8 load factors |
| `0x551D`-`0x5564` | 72 | speed envelope, ceiling, same index |

The values themselves are game data and stay out of this repository; the asset
converter reads them at build time on the user's machine.

## Open

- Which device field A and field B in `[0xFF7E]` (and the parallel `[0xFF7C]`)
  actually are, and what pilot action sets field A to deployed — only the
  overspeed escalation and the spawn state have been found.
- The exact scale of the energy term returned by the stall/departure routine —
  its structural role is established, but not a real-world climb rate.
- The moderate-deficit path at `0x5381`'s precise shape; it clearly returns a
  smaller, division-based term than the comfortable-margin case, but has not
  been worked out instruction by instruction.
- `0x4188`, called from the model at `0x5241`, is a sound call —
  `lcall [0xFC14]` with `ah=0x10` — gated by a patched immediate at `0x418A`
  that doubles as the effect number and the on/off flag. Sound is deferred.
