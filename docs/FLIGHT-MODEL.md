# The flight model

`0x4EB6` is the aircraft update. The game loop calls it when a self-modified
flag is set, and it dispatches into `0x5000`-`0x5500`, a region that holds
almost the whole model.

What follows is what has been read so far: the units, the speed equation, the
turn rate, the ground constraint and the throttle. The variable inventory is in
[GAME-LOOP.md](GAME-LOOP.md); the reading techniques are in
[X86DISASSEMBLE.md](X86DISASSEMBLE.md).

## Units and conventions

Everything in the model is fixed point, and the scales were settled by finding
the instrument routine that displays each quantity.

| Quantity | Address | Unit | Start |
|---|---|---|---|
| Airspeed | `[0xAE68]` | 8 per knot | 3200 = 400 kt |
| Vertical position | `[0x3984]` | 4 ft, axis **down**, ground at -20 | -3000 = 11,920 ft |
| Altitude, positive | `[0x5115]` | `-[0x3984]` | 3000 |
| Heading | `[0xA81E]` | 2048 to the circle | 1024 = due south |
| Bank | `[0xAB64]` | signed byte, see below | |
| Throttle | `[0xB43A]` | 0..500, idle at 135 | |
| Frame delta | `[0x347C]` | ticks, clamped to 25 | |
| | `[0x347B]` | the same as 8.8 fixed point | |

World coordinates are 16.16 fixed point with the integer part in the high word.

### Angles: 16 bit internally, 11 bit for use

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
it eleven while dropping the top bit; the mask keeps eleven. The net effect is
**`(ax >> 5) & 0x7FF`**.

So the model carries angles as 16-bit fractions of a circle and converts to the
11-bit form — 2048 to the circle — whenever one is stored or used as an index.
Its results go to `[0xA81E]`, the heading, and `[0xA81B]`.

For the port: compute in 16 bits, store and index in 11.

## Airspeed

