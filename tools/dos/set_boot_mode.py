#!/usr/bin/env python3
r"""Rewrite CONFIG.SYS / AUTOEXEC.BAT inside img/f29.hdd without rebuilding it.

Swapping the two boot files in place with mtools takes well under a second, so
iterate with this rather than re-running build_dos_hdd.py.

Modes:
  bootstrap  no memory manager; expand HIMEM/EMM386/... from the KWAJ `.??_`
             archives with the genuine EXPAND.EXE, then QUIT.COM.
  dos        HIMEM + DOS=HIGH only; report MEM /C and DIR C:\RETAL; QUIT.
             No EMM386: X.EXE has no EMS/XMS strings and asks for every free
             paragraph (e_maxalloc 0xFFFF), so a memory manager only costs it
             conventional RAM.
  f29        `dos` + run C:\RETAL\X.EXE.  Does NOT quit -- the game owns the
             screen and stops on a doc-check prompt; drive it with
             run_qemu.py --key/--shot.
  bare       no CONFIG.SYS drivers at all (closest to a 1990 machine), then X.EXE.
  shell      `dos`, then a C:\RETAL> prompt for interactive use with a display.

Usage: python tools/dos/set_boot_mode.py <mode>
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dosimg

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MSYS = r'C:\msys64\mingw64\bin'
HDD = os.path.join(ROOT, 'img', 'f29.hdd')
STAGE = os.path.join(ROOT, 'build', 'img_build')
PART_OFF = json.load(open(HDD + '.geom.json'))['part_offset']

HIMEM = (b'DEVICE=C:\\DOS\\HIMEM.SYS\r\n'
         b'DOS=HIGH\r\n'
         b'FILES=20\r\n'
         b'BUFFERS=15\r\n')
PLAIN = b'FILES=20\r\nBUFFERS=15\r\n'

HEAD = b'@ECHO OFF\r\nPROMPT $P$G\r\nPATH C:\\DOS\r\n'

# The game hardcodes \RETAL and rewrites \RETAL\RETAL.LOG, so always CD there.
RUN_GAME = (b'C:\r\nCD \\RETAL\r\n'
            b'ECHO --- launching X.EXE --- >> C:\\BOOT.LOG\r\n'
            b'X.EXE\r\n'
            b'ECHO --- X.EXE returned --- >> C:\\BOOT.LOG\r\n'
            b'CD \\\r\nC:\\QUIT.COM\r\n')

MODES = {
    'bootstrap': (PLAIN, dosimg.expand_autoexec()),
    'dos': (
        HIMEM,
        HEAD +
        b'ECHO === dos === > C:\\BOOT.LOG\r\n'
        b'VER >> C:\\BOOT.LOG\r\n'
        b'C:\\DOS\\MEM.EXE /C >> C:\\BOOT.LOG\r\n'
        b'DIR C:\\RETAL >> C:\\BOOT.LOG\r\n'
        b'ECHO === dos done === >> C:\\BOOT.LOG\r\n'
        b'C:\\QUIT.COM\r\n'),
    'f29': (HIMEM, HEAD + b'ECHO === f29 === > C:\\BOOT.LOG\r\n'
                          b'C:\\DOS\\MEM.EXE /C >> C:\\BOOT.LOG\r\n' + RUN_GAME),
    'bare': (PLAIN, HEAD + b'ECHO === bare === > C:\\BOOT.LOG\r\n' + RUN_GAME),
    'shell': (HIMEM, HEAD + b'C:\r\nCD \\RETAL\r\n'),
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        sys.exit(f'usage: set_boot_mode.py {{{"|".join(MODES)}}}')
    config, autoexec = MODES[sys.argv[1]]
    for name, data in (('CONFIG.SYS', config), ('AUTOEXEC.BAT', autoexec)):
        p = os.path.join(STAGE, name)
        open(p, 'wb').write(data)
        r = subprocess.run([os.path.join(MSYS, 'mcopy.exe'), '-o', '-i',
                            f'{HDD}@@{PART_OFF}', p, '::/' + name],
                           capture_output=True, text=True,
                           env=dict(os.environ, MTOOLS_SKIP_CHECK='1'))
        if r.returncode != 0:
            sys.exit(f'mcopy failed: {r.stdout}{r.stderr}')
    print(f'img/f29.hdd set to mode "{sys.argv[1]}"')


if __name__ == '__main__':
    main()
