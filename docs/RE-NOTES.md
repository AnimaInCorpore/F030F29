# Reverse-engineering notes: X.EXE

Tools in `tools/re/`:

```bash
python tools/re/mzinfo.py     # MZ header, relocations, segment layout
python tools/re/disasm.py     # recursive-descent disassembler -> re/listings/x.lst
python tools/re/codemap.py    # code/data segmentation by windowed analysis
python tools/re/peek.py D2C0 -n 30
python tools/re/xref.py E4C5  # who calls this?
```

## Size

| File | Size | Code | Data |
|---|---:|---:|---:|
| `X.EXE` (load module) | 68,128 B | **~50,976 B (74.8 %)** | ~17,152 B |
| `RETAL.00` | 239,200 B | — | 239,200 B |
| `RETAL.01` | 359,172 B | — | 359,172 B |

**All the program code is in `X.EXE`** — roughly **51 KB** of x86 real mode. At
the measured 2.14 bytes per instruction that is about **23,000 to 24,000
instructions**.

`RETAL.00` and `.01` hold no code as stored. The windowed analysis reports 11 %
and 15 % "code", but not one contiguous run of 1 KB or more is classified that
way — scattered 256-byte windows are the noise pattern, not real code. The
opcode statistics agree:

| | `call` | `ret` | `mov r,rm` |
|---|---:|---:|---:|
| `X.EXE` | 1.91 % | 0.97 % | 1.98 % |
| `RETAL.00` | 0.29 % | 0.15 % | 0.14 % |
| `RETAL.01` | 0.23 % | 0.06 % | 0.09 % |

The one exception is `RETAL.00` resource 15, a 7,081-byte overlay that the
loader far-calls at offset 0. See [ARCHIVE-FORMAT.md](ARCHIVE-FORMAT.md).

## Memory layout

Entry at `0000:0000`. The first 32 bytes build a segment table: nine words of
*sizes* in paragraphs sit at `0xFC16`, and the loop at `0x0012` converts them
in place into *segment bases* (read `bx = [di]`, store `ax`, `ax += bx`).

```
0000:0000  cli / cld
0000:0002  mov  dx, [2]          ; PSP: top of memory segment
0000:000C  mov  di, 0xFC16       ; segment table, nine entries
0000:000F  mov  cx, 9
0000:0012  mov  bx, [di] / stosw / add ax, bx / loop
0000:0019  mov  ss, [0xFC1C]     ; stack from slot 3
0000:001D  mov  sp, 0xC00        ; 3 KB stack
```

Result, relative to the load address:

| Slot | Base | Size | Purpose |
|---|---|---:|---|
| `FC16` | +0x0000 | — | code segment (= CS) |
| `FC18` | +0x0000 | 64 KB | code and data |
| `FC1A` | +0x1000 | 64 KB | tail segment (target of the four relocations) |
| `FC1C` | +0x2000 | 64 KB | **stack** (SP = 0xC00) |
| `FC1E` | +0x3000 | 63,360 B | buffer |
| `FC20` | +0x3F78 | 12,000 B | buffer |
| `FC22` | +0x4266 | 37,440 B | buffer (`mov es,[0xFC22]` at `0x0067`) |
| `FC24` | +0x4B8A | 36,096 B | buffer |
| `FC26` | +0x5452 | 7,840 B | buffer (holds the overlay) |
| end | +0x563C | | total **352,448 B** |

## Overlay dispatcher `lcall [0xFC14]`

35 call sites. The far pointer is patched at run time; the target is
`RETAL.00` resource 15, loaded into slot 8. `AX` is a command of the form
`AH` = function, `AL` = parameter. Details in
[ARCHIVE-FORMAT.md](ARCHIVE-FORMAT.md).

Because this dispatcher leads out of `X.EXE`, it cannot be resolved from here.

## Resolved indirect jumps

Every target is documented in [`re/seeds.txt`](../re/seeds.txt) and read by
`disasm.py` automatically. Together with the techniques described under
"Widening the sweep" below, coverage went from **8.2 %** at the start of this
work to whatever `disasm.py`'s own tail output currently reports — run it
rather than trust a number here, since `re/seeds.txt` keeps growing. 51.8 %
as of the object-callback and keyboard-table work.