Two routines run back to back. `0x5260` computes the speed the aircraft *wants*
to be doing; `0x51F7` moves it there at a limited rate.

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
528A  mov  cl,[0xAB64]             ; bank
528E  or   cl, cl
5290  jns  .2
5292  neg  cl                      ;   magnitude
.2
5296  cmp  cl, 0xA
5299  jae  .3
529B  mov  cl, 0xA                 ;   floored at 10
.3
529D  shl  ax,1 (three times)      ; thrust * 8
52A3  cdq
52A4  idiv cx                      ;   / max(|bank|, 10)
52A6  xchg dx, ax                  ; dx = the quotient
52A7  mov  al,[di+0x143B]          ; a per-entity constant
52AB  cwde
52AC  shl  ax, 1
52AE  sub  dx, ax                  ;   minus twice it
52B0  sub  dx, bx                  ; minus the drag term
52B2  shr  bx,1 / shr bx,1
52B6  sub  dx, bx                  ;   and a quarter more, so 1.25x
```

Written out:

```
drag   = (63 - altitude>>8) + high_byte(6 * kink(speed)/2)
target = 8*(throttle - 135) / max(|bank|, 10) - 2*[di+0x143B] - 1.25*drag
```

Four things fall out.

**Thrust is throttle above an idle offset of 135**, clamped so that closing the
throttle below idle gives zero rather than negative thrust.

**Banking costs speed.** Dividing thrust by the bank magnitude is induced drag
in the turn, done in one instruction. The floor of 10 means level flight gets
the full value and nothing divides by zero.

**Drag is linear in speed, with a break at 580 knots.** Above 4640 the speed is
bumped by 80 before the multiply, so the curve steepens — transonic drag rise,
one compare and one add.

**Thrust falls with altitude.** `[0x5116]` is the high byte of `[0x5115]`, so
the constant term is `63 - (altitude >> 8)`: 63 at sea level, 52 at the
3000-unit start. Air density, at the cost of one byte read.

### The rate limiter

```
51F7  mov  dx, 0            ; the target, patched in by 0x5260
51FA  cmp  ax, dx
51FC  jle  .done
51FE  mov  cl,[0x347C]      ; frame delta
5202  sub  ch, ch
5204  shl  cx, 1
5206  sub  ax, cx           ; three times 2*delta
5208  sub  ax, cx
520A  sub  ax, cx
520C  cmp  ax, dx
520E  jge  .store
5210  xchg dx, ax           ; do not overshoot
.store
5211  mov  [0xAE68], ax
```

Six units per frame delta, clamped against overshoot. This shape recurs
throughout the model: reduce toward a target at a fixed rate, never past it.

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

Accumulate a delta, clamp to 0..500. With idle at 135 the usable range is 135
to 500 forward and 0 to 135 as a retarding region — an airbrake or reverse, or
simply below-idle drag.

## Turn rate

`0x52FF` produces the rate at which the heading changes. Its result is scaled by
the frame delta at `0x50FD` and integrated into `[0xA81E]` through the angle
converter.

```
52FF  and  byte [0xAF81], 0xF7    ; clear a flag bit
5304  mov  al,[0xAB64]            ; bank
5307  or   al, al
5309  jns  .1
530B  neg  al                     ;   magnitude
.1
530D  sub  al, 5
530F  jae  .2
5311  sub  al, al                 ;   dead zone of 5
.2
5313  aam  0x0A                   ; ah = al/10, al = al%10
5315  mov  al, 7
5317  cmp  ah, al
5319  jg   .3
531B  mov  al, ah                 ; column = min(|bank|-5)/10, 7)
.3
531D  sub  bh, bh
531F  mov  bl,[0x5116]            ; altitude high byte
5323  shl  bl, 1
5325  cmp  bl, 0x48
5328  jb   .4
532A  mov  bl, 0x40               ;   clamped
.4
532C  and  bl, 0x78               ; row, a multiple of 8
532F  or   bl, al
5331  mov  al,[0xFF7E]
5334  xor  al, 2
5336  test al, 3
5338  mov  al,[bx+0x54D5]         ; <- the table
533C  mov  ah, bh
533E  jne  .5
5340  sub  ax, 0x17               ;   configuration penalty of 23
.5
5343  shl  ax, 1
```

**It is a two-dimensional table lookup at `0x54D5`, eight columns by nine rows.**

The column is the bank magnitude in buckets of ten with a dead zone of five,
saturating at bucket 7 — so bank magnitudes above 75 all give the maximum rate.

The row is `altitude >> 10`: `[0x5116]` is `altitude >> 8`, doubled and masked
to multiples of 8, so the row advances every 1024 altitude units. At four feet
per unit that is **one row per 4,096 feet**, nine rows covering the aircraft's
whole envelope. Turn rate falling with altitude is exactly right — thinner air
means a higher true airspeed for the same indicated, and a wider turn.

The table occupies `0x54D5`-`0x551C`, which sits inside the data gap between the
last instruction at `0x5484` and the next at `0x5565`. It is 72 bytes, and
nothing in the image writes to it.

The `[0xFF7E]` test costs 23 off the rate when the low two bits are not 2 — one
of the two device states penalising the turn.

### `[0xAB64]` is the bank angle

It has exactly two uses, and both are what bank does and nothing else does:

- it indexes the turn-rate table, and
- it divides thrust in the speed equation.

Rate of turn from bank, and speed bled off in a turn. The bucket size of ten
with saturation at 75 reads as degrees.

## Ground handling

`0x53CD` constrains the `[0x5084]` control axis, and only near the ground:

```
53CD  cmp  word [0x5115], 0x14   ; altitude at or below 20 units
53D2  jg   .store                ;   airborne: no constraint at all
53D4  mov  dx,[0x347B]           ; frame delta, 8.8
53D8  shr  dx,1 / shr dx,1       ;   / 4
53DC  or   ax, ax
53DE  js   .neg
53E0  shr  dx,1 / shr dx,1       ;   / 16 for the positive side
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

On the ground the axis bleeds toward zero — asymmetrically, at `delta/4` from
the negative side and `delta/16` from the positive — and is then clamped to a
speed-dependent envelope:

| Side | Limit |
|---|---|
| positive | `min(speed * 2, 2047)` |
| negative | `-min(speed * 2, 256)` |

**Authority proportional to airspeed, with eight times more of it one way than
the other.** That is a nosewheel on the runway: rotation authority grows as
speed builds, up to a large value, while the opposite deflection stays capped
because the nose cannot go through the tarmac.

## The control axes

`[0x5084]` and `[0x4FCC]` both centre themselves when nothing drives them:

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

