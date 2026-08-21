#!/bin/bash
# Assemble src/dsp/3d.asm into release/3d.lod.
#
# ASM56000 is a DOS4GW program, so it runs under DOSBox and needs 8.3 names.
# Recipe taken from f030dsp3d/tools/build-dsp.sh.  DOSBox Staging installs
# outside PATH on Windows, hence the explicit default; override with DOSBOX=...
set -e

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

. "$ROOT/tools/toolchain.sh"

DOSBOX=${DOSBOX:-$(command -v dosbox-staging || command -v dosbox || true)}
if [ -z "$DOSBOX" ]; then
    DOSBOX="/c/Users/$USERNAME/AppData/Local/Programs/DOSBox Staging/dosbox.exe"
fi
[ -x "$DOSBOX" ] || { echo "error: no dosbox found (set DOSBOX=...)" >&2; exit 1; }

f29_require ASM56K f030dsp3d/tools/asm56k F030Arcade/third_party/asm56k
[ -d "$ASM56K" ] || { echo "error: asm56k is not a directory: $ASM56K" >&2; exit 1; }

BUILD="$ROOT/build/dsp"
rm -rf "$BUILD"
mkdir -p "$BUILD" release

cp src/dsp/3d.asm "$BUILD/3D.ASM"
cp src/dsp/*.inc "$BUILD/" 2>/dev/null || true
cp "$ASM56K/ASM56000.EXE" "$ASM56K/CLDLOD.EXE" "$ASM56K/DOS4GW.EXE" "$BUILD/"

cat > "$BUILD/BUILD.BAT" <<'EOF'
@ECHO OFF
ASM56000.EXE -q -a -b3D.CLD -z -l3D.LST 3D.ASM
IF ERRORLEVEL 1 EXIT 1
CLDLOD.EXE 3D.CLD > 3D.LOD
EXIT
EOF

"$DOSBOX" --noprimaryconf --set output=texture "$BUILD/BUILD.BAT" >/dev/null 2>&1 || true

if [ ! -s "$BUILD/3D.LOD" ]; then
    echo "error: no 3D.LOD produced - assembler errors follow" >&2
    sed -n '/^ *[0-9]* *[0-9]* *E /p;/error/Ip' "$BUILD/3D.LST" 2>/dev/null | head -30 >&2
    exit 1
fi

# ASM56000 still emits a .cld after errors, so trust its summary line rather
# than grepping for "error" - ioequ.inc is full of "Parity Error" comments.
ERRORS=$(sed -n 's/^\([0-9][0-9]*\)[[:space:]][[:space:]]*Errors[[:space:]]*$/\1/p' "$BUILD/3D.LST" | tail -1)
if [ "${ERRORS:-1}" != "0" ]; then
    echo "assembler reported ${ERRORS:-?} error(s):" >&2
    grep -nE "^[[:space:]]*[0-9]+[[:space:]]+.*\*\*\*|ERROR:" "$BUILD/3D.LST" | head -30 >&2
    exit 1
fi

cp "$BUILD/3D.LOD" release/3d.lod
echo "wrote release/3d.lod ($(wc -c < release/3d.lod) bytes)"
