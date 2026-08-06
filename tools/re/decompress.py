#!/usr/bin/env python3
"""Decompress RETAL resources - RLE with escape byte 0x26.

Reimplements the routine at 0xD409 in X.EXE, which runs on every resource
before the type-specific handler:

    lodsb                       ; token
    cmp  al, 0x26               ; escape?
    jne  emit_literal
    lodsb                       ; count byte
    or   al, al
    je   literal_escape         ; count 0 -> emit a literal 0x26
    js   reuse_value            ; bit 7 set -> repeat the previous value
    mov  bh, [si] / inc si      ; else read a new run value
  reuse_value:
    mov  cx, 0x7f / and cl, al
    mov  al, bh
    rep  stosb / stosb          ; 0xD429, 0xD42B
    pop  cx
    cmp  ax, 0xC38A             ; 0xD42D, only sets flags
    stosb                       ; 0xD430 - the run path falls through into this

The run length is **(count & 0x7f) + 2**, not + 1: the run path emits `cl` bytes
via `rep stosb`, one more at 0xD42B, and then falls through the `cmp` into the
literal store at 0xD430, which emits a third.  The literal path jumps straight
to 0xD430 and so emits exactly one byte.

The run value in BH persists across runs, so `26 8N` repeats whatever value was
used last.  It starts at 0, because the routine loads BX with 0x0026 to get the
escape byte into BL - the high half is initialisation by side effect.

The "emit a literal 0x26" case is a jump into the middle of a three-byte
instruction: `cmp ax, 0xC38A` at 0xD42D is `3d 8a c3`, and entering at 0xD42E
executes `8a c3` = `mov al, bl`, putting the escape byte back into AL before
falling into the literal store.
"""
import argparse
import glob
import os
import sys

ESCAPE = 0x26


def decompress(src: bytes) -> bytes:
    out = bytearray()
    value = 0                      # BH, persists across runs
    i, n = 0, len(src)
    while i < n:
        b = src[i]
        i += 1
        if b != ESCAPE:
            out.append(b)
            continue
        if i >= n:
            break                  # truncated escape at end of stream
        count = src[i]
        i += 1
        if count == 0:
            out.append(ESCAPE)
            continue
        if not count & 0x80:
            if i >= n:
                break
            value = src[i]
            i += 1
        out.extend(bytes([value]) * ((count & 0x7F) + 2))
    return bytes(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", default=None,
                    help="resource files (default: all of re/resources/*.bin)")
    ap.add_argument("--out", default="re/unpacked")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    files = args.files or sorted(glob.glob("re/resources/*.bin"))
    if not files:
        sys.exit("no resources found - run tools/re/unpack.py --extract first")

    print(f"  {'resource':<28} {'packed':>8} {'unpacked':>9} {'ratio':>6}  escapes")
    total_in = total_out = 0
    for path in files:
        src = open(path, "rb").read()
        dst = decompress(src)
        escapes = src.count(ESCAPE)
        ratio = len(dst) / len(src) if src else 0
        print(f"  {os.path.basename(path):<28} {len(src):8d} {len(dst):9d} "
              f"{ratio:6.2f}  {escapes}")
        total_in += len(src)
        total_out += len(dst)
        if args.write:
            os.makedirs(args.out, exist_ok=True)
            name = os.path.basename(path).replace(".bin", ".raw")
            with open(os.path.join(args.out, name), "wb") as fh:
                fh.write(dst)

    print()
    print(f"  {total_in} -> {total_out} bytes, overall ratio {total_out / total_in:.2f}")
    if args.write:
        print(f"  written to {args.out}/")


if __name__ == "__main__":
    main()
