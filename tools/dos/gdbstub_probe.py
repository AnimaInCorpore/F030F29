#!/usr/bin/env python3
r"""Runtime probe for the project's DOS oracle image, over QMP/HMP.

**Master copy in F030Method/dos/; synced verbatim into every family project
that carries the harness** (`python dos/sync.py`) -- like `dosimg.py`,
`run_qemu.py` and `mbr.asm`.  Nothing here is game-specific: the image, the
game binary, the Ghidra address skew and the RAM signatures are all
discovered from the project layout and the MZ header.  Fix bugs in the
master, then `sync.py --push`.

Boots the image in its current mode (for UW1: `uw`), waits for the game to
reach a steady state, then reads off what the static disassembly cannot:

  * **the file->linear mapping** -- two distinctive 16-byte windows of the game
    binary are hunted for in guest RAM.  Both must come back at the *same*
    delta; that delta calibrates everything else, and gives the load segment.
  * **what is actually resident** -- the whole file is then checked against RAM,
    16 B every 4 KB.  A 16-byte signature match proves 16 bytes and nothing
    more: this check is what revealed that UW1's "self-loaded 141 KB tail" is a
    Borland `FBOV` overlay pool that is *not* resident (uwexe.md §13.3).
  * **where the code spends its time** -- an EIP histogram, symbolicated
    against `ghidra_export/functions.txt`.  Beware: the hottest address is
    usually a timer ISR, and any address inside an overlay pool "resolves" to
    some pool function because they tile it.  `--chase` matches the bytes at
    CS:IP back into the file instead, which does prove something.
  * a screenshot per step, so a histogram can be attributed to a known state.

The CPU is never stopped: the register snapshots are racy but the game spins
in tight loops, so repeated samples are representative.  (QEMU's raw gdbstub
was tried first but proved flaky on this build: with `wait=off` it accepts the
connection yet drops commands intermittently.  Hence QMP.)

Usage:
  python work/gdbstub_probe.py                       # 55 s wait, one round
  python work/gdbstub_probe.py --wait 90 --samples 60
  python work/gdbstub_probe.py --key esc --key esc   # drive the game, sample again
  python work/gdbstub_probe.py --chase 120           # identify overlay code
"""
import argparse
import atexit
import collections
import json
import os
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dosimg

QEMU = dosimg.host_tool('qemu-system-i386')


def free_port():
    """Ask the OS for an unused QMP port instead of hardcoding one.

    Same rule as run_qemu.py: the sibling projects run this same script, and a
    fixed port meant two concurrent runs fought over it and one died in a way
    that looked like a guest crash."""
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def stale(*paths):
    """Delete previous runs' artefacts before asking QEMU for new ones.

    OUTDIR persists between runs and the tags repeat (`round1`, `key1_esc`),
    so a capture that never arrives would otherwise be answered by the *last*
    run's file -- silently, and looking exactly like a successful capture.
    """
    for p in paths:
        try:
            os.remove(p)
        except OSError:
            pass


def project_root():
    """Nearest ancestor of this script holding an `img/` directory -- so this
    file stays byte-identical across the sibling projects however they lay
    their scripts out (`work/` in UW1/UW2/TIE, `tools/dos/` in F29)."""
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.isdir(os.path.join(d, 'img')):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        d = parent


ROOT = project_root()
OUTDIR = next((os.path.join(ROOT, d, 'qemu_out') for d in ('work', 'build')
               if os.path.isdir(os.path.join(ROOT, d))),
              os.path.join(ROOT, 'work', 'qemu_out'))


def default_hdd():
    """The image build_dos_hdd.py produced.  Only images with a `.geom.json`
    sidecar count, so a leftover hand-built disk in img/ cannot be picked up by
    accident (this is how UW1's dead dos622.hdd once won a plain glob)."""
    img = os.path.join(ROOT, 'img')
    try:
        entries = os.listdir(img)
    except OSError:
        return None            # no img/ yet -- main() reports what to build
    cands = sorted(f for f in entries
                   if f.endswith('.hdd')
                   and os.path.exists(os.path.join(img, f + '.geom.json')))
    return os.path.join(img, cands[0]) if cands else None


