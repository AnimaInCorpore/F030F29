# Architektur

## Aufgabenteilung 68030 / DSP56001

Das Nachbarprojekt [`f030dsp3d`](../../f030dsp3d) enthält eine vollständige,
lauffähige 3D-Engine für den Falcon — eigener Code, Ursprung 1994. Sie wird als
Basis übernommen. Die Aufgabenteilung dort ist für einen Flugsimulator praktisch
ideal, weil nahezu die gesamte Geometriepipeline auf dem DSP liegt und der
68030 nur noch füllt.

### DSP56001 (32 MHz, 24-Bit-Festkomma)

Aus `f030dsp3d/src/3d.asm` (2591 Zeilen), Routinen in Pipeline-Reihenfolge:

| Stufe | Zeile | Aufgabe |
|---|---|---|
| Rotationsmatrizen | 2371 | Kamera-, Objekt- und kombinierte Matrix aus sin/cos-Tabelle |
| Rotate + Translate | 2546 | Punktearray transformieren |
| 3D-Clipping | 2002 | Polygone an der z-Ebene clippen |
| Zentralprojektion | 1936 | 3D → 2D, perspektivisch |
| BSP-Sortierung | 2201 | Flächensortierung über BSP-Baum |
| 2D-Clipping | 1108 | Sutherland-Hodgman, Ring-Buffer zwingend an `x:$0` |
| Polygonumwandlung | 1882 | Polygonstruktur für den Filler aufbereiten |
| LeftRight-Tabelle | 583 | Kantentabelle je Scanline — der 68030 bekommt fertige Spans |
| Texturgradienten | 884 | Gradienten einer Fläche im Bildschirmraum |

Der DSP liefert dem 68030 also **fertige Span-Listen**. Die CPU macht keine
Geometrie, keine Sortierung, kein Clipping.

Speicherlayout (DSP-SRAM, 32K Worte à 24 Bit):

```
p:$0       Reset-Vektor → main
p:$22      Host transmit data empty interrupt
x:$0       Ring-Buffer 2D-Clipping (30*2 Worte) — Adresse ist hardwareseitig fix
x:$200     Clip-Grenzen, Objektmatrix, Positionsvektoren
           array_2d_point / array_vector_point   (MAX_POINTS  = 2000, ×3)
           array_polygon_sorted                  (MAX_POLYGONS = 1000, ×7)
y:$800     Clip-Kanten, Screen-Offsets, Lichtvektor, Kamera, Betrachter,
           Objektkopf, sin/cos-Tabelle
```

Für F29 sind die Budgets zu prüfen: Terrain mit weiter Sichtweite erzeugt
deutlich mehr Polygone als das Einzelobjekt in `f030dsp3d`.

### 68030 (16 MHz)

Aus `f030dsp3d/src/dp_hc.s` (1037 Zeilen) und `dsp3d.s` (1172 Zeilen):

- **`draw_poly_hc_l`** — Span-Filler über den **Blitter**. Trick: `HOP=%01`
  (Quelle = Halftone-Register), `OP=%0011` (Ziel = Quelle), `Dst_Xinc=0`,
  `Dst_Yinc=2`, `X_Count=1`. Damit wird `Y_Count` zur Spanlänge, und der Blitter
  füllt einen horizontalen Lauf aus 16-Bit-Pixeln. Die Farbe steht im
  Halftone-Register. Bis zu 65535 Pixel pro Blit.
- **`draw_quad_tex` / `draw_poly_tex`** — texturierte Flächen, CPU-seitig.
- **Doppelpufferung** — `work_screen` / `display_screen` werden getauscht.
- **Dirty-Range-Clear** (`clear_screen4`) — `screen_low_high_work` merkt die
  berührte Min/Max-Adresse, gelöscht wird nur dieser Bereich. Bei einem
  Flugsimulator mit Himmel/Boden-Hintergrund ist das potenziell hinfällig, weil
  ohnehin flächendeckend überschrieben wird — messen.
- Tastatur, VBL, Objekt-Loader.

## Grafikmodus

Ziel ist **320x240 True Color**, `f030dsp3d` läuft auf 300x224 True Color. Der
Unterschied sind Konstanten an zwei Stellen:

- `src/dsp/3d.asm`: `SCREEN_WIDTH` / `SCREEN_HEIGHT`
- `src/dp_hc.s`: `SCREEN_WIDTH` / `SCREEN_HEIGHT`

### Bandbreite

Der wesentliche Engpass auf einem 16-MHz-Falcon ist der 16-Bit-ST-RAM-Bus, den
sich CPU, Blitter und VIDEL teilen. Der Bildschirmspeicher muss im ST-RAM
liegen, weil VIDEL nur von dort DMA machen kann; ein 4-MB-Falcon hat ohnehin
kein Fast-RAM.

| Modus | Bytes/Frame | VIDEL-Refresh bei 60 Hz |
|---|---|---|
| 320x240 True Color | 153.600 | ~9,2 MB/s |
| 300x224 True Color (f030dsp3d) | 134.400 | ~8,1 MB/s |
| 320x240, 8 Bit | 76.800 | ~4,6 MB/s |

True Color kostet also rund die doppelte Refresh-Bandbreite gegenüber 8 Bit,
spart im Gegenzug aber die C2P-Wandlung komplett ein und macht den Rasterizer
linear adressierbar.

### Rückfallebene 8 Bit

Falls die Framerate nicht reicht, soll der Wechsel auf 8 Bit + DSP-C2P lokal
bleiben. Dafür gilt:

- Pixelbreite nur über eine Konstante (`BYTES_PER_PIXEL`) ausdrücken, nie
  literal `2` im Code.
- Farbwerte über eine Indirektion (`colour_table`) statt direkter RGB-Werte im
  Halftone-Register.
- Der Blitter-Span-Filler funktioniert in 8 Bit nicht unverändert — planar. Die
  Filler-Schnittstelle (Eingabe: LeftRight-Tabelle vom DSP) bleibt aber gleich,
  nur die Implementierung dahinter tauscht.

## Build

Kein `make` auf diesem Rechner. Der Build läuft über Bash-Skripte wie in
`f030dsp3d`:

- `tools/build-run.sh` — vasm je Quelldatei, dann vlink → `.TOS`
- `tools/build-dsp.sh` — ASM56000 unter DOSBox (DOS4GW, braucht 8.3-Namen),
  danach CLDLOD → `.LOD`
- `tools/run.sh` — Hatari mit Falcon-Maschine und DSP-Emulation

vlink-Aufruf: `-tos-fastload -b ataritos -e start`, vasm: `-Felf -m68030`.
