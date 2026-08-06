#!/usr/bin/env python3
"""Parse the 3D models in RETAL.01 resource 9.

Layout, derived from the data and the parser at 0x431A:

    byte        vertex count minus one
    n * 6       vertices: X, Y, Z as 16-bit signed little endian
    faces       records of: marker, colour byte, then one 16-bit word per corner

The marker encodes the corner count in steps of four: 0x24 is a triangle, 0x28
a quad, 0x2C a pentagon, so corners = (marker >> 2) - 6.  A face record is
therefore 2 + 2*corners bytes long.

The words in a face record are **byte offsets** into the vertex array, not
indices - vertex k sits at offset 6*k.  Verified two ways: the quad
`28 10 30 00 36 00 3c 00 42 00` references offsets 48, 54, 60, 66, which are
vertices 8..11, the four corners of the (+-100, 130, +-100) square; and
`24 16 00 00 1e 00 12 00` is followed immediately by another record starting
`28 05`, which only works if the 0x24 record carries exactly three words.
"""
import argparse
import struct
import sys

MARKER_MIN, MARKER_MAX = 0x1C, 0x3C
COORD_LIMIT = 20000        # coordinates far beyond this are not model space


def corners(marker: int) -> int:
    return (marker >> 2) - 6


def is_marker(b: int) -> bool:
    return MARKER_MIN <= b <= MARKER_MAX and b % 4 == 0


def parse_model(d: bytes, pos: int):
    """Parse one model at pos, or return None if it does not look like one."""
    if pos >= len(d):
        return None
    count = d[pos] + 1
    vbase = pos + 1
    if count < 3 or vbase + count * 6 > len(d):
        return None

    verts = []
    for k in range(count):
        x, y, z = struct.unpack_from("<hhh", d, vbase + k * 6)
        if max(abs(x), abs(y), abs(z)) > COORD_LIMIT:
            return None
        verts.append((x, y, z))

    faces, p = [], vbase + count * 6
    while p + 2 <= len(d) and is_marker(d[p]):
        n = corners(d[p])
        if n < 2 or p + 2 + 2 * n > len(d):
            break
        colour = d[p + 1]
        refs = struct.unpack_from(f"<{n}H", d, p + 2)
        if any(r % 6 or r // 6 >= count for r in refs):
            break
        faces.append((colour, [r // 6 for r in refs]))
        p += 2 + 2 * n

    if not faces:
        return None
    return {"start": pos, "end": p, "verts": verts, "faces": faces,
            "next_marker": d[p] if p < len(d) else None}


def scan(d: bytes, start: int, limit: int | None = None):
    """Walk models from start, stopping when parsing no longer succeeds."""
    models, pos = [], start
    while pos < len(d):
        m = parse_model(d, pos)
        if m is None:
            pos += 1
            if limit and len(models) >= limit:
                break
            if pos > start + 4096 and not models:
                break
            continue
        models.append(m)
        pos = m["end"]
        if limit and len(models) >= limit:
            break
    return models


def write_obj(path: str, model: dict) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"# F29 model from resource 9, offset {model['start']:#06x}\n")
        for x, y, z in model["verts"]:
            fh.write(f"v {x} {y} {z}\n")
        for colour, refs in model["faces"]:
            fh.write(f"# colour {colour}\n")
            fh.write("f " + " ".join(str(i + 1) for i in refs) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="re/unpacked/RETAL_01_09_t0.raw")
    ap.add_argument("--start", default="0x28", help="offset of the first model")
    ap.add_argument("--obj", help="write the first model to this .obj file")
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()

    d = open(args.input, "rb").read()
    models = scan(d, int(args.start, 0), args.limit)
    if not models:
        sys.exit(f"no models found from {args.start}")

    total_v = sum(len(m["verts"]) for m in models)
    total_f = sum(len(m["faces"]) for m in models)
    print(f"{args.input}: {len(d)} bytes")
    print(f"{len(models)} models, {total_v} vertices, {total_f} faces")
    print(f"covered {models[-1]['end'] - models[0]['start']} bytes "
          f"({models[0]['start']:#06x}..{models[-1]['end']:#06x})")
    print()
    print(f"  {'offset':>7} {'verts':>6} {'faces':>6}  extent (x, y, z)")
    for m in models[:25]:
        xs = [v[0] for v in m["verts"]]
        ys = [v[1] for v in m["verts"]]
        zs = [v[2] for v in m["verts"]]
        print(f"  {m['start']:#07x} {len(m['verts']):6d} {len(m['faces']):6d}"
              f"  {max(xs) - min(xs):5d} {max(ys) - min(ys):5d} {max(zs) - min(zs):5d}")
    if len(models) > 25:
        print(f"  ... +{len(models) - 25} more")

    if args.obj:
        write_obj(args.obj, models[0])
        print(f"\nwrote {args.obj}")


if __name__ == "__main__":
    main()
