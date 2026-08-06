#!/usr/bin/env python3
"""Dump the MZ header, relocation table and segment layout of a DOS executable.

X.EXE is a 68 KB real-mode image with only four relocations, so it cannot be
using the linker's segment fixups for anything but a handful of far pointers -
it must compute segments itself at runtime.  This tool exists to pin that down
before disassembly, because the disassembler needs to know which paragraphs are
code.
"""
import struct
import sys

MZ_FIELDS = (
    "signature lastpage pages relocs hdrparas minalloc maxalloc "
    "ss sp checksum ip cs reloctab overlay"
).split()


def parse(data: bytes) -> dict:
    if data[:2] not in (b"MZ", b"ZM"):
        raise ValueError("not an MZ executable")
    hdr = dict(zip(MZ_FIELDS, struct.unpack_from("<14H", data, 0)))
    hdr["hdrsize"] = hdr["hdrparas"] * 16
    # lastpage == 0 means the final page is full.
    hdr["imagesize"] = (
        (hdr["pages"] - 1) * 512 + hdr["lastpage"] if hdr["lastpage"] else hdr["pages"] * 512
    )
    hdr["loadsize"] = hdr["imagesize"] - hdr["hdrsize"]
    return hdr


def relocations(data: bytes, hdr: dict) -> list[tuple[int, int, int]]:
    """Return (segment, offset, linear file offset) for each fixup."""
    out = []
    pos = hdr["reloctab"]
    for _ in range(hdr["relocs"]):
        off, seg = struct.unpack_from("<HH", data, pos)
        out.append((seg, off, hdr["hdrsize"] + (seg << 4) + off))
        pos += 4
    return out


def main(path: str) -> None:
    data = open(path, "rb").read()
    hdr = parse(data)

    print(f"{path}: {len(data)} bytes on disk")
    print()
    print("MZ header")
    print(f"  header size    {hdr['hdrsize']} bytes ({hdr['hdrparas']} paragraphs)")
    print(f"  image size     {hdr['imagesize']} bytes  ({hdr['pages']} pages, last {hdr['lastpage']})")
    print(f"  load module    {hdr['loadsize']} bytes  -> {hdr['loadsize'] / 65536:.2f} segments")
    print(f"  entry CS:IP    {hdr['cs']:04X}:{hdr['ip']:04X}  (file offset {hdr['hdrsize'] + (hdr['cs'] << 4) + hdr['ip']:#07x})")
    print(f"  stack SS:SP    {hdr['ss']:04X}:{hdr['sp']:04X}")
    print(f"  minalloc       {hdr['minalloc']} paragraphs ({hdr['minalloc'] * 16} bytes)")
    print(f"  maxalloc       {hdr['maxalloc']} paragraphs")
    if len(data) > hdr["imagesize"]:
        print(f"  OVERLAY DATA   {len(data) - hdr['imagesize']} bytes past the image")
    print()

    relocs = relocations(data, hdr)
    print(f"relocations ({len(relocs)})")
    for seg, off, lin in relocs:
        target = struct.unpack_from("<H", data, lin)[0]
        print(f"  {seg:04X}:{off:04X}  file {lin:#07x}  patches segment word {target:04X}")
    print()

    # SS:SP tells us where the program expects its stack, which bounds the
    # image: everything below SS<<4 is code/data the loader brought in.
    stack_top = (hdr["ss"] << 4) + hdr["sp"]
    print("derived layout")
    print(f"  load module spans linear 00000..{hdr['loadsize'] - 1:05X}")
    print(f"  stack base SS<<4 = {hdr['ss'] << 4:#07x} ({hdr['ss'] << 4})")
    print(f"  stack top  SS:SP = {stack_top:#07x} ({stack_top})")
    if (hdr["ss"] << 4) < hdr["loadsize"]:
        print(f"  -> stack sits INSIDE the load module, overlapping {hdr['loadsize'] - (hdr['ss'] << 4)} bytes")
    else:
        print(f"  -> stack sits {(hdr['ss'] << 4) - hdr['loadsize']} bytes above the load module")
    print(f"  total runtime need {stack_top + hdr['minalloc'] * 16:#07x} bytes")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/extracted/F29Retal/Retal/X.EXE")
