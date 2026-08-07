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
places, consistent with twelve being the last valid state. Reading the table
directly from the file (rather than trusting `re/seeds.txt`'s discovery-order
listing) gives the handler for each index in order:

```
state   0   1   2   3   4   5   6   7   8   9  10  11  12
addr  A9BC A93B AE09 AE09 ADD3 ADE7 ADC2 ADF7 AD98 ADB0 A979 A95A A8F9
```

States 2 and 3 share `0xAE09` — worth noting before reading anything else,
since it means one of the thirteen slots is trivially a no-op (`ret`, nothing
else). Twelve routines to account for, not thirteen.

Once read, these turn out to be **view/display-mode handlers, not mission
phases**: state 12, examined earlier, draws the in-flight HUD (`ALTITUDE` sits
at `0xA8FC`, an inline string after `call 0x5B4C`); the rest split between a
shared chain of camera-view labels and a pair of instrument-panel layouts. See
below for all twelve.

`[0xF3A2]` is a second, independent selector: the theatre. `0xCC8C` tests it
against `0x62` at its first instruction, the placement-list walker at `0x438D`
uses it to choose a group, and `0x75FC` indexes a per-theatre parameter table
with it. Three routines found separately all key off the same byte.

## The twelve state handlers

### A second inline-data idiom, and a disassembler fix

States 0, 1, 10 and 11 all call `sub_0000_6680`, and every call site was
garbage past that point — `pop ax`, nonsense `add`/`and` sequences, an `fdivr`
in the middle of what should be code. The same trap as the inline strings
documented in [X86DISASSEMBLE.md](X86DISASSEMBLE.md), but a different shape:

```
6680  pop  si          ; the return address, taken as a data pointer
6681  lodsw / mov dx,ax     ; word 1
6684  lodsw                  ; word 2
6685  mov  bl, ah / xor ah,ah / mov di,ax   ;   split: bl = high byte, di = low byte
668B  lodsb / mov bp,ax        ; byte 3
668E  lodsw / push si / mov si,ax  ; word 4, old si saved for later
```

Five fields, `2+2+1+2 = 7` bytes, no terminator to scan for — a **fixed-length
record**, not a string. `tools/re/disasm.py` only knew how to skip
terminator-scanned strings (`INLINE_STRING_ROUTINES`), so it decoded these 7
bytes as instructions at every one of `0x6680`'s call sites and derailed. Added
a second table, `INLINE_RECORD_ROUTINES = {0x6680: 7}`, and a matching branch
in the descent loop that skips a fixed count instead of scanning. Coverage
went from 44.6% to **45.7%** in one pass, entirely previously-mislabelled
code, not new guessing — the data guard still holds (13 regions, all
untouched).

With the records read correctly, `0x6680` decodes each one as
`(dx, di, bl, bp, si)` and, past a branch on whether `bp` is odd or even,
programs the VGA/EGA Graphics Controller and Sequencer directly (`out` to
ports `0x3CE`/`0x3CF`/`0x3C4`/`0x3C5` — index/data pairs for the bit mask and
map mask registers) before a masked `movsb` blit from a bitmap at
`[0xFC22]:si` — `[0xFC22]` is the seventh entry of the nine-word segment table
documented in `RE-NOTES.md`. This is a **hardware-level icon/glyph plotter**:
`dx` reads as a screen coordinate, `si` selects which bitmap, `bp`/`bl`/`di`
some mix of size and placement. What each field means precisely, and what the
bitmaps themselves look like, is not chased further — the values are game
data and stay out of this repository regardless.

### States 0 and 10: the cockpit instrument panel, live and on a second page

State 0 (`sub_0000_A995`) draws three icons via `0x6680` at `dx = 88, 64, 40`
(likely three stacked screen rows), then two gauge bars:

```
AA24  mov  si, 5
      mov  ax, [0xB43A]     ; the throttle
      mov  cx, 0x32          ; scale: 50
      call 0xAA45
      mov  si, 6
      mov  ax, [0xB444]       ; a second gauge source, not yet identified
      mov  cx, 0x320            ; scale: 800
      call 0xAA45
```

