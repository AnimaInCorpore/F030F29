# Continuing the disassembly

For picking this work up cold. [X86DISASSEMBLE.md](X86DISASSEMBLE.md) is the
general technique — read that first if disassembling a DOS binary is new.
This document is the operational side: what's in this repository, what tools
exist, how a session of work actually proceeds, and the patterns worth
knowing before spending an hour rediscovering them.

## The moving pieces

```
assets/            the original game - gitignored, bring your own copy
re/
  seeds.txt         resolved indirect jump targets, WITH evidence - committed
  listings/x.lst    the current disassembly - regenerated, gitignored
  resources/        extracted archive contents - gitignored
  unpacked/         decompressed resources - gitignored
tools/re/           the tools that produced all of the above - committed
docs/               the findings - committed
```

Nothing under `assets/`, `re/resources/`, `re/unpacked/` or `re/listings/`
is ever committed — see [Copyright](#copyright), it is load-bearing, not
incidental. `re/seeds.txt` is the one file under `re/` that *is* committed:
it holds no game data, only addresses and the reasoning that resolved them.

## Regenerating the listing

```bash
python tools/re/disasm.py
```

Reads `assets/extracted/F29Retal/Retal/X.EXE`, applies every seed in
`re/seeds.txt`, and writes `re/listings/x.lst`. Read the tail of its own
output every time — it is the health check for everything downstream:

```
reached 12771 instructions, 31116 bytes (45.7% coverage)
call targets: 354   branch targets: 1476
data check: all 13 known data regions left alone
indirect control flow: 74 sites, 21 distinct forms
unreached regions (132 total, largest 15)
```

**`data check` must say every region is left alone, every time.** That line
is the guard against manufacturing code out of data — see
`KNOWN_DATA`/`EXPECTED_DATA_HITS` near the top of `disasm.py`. If a change
ever makes a known-data region show up as reached, the change is wrong,
full stop, regardless of how much coverage it gained.

**Coverage is capped at 45.7% on purpose**, via `--scan-calls` (default 2 —
a byte-scanned call target needs at least two call sites before it's
trusted). `--scan-calls 1` reaches 66% but disassembles seven proven-data
regions as code; the extra coverage is worthless because it isn't real.
Raising coverage further needs *proof* for specific new call targets or
indirect sites (like the seeding work below), not a looser threshold.

`--callgraph N` prints the routines that call the most others — this is how
the game loop and several major subsystems were found originally; hunting
for anchors (a trig table, a distinctive constant) failed twice before the
call graph found the same routine structurally in one step.

## The toolbox

Roughly in the order a piece of work touches them:

| Tool | For |
|---|---|
| `mzinfo.py` | MZ header, relocations, segment layout — start here on a new binary |
| `codemap.py` | segment a real-mode image into code/data by how well a linear sweep self-synchronises |
| `disasm.py` | the recursive-descent disassembler itself |
| `peek.py` | linear disassembly / hex dump of an arbitrary range — companion to `disasm.py` for looking at what recursive descent hasn't reached. **Has misaligned before** (see Traps) — cross-check anything it shows against the real listing |
| `xref.py` | byte-scan the whole image for callers of an orphaned address |
| `findtable.py` | locate indirect `call`/`jmp` sites with a memory operand — for finding dispatch tables |
| `unpack.py` | extract archive resources (`RETAL.00`/`RETAL.01`) |
| `decompress.py` | RLE-decompress a resource |
| `overlay.py` | the sound/music driver overlay and its call sites |
| `patterns.py` | the music pattern command-stream decoder |
| `models.py` | parse 3D models out of a decompressed library |
| `objects.py` | parse world object placement lists |
| `render.py` | render a decompressed type-1 (EGA bitmap) resource to PNG |
| `model2o3d.py` | convert one model to the engine's `.o3d` format |
| `scene2f29.py` | build a scene file (model library + placements) for the engine |

Each has a docstring at the top of the file explaining its own format
assumptions and which disassembled routine it reimplements — read that
before the code.

## The session workflow

This is what an actual piece of continuing work looks like, start to finish:

1. **Pick a target.** Usually one of: an unexamined callee named in a doc's
   `## Open` section (`grep -rn '^## Open\|^### Open' docs/*.md` and read
   what follows), an unresolved indirect from `disasm.py`'s own tail output,
   or a routine `--callgraph` surfaces with high fan-out that nothing has
   named yet.
2. **Read it from the listing, not `peek.py`.** Pull the routine with
   something like:
   ```bash
   n=$(grep -n "^sub_0000_XXXX:" re/listings/x.lst | cut -d: -f1)
   end=$(grep -n "^sub_0000_" re/listings/x.lst | awk -F: -v n="$n" '$1>n{print $1; exit}')
   sed -n "${n},${end}p" re/listings/x.lst
   ```
   The end boundary this finds is *whatever the next label is*, which is not
   always the real end of the routine — cross-check against a `ret` and
   watch for the routine falling straight through into what looks like a
   separate label (this has happened repeatedly: two "routines" turning out
   to be one contiguous body with an internal entry point).
3. **Decode every branch.** Don't leave a `...` where the descent gets
   complicated — a truncated write-up reads as finished and wastes the next
   session's time re-establishing what was already half-found. If a routine
   is genuinely large, it is fine to note *which specific branch* is still
   open, but trace the shape of the whole thing first.
4. **Cross-check before trusting a reading.** The single most productive
   move in this whole effort has been grepping for every other reference to
   an address once one use of it is understood — `grep -n "0xXXXX" 
   re/listings/x.lst`. Repeatedly, the *other* user of a table turned out to
   be its writer (settling what it holds), or a second call site with
   different register contents (settling a parameter's range), or a
   completely different subsystem reusing the same field for an unrelated
   reason worth knowing about.
5. **Verify structurally wherever possible**, in order of strength:
   round numbers that fall out exactly (a table that fills its slot with
   zero bytes to spare), independent derivations agreeing (three HUD fields
   all resolving to the same `frame_count`), simulation (running a
   suspected PRNG and checking its period/distribution), rendering (a
   decoded model or bitmap looking like something recognisable). Plausible
   disassembly is the weakest evidence available and every wrong finding
   logged in [RE-NOTES.md](RE-NOTES.md) passed a plausibility check first.
6. **If an indirect call/jump needed resolving**, add it to `re/seeds.txt`
   with the reasoning inline as a comment above the address (match the
   existing entries' style), then re-run `disasm.py` and confirm the data
   guard still passes and coverage moved the way expected. Decode the raw
   bytes at the target independently *before* seeding, as a sanity check
   that it's real code and not data that happens to be reachable via some
   register value.
7. **Document in the right place.** Check the doc-per-topic map below
   before adding a new file — most findings extend an existing document.
   Update or remove the `## Open` bullet the finding closes; add new ones
   for whatever it opened up. Cross-reference between docs with relative
   markdown links.
8. **Guard check, then commit.** `python tools/re/disasm.py` one more time
   before every commit — a doc-only change should show identical coverage
   and a clean data-guard line; if it doesn't, something is wrong with the
   commit, not the guard.

## Patterns worth knowing before rediscovering them

- **Self-modifying immediates are this program's standard way of holding
  working state**, not an occasional trick — an 8086 optimisation, since
  `mov ax,imm` beats `mov ax,[mem]` with the immediate already in the
  prefetch queue. Confirmed for airspeed, altitude (three different
  representations), pitch, bank, heading and more — see
  [FLIGHT-MODEL.md](FLIGHT-MODEL.md). **When an address has both writers
  and readers but no consumer that does anything with the value, check
  whether the address itself sits inside an instruction.**
- **World position fields are consistently laid out**: `+0xE` is X (high
  word of a 16.16 pair), `+0x12` is Y, `+0x16` is Z, across every structure
  that carries a position — world object instances, the waypoint database,
  the k-d tree keys, arrival/proximity checks. Seeing these three offsets
  together is close to proof of a position-bearing structure on sight.
- **A negative field can be a tagged index rather than a value.** Seen at
  the `0x9811` scan's `es:[di+0x22]` (resolved through a table built at
  *load* time by the resource-11 loader, not at runtime — see
  [MODEL-FORMAT.md](MODEL-FORMAT.md) and [GAME-LOOP.md](GAME-LOOP.md)).
  `not reg / shl reg,1 / jae`/`jb` on the shifted value is the tell — it's
  testing the original sign bit without a plain `test`.
- **The high-bit terminator convention** used for inline strings
  (X86DISASSEMBLE.md) generalises: `0x5CEE` skips *N* consecutive
  terminated records the same way, not just one string.
- **`[0xF3A2]`, the theatre, gates far more than it looks like it should** —
  `0xCC8C`'s own entry test, a per-theatre parameter table at `0x75FC`, and
  a per-theatre mission-script pointer table at `0x9C84` are three separate
  subsystems keying off the identical byte. If something looks
  theatre-specific, grep for `0xf3a2` before assuming it's standalone.
- **Attribute call sites to a routine by contiguously reached
  instructions — a gap ends it.** "Nearest call target at or below the
  site" produces phantom master-dispatchers that are really the last real
  routine before a large unreached region collecting every site inside it.
- **Only `bp` has been proven as a function-pointer register** in general
  dispatch; `bx`/`di` usually hold data pointers here and seeding them as
  call targets drags in provably-data regions. Individual `call bx`/`call
  bx`-style sites are still resolved case by case (`0x9930` is one,
  confirmed by decoding its raw bytes before seeding) — the point is not to
  admit the register *class* wholesale.

## Traps

The generalisable ones (inline data, signed/unsigned confusion, packed data
read unpacked, jumps into the middle of an instruction) are in
[X86DISASSEMBLE.md](X86DISASSEMBLE.md) §5. Specific to working *in this
repository*:

- **`peek.py` has reported misaligned addresses more than once** — trust the
  recursive-descent listing over it; if the two disagree, the listing wins.
- **The engine's debug font is 4x5 pixels.** Screenshots read at thumbnail
  scale have produced real misreadings — "913" for "013", "12352" for
  "12952" — that looked exactly like plausible bugs until the PNG was
  cropped and upscaled. Do that before debugging a discrepancy that
  involves reading rendered digits.
- **When editing a doc in Python, build the full string first, then open
  the file for writing.** `open(p,'w')` truncates immediately; a
  `UnicodeEncodeError` (or anything else) raised after that point leaves an
  empty file, and a following `git add -A` will happily commit the loss.
  Write UTF-8 explicitly. This destroyed `RE-NOTES.md` once; it was
  recovered from git history, and the lesson is why this note exists.
- **A "wrong result" from a rendered or simulated check is sometimes a
  measurement bug, not a code bug** — a frame grabbed too early shows the
  TOS desktop, not the program; a frame rate divided by the wrong interval
  gives a plausible-looking but meaningless number. Before changing code
  again because a check came back wrong, confirm the check is measuring
  what it claims to.

## The documentation map

| Doc | Scope |
|---|---|
| [RE-NOTES.md](RE-NOTES.md) | memory layout, resolved dispatchers, the inline-string idiom, dead ends |
| [GAME-LOOP.md](GAME-LOOP.md) | the per-frame update — state dispatch, `0xCC8C`'s callees, timing, mission scripts, waypoints. The largest and most active document; consider splitting a subsystem out (as `FLIGHT-MODEL.md` was) if a section outgrows the page |
| [FLIGHT-MODEL.md](FLIGHT-MODEL.md) | the flight model in full |
| [ARCHIVE-FORMAT.md](ARCHIVE-FORMAT.md), [RESOURCE-FORMATS.md](RESOURCE-FORMATS.md) | container and compression format of `RETAL.00`/`RETAL.01` |
| [MODEL-FORMAT.md](MODEL-FORMAT.md), [WORLD-FORMAT.md](WORLD-FORMAT.md) | 3D models and placement lists |
| [SOUND-DRIVER.md](SOUND-DRIVER.md), [ADLIB-BACKEND.md](ADLIB-BACKEND.md), [MPU401-BACKEND.md](MPU401-BACKEND.md) | the audio subsystem — deferred, but decoded as far as documented |
| [DISPLAY-LIST.md](DISPLAY-LIST.md) | the `0x4777` vector interpreter, and what it turned out not to be |
| [ARCHITECTURE.md](ARCHITECTURE.md), [ENGINE.md](ENGINE.md), [HUD.md](HUD.md) | the Falcon port itself, not the reverse engineering |

A finding almost always extends one of these rather than needing a new file.
Split a new document out only when a section has grown large enough to be
its own subject with its own `## Open` list — that has happened once
(`FLIGHT-MODEL.md` out of `GAME-LOOP.md`) and is a reasonable move again if
`GAME-LOOP.md` keeps growing.

## Copyright

No game data, in any form, ever gets committed — not the original files, not
extracted or decompressed resources, not rendered images, not the
disassembly listing itself. `.gitignore` enforces the mechanical side; the
discipline is to write findings as *mechanism* (formats, algorithms,
addresses, control flow) rather than *content* (the actual table values,
text strings, artwork). Where a value matters for a structural proof — a
round number, a sentinel — quoting that one value is fine; dumping a table's
contents is not.

## Where the frontier is right now

This section is a snapshot and will go stale fast — treat it as a starting
point, not a source of truth. The reliable way to find current open work is:

```bash
grep -rn '^## Open\|^### Open' docs/*.md
```

then read what follows each match. As of this writing: `0xCC8C`'s
eighteen direct callees are all read, several with their own callees fully
traced (`0x9811`, `0x9824`, `0x9930`, `0x9986`, `0x993E`, `0x314E`/`0x3160`);
the state-handler and cockpit-panel work is likewise done. The 3D model
parser still has a 20% unparsed fraction (further primitive types, tracked
in [MODEL-FORMAT.md](MODEL-FORMAT.md)); the sound subsystem is decoded but
deliberately not wired into the engine yet; and 45.7% raw coverage still
leaves 132 unreached regions, the largest 4.25 KB, that no seed currently
reaches at all.
