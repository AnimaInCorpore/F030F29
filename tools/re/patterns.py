#!/usr/bin/env python3
"""Decode the music pattern command stream in the overlay.

The interpreter sits at 0x01D0 of the decompressed overlay:

    01D0  lodsb                     ; token
    01D1  cmp  al, 0x41
    01D3  jl   0x1DD                ; SIGNED - so 0x80..0xFF go here too
    01D5  shl  al, 1
    01D7  mov  bl, al
    01D9  jmp  word ptr [bx+0x8F8]  ; command dispatch

and the sub-0x41 path splits again on the unsigned comparison:

    01DD  jae  0x1E4
    01DF  mov  [di+0x1C], al        ; 0x00..0x40 - duration
    01E2  jmp  bp
    01E4  mov  [di+0x20], al        ; 0x80..0xFF - note
    01E7  mov  [di+0x12], si
    01FC  call word ptr [0xBCD]     ;   and trigger note-on

So a token is one of three things:

    0x00..0x40   duration
    0x41..0x5B   command, mnemonic is the ASCII letter, 0 to 2 operand bytes
    0x80..0xFF   note, triggers note-on

Operand sizes come from each handler: whether it does lodsb, lodsw or neither.
The command table ends at 0x5B because entry 0x5C would fall on 0x9B0, which is
where the channel structures begin.
"""
import argparse
import struct
import sys

TRACK_TABLE = 0x134D
COMMAND_TABLE = 0x8F8
CMD_LO, CMD_HI = 0x41, 0x5B

# (mnemonic letter, operand bytes, what the handler does)
COMMANDS = {
    0x41: ("A", 0, "restore duration from [di+0x1C]"),
    0x42: ("B", 0, "loop via [di+0x24] and [di+0x14]"),
    0x43: ("C", 0, "test [di]; end of pattern when zero"),
    0x44: ("D", 1, "set [di+0x21]"),
    0x45: ("E", 1, "set global [0x236]"),
    0x46: ("F", 1, "set global [0x156]"),
    0x47: ("G", 0, "loop start, count 2, mark at [di+0x16]"),
    0x48: ("H", 1, "loop start, count from operand"),
    0x49: ("I", 0, "loop end, decrement [di+0x25]"),
    0x4A: ("J", 1, "set [di+0x1D]"),
    0x4B: ("K", 0, "clear [di+0x1D]"),
    0x4C: ("L", 1, "device call through [0xBBF]"),
    0x4D: ("M", 1, "set global [0x1A8]"),
    0x4E: ("N", 1, "set [di+0x0C], [di+0x0D]"),
    0x4F: ("O", 2, "set [di+0x0C], [di+0x0D] from word"),
    0x50: ("P", 2, "set [di+0x10] word"),
    0x51: ("Q", 1, "set global [0x755]"),
    0x52: ("R", 2, "set [di+0x0C], [di+0x0D] word"),
    0x53: ("S", 0, "set flag 0x20 in [di+4]"),
    0x54: ("T", 0, "set flag 0x10 in [di+4]"),
    0x55: ("U", 1, "set [di+0x1A]"),
    0x56: ("V", 1, "set [di+0x0F]"),
    0x57: ("W", 0, "no operation"),
    0x58: ("X", 0, "jmp si"),
    0x59: ("Y", 2, "conditional on bit 0"),
    0x5A: ("Z", 1, "relative branch, signed"),
    0x5B: ("[", 1, "set global [0x5CA]"),
}


def decode(data: bytes, start: int, end: int | None = None):
    """Decode tokens in [start, end). Returns (tokens, end offset, error).

    Patterns are **not** self-terminating.  Their extent comes from the
    sequence table: sorting every referenced pattern address gives boundaries,
    and each pattern runs up to the next one.  All 74 of them tokenise to land
    exactly on that boundary, which is what validates the operand sizes - a
    single wrong one would desynchronise the stream and overshoot.

    The most common last token is B (0x42), which reloads si from [di+0x14],
    so it means "pattern finished, advance the sequence".  Some patterns end on
    C, Z or simply run to the boundary instead.
    """
    limit = len(data) if end is None else end
    tokens, pos = [], start
    while pos < limit:
        token = data[pos]
        pos += 1
        if token >= 0x80:
            tokens.append((token, "note", token, None))
            continue
        if token < CMD_LO:
            tokens.append((token, "dur", token, None))
            continue
        if token > CMD_HI:
            return tokens, pos, f"unknown command {token:#04x} at {pos - 1:#06x}"
        name, nargs, _ = COMMANDS[token]
        if pos + nargs > limit:
            return tokens, pos, f"operand of {name} crosses the boundary"
        arg = None
        if nargs == 1:
            arg = data[pos]
        elif nargs == 2:
            arg = struct.unpack_from("<H", data, pos)[0]
        pos += nargs
        tokens.append((token, name, arg, nargs))
    return tokens, pos, None if pos == limit else "desynchronised"


