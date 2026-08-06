#!/usr/bin/env python3
"""Parse the 3D models in RETAL.01 resource 9.

Layout, derived from the data and the parser at 0x431A:

    byte        vertex count minus one
    n * 6       vertices: X, Y, Z as 16-bit signed little endian
    faces       records of: marker, colour byte, then one 16-bit word per corner

The marker is not an encoded corner count.  Every marker observed is a multiple
of four and none relates arithmetically to the number of corners, so it is a
byte offset into a primitive-type dispatch table in the renderer and each
primitive has its own record layout:

    0x04   3 corners, colour in byte 1, refs from byte 2            ( 8 bytes)
    0x14   3 corners, no colour byte,   refs from byte 1,
           plus one trailing word                                   ( 9 bytes)
    0x1C   2 corners, colour in byte 1, refs from byte 2            ( 6 bytes)
    0x20   1 corner,  colour in byte 1, ref  from byte 2,
           plus one parameter word                                  ( 6 bytes)
    0x24   3 corners, colour in byte 1, refs from byte 2            ( 8 bytes)
    0x28   4 corners, colour in byte 1, refs from byte 2            (10 bytes)
    0x2C   corner count in byte 1, colour in byte 2, refs from byte 3

Each layout was checked against every occurrence: refs come out as multiples of
six inside the model's own vertex array, and the byte after the record is always
a valid marker or the 0x00 terminator.  Further markers exist - 0x0C in
particular - whose layout is not known; see docs/MODEL-FORMAT.md.

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

# Marker to record layout.  The markers are all multiples of four and bear no
# arithmetic relation to the corner count, so this is a byte offset into a
# primitive-type dispatch table in the renderer, and every type has its own
# record shape.  Each entry below was verified against every occurrence: the
# refs come out as multiples of six inside the model's own vertex array, and
# the byte after the record is a valid marker or the 0x00 terminator.
FIXED_CORNERS = {0x04: 3, 0x1C: 2, 0x24: 3, 0x28: 4}
MARKER_COUNTED = 0x2C          # corner count sits in the following byte
MARKER_POINT = 0x20            # single vertex plus a 16-bit parameter
MARKER_UNCOLOURED = 0x14       # no colour byte: three refs plus a trailing word
COORD_LIMIT = 20000            # coordinates far beyond this are not model space


def face_record(data: bytes, pos: int):
    """Return (corners, colour, first-ref offset, record size) or None."""
    if pos + 2 > len(data):
        return None
    marker = data[pos]
    if marker in FIXED_CORNERS:
        n = FIXED_CORNERS[marker]
        return n, data[pos + 1], pos + 2, 2 + 2 * n
    if marker == MARKER_COUNTED and pos + 3 <= len(data):
        n = data[pos + 1]
        return n, data[pos + 2], pos + 3, 3 + 2 * n
    if marker == MARKER_POINT:
        # colour, one vertex reference, one parameter word - six bytes.
        return 1, data[pos + 1], pos + 2, 6
    if marker == MARKER_UNCOLOURED:
        # marker, three refs, one trailing word - nine bytes, no colour byte.
        return 3, None, pos + 1, 9
    return None


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
    while p + 2 <= len(d):
        record = face_record(d, p)
        if record is None:
            break
        n, colour, rbase, size = record
        if n > 16 or p + size > len(d):
            break
        if n == 0:                       # stream control, consumes no vertices
            p += size
            continue
        refs = struct.unpack_from(f"<{n}H", d, rbase)
        if any(r % 6 or r // 6 >= count for r in refs):
            break
        faces.append((colour, [r // 6 for r in refs]))
        p += size

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
