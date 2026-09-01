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

# Guest RAM, in MB.  Named because the signature search has to know it: a
# real-mode image lives below the 640 KB line, a DPMI-extended one does not,
# and scanning only the first 0xA0000 for the latter reports every signature
# as "NOT FOUND in RAM (overwritten at runtime?)" -- absence of evidence
# printed as evidence of absence.
MEM_MB = 16


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
# The name class must admit digits: `CR0`, `CR4` and `DR7` are registers too,
# and `[A-Z]{2,6}` silently skipped every one of them -- which is how CR0.PE,
# the one bit that says whether the guest is in protected mode at all, went
# missing and a DOS/4GW guest was reported as `mode=real`.
REG_RE = re.compile(r'\b([A-Z][A-Z0-9]{1,5})\s*=\s*([0-9a-fA-F]{4,8})\b')


def parse_regs(text):
    d = {}
    for name, val in REG_RE.findall(text):
        d.setdefault(name, int(val, 16))         # first occurrence wins
    return d


# A protected-mode guest's segment registers are selectors, not paragraphs:
# `(sel << 4) + off` is then a number with no meaning, and EIP is 32 bits wide
# so masking it to 16 loses the address entirely.  QEMU prints the descriptor
# the selector resolves to right next to it -- take the base from there:
#
#   CS =0180 00000000 ffffffff 00cf9b00 DPL=0 CS32 [-RA]
#         ^selector ^base    ^limit   ^attr        ^ 32-bit code
#
# DOS/4GW and Phar Lap targets run flat (base 0, 4 GB limit) with the image
# loaded above 1 MB, which is why the real-mode assumptions below had to be
# made explicit rather than left implicit.
SEG_RE = re.compile(r'\b(ES|CS|SS|DS|FS|GS)\s*=\s*([0-9a-fA-F]{4})\s+'
                    r'([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})\s+'
                    r'([0-9a-fA-F]{8})')


def parse_segs(text):
    """{'CS': (selector, base, limit, attr), ...} -- empty in real mode."""
    return {n: (int(sel, 16), int(base, 16), int(lim, 16), int(attr, 16))
            for n, sel, base, lim, attr in SEG_RE.findall(text)}


def cpu_mode(text, regs):
    """'real', 'v86', 'pm16' or 'pm32', from CR0.PE, EFLAGS.VM and the CS D bit.

    QEMU prints the descriptor type mnemonic (`CS32`/`CS16`) for a protected
    mode guest; fall back to attr bit 22 (D/B) when the mnemonic is absent.

    **V86 is not protected mode for addressing purposes.**  Any DOS guest with
    EMM386 loaded runs with CR0.PE=1 while its segment registers stay
    paragraphs, so calling that `pm16` and reaching for a descriptor base
    would be a wrong label on a right answer -- QEMU reports base = sel<<4
    there, so both routes agree, and the label is what a reader would
    otherwise carry into the next project.
    """
    if not regs.get('CR0', 0) & 1:
        return 'real'
    if regs.get('EFL', 0) & (1 << 17):            # EFLAGS.VM
        return 'v86'
    if 'CS32' in text:
        return 'pm32'
    if 'CS16' in text:
        return 'pm16'
    segs = parse_segs(text)
    return 'pm32' if segs.get('CS', (0, 0, 0, 0))[3] & (1 << 22) else 'pm16'


def linear(mode, regs, segs, seg, off):
    """Linear address of `seg:off` under the guest's *current* mode.

    Real mode keeps the paragraph arithmetic and the 16-bit offset.  In
    protected mode the descriptor base is the only correct answer, and the
    offset must not be truncated.
    """
    if mode in ('real', 'v86'):
        return ((regs.get(seg, 0) & 0xFFFF) << 4) + (off & 0xFFFF)
    if seg in segs:
        return (segs[seg][1] + off) & 0xFFFFFFFF
    return off & 0xFFFFFFFF


