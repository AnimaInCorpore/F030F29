#!/usr/bin/env python3
"""Recursive-descent disassembler for the X.EXE real-mode load module.

Addresses are (segment, offset) pairs throughout.  Near branches wrap inside
their 64 KB segment, so the target has to be masked to 16 bits relative to the
segment the instruction lives in - disassembling on a flat linear address gets
this wrong.  X.EXE is one segment at 0000 plus a 2592 byte tail at 1000.

Recursive descent deliberately does not guess: it follows only control flow it
can prove, and reports what it could not reach.  Indirect jumps (jump tables,
computed calls, the far-call dispatch vectors) leave gaps - those are listed at
the end so they can be seeded by hand via --seed SEG:OFF.
"""
import argparse
import re
import struct
import sys
from collections import defaultdict

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16, CS_AC_WRITE
    from capstone.x86 import X86_OP_IMM, X86_OP_REG
except ImportError:
    sys.exit("capstone is required: python -m pip install capstone")

# Routines that consume a string placed inline after the call site.  They do
# `pop si` to get the return address as a string pointer and `jmp si` to resume
# past the terminator (a byte with bit 7 set).  See re/seeds.txt.
INLINE_STRING_ROUTINES = (0x5B4C, 0x5B51, 0x5B56, 0x5B62)

# Routines that consume a FIXED-length record placed inline after the call
# site, rather than a terminator-scanned string.  0x6680 does `pop si / lodsw
# / lodsw / lodsb / lodsw` - a 2+2+1+2 = 7 byte record - before continuing.
# See docs/GAME-LOOP.md, the state-handler section.
INLINE_RECORD_ROUTINES = {0x6680: 7}

TERMINATORS = {"ret", "retf", "iret", "iretd", "jmp", "ljmp", "hlt"}
UNCONDITIONAL = {"jmp", "ljmp"}
CONDITIONAL = {
    "ja", "jae", "jb", "jbe", "jc", "jcxz", "je", "jecxz", "jg", "jge", "jl",
    "jle", "jna", "jnae", "jnb", "jnbe", "jnc", "jne", "jng", "jnge", "jnl",
    "jnle", "jno", "jnp", "jns", "jnz", "jo", "jp", "jpe", "jpo", "js", "jz",
    "loop", "loope", "loopne", "loopnz", "loopz",
}
CALLS = {"call", "lcall"}
FAR = {"lcall", "ljmp"}
# Opcodes that essentially never appear in hand-written game code.  Used to
# reject byte-scan candidates that are really data.
JUNK_OPS = {"aaa", "aad", "aam", "aas", "daa", "das", "into", "salc", "hlt",
            "arpl", "bound", "lock", "in", "out", "iret", "sahf", "lahf"}
# Registers this program genuinely uses to hold a function pointer.  See
# resolve_register_calls for why the list is this short.
FUNCTION_POINTER_REGS = {"bp"}

# Regions proven to be data elsewhere in the analysis (see docs/RE-NOTES.md and
# docs/ARCHIVE-FORMAT.md).  Anything that widens the sweep has to leave these
# alone; if the disassembler starts "reaching" them it is manufacturing code out
# of data and the extra coverage is worthless.  The keyboard tables at 0x2E8F
# are reached even by the plain descent and are a known, pre-existing exception.
KNOWN_DATA = {
    0x143A: "sine table, 1024 words",
    0x2E8F: "keyboard tables",
    0x30A3: "copy-protection text",
    0x802E: "status/message text pool",
    0x5485: "manoeuvre envelope, 10 x 8",
    0x54D5: "speed envelope, reference/minimum, 9 x 8",
    0x551D: "speed envelope, ceiling, 9 x 8",
    0x5BF0: "token phrase pool",
    0x5CC0: "token table",
    0x734A: "base names",
    0x8D62: "call signs",
    0xFC00: "EGA palette",
    0xFC16: "segment table",
    0xFC4A: "archive index RETAL.00",
    0xFC8E: "archive index RETAL.01",
}
EXPECTED_DATA_HITS = {0x2E8F}
FAR_IMM = re.compile(r"^\s*(0x[0-9a-f]+)\s*:\s*(0x[0-9a-f]+)\s*$", re.I)