Reduce the magnitude, clamp, restore the sign — a stick returning to neutral
when released, at 32 units per frame delta.

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

Each field starts at 2 when the device is deployed and escalates to 6 and then 7
as speed passes its two limits. Two devices with *different* limits — 260 and
365 against 242 and 325 — which is what undercarriage and flaps look like, the
escalation being overspeed damage. The turn-rate lookup reads the same byte.

## Position integration

```
5123  mov  ax,[0x347B]      ; frame delta as 8.8
5126  imul word ptr [0xAE68]
512A  mov  cx, dx           ; keep the high word
512C  mov  ax,[di+0x143A]   ; a direction component
5130  imul cx
5132  add  ax, bp           ; accumulate 32-bit
5135  adc  dx, bp
```

Speed times time times direction, summed into a 16.16 position. `[di+0x143A]`
and `[di+0x143B]` are fields of a per-entity record; `[si+0x163A]` below belongs
to the same family.

Control authority is scaled by speed at `0x5000`:

```
5002  sar  dx,1 / rcr ax,1   ; a 32-bit value, halved
5006  mov  cx,[0xAE68]
500A  cmp  cx, 0x7D0         ; floored at 2000, which is 250 kt
5010  mov  cx, 0x7D0
5013  shl  cx,1 / shl cx,1
5017  idiv cx
```

Dividing by speed with a floor is the standard way to scale control authority:
the faster you go, the less angular change a given input buys per unit of
distance, and at a standstill it cannot blow up.

## Not yet identified

`0x5416`, called only from `0x503D`, computes an angle-like quantity and clamps
it to the asymmetric range **-30 to +90**:

```
5416  push cx
5417  sar  ax, 1
5419  cmp  ax, 0x2D00 / mov ax,0x2CFF    ; clamp to +-11519 ...
5421  cmp  ax, 0xD300 / mov ax,0xD301    ;   so the byte divide cannot overflow
5429  mov  cl, 0x5A
542B  idiv cl                            ; / 90
542D  mov  bl, al
542F  call 0x5450
5432  pop  cx
5433  cmp  cl, al
5435  jge  .1
5437  add  al, cl / shr al, 1            ; average with the incoming cx
.1
543B  add  al, bl
543D  jo   .ovf
543F  cmp  al, 0xE2 / jl  .lo            ; -30
5443  cmp  al, 0x5A / jg  .hi            ; +90
```

and `0x5450` supplies a reciprocal term from a per-entity field:

```
5450  mov  cx,[si+0x163A]
5454  cmp  cx, 0xA    / jb .out          ; reject |cx| < 10 either sign,
5459  cmp  cx, 0xFFF6 / ja .out          ;   so the divide is safe
545E  mov  ax, 0xFFFF
5461  mov  dx, 4
5464  idiv cx                            ; 327679 / cx, about 5*65536/cx
5466  abs
546C  cmp  ax, 0x64 / jae .out           ; must come out under 100
5471  mov  dl, al
5473  mov  al, 0x14
5475  imul ch                            ; 20 * high byte of the field
5477  add  ax, 0x80
547A  mov  al, 0xF6                      ; -10
547C  add  al, dl
547E  add  al, ah
5481  .out: mov ax, 0x0A63
```

The divide by 90 and the -30..+90 bounds say it is an angle in degrees, and the
reciprocal of a per-entity field says it depends on something like a rate or a
radius. Which angle is open.

`0x4188`, also called from the model at `0x5241`, is a sound call —
`lcall [0xFC14]` with `ah=0x10` — gated by a patched immediate at `0x418A` that
doubles as the effect number and the on/off flag. Sound is deferred, so it is
noted and left.

## Open

- Which angle `0x5416` produces, and what `[si+0x163A]` is.
- The pitch axis. `[0x4FCC]` self-centres like `[0x5084]` but has not been
  followed to a consumer.
- `[0x5119]`, an instruction immediate initialised to `0x8000` at `0x4E89` and
  read at `0x50AD`. `0x5571` has two more of its own at `0x5575` and `0x5582`.
- The contents of the turn-rate table at `0x54D5`. Reading it would give the
  actual rates, but the values are game data and stay out of this repository;
  the converter reads them at build time on the user's machine.
