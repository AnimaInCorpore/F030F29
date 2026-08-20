#!/usr/bin/env python3
r"""Build img/f29.hdd -- bootable MS-DOS 6.22 disk running the original F29.

    python tools/dos/build_dos_hdd.py            # build + in-guest EXPAND bootstrap
    python tools/dos/build_dos_hdd.py --no-boot  # build only

This is the *oracle for the original game*, not part of the Falcon port: it lets
the DOS original be run headless and screenshotted, so port output can be
compared against the real thing frame by frame.  See docs/DOS-ORACLE.md.

Two hard requirements come from the game itself:

  * **It must live in `C:\RETAL`.**  READ1ST.INC says "This game MUST be
    installed in a subdirectory named Retal off of the root directory", and
    X.EXE carries the literal strings `\RETAL` and `\RETAL\RETAL.LOG`.
  * **That directory must be writable** -- RETAL.LOG is rewritten in place.

X.EXE is a plain 16-bit MZ real-mode binary (e_minalloc 0x1000, e_maxalloc
0xFFFF: it asks for every free paragraph) with no EMS/XMS strings at all, so the
runtime config loads *no* memory manager beyond HIMEM+DOS=HIGH, which buys back
conventional memory without putting EMM386 in the way.  Layout and boot-record
rules live in tools/dos/dosimg.py.

The game files are not in this repository -- point GAME at your own copy
(default: assets/extracted/F29Retal/Retal, where tools/re/unpack.py expects it).
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dosimg

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FLOPPIES = os.path.join(ROOT, 'img', 'Microsoft MS-DOS 6.22 Plus Enhanced Tools (3.5)')
WORK = os.path.join(ROOT, 'build', 'img_build')
GAME = os.environ.get('F29_GAME',
                      os.path.join(ROOT, 'assets', 'extracted', 'F29Retal', 'Retal'))
OUT = os.path.join(ROOT, 'img', 'f29.hdd')

if not os.path.isdir(GAME):
    sys.exit(f'no game data at {GAME}\n'
             'This repository ships none -- set F29_GAME to your own copy.')

dosimg._verify_mbr(os.path.join(HERE, 'mbr.asm'), os.path.join(WORK, 'mbr.bin'))

img = dosimg.DosImage(OUT, size_mb=16, floppy_dir=FLOPPIES, work_dir=WORK,
                      label='F29_DOS')
print(f'game files: {img.add_tree("/RETAL", GAME)}')
img.add_bytes(b'FILES=20\r\nBUFFERS=15\r\n', '/CONFIG.SYS')
img.add_bytes(dosimg.expand_autoexec(), '/AUTOEXEC.BAT')
img.write()

if '--no-boot' not in sys.argv:
    print('\n--- bootstrap boot (in-guest EXPAND) ---')
    rc = subprocess.call([sys.executable, os.path.join(HERE, 'run_qemu.py'),
                          '--timeout', '120', '--cat', '::/BOOT.LOG'])
    if rc != 0:
        sys.exit('bootstrap boot failed -- see output above')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'set_boot_mode.py'),
                           'f29'])
