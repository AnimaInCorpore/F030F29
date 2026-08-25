#!/usr/bin/env python3
"""Byte-exact reassembly ratchet for F29's authoritative X.EXE.

The conservative recursive-descent map from :mod:`disasm` supplies candidate
instructions.  This harness emits a complete flat source file (MZ header,
load module, and tail), assembles it with NASM, compares every claimed
instruction at its intended file offset, and demotes only mismatches to raw
bytes.  The final whole-file SHA-256 is the invariant; the mnemonic byte count
is the useful score, not the proof by itself.

Generated output belongs under ``build/reasm`` and is ignored by the project.
No game data or generated listing is committed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

try:
    from capstone.x86 import X86_OP_IMM
except ImportError:
    X86_OP_IMM = 2

HERE = Path(__file__).resolve()
PROJECT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))

from disasm import (  # noqa: E402
    CALLS,
    CONDITIONAL,
    FAR,
    KNOWN_DATA,
    EXPECTED_DATA_HITS,
    Disassembler,
    Addr,
    parse_addr,
)

DEFAULT_EXE = PROJECT / "assets" / "extracted" / "F29Retal" / "Retal" / "X.EXE"
DEFAULT_OUT = PROJECT / "build" / "reasm"
AUTHORITATIVE_SHA256 = "e47717e4dc5f3903a45aa305a1839e21be0e030439984230513cac5ddd259b2c"

# NASM accepts the capstone spelling after the ptr token and segment colon are
# normalised.  The renderer deliberately stays small: unsupported or unusual
# encodings fall through to db and are still part of the byte-exact proof.
SEGMENT_MEMORY = re.compile(r"\b(cs|ds|es|ss|fs|gs):\[")
NUMBER = re.compile(r"^-?(?:0x[0-9a-f]+|[0-9]+)$", re.I)
ERROR_LINE = re.compile(r":(\d+):\s*(?:fatal )?error:", re.I)
ERROR_PAREN = re.compile(r"\((\d+)\):\s*(?:fatal )?error:", re.I)
LISTING_LINE = re.compile(r"^\s*(\d+)\s+([0-9A-F]{8})\s+((?:[0-9A-F]{2})+)")
LISTING_CONT = re.compile(r"^\s+([0-9A-F]{8})\s+((?:[0-9A-F]{2})+)")

BRANCHES = set(CALLS) | set(CONDITIONAL) | {"jmp", "ljmp"}


class Container:
    """The plain MZ envelope and its flat load-module image."""

    def __init__(self, data: bytes):
        self.data = data
        u16 = lambda off: struct.unpack_from("<H", data, off)[0]
        self.e_cblp = u16(0x02)
        self.e_cp = u16(0x04)
        self.e_crlc = u16(0x06)
        self.e_cparhdr = u16(0x08)
        self.e_ip = u16(0x14)
        self.e_cs = u16(0x16)
        self.e_lfarlc = u16(0x18)
        self.header_size = self.e_cparhdr * 16
        self.image_end = ((self.e_cp - 1) * 512 + self.e_cblp
                          if self.e_cblp else self.e_cp * 512)
        self.image = data[self.header_size:self.image_end]
        self.relocations = [
            struct.unpack_from("<HH", data, self.e_lfarlc + 4 * i)
            for i in range(self.e_crlc)
        ]
        self.entry = Addr(self.e_cs, self.e_ip)

    def check(self) -> None:
        if self.data[:2] != b"MZ":
            raise RuntimeError("authoritative input is not an MZ executable")
        if self.image_end != len(self.data):
            raise RuntimeError(
                f"unexpected appended data: MZ image ends at 0x{self.image_end:X}, "
                f"file is {len(self.data)} bytes"
            )
        reloc_end = self.e_lfarlc + self.e_crlc * 4
        if any(self.data[reloc_end:self.header_size]):
            raise RuntimeError("MZ header slack is not zero-filled")
        for off, seg in self.relocations:
            if self.header_size + (seg << 4) + off + 2 > self.image_end:
                raise RuntimeError(f"relocation target outside image: {seg:04X}:{off:04X}")


def read_seeds(path: Path) -> list[Addr]:
    seeds = []
    if not path.exists():
        return seeds
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            seeds.append(parse_addr(line))
    return seeds


def target_from_insn(d: Disassembler, addr: Addr, insn):
    """Return a direct branch target without resolving indirect transfers."""
    if insn.mnemonic in FAR:
        return d._target(addr, insn)
    if insn.mnemonic not in BRANCHES or not insn.operands:
        return None
    op = insn.operands[0]
    if op.type != X86_OP_IMM:
        return None
    return Addr(addr.seg, op.imm & 0xFFFF)


def branch_text(mnem: str, addr: Addr, size: int, target):
    """Translate one direct branch using the original 16-bit displacement.

    A flat source label has the wrong arithmetic when a real-mode branch wraps
    from offset Fxxx back to 0xxx.  ``$`` keeps NASM's calculation local while
    the explicit displacement preserves the segment-relative encoding.
    """
    if mnem == "ljmp":
        return None
    width = "short" if size == 2 else "near"
    if mnem in {"loop", "loope", "loopne", "loopz", "loopnz", "jcxz", "jecxz"}:
        width = "short"
    displacement = (target.off - (addr.off + size)) & 0xFFFF
    signed = displacement if displacement < 0x8000 else displacement - 0x10000
    if signed < 0:
        expression = f"$+{size}{signed}"
    else:
        expression = f"$+{size}+{signed}"
    return f"{mnem} {width} {expression}"


def to_nasm(d: Disassembler, addr: Addr, insn, labels: dict[Addr, str]):
    """Translate a capstone instruction, or return None for a db fallback."""
    mnem = insn.mnemonic
    op = insn.op_str.strip()
    target = target_from_insn(d, addr, insn)
    if mnem == "lcall" and target is not None:
        return f"call far {op}"
    if mnem == "ljmp" and target is not None:
        return f"jmp far {op}"
    if mnem in BRANCHES and target is not None and NUMBER.fullmatch(op):
        return branch_text(mnem, addr, insn.size, target)

    # Capstone's Intel syntax is close to NASM's, but NASM does not use ptr.
    op = re.sub(r"\b(byte|word|dword|qword|tbyte|fword) ptr\s+", r"\1 ", op)
    op = re.sub(r"\bptr\s+", "", op)
    op = SEGMENT_MEMORY.sub(r"[\1:", op)
    return f"{mnem} {op}".strip()


def db_lines(raw: bytes) -> list[str]:
    return ["    db " + ",".join(f"0x{b:02x}" for b in raw[i:i + 16])
            for i in range(0, len(raw), 16)]


def emit_source(c: Container, d: Disassembler, forced: set[int], path: Path):
    """Emit source and return claims and the claimed mnemonic-byte count."""
    insns = {c.header_size + addr.linear: (addr, insn)
             for addr, insn in d.insns.items()}
    labels = {
        addr: f"L_{c.header_size + addr.linear:05X}"
        for addr in d.xrefs
        if addr in d.insns
    }
    labels_at_file = {
        c.header_size + addr.linear: label for addr, label in labels.items()
    }
    # Any discovered entry is a hard boundary.  F29 has real jumps into the
    # middle of another decoded stream; emitting the earlier instruction would
    # hide the later label and claim the wrong instruction boundary.
    hard = set(insns)
    string_ranges = []
    for start, end in d.strings.items():
        lo = c.header_size + start.linear
        hi = c.header_size + end.linear
        string_ranges.append((lo, hi))

    lines = ["bits 16", "org 0"]
    claims = {}  # source line -> (file offset, original bytes)
    code_bytes = 0
    pending = bytearray()
    pc = 0

    def flush():
        nonlocal pending
        if pending:
            lines.extend(db_lines(bytes(pending)))
            pending = bytearray()

    def in_string(offset: int) -> bool:
        return any(lo <= offset < hi for lo, hi in string_ranges)

    while pc < len(c.data):
        if pc in labels_at_file:
            flush()
            lines.append(f"{labels_at_file[pc]}:")

        item = insns.get(pc)
        if item and pc not in forced and not in_string(pc):
            addr, insn = item
            end = pc + insn.size
            spans_entry = any(pc < entry < end for entry in hard)
            asm = None if spans_entry else to_nasm(d, addr, insn, labels)
            if asm:
                flush()
                lines.append(f"    {asm}")
                claims[len(lines)] = (pc, c.data[pc:end])
                code_bytes += insn.size
                pc = end
                continue

        pending.append(c.data[pc])
        pc += 1

    flush()
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return claims, code_bytes, len(lines)


def listing_bytes(path: Path) -> dict[int, bytes]:
    """Parse NASM's source-line keyed listing bytes."""
    out = {}
    last = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = LISTING_LINE.match(raw)
        if m:
            last = int(m.group(1))
            out[last] = bytes.fromhex(m.group(3))
            continue
        if last is not None:
            m = LISTING_CONT.match(raw)
            if m:
                out[last] += bytes.fromhex(m.group(2))
            else:
                last = None
    return out


