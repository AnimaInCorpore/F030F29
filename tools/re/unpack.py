#!/usr/bin/env python3
"""Extract the resources from RETAL.00 / RETAL.01.

The archive has no header of its own - the index lives inside X.EXE.  A word
table at 0xD3A5 holds one pointer per archive file, and each pointer leads to an
array of 4-byte entries:

    byte 0..2   file offset, 24-bit little endian
    byte 3      resource type, selects one of 7 post-processing handlers

The length of resource i is offset[i+1] - offset[i], so the array carries one
extra sentinel entry whose offset equals the file size.  That sentinel is what
bounds the table, since nothing else records the entry count.

Resource numbers as used by the game are 16-bit: the low 9 bits index the
table, the upper bits select the archive file (see loader at 0xD2F0).
"""
import argparse
import os
import struct
import sys

TABLE_OF_TABLES = 0xD3A5      # word array, one pointer per archive file
ARCHIVES = ["RETAL.00", "RETAL.01"]

# Type byte -> handler in the table at 0xD43A, see docs/RE-NOTES.md.
TYPE_NAMES = {
    0: "raw (handler 0xD524 = ret, no conversion)",
    1: "handler 0xD448",
    2: "handler 0xD456",
    3: "handler 0xD496",
    4: "handler 0xD4C7",
    5: "handler 0xD4F2",
    6: "handler 0xD525",
}


def load_exe(path: str) -> bytes:
    data = open(path, "rb").read()
    lastpage, pages = struct.unpack_from("<HH", data, 2)
    hdrsize = struct.unpack_from("<H", data, 8)[0] * 16
    imagesize = (pages - 1) * 512 + lastpage if lastpage else pages * 512
    return data[hdrsize:imagesize]


def read_index(image: bytes, table_addr: int, file_size: int) -> list[tuple[int, int]]:
    """Return [(offset, type), ...] including the trailing sentinel.

    Reads until an entry's offset reaches the archive size - that entry is the
    sentinel and terminates the table.
    """
    entries, pos = [], table_addr
    while pos + 4 <= len(image):
        lo, mid, hi, kind = image[pos:pos + 4]
        offset = lo | (mid << 8) | (hi << 16)
        entries.append((offset, kind))
        if offset >= file_size:
            return entries
        if len(entries) > 512:
            break
        pos += 4
    raise ValueError(f"no sentinel at or below {file_size} - table at {table_addr:#06x} "
                     f"is not an index for this file")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default="assets/extracted/F29Retal/Retal/X.EXE")
    ap.add_argument("--dir", default="assets/extracted/F29Retal/Retal",
                    help="directory holding RETAL.00 / RETAL.01")
    ap.add_argument("--out", default="re/resources")
    ap.add_argument("--extract", action="store_true", help="write the resources out")
    args = ap.parse_args()

    image = load_exe(args.exe)
    pointers = [struct.unpack_from("<H", image, TABLE_OF_TABLES + 2 * i)[0]
                for i in range(len(ARCHIVES))]

    total = 0
    for file_index, (name, table_addr) in enumerate(zip(ARCHIVES, pointers)):
        path = os.path.join(args.dir, name)
        blob = open(path, "rb").read()
        entries = read_index(image, table_addr, len(blob))
        count = len(entries) - 1

        print(f"{name}: {len(blob)} bytes, index at {table_addr:#06x}, "
              f"{count} resources (+1 sentinel)")
        print(f"  {'res':>4}  {'resnum':>6}  {'offset':>8}  {'length':>7}  type")
        for i in range(count):
            offset, kind = entries[i]
            length = entries[i + 1][0] - offset
            resnum = (file_index << 9) | i
            print(f"  {i:4d}  {resnum:#06x}  {offset:8d}  {length:7d}  {kind}")
            if args.extract:
                os.makedirs(args.out, exist_ok=True)
                out = os.path.join(args.out, f"{name.replace('.', '_')}_{i:02d}_t{kind}.bin")
                with open(out, "wb") as fh:
                    fh.write(blob[offset:offset + length])
            total += length
        sentinel = entries[-1][0]
        status = "ok" if sentinel == len(blob) else f"MISMATCH (file is {len(blob)})"
        print(f"  sentinel {sentinel} - {status}")
        print()

    print(f"{total} bytes across all resources")
    if args.extract:
        print(f"written to {args.out}/")
    else:
        print("re-run with --extract to write them out")


if __name__ == "__main__":
    main()
