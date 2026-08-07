# Disassembling a DOS binary

Notes from taking `X.EXE` — 68 KB of hand-written x86 real mode, F29 Retaliator,
1990 — from an opaque blob to 44.6 % coverage with the archive format, the sound
driver, the model format and the way into the game code all decoded.

This is one binary, and a particular kind: a hand-written real-mode game from
the era when programmers still played tricks with the instruction stream. Some
of what follows generalises, some does not. The last section says which.

The methods here are implemented in `tools/re/`; the findings they produced are
in [RE-NOTES.md](RE-NOTES.md) and the format documents beside it.

---

## 1. Start with the container, not the code

Before disassembling anything, work out where the code *is*.

Parse the MZ header: header size, image size, entry `CS:IP`, `SS:SP`, and the
relocation table. The relocations are worth more than they look. `X.EXE` has
exactly four, all patching the same segment value — which said immediately that
the program computes its own segments rather than letting the loader do it, and
that it is essentially one 64 KB segment plus a small tail.

Then read the first thirty instructions. Startup code is short, unobfuscated and
tells you the memory model. Here it built a nine-entry segment table in place:
a loop that reads a size, stores a running base, adds the size. That gave the
whole memory map — 352 KB in nine regions — before a single game routine was
looked at.

**Watch for a second, larger view.** Buffers well past the load module are where
loaded data goes. Their sizes are a hint about what gets loaded.

## 2. Recursive descent is the spine

Follow control flow you can prove; do not linear-sweep. A linear sweep through
data produces plausible-looking instructions and no way to tell.

Two details matter in 16-bit mode:

- **Mask near branch targets into their segment.** Disassemblers compute
  `offset + rel` without wrapping, so a backwards branch shows up as `0x1xxxx`.
  Track `(segment, offset)` pairs, not flat addresses, and mask to 16 bits
  relative to the segment the *instruction* is in.
- **`int 20h` ends a program; `int 21h` usually does not.** Treat only the
  unconditional cases as terminal.

Expect this to stall early. Ours reached 8.2 %.

## 3. What actually stalls it: inline data idioms

This is the biggest single lesson. The blocker was not jump tables.

An **inline-string call** looks like this:

```
call print_routine
db  'SOME TEXT', 0x80        ; the string sits in the instruction stream
<execution resumes here>
```

The routine does `pop si` to take the return address as a string pointer, walks
the string, and `jmp si` past it. Anyone unaware of this disassembles from the
`call` straight into the text and derails — and everything downstream is lost.

Detecting it automatically is worth the effort, and there is a trap in doing so:

> **The scan must run over raw bytes, not over discovered call sites.** The
> routines worth finding are precisely the ones recursive descent has not
> reached, so grouping the call sites it *did* find is circular and finds
> nothing.

The test that works: scan the whole image for the `call rel16` encoding, group
by target, and classify a target as an inline-string routine if it has at least
three call sites and text follows at 80 % or more of them. Then re-run the
descent, which reveals more routines, and iterate to a fixpoint.

Terminators vary. Here it was "byte with bit 7 set", which also means the last
character of every string is corrupted from a naive strings dump — `SCENARI`,
`FIRE AND FORGE`. If your strings look like they are missing their last letter,
this is why.

The same idiom appears for **inline jump tables** (`pop bx / add bx,ax /
jmp [bx]`) and **inline byte strings for hardware** (the MT-32 init sequences).
Once you have seen it in one place, look for it everywhere.

## 4. Resolving indirect control flow

Work through these in order of leverage — count the sites first.

**Constant propagation.** `mov ax,imm / jmp ax` in the same basic block is free
to resolve. Track `mov reg, imm` and forget a register on any other write.

**Function pointers in registers across blocks.** If the program loads a
constant into a register anywhere and elsewhere does `call <that register>`,
the constant is a function entry. But be selective about *which* register:
here only `bp` qualified. Admitting `bx` and `di` gained coverage and dragged
in provably-data regions, because those registers hold data pointers in most
contexts — `mov si, 0xFC00` is a palette, and it would be seeded as code merely
because `jmp si` occurs somewhere else. That `jmp si` was the inline-string
return, not a function pointer at all.

**Jump tables.** The table base is usually visible in the addressing mode
(`call [bx-0x2BC6]` → base `0xD43A`). The hard part is the length, and it must
be *proven*, not eyeballed:

- a `mov cl,N` before the bounds check gives the count outright;
- a branch to an address makes that address code, so a table cannot extend past
  it — `jb 0xC572` bounded one table exactly;
- the start of a known routine bounds it — another ended precisely where an
  inline-string routine began;
- entries that point back into the table itself are not entries. That is how it
  became clear one dispatcher did not serve the markers it appeared to.

**Byte-scan for callers** when a routine is orphaned. Scanning for `call rel16`
targeting an address finds callers that recursive descent cannot reach, which
breaks the circle. False positives are real — `0xE8` occurs in data — so confirm
each hit against context.

## 5. Traps

**Self-modifying code.** Immediates get patched at run time. In this binary at
least six places do it: the resource number written into a `mov bx,imm`, the
filename digits written into the string, a detail-level toggle that swaps
`nop nop` for `sar ax,1`.

The consequence for analysis: *static bytes are a snapshot*. I read a word as a
resource number when it was the immediate of `mov ax,imm` — a jump vector for
the error path. Always ask whether a data address you are reading is actually
inside an instruction.

