#!/usr/bin/env python3
"""Convert an F29 Retaliator model into the engine's .o3d format.

This is the join between the reverse engineering and the Falcon engine: it
reads a model out of the decoded libraries (see docs/MODEL-FORMAT.md) and
writes what src/f29.s loads at startup.

The .o3d layout, taken from f030dsp3d's wavefront2object.js:

    word    point count
    word    normal count
    word    polygon count
    word    rotation x, y, z
    long    position x, y, z
    long[]  points,  three per point, scaled so the largest extent is 2000
    long[]  normals, three per normal, each component * (0x7fffff - 0xff)
    per polygon:
        word    corner count
        word    colour * 32
        word    (point count + normal index) * 3
        word    back polygon word offset + 3, or 0
        word    front polygon word offset + 3, or 0
        word[]  point index * 3

Everything is big endian - the 68030 reads it directly, no swapping at load.

The back and front words are a BSP tree, and the DSP walks it to order faces
back to front. The tree is built the same way the original converter does it:
pick the face whose plane splits the rest most evenly while straddling the
fewest, recurse on each side, then lay the faces out in tree order so the
offsets can be resolved.
"""
import argparse
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
import models  # noqa: E402

TARGET_EXTENT = 2000            # what the largest model dimension scales to
NORMAL_SCALE = 0x7FFFFF - 0xFF
STRADDLE_WEIGHT = 8             # how much a straddling face costs when scoring


def face_geometry(verts, refs):
    """Return (centre, unit normal) of a face, Newell's method for the normal."""
    n = len(refs)
    cx = sum(verts[i][0] for i in refs) / n
    cy = sum(verts[i][1] for i in refs) / n
    cz = sum(verts[i][2] for i in refs) / n

    nx = ny = nz = 0.0
    for k in range(n):
        a = verts[refs[k]]
        b = verts[refs[(k + 1) % n]]
        nx += (a[1] - b[1]) * (a[2] + b[2])
        ny += (a[2] - b[2]) * (a[0] + b[0])
        nz += (a[0] - b[0]) * (a[1] + b[1])

    length = (nx * nx + ny * ny + nz * nz) ** 0.5
    if length < 1e-9:
        return (cx, cy, cz), (0.0, 0.0, 1.0)
    return (cx, cy, cz), (nx / length, ny / length, nz / length)


class Face:
    __slots__ = ("refs", "colour", "centre", "normal", "back", "front", "offset")

    def __init__(self, refs, colour, centre, normal):
        self.refs = refs
        self.colour = colour
        self.centre = centre
        self.normal = normal
        self.back = None
        self.front = None
        self.offset = 0

    def distance(self, point):
        return sum((point[i] - self.centre[i]) * self.normal[i] for i in range(3))

    def word_size(self):
        return 5 + len(self.refs)


def straddles(face, plane, verts):
    """True if the face has vertices on both sides of the plane."""
    seen_back = seen_front = False
    for i in face.refs:
        d = plane.distance(verts[i])
        if d < -1e-6:
            seen_back = True
        elif d > 1e-6:
            seen_front = True
        if seen_back and seen_front:
            return True
    return False


def choose_split(faces, verts):
    best, best_score = faces[0], None
    for candidate in faces:
        back = front = straddling = 0
        for face in faces:
            if face is candidate:
                continue
            if candidate.distance(face.centre) < 0:
                back += 1
            else:
                front += 1
            if straddles(face, candidate, verts):
                straddling += 1
        score = straddling * STRADDLE_WEIGHT + abs(back - front)
        if best_score is None or score < best_score:
            best, best_score = candidate, score
    return best


def build_bsp(faces, verts):
    if not faces:
        return None
    split = choose_split(faces, verts)
    back = [f for f in faces if f is not split and split.distance(f.centre) < 0]
    front = [f for f in faces if f is not split and split.distance(f.centre) >= 0]
    split.back = build_bsp(back, verts)
    split.front = build_bsp(front, verts)
    return split


def tree_order(root, out):
    if root is None:
        return
    out.append(root)
    tree_order(root.back, out)
    tree_order(root.front, out)


def convert(model, distance, flip=True):
    verts = model["verts"]
    faces = []
    for colour, refs in model["faces"]:
        centre, normal = face_geometry(verts, refs)
        if flip:
            normal = (-normal[0], -normal[1], -normal[2])
        faces.append(Face(refs, colour if colour is not None else 7, centre, normal))

    if len(faces) > 1:
        ordered = []
        tree_order(build_bsp(list(faces), verts), ordered)
    else:
        ordered = faces

    offset = 0
    for face in ordered:
        face.offset = offset
        offset += face.word_size()

    span = max(max(v[i] for v in verts) - min(v[i] for v in verts) for i in range(3))
    scale = TARGET_EXTENT / span if span else 1.0

    out = bytearray()
    out += struct.pack(">HHH", len(verts), len(ordered), len(ordered))
    out += struct.pack(">HHH", 0, 1000, 0)                  # starting rotation
    out += struct.pack(">lll", 0, 0, distance)              # starting position

    for x, y, z in verts:
        out += struct.pack(">lll", round(x * scale), round(y * scale), round(z * scale))

    for face in ordered:
        for component in face.normal:
            out += struct.pack(">L", round(component * NORMAL_SCALE) & 0xFFFFFF)

    for index, face in enumerate(ordered):
        out += struct.pack(">HHHHH",
                           len(face.refs),
                           (face.colour & 15) * 32,
                           (len(verts) + index) * 3,
                           face.back.offset + 3 if face.back else 0,
                           face.front.offset + 3 if face.front else 0)
        for ref in face.refs:
            out += struct.pack(">H", ref * 3)

    return bytes(out), ordered


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="re/unpacked/RETAL_01_09_t0.raw",
                    help="a decompressed model library")
    ap.add_argument("--start", default="0x28", help="offset of the first model")
    ap.add_argument("--index", type=int, default=2, help="which model to convert")
    ap.add_argument("--distance", type=int, default=2500,
                    help="starting camera distance")
    ap.add_argument("-o", "--out", default="release/model.o3d")
    ap.add_argument("--keep-winding", action="store_true",
                    help="do not reverse the face normals. F29 winds its faces "
                         "the opposite way round from what the engine culls "
                         "against, so they are reversed by default - without "
                         "that every face is back-facing and the model is "
                         "invisible bar the odd stray polygon")
    ap.add_argument("--list", action="store_true", help="list models and stop")
    args = ap.parse_args()

    data = open(args.input, "rb").read()
    found = models.scan(data, int(args.start, 0))
    if not found:
        sys.exit(f"no models found in {args.input}")

    if args.list:
        for i, m in enumerate(found):
            print(f"  {i:3d}  {m['start']:#07x}  {len(m['verts']):4d} vertices  "
                  f"{len(m['faces']):4d} faces")
        return

    if not 0 <= args.index < len(found):
        sys.exit(f"index {args.index} out of range, {len(found)} models available")

    model = found[args.index]
    blob, ordered = convert(model, args.distance, not args.keep_winding)
    open(args.out, "wb").write(blob)

    corners = {}
    for face in ordered:
        corners[len(face.refs)] = corners.get(len(face.refs), 0) + 1
    print(f"model {args.index} at {model['start']:#07x}: "
          f"{len(model['verts'])} vertices, {len(ordered)} faces "
          f"({', '.join(f'{n}x{c}' for n, c in sorted(corners.items()))})")
    print(f"wrote {args.out}, {len(blob)} bytes")


if __name__ == "__main__":
    main()
