#!/bin/bash
# Run release/f29.tos in Hatari as a Falcon030 with DSP emulation.
#
# --memsize 14 is deliberately generous for development; the release target is
# a 4 MB machine, so memory footprint has to be checked separately.
set -e

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

. "$ROOT/tools/toolchain.sh"

f29_require HATARI F030Arcade/third_party/hatari/build-ucrt64/src/hatari \
                   F030Arcade/third_party/hatari/build/src/hatari
f29_require TOS    f030dsp3d/tools/tos402.rom \
                   F030Arcade/third_party/tos/tos402.img

PRG=${1:-release/f29.tos}
[ -f "$PRG" ] || { echo "error: $PRG not built - run tools/build-run.sh" >&2; exit 1; }

"$HATARI" --memsize 14 --tos "$TOS" --patch-tos true --mmu true \
          --frameskips 0 --monitor rgb --machine falcon --dsp emu "$PRG"