Check whether a table you are about to trust is written to: scan for every
`mov [imm16], reg` and `mov word [imm16], imm` targeting its range. Finding none
is worth knowing.

And the converse: **an address written to may not be a variable at all.** The
aircraft's airspeed appeared to live at `0xAE68`, written by the flight model
and read in twenty places, yet nothing ever displayed it. `0xAE68` is the
immediate of a `mov bx, imm` at `0xAE67` inside the instrument routine — the
model writes the speed into the instruction that will load it. When a variable
has writers and readers but no plausible consumer, check whether its address
lands inside an instruction.

In this binary that turned out to be the *standard* way of holding working
state, not an occasional trick — airspeed, altitude and both control axes are
all stored in the immediate of the instruction that reads them. On an 8086
`mov ax, imm` is appreciably faster than `mov ax, [mem]` because the immediate
is already in the prefetch queue, so it is an optimisation rather than
obfuscation. Once you have found one, assume there are more and check every hot
variable the same way.

**Signed versus unsigned comparisons.** `cmp al,0x41 / jl` is *signed*, so
values from `0x80` up take the low branch too. Reading it as unsigned sent me
looking for a second dispatch table that does not exist. When a dispatcher seems
to have a hole, check the condition code.

**Packed data read as unpacked.** The overlay's dispatch table gave nonsense
until I read the *decompressed* resource instead of the stored one. What hid the
mistake: the packed stream happened to start with bytes containing no escape
byte, so the first instructions decoded perfectly and nothing suggested
compression. Everything deeper was shifted. If a structure is valid at the start
and garbage further in, suspect this.

**Jumps into the middle of instructions.** A decompressor here emitted a literal
escape byte by jumping to the second byte of `cmp ax, 0xC38A` (`3d 8a c3`),
executing `8a c3` = `mov al, bl`. Disassemblers show one instruction; two exist.

## 6. Proving you are right

This is what separates a decode from a guess.

**Guard the regions you have already proven are data.** Every technique that
widens the sweep can be pushed until it manufactures code out of data. Keep a
list of addresses known to be data — palette, segment table, string pool,
archive index — and check after every run that none has been disassembled.

That guard set our parameters. Seeding every byte-scanned call target reached
**66.2 %** and disassembled six of ten known data regions; requiring two call
sites reached **44.6 %** and none. The 66 % is worthless: the extra coverage is
regions whose contents are already fully understood as data.

**Use structural invariants.** The strongest evidence is a decode that has to
land exactly:

- All 74 music patterns tokenise to end *precisely* on the boundary derived
  independently from the sequence table. One wrong operand size anywhere would
  desynchronise and overshoot. That single fact validates 27 opcode definitions.
- Both archive index tables end with a sentinel equal to the file size, and the
  resource lengths sum to the file exactly.
- A decompressor correction turned ten outputs into *exactly* 32,000 bytes —
  320 × 200 × 4 bits. Round numbers appearing where a format predicts them are
  worth more than any amount of plausible-looking disassembly.

**Statistics separate code from data cheaply.** Opcode frequency works well:
`call` at 1.9 % and `ret` at 1.0 % in real program text against 0.29 % and
0.15 % in the archives — an order of magnitude, and enough to settle whether a
file contains code at all.

**Render it.** For graphics, models or anything visual, convert and look. A
recognisable title screen or a control tower ends the argument in a way that no
byte-level reasoning does.

## 7. Finding your way around

**A call graph beats hunting for anchors.** Looking for the game loop by
searching for a trig table or a distinctive constant failed twice — both
candidates were data. The call graph found it structurally in one step: the
routine calling the most others, in the largest code region.

Attributing call sites to routines has a trap of its own, since boundaries are
unknown. "Nearest call target at or below the site" lets the last routine before
a large unreached region collect every site in it. That produced a 0x2B-byte
routine at the top of the ranking with 87 callees from a single caller, reading
exactly like a master dispatcher. **Bound an owner by contiguously reached
instructions** — a gap ends the routine — and the edge count drops from 607 to
351 as the phantoms disappear.

**Sanity-check the graph against something you already understand.** The
resource loader appearing with the right number of callees and callers is what
made the corrected graph trustworthy.

**Keep resolved targets in a file, with the evidence.** `re/seeds.txt` holds
every resolved indirect jump together with the reasoning that fixed its table
length. The disassembler reads it automatically, so coverage never regresses and
nobody re-derives the same table twice.

**Record the dead ends too.** Two documents here exist mainly to say what
something is *not* — that a dispatcher found after considerable effort is not
the one being looked for, and why. That is worth as much as a positive result to
whoever comes next.

## 8. What generalises, and what does not

Generalises to most binaries:

- container first, recursive descent as the spine, byte-scan to break
  reachability circles;
- prove table lengths rather than eyeballing them;
- guard known-data regions against every technique that widens coverage;
- validate with structural invariants and round numbers;
- call graph over anchor-hunting;
- keep resolved targets and dead ends in files.

Specific to hand-written real-mode code of this era:

- inline data after `call` — a compiler will not do this;
- self-modifying immediates, likewise;
- jumps into the middle of instructions;
- the specific register discipline. `bp` being the only function-pointer
  register is a fact about this program, not about x86. Measure it for yours.

Compiler output differs in the ways that matter: standard prologues make
boundaries obvious, jump tables are regular and bounded by a preceding compare,
and no data hides in the instruction stream. Recursive descent gets much further
before it stalls, and much of section 3 simply does not apply.
