#!/usr/bin/env python3
"""Linear disassembly and hex dump of a range in the X.EXE load module.

Companion to disasm.py: recursive descent only shows what it could prove
reachable, so resolving an indirect jump needs a way to look at arbitrary
addresses - both as instructions and as raw words, since jump tables have to be
read as data.

    python tools/re/peek.py D2C0 -n 64          # disassemble
    python tools/re/peek.py D43A -n 64 --words  # read as a word table
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
    ap.add_argument("addr", help="start address, hex, as OFF or SEG:OFF")
    ap.add_argument("-n", "--count", type=int, default=32,
                    help="instructions to decode, or words/bytes to dump")
    ap.add_argument("--words", action="store_true", help="dump as 16-bit words")
    ap.add_argument("--bytes", action="store_true", help="dump as raw bytes")
    ap.add_argument("--exe", default="assets/extracted/F29Retal/Retal/X.EXE")
    args = ap.parse_args()

    image = load(args.exe)
    if ":" in args.addr:
        seg, off = (int(p, 16) for p in args.addr.split(":", 1))
    else:
        seg, off = 0, int(args.addr, 16)
    linear = (seg << 4) + off

    if args.words:
        print(f"{seg:04X}:{off:04X}  {args.count} words")
        for i in range(args.count):
            pos = linear + i * 2
            if pos + 2 > len(image):
                break
            w = struct.unpack_from("<H", image, pos)[0]
            note = ""
            if 0 < w < len(image):
                note = f"  -> {seg:04X}:{w:04X}"
            print(f"  [{off + i * 2:04X}]  {w:04X}{note}")
        return

    if args.bytes:
        print(f"{seg:04X}:{off:04X}  {args.count} bytes")
        for i in range(0, args.count, 16):
            chunk = image[linear + i:linear + i + 16]
            text = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
            print(f"  {off + i:04X}  {chunk.hex(' '):<47}  {text}")
        return

    md = Cs(CS_ARCH_X86, CS_MODE_16)
    md.detail = True
    print(f"{seg:04X}:{off:04X}  {args.count} instructions")
    for insn in md.disasm(image[linear:linear + args.count * 8], off, args.count):
        ops = insn.op_str
        # Capstone does not wrap near-branch targets into the segment, so a
        # backwards branch shows up as 0x1xxxx.  Mask it for readability.
        if insn.mnemonic in ("call", "jmp") or insn.mnemonic.startswith("j"):
            try:
                if ops.startswith("0x") and int(ops, 16) > 0xFFFF:
                    ops = f"{int(ops, 16) & 0xFFFF:#06x}"
            except ValueError:
                pass
        print(f"  {seg:04X}:{insn.address:04X}  {insn.bytes.hex():<14}  {insn.mnemonic:<7} {ops}")


if __name__ == "__main__":
    main()