class Addr(tuple):
    """(segment, offset), ordered and hashable, with a linear view."""
    __slots__ = ()

    def __new__(cls, seg, off):
        return super().__new__(cls, (seg & 0xFFFF, off & 0xFFFF))

    @property
    def seg(self):
        return self[0]

    @property
    def off(self):
        return self[1]

    @property
    def linear(self):
        return (self[0] << 4) + self[1]

    def __str__(self):
        return f"{self[0]:04X}:{self[1]:04X}"


class Disassembler:
    def __init__(self, image: bytes):
        self.image = image
        self.md = Cs(CS_ARCH_X86, CS_MODE_16)
        self.md.detail = True
        self.insns = {}                     # Addr -> capstone insn
        self.xrefs = defaultdict(set)       # Addr -> {Addr, ...}
        self.call_targets = set()
        self.indirect = []                  # (Addr, mnemonic, op_str)
        self.interrupts = defaultdict(set)
        self.far_refs = set()               # far pointers seen as immediates
        self.strings = {}                   # start Addr -> end Addr of inline strings/records
        self.inline_string_routines = {Addr(0, o) for o in INLINE_STRING_ROUTINES}
        self.inline_record_routines = {Addr(0, o): n for o, n in INLINE_RECORD_ROUTINES.items()}

    def _read(self, addr: Addr, n: int = 16) -> bytes:
        return self.image[addr.linear:addr.linear + n]

    def run(self, seeds: list[Addr]) -> None:
        worklist = list(seeds)
        while worklist:
            addr = worklist.pop()
            regs = {}                       # reg -> immediate, for `mov r,imm / jmp r`
            while True:
                if addr in self.insns or not (0 <= addr.linear < len(self.image)):
                    break
                decoded = next(self.md.disasm(self._read(addr), addr.off, 1), None)
                if decoded is None:
                    break
                self.insns[addr] = decoded
                mnem = decoded.mnemonic

                if mnem == "int":
                    try:
                        self.interrupts[int(decoded.op_str, 0)].add(addr)
                    except ValueError:
                        pass

                target = self._target(addr, decoded, regs)
                if mnem in CALLS or mnem in CONDITIONAL or mnem in UNCONDITIONAL:
                    if target is None:
                        self.indirect.append((addr, mnem, decoded.op_str))
                    else:
                        self.xrefs[target].add(addr)
                        if mnem in CALLS:
                            self.call_targets.add(target)
                        if mnem in FAR:
                            self.far_refs.add(target)
                        if target not in self.insns and 0 <= target.linear < len(self.image):
                            worklist.append(target)

                if mnem in TERMINATORS:
                    break
                if mnem == "int" and decoded.op_str.strip() == "0x20":
                    break

                self._track_regs(decoded, regs)
                nxt = Addr(addr.seg, addr.off + decoded.size)

                # Inline-string idiom: the callee pops the return address as a
                # string pointer and resumes past the terminator, so execution
                # continues after the string, not after the call.
                if mnem == "call" and target in self.inline_string_routines:
                    end = self._skip_string(nxt)
                    if end is not None:
                        self.strings[nxt] = end
                        nxt = end
                    else:
                        break
                # Same idiom, but the callee consumes a fixed-length record
                # instead of scanning for a terminator.
                elif mnem == "call" and target in self.inline_record_routines:
                    end = Addr(nxt.seg, nxt.off + self.inline_record_routines[target])
                    self.strings[nxt] = end
                    nxt = end
                addr = nxt

    def reset(self) -> None:
        """Clear analysis state but keep the learned inline-string routines."""
        self.insns.clear()
        self.xrefs.clear()
        self.call_targets.clear()
        self.indirect.clear()
        self.interrupts.clear()
        self.far_refs.clear()
        self.strings.clear()

    def run_to_fixpoint(self, seeds: list[Addr], max_passes: int = 8,
                        scan_calls: int = 0) -> int:
        """Alternate descent and inline-string detection until nothing new.

        An unrecognised inline-string routine derails the sweep into the string
        bytes, so each newly detected one typically unlocks further code, which
        may in turn reveal more such routines.

        With scan_calls set, byte-scanned call targets are added to the seed
        set as well; the value is the minimum number of call sites a target
        needs before it is trusted.
        """
        seeds = list(seeds)
        if scan_calls:
            seeds.extend(self.scan_call_targets(min_sites=scan_calls))
        passes = 0
        while passes < max_passes:
            passes += 1
            self.reset()
            self.run(seeds)
            found = self._detect_inline_string_routines()
            new = found - self.inline_string_routines
            extra = self.resolve_register_calls() - set(seeds)
            if not new and not extra:
                break
            self.inline_string_routines |= new
            seeds.extend(extra)
        return passes

    def _detect_inline_string_routines(self) -> set:
        """Call targets whose call sites are consistently followed by text.

        A routine taking an inline string is called from many places, and at
        every one of them the following bytes are a high-bit-terminated string.
        That pattern does not occur by chance across several call sites.

        The scan is over raw bytes, not over discovered call sites: a routine
        we have not reached yet is exactly the one worth detecting, and relying
        on the descent to find it first would be circular.
        """
        sites_by_target = defaultdict(list)
        for pos in range(len(self.image) - 2):
            if self.image[pos] != 0xE8:                  # call rel16
                continue
            rel = struct.unpack_from("<h", self.image, pos + 1)[0]
            seg = 0 if pos < 0x10000 else TAIL_SEGMENT
            base = pos - (seg << 4)
            sites_by_target[Addr(seg, base + 3 + rel)].append(Addr(seg, base + 3))

        found = set()
        for target, sites in sites_by_target.items():
            if len(sites) < 3:
                continue
            good = sum(1 for s in sites if self._looks_like_string(s))
            if good >= max(3, int(len(sites) * 0.8)):
                found.add(target)
        return found

    def scan_call_targets(self, min_sites: int = 1, probe: int = 10) -> set:
        """Byte-scan the image for `call rel16` targets that look like code.

        Recursive descent only finds a routine once something reaches it, so a
        function whose only callers sit in unreached code stays invisible even
        though its call sites are plainly there in the bytes.  Scanning for the
        call encoding directly breaks that circle.

        Every candidate is probed before being accepted: disassembling from it
        has to yield `probe` instructions with no decode failure and no opcode
        that real program text does not contain.  Raising min_sites to 2 asks
        for corroboration from a second call site, which trades reach for
        certainty.
        """
        sites = defaultdict(int)
        for pos in range(len(self.image) - 2):
            if self.image[pos] != 0xE8:
                continue
            rel = struct.unpack_from("<h", self.image, pos + 1)[0]
            seg = 0 if pos < 0x10000 else TAIL_SEGMENT
            sites[Addr(seg, (pos - (seg << 4)) + 3 + rel)] += 1

        accepted = set()
        for target, count in sites.items():
            if count < min_sites or not 0 <= target.linear < len(self.image):
                continue
            if self._probe_code(target, probe):
                accepted.add(target)
        return accepted

    def resolve_register_calls(self) -> set:
        """Targets for `call reg` / `jmp reg`, from immediates loaded into reg.

        Eleven `call bp` sites survive the descent because the register is
        loaded in a different basic block than the call, so the intra-run
        constant propagation never sees it.  The inference that works is the
        other way round: if the program loads a constant into bp anywhere and
        elsewhere does `call bp`, that constant is a function entry.

        Only bp qualifies, and the restriction is not cosmetic - it was
        measured.  Admitting bx as well takes coverage from 41.8 % to 48.5 %
        but drags in five regions that are provably data, including both
        archive indices; adding di brings in the EGA palette and the segment
        table too.  The reason is that those registers hold data pointers in
        most contexts, so `mov si, 0xFC00` (the palette) would be seeded as
        code merely because `jmp si` occurs elsewhere - and that `jmp si` is
        the inline-string return, not a function pointer at all.
        """
        indirect_regs = {ops.strip() for _, mnem, ops in self.indirect
                         if ops.strip() in FUNCTION_POINTER_REGS}
        if not indirect_regs:
            return set()

        found = set()
        for addr, insn in self.insns.items():
            if insn.mnemonic != "mov" or len(insn.operands) != 2:
                continue
            dst, src = insn.operands
            if dst.type != X86_OP_REG or src.type != X86_OP_IMM:
                continue
            if insn.reg_name(dst.reg) not in indirect_regs:
                continue
            target = Addr(addr.seg, src.imm & 0xFFFF)
            if 0 <= target.linear < len(self.image) and self._probe_code(target, 10):
                found.add(target)
        return found

    def _probe_code(self, addr: Addr, want: int) -> bool:
        """True if `want` instructions decode cleanly from addr."""
        window = self.image[addr.linear:addr.linear + want * 8]
        decoded = list(self.md.disasm(window, addr.off, want))
        if len(decoded) < want:
            return False
        return not any(i.mnemonic in JUNK_OPS for i in decoded)

    def _looks_like_string(self, start: Addr, minlen: int = 3, maxlen: int = 200) -> bool:
        pos, n = start.linear, 0
        while pos < len(self.image) and n < maxlen:
            b = self.image[pos]
            c = b & 0x7F
            if not (32 <= c < 127 or c in (9, 10, 13)):
                return False
            n += 1
            if b & 0x80:
                return n >= minlen
            pos += 1
        return False

    def _skip_string(self, start: Addr) -> Addr | None:
        """End of a high-bit-terminated inline string, or None if unterminated."""
        pos = start.linear
        limit = min(pos + 512, len(self.image))
        while pos < limit:
            if self.image[pos] & 0x80:
                return Addr(start.seg, start.off + (pos - start.linear) + 1)
            pos += 1
        return None

    @staticmethod
    def _track_regs(insn, regs: dict) -> None:
        """Track `mov reg, imm`; forget a register on any other write to it."""
        ops = insn.operands
        if insn.mnemonic == "mov" and len(ops) == 2 and ops[1].type == X86_OP_IMM:
            if ops[0].type == X86_OP_REG:
                regs[insn.reg_name(ops[0].reg)] = ops[1].imm & 0xFFFF
                return
        for op in ops:
            if op.type == X86_OP_REG and op.access & CS_AC_WRITE:
                regs.pop(insn.reg_name(op.reg), None)

    def _target(self, addr: Addr, insn, regs: dict | None = None) -> Addr | None:
        """Resolve a direct branch target, or None when indirect."""
        if insn.mnemonic in FAR:
            m = FAR_IMM.match(insn.op_str)
            if m:
                return Addr(int(m.group(1), 16), int(m.group(2), 16))
            return None                     # lcall [mem] etc.
        if not insn.operands:
            return None
        # `mov ax,imm / jmp ax` - constant propagation resolves these.
        if regs and insn.operands[0].type == X86_OP_REG:
            if insn.mnemonic in CALLS | CONDITIONAL | UNCONDITIONAL:
                name = insn.reg_name(insn.operands[0].reg)
                if name in regs:
                    return Addr(addr.seg, regs[name])
            return None
        if insn.operands[0].type != X86_OP_IMM:
            return None
        # Near branch: capstone computed off + rel without wrapping, so mask
        # back into the segment the instruction lives in.
        return Addr(addr.seg, insn.operands[0].imm & 0xFFFF)

    def coverage(self):
        """Bytes accounted for, and the runs we never reached.

        Inline strings count as accounted for - they are identified data, not
        an unexplored gap.
        """
        spans = [(a.linear, a.linear + i.size) for a, i in self.insns.items()]
        spans += [(a.linear, e.linear) for a, e in self.strings.items()]
        spans.sort()
        covered, gaps, prev_end = 0, [], 0
        for lo, hi in spans:
            if lo > prev_end:
                gaps.append((prev_end, lo - prev_end))
            covered += max(0, hi - max(lo, prev_end))
            prev_end = max(prev_end, hi)
        if prev_end < len(self.image):
            gaps.append((prev_end, len(self.image) - prev_end))
        return covered, gaps

    def listing(self, out) -> None:
        labels = {}
        for target in sorted(self.xrefs):
            prefix = "sub" if target in self.call_targets else "loc"
            labels[target] = f"{prefix}_{target.seg:04X}_{target.off:04X}"

        prev_end = None
        for addr in sorted(self.insns):
            insn = self.insns[addr]
            lin = addr.linear
            if prev_end is not None and lin != prev_end:
                out.write(f"\n; ---- {lin - prev_end} bytes not reached ----\n\n")
            if addr in labels:
                refs = " ".join(str(r) for r in sorted(self.xrefs[addr])[:6])
                more = "" if len(self.xrefs[addr]) <= 6 else f" (+{len(self.xrefs[addr]) - 6})"
                out.write(f"\n{labels[addr]}:\t\t\t; xrefs: {refs}{more}\n")
            target = self._target(addr, insn)
            comment = f"\t; -> {labels[target]}" if target in labels else ""
            out.write(
                f"{addr}  {insn.bytes.hex():<16}  {insn.mnemonic:<7} {insn.op_str}{comment}\n"
            )
            prev_end = lin + insn.size

            nxt = Addr(addr.seg, addr.off + insn.size)
            if nxt in self.strings:
                end = self.strings[nxt]
                raw = self.image[nxt.linear:end.linear]
                text = "".join(chr(b & 0x7F) if 32 <= (b & 0x7F) < 127 else f"\\x{b:02x}"
                               for b in raw)
                out.write(f"{nxt}  {len(raw):>3} bytes         db      '{text}'\n")
                prev_end = end.linear