def default_exe():
    """The game binary the image was built from: the largest MZ .EXE under the
    project's expanded/extracted game tree."""
    best = None
    for sub in ('work/expanded', 'work/extracted', 'game', 'assets/extracted'):
        for dirpath, _dirs, files in os.walk(os.path.join(ROOT, *sub.split('/'))):
            for n in files:
                if not n.lower().endswith('.exe'):
                    continue
                p = os.path.join(dirpath, n)
                try:
                    with open(p, 'rb') as f:
                        if f.read(2) != b'MZ':
                            continue
                    sz = os.path.getsize(p)
                except OSError:
                    continue
                if best is None or sz > best[0]:
                    best = (sz, p)
        if best:
            return best[1]
    return best[1] if best else None


def ghidra_skew(exe):
    """Ghidra address -> file offset for the DOS-loaded image.

        file = ((seg - 0x1000) << 4) + off + e_cparhdr*16
        i.e. ghidra_linear = file + (0x10000 - e_cparhdr*16)

    The MZ *header* is not mapped, so the tempting `ghidra_linear = 0x10000 +
    file` is wrong by exactly e_cparhdr*16 (UW1: 0x3200) -- and being wrong that
    way silently mis-names every single sample with a well-formed function name.
    Derive it from the header rather than hardcoding it per game."""
    e_cparhdr = int.from_bytes(exe[0x08:0x0A], 'little')
    return 0x10000 - e_cparhdr * 16


def find_overlay_pool(exe):
    """Borland overlaid programs end in an `FBOV` pool: 4-byte magic, then
    ovrsize/exeinfo/segnum, with `ovrsize == pool size - 16`.  Returns the pool's
    file offset, or None.  Both UW1 and UW2 have one; it is *not* a self-loaded
    contiguous tail, and its runtime address differs per overlay load."""
    i = exe.find(b'FBOV')
    if i < 0:
        return None
    ovrsize = int.from_bytes(exe[i + 4:i + 8], 'little')
    if ovrsize != len(exe) - i - 16:
        print(f'warning: FBOV at {i:#x} but ovrsize {ovrsize:#x} != '
              f'{len(exe) - i - 16:#x}; treating it as the pool start anyway')
    return i


def relocated_bytes(exe):
    """File offsets of every byte the DOS loader patches, from the MZ
    relocation table.  A signature window covering one of these can never match
    RAM: the loader adds the load segment to that word.  (This is also what
    makes ~25-30%% of the residency check's windows differ -- they are not
    corruption.)"""
    e_crlc = int.from_bytes(exe[0x06:0x08], 'little')
    hdr = int.from_bytes(exe[0x08:0x0A], 'little') * 16
    e_lfarlc = int.from_bytes(exe[0x18:0x1A], 'little')
    patched = set()
    for k in range(e_crlc):
        rec = e_lfarlc + k * 4
        if rec + 4 > len(exe):
            break
        off = int.from_bytes(exe[rec:rec + 2], 'little')
        seg = int.from_bytes(exe[rec + 2:rec + 4], 'little')
        target = hdr + (seg << 4) + off
        patched.add(target)
        patched.add(target + 1)
    return patched


def pick_signatures(exe, tail_start, count=8):
    """Candidate 16-byte windows to hunt for in guest RAM.

    Several, not one, because a window that looks fine statically can still be
    absent at runtime -- it may be data the program has already overwritten.
    (A single auto-picked window did exactly that on the first try.)  Windows
    must be distinctive, so a run of one byte is rejected: 16 zero bytes match
    everywhere and calibrate nothing.  Windows containing a relocation are
    rejected too -- the loader has patched those bytes."""
    patched = relocated_bytes(exe)
    hdr = int.from_bytes(exe[0x08:0x0A], 'little') * 16
    end = tail_start or len(exe)

    def usable(off):
        return (len(set(exe[off:off + 16])) >= 8
                and not any(b in patched for b in range(off, off + 16)))

    sigs = []
    if tail_start:
        sigs.append(('overlay pool / tail', tail_start))
    span = end - hdr
    for k in range(1, count):
        start = hdr + span * k // count & ~0xF
        for cand in range(start, min(start + 0x8000, end - 16), 16):
            if usable(cand):
                sigs.append((f'image @{cand:#07x}', cand))
                break
    return tuple(sigs)


