#!/usr/bin/env python3
"""Build a scene file from an F29 model library and a placement list.

The engine inherited a one-object file format: header, points, normals,
polygons, one BSP tree. A flight simulator needs a *scene* - a library of
models used many times over, and a list of where the instances stand.

Layout, all big endian so the 68030 reads it without swapping:

    0   4   'F29S'
    4   2   model count
    6   2   instance count
    8   4   offset of the model directory
    12  4   offset of the instance list
    16  4   suggested camera x
    20  4   suggested camera y
    24  4   suggested camera z
    28      model data, concatenated

The camera position is the centroid of the instances, lifted off the ground.
Without it the viewer starts at the origin, and since a theatre's scenery sits
tens of thousands of units away the first render is an empty horizon.

  model directory entry, 16 bytes:
    0   4   offset of this model's data from the start of the file
    4   4   length of that data in bytes
    8   2   point count
    10  2   normal count
    12  2   polygon count
    14  2   radius, for view culling

  model data, exactly what the DSP already consumes:
    long[]  points,  three per point
    long[]  normals, three per normal
    word[]  polygons: corner count, colour * 32, normal ref,
            back link, front link, then one word per corner

  instance entry, 16 bytes:
    0   2   model index
    2   2   reserved, for per-instance orientation later
    4   4   x
    8   4   y
    12  4   z

Model coordinates stay in F29's own units rather than being rescaled. The
world is +-32768 and models run from 40 to 1300 units, so the two are already
in the same space; rescaling each model to a fixed extent - which the
single-object converter does - would make every building a different size
relative to the ground.
"""
import argparse
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
import models      # noqa: E402
import objects     # noqa: E402
import model2o3d   # noqa: E402

MAGIC = b"F29S"
HEADER_SIZE = 28
DIRECTORY_ENTRY = 16
INSTANCE_ENTRY = 16

LIBRARIES = [("re/unpacked/RETAL_01_08_t0.raw", 0),
             ("re/unpacked/RETAL_01_09_t0.raw", 0x28),
             ("re/unpacked/RETAL_01_10_t0.raw", 0),
             ("re/unpacked/RETAL_01_11_t0.raw", 0)]


def model_body(model, flip=True, line_quads=True):
    """Points, normals and polygons for one model, in DSP order."""
    verts = list(model["verts"])

    span = max(max(v[i] for v in verts) - min(v[i] for v in verts) for i in range(3))
    half_width = span * model2o3d.LINE_WIDTH_FRACTION / 2 if span else 1.0

    ordered, line_count = model2o3d.build_faces(verts, model["faces"], half_width,
                                                flip, line_quads)

    out = bytearray()
    for x, y, z in verts:
        out += struct.pack(">lll", round(x), round(y), round(z))
    for face in ordered:
        for component in face.normal:
            out += struct.pack(">L",
                               round(component * model2o3d.NORMAL_SCALE) & 0xFFFFFF)
    for index, face in enumerate(ordered):
        out += struct.pack(">HHHHH",
                           len(face.refs),
                           (face.colour & 15) * 32,
                           (len(verts) + index) * 3,
                           face.back.offset + 3 if face.back else 0,
                           face.front.offset + 3 if face.front else 0)
        for ref in face.refs:
            out += struct.pack(">H", ref * 3)

    radius = max((max(abs(c) for c in v) for v in verts), default=1)
    radius = round(max(radius, 1))
    return bytes(out), len(verts), len(ordered), radius, line_count


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--placement", default="re/unpacked/RETAL_01_12_t0.raw",
                    help="a world object placement list")
    ap.add_argument("--group", type=int, default=0,
                    help="which group of the placement list to use; group 0 is "
                         "the theatre's static scenery")
    ap.add_argument("--max-instances", type=int, default=256)
    ap.add_argument("--no-line-quads", action="store_true",
                    help="see model2o3d.py --no-line-quads")
    ap.add_argument("-o", "--out", default="release/scene.f29")
    args = ap.parse_args()

    library = []
    for path, start in LIBRARIES:
        try:
            data = open(path, "rb").read()
        except FileNotFoundError:
            sys.exit(f"{path} not found - run unpack.py and decompress.py first")
        library += models.scan(data, start)
    if not library:
        sys.exit("no models found")

    groups, _ = objects.parse(open(args.placement, "rb").read())
    if args.group >= len(groups):
        sys.exit(f"group {args.group} out of range, {len(groups)} present")
    placements = groups[args.group][:args.max_instances]

    # An object type byte can exceed the number of models we managed to parse,
    # so fold it into range rather than dropping the instance - the mapping from
    # type to library index is not established yet either way.
    bodies, directory, blob = [], bytearray(), bytearray()
    offset = HEADER_SIZE
    total_lines = 0
    for model in library:
        body, points, polys, radius, line_count = model_body(model, line_quads=not args.no_line_quads)
        bodies.append((body, points, polys, radius))
        blob += body
        total_lines += line_count

    for body, points, polys, radius in bodies:
        directory += struct.pack(">LLHHHH", offset, len(body), points, polys,
                                 polys, min(radius, 0xFFFF))
        offset += len(body)

    directory_offset = offset
    instance_offset = directory_offset + len(directory)

    instances = bytearray()
    for kind, x, y, z in placements:
        instances += struct.pack(">HHlll", kind % len(library), 0, x, y, z)

    if placements:
        cam_x = sum(p[1] for p in placements) // len(placements)
        cam_z = sum(p[3] for p in placements) // len(placements)
    else:
        cam_x = cam_z = 0

    out = bytearray()
    out += MAGIC
    out += struct.pack(">HH", len(library), len(placements))
    out += struct.pack(">LL", directory_offset, instance_offset)
    out += struct.pack(">lll", cam_x, -400, cam_z)
    out += blob + directory + instances

    open(args.out, "wb").write(out)
    print(f"{len(library)} models, {len(placements)} instances")
    print(f"  model data      {len(blob)} bytes")
    print(f"  directory       {len(directory)} bytes at {directory_offset:#x}")
    print(f"  instances       {len(instances)} bytes at {instance_offset:#x}")
    print(f"  camera start    ({cam_x}, -400, {cam_z})")
    if total_lines:
        note = "widened into quads" if not args.no_line_quads else "left degenerate"
        print(f"  {total_lines} 2-corner lines across the library, {note}")
    print(f"wrote {args.out}, {len(out)} bytes")


if __name__ == "__main__":
    main()
