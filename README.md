# F030F29 — F29 Retaliator für Atari Falcon030

Portierung des DOS-Spiels *F29 Retaliator* (Digital Image Design / Ocean, 1990)
auf den Atari Falcon030.

## Projektentscheidungen

| Thema | Entscheidung |
|---|---|
| Ansatz | 1:1-Port via Reverse Engineering — `X.EXE` wird disassembliert und die x86-Realmode-Logik funktionsweise nach 68030 übersetzt |
| Sprache | Reines 68030-Assembler (vasm, Motorola-Syntax) + DSP56001-Assembler |
| Grafikmodus | 320x240, True Color (16 Bit, 2 Byte/Pixel) |
| Zielhardware | Standard-Falcon030, 16 MHz, 4 MB, ohne FPU |

Der Rasterizer ist so gegliedert, dass ein späterer Wechsel auf 8 Bit + C2P eine
lokalisierte Änderung bleibt (siehe [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

## Ausgangsmaterial

`assets/F29_Retaliator_1990.zip` enthält zu ~95 % eine DOSBox-Distribution. Das
eigentliche Spiel sind drei Dateien in `F29Retal/Retal/` — zusammen ~670 KB:

| Datei | Größe | Inhalt |
|---|---|---|
| `X.EXE` | 68.640 B | DOS-MZ-Realmode-Executable, ungepackt, 68.128 B Code+Daten, 4 Relocations. Alle UI-Texte im Klartext ab Offset `0x30A3` |
| `RETAL.00` | 239.200 B | Daten, Entropie 5,76 — keine Strings |
| `RETAL.01` | 359.172 B | Daten, Entropie 5,53 — keine Strings |

Die vorliegende Kopie ist ein Crack-Release. Original-Assets werden deshalb
**nicht** mit ausgeliefert: die Engine lädt `RETAL.00`/`RETAL.01` zur Laufzeit,
Nutzer müssen ihre eigene Kopie mitbringen — Vorgehen wie bei OpenTTD oder
Devilution.

## Bauen

```bash
./tools/build-run.sh
```

Erzeugt `release/f29.tos` (gestrippt) und `release/f29_d.tos` (mit Symbolen).

```bash
./tools/build-dsp.sh
```

Assembliert `src/dsp/*.asm` nach `release/*.lod`. Braucht DOSBox Staging, weil
ASM56000 ein DOS4GW-Programm ist.

```bash
./tools/run.sh
```

Startet den Build in Hatari (Falcon, DSP-Emulation, TOS 4.02).

## Toolchain

Alle Werkzeuge sind bereits auf diesem Rechner vorhanden und werden aus den
Nachbarprojekten referenziert — es wird nichts nachinstalliert:

| Werkzeug | Pfad |
|---|---|
| vasm (m68k/mot) | `C:/Arbeit/F030Arcade/third_party/vasm/vasmm68k_mot.exe` |
| vlink | `C:/Arbeit/F030Arcade/third_party/vlink/vlink.exe` |
| ASM56000 (DSP) | `C:/Arbeit/f030dsp3d/tools/asm56k/` (via DOSBox Staging) |
| Hatari | `C:/Arbeit/F030Arcade/third_party/hatari/build-ucrt64/src/hatari.exe` |
| TOS 4.02 ROM | `C:/Arbeit/f030dsp3d/tools/tos402.rom` |

`make` ist auf diesem Rechner nicht installiert — der Build läuft über
Bash-Skripte, wie in `f030dsp3d`.

## Verzeichnisse

```
assets/     DOS-Original (unverändert) + extrahierte Rohdateien
docs/       Architektur, RE-Notizen
re/         RE-Artefakte: Disassembly-Listings, Symbolkarten
src/        68030-Assembler
src/dsp/    DSP56001-Assembler
tools/re/   Reverse-Engineering-Werkzeuge (Python)
tools/      Build- und Runner-Skripte
build/      Objektdateien
release/    Fertige .TOS und .LOD
```