def pattern_bounds(overlay: bytes) -> list[tuple[int, int]]:
    """Every referenced pattern as (start, end), derived from the sequence table."""
    refs = set()
    for _, voices in tracks(overlay):
        for count, pointer in voices:
            for k in range(count):
                refs.add(struct.unpack_from("<H", overlay, pointer + 2 * k)[0])
    ordered = sorted(refs)
    return [(s, ordered[i + 1] if i + 1 < len(ordered) else len(overlay))
            for i, s in enumerate(ordered)]


def tracks(overlay: bytes):
    out, pos = [], TRACK_TABLE
    while pos < len(overlay):
        header, pos = overlay[pos], pos + 1
        voices = []
        while pos + 4 <= len(overlay) and overlay[pos] != 0xFF:
            count, pointer = struct.unpack_from("<HH", overlay, pos)
            if not (0 < count <= 64 and 0 < pointer + 2 * count <= len(overlay)):
                voices = []
                break
            voices.append((count, pointer))
            pos += 4
        if not voices:
            break
        pos += 1
        out.append((header, voices))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--overlay", default="re/unpacked/RETAL_00_15_t0.raw")
    ap.add_argument("--pattern", help="decode a single pattern at this hex offset")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    try:
        overlay = open(args.overlay, "rb").read()
    except FileNotFoundError:
        sys.exit(f"{args.overlay} not found - run unpack.py and decompress.py first")

    if args.pattern:
        start = int(args.pattern, 16)
        stop = next((e for s, e in pattern_bounds(overlay) if s == start), None)
        if stop is None:
            sys.exit(f"{start:#06x} is not a referenced pattern start")
        toks, end, err = decode(overlay, start, stop)
        print(f"pattern {start:#06x}..{end:#06x}  {len(toks)} tokens"
              + (f"  ERROR: {err}" if err else ""))
        for token, name, arg, nargs in toks:
            if name == "note":
                print(f"  {token:02x}        note {token:#04x}")
            elif name == "dur":
                print(f"  {token:02x}        duration {token}")
            elif nargs == 0:
                print(f"  {token:02x}        {name}         {COMMANDS[token][2]}")
            else:
                width = 2 if nargs == 1 else 4
                print(f"  {token:02x} {arg:0{width}x}   {name} {arg:#0{width + 2}x}"
                      f"   {COMMANDS[token][2]}")
        return

    bounds = pattern_bounds(overlay)
    ok, failed, notes, durations, used = 0, [], 0, 0, {}
    last_token = {}
    for start, end in bounds:
        toks, stop, err = decode(overlay, start, end)
        if err:
            failed.append((start, err))
            continue
        ok += 1
        if toks:
            name = toks[-1][1]
            last_token[name] = last_token.get(name, 0) + 1
        for token, name, _, _ in toks:
            if name == "note":
                notes += 1
            elif name == "dur":
                durations += 1
            else:
                used[name] = used.get(name, 0) + 1

    span = bounds[-1][1] - bounds[0][0]
    print(f"{len(bounds)} patterns, {ok} tokenise exactly to their boundary, "
          f"{len(failed)} desynchronise")
    print(f"  region {bounds[0][0]:#06x}..{bounds[-1][1]:#06x}, {span} bytes")
    print(f"  {notes} notes, {durations} durations, {sum(used.values())} commands")
    print(f"  last token: "
          + ", ".join(f"{n} {c}x" for n, c in
                      sorted(last_token.items(), key=lambda kv: -kv[1])[:5]))
    print()
    print("  commands used:")
    for name in sorted(used, key=lambda n: -used[n]):
        code = next(c for c, (n, _, _) in COMMANDS.items() if n == name)
        print(f"    {name} ({code:#04x})  {used[name]:4d}x   {COMMANDS[code][2]}")
    unused = [n for _, (n, _, _) in sorted(COMMANDS.items()) if n not in used]
    if unused:
        print(f"  never used: {' '.join(unused)}")
    for start, err in failed[:10]:
        print(f"  FAILED {start:#06x}: {err}")


if __name__ == "__main__":
    main()
