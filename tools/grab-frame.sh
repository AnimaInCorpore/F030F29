#!/bin/bash
# Headless Hatari frame grab.
#
#   bash tools/grab-frame.sh [vbl] [out.png]
#
# Runs release/f29.tos, breaks at a VBL count, reads the displayed buffer
# address out of the Videl base registers, dumps it and converts it to PNG.
#
# Two passes, because Hatari's savebin cannot dereference a pointer: the first
# reads the address, the second dumps from it. The address is stable for a
# given build but moves whenever the BSS layout changes, so it is never
# hard-coded.
set -e

VBL=${1:-600}
OUT=${2:-build/frame.png}

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

. "$ROOT/tools/toolchain.sh"

# An MSYS2 UCRT64 Hatari will not even start without its runtime DLLs on PATH -
# it exits silently with status 0, writing no log at all. Harmless elsewhere,
# so this only fires where that directory actually exists.
[ -d /c/msys64/ucrt64/bin ] && export PATH="/c/msys64/ucrt64/bin:$PATH"

f29_require HATARI F030Arcade/third_party/hatari/build-ucrt64/src/hatari \
                   F030Arcade/third_party/hatari/build/src/hatari
f29_require TOS    f030dsp3d/tools/tos402.rom \
                   F030Arcade/third_party/tos/tos402.img

# Only used for the final PPM -> PNG step, so a miss is not fatal.
f29_optional MAGICK "/c/Program Files/ImageMagick-7.1.2-Q16-HDRI/magick" magick

# BSD userland has no timeout(1); coreutils installs it as gtimeout.
TIMEOUT=$(command -v timeout || command -v gtimeout || true)

WIDTH=320
HEIGHT=240
FRAME_BYTES=$((WIDTH * HEIGHT * 2))

mkdir -p build

run_hatari() {
    (cd release && $TIMEOUT ${TIMEOUT:+150} "$HATARI" \
        --memsize 14 --tos "$(f29_hostpath "$TOS")" \
        --patch-tos true --mmu true --frameskips 0 --monitor rgb \
        --machine falcon --dsp emu --fast-boot true --sound off \
        --cpu-exact true --compatible true \
        --confirm-quit off --disable-video on --run-vbls $((VBL + 200)) \
        --parse dbg.ini --log-file hatari.log --alert-level fatal \
        f29.tos >/dev/null 2>&1) || true
}

cat > release/dbg.ini <<EOF
logfile f29-dbg.txt
b VBL = $VBL :once :file grab.ini
EOF

# Pass 1: the VBL handler copies display_screen into the Videl base registers,
# so those three bytes are the address of the last completed frame.
cat > release/grab.ini <<'EOF'
m $ffff8201 1
m $ffff8203 1
m $ffff820d 1
quit
EOF

rm -f release/f29-dbg.txt
run_hatari

ADDR=$(sed -n 's/.*FFFF820[13D]: \([0-9a-f][0-9a-f]\).*/\1/p' release/f29-dbg.txt | tr -d '\n')

if [ ${#ADDR} -ne 6 ]; then
    echo "could not read the Videl base (got '$ADDR') - did the program start?" >&2
    tail -20 release/f29-dbg.txt 2>/dev/null >&2 || true
    exit 1
fi

echo "display buffer at \$$ADDR"

cat > release/grab.ini <<EOF
savebin frame.bin \$$ADDR \$$(printf '%x' $FRAME_BYTES)
quit
EOF

rm -f release/frame.bin
run_hatari

[ -s release/frame.bin ] || { echo "no frame dumped" >&2; exit 1; }

node tools/fb2png.js release/frame.bin build/frame.ppm $WIDTH $HEIGHT
if [ -n "$MAGICK" ]; then
    "$MAGICK" build/frame.ppm "$OUT"
    echo "wrote $OUT"
else
    echo "wrote build/frame.ppm (ImageMagick not found, no PNG conversion)"
fi