def kill_strays():
    """Kill every qemu-system-i386 on the host -- including runs belonging to
    *sibling projects*, which is why this is opt-in (`--kill-strays`) and no
    longer runs unconditionally: a probe here used to silently destroy a
    concurrent run_qemu.py/run_trace.py next door, and the victim saw exactly
    the 'guest crashed' signature this was meant to clean up after.  Use it
    only when a crashed probe's orphan is actually in the way."""
    try:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/F', '/IM', 'qemu-system-i386.exe'],
                           capture_output=True)
        else:
            subprocess.run(['pkill', '-f', 'qemu-system-i386'],
                           capture_output=True)
        time.sleep(1)
    except OSError:
        pass


def geometry(hdd):
    g = json.load(open(hdd + '.geom.json'))
    return g['cyls'], g['heads'], g['secs'], g['part_offset']


class Qmp:
    def __init__(self, port):
        self.dead = False
        self.s = socket.create_connection(('127.0.0.1', port), timeout=30)
        self.f = self.s.makefile('rw')
        self.f.readline()                                   # greeting
        self._cmd({'execute': 'qmp_capabilities'})

    def _cmd(self, obj):
        """Returns None once the guest is gone.  ESC at UW's main menu quits to
        DOS, AUTOEXEC then runs QUIT.COM and QEMU exits -- so the monitor
        vanishing mid-probe is a normal outcome, not an error."""
        if self.dead:
            return None
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
        except (OSError, socket.timeout, ValueError):
            self.dead = True
            return None

    def hmp(self, cmd):
        m = self._cmd({'execute': 'human-monitor-command',
                       'arguments': {'command-line': cmd}})
        return (m or {}).get('return', '')

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


# QEMU x86 `info registers` looks like this -- note the SPACE in `ES =0000`,
# and that the flags register is `EFL`, not `EFLAGS`:
#
#   EAX=00005000 EBX=00000000 ECX=00000000 EDX=00000000
#   ESI=... EDI=... EBP=... ESP=0000911a
#   EIP=00000102 EFL=00000246 [---Z-P-] CPL=0 II=0 A20=1 SMM=0 HLT=0
#   ES =1234 00012340 0000ffff 00009300
#   CS =0596 00005960 0000ffff 00009b00
#
# Splitting on whitespace and requiring '=' inside the token (the first version
# of this script) therefore silently lost every segment register and reported
# CS=DS=ES=SS=0000 -- which makes every linear address wrong.  Match with a
# regex that tolerates the space instead.
REG_RE = re.compile(r'\b([A-Z]{2,6})\s*=\s*([0-9a-fA-F]{4,8})\b')


def parse_regs(text):
    d = {}
    for name, val in REG_RE.findall(text):
        d.setdefault(name, int(val, 16))         # first occurrence wins
    return d


def load_functions(skew):
    """work/ghidra_export/functions.txt -> two sorted [(start, end, name)]
    lists, both keyed by **UW.EXE file offset**.

    The export mixes three address forms, and only converting each correctly
    makes a sample resolvable:

      `1000:0000  size=115 ...`          image, Ghidra linear = file + 0xCE00
      `CODE_TAIL::066b30  size=...`      tail block, address  = file offset
      `int::00000021  size=1 ...`        DOS syscall pseudo-fns -- not code
    """
    path = next((q for q in (os.path.join(ROOT, d, 'ghidra_export', 'functions.txt')
                             for d in ('work', 'build', 're', 'analysis'))
                 if os.path.exists(q)), '')
    image, tail = [], []
    try:
        fh = open(path)
    except OSError:
        return image, tail
    with fh:
        for line in fh:
            m = re.match(r'([0-9a-f]{4}):([0-9a-f]{4})\s+size=(\d+)\s+'
                         r'inrefs=\d+\s+(\S+)', line.strip())
            if m:
                seg, off, size, name = m.groups()
                start = (int(seg, 16) << 4) + int(off, 16) - skew
                image.append((start, start + int(size), name))
                continue
            m = re.match(r'CODE_TAIL::([0-9a-f]+)\s+size=(\d+)\s+'
                         r'inrefs=\d+\s+(\S+)', line.strip())
            if m:
                start = int(m.group(1), 16)
                tail.append((start, start + int(m.group(2)), m.group(3)))
    image.sort()
    tail.sort()
    return image, tail