def mapping_report(exe, ram, step=0x1000, win=16):
    """Every `step` bytes of the file, hunted for in a whole-RAM dump.

    The signature vote reads 7 windows over QMP and asks which single delta
    most of them agree on.  That is enough for a real-mode image loaded in one
    piece, and actively misleading for anything else: an extender image, a
    self-loaded overlay and a second copy of the same bytes all produce
    windows that vote against each other, and the loser is printed as
    'NOT FOUND ... (overwritten at runtime?)' -- absence of evidence again.

    With the whole of RAM on the host, every window can be checked against
    every address for free.  Returns a list of (delta, first_file_off,
    last_file_off, count) runs, so a caller can see *which file range* each
    delta covers rather than one number for the file as a whole.

    A window that occurs at several deltas is reported at each of them: two
    resident copies of one image is a fact about the guest, not an ambiguity
    to be resolved by picking one.
    """
    by_delta = collections.defaultdict(list)
    unmatched = 0
    for off in range(0, len(exe) - win, step):
        w = exe[off:off + win]
        if len(set(w)) < 4:            # 00-fill and pad runs match everywhere
            continue
        hits, at = [], ram.find(w)
        while at >= 0 and len(hits) < 8:
            hits.append(at - off)
            at = ram.find(w, at + 1)
        if not hits:
            unmatched += 1
        for d in hits:
            by_delta[d].append(off)
    runs = []
    for d, offs in by_delta.items():
        offs.sort()
        start = prev = offs[0]
        n = 1
        for o in offs[1:]:
            if o - prev <= step * 4:            # tolerate fixed-up gaps
                prev, n = o, n + 1
                continue
            runs.append((d, start, prev, n))
            start = prev = o
            n = 1
        runs.append((d, start, prev, n))
    runs.sort(key=lambda r: (-r[3], r[1]))
    return runs, unmatched


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
    ap.add_argument('--dump-ram', action='store_true',
                    help='pmemsave all of guest RAM once, then match every '
                         '4 KB file window against it on the host. Exhaustive '
                         'where the 7-signature vote is a sample.')
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
    cmd = [QEMU, '-M', 'pc', '-cpu', '486', '-m', str(MEM_MB),
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
        # Called once more after the teardown closes log_fh, so a closed
        # handle is normal here -- it used to end the run in a traceback
        # *after* all the evidence had been gathered and printed.
        try:
            log_fh.flush()
        except ValueError:
            pass
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
    segs = parse_segs(raw)
    mode = cpu_mode(raw, r)
    print('--- parsed ---')
    print('  ' + '  '.join(f'{k}={r[k]:04X}' for k in
                           ('CS', 'DS', 'ES', 'SS') if k in r))
    if 'CS' not in r:
        print('  !! CS still unparsed -- fix REG_RE before trusting anything')
    print(f'  mode={mode}' + (
        '  (real-mode paragraph arithmetic)' if mode == 'real' else
        '  (V86: CR0.PE is set, but segments are still paragraphs)'
        if mode == 'v86' else
        '  ' + '  '.join(f'{k} base={segs[k][1]:#010x}'
                         for k in ('CS', 'DS', 'SS') if k in segs)))
    if mode not in ('real', 'v86'):
        print('  protected mode: selectors are not paragraphs -- linear '
              'addresses below come from the descriptor base, and EIP is '
              'used at full width')

    # A DPMI/extender guest sampled at one moment may be inside a real-mode
    # stub the next; the scan has to cover wherever the image can be.
    scan_end = 0xA0000 if mode in ('real', 'v86') else MEM_MB << 20

    # ---- exhaustive mapping, when asked for -------------------------------
    ram_runs = None
    if args.dump_ram:
        ram_path = os.path.join(OUTDIR, 'ram.bin')
        stale(ram_path)
        nbytes = MEM_MB << 20
        qmp.hmp(f'pmemsave 0 {nbytes} "{ram_path}"')
        for _ in range(60):
            if os.path.exists(ram_path) and os.path.getsize(ram_path) >= nbytes:
                break
            time.sleep(0.5)
        if not os.path.exists(ram_path) or os.path.getsize(ram_path) < nbytes:
            print(f'!! pmemsave produced {os.path.getsize(ram_path) if os.path.exists(ram_path) else 0}'
                  f' of {nbytes} B -- skipping the mapping report')
        else:
            ram = open(ram_path, 'rb').read()
            ram_runs, unmatched = mapping_report(exe, ram)
            total = len(exe) // 0x1000
            print(f'--- mapping report: every 4 KB of the file vs all '
                  f'{nbytes >> 20} MB of RAM ({ram_path}) ---')
            print(f'  {unmatched} of ~{total} windows found nowhere in RAM '
                  f'(not loaded, or rewritten by load-time fixups)')
            for d, lo, hi, n in ram_runs[:16]:
                print(f'  delta {d:#010x}  file {lo:#08x}..{hi:#08x}  '
                      f'{n} window{"s" if n > 1 else ""}  '
                      f'-> linear {lo + d:#010x}..{hi + d:#010x}')

    # ---- calibrate the file->linear delta ---------------------------------
    print(f'--- signature search: {len(sigs)} candidates, one pass over '
          f'0x00000..{scan_end:#x} in 16 KB chunks (15 B overlap) ---')
    found = {}
    carry = b''
    unread = 0
    nchunks = 0
    for base in range(0x00000, scan_end, 0x4000):
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
        # An exact window match is the only positive here, so every negative
        # has to carry its own caveats: the search bound, and the fact that a
        # loader applying fixups rewrites bytes on pages that ARE resident.
        state = (f'delta {found[label]:#07x}' if label in found
                 else ('NOT FOUND in readable RAM (unreadable chunks above?)'
                       if unread else
                       f'NOT FOUND below {scan_end:#x} (not loaded, '
                       f'overwritten, or rewritten by load-time fixups)'))
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
        if mode in ('real', 'v86'):
            # V86 included: a DOS program under EMM386 still has a PSP and
            # still loads on a paragraph boundary.
            print(f'*** load module base   = {delta + hdr:#07x} '
                  f'(segment {load_seg:#06x}, PSP {load_seg - 0x10:#06x})')
        else:
            print(f'*** load module base   = {delta + hdr:#07x} '
                  f'(no PSP/segment reading: the guest is in {mode})')
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
    if len(votes) > 1:
        # Several deltas, each backed by a located window, is the signature of
        # a multi-object load (LE/P3 objects, or an image plus a separately
        # placed overlay).  One of them is not "the" delta: print the file
        # ranges each one covers and let the project's executable.md model the
        # objects.  Collapsing this to a majority is how a wrong flat mapping
        # gets written down as measured.
        print(f'--- {len(votes)} distinct deltas among located windows: the '
              f'image is NOT one flat span ---')
        by_delta = {}
        for label, off in sigs:
            if label in found:
                by_delta.setdefault(found[label], []).append((off, label))
        for d in sorted(by_delta):
            offs = sorted(by_delta[d])
            span = f'{offs[0][0]:#07x}..{offs[-1][0]:#07x}'
            print(f'  delta {d:#09x}  file {span}  '
                  f'({len(offs)} window{"s" if len(offs) > 1 else ""})')

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
        raw_s = qmp.hmp('info registers')
        rr = parse_regs(raw_s)
        ssegs = parse_segs(raw_s)
        smode = cpu_mode(raw_s, rr)
        if 'SS' in rr:
            sp = (rr.get('ESP', 0) if smode not in ('real', 'v86')
                  else rr.get('ESP', 0) & 0xFFFF)
            slin = linear(smode, rr, ssegs, 'SS', rr.get('ESP', 0))
            print(f'--- stack: SS:SP = {rr["SS"]:04X}:{sp:08X} = {slin:#09x} '
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
            raw_r = qmp.hmp('info registers')
            rr = parse_regs(raw_r)
            rsegs = parse_segs(raw_r)
            rmode = cpu_mode(raw_r, rr)
            cs = rr.get('CS')
            if cs is None:
                break
            ip = (rr.get('EIP', 0) if rmode not in ('real', 'v86')
                  else rr.get('EIP', 0) & 0xFFFF)
            lin = linear(rmode, rr, rsegs, 'CS', rr.get('EIP', 0))
            f_off = lin - (delta or 0)
            # Without a delta there is no "inside the image" to be outside of,
            # so chase every distinct sampled address instead: the byte match
            # below is what proves a mapping, and it needs no delta to run.
            key = cs if delta is not None else lin
            in_scope = (tail_start and tail_start <= f_off < len(exe)) \
                if delta is not None else True
            if not in_scope or key in seen:
                time.sleep(0.15)
                continue
            seen.add(key)
            blob = xp(lin, 32)
            model = (f'("file {f_off:#07x}" under the +{delta:#x} model)'
                     if delta is not None else '(no calibrated delta)')
            print(f'  CS:EIP {cs:04X}:{ip:08X} = {lin:#09x}  {model}')
            print(f'    ram : {blob.hex(" ")}')
            if delta is not None:
                print(f'    file: {exe[f_off:f_off + 32].hex(" ")}')
            hit = exe.find(blob[:10]) if len(blob) >= 10 else -1
            if hit >= 0:
                dup = exe.find(blob[:10], hit + 1)
                print(f'    -> those bytes DO occur in UW.EXE at file {hit:#07x}'
                      f'  => delta {lin - hit:#09x}'
                      + ('  (NOT unique -- also at '
                         f'{dup:#07x}; delta unproven)' if dup >= 0 else ''))
            else:
                print('    -> not found in UW.EXE (relocated, generated, '
                      'or decompressed at runtime)')
            time.sleep(0.15)
        if not seen:
            print('  (no sample landed outside the image this run)')

    if args.chase:
        if delta is None:
            print('--- chase: uncalibrated, so every distinct sampled address '
                  'is matched back into the file by bytes ---')
        chase(args.chase)

    # ---- EIP histogram ----------------------------------------------------
    def round_of_samples(tag):
        print(f'--- EIP samples ({tag}, n={args.samples}) ---')
        hist = collections.Counter()
        seg_hist = collections.Counter()
        modes = collections.Counter()
        for i in range(args.samples):
            raw_i = qmp.hmp('info registers')
            rr = parse_regs(raw_i)
            isegs = parse_segs(raw_i)
            imode = cpu_mode(raw_i, rr)
            cs = rr.get('CS')
            ip = (rr.get('EIP', 0) if imode not in ('real', 'v86')
                  else rr.get('EIP', 0) & 0xFFFF)
            if cs is None:
                continue
            lin = linear(imode, rr, isegs, 'CS', rr.get('EIP', 0))
            modes[imode] += 1
            hist[lin] += 1
            seg_hist[(cs, rr.get('DS'), rr.get('ES'), rr.get('SS'))] += 1
            if i < 4:
                where = ''
                if delta is not None and 0 <= lin - delta < len(exe):
                    nm = name_for(funcs, lin - delta, tail_start)
                    where = f'  file {lin - delta:#07x}' + (f'  {nm}' if nm else '')
                print(f'  {i}: {cs:04X}:{ip:08X} = {lin:#09x}{where}   '
                      f'DS={rr.get("DS", 0):04X} ES={rr.get("ES", 0):04X} '
                      f'SS={rr.get("SS", 0):04X} SP={rr.get("ESP", 0):08X}')
            time.sleep(0.2)
        print(f'  top addresses ({len(hist)} distinct):')
        for lin, n in hist.most_common(12):
            where = 'outside the image'
            if delta is not None and 0 <= lin - delta < len(exe):
                f_off = lin - delta
                nm = name_for(funcs, f_off, tail_start)
                where = f'file {f_off:#07x}' + (f'  {nm}' if nm else '  (no fn)')
            print(f'    {n:3d}x  {lin:#09x}  {where}')
        if len(modes) > 1:
            # A DPMI guest drops back into the stub for I/O; a histogram that
            # mixes modes has mixed address spaces in it.
            print('  CPU mode per sample: ' + ', '.join(
                f'{m}x{n}' for m, n in modes.most_common()))
        print('  segment registers seen (CS, DS, ES, SS):')
        for (cs, ds, es, ss), n in seg_hist.most_common(6):
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