def nasm_path() -> str:
    override = os.environ.get("NASM")
    if override:
        return override
    candidates = [
        "nasm",
        r"C:\msys64\mingw64\bin\nasm.exe",
        r"C:\msys64\usr\bin\nasm.exe",
    ]
    for candidate in candidates:
        if candidate == "nasm":
            if shutil.which(candidate):
                return candidate
        elif Path(candidate).exists():
            return candidate
    raise RuntimeError("NASM not found; set NASM to the executable path")


def assemble(src: Path, dst: Path, listing: Path):
    result = subprocess.run(
        [nasm_path(), "-f", "bin", "-o", str(dst), "-l", str(listing),
         "-Wno-label-redef-late", str(src)],
        capture_output=True, text=True,
    )
    return result.returncode == 0, result.stderr


def error_lines(stderr: str) -> set[int]:
    lines = {int(m.group(1)) for m in ERROR_LINE.finditer(stderr)}
    lines.update(int(m.group(1)) for m in ERROR_PAREN.finditer(stderr))
    return lines


def roundtrip(c: Container, d: Disassembler, outdir: Path, passes: int):
    src = outdir / "x.asm"
    binary = outdir / "x.rebuilt"
    listing = outdir / "x.lst"
    forced: set[int] = set()

    for attempt in range(1, passes + 1):
        claims, code_bytes, source_lines = emit_source(c, d, forced, src)
        ok, stderr = assemble(src, binary, listing)
        if not ok:
            bad = {claims[line][0] for line in error_lines(stderr) if line in claims}
            if not bad:
                raise RuntimeError(
                    "NASM error did not identify an instruction claim:\n" + stderr
                )
            forced.update(bad)
            print(f"pass {attempt}: demoted {len(bad)} NASM-error instruction(s)")
            continue

        emitted = listing_bytes(listing)
        mismatches = {
            addr for line, (addr, original) in claims.items()
            if emitted.get(line) != original
        }
        if mismatches:
            forced.update(mismatches)
            print(f"pass {attempt}: demoted {len(mismatches)} re-encoding mismatch(es)")
            continue

        rebuilt = binary.read_bytes()
        if rebuilt != c.data:
            first = next(
                (i for i, (a, b) in enumerate(zip(rebuilt, c.data)) if a != b),
                min(len(rebuilt), len(c.data)),
            )
            raise RuntimeError(
                f"all claimed lines match but whole file differs at 0x{first:X}; "
                f"rebuilt={len(rebuilt)} original={len(c.data)}"
            )
        return {
            "attempts": attempt,
            "forced": forced,
            "code_bytes": code_bytes,
            "source_lines": source_lines,
            "rebuilt_sha256": hashlib.sha256(rebuilt).hexdigest(),
        }

    raise RuntimeError(f"ratchet did not converge in {passes} passes")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("exe", nargs="?", type=Path, default=DEFAULT_EXE)
    ap.add_argument("--seeds", type=Path, default=PROJECT / "re" / "seeds.txt")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--scan-calls", type=int, default=2)
    ap.add_argument("--passes", type=int, default=32)
    args = ap.parse_args()

    data = args.exe.read_bytes()
    c = Container(data)
    c.check()
    actual = hashlib.sha256(data).hexdigest()
    print(f"input:  {args.exe}")
    print(f"sha256: {actual}{'  [authority]' if actual == AUTHORITATIVE_SHA256 else ''}")
    if actual != AUTHORITATIVE_SHA256:
        print("warning: input hash differs from the documented authority")

    d = Disassembler(c.image)
    seeds = [c.entry] + read_seeds(args.seeds)
    descent_passes = d.run_to_fixpoint(seeds, scan_calls=args.scan_calls)
    covered, gaps = d.coverage()
    reached = set()
    for addr, insn in d.insns.items():
        reached.update(range(addr.linear, addr.linear + insn.size))
    violations = [
        (off, name) for off, name in KNOWN_DATA.items()
        if off in reached and off not in EXPECTED_DATA_HITS
    ]
    print(f"descent: {len(d.insns)} instructions, {covered} bytes "
          f"({covered * 100 / len(c.image):.1f}%), {descent_passes} passes")
    print(f"gaps: {len(gaps)}; largest={max((n for _, n in gaps), default=0)} bytes")
    if violations:
        raise RuntimeError("known-data guard violated: " + ", ".join(
            f"0x{off:04X} {name}" for off, name in violations
        ))
    print(f"data guard: all {len(KNOWN_DATA) - len(EXPECTED_DATA_HITS)} guarded "
          "regions left alone")

    args.out.mkdir(parents=True, exist_ok=True)
    report = roundtrip(c, d, args.out, args.passes)
    jumped_into = []
    for target in sorted(d.xrefs, key=lambda a: a.linear):
        if target not in d.insns:
            continue
        for owner, insn in sorted(d.insns.items(), key=lambda item: item[0].linear):
            if owner == target:
                continue
            if owner.linear < target.linear < owner.linear + insn.size:
                jumped_into.append({
                    "target": f"{target.seg:04X}:{target.off:04X}",
                    "owner": f"{owner.seg:04X}:{owner.off:04X}",
                    "owner_bytes": insn.bytes.hex(),
                })
                break
    residue = [
        {"linear": start, "size": size}
        for start, size in sorted(gaps)
    ]
    machine_report = {
        "input": str(args.exe),
        "input_sha256": actual,
        "rebuilt_sha256": report["rebuilt_sha256"],
        "file_bytes": len(data),
        "header_bytes": c.header_size,
        "load_module_bytes": len(c.image),
        "descent_passes": descent_passes,
        "instructions": len(d.insns),
        "descent_covered_bytes": covered,
        "descent_gaps": residue,
        "largest_gap": max((size for _, size in gaps), default=0),
        "mnemonic_bytes": report["code_bytes"],
        "mnemonic_percent_whole_file": round(report["code_bytes"] * 100 / len(data), 3),
        "demoted_instruction_count": len(report["forced"]),
        "jump_into_middle_count": len(jumped_into),
        "jump_into_middle": jumped_into,
        "known_data_regions": len(KNOWN_DATA) - len(EXPECTED_DATA_HITS),
    }
    (args.out / "report.json").write_text(
        json.dumps(machine_report, indent=2) + "\n", encoding="utf-8"
    )
    (args.out / "residue.txt").write_text(
        "# Exact unreached runs in the conservative recursive-descent map.\n"
        "# Regenerate with: python tools/re/reasm.py\n" +
        "".join(f"0x{start:05X} {size}\n" for start, size in sorted(gaps)),
        encoding="utf-8",
    )
    print(f"ratchet: {report['attempts']} pass(es), "
          f"{report['code_bytes']} mnemonic bytes "
          f"({report['code_bytes'] * 100 / len(data):.1f}% whole file), "
          f"{len(report['forced'])} demoted instruction(s)")
    print(f"rebuilt: {report['rebuilt_sha256']}")
    print(f"jump-into-middle entries: {len(jumped_into)}")
    print(f"report:  {args.out / 'report.json'}")
    print(f"source:  {args.out / 'x.asm'}")
    print(f"gaps remain a worklist; use the listing only as generated output")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
