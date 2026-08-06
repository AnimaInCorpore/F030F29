#!/usr/bin/env python3
"""Analyse the overlay in RETAL.00 resource 15 and the calls into it.

The overlay is the sound and music driver. X.EXE loads it into segment table
slot 8 and calls offset 0 through `lcall [0xFC14]`, with a command in AX:
AH selects the function, AL carries the parameter.

Its own dispatch table lives at offset 0xC5E of the **decompressed** resource -
reading it in the packed file yields nonsense, which is what made this look
unresolvable for a while. The packed stream happens to start with bytes that
contain no 0x26 escape, so the first instructions decode correctly and the
mistake is not obvious.

    python tools/re/overlay.py            # function table plus call sites
"""
import argparse
import collections
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
except ImportError:
    sys.exit("capstone is required: python -m pip install capstone")

DISPATCH_TABLE = 0xC5E
LCALL_PATTERN = b"\xff\x1e\x14\xfc"      # lcall far [0xFC14]
MOV_AX_IMM = 0xB8

# Hardware the driver touches, established from its port constants.
PORTS = {
    0x388: "AdLib / OPL2 address",
    0x389: "AdLib / OPL2 data",
    0x330: "MPU-401 data",
    0x331: "MPU-401 status",
    0x61: "PC speaker gate",
    0x42: "PIT channel 2",
    0x43: "PIT control",
}


def load_exe(path: str) -> bytes:
    data = open(path, "rb").read()
    lastpage, pages = struct.unpack_from("<HH", data, 2)
    hdrsize = struct.unpack_from("<H", data, 8)[0] * 16
    imagesize = (pages - 1) * 512 + lastpage if lastpage else pages * 512
    return data[hdrsize:imagesize]


def function_table(overlay: bytes, md) -> list[tuple[int, int, str]]:
    """Return (AH, entry offset, first instructions) until the table ends."""
    out = []
    for ah in range(64):
        entry = struct.unpack_from("<H", overlay, DISPATCH_TABLE + 2 * ah)[0]
        if not 0 < entry < len(overlay):
            break
        head = list(md.disasm(overlay[entry:entry + 16], entry))[:3]
        out.append((ah, entry, " / ".join(f"{i.mnemonic} {i.op_str}".strip()
                                          for i in head)))
    return out


def call_sites(image: bytes, md) -> list[tuple[int, int | None, int | None]]:
    """Every lcall site with the AX value loaded before it, where static."""
    sites, pos = [], 0
    while True:
        pos = image.find(LCALL_PATTERN, pos)
        if pos < 0:
            break
        found = None
        for back in range(3, 40):
            start = pos - back
            if start < 0:
                break
            if image[start] != MOV_AX_IMM:
                continue
            decoded = list(md.disasm(image[start:pos + 4], start))
            if decoded and sum(i.size for i in decoded[:-1]) == pos - start:
                found = struct.unpack_from("<H", image, start + 1)[0]
                break
        sites.append((pos, None, None) if found is None
                     else (pos, found >> 8, found & 0xFF))
        pos += 1
    return sites


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default="assets/extracted/F29Retal/Retal/X.EXE")
    ap.add_argument("--overlay", default="re/unpacked/RETAL_00_15_t0.raw")
    args = ap.parse_args()

    md = Cs(CS_ARCH_X86, CS_MODE_16)
    try:
        overlay = open(args.overlay, "rb").read()
    except FileNotFoundError:
        sys.exit(f"{args.overlay} not found - run unpack.py and decompress.py first")
    image = load_exe(args.exe)

    table = function_table(overlay, md)
    print(f"overlay {len(overlay)} bytes, dispatch table at {DISPATCH_TABLE:#06x}, "
          f"{len(table)} functions")
    for ah, entry, head in table:
        print(f"  AH={ah:2d}  {entry:04X}  {head}")
    print()

    sites = call_sites(image, md)
    known = [s for s in sites if s[1] is not None]
    print(f"{len(sites)} call sites in X.EXE, {len(known)} with a static AX")
    by_fn = collections.Counter(ah for _, ah, _ in known)
    for ah, count in sorted(by_fn.items()):
        params = sorted({al for _, a, al in known if a == ah})
        shown = " ".join(f"{p:#04x}" for p in params[:8])
        print(f"  AH={ah:2d}  {count:2d} calls   AL: {shown}")
    print(f"  AX not static at {len(sites) - len(known)} sites")


if __name__ == "__main__":
    main()
