#!/usr/bin/env python3
"""Segment a real-mode image into code and data regions.

Scores each window by how well a linear x86-16 sweep decodes it.  Code
self-synchronises: a sweep started at an arbitrary offset inside real code
re-aligns within a few instructions and then produces a long run of valid,
short instructions.  Data produces either decode failures or implausibly long
"instructions" and a very different opcode mix.
"""
import argparse
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
except ImportError:
    sys.exit("capstone is required: python -m pip install capstone")

WINDOW = 256

# Opcodes that dominate real x86-16 program text.
CODE_OPS = {
    "mov", "call", "ret", "push", "pop", "cmp", "jmp", "je", "jne", "jz", "jnz",
    "add", "sub", "inc", "dec", "test", "and", "or", "xor", "lea", "retf",
    "shl", "shr", "loop", "jb", "jae", "ja", "jbe", "jl", "jge", "jg", "jle",
}
# Opcodes that essentially never appear in hand-written game code and are a
# strong tell that the sweep is chewing through data.
JUNK_OPS = {"aaa", "aad", "aam", "aas", "daa", "das", "into", "salc", "hlt",
            "in", "out", "lock", "arpl", "bound", "les", "lds", "sahf", "lahf"}


def score(md, block: bytes, base: int) -> float:
    """0.0 = looks like data, 1.0 = looks like code."""
    decoded = list(md.disasm(block, base))
    if not decoded:
        return 0.0
    covered = sum(i.size for i in decoded)
    if covered < len(block) * 0.75:
        return 0.0                       # sweep stalled on undecodable bytes
    good = sum(1 for i in decoded if i.mnemonic in CODE_OPS)
    junk = sum(1 for i in decoded if i.mnemonic in JUNK_OPS)
    return max(0.0, (good - 2 * junk) / len(decoded))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("exe", nargs="?", default="assets/extracted/F29Retal/Retal/X.EXE")
    ap.add_argument("--raw", action="store_true", help="treat input as a flat image, no MZ header")
    ap.add_argument("--threshold", type=float, default=0.45)
    args = ap.parse_args()

    data = open(args.exe, "rb").read()
    if args.raw:
        image, base_note = data, "flat image"
    else:
        lastpage, pages = struct.unpack_from("<HH", data, 2)
        hdrsize = struct.unpack_from("<H", data, 8)[0] * 16
        imagesize = (pages - 1) * 512 + lastpage if lastpage else pages * 512
        image, base_note = data[hdrsize:imagesize], f"MZ load module (header {hdrsize} B)"

    md = Cs(CS_ARCH_X86, CS_MODE_16)
    scores = [
        (off, score(md, image[off:off + WINDOW], off))
        for off in range(0, len(image), WINDOW)
    ]

    # Merge adjacent windows of the same class into runs.
    runs, cur_kind, cur_start = [], None, 0
    for off, s in scores:
        kind = "code" if s >= args.threshold else "data"
        if kind != cur_kind:
            if cur_kind is not None:
                runs.append((cur_kind, cur_start, off - cur_start))
            cur_kind, cur_start = kind, off
    runs.append((cur_kind, cur_start, len(image) - cur_start))

    code = sum(n for k, _, n in runs if k == "code")
    dat = sum(n for k, _, n in runs if k == "data")
    print(f"{args.exe}: {len(image)} bytes, {base_note}")
    print(f"  code ~{code:6d} bytes ({code * 100 / len(image):5.1f}%)")
    print(f"  data ~{dat:6d} bytes ({dat * 100 / len(image):5.1f}%)")
    print(f"  {len(runs)} runs at {WINDOW}-byte resolution, threshold {args.threshold}")
    print()
    print("  runs >= 1 KB:")
    for kind, start, size in runs:
        if size >= 1024:
            print(f"    {kind:4}  {start:#07x}..{start + size:#07x}  {size:6d} bytes")


if __name__ == "__main__":
    main()
