#!/usr/bin/env python3
r"""dosimg -- build a bootable MS-DOS 6.22 FAT16 hard-disk image for a DOS game.

Reusable across the sibling DOS-game projects (UW1 / UW2 / TIE); each one ships
an identical copy of this module plus a thin `build_dos_hdd.py` that supplies
its own layout and CONFIG.SYS/AUTOEXEC.BAT.  See `analysis/qemu-boot.md` for the
whole procedure and the reasons behind each rule below.

The five things that make the image actually boot -- every one of them was a
real failure first:

  1. **A hard disk needs an MBR partition table.**  A "superfloppy" image (FAT
     written at LBA 0, no partition table) boots nothing and DOS will not assign
     it a drive letter -- `DIR C:` comes back empty.
  2. **Use the genuine MS-DOS 6.22 boot record** (sector 0 of the install
     floppy) with only its BPB replaced.  mformat's own boot code hangs in QEMU.
  3. **IO.SYS must be root directory entry 0 and MSDOS.SYS entry 1**, and
     IO.SYS's first 3 sectors must be consecutive: the boot record compares
     those two names literally and then reads 3 sectors without walking the FAT.
     So copy them before anything else -- and never pass `mformat -v`, which
     spends entry 0 on a volume label.
  4. **BPB `hidden` = the partition's start LBA**, and total16/total32 must
     describe the *partition*, not the disk.  The boot record adds `hidden` to
     every sector number it computes.
  5. **The BPB's CHS (spt/heads) must match what the emulator reports.**  QEMU
     takes geometry on the device (`-device ide-hd,cyls=,heads=,secs=`), not on
     `-drive` -- since QEMU 6 the latter errors out.

Requires: mtools + nasm (found on $PATH, or in the MSYS2 prefix on the
Windows machine -- see host_tool()), and the genuine DOS 6.22
install floppies (Disk1.img has IO.SYS/MSDOS.SYS/COMMAND.COM and the boot
record; Disk2.img has HIMEM/SHARE).
"""
import json
import os
import shutil
import struct
import subprocess
import sys

# Host-side helper programs (mtools, nasm).  Looked up in this order:
#
#   1. $<PROG> -- e.g. NASM=/opt/homebrew/bin/nasm, MCOPY=...
#   2. $DOS_TOOLS, a directory holding them all
#   3. $PATH
#   4. the MSYS2 prefix this harness was originally written against
#
# so one copy of this file works on Windows, macOS and Linux.  Note these are
# *host* paths; the C:\... strings elsewhere in this file are DOS guest paths
# and have nothing to do with the machine running QEMU.
MSYS = r'C:\msys64\mingw64\bin'


def host_tool(prog):
    """Absolute path to a host helper program, or exit with how to supply it."""
    override = os.environ.get(prog.upper().replace('-', '_'))
    if override:
        return override
    for d in (os.environ.get('DOS_TOOLS'), MSYS):
        if not d:
            continue
        for cand in (os.path.join(d, prog), os.path.join(d, prog + '.exe')):
            if os.path.isfile(cand):
                return cand
    found = shutil.which(prog)
    if found:
        return found
    sys.exit(f'{prog} not found on $PATH. Install it, or set '
             f'{prog.upper().replace("-", "_")}=<path> or DOS_TOOLS=<dir>.')

# Fixed geometry: 16 heads x 63 sectors is the universal BIOS translation and
# addresses up to 1024 cyl = 528 MB, which covers every image here.
HEADS, SPT = 16, 63
CYL_SECTORS = HEADS * SPT                      # 1008
MAX_CYLS = 1024

