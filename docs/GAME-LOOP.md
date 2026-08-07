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

## The flight model

`0x4EB6` is the aircraft update, called from the loop when a self-modified flag
is set, and it dispatches into `0x5000`-`0x5500`.

The clearest piece decoded so far, at `0x51F7`:

```
51F7  mov  dx, 0            ; target value, patched at run time
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
5210  xchg dx, ax           ; do not overshoot the target
.store
5211  mov  [0xAE68], ax
```

A **rate-limited approach to a target**: the value at `[0xAE68]` moves toward
`dx` at six units per frame delta, clamped so it cannot pass it. That is how
thrust, airspeed or a control surface settles, and the same shape will recur
throughout the model.

`0x4EB6` then reads `[0xAE68]` back and compares it against thresholds — `0x790`
(1936), `0x820` (2080), `0xB68` (2920) — combined with flag bits out of
`[0xFF7E]`, producing a small integer. Discrete bands over a continuous value:
gear and flap limits, or afterburner stages.

### `[0xAE68]` is the airspeed

Established, from five independent uses across twenty accesses.

**It is integrated into position.** At `0x5123`:

```
5123  mov  ax,[0x347B]      ; the word whose high byte is the frame delta
5126  imul word ptr [0xAE68]
512A  mov  cx, dx           ; keep the high word of the product
512C  mov  ax,[di+0x143A]   ; a direction component
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

**It accelerates at a limited rate** toward a target, six units per frame delta,
clamped against overshoot (`0x51F7`, quoted above).

**It gates discrete bands** at `0x4EB6`, against 1936, 2080 and 2920 combined
with flag bits.

**It drives a low-speed animation.** At `0x94D6` it is clamped to 880, shifted
right four and accumulated into a phase that wraps at 8 — a cycle whose rate
follows speed, with a separate floor of 40 below which it stops. Ground roll,
by the look of it: wheels or runway markings.

It is initialised to `0x0C80`, 3200, at `0xEF92`.

**The unit is not established.** The constants are consistent with a fixed-point
airspeed — 3200 in flight, control authority floored at 2000, ground animation
capped at 880 and stopping below 40 — and if 880 is near the 270 to 300 knots
the READ.ME gives for an approach, one knot is roughly three units and the
2920 band lands near 1000 knots. That is arithmetic on a guess, though, not a
reading of the code. Pinning it down means finding where the value reaches the
airspeed indicator, and none of the twenty accesses is that path.

## State found so far

| Address | Meaning | How it is known |
|---|---|---|
| `[0x347C]` | frame delta, clamped to 25 | computed at `0xEFCE`, read by the physics |
| `[0xF895]` | free-running timer | source of the delta |
| `[0x6327]` | the timer's value last frame | |
| `[0xA720]` | game state, 0..12 | indexes the table at `0xA6D7` |
| `[0xF3A2]` | theatre | tested at `0xCC8C`, `0x438D`, `0x75FC` |
| `[0xAE68]` | **airspeed**, rate-limited, initialised to 3200 | integrated into position at `0x5126`, divided by at `0x5017` |
| `[0xFF7E]` | flag word read by the aircraft update | |
| `[0xFB3A]` | flag byte, bit 3 gates `0xB1B8` | |

## Open

- The unit of `[0xAE68]`, which needs the path to the airspeed indicator.
- The rest of the aircraft state block. `[0x347B]` holding the frame delta as
  the high byte of a word means it is used as 8.8 fixed point, which is likely
  the format the whole model works in.
- The other seventeen callees of `0xCC8C`.
- The thirteen state handlers, of which only the in-flight one has been looked
  at at all.
- Two self-modified flags gate parts of the loop, at `0xEFE0` and `0xF26E`.
  Both are written from `0xF288`. Whatever sets them decides which paths run.
