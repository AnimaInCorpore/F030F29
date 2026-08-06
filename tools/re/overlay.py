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
TRACK_TABLE = 0x134D                     # from `mov bx, 0x134D` in function AH=1
TRACK_TERMINATOR = 0xFF
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


def music_tracks(overlay: bytes, limit: int = 16) -> list[tuple[int, list]]:
    """Parse the track table into [(header, [(count, pointer), ...]), ...].

    Function AH=1 walks it: a header byte, then four-byte voice entries, then a
    0xFF.  Skipping to track N is `inc bx / add bx,4` until the terminator,
    repeated N times, which fixes the layout exactly.

    Each voice entry is (count, pointer) and the pointer leads to `count` words,
    every one of them the address of a pattern - so the structure is the usual
    tracker arrangement of song, voices, sequence, patterns.
    """
    def sane(count: int, pointer: int) -> bool:
        return 0 < count <= 64 and 0 < pointer and pointer + 2 * count <= len(overlay)

    tracks, pos = [], TRACK_TABLE
    while pos < len(overlay) and len(tracks) < limit:
        header, pos = overlay[pos], pos + 1
        voices = []
        while pos + 4 <= len(overlay) and overlay[pos] != TRACK_TERMINATOR:
            count, pointer = struct.unpack_from("<HH", overlay, pos)
            if not sane(count, pointer):
                voices = []               # ran past the table into pattern data
                break
            voices.append((count, pointer))
            pos += 4
        if not voices:
            break
        if pos < len(overlay) and overlay[pos] == TRACK_TERMINATOR:
            pos += 1
        tracks.append((header, voices))
    return tracks


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
    print()

    tracks = music_tracks(overlay)
    patterns = set()
    for _, voices in tracks:
        for count, pointer in voices:
            for k in range(count):
                patterns.add(struct.unpack_from("<H", overlay, pointer + 2 * k)[0])
    voices_total = sum(len(v) for _, v in tracks)
    seq_lo = min(p for _, v in tracks for _, p in v)
    seq_hi = max(p + 2 * c for _, v in tracks for c, p in v)

    print(f"music: {len(tracks)} tracks, {voices_total} voices, "
          f"{len(patterns)} distinct patterns")
    table_end = TRACK_TABLE + sum(2 + 4 * len(v) for _, v in tracks)
    print(f"  track table   {TRACK_TABLE:#06x}..{table_end - 1:#06x}")
    print(f"  sequences     {seq_lo:#06x}..{seq_hi - 1:#06x}")
    print(f"  patterns      {min(patterns):#06x}..{len(overlay) - 1:#06x}  "
          f"({len(overlay) - min(patterns)} bytes)")
    for i, (header, voices) in enumerate(tracks):
        print(f"  track {i}: header {header:#04x}, {len(voices)} voices, "
              f"{sum(c for c, _ in voices)} sequence steps")


if __name__ == "__main__":
    main()
