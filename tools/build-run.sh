#!/bin/bash
# Assemble and link the 68030 side into release/f29.tos.
#
# vasm/vlink are the prebuilt Win32 binaries from the sibling F030Arcade
# checkout - same arrangement as f030dsp3d/tools/build-run.sh.  Override with
# VASM=... / VLINK=... if they move.
set -e

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

VASM=${VASM:-/c/Arbeit/F030Arcade/third_party/vasm/vasmm68k_mot.exe}
VLINK=${VLINK:-/c/Arbeit/F030Arcade/third_party/vlink/vlink.exe}

[ -x "$VASM" ]  || { echo "error: vasm not found at $VASM" >&2; exit 1; }
[ -x "$VLINK" ] || { echo "error: vlink not found at $VLINK" >&2; exit 1; }

mkdir -p build release

# start.s must come first - vlink places the first object at the TEXT base and
# the entry point has to sit there for -tos-fastload to be worth anything.
SOURCES="start"
for f in src/*.s; do
    name=$(basename "$f" .s)
    [ "$name" = start ] && continue
    SOURCES="$SOURCES $name"
done

OBJECTS=""
for name in $SOURCES; do
    [ -f "src/$name.s" ] || { echo "error: src/$name.s missing" >&2; exit 1; }
    "$VASM" "src/$name.s" -quiet -Felf -m68030 -o "build/$name.o" -L "build/$name.lst"
    OBJECTS="$OBJECTS build/$name.o"
done

"$VLINK" $OBJECTS -tos-fastload -b ataritos -e start -o release/f29_d.tos
"$VLINK" $OBJECTS -tos-fastload -b ataritos -s -e start -o release/f29.tos

echo "built release/f29.tos ($(wc -c < release/f29.tos) bytes), release/f29_d.tos"