| Site | Kind | Resolution |
|---|---|---|
| `0xD2DA` | `call cs:[bx-0x2BC6]` | table at `0xD43A`, **16 raw slots** (indices 7/14 and 8/15 repeat, so 14 unique). Every handler tests `cs:[0xD5C8]` against 4 and works with `cx` = 0x2000/0x2880/0x0800/0x3C00 → **pixel format dispatcher** for CGA/Tandy/EGA/VGA, not a decompressor. Three slots stay unresolved — see the note below the table |
| `0xD2EE` | `jmp ax` | `mov ax,0xD329` immediately before — constant propagation |
| `0x29D5` | `call [si]` | **one** table at `0x29EF`, 16 entries — confirmed by reading the loop itself (`inc si` by 2 per one of 16 bit-tested iterations), not by guessing a length from where the values stop looking like code. An earlier pass misread this as two 8-entry tables ("forward" and "inverse"); the second half is simply where the same loop's index reaches, not a separate base. **Flag-change callback dispatcher**. Bit 7 is `int 15h AX=C200`, the PS/2 mouse |
| `0x5B8C` | `jmp ax` | trampoline table running **backwards** from `0x5BE6`: code 9 lands on `0x5BE6`, code 0 on `0x5BD4` |
| `0x5B92` | `jmp bp` | three glyph renderers: `0x58FB`, `0x5852`, `0x599A` |
| `0xE4CC` | `jmp [bx]` | **menu dispatcher**, table inline after each call site. Three sites: `0xC564` (7), `0xD754` (8), `0xE680` (7) |
| `0x8F26` | `call [bx-0x70C4]` | base `0x8F3C`, table mixes code pointers and ASCII text ("...LEL DONE..."); unreached, entry point not established |
| `0xF263` | `call [bx-0x5929]` | base `0xA6D7`, **13 code entries** (indices 0-12) indexed by `[0xA720]`. Index 13 (`0x5C58`) decodes as incoherent garbage on inspection, not a fourteenth state; indices 14-15 are a literal ASCII `"00"` and a `0x0000` null, plainly sentinels rather than table content. This is the game *state* dispatcher, one handler per state; the HUD is what one of them draws. See [GAME-LOOP.md](GAME-LOOP.md) |
| `0x9E37` | `jmp [bx-0x5F45]` | **keyboard dispatch table** at `0xA0BB`, 64 entries, most defaulting to a no-op `ret`. A bounds check (`cmp bx,0x9FB9 / jb`) statically proves the table's live region rather than leaving it to guesswork |
| `0x35BC` | `call [bp+0x49]` | **object virtual-method dispatch** — a game-object structure carries a callback pointer at `+0x49`, found by scanning for `mov [bp+0x49],imm16` across the image (4 targets). The same structure has two more callback slots, `+0x2C` (`call [bp+0x2C]` at `0x337F`, 3 targets) and `+0x7D` (1 target) |

`0xD2DA`'s three unresolved slots, for anyone tempted to seed them later: index 7 (`0x802E`) is plausible-looking at a glance but is ASCII text ("...OVERWHELMED BY A MASSIVE...", a status-message pool, now in `KNOWN_DATA`); indices 9 and 11 (`0x04D5`, `0x04BA`) both open with byte `0xF1` (ICEBP — essentially never legitimate) followed by code that reads far more coherently starting one byte later, an off-by-one never resolved; index 10 (`0x0E76`) reaches an `out dx,al` with `dx` never set by anything nearby. None of the three are in `re/seeds.txt`.

### The menu dispatcher

The pattern repeats throughout the program:

```
D74A  mov  cl, 8           ; number of menu entries
D74C  call 0xE49F          ; read and validate a key
D74F  jae  0xD74A          ; invalid -> again
D751  call 0xE4C5          ; dispatch
D754  dw   D872, E199, DC02, E106, DCB5, D766, E6F3, 74CA   ; inline
```

`0xE49F` reads a key, maps `'1'..'9','0'` to index 0..9 (`sub al,0x30`, `'0'`
becomes 10, then `dec ax`) and checks it against `cl`. `0xE4C5` does
`pop bx / add bx,ax / jmp [bx]` — the return address *is* the table base.

Table lengths are statically provable: at `0xC564` by the `jb 0xC572` at
`0xC55F`, which makes `0xC572` code; at `0xE680` by the inline-string routine
starting at `0xE68E`; at `0xD754` by the `mov cl,8`.

## The inline-string idiom

The main reason coverage started so low was not the jump tables but this: a
`call` to a text routine followed immediately by the string. The routine pops
the return address as a string pointer and returns past the terminator, which is
**a byte with bit 7 set**.

```
5B59  pop  si              ; si = return address = string pointer
5B5A  call 0x5BCA
5B5D  call 0x5B6E          ; walk the string
5B60  jmp  si              ; resume after it
```

