#!/usr/bin/env python3
"""Render a decompressed type-1 resource to PNG.

The plane layout comes straight from the type-1 handler at 0xD45E, which reads
four consecutive bytes and shifts them into pixels:

    lodsw / xchg bx,ax          ; bl = byte0, bh = byte1
    lodsw / mov dl,al           ; dl = byte2, ah = byte3
    rol ax,1                    ; byte3 MSB -> pixel bit
    shl dl,1 / rcl al,1         ; byte2 MSB
    shl bh,1 / rcl al,1         ; byte1 MSB
    shl bl,1 / rcl al,1         ; byte0 MSB

So four consecutive bytes hold the four bitplanes of the same eight pixels -
byte-interleaved planar, the same arrangement the Atari ST uses - and the pixel
value is byte3<<3 | byte2<<2 | byte1<<1 | byte0, MSB-first within each byte.

Writes PNG directly via zlib so there is no imaging dependency.
"""
import argparse
import struct
import sys
import zlib

# Standard 16-colour EGA palette.  The game ships its own palette somewhere -
# this is only meant to make the image legible enough to identify.
EGA = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0xAA), (0x00, 0xAA, 0x00), (0x00, 0xAA, 0xAA),
    (0xAA, 0x00, 0x00), (0xAA, 0x00, 0xAA), (0xAA, 0x55, 0x00), (0xAA, 0xAA, 0xAA),
    (0x55, 0x55, 0x55), (0x55, 0x55, 0xFF), (0x55, 0xFF, 0x55), (0x55, 0xFF, 0xFF),
    (0xFF, 0x55, 0x55), (0xFF, 0x55, 0xFF), (0xFF, 0xFF, 0x55), (0xFF, 0xFF, 0xFF),
]


def planar_to_indices(data: bytes, width: int) -> list[list[int]]:
    """Decode byte-interleaved 4-plane data into rows of palette indices."""
    stride = width // 2          # 4 bits per pixel, so half a byte each
    rows = []
    pos = 0
    while pos + stride <= len(data):
        row = []
        for group in range(0, stride, 4):
            b0, b1, b2, b3 = data[pos + group:pos + group + 4]
            for bit in range(7, -1, -1):
                m = 1 << bit
                row.append((bool(b0 & m) << 0) | (bool(b1 & m) << 1)
                           | (bool(b2 & m) << 2) | (bool(b3 & m) << 3))
        rows.append(row[:width])
        pos += stride
    return rows


def chunky_to_indices(data: bytes, width: int) -> list[list[int]]:
    """Decode packed 4-bits-per-pixel data, high nibble first.

    This is the layout the type-3 handler at 0xD496 consumes: it reads one word
    and emits one word, interleaving nibbles into bitplanes, so what sits in the
    file is two pixels per byte rather than separate planes.
    """
    stride = width // 2
    rows = []
    for pos in range(0, len(data) - stride + 1, stride):
        row = []
        for b in data[pos:pos + stride]:
            row.append(b >> 4)
            row.append(b & 0x0F)
        rows.append(row[:width])
    return rows


def write_png(path: str, rows: list[list[int]], palette: list[tuple]) -> None:
    height, width = len(rows), len(rows[0]) if rows else 0
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0))
    png += chunk(b"PLTE", b"".join(bytes(c) for c in palette))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("-w", "--width", type=int, default=320)
    ap.add_argument("--chunky", action="store_true",
                    help="packed 4bpp instead of 4-plane interleaved")
    args = ap.parse_args()

    data = open(args.input, "rb").read()
    decode = chunky_to_indices if args.chunky else planar_to_indices
    rows = decode(data, args.width)
    if not rows:
        sys.exit(f"{args.input}: too small for width {args.width}")

    out = args.out or args.input.rsplit(".", 1)[0] + ".png"
    write_png(out, rows, EGA)
    print(f"{args.input}: {len(data)} bytes -> {args.width}x{len(rows)}  {out}")


if __name__ == "__main__":
    main()
