#!/usr/bin/env python3
"""Find direct callers/jumpers to an address by scanning the whole image.

Recursive descent can only find a routine once something reaches it.  When a
routine is orphaned - reachable only through an unresolved indirect jump - the
way back in is to scan every byte position for a relative call or jump that
lands on it, then confirm the hit against the listing.

Byte-level scanning produces false positives where E8/E9 happens to sit inside
data or in the middle of another instruction's operand, so hits are reported
with context rather than trusted blindly.

    python tools/re/xref.py E4C5            # who calls this?
    python tools/re/xref.py E440-E4C5       # who calls anything in this range?
"""
import argparse
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
except ImportError:
    sys.exit("capstone is required: python -m pip install capstone")


def load(path: str) -> bytes:
    data = open(path, "rb").read()
    lastpage, pages = struct.unpack_from("<HH", data, 2)
    hdrsize = struct.unpack_from("<H", data, 8)[0] * 16
    imagesize = (pages - 1) * 512 + lastpage if lastpage else pages * 512
    return data[hdrsize:imagesize]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("target", help="address or LO-HI range, hex")
    ap.add_argument("--exe", default="assets/extracted/F29Retal/Retal/X.EXE")
    ap.add_argument("--context", type=int, default=3,
                    help="instructions of context to show before each hit")
    args = ap.parse_args()

    if "-" in args.target:
        lo, hi = (int(p, 16) for p in args.target.split("-", 1))
    else:
        lo = hi = int(args.target, 16)

    image = load(args.exe)
    md = Cs(CS_ARCH_X86, CS_MODE_16)

    hits = []
    for pos in range(len(image) - 3):
        op = image[pos]
        if op not in (0xE8, 0xE9):          # call rel16 / jmp rel16
            continue
        rel = struct.unpack_from("<h", image, pos + 1)[0]
        target = (pos + 3 + rel) & 0xFFFF
        if lo <= target <= hi:
            hits.append((pos, "call" if op == 0xE8 else "jmp", target))

    kind = f"{lo:04X}" if lo == hi else f"{lo:04X}-{hi:04X}"
    print(f"{len(hits)} direct references to {kind}\n")
    for pos, mnem, target in hits:
        start = max(0, pos - args.context * 4)
        window = list(md.disasm(image[start:pos + 3], start))
        # Keep only the instructions that end exactly at the hit, so a decode
        # that drifted out of alignment is visible as a missing lead-in.
        aligned = [i for i in window if i.address + i.size <= pos + 3]
        for insn in aligned[-(args.context + 1):]:
            marker = "->" if insn.address == pos else "  "
            print(f"  {marker} 0000:{insn.address:04X}  {insn.mnemonic:<7} {insn.op_str}")
        print(f"     (target {target:04X}, inline data follows at {pos + 3:04X}: "
              f"{image[pos + 3:pos + 19].hex(' ')})")
        print()


if __name__ == "__main__":
    main()