# Uncompressed DOS files live on Disk1; the KWAJ-compressed ones on Disk1/Disk2.
# (`.??_` = KWAJ method 3, LZ+Huffman -- not decodable by 7-Zip/mtools, so they
# are expanded in-guest by the genuine EXPAND.EXE; see bootstrap_expand().)
DOS_PAYLOAD = {
    # MSCDEX is the CD redirector; it still needs a vendor ATAPI *device
    # driver* loaded from CONFIG.SYS before it will assign a drive letter.
    'Disk1.img': ['IO.SYS', 'MSDOS.SYS', 'COMMAND.COM', 'EXPAND.EXE', 'DEBUG.EXE',
                  'FDISK.EXE', 'FORMAT.COM', 'ATTRIB.EXE', 'SYS.COM', 'MEM.EX_',
                  'EMM386.EX_', 'XCOPY.EX_', 'CHKDSK.EXE', 'MSCDEX.EXE'],
    'Disk2.img': ['HIMEM.SY_', 'SHARE.EX_', 'SMARTDRV.EX_'],
}
SYSTEM_FILES = ('IO.SYS', 'MSDOS.SYS', 'COMMAND.COM')

# Expanded in-guest during bootstrap: (compressed, expanded)
EXPAND_PAIRS = [('HIMEM.SY_', 'HIMEM.SYS'), ('EMM386.EX_', 'EMM386.EXE'),
                ('MEM.EX_', 'MEM.EXE'), ('SHARE.EX_', 'SHARE.EXE'),
                ('XCOPY.EX_', 'XCOPY.EXE'), ('SMARTDRV.EX_', 'SMARTDRV.EXE')]

# QUIT.COM -- `mov dx,0F4h / mov al,0Ah / out dx,al / int 20h`.  Writing to
# QEMU's isa-debug-exit port ends the run with code (0x0A<<1)|1 = 21, so a
# headless run terminates itself instead of being killed on a timeout.  The
# INT 20h keeps it harmless on real hardware and in 86Box.
QUIT_COM = bytes.fromhex('BAF400B00AEECD20')
QUIT_EXIT_CODE = 21


def run(prog, *args, check=True, cwd=None):
    p = subprocess.run([host_tool(prog), *args],
                       capture_output=True, text=True, cwd=cwd,
                       env=dict(os.environ, MTOOLS_SKIP_CHECK='1'))
    if check and p.returncode != 0:
        sys.exit(f'{prog} {" ".join(args[:4])}... failed ({p.returncode}):\n'
                 f'{p.stdout}\n{p.stderr}')
    return p.stdout


def is_83(name):
    base, dot, ext = name.partition('.')
    bad = set(' +,;=[]"*?<>|/\\:')
    return (1 <= len(base) <= 8 and len(ext) <= 3 and not (dot and not ext)
            and not (set(name) & bad))


