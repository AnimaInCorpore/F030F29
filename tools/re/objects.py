#!/usr/bin/env python3
"""Parse the world object placement lists in RETAL.01 resources 12-15.

Record layout, matching the walker at 0x438D in X.EXE which steps `add si, 7`
and tests for 0xFF:

    byte        object type - selects a model from the model libraries
    word        X, signed 16-bit little endian
    word        Y, signed 16-bit little endian - altitude
    word        Z, signed 16-bit little endian

A 0xFF byte where a type would be ends the current group; groups are what
0x438D selects between using [0xF3A2] and [0xE993].

The alignment is not guessed.  If the record stride were wrong the Y column
would be uniformly distributed over the full 16-bit range; instead it collapses
onto a handful of small values - in resource 12, 272 of 530 records have Y
exactly 0 and another 106 have -50.  X and Z do span the full range, which is
what world coordinates on a wrapping map look like.
"""
import argparse
import collections
import struct
import sys

RESOURCES = ["12", "13", "14", "15"]
TERMINATOR = 0xFF


def parse(data: bytes):
    """Return a list of groups, each a list of (type, x, y, z)."""
    groups, current, pos = [], [], 0
    while pos + 7 <= len(data):
        if data[pos] == TERMINATOR:
            groups.append(current)
            current = []
            pos += 1
            continue
        kind = data[pos]
        x, y, z = struct.unpack_from("<hhh", data, pos + 1)
        current.append((kind, x, y, z))
        pos += 7
    if current:
        groups.append(current)
    return groups, len(data) - pos


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="re/unpacked")
    ap.add_argument("--resource", help="single resource number, e.g. 12")
    ap.add_argument("--dump", type=int, default=0,
                    help="print this many records of the first group")
    args = ap.parse_args()

    wanted = [args.resource] if args.resource else RESOURCES
    for res in wanted:
        path = f"{args.dir}/RETAL_01_{res}_t0.raw"
        try:
            data = open(path, "rb").read()
        except FileNotFoundError:
            sys.exit(f"{path} not found - run unpack.py and decompress.py first")

        groups, tail = parse(data)
        records = [r for g in groups for r in g]
        kinds = collections.Counter(r[0] for r in records)
        heights = collections.Counter(r[2] for r in records)

        print(f"resource {res}: {len(data)} bytes, {len(records)} records in "
              f"{len(groups)} groups, {tail} trailing byte(s)")
        print(f"  group sizes: {[len(g) for g in groups]}")
        print(f"  {len(kinds)} object types, most common: "
              + " ".join(f"{k:02X}x{v}" for k, v in kinds.most_common(6)))
        print("  altitudes: "
              + " ".join(f"{h}({n})" for h, n in heights.most_common(5)))

        if args.dump:
            print(f"  first {args.dump} records:")
            for kind, x, y, z in records[:args.dump]:
                print(f"    type {kind:02X}  X={x:7d}  Y={y:6d}  Z={z:7d}")
        print()


if __name__ == "__main__":
    main()