`[0xB43A]` is the throttle, already established in
[FLIGHT-MODEL.md](FLIGHT-MODEL.md) — 0..500, so a scale of 50 covers it in
round tenths. `[0xB444]`'s scale of 800 doesn't match anything documented yet.
`0xAA45` itself (the bar-drawing primitive) is not traced.

State 10 is a thin wrapper around the *same* routine:

```
A979  mov  ax, [0xC34]       ; the current video segment/page
      push ax                 ; save it
      add  ax, 0xD2             ; offset to a second page
      cmp  byte [0xD5C8], 4      ; adapter-class check (CGA/Tandy/EGA/VGA)
      jne  .skip
      add  ax, 0                  ; adapter-specific adjustment, self-modified
.skip
      mov  [0xC34], ax              ; swap to the alternate page
      call 0xA995                     ; draw the SAME panel there
      pop  [0xC34]                      ; restore the original page
      ret
```

State 10 draws the identical instrument panel to a second video page instead
of the visible one. A back buffer for a smooth page-flip, or a picture-in-
picture / satellite-view surface rendered off-screen — which, is not settled;
either is consistent with what's here.

### States 1 and 11: a mirrored pair of gauge clusters

Both call `0x6680` three times and return — no gauges, no fall-through into
anything else. Decoding all six records side by side:

```
state  1: dx=88 di=0x02 ...   dx=64 di=0x23 ...   dx=40 di=0x42 ...
state 11: dx=88 di=0x5A ...   dx=64 di=0x7B ...   dx=40 di=0x9A ...
```

Every field is identical between the two states **except `di`, offset by
exactly `0x58` (88) in every entry**. Same three icons, same rows (`dx`),
shifted sideways by a fixed 88 pixels — a left/right pair of identical
three-icon gauge clusters, not two different displays.

### States 4-9: one shared view-mode label chain