def name_for(funcs, file_off, tail_start):
    """Resolve a UW.EXE file offset to a Ghidra function name.  The two address
    spaces do not overlap in file terms, so pick by range rather than trying
    both -- trying both produced false 'tail' hits for image addresses."""
    image, tail = funcs
    table = tail if (tail_start and file_off >= tail_start) else image
    lo, hi = 0, len(table)
    while lo < hi:                                           # bisect right
        mid = (lo + hi) // 2
        if table[mid][0] <= file_off:
            lo = mid + 1
        else:
            hi = mid
    if lo:
        start, end, nm = table[lo - 1]
        if start <= file_off < end:
            return f'{nm}+{file_off - start:#x}'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hdd', default=default_hdd())
    ap.add_argument('--exe', default=default_exe(),
                    help='game binary the image was built from')
    ap.add_argument('--wait', type=int, default=55,
                    help='seconds after QEMU start before the first round')
    ap.add_argument('--samples', type=int, default=40,
                    help='EIP samples per round (0.2 s apart)')
    ap.add_argument('--key', action='append', default=[],
                    help='HMP sendkey after round 1, then sample again')
    ap.add_argument('--chase', type=int, default=0, metavar='N',
                    help='N samples hunting for code outside the loaded image')
    ap.add_argument('--kill-strays', action='store_true',
                    help='kill every qemu-system-i386 on the host first. '
                         'Off by default: it also kills sibling projects\' '
                         'concurrent runs.')
    args = ap.parse_args()

    if not args.hdd:
        sys.exit('no *.hdd with a .geom.json sidecar in img/ -- build one '
                 'with work/build_dos_hdd.py (or pass --hdd)')
    if not args.exe:
        sys.exit('no MZ .EXE found under work/expanded, work/extracted, game '
                 'or assets/extracted -- pass --exe')
    os.makedirs(OUTDIR, exist_ok=True)
    if args.kill_strays:
        kill_strays()
    qmp_port = free_port()
    cyls, heads, secs, _part_off = geometry(args.hdd)
    cmd = [QEMU, '-M', 'pc', '-cpu', '486', '-m', '16',
           '-drive', f'file={args.hdd.replace(chr(92), "/")},format=raw,'
                     f'if=none,id=hd0,cache=writeback',
           '-device', f'ide-hd,drive=hd0,bus=ide.0,unit=0,'
                      f'cyls={cyls},heads={heads},secs={secs}',
           '-boot', 'c', '-display', 'none', '-vga', 'std', '-no-reboot',
           '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
           '-qmp', f'tcp:127.0.0.1:{qmp_port},server=on,wait=off']
    print('$', ' '.join(cmd), '\n')
    # stdout to a file, not a pipe: nothing drains a pipe during the run, so a
    # chatty QEMU would fill the 64 KB buffer and block -- looking exactly
    # like a wedged guest.
    qemu_log = os.path.join(OUTDIR, 'probe_qemu_stdout.log')
    stale(qemu_log)
    log_fh = open(qemu_log, 'wb')
    proc = subprocess.Popen(cmd, stdout=log_fh, stderr=subprocess.STDOUT)
    atexit.register(lambda: proc.kill() if proc.poll() is None else None)

    def qemu_out():
        log_fh.flush()
        try:
            return open(qemu_log, encoding='utf-8', errors='replace').read()
        except OSError:
            return ''

    t0 = time.time()
    while time.time() - t0 < args.wait:
        if proc.poll() is not None:
            sys.exit('QEMU died before the wait elapsed:\n' + qemu_out())
        time.sleep(0.5)

    qmp = None
    for _ in range(20):
        try:
            qmp = Qmp(qmp_port)
            break
        except OSError:
            time.sleep(0.5)
    if qmp is None:
        proc.kill()
        sys.exit('QMP never came up')
    print(f'--- attached after {time.time() - t0:.1f}s ---')

    exe = open(args.exe, 'rb').read()
    skew = ghidra_skew(exe)
    tail_start = find_overlay_pool(exe)
    sigs = pick_signatures(exe, tail_start)
    pool = f'FBOV overlay pool at file {tail_start:#07x}' if tail_start \
        else 'no FBOV overlay pool'
    print(f'exe {args.exe} ({len(exe)} B), Ghidra skew {skew:#07x}, {pool}')
    funcs = load_functions(skew)
    print(f'{len(funcs[0])} image + {len(funcs[1])} CODE_TAIL functions loaded '
          f'for symbolication')

    def xp(addr, n=16):
        """HMP `xp` prints `00076b30: 0x00 0x00 ...`; count is DECIMAL."""
        t = qmp.hmp(f'xp /{n}xb 0x{addr:x}')
        vals = []
        for tok in t.split():
            tok = tok[2:] if tok.startswith('0x') else tok
            if len(tok) == 2 and all(c in '0123456789abcdef' for c in tok):
                vals.append(tok)
        try:
            return bytes.fromhex(''.join(vals[:n]))
        except ValueError:
            return b''

    def screenshot(tag):
        ppm = os.path.join(OUTDIR, f'probe_{tag}.ppm')
        png = os.path.join(OUTDIR, f'probe_{tag}.png')
        # Delete the previous run's files first: the tags repeat between
        # runs, so a screendump that never arrives would otherwise be
        # answered by the *last* run's picture and reported as this run's
        # evidence -- the hardest staleness to notice.
        stale(ppm, png)
        qmp._cmd({'execute': 'screendump', 'arguments': {'filename': ppm}})
        for _ in range(30):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
                break
            time.sleep(0.2)
        if not os.path.exists(ppm):
            print('screenshot: <none -- screendump produced no file>')
            return
        # PPM is already a readable capture; PNG is a convenience.  A missing
        # ffmpeg must not take the probe down -- hand back the PPM instead.
        try:
            subprocess.run([dosimg.host_tool('ffmpeg'), '-y', '-loglevel',
                            'error', '-i', ppm, png], capture_output=True)
        except (OSError, SystemExit):
            pass
        print(f'screenshot: {png if os.path.exists(png) else ppm}')

    # ---- raw registers once, so the parse can be eyeballed ----------------
    raw = qmp.hmp('info registers')
    print('--- raw `info registers` ---')
    print(raw.strip())
    r = parse_regs(raw)
    print('--- parsed ---')
    print('  ' + '  '.join(f'{k}={r[k]:04X}' for k in
                           ('CS', 'DS', 'ES', 'SS') if k in r))
    if 'CS' not in r:
        print('  !! CS still unparsed -- fix REG_RE before trusting anything')

    # ---- calibrate the file->linear delta ---------------------------------
    print(f'--- signature search: {len(sigs)} candidates, one pass over '
          f'0x00000..0xA0000 in 16 KB chunks (15 B overlap) ---')
    found = {}
    carry = b''
    unread = 0
    nchunks = 0
    for base in range(0x00000, 0xA0000, 0x4000):
        nchunks += 1
        d = xp(base, 0x4000)
        if len(d) != 0x4000:
            # An unreadable chunk is a hole in the search, not evidence of
            # absence -- count it so 'NOT FOUND' below can be qualified.
            unread += 1
            carry = b''
            continue
        blob = carry + d                 # overlap: a hit may straddle a chunk
        for label, off in sigs:
            if label in found:
                continue
            i = blob.find(exe[off:off + 16])
            if i >= 0:
                found[label] = (base - len(carry) + i) - off
        carry = d[-15:]
        if len(found) == len(sigs):
            break
    if unread:
        print(f'  !! {unread} of {nchunks} 16 KB chunks unreadable over QMP -- '
              f'treat NOT FOUND below as inconclusive, not as overwritten')
    for label, off in sigs:
        state = (f'delta {found[label]:#07x}' if label in found
                 else ('NOT FOUND in readable RAM (unreadable chunks above?)'
                       if unread else
                       'NOT FOUND in RAM (overwritten at runtime?)'))
        print(f'  {label:24s} file {off:#07x}  {exe[off:off + 8].hex(" ")}…  '
              f'{state}')

    # Majority vote among the located *image* signatures.  A window can
    # legitimately be missing (already overwritten), so require a strict
    # majority of those found rather than all of them -- a tie proves
    # nothing, and the old `>= len//2` accepted a 4-4 split with insertion
    # order deciding the winner.  The overlay-pool window never votes: an
    # overlay pool's runtime address is legitimately different per load
    # (find_overlay_pool's own docstring), so it can only distort the vote.
    POOL_LABEL = 'overlay pool / tail'
    image_found = {k: v for k, v in found.items() if k != POOL_LABEL}
    votes = collections.Counter(image_found.values())
    top = votes.most_common(1)
    if top and top[0][1] >= 2 and top[0][1] * 2 > len(image_found):
        delta, agree = top[0]
        hdr = int.from_bytes(exe[0x08:0x0A], 'little') * 16   # e_cparhdr*16
        load_seg = (delta + hdr) >> 4        # the load module starts at `hdr`
        pool_note = ''
        if POOL_LABEL in found:
            pool_note = (f'; pool window at delta {found[POOL_LABEL]:#07x} '
                         f'excluded from the vote')
        print(f'\n*** file -> linear delta = {delta:#07x} '
              f'({agree} of {len(image_found)} located image signatures agree'
              f'{pool_note})')
        print(f'*** load module base   = {delta + hdr:#07x} '
              f'(segment {load_seg:#06x}, PSP {load_seg - 0x10:#06x})')
        if tail_start:
            print(f'*** pool first bytes   = {tail_start + delta:#07x} '
                  f'(overlay buffer base -- NOT proof the pool is resident; '
                  f'see the residency check below)')
        print(f'*** runtime seg + {(skew - delta) >> 4:#05x} '
              f'= Ghidra segment (offsets unchanged)')
    else:
        delta = None
        print(f'\n!! no strict majority among located image signatures '
              f'(a tie or too few hits): {found} -- '
              f'cannot calibrate; EIP samples stay unsymbolicated')

    # ---- is the whole file really resident at `delta`? --------------------
    # The two signature hits only prove 32 bytes.  A single sampled SS:SP
    # landed inside the address range those hits imply for the tail, which
    # would mean the stack is sitting in the middle of executing code -- so
    # check the claim across the whole file instead of assuming it.
    if delta is not None:
        print('--- residency check: memory vs UW.EXE, 16 B every 4 KB ---')
        hdr = int.from_bytes(exe[0x08:0x0A], 'little') * 16
        for label, lo, hi in (('image', hdr, tail_start or len(exe)),
                              ('tail ', tail_start or len(exe), len(exe))):
            same = diff = unreadable = 0
            first_bad = None
            for f_off in range(lo, hi, 0x1000):
                want = exe[f_off:f_off + 16]
                got = xp(f_off + delta, 16)
                if not got:
                    # A failed QMP read is not a mismatch and not a match --
                    # count it, or the percentage quietly changes denominator.
                    unreadable += 1
                    continue
                if got == want:
                    same += 1
                else:
                    diff += 1
                    if first_bad is None:
                        first_bad = (f_off, want, got)
            total = same + diff
            pct = 100.0 * same / total if total else 0.0
            note = f', {unreadable} unreadable' if unreadable else ''
            print(f'  {label}: {same}/{total} windows match ({pct:.0f}%){note}')
            if first_bad:
                f_off, want, got = first_bad
                print(f'    first mismatch at file {f_off:#07x} '
                      f'(linear {f_off + delta:#07x}):')
                print(f'      file {want.hex(" ")}')
                print(f'      ram  {got.hex(" ")}')

        # What does the current stack actually look like, and where is it?
        rr = parse_regs(qmp.hmp('info registers'))
        if 'SS' in rr:
            sp = rr.get('ESP', 0) & 0xFFFF
            slin = (rr['SS'] << 4) + sp
            print(f'--- stack: SS:SP = {rr["SS"]:04X}:{sp:04X} = {slin:#07x} '
                  f'(file {slin - delta:#07x} if inside the image) ---')
            print(f'  at SP:      {xp(slin, 32).hex(" ")}')
            print(f'  file there: {exe[slin - delta:slin - delta + 32].hex(" ") if 0 <= slin - delta < len(exe) else "(outside)"}')

    # ---- chase: what is executing outside the loaded image? ---------------
    # Sampling showed CS values around 0x6Axx-0x6Cxx.  Naively that is
    # "file + delta" territory = CODE_TAIL, and it symbolicates -- but the 559
    # tail functions tile the whole region, so *any* address there resolves to
    # one.  That is not evidence.  Take the bytes at CS:IP and find out where
    # (if anywhere) they actually live in UW.EXE.
    def chase(rounds):
        print('--- chase: bytes at CS:IP for code outside the DOS-loaded image ---')
        seen = set()
        for _ in range(rounds):
            rr = parse_regs(qmp.hmp('info registers'))
            cs = rr.get('CS')
            if cs is None:
                break
            ip = rr.get('EIP', 0) & 0xFFFF
            lin = (cs << 4) + ip
            f_off = lin - (delta or 0)
            if not (tail_start and tail_start <= f_off < len(exe)) or cs in seen:
                time.sleep(0.15)
                continue
            seen.add(cs)
            blob = xp(lin, 32)
            print(f'  CS:IP {cs:04X}:{ip:04X} = {lin:#07x}  '
                  f'("file {f_off:#07x}" under the +{delta:#x} model)')
            print(f'    ram : {blob.hex(" ")}')
            print(f'    file: {exe[f_off:f_off + 32].hex(" ")}')
            hit = exe.find(blob[:10]) if len(blob) >= 10 else -1
            if hit >= 0:
                print(f'    -> those bytes DO occur in UW.EXE at file {hit:#07x}'
                      f'  => delta {lin - hit:#07x}')
            else:
                print('    -> not found in UW.EXE (relocated, generated, '
                      'or decompressed at runtime)')
            time.sleep(0.15)
        if not seen:
            print('  (no sample landed outside the image this run)')

    if args.chase:
        if delta is None:
            print('--- chase skipped: calibration failed, there is no '
                  'file->linear delta to test candidate bytes against ---')
        else:
            chase(args.chase)

    # ---- EIP histogram ----------------------------------------------------
    def round_of_samples(tag):
        print(f'--- EIP samples ({tag}, n={args.samples}) ---')
        hist = collections.Counter()
        segs = collections.Counter()
        for i in range(args.samples):
            rr = parse_regs(qmp.hmp('info registers'))
            cs, ip = rr.get('CS'), rr.get('EIP', 0) & 0xFFFF
            if cs is None:
                continue
            lin = (cs << 4) + ip
            hist[lin] += 1
            segs[(cs, rr.get('DS'), rr.get('ES'), rr.get('SS'))] += 1
            if i < 4:
                where = ''
                if delta is not None and 0 <= lin - delta < len(exe):
                    nm = name_for(funcs, lin - delta, tail_start)
                    where = f'  file {lin - delta:#07x}' + (f'  {nm}' if nm else '')
                print(f'  {i}: {cs:04X}:{ip:04X} = {lin:#07x}{where}   '
                      f'DS={rr.get("DS", 0):04X} ES={rr.get("ES", 0):04X} '
                      f'SS={rr.get("SS", 0):04X} SP={rr.get("ESP", 0) & 0xFFFF:04X}')
            time.sleep(0.2)
        print(f'  top addresses ({len(hist)} distinct):')
        for lin, n in hist.most_common(12):
            where = 'outside the image'
            if delta is not None and 0 <= lin - delta < len(exe):
                f_off = lin - delta
                nm = name_for(funcs, f_off, tail_start)
                where = f'file {f_off:#07x}' + (f'  {nm}' if nm else '  (no fn)')
            print(f'    {n:3d}x  {lin:#07x}  {where}')
        print('  segment registers seen (CS, DS, ES, SS):')
        for (cs, ds, es, ss), n in segs.most_common(6):
            def fmt(v):
                return f'{v:04X}' if v is not None else '????'
            print(f'    {n:3d}x  CS={fmt(cs)} DS={fmt(ds)} ES={fmt(es)} '
                  f'SS={fmt(ss)}')
        return hist

    screenshot('round1')
    round_of_samples('round 1')

    for n, k in enumerate(args.key, 1):
        print(f'--- sendkey {k} ---')
        qmp.hmp(f'sendkey {k}')
        time.sleep(3.0)
        if qmp.dead:
            print('  guest exited after this key (UW quit -> QUIT.COM)')
            break
        screenshot(f'key{n}_{k}')
    if args.key and not qmp.dead:
        time.sleep(2.0)
        round_of_samples(f'round 2, after {len(args.key)} keys')

    qmp.close()
    try:
        proc.kill()
    except OSError:
        pass
    log_fh.close()
    out = qemu_out()
    if out.strip():
        print('--- qemu stdout ---\n' + out)
    print('done' if delta is not None else 'done (UNCALIBRATED)')
    # Exit status says whether calibration succeeded, so an automated caller
    # can tell a good run from an uncalibrated one.
    return 0 if delta is not None else 1


if __name__ == '__main__':
    sys.exit(main())
