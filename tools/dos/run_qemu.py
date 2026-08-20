#!/usr/bin/env python3
r"""Headless QEMU runner for img/uw.hdd -- the project's dynamic oracle.

Observability on the Windows QEMU build is limited (no working serial sink), so
this driver uses three channels instead:

  1. **C:\QUIT.COM -> isa-debug-exit (port 0xF4)** lets the guest end the run
     itself; QEMU exits with code (AL<<1)|1 = 21.  A run that ends any other way
     hung or crashed.
  2. **VGA text plane at 0xB8000** dumped over QMP `pmemsave` and decoded to
     80x25 text -- readable even when the guest is wedged.
  3. **Files the guest wrote** (C:\BOOT.LOG ...), read back with mtools.

Usage:
  python work/run_qemu.py                    # boot, wait for QUIT.COM, dump
  python work/run_qemu.py --timeout 60
  python work/run_qemu.py --floppy img/x.img --boot a
  python work/run_qemu.py --key 20:spc --key 22:ret --shot 30 --shot 45
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

QEMU = r'C:\Program Files\Qemu\qemu-system-i386.exe'
MSYS = r'C:\msys64\mingw64\bin'


def project_root():
    """Nearest ancestor of this script that holds an `img/` directory.

    Found by walking up rather than assuming a fixed depth, so this file stays
    byte-identical across the sibling projects however they lay their scripts
    out (`work/run_qemu.py` in UW1/UW2/TIE, `tools/dos/run_qemu.py` in F29)."""
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.isdir(os.path.join(d, 'img')):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        d = parent


ROOT = project_root()
# scratch dir: whichever of these the project already uses for build output
OUTDIR = next((os.path.join(ROOT, d, 'qemu_out') for d in ('work', 'build')
               if os.path.isdir(os.path.join(ROOT, d))),
              os.path.join(ROOT, 'work', 'qemu_out'))


def default_hdd():
    """The image build_dos_hdd.py produced -- keeps this file identical across
    the sibling projects (uw.hdd / uw2.hdd / tie.hdd).

    Only images with a `.geom.json` sidecar count, so leftover hand-built disks
    sitting in img/ can never be picked up by accident (img/dos622.hdd sorted
    ahead of img/uw.hdd and silently won a plain glob)."""
    import glob
    hits = sorted(p for p in glob.glob(os.path.join(ROOT, 'img', '*.hdd'))
                  if os.path.exists(p + '.geom.json'))
    return hits[0] if hits else os.path.join(ROOT, 'img', 'dos.hdd')


HDD = default_hdd()
CLEAN_EXIT = 21                       # (0x0A << 1) | 1, see QUIT.COM


def free_port():
    """Ask the OS for an unused port instead of hardcoding one.

    The four sibling projects run the same script; a fixed QMP port meant two
    concurrent runs fought over it and one died in a way that looked like a
    guest crash."""
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def geometry(hdd):
    """Geometry must match the BPB exactly or the boot record reads the wrong
    sectors.  dosimg.py writes it next to the image; never hardcode it here."""
    side = hdd + '.geom.json'
    if not os.path.exists(side):
        sys.exit(f'missing {side} -- rebuild the image with work/build_dos_hdd.py')
    g = json.load(open(side))
    return g['cyls'], g['heads'], g['secs'], g['part_offset']


class Qmp:
    def __init__(self, port):
        self.s = None
        self.dead = False
        for _ in range(40):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=2)
                break
            except OSError:
                time.sleep(0.25)
        if self.s is None:
            raise RuntimeError('QMP never came up')
        self.f = self.s.makefile('rw')
        self.f.readline()                                   # greeting
        self._cmd({'execute': 'qmp_capabilities'})

    def _cmd(self, obj):
        # The guest can end the run at any moment (QUIT.COM -> isa-debug-exit),
        # which drops the QMP socket mid-command.  That is a normal outcome, not
        # an error: report it instead of dying with ConnectionResetError.
        try:
            self.f.write(json.dumps(obj) + '\n')
            self.f.flush()
            while True:
                line = self.f.readline()
                if not line:
                    self.dead = True
                    return None
                m = json.loads(line)
                if 'event' in m:
                    continue
                return m
        except OSError:
            self.dead = True
            return None

    def hmp(self, cmd):
        if self.dead:
            return '<qmp closed>'
        m = self._cmd({'execute': 'human-monitor-command',
                       'arguments': {'command-line': cmd}})
        return (m or {}).get('return', '')

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def dump_text_screen(qmp, tag):
    """Decode the VGA colour-text plane (0xB8000, 80x25, char/attr pairs)."""
    path = os.path.join(OUTDIR, f'vga_{tag}.bin')
    qmp.hmp(f'pmemsave 0xB8000 4000 "{path.replace(chr(92), "/")}"')
    for _ in range(20):
        if os.path.exists(path) and os.path.getsize(path) == 4000:
            break
        time.sleep(0.1)
    if not os.path.exists(path):
        return '<no VGA dump>'
    d = open(path, 'rb').read()
    cp437 = lambda b: bytes([b]).decode('cp437') if b else ' '
    rows = [''.join(cp437(d[(r * 80 + c) * 2]) for c in range(80)).rstrip()
            for r in range(25)]
    return '\n'.join(rows)


def screendump(qmp, tag):
    """QMP screendump -> PPM, converted to PNG (readable in graphics modes,
    where the 0xB8000 text plane is meaningless)."""
    ppm = os.path.join(OUTDIR, f'screen_{tag}.ppm')
    png = os.path.join(OUTDIR, f'screen_{tag}.png')
    qmp.hmp(f'screendump "{ppm.replace(chr(92), "/")}"')
    for _ in range(30):
        if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
            break
        time.sleep(0.2)
    if not os.path.exists(ppm):
        return '<no screendump>'
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', ppm, png],
                   capture_output=True)
    return png if os.path.exists(png) else ppm


def mtool(prog, hdd, part_off, *args):
    """NB: mtype/mcat on a *missing* file dump the raw image and look like
    content -- always check the return code (lesson from the TIE project)."""
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    p = subprocess.run([os.path.join(MSYS, prog + '.exe'), '-i',
                        f'{hdd}@@{part_off}', *args],
                       capture_output=True, text=True, env=env)
    return p.stdout if p.returncode == 0 else f'<{prog}: {p.stderr.strip()}>'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--timeout', type=int, default=90)
    ap.add_argument('--hdd', default=HDD)
    ap.add_argument('--floppy')
    ap.add_argument('--cdrom', help='ISO (2048 B/sector) for the ATAPI drive; '
                                    'the guest still needs a CD device driver '
                                    'plus MSCDEX to get a drive letter')
    ap.add_argument('--boot', default='c')
    ap.add_argument('--mem', default='16')
    ap.add_argument('--cpu', default='486')
    ap.add_argument('--cat', action='append', default=[],
                    help=r'guest file to print after the run, e.g. ::/BOOT.LOG')
    ap.add_argument('--key', action='append', default=[], metavar='SEC:KEY',
                    help='QMP sendkey at SEC seconds, e.g. 20:spc or 25:ret. '
                         'Repeatable; needed for games that wait for input '
                         '(F29 stops on a doc-check screen).')
    ap.add_argument('--shot', action='append', default=[], type=float,
                    metavar='SEC', help='extra screenshot at SEC seconds; '
                                        'repeatable')
    ap.add_argument('--exit-port', default='0xf4',
                    help="I/O port for isa-debug-exit, or 'none' to leave the "
                         "device out (useful when ruling it out as the cause "
                         "of an unexplained exit).")
    ap.add_argument('--keep-running', action='store_true')
    args = ap.parse_args()

    # (time, kind, payload) schedule, replayed by the wait loop below
    schedule = []
    for spec in args.key:
        when, _, key = spec.partition(':')
        if not key:
            sys.exit(f'--key wants SEC:KEY, got {spec!r}')
        schedule.append((float(when), 'key', key))
    schedule += [(t, 'shot', None) for t in args.shot]
    schedule.sort()

    os.makedirs(OUTDIR, exist_ok=True)
    qmp_port = free_port()
    cyls, heads, secs, part_off = geometry(args.hdd)
    # QEMU >= 6 rejects cyls=/heads=/secs= on -drive ("Block format 'raw' does
    # not support the option 'cyls'"); CHS geometry now belongs on the device.
    drive = (f'file={args.hdd.replace(chr(92), "/")},format=raw,if=none,id=hd0,'
             f'cache=writeback')
    cmd = [QEMU, '-M', 'pc', '-cpu', args.cpu, '-m', args.mem,
           '-drive', drive,
           '-device', f'ide-hd,drive=hd0,bus=ide.0,unit=0,'
                      f'cyls={cyls},heads={heads},secs={secs}',
           '-boot', args.boot,
           '-display', 'none', '-vga', 'std', '-no-reboot',
           '-qmp', f'tcp:127.0.0.1:{qmp_port},server=on,wait=off']
    if args.exit_port != 'none':
        cmd += ['-device',
                f'isa-debug-exit,iobase={args.exit_port},iosize=0x04']
    if args.floppy:
        cmd += ['-drive', f'file={args.floppy.replace(chr(92), "/")},format=raw,'
                          f'if=floppy,index=0']
    if args.cdrom:
        cmd += ['-drive', f'file={args.cdrom.replace(chr(92), "/")},format=raw,'
                          f'if=none,id=cd0,media=cdrom,readonly=on',
                '-device', 'ide-cd,drive=cd0,bus=ide.1,unit=0']
    print('$', ' '.join(cmd), '\n')

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True)
    qmp = Qmp(qmp_port)
    t0 = time.time()
    rc = None
    pending = list(schedule)
    while time.time() - t0 < args.timeout:
        rc = proc.poll()
        if rc is not None:
            break
        now = time.time() - t0
        while pending and pending[0][0] <= now:
            _, kind, payload = pending.pop(0)
            if kind == 'key':
                qmp.hmp(f'sendkey {payload}')
                print(f'  [{now:5.1f}s] sendkey {payload}')
            else:
                print(f'  [{now:5.1f}s] screenshot:',
                      screendump(qmp, f't{int(now)}'))
        time.sleep(0.2)

    if rc is None:
        print(f'--- TIMEOUT after {args.timeout}s ---')
        print('screenshot:', screendump(qmp, 'timeout'))
        print('--- VGA text plane (garbage unless in a text mode) ---')
        print(dump_text_screen(qmp, 'timeout'))
        print(qmp.hmp('info registers'))
        if not args.keep_running:
            qmp.hmp('quit')
            time.sleep(1)
            proc.kill()
    else:
        print(f'--- QEMU exited rc={rc} '
              f'({"clean QUIT.COM" if rc == CLEAN_EXIT else "UNEXPECTED"}) '
              f'after {time.time() - t0:.1f}s ---')
    qmp.close()
    out = proc.stdout.read()
    if out.strip():
        print('--- qemu stdout ---\n' + out)

    for f in args.cat:
        print(f'\n--- guest {f} ---')
        print(mtool('mtype', args.hdd, part_off, f))
    return 0 if rc == CLEAN_EXIT else 1


if __name__ == '__main__':
    sys.exit(main())
