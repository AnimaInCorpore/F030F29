#!/bin/bash
# Run release/f29.tos in Hatari as a Falcon030 with DSP emulation.
#
# --memsize 14 is deliberately generous for development; the release target is
# a 4 MB machine, so memory footprint has to be checked separately.
set -e

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

HATARI=${HATARI:-/c/Arbeit/F030Arcade/third_party/hatari/build-ucrt64/src/hatari.exe}
TOS=${TOS:-/c/Arbeit/f030dsp3d/tools/tos402.rom}

[ -x "$HATARI" ] || { echo "error: hatari not found at $HATARI" >&2; exit 1; }
[ -f "$TOS" ]    || { echo "error: TOS rom not found at $TOS" >&2; exit 1; }

PRG=${1:-release/f29.tos}
[ -f "$PRG" ] || { echo "error: $PRG not built - run tools/build-run.sh" >&2; exit 1; }

"$HATARI" --memsize 14 --tos "$TOS" --patch-tos true --mmu true \
          --frameskips 0 --monitor rgb --machine falcon --dsp emu "$PRG"