Anyone unaware of this disassembles from the `call` straight into the string
bytes and derails. `disasm.py` detects such routines by itself: it scans the
whole image for `call rel16`, groups by target, and classifies a target as an
inline-string routine when it has at least 3 call sites and text with a bit-7
terminator follows at 80 % or more of them. The scan runs over raw bytes rather
than discovered call sites — otherwise it would be circular, since the routines
worth finding are precisely the ones not yet reached.

Found: `0x5B4C`, `0x5B51`, `0x5B56`, `0x5B62`, `0xAE0A`. Currently 50 strings
totalling 1,647 bytes.

The text interpreter itself is compact: characters below 0x20 are control codes
(0 to 9 via the trampoline table, 10 to 31 shift `dx`), 0x20 to 0x67 go to the
preselected glyph renderer in `bp`, and **characters from 0x68 up are tokens**
that index `[0x5BF0 + 2*char]`, effectively from `0x5CC0`, into a phrase pool.
That is why an initial string search only turned up fragments like `SCENARI` or
`FIRE AND FORGE` — the last letter carries bit 7.

## Widening the sweep

Two techniques beyond plain recursive descent, and one guard that keeps them
honest.

### Byte-scanned call targets (`--scan-calls N`)

Recursive descent only finds a routine once something reaches it, so a function
whose only callers sit in unreached code stays invisible even though its call
sites are plainly there in the bytes. Scanning the image for the `call rel16`
encoding breaks that circle. Each candidate is probed first: ten instructions
have to decode from it without a failure and without an opcode real program
text does not contain.

`N` is how many call sites a target needs before it is trusted. **The default
is 2.**

### Function pointers in registers

Eleven `call bp` sites survive the descent because `bp` is loaded in a
different basic block than the call. The inference that works runs the other
way: if the program loads a constant into `bp` anywhere and elsewhere does
`call bp`, that constant is a function entry.

Only `bp` qualifies. That restriction is measured, not assumed — see below.

### The data-region guard

Ten regions are proven to be data by other parts of the analysis: the palette
at `0xFC00`, the segment table at `0xFC16`, both archive indices, the token
pool, the base names and so on. `disasm.py` checks after every run that it has
not disassembled any of them, and says so:

```
data check: all 9 known data regions left alone
```

This guard is the whole reason the settings above are what they are. Without
it, the numbers look far better and mean nothing:

| Setting | Coverage | Data regions wrongly decoded |
|---|---:|---:|
| plain descent | 40.6 % | 0 |
| `--scan-calls 1` | **66.2 %** | **6** |
| `--scan-calls 2` | 44.6 % | 0 |
| register pointers, `bp` only | +1.2 pt | 0 |
| register pointers, `bp` + `bx` | +6.7 pt | 4 |
| register pointers, plus `di` | +12.5 pt | 6 |

`--scan-calls 1` reaches two thirds of the image, and six of the ten regions it
"reaches" are things whose contents are already fully understood as data. The
gain is manufactured.

Admitting `bx` and `di` as function-pointer registers fails for a specific
reason worth remembering: they hold data pointers in most contexts, so
`mov si, 0xFC00` — the palette — would be seeded as code merely because
`jmp si` occurs somewhere. And that `jmp si` is the inline-string return, not a
function pointer at all.

## Call graph

```bash
python tools/re/disasm.py --callgraph 20
```

Hunting for the game loop by looking for anchors - a trig table, a HUD label,
a distinctive constant - did not work. Two candidate tables turned out to be
data misread as code. The call graph finds it structurally instead.

346 routines, 351 edges. The routines that call the most others:

| Routine | Calls | Called from | What it looks like |
|---|---:|---:|---|
| `0xCC8C` | 18 | 3 | dispatches into `0x3000`-`0x4900`, the largest code run |
| `0xE19F` | 18 | 3 | callees are the inline-string family, so menus and text |
| `0xC660` | 11 | 2 | |
| `0xD20F` | 7 | 12 | the resource loader — a known quantity, and a useful check that the graph is right |

**`0xCC8C` is the way into the game code.** It is called from `0xF2C9`, and the
`0xF2xx` region also holds the HUD dispatcher at `0xF263`, so that region is the
per-frame update. `0xCC8C` opens by testing `[0xF3A2]` against `0x62` - the same
theatre variable that selects a group in the placement-list walker at `0x438D`
and indexes the per-theatre table in `0x75FC`.

### Attributing calls to routines

Worth recording, because the first two attempts produced confident nonsense.

Routine boundaries are not known, so a call site has to be attributed to
whichever entry point it sits under. "The nearest call target at or below the
site" is not good enough: the last routine before a large unreached region
collects every call site in that region. That put `0xE8F6` at the top with 87
callees, from one caller - which reads exactly like a master dispatcher. It is
a 0x2B-byte routine that copies a table and returns.

