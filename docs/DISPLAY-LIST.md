# The vector display list interpreter at 0x4777

Found while looking for the model face renderer. It is **not** that renderer —
see "Why this is not the model renderer" below — but it is a real interpreter
with its own dispatch table, and it is what the HUD and instrument work will
need.

## The dispatch loop

```
476D  mov  di, [bp+0x49]        ; stream base
4770  mov  bl, [bp+0x51]        ; offset into the stream
4773  sub  bh, bh
4775  lea  si, [bx+di]
4777  lodsb                     ; al = opcode                <- loop top
4778  mov  bl, al               ; used as a byte offset, NOT shifted
477A  jmp  word ptr [bx+0x46A5] ; dispatch
```

`mov bl, al` with no shift is the giveaway: the opcode byte indexes the table
at `0x46A5` directly, so opcodes are spaced by the table's stride.

## Table at 0x46A5

Word entries. Reading at the four-byte spacing the observed opcodes imply:

| Opcode | Handler | What it does |
|---|---|---|
| `0x00` | `0x4839` | loads `[bp+0x56]`, `[bp+0x5a]`, then falls into `0x4866` |
| `0x04` | `0x4843` | two words as coordinates, each added to an accumulator (`[bp+0x56]`, `[bp+0x5a]`), then `0x4866` — a **relative draw** |
| `0x08` | `0x4860` | two words as **absolute** coordinates, then `0x4866` |
| `0x0C` | `0x472B` | one word added to `[bp+0x26]`, masked `and ah,7` — an **angle**, 2048 units per revolution |
| `0x10` | `0x4721` | `dec [bp+0x54] / je / mov bl,[bp+0x55]` — a **loop/repeat** |
| `0x14` | `0x4793` | calls `0x1378`, compares against `0x17E` = 382 |
| `0x18` | `0x4784` | |
| `0x1C` | `0xC00A` | |
| `0x20` | `0xAFE9` | |
| `0x24` | `0x497E` | |

`0x4866` is the shared tail: it takes a third coordinate from `[bp+0x58]`,
clears `[bp+0x48]` and calls `0x13A3`, which is the draw.

The entries beyond `0x24` — `0x46CD` giving `0x46C6` and `0x46D1` giving
`0x468B` — point back inside the table region itself and are therefore not
valid handlers. The table ends at ten entries.

**The table is not self-modified.** A scan of every `mov [imm16], reg` and
`mov word [imm16], imm` in the image finds no write into `0x46A5..0x46D9`.

## Why this is not the model renderer

Three reasons, and the third is decisive:

1. The model face records use markers up to `0x2C`, and this table has no valid
   entry at `0x28` or `0x2C` — yet `0x28` is the single most common marker in
   the model data, 2,190 occurrences.
2. Its handlers work on relative and absolute coordinates fed through
   accumulators. The model face records carry **vertex references**, byte
   offsets that are multiples of six into the model's own vertex array. Those
   are different data models.
3. Applying this table's `0x0C` semantics (three bytes, an angle, no geometry)
   to the model parser changes the unparsed fraction by six bytes out of 88,928
   — from 20.0 % to 20.0 %.

So this interpreter drives some other vector list: the HUD, the cockpit
instruments, or the wireframe map. Relative draw, absolute draw, angle and
repeat opcodes are exactly the instruction set for that.

## Still looking for the model renderer

It dispatches through a table as well — a scan for `cmp al,0x28`, `cmp bl,0x28`
and `cmp cl,0x28` across the whole image finds **no** comparison against the
most common marker, so it is not a compare chain.

Searching for runs of ten or more consecutive plausible code pointers turns up
only data tables (monotonically rising values at a constant stride). Candidate
indirect sites not yet run down: `jmp [bx-0x5943]` at `0xA77E` (base `0xA6BD`,
adjacent to the known 13-entry HUD table at `0xA6D7`) and `jmp [bx-0x3467]` at
`0xCB8B` (base `0xCB99`).

Tool: `tools/re/findtable.py` lists every indirect near call/jmp with a memory
operand together with its lead-in, which is how `0x477A` was found.
