# Reassembly ratchet

**Status: RESOLVED (2026-08-24).** The authoritative `X.EXE` is reproduced
byte-for-byte from generated NASM source. This proves the selected instruction
encodings and boundaries where they are claimed; the independent data guard
still decides whether a byte range is code.

## Reproduce it

The input must be the locally supplied executable documented in
[`AGENTS.md`](../AGENTS.md). Run the conservative disassembly and then the
ratchet:

```text
python tools/re/disasm.py --scan-calls 2
python tools/re/reasm.py
```

The current authority is 68,640 bytes with a 512-byte MZ header and a 68,128-
byte load module:

```text
input:  sha256 e47717e4dc5f3903a45aa305a1839e21be0e030439984230513cac5ddd259b2c
rebuilt: sha256 e47717e4dc5f3903a45aa305a1839e21be0e030439984230513cac5ddd259b2c
```

The guarded descent reaches 14,569 instructions and 35,301 bytes (51.8% of
the load module), leaving 141 exact unreached runs; the largest is 4,254
bytes. All 14 guarded data regions remain untouched. The ratchet converges in
three passes: 2,521 candidates are retained as raw `db` fallbacks when NASM
cannot reproduce the original encoding, leaving 28,655 mnemonic bytes (41.7%
of the whole EXE).

Branches are emitted with `$`-relative displacements calculated from the
original segment offsets. This preserves 16-bit wraparound at the 64 KiB
boundary; flat labels alone would encode those branches incorrectly. The
harness also treats every discovered entry point as a hard boundary, recording
17 entries that land inside another decoded instruction instead of silently
swallowing them.

Generated source, listing, rebuilt binary, the exact residue inventory and a
machine-readable report are written below `build/reasm/`. They are derived
artifacts and remain uncommitted under the no-game-data rule.

## What remains open

The ratchet does not promote unresolved indirect targets. In particular, the
`0xD2DA` table entries at `0x04BA` and `0x04D5` still begin with `ICEBP` and
look more coherent one byte later. They remain explicitly unresolved rather
than being seeded merely because the generated source can encode either
interpretation. Runtime evidence or a structural caller proof is still needed.