class DosImage:
    def __init__(self, out, size_mb, floppy_dir, work_dir, label='DOS622'):
        self.out = os.path.abspath(out)
        self.floppy_dir = floppy_dir
        self.work = work_dir
        self.label = label.upper().ljust(11)[:11]
        os.makedirs(self.work, exist_ok=True)
        os.makedirs(os.path.dirname(self.out), exist_ok=True)
        self.part = os.path.join(self.work, 'part.raw')
        self.dosf = os.path.join(self.work, 'dos_files')

        want = size_mb * 1024 * 1024 // 512
        self.cyls = min(MAX_CYLS, max(2, -(-want // CYL_SECTORS)))
        self.disk_sectors = self.cyls * CYL_SECTORS
        self.part_start = SPT                       # LBA 63 = cyl 0, head 1, sec 1
        self.part_cyls = self.cyls - 1
        self.part_sectors = self.part_cyls * CYL_SECTORS
        # smallest power-of-two cluster keeping the count inside the FAT16 window
        self.spc = 4
        while self.part_sectors // self.spc > 65000 and self.spc < 128:
            self.spc *= 2
        self.root_sectors = 32                      # 512 root entries
        self._pending = []                          # (kind, args) replayed in write()

    # --- content -----------------------------------------------------------
    def mkdir(self, guest):
        self._pending.append(('mmd', guest))

    def add_file(self, local, guest):
        self._pending.append(('file', (local, guest)))

    def add_bytes(self, data, guest):
        name = guest.rstrip('/').rsplit('/', 1)[-1]
        p = os.path.join(self.work, 'stage_' + name)
        open(p, 'wb').write(data)
        self.add_file(p, guest)

    def add_tree(self, guest_root, *local_roots):
        """Copy one or more local trees into guest_root, merged.

        Merging is how UW2's five install disks become one C:\\UW2; passing a
        single root is the ordinary case.
        """
        self.mkdir(guest_root)
        merged = {}
        for lr in local_roots:
            for root, _, files in os.walk(lr):
                rel = os.path.relpath(root, lr).replace(os.sep, '/')
                rel = '' if rel == '.' else rel
                for f in files:
                    key = f'{rel}/{f}' if rel else f
                    if key in merged:
                        sys.exit(f'collision merging trees: {key}')
                    merged[key] = os.path.join(root, f)
        bad = [k for k in merged if not all(is_83(p) for p in k.split('/'))]
        if bad:
            sys.exit(f'not 8.3-clean, would be mangled by mcopy: {bad[:10]}')
        for d in sorted({k.rsplit('/', 1)[0] for k in merged if '/' in k}):
            self.mkdir(f'{guest_root}/{d}')
        bydir = {}
        for k, v in merged.items():
            bydir.setdefault(k.rsplit('/', 1)[0] if '/' in k else '', []).append(v)
        for d, files in sorted(bydir.items()):
            dest = f'{guest_root}/{d}/' if d else f'{guest_root}/'
            self._pending.append(('batch', (sorted(files), dest)))
        return len(merged)

    # --- build -------------------------------------------------------------
    def _stage_dos_files(self):
        os.makedirs(self.dosf, exist_ok=True)
        for disk, names in DOS_PAYLOAD.items():
            img = os.path.join(self.floppy_dir, disk)
            if not os.path.exists(img):
                sys.exit(f'missing genuine DOS floppy: {img}')
            # Destination must be '.' with cwd set: mtools reads a trailing
            # `C:\...` argument as a *drive letter* ("Drive 'C:' not supported").
            # `-o` only covers clashes on the DOS side; overwriting an existing
            # *host* file needs `-n`, or a rebuild over a populated staging dir
            # stops on `File "./IO.SYS" exists, overwrite (y/n) ?` and blocks
            # forever waiting on a tty that isn't there.
            run('mcopy', '-m', '-o', '-n', '-i', img,
                *[f'::{n}' for n in names], '.', cwd=self.dosf)

    def _mcopy(self, dest, files):
        # Windows caps a command line at ~32 KB; chunk long file lists.
        chunk, size = [], 0
        for f in files:
            if size + len(f) > 28000 and chunk:
                run('mcopy', '-i', self.part, '-o', *chunk, dest)
                chunk, size = [], 0
            chunk.append(f)
            size += len(f) + 1
        if chunk:
            run('mcopy', '-i', self.part, '-o', *chunk, dest)

    def write(self):
        self._stage_dos_files()
        with open(self.part, 'wb') as f:
            f.truncate(self.part_sectors * 512)
        # NB: no `-v LABEL` -- see rule 3 in the module docstring.
        run('mformat', '-i', self.part, '-h', str(HEADS), '-n', str(SPT),
            '-t', str(self.part_cyls), '-H', str(self.part_start),
            '-c', str(self.spc), '-r', str(self.root_sectors), '-M', '512', '::')

        for n in SYSTEM_FILES:                      # entries 0,1,2 -- order matters
            run('mcopy', '-i', self.part, '-o', os.path.join(self.dosf, n), '::/' + n)
        run('mattrib', '-i', self.part, '+r', '+s', '+h', '::/IO.SYS', '::/MSDOS.SYS')

        quit_path = os.path.join(self.work, 'QUIT.COM')
        open(quit_path, 'wb').write(QUIT_COM)
        run('mcopy', '-i', self.part, '-o', quit_path, '::/QUIT.COM')

        run('mmd', '-i', self.part, '::/DOS')
        self._mcopy('::/DOS/', [os.path.join(self.dosf, n) for disk in DOS_PAYLOAD
                                for n in DOS_PAYLOAD[disk] if n not in SYSTEM_FILES])

        for kind, arg in self._pending:
            if kind == 'mmd':
                run('mmd', '-i', self.part, '::' + arg)
            elif kind == 'file':
                run('mcopy', '-i', self.part, '-o', arg[0], '::' + arg[1])
            elif kind == 'batch':
                self._mcopy('::' + arg[1], arg[0])

        self._install_boot_record()
        self._assemble()
        return self

    def _install_boot_record(self):
        part = bytearray(open(self.part, 'rb').read())
        genuine = bytearray(open(os.path.join(self.floppy_dir, 'Disk1.img'),
                                 'rb').read(512))
        assert genuine[:3] == b'\xEB\x3C\x90', genuine[:3].hex()
        assert genuine[0x1FE:0x200] == b'\x55\xAA'
        bs = bytearray(genuine)
        bs[0x0B:0x3E] = part[0x0B:0x3E]              # BPB exactly as mformat built it
        bs[0x24] = 0x80                              # physical drive = first HDD
        bs[0x2B:0x36] = self.label.encode()
        bs[0x36:0x3E] = b'FAT16   '
        part[0:512] = bs

        u16 = lambda o: struct.unpack('<H', bs[o:o + 2])[0]
        u32 = lambda o: struct.unpack('<I', bs[o:o + 4])[0]
        self.bpb = dict(bps=u16(0x0B), spc=bs[0x0D], resv=u16(0x0E), nfat=bs[0x10],
                        rootent=u16(0x11), tot16=u16(0x13), media=bs[0x15],
                        spf=u16(0x16), spt=u16(0x18), heads=u16(0x1A),
                        hidden=u32(0x1C), tot32=u32(0x20), drive=bs[0x24])
        b = self.bpb
        assert b['bps'] == 512 and b['media'] == 0xF8 and b['drive'] == 0x80
        assert b['spt'] == SPT and b['heads'] == HEADS
        assert b['hidden'] == self.part_start, (b['hidden'], self.part_start)
        assert self.part_sectors in (b['tot16'], b['tot32']), b
        assert b['rootent'] == self.root_sectors * 512 // 32

        data_sectors = (self.part_sectors - b['resv'] - b['nfat'] * b['spf']
                        - b['rootent'] * 32 // 512)
        self.nclust = data_sectors // b['spc']
        assert 4085 <= self.nclust < 65525, f'not FAT16: {self.nclust} clusters'

        root_lba = b['resv'] + b['nfat'] * b['spf']
        root = part[root_lba * 512:root_lba * 512 + b['rootent'] * 32]
        assert root[0:11] == b'IO      SYS', root[0:11]
        assert root[32:43] == b'MSDOS   SYS', root[32:43]
        io_clust = struct.unpack('<H', root[26:28])[0]
        fat = part[b['resv'] * 512:]
        assert io_clust == 2, io_clust
        assert struct.unpack('<H', fat[4:6])[0] == 3, 'IO.SYS not contiguous'
        self._part_bytes = part

    def _assemble(self):
        mbr = bytearray(512)
        mbr[:len(MBR_CODE)] = MBR_CODE
        chs = lambda lba: (lba // CYL_SECTORS, lba % CYL_SECTORS // SPT,
                           lba % SPT + 1)
        c0, h0, s0 = chs(self.part_start)
        c1, h1, s1 = chs(self.part_start + self.part_sectors - 1)
        mbr[0x1BE] = 0x80                                        # active
        mbr[0x1BF:0x1C2] = bytes([h0, (s0 & 0x3F) | ((c0 >> 2) & 0xC0), c0 & 0xFF])
        mbr[0x1C2] = 0x06                                        # type 06 = FAT16
        mbr[0x1C3:0x1C6] = bytes([h1, (s1 & 0x3F) | ((c1 >> 2) & 0xC0), c1 & 0xFF])
        struct.pack_into('<I', mbr, 0x1C6, self.part_start)
        struct.pack_into('<I', mbr, 0x1CA, self.part_sectors)
        mbr[0x1FE:0x200] = b'\x55\xAA'

        img = bytearray(self.disk_sectors * 512)
        img[0:512] = mbr
        off = self.part_start * 512
        img[off:off + len(self._part_bytes)] = self._part_bytes
        open(self.out, 'wb').write(img)
        json.dump(dict(cyls=self.cyls, heads=HEADS, secs=SPT,
                       part_offset=self.part_start * 512, clusters=self.nclust,
                       cluster_bytes=self.bpb['spc'] * 512),
                  open(self.out + '.geom.json', 'w'), indent=1)
        print(f'{self.out}: {len(img)} B, {self.cyls}c/{HEADS}h/{SPT}s, '
              f'partition LBA {self.part_start}..'
              f'{self.part_start + self.part_sectors - 1} '
              f'(CHS {c0}/{h0}/{s0}..{c1}/{h1}/{s1}), '
              f'{self.nclust} x {self.bpb["spc"] * 512} B clusters')


def expand_autoexec(then=b'C:\\QUIT.COM\r\n'):
    """AUTOEXEC that runs the genuine EXPAND.EXE over the KWAJ `.??_` files."""
    out = [b'@ECHO OFF\r\n', b'PROMPT $P$G\r\n', b'PATH C:\\DOS\r\n',
           b'C:\r\n', b'CD \\DOS\r\n',
           b'ECHO === bootstrap === > C:\\BOOT.LOG\r\n', b'VER >> C:\\BOOT.LOG\r\n']
    for src, dst in EXPAND_PAIRS:
        out.append(f'EXPAND {src} C:\\DOS\\{dst} >> C:\\BOOT.LOG\r\n'.encode())
    out += [b'CD \\\r\n', b'ECHO === bootstrap done === >> C:\\BOOT.LOG\r\n', then]
    return b''.join(out)


# 446-byte MBR chain-loader assembled from work/mbr.asm:
#   nasm -f bin work/mbr.asm -o work/img_build/mbr.bin
# Relocates to 0x0600, picks the active partition, reads its boot sector to
# 0x7C00 via INT 13h AH=42h (LBA) with an AH=02h CHS fallback, then jumps with
# DL = drive and DS:SI = the partition entry.  The LBA path is what makes this
# geometry-proof.
MBR_CODE = bytes.fromhex(
    'fa31c08ed88ec08ed0bc007cfbfcbe007cbf0006b90001f3a5ea1e0600008816bc06bebe'
    '07b90400803c80740a83c610e2f6bebd06eb628b4408a3b4068b440aa3b606b441bbaa55'
    '8a16bc06cd13721a81fb55aa7514f6c101740fb4428a16bc0656beac06cd135e731b8a74'
    '018b4c028a16bc06bb007cb80102cd137202eb05bed306eb14813efe7d55aa75098a16bc'
    '06ea007c0000bee506ac08c07409b40ebb0700cd10ebf2f4ebfd909010000100007c0000'
    '0000000000000000804e6f2061637469766520706172746974696f6e0d0a004469736b20'
    '72656164206572726f720d0a004e6f20626f6f74207369676e61747572650d0a')


def _verify_mbr(asm_path, bin_path):
    """Re-assemble mbr.asm and compare -- keeps MBR_CODE honest."""
    os.makedirs(os.path.dirname(bin_path), exist_ok=True)   # may run before DosImage
    run('nasm', '-f', 'bin', asm_path, '-o', bin_path)
    fresh = open(bin_path, 'rb').read()
    assert len(fresh) == 446, len(fresh)
    if fresh != MBR_CODE.ljust(446, b'\0'):
        sys.exit('MBR_CODE in dosimg.py does not match a fresh nasm build of '
                 f'{asm_path} -- update the constant.')
    print('MBR verified against nasm build of', asm_path)