A second guess, that the Addr tuple sorting by segment rather than linear
address was to blame, was also wrong and changed nothing.

What works is bounding an owner by *contiguously reached* instructions: a gap
in the sweep ends the routine, and sites past it belong to nobody. That drops
the edge count from 607 to 351 and `0xE8F6` off the list entirely.

## Operating system interface

Remarkably narrow; the game drives almost everything straight at the hardware.

| Interrupt | Sites | Purpose |
|---|---:|---|
| `int 21h` | 5 | `AH=30h` DOS version, `AH=3Fh` read, `AH=3Eh` close, `AH=4Eh` findfirst |
| `int 10h` | 5 | BIOS video mode |
| `int 15h` | 1 | `AX=C200`, PS/2 mouse |
| `int 00h` | 1 | divide by zero |

Central `int 21h` wrapper: `sub_0000_D3A9`. Filenames in clear at `0xD39F`
(`\RETAL`, `RETAL.00`) and `0xDABB` (`\RETAL\RETAL.LOG`). `RETAL.01` never
appears as a literal — the last digit is generated.

The `.LOG` reader sits at `0xDBB4`: reads up to 64 KB, closes, then compares
against `cx = 0x30B` = 779 bytes, exactly the size of `RETAL.LOG`.

## Known data regions in X.EXE

| Offset | Contents |
|---|---|
| `0x2E8F` | keyboard tables (`1234567890-=`, `qwertyuiop[]`, ...) |
| `0x30A3` | copy protection: `PILOT AUTHORISATION`, `WHICH SECTOR DOES THIS ... CONCERN?` |
| `0x802E` | status/message text pool (`...OVERWHELMED BY A MASSIVE...ONSLAUGHT...`) |
| `0x5BEE` | token phrase pool |
| `0x5CC0` | token table, indexed by character from 0x68 |
| `0x5DEE` | mission select: `SCENARIO`, `FIRE AND FORGET`, `TEST RANGE`, `RED ARMY` |
| `0x7118` | pilot log, ranks, medals (`PURPLE HEART` ... `MEDAL OF HONOUR`) |
| `0x734A` | base names and descriptions (`GROOM LAKE`, `USAF RAMSTEIN`, ...) |
| `0x8D62` | call signs (`RETALIATOR`, `HOUR GLASS`, `SAVIOUR`, ...) |
| `0xD6A7` | main menu (`RETALIATOR`, `1: ENROL TO...`) |
| `0xFBF0` | EGA sequencer register table |
| `0xFC00` | EGA attribute controller palette (identity) |
| `0xFC10` | segment table |
| `0xFC4A` | archive index, `RETAL.00` |
| `0xFC8E` | archive index, `RETAL.01` |

## Open

Remaining indirect jumps, by leverage:

| Site(s) | Kind | Why still open |
|---|---|---|
| 35x `lcall [0xFC14]` | overlay | leads out of `X.EXE`; needs the overlay's own dispatch table |
| `call bp` | dynamic | largely resolved by the register-pointer pass; the residue is `bp` values computed rather than loaded as constants |
| 2x `jmp si` (`0x5B60`, `0x5B66`) | inline string | no fixed target — returns past the respective string. Handled correctly already, just not resolvable as a "target" |
| 2x `call di` (`0x3393`, `0x33B3`) | dynamic | resolved to two targets, `0x95CC` and `0x9619`, both short and coherent; what sets `di` before either call site is not traced |
| `call bx` (`0x9849`) | dynamic | resolved — single target `0x9930`, see [GAME-LOOP.md](GAME-LOOP.md) |
| `jmp bx` (`0x9E48`) | jump table | resolved — the keyboard dispatch table above |
| `call [bp+0x2C]`, `call [bp+0x49]` | struct-relative | resolved — the object virtual-method dispatch above |
| `call [bx+0xE]`, `jmp [bx+si+5]` | struct-relative | still open |

Other:

- Analyse the self-modifying detail-level toggle at `0xA04E`, which patches
  `0xBBA9` between `nop nop` and `sar ax,1`.
- Check `lcall 0x14E8:0x1E2A` at `0xA973` — probably misread data, the segment
  matches no table entry.
- The windowed analysis estimates ~50,976 bytes of code. 30,395 bytes are
  reached, of which 1,647 are inline strings, so **~28,750 bytes of code, about
  56 % of the estimate**.
- The remaining ~22,000 bytes of estimated code are most likely reached only
  through the overlay interface or through the struct-relative dispatchers, so
  further progress there depends on the same two things everything else does.
