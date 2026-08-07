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

Which quantity `[0xAE68]` holds is not yet established. The thresholds are in
the low thousands, and the READ.ME says the aircraft cruises at 270 to 300 knots
on approach, so a fixed-point airspeed is the obvious guess — but it is a guess.

## State found so far

| Address | Meaning | How it is known |
|---|---|---|
| `[0x347C]` | frame delta, clamped to 25 | computed at `0xEFCE`, read by the physics |
| `[0xF895]` | free-running timer | source of the delta |
| `[0x6327]` | the timer's value last frame | |
| `[0xA720]` | game state, 0..12 | indexes the table at `0xA6D7` |
| `[0xF3A2]` | theatre | tested at `0xCC8C`, `0x438D`, `0x75FC` |
| `[0xAE68]` | an aircraft quantity, rate-limited | written at `0x5211`, banded at `0x4EB6` |
| `[0xFF7E]` | flag word read by the aircraft update | |
| `[0xFB3A]` | flag byte, bit 3 gates `0xB1B8` | |

## Open

- What `[0xAE68]` actually is, and the rest of the aircraft state block. The
  three readers of the frame delta are the way in.
- The other seventeen callees of `0xCC8C`.
- The thirteen state handlers, of which only the in-flight one has been looked
  at at all.
- Two self-modified flags gate parts of the loop, at `0xEFE0` and `0xF26E`.
  Both are written from `0xF288`. Whatever sets them decides which paths run.