`0xAD98` (state 8) through `0xAE09` (states 2/3's no-op) is a single linear
sequence with no internal jumps back to a common dispatcher — six labelled
calls to `sub_0000_AE0A` in a row, falling straight through from one to the
next:

```
state  8 enters here -> "SATELLITE VIEW"
                         "BEHIND MISSILE"
state  9 enters here -> (same as above, from BEHIND MISSILE)
state  6 enters here -> "LOOKING NORTH"
state  4 enters here -> "FULL SCREEN VIEW"
state  5 enters here -> "BEHIND PLANE"
state  7 enters here -> "LOOKING SOUTH"  (state 7 is the only one that
                                           reaches just this single label)
```

Six view modes, six labels, one shared trailer of code reused via six
different entry points — a normal size-saving trick in hand-written assembly,
and the reason states 4 through 9 looked like six near-duplicate blocks before
reading them side by side.

One label was garbage in the listing — `0xADE7`'s content showed as a single
`\x80` byte followed by nonsense, because the string's own *first* byte
happens to be `0x80`, which the terminator scan (any byte with bit 7 set)
reads as an immediate empty string. Reading the raw bytes directly settles it:
`\x80BEHIND PLANE\xC5` — a leading marker byte per label (`|` for the two
"VIEW"/"MISSILE" entries, `~` for the two "LOOKING" entries, `x` for "FULL
SCREEN VIEW", `0x80` here), then the text, terminated on the last letter with
its high bit set as usual (`E`+0x80 = `0xC5`). This one call site's resume
point is a manual correction; the disassembler's generic terminator scan has
no way to know a leading marker byte can itself look like a terminator, and
this is the only place in the image where that collision happens.

`sub_0000_AE0A` does more than print the label. After it, gated by the same
call, every entry in the chain also draws the **full flight instrument
readout** — the same heading/airspeed/altitude routine (`0xAE4C`) and the same
three-position print (`0x58B6`) already documented for state 12's HUD:

```
AE0A  test byte [0xFB3E], 0xFF    ; a blink/flash gate
      jne  .skip                    ;   nonzero: skip this frame entirely
      call 0x5B4C                     ; print the label (inline text, see above)
      pop  si
      call 0x5BE6
      call 0x5B6E
      call 0xAE4C                       ; heading / altitude / airspeed - see FLIGHT-MODEL.md
      ... three calls to 0x58B6 ...       ; print each at its screen column
.skip (AE08)
      pop  si
      ret
```

`[0xFB3E]` has exactly one writer in the image, a bare `not byte [0xFB3E]` at
`0x9DE4` — a toggle, consistent with a blink cadence flipping the flag between
all-zero and all-one on some other timer. What exactly happens on the
"skipped" path — whether `pop si; ret` correctly resumes past the caller's own
trailing label text, or whether the real resume mechanism lives deeper in the
`0x58B6`/`0x58CB` print chain reached by the *previous* frame's successful
draw — was not fully traced. The label text and the shared HUD tail are solid;
the exact blink-skip control flow is flagged open below.

So states 4-9 are six camera/view modes that all show the same flight
instruments underneath a different mode label - consistent with the READ.ME's
external-view descriptions, and with states 0/10/1/11 being cockpit-panel
and gauge-cluster views rather than anything narrative.

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
| `0x1F3A` | builds a 3x3 rotation matrix from three angles, entirely on the CPU — see below |
| `0x314E`, `0x3160` | a linked list fed into a binary search tree, sorted on object position — see below |
| `0x3F62` | spawns a small cluster of objects around one position, then a proximity sound check — see below |
| `0x40A3` | sound-driver query, and a squared-3D-distance proximity cue — see below |
| `0x9811` | a budget-limited scan that sums a field over a set of objects, then feeds `0x314E`'s pipeline — see below |
| `0x3644` | pool-allocates a tagged, timestamped position marker and redirects a dangling-looking reference onto it — see below |

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

### `0x1F3A`: a 3x3 rotation matrix, built on the 8086

`0x1F3A` unpacks three angle-table offsets from the caller's stack frame and
falls straight into `0x1F43` — no `ret` between them, so this is one routine
in two parts:

```
1F3A  mov  bx, [bp+0x24]     ; three angle offsets, into the sin/cos tables
1F3D  mov  di, [bp+0x26]     ;   from 0x143A/0x163A, exactly as in the flight model
1F40  mov  si, [bp+0x28]
1F43  mov  ax, [bx+0x163A]   ; c1 = cos(angle 1)
      mov  es, ax             ;   stashed — this 8086 has no spare general register
      ...
```

Twenty-six instructions of `imul` / `shl,rcl` / add-or-subtract pairs later,
nine words land at `bp+0x35` through `bp+0x45`, each a sum of sin/cos products
of the three angles — `s1*s2*s3 + c2*c3`, `-c1*s3`, `s1*c2*s3 - s2*c3`, and six
more in that shape. Reconstructing the formulas and checking them numerically
in Python settles what they are: for every angle triple tried, the resulting
3x3 matrix is orthonormal to machine precision and has determinant exactly 1.
**A full 3D rotation matrix, computed by the CPU, from three Euler-style
angles**, matching the trig-table convention already established in the
flight model.

`f030dsp3d` — the DSP engine this port is built from — does exactly this job
on the DSP56001 (`ARCHITECTURE.md`, "Rotation matrices"). This is the original
game's own equivalent, done on the 8086 because it has no DSP: build the
matrix once per object per frame from its stored orientation, ready for
whatever transforms the vertices afterward. Called from five sites, two of
them inside `0xCC8C` itself (`0xCDC9`, `0xCE80`); the other three are `0x3AF5`,
`0x3D9E`, `0xEE2C`, not yet examined.

### `0x314E` and `0x3160`: a linked list, sorted into a binary search tree

`0x314E` walks a null-terminated linked list — read a pointer, and while it is
non-zero, call `0x3160` on it and follow the node's first word as the next
pointer:

```
314E  lodsw            ; ax = the list head, from the stream at si
      or   ax, ax
      je   .empty
      mov  bp, ax
.loop
      call 0x3160
      mov  bp, [bp]     ; follow the "next" link
      or   bp, bp
      jne  .loop
```

`0x3160` is a textbook **binary search tree insertion**, keyed on
`[bp+0xE]` first and `[bp+0x16]` second:

```
3160  xor  ax, ax
      mov  [bp+4], ax     ; zero the new node's two child pointers
      mov  [bp+6], ax
      mov  ax, [bp+0xE]   ; primary key
      mov  dx, [bp+0x16]  ; secondary key
      mov  bx, bp         ; bx = the new node
      mov  cx, [si]       ; the tree's root pointer lives at si
      or   cx, cx
      jne  .descend
      mov  [si], bp       ; empty tree: the new node becomes the root
      ret
.descend
      mov  bp, cx                    ; bp = current node
      cmp  ax, [bp+0xE]               ; compare primary keys
      jg   .go_right
      ; equal-or-less: descend left, or break the tie on the secondary key
      ...
```

`[bp+0xE]` and `[bp+0x16]` are the same X-high and Z-high fields identified in
the world-coordinate work above — this sorts objects into a tree **by
position**, X first and Z as a tie-break. `ARCHITECTURE.md` documents the
DSP's polygon-level BSP sort (`f030dsp3d`, "BSP sorting"); this is the
original's coarser, CPU-side, whole-object counterpart, built incrementally
with an ordinary BST rather than a proper BSP tree. `0x3160` is also called
directly, outside the list walk, from `0x3B37`, `0x45F7` and `0xCE87`.

### `0x3F62`: spawn a cluster, then check a proximity sound

```
3F62  cmp  ax, 0x3EE
      je   .special            ; -> 0x3F9C, a second table-driven path, not fully chased
      mov  cx, 8
      mov  si, 0x406F           ; a table of 8 (X,Z) offset pairs
      cmp  ax, 0x3F0
      je   .spawn
      cmp  ax, 0x3EF
      je   .shorter
      jmp  0x40A3                 ; anything else: straight to the proximity check below
.shorter
      mov  si, 0x4053              ; a different table
      dec  cx                       ; 7 entries instead of 8
.spawn (3F7E)
      lodsw
      add  ax, [bp+0xE]              ; object.X + table.X
      mov  bx, [bp+0x12]              ; object.Y, unchanged
      mov  dx, [si]
      add  dx, [bp+0x16]               ; object.Z + table.Z
      inc  si
      inc  si
      call 0x40AF                       ; spawn an object at that position
      loop .spawn
      jmp  0x4132                         ; then the proximity check, see below
```

Dispatches on a numeric code in `ax`. Two of the three cases walk a small
fixed table of position offsets and spawn one object per entry around the
caller's position via `0x40AF` — the same routine `0x412C` reaches, already
tied to the world-coordinate work. Every path ends the same way: a tail call
toward the proximity-sound check next.

### `0x40A3`: a sound-driver query, and a distance-gated cue

```
40A3  call 0x4132       ; al = 0, falls through into 0x4134
4132  sub  al, al
4134  push ax
      mov  dl, 1
      mov  ah, 0x12      ; sound driver function 0x12: a query
      lcall [0xfc14]
      sub  al, 4
      jne  .distance
      call 0x4188         ; result was 4: play effect 0 through the sound gate
.distance (4144)
      mov  ax, [0x3259]    ; a second tracked position — not the aircraft's own
      mov  bx, [0x326C]     ; (that's 0x397A/0x3984/0x398E)
      mov  cx, [0x3261]
      call 0x1383            ; squared 3D distance to the object at bp
      pop  ax                 ; the caller's original al parameter
      cmp  dh, 4
      jae  .return              ; too far: nothing
      ...                        ; else scale dx by al's low two bits (x1, x2, or x8)
      cmp  dh, 2 / clamp
      mov  al, 0xD              ; 13
      sub  al, dh                ; effect = 13 - dh
      mov  ah, 0x10               ; play it directly - not through the 0x4188 gate
      lcall [0xfc14]
```

`0x1383` is a clean, self-contained squared-distance function:

```
1383  sub  ax, [bp+0xE]    ; dX = point.X - object.X
      imul ax                ; dX^2
      ...                     ; same for Y and Z, accumulated in dx:ax
      ret                      ; returns dX^2 + dY^2 + dZ^2, no square root needed
```

Comparing squared distances instead of taking a square root is the standard
trick, and it is exactly what this does. The point compared against —
`[0x3259]`/`[0x326C]`/`[0x3261]` — is read from several other places too
(`0x345F`, `0x41D4`, and three sites around `0xA183`), so it is some
consistently-tracked position, just not the aircraft's own. The nearer that
point is to the object at `bp` (in bands set by `dh`), the higher-priority the
effect selected — a distance-gated audio cue, played directly rather than
through the `0x4188` gate, scaled by a caller-supplied factor of 1, 2 or 8.

### `0x9811`: a budget-limited scan that sums a field, then hands off to `0x314E`

```
9811  mov  bx, 0x9930      ; bx = a function pointer - a genuine one, unlike
      call 0x9824            ;   the register-indirect calls seeded so far
      jae  .walk               ; ok: enter the scan (see below)
      ret                        ; else: nothing to do
```

`bx` is never used as a jump-table base here — it is loaded once, unconditionally,
and called directly at `0x9849` inside the scan loop below. That is a genuine
function pointer, not a table dispatch, so it needed its own seed (`re/seeds.txt`)
rather than the usual jump-table proof. Decoding the raw bytes at `0x9930`
confirmed it before seeding: 14 sensible instructions ending in `ret`, and clean
code beyond that too.

**The callback, `0x9930`, is a running accumulator:**

```
9930  mov  ax, es:[di+0x1E]   ; a signed field from the current scan item
      cdq                      ; sign-extend to 32 bit
      add  [0xF5B2], ax         ; accumulate the low word
      adc  [0xF5AC], dl          ; and the high byte, with carry
      ret
```

`[0xF5B2]`/`[0xF5AC]` are zeroed together in the same spawn-init block as the
sound gate and the three `0x42BD` flags (`0xEEF1`-`0xEEF4`) — so this is a
**per-mission running sum**, rebuilt from zero at the start of each flight, one
term contributed by each item the scan visits. What the summed field represents
is not identified; a mission-long tally is consistent with score, remaining
ordnance, or a kill count.

**`0x9824`** gates entry on `[bp+0x32]` bit 6 and the sign of `[bp+0x2E]`, then
subtracts a per-call amount from `[bp+0x2E]` before allowing the scan to run —
a budget that is spent down each time this is called, with the scan only
running while it stays positive. The scan loop itself (`0x9848` onward) walks
a structure via `es:[di+0x22]`, looks entries up in a table at `[si+0x2EB6]`,
and calls the accumulator once per item, continuing while a running total
(swapped through `[bp+0x2E]`) stays non-negative.

At the end (`0x98A9` onward), once the budget or the scan is exhausted,
`sub_0000_98E9` checks whether the scan reached its end (`cmp si,di`) and, if
not, calls `sub_0000_98F2` (not traced) before setting the departure marker CF.
On success, the same `si=0x2E66 / [si+2]=0 / call 0x314E` sequence closes it
out — this scan's results are handed to the same list-to-BST pipeline `0x314E`
serves elsewhere, sorted into the same position-keyed tree as everything else
that pipeline touches.

### `0x3644`: a pooled, timestamped position marker that steals a reference

```
3644  mov  bx, [0x2E94]        ; head of a linked list, searched below
      mov  cx, [0xFADC]          ; a theatre-dependent value...
      jne  .have_it
      mov  cx, [0xFADE]            ; ...or its fallback if the first is zero
.have_it
      mov  di, bp                   ; di = the CALLER's own record pointer
      mov  si, 0x2EAA                 ; head of a free-list pool
      sub  dx, dx                      ; dx = 0
      call 0x3E6C
```

`0x3E6C` opens with `call 0x30FA`, a **free-list pop**:

```
30FA  mov  ax, [si]      ; si = 0x2EAA, the pool's free-list head
      or   ax, ax
      je   .empty          ; nothing available: abort the whole operation
      mov  bp, ax            ; bp = the popped record
      xchg [si+2], ax          ; the usual head/tail free-list bookkeeping
      xchg [bp], ax
      mov  [si], ax
```

With a record in hand, `0x3E6C` initialises it — a magic tag, a
theatre-dependent value, and a **deadline**:

```
3E71  mov  [bp+0x2C], 0xBB8B    ; a tag - this record is a marker, not the
                                  ;   original object
3E76  mov  [bp+0x2A], cx          ; the theatre-dependent value from 0x3644
3E79  mov  ax, [0xF895]            ; the free-running timer
3E7C  inc  ah                       ; + 256
3E7E  mov  [bp+0x33], ax              ; -> a deadline, ~256 ticks out
```

— then copies the **caller's own position** into the new record, six words
(the X/Y/Z coordinate pair fields at `+0xC` through `+0x17`, the same ones
identified in the world-coordinate work) straight across:

```
3E87  mov  ax, di            ; di = the caller's record (saved by 0x3644)
3E89  lea  si, [di+0xC]
3E8C  lea  di, [bp+0xC]
3E8F  mov  cx, 6
3E92  rep  movsw               ; copy all three 32-bit coordinates
```

Finally, it walks the list at `[0x2E94]` looking for a node whose `+0x58`
field points at the *caller's* record and whose `+0x30` field is non-zero,
and when found, **retargets that node's `+0x58` to the new marker instead**:

```
3E98  cmp  [bx+0x58], ax    ; does this node reference the caller?
      je   .check
      mov  bx, [bx]           ; else follow the list
      jne  .loop
.check
      cmp  [bx+0x30], dx        ; dx = 0: only redirect if this field is set
      je   .next
      mov  [bx+0x58], bp          ; redirect the reference to the new marker
```

Read together: something elsewhere holds a reference to the calling object by
its record pointer. `0x3644` gives that reference a small, independent,
tagged, self-expiring stand-in — a copy of the position, nothing else — and
retargets the reference onto it. That is the shape of "the object this was
tracking is going away; keep pointing at where it last was for a while
instead of a pointer that is about to dangle." What specifically triggers this
(what caller sits at `0xCD7C` inside `0xCC8C`, and which subsystem holds the
`+0x58` reference) has not been traced.

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
- All eighteen of `0xCC8C`'s direct callees are now read, `0x9811` and
  `0x3644` included. What remains: what `0x9930`'s summed field (`es:[di+0x1E]`)
  represents; `sub_0000_98F2` (reached from `0x98E9`, not traced); which
  subsystem holds the `+0x58` reference that `0x3644` redirects, and what
  calls it from `0xCD7C`.
- Which structure `0xCFB3`'s CRC-16 actually protects, and what the
  `0xCF81`/`0xCF5D` record codec pair's fields mean — both are mechanically
  understood but not tied to game data yet.
- What reads the three flags `0x42BD` masks (`0xB3D8`, `0xB3E6`, `0xB3F4`).
- What `[0x2E70]`-`[0x2E94]`, the small tables `0x3F62`'s special case reads,
  actually hold, and what `[0x3259]`/`[0x326C]`/`[0x3261]` (the second tracked
  position in the distance cue) represents.
- `sub_0000_993E`, found in passing right next to the seeded `0x9930` and
  unrelated to it: a per-theatre byte-stream command interpreter (table at
  `0x9C84`, indexed like `0x75FC`) with four opcode classes, called from four
  sites (`0xC83E`, `0xF116`, `0xF2B0`, `0xF58D`) that have nothing to do with
  `0xCC8C`. Not decoded beyond its shape.
- The three other callers of `0x1F3A`'s rotation-matrix builder
  (`0x3AF5`, `0x3D9E`, `0xEE2C`), and the three other direct callers of
  `0x3160`'s tree insert (`0x3B37`, `0x45F7`, `0xCE87`).
- All thirteen state handlers are now read at some depth. Still open within
  them: `0xAA45` (the gauge-bar primitive states 0/10 use), `0x0A72` (called
  by states 0/8/10), what `[0xB444]` is, `0x6703` (the odd-`bp` branch of the
  icon blitter `0x6680`), and the exact control flow of `0xAE0A`'s blink-skip
  path (does `pop si; ret` at `0xAE08` correctly resume the caller past its
  trailing label, or does that depend on the `0x58B6`/`0x58CB` print chain
  from a prior frame — not traced).
- What triggers a transition between the thirteen states — `[0xA720]` is
  written in several places not yet examined, so what makes the player cycle
  through view modes (a key binding, most likely) is still open.
- Two self-modified flags gate parts of the loop, at `0xEFE0` and `0xF26E`.
  `0xF288` writes both; `0xEFE0` is also set to `1` at spawn (`0xEEEC`, the
  same block that arms the three `0x42BD` flags and the sound gate). Whatever
  `0xF288` does thereafter still decides which paths run.
