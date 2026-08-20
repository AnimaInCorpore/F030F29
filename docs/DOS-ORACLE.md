# The DOS oracle — running the original F29 headless

The port needs something to be checked *against*. This is that: a bootable
MS-DOS 6.22 disk image that runs the original `X.EXE` under QEMU with no
display, driven by a script and screenshotted on a schedule. Point it at the
same moment the Falcon build reaches and compare pictures.

It is the counterpart to `tools/grab-frame.sh`, which does the same for the
Hatari side.

**Status:** working. The title sequence, the Pilot Authorisation doc check and
the USAF Enrolment Databank have all been reached and captured headlessly.

## Use

```bash
python tools/dos/build_dos_hdd.py          # build img/f29.hdd (+ first boot)
python tools/dos/set_boot_mode.py f29      # choose what the image does on boot
python tools/dos/run_qemu.py --timeout 60 --shot 12 --shot 25
```

The game data is **not** in this repository. `build_dos_hdd.py` reads
`assets/extracted/F29Retal/Retal` by default; override with `F29_GAME`:

```bash
F29_GAME=/path/to/retal python tools/dos/build_dos_hdd.py
```

You also need the genuine MS-DOS 6.22 install floppies in
`img/Microsoft MS-DOS 6.22 Plus Enhanced Tools (3.5)/` (`Disk1.img` supplies
IO.SYS/MSDOS.SYS/COMMAND.COM and the boot record, `Disk2.img` HIMEM). Both
directories are gitignored.

Tools: mtools 4.0.49 and nasm 3.02 (`C:\msys64\mingw64\bin`), QEMU 11.1.0,
ffmpeg (PPM→PNG).

## What the game requires

| Requirement | Evidence |
|---|---|
| Must live in **`C:\RETAL`** | `READ1ST.INC`: "This game MUST be installed in a subdirectory named Retal off of the root directory"; `X.EXE` carries the literals `\RETAL` and `\RETAL\RETAL.LOG` |
| That directory must be **writable** | `RETAL.LOG` is rewritten in place |
| Conventional memory, nothing else | `X.EXE` is a plain 16-bit MZ (`e_minalloc 0x1000`, `e_maxalloc 0xFFFF` — it asks for every free paragraph) and contains **no** EMS/XMS strings |

So the runtime config is HIMEM + `DOS=HIGH` and *no* EMM386 — a memory manager
would only cost conventional RAM. Measured with `MEM /C` on the image:
**622 KB largest executable program**, DOS resident in the HMA.

`run.bat` in the game directory is a sound-selection menu that calls a `CONFIG`
utility which is not present in this copy; the modes here run `X.EXE` directly.
No sound card is configured (project-wide decision — this QEMU build has no
`-soundhw`).

## Boot modes (`tools/dos/set_boot_mode.py`)

| Mode | What the image does on boot |
|---|---|
| `bootstrap` | expand the KWAJ-compressed `.??_` DOS files with the genuine `EXPAND.EXE`, then `QUIT.COM` |
| `dos` | HIMEM + DOS=HIGH, `MEM /C` and `DIR C:\RETAL` into `C:\BOOT.LOG`, `QUIT.COM` |
| `f29` | `dos` + run `C:\RETAL\X.EXE` |
| `bare` | no CONFIG.SYS drivers at all (closest to a 1990 machine), then `X.EXE` |
| `shell` | `dos`, then a `C:\RETAL>` prompt for interactive use with a display |

Switching modes rewrites two files inside the image with mtools; it takes well
under a second, so iterate with it rather than rebuilding.

## Driving the game headlessly

`run_qemu.py` takes a schedule: `--key SEC:KEY` sends a key over QMP at SEC
seconds, `--shot SEC` grabs a screenshot. A sequence that reaches the pilot
screen from a cold boot:

```bash
python tools/dos/run_qemu.py --timeout 190 \
  --key 60:ret --key 70:spc --key 73:ret --key 85:ret \
  --shot 95  --key 100:a --key 102:ret \
  --shot 110 --key 115:1 --key 117:ret --shot 130
```

Timeline observed on this machine (QEMU `-cpu 486`, wall-clock, not exact):

| ≈ t | Screen |
|---|---|
| 12 s | Ocean logo |
| 25 s | F29 Retaliator title art |
| 45 s | credits (Jas. C. Brooke / Digital Image Design / © 1991 Ocean) |
| 95 s | **Pilot Authorisation** — the manual doc check |
| 110 s | USAF Enrolment Databank — pilot creation |