def parse_addr(text: str) -> Addr:
    if ":" in text:
        seg, off = text.split(":", 1)
        return Addr(int(seg, 16), int(off, 16))
    return Addr(0, int(text, 16))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("exe", nargs="?", default="assets/extracted/F29Retal/Retal/X.EXE")
    ap.add_argument("-o", "--out", default="re/listings/x.lst")
    ap.add_argument("--seed", action="append", default=[],
                    help="extra entry point as SEG:OFF hex (repeatable)")
    ap.add_argument("--seeds", default="re/seeds.txt",
                    help="file of resolved indirect targets, one SEG:OFF per line")
    ap.add_argument("--callgraph", type=int, nargs="?", const=20, default=0,
                    metavar="N",
                    help="print the N routines that call the most others, with "
                         "their callers and callees. Finding the game loop by "
                         "hunting for tables does not work; the call graph "
                         "shows it structurally")
    ap.add_argument("--scan-calls", type=int, nargs="?", const=1, default=2,
                    metavar="MIN_SITES",
                    help="also seed byte-scanned call targets; the value is how "
                         "many call sites a target needs before it is trusted. "
                         "The default of 2 is the highest setting that leaves "
                         "every known data region alone; 1 reaches 66%% but "
                         "disassembles seven of them as code")
    args = ap.parse_args()

    file_seeds = []
    try:
        for line in open(args.seeds, encoding="utf-8"):
            line = line.split("#", 1)[0].strip()
            if line:
                file_seeds.append(parse_addr(line))
    except FileNotFoundError:
        pass

    data = open(args.exe, "rb").read()
    lastpage, pages = struct.unpack_from("<HH", data, 2)
    hdrsize = struct.unpack_from("<H", data, 8)[0] * 16
    imagesize = (pages - 1) * 512 + lastpage if lastpage else pages * 512
    image = data[hdrsize:imagesize]
    ip, cs = struct.unpack_from("<HH", data, 20)

    seeds = [Addr(cs, ip)] + [parse_addr(s) for s in args.seed] + file_seeds
    d = Disassembler(image)
    passes = d.run_to_fixpoint(seeds, scan_calls=args.scan_calls)

    covered, gaps = d.coverage()
    total = len(image)
    strbytes = sum(e.linear - a.linear for a, e in d.strings.items())
    print(f"load module {total} bytes, entry {seeds[0]}, {passes} passes")
    print(f"reached {len(d.insns)} instructions, {covered} bytes ({covered * 100 / total:.1f}% coverage)")
    print(f"call targets: {len(d.call_targets)}   branch targets: {len(d.xrefs)}")
    print(f"inline strings: {len(d.strings)} totalling {strbytes} bytes, "
          f"from {len(d.inline_string_routines)} routines")
    print("  " + " ".join(str(r) for r in sorted(d.inline_string_routines)))
    print()

    reached = set()
    for a, insn in d.insns.items():
        reached.update(range(a.linear, a.linear + insn.size))
    violations = [(off, name) for off, name in KNOWN_DATA.items()
                  if off in reached and off not in EXPECTED_DATA_HITS]
    if violations:
        print(f"WARNING: {len(violations)} known data regions were disassembled "
              f"as code - the extra coverage is not real")
        for off, name in sorted(violations):
            print(f"  {off:#06x}  {name}")
    else:
        print(f"data check: all {len(KNOWN_DATA) - len(EXPECTED_DATA_HITS)} "
              f"known data regions left alone")
    print()

    if d.interrupts:
        print("DOS/BIOS interrupts used")
        for num in sorted(d.interrupts):
            sites = sorted(d.interrupts[num])
            shown = " ".join(str(s) for s in sites[:8])
            more = "" if len(sites) <= 8 else f" (+{len(sites) - 8} more)"
            print(f"  int {num:#04x}  {len(sites):3d} sites: {shown}{more}")
        print()

    if d.indirect:
        counts = defaultdict(list)
        for addr, mnem, ops in d.indirect:
            counts[f"{mnem} {ops}"].append(addr)
        print(f"indirect control flow: {len(d.indirect)} sites, {len(counts)} distinct forms")
        for form, sites in sorted(counts.items(), key=lambda kv: -len(kv[1]))[:15]:
            shown = " ".join(str(s) for s in sites[:5])
            more = "" if len(sites) <= 5 else f" (+{len(sites) - 5})"
            print(f"  {len(sites):4d}x  {form:<28} at {shown}{more}")
        print()

    if args.callgraph:
        # Attribute every call to the routine it sits in.
        #
        # "The nearest call target at or below the site" is not good enough: the
        # last routine before a large unreached region then collects every call
        # site in that region, and the result is a confident-looking top entry
        # that is pure artefact. So an owner only extends over *contiguously
        # reached* instructions - a gap ends it, and sites past the gap belong
        # to nobody.
        owner_of = {}
        current = None
        prev_end = None
        for addr in sorted(d.insns, key=lambda a: a.linear):
            if prev_end is not None and addr.linear != prev_end:
                current = None                  # a gap: the routine ended
            if addr in d.call_targets:
                current = addr
            if current is not None:
                owner_of[addr] = current
            prev_end = addr.linear + d.insns[addr].size

        callees = defaultdict(set)
        for target in sorted(d.xrefs):
            if target not in d.call_targets:
                continue
            for site in d.xrefs[target]:
                insn = d.insns.get(site)
                if insn is None or insn.mnemonic not in CALLS:
                    continue
                owner = owner_of.get(site)
                if owner is not None and owner != target:
                    callees[owner].add(target)

        ranked = sorted(callees.items(), key=lambda kv: -len(kv[1]))
        print(f"call graph: {len(d.call_targets)} routines, "
              f"{sum(len(v) for v in callees.values())} edges")
        print(f"the {args.callgraph} routines that call the most others")
        print()
        for owner, targets in ranked[:args.callgraph]:
            callers = [c for c in d.xrefs.get(owner, ())
                       if d.insns.get(c) is not None
                       and d.insns[c].mnemonic in CALLS]
            print(f"  {owner}  calls {len(targets):2d}, called from {len(callers)}")
            shown = " ".join(str(t) for t in sorted(targets)[:10])
            print(f"      -> {shown}{' ...' if len(targets) > 10 else ''}")
        print()

    print(f"unreached regions ({len(gaps)} total, largest 15)")
    for start, size in sorted(gaps, key=lambda g: -g[1])[:15]:
        print(f"  linear {start:#07x}  {size:6d} bytes")

    with open(args.out, "w", encoding="utf-8") as fh:
        d.listing(fh)
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
