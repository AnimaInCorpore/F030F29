# F030F29 — working rules

## Goal

Recover the DOS game *F29 Retaliator* and port its observable behaviour to the
Atari Falcon030. The target is a semantic twin: instruction-for-instruction x86
translation is neither required nor sufficient.

## Authority and generated data

- The authoritative executable is the locally extracted
  `assets/extracted/F29Retal/Retal/X.EXE`, SHA-256
  `e47717e4dc5f3903a45aa305a1839e21be0e030439984230513cac5ddd259b2c`.
- Original and extracted game data are ignored and must never be committed.
- Generated listings, images and frames remain reproducible and ignored unless
  a document explicitly designates a small fixture.
- Record findings as `RESOLVED`, `PARTIALLY RESOLVED`, `IDENTIFIED` or `TBD`,
  with the invariant and verification scope that justify the status.

## Shared method

`../F030Method/METHOD.md` is authoritative. Work one vertical slice through
Decode → Disassemble + Prove → Understand → Port. Byte equality proves an
encoding or reconstruction; it does not by itself prove code classification,
runtime behaviour, or port fidelity. The generated `docs/CROSS-PROJECT.md`
contains transferable techniques for the eleven projects in the parent manifest.

For disassembly, seed only evidence-backed targets, keep proven data guarded,
and classify residue instead of treating all undecoded bytes as instructions.
Use the original DOS program as a runtime oracle and compare observable state
or output before declaring a Falcon path faithful.

Every active 68030/DSP translation must identify the authoritative source hash,
canonical DOS address or range, preserved contract and side effects, and an
evidence grade: `executed/content-matched`, `ratchet+guard`, or
`sweep-inferred`. Platform-only code must say `N/A - platform replacement`.

## Closed platform-substitution list

The current substitution surface is closed to these reviewed boundaries:

- TOS process startup, shutdown and exception restoration;
- VIDEL/framebuffer presentation and VBL publication;
- IKBD keyboard/joystick input;
- GEMDOS file access and Falcon memory ownership;
- DSP host-interface transport for geometry work;
- local data-cache/conversion tooling for DOS resource formats;
- Hatari/headless capture and diagnostic instrumentation.

Adding a category requires a documentation review against the DOS contract.
Everything else is translated or explicitly adapted and still owes the
original observable result.

## Build and verification

Use `tools/build-run.sh`, `tools/build-dsp.sh`, and the checks documented in
`docs/ENGINE.md`. Keep exact regeneration commands in the relevant document.
After shared-document or DOS-harness changes, run the parent generators rather
than editing generated copies locally.
