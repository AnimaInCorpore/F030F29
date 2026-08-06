#!/usr/bin/env python3
"""Locate indirect near call/jmp instructions with a memory operand.

Used to find the renderer's primitive dispatch table. The model face markers
are all multiples of four and index the table directly, so the dispatch site
should read a byte from the model stream and use it as an offset *without* a
shift - which is unusual enough to pick out, since most jump tables need a
`shl bx,1` first.

Encoding: 0xFF followed by a ModRM byte whose reg field is 2 (call near
indirect) or 4 (jmp near indirect) and whose mod field is not 3.
"""
import argparse
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
except ImportError:
    sys.exit("capstone is required: python -m pip install capstone")

RM_NAMES = ["bx+si", "bx+di", "bp+si", "bp+di", "si", "di", "bp", "bx"]
# A byte fetched straight from the model stream lands in AL, so these are the
# instructions worth seeing in the lead-in.
LEAD_HINTS = ("lodsb", "mov", "xor", "sub", "and", "movzx", "xchg")


def load(path: str) -> bytes:
    data = open(path, "rb").read()
    lastpage, pages = struct.unpack_from("<HH", data, 2)
    hdrsize = struct.unpack_from("<H", data, 8)[0] * 16
    imagesize = (pages - 1) * 512 + lastpage if lastpage else pages * 512
    return data[hdrsize:imagesize]


def decode_operand(image: bytes, pos: int):
    """Return (text, displacement, total instruction length) or None."""
    modrm = image[pos + 1]
    mod, reg, rm = modrm >> 6, (modrm >> 3) & 7, modrm & 7
    if mod == 3 or reg not in (2, 4):
        return None
    kind = "call" if reg == 2 else "jmp"
    if mod == 0 and rm == 6:                       # disp16 only, no base
        disp = struct.unpack_from("<H", image, pos + 2)[0]
        return f"{kind} [{disp:#06x}]", disp, 4
    if mod == 0:
        return f"{kind} [{RM_NAMES[rm]}]", None, 2
    if mod == 1:
        disp = struct.unpack_from("<b", image, pos + 2)[0]
        return f"{kind} [{RM_NAMES[rm]}{disp:+#x}]", disp, 3
    disp = struct.unpack_from("<h", image, pos + 2)[0]
    return f"{kind} [{RM_NAMES[rm]}{disp:+#x}]", disp, 4


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default="assets/extracted/F29Retal/Retal/X.EXE")
    ap.add_argument("--context", type=int, default=5)
    ap.add_argument("--only-unshifted", action="store_true",
                    help="skip sites whose lead-in contains a shift")
    args = ap.parse_args()

    image = load(args.exe)
    md = Cs(CS_ARCH_X86, CS_MODE_16)

    for pos in range(len(image) - 4):
        if image[pos] != 0xFF:
            continue
        decoded = decode_operand(image, pos)
        if decoded is None:
            continue
        text, disp, _ = decoded

        start = max(0, pos - args.context * 4)
        window = [i for i in md.disasm(image[start:pos], start)
                  if i.address + i.size <= pos]
        lead = window[-args.context:]
        lead_text = " / ".join(f"{i.mnemonic} {i.op_str}".strip() for i in lead)

        if args.only_unshifted and any(i.mnemonic in ("shl", "sal", "shr", "add")
                                       and "1" in i.op_str for i in lead):
            continue
        # A table indexed by a byte straight from a stream: the lead-in should
        # move a byte into the index register and not scale it.
        interesting = any(i.mnemonic in LEAD_HINTS for i in lead)
        flag = " <<<" if interesting and disp is not None else ""
        print(f"0000:{pos:04X}  {text:<24}{flag}")
        if lead_text:
            print(f"          lead-in: {lead_text}")


if __name__ == "__main__":
    main()