The doc check wants *a character and then Enter*, not Enter alone — this copy
accepts any answer (`INCFO.INC`: "you just hit any key and enter on the doc
check screen"). An empty field does nothing, which is why a bare `--key ret`
appears to hang.

Timings are wall-clock and will drift with host load; prefer `--shot` at several
points over betting on one exact instant.

## How the image is built

`tools/dos/dosimg.py` is shared verbatim with the sibling projects
(F030Underworld, F030Underworld2, F030TIE). It builds the filesystem with
mtools and installs the **genuine** MS-DOS 6.22 boot record, keeping only its
BPB replaced. Five invariants are asserted at build time, each of which was a
real failure first in the sibling projects:

1. **A hard disk needs an MBR partition table.** A "superfloppy" (FAT at LBA 0,
   no partition table) boots nothing *and* DOS gives it no drive letter.
2. **Use the genuine boot record** — mformat's own boot code hangs in QEMU.
3. **IO.SYS must be root entry 0, MSDOS.SYS entry 1**, IO.SYS contiguous: the
   boot record compares those two names literally and then reads three
   consecutive sectors without walking the FAT. Hence no `mformat -v LABEL`,
   which would spend entry 0 on a volume label.
4. **BPB `hidden` = partition start LBA**; total16/total32 describe the
   partition, not the disk.
5. **BPB CHS must match the emulator** — geometry is written to
   `img/f29.hdd.geom.json` and read back by the runner, never hardcoded.

`img/f29.hdd` is 16 MB: 33 cyl × 16 heads × 63 sect, one active type-06 FAT16
partition at LBA 63.

```
C:\ IO.SYS MSDOS.SYS COMMAND.COM QUIT.COM CONFIG.SYS AUTOEXEC.BAT
C:\DOS\    HIMEM.SYS MEM.EXE EXPAND DEBUG FDISK FORMAT ATTRIB SYS CHKDSK ...
C:\RETAL\  X.EXE RETAL.00 RETAL.01 RETAL.LOG *.INC READ.ME run.bat
```

### Why the first boot runs by itself

`HIMEM.SY_`, `EMM386.EX_`, `MEM.EX_` and friends ship **KWAJ-compressed**
(`4B 57 41 4A 88 F0 27 D1`, method `0x0003` = LZ+Huffman) — neither 7-Zip nor
mtools can read that. Instead of reimplementing the codec, the build copies the
`.??_` files plus the genuine `EXPAND.EXE` onto the image and boots it once to
expand them in place. `build_dos_hdd.py` does this automatically.

## Headless observation

The Windows QEMU build has **no working serial sink** (`-serial file:` leaves a
0-byte file). Three channels replace it:

1. **`C:\QUIT.COM` → isa-debug-exit.** Eight bytes — `mov dx,0F4h / mov al,0Ah /
   out dx,al / int 20h`. QEMU exits with code `(0x0A<<1)|1 = 21`, so the *guest*
   ends the run; any other exit means it hung or died. The trailing `INT 20h`
   makes the same `.COM` harmless on real hardware.
2. **Screenshots** over QMP `screendump` → PPM → PNG, which is what matters for
   a graphics-mode game.
3. **Guest files** read back with `mtype` — `AUTOEXEC.BAT` logs to `C:\BOOT.LOG`.
   Careful: `mtype` on a *missing* file dumps the raw image and looks like
   content; always check the exit status.

## Gotchas

- **mtools + Windows paths**: a trailing `C:\...` destination is read as a
  *drive letter* (`Drive 'C:' not supported`). Run mcopy with `cwd=` set and `.`
  as the destination; `-i` wants a Windows path, not an MSYS `/c/...` one.
- **`mformat -r` counts SECTORS, not entries** — `-r 32` = 512 root entries.
- **QEMU ≥ 6 rejects `cyls=`/`heads=`/`secs=` on `-drive`**; CHS geometry goes on
  `-device ide-hd`.
- **Python stdout is block-buffered when redirected** — run these with `python -u`
  or a hang leaves you an empty log.
- The QMP port is chosen fresh per run (`free_port()`), so runs in several of the
  sibling projects can overlap without fighting over one socket.
