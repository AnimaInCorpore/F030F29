# Inhaltsformate der Ressourcen

Aufbauend auf [ARCHIVE-FORMAT.md](ARCHIVE-FORMAT.md). Werkzeugkette:

```bash
python tools/re/unpack.py --extract        # Archiv -> re/resources/
python tools/re/decompress.py --write      # RLE   -> re/unpacked/
python tools/re/render.py re/unpacked/RETAL_00_01_t1.raw
```

## RLE-Kompression

**Jede** Ressource ist komprimiert. Der Entpacker bei `0xD409` läuft im Loader
vor dem Typ-Handler.

| Token | Bedeutung |
|---|---|
| `bb` (≠ `0x26`) | literales Byte |
| `26 00` | literales `0x26` |
| `26 nn` mit Bit 7 frei, dann `vv` | `(nn & 0x7F) + 2` mal `vv`, merkt `vv` |
| `26 nn` mit Bit 7 gesetzt | `(nn & 0x7F) + 2` mal den **zuletzt gemerkten** Wert |

Der gemerkte Wert startet bei 0 — die Routine lädt `bx` mit `0x0026`, um das
Escape-Byte in `bl` zu bekommen, und initialisiert `bh` dabei nebenbei.

Zwei Fallstricke, die beim Nachbau leicht danebengehen:

**Die Lauflänge ist `+2`, nicht `+1`.** Der Lauf-Pfad schreibt `cl` Bytes per
`rep stosb` (`0xD429`), eines bei `0xD42B`, und fällt dann durch das
flag-setzende `cmp` hindurch in den Literal-Store bei `0xD430`, der ein drittes
schreibt.

**`26 00` ist ein Sprung mitten in eine Instruktion.** `cmp ax, 0xC38A` bei
`0xD42D` sind die Bytes `3d 8a c3`; der Einsprung auf `0xD42E` führt `8a c3`
aus, also `mov al, bl`, und legt damit das Escape-Byte zum Schreiben bereit.

Verifikation: mit der `+2`-Korrektur entpacken zehn Ressourcen auf **exakt
32.000 Byte** = 320 × 200 × 4 bit. Mit `+1` lagen sie 300–600 Byte darunter.

## Typ-Handler

Der Typ aus dem Indexeintrag wählt die Nachbearbeitung (Tabelle bei `0xD43A`).
Alle Handler prüfen `cs:[0xD5C8]` — die Grafikadapterklasse — gegen 4.

| Typ | Handler | Wirkung |
|---|---|---|
| 0 | `0xD524` = `ret` | keine |
| 1 | `0xD448` | 4-Plane interleaved → chunky 4 bpp |
| 2 | `0xD456` | wie Typ 1, anderer Einsprung |
| 3 | `0xD496` | chunky 4 bpp → bit-interleaved, wortweise |
| 4 | `0xD4C7` | `0xD4F2` + Plane-Umordnung |
| 5 | `0xD4F2` | Typ 1 oder Plane-Umordnung, je nach Adapter |
| 6 | `0xD525` | Verbundressource, vier Abschnitte |

### Typ 1 — der Hauptfall

`0xD45E` liest **vier aufeinanderfolgende Bytes** und schiebt sie bitweise zu
Pixeln zusammen:

```
lodsw / xchg bx,ax      ; bl = Byte0, bh = Byte1
lodsw / mov dl,al       ; dl = Byte2, ah = Byte3
rol ax,1                ; Byte3 MSB -> Pixelbit 3
shl dl,1 / rcl al,1     ; Byte2 MSB -> Pixelbit 2
shl bh,1 / rcl al,1     ; Byte1 MSB -> Pixelbit 1
shl bl,1 / rcl al,1     ; Byte0 MSB -> Pixelbit 0
```

Vier aufeinanderfolgende Bytes sind also die vier Bitplanes **derselben acht
Pixel** — byte-interleaved planar, exakt die Anordnung des Atari ST. Der
Pixelwert ist `Byte3<<3 | Byte2<<2 | Byte1<<1 | Byte0`, MSB zuerst.

Auflösung **320 × 200, 16 Farben** = 32.000 Byte, bestätigt durch das
Videosetup bei `0x6388`:

```
6388  cmp byte [0xD5C8], 4
638D  jbe 0x63B8         ; Adapter <= 4 -> mov ax,9  (Tandy 320x200x16)
638F  mov ax, 0x000D     ; sonst BIOS-Modus 0Dh = EGA 320x200x16
6392  int 0x10
```

Verifiziert durch Rendern: `RETAL.00` Ressource 1 ist der Titelbildschirm,
Ressource 2 ein Pilotenporträt mit Helm und Sauerstoffmaske.

### Palette

Die Tabelle bei `0xFC00` ist `00 01 02 … 0f` — die **Identitätspalette**. Sie
wird von `0x626D` als 20 Register an Port `0x3C0` (Attribute Controller)
geschrieben, wobei Werte ≥ 8 um `ch` erhöht werden (EGA-Intensitätsbit).

Es gibt **keine** Schreibzugriffe auf den VGA-DAC (`0x3C8`/`0x3C9`) im
erreichten Code. Die Bilder verwenden damit die Standard-EGA-16-Farben-Palette.
Weitere Registertabellen: `0xFBF0` (Sequencer, Port `0x3C4`) und `0xFBF6`
(Graphics Controller, Port `0x3CE`).

### Typ 3

`0xD496` liest **ein Wort und schreibt ein Wort**. Es bildet `dx = ax << 4` und
verschachtelt dann in vier Durchgängen die MSBs von `al`, `dl`, `ah`, `dh` in
`bx`; die Schleife endet, wenn das Sentinel-Bit `0x8000` aus `bx` herausfällt,
also nach 16 Schiebeoperationen.

Das Quellformat ist damit **chunky 4 bpp**, zwei Pixel pro Byte — nicht planar.

### Typ 6 — Verbundressource

`0xD525` ruft vier Handler mit festen Längen auf:

| Abschnitt | Länge | Handler | Format |
|---:|---:|---|---|
| 1 | `0x2000` = 8.192 | `0xD448` | 4-Plane interleaved |
| 2 | `0x2880` = 10.368 | `0xD456` | 4-Plane interleaved |
| 3 | `0x0800` = 2.048 | `0xD448` | 4-Plane interleaved |
| 4 | `0x3C00` = 15.360 | `0xD496` | chunky 4 bpp |
| | **35.968** | | |

`RETAL.01` Ressourcen 2 und 3 entpacken auf **exakt 35.968 Byte**. Ressourcen 0
und 1 sind mit 18.560 bzw. 25.728 Byte kürzer — 18.560 entspricht genau
Abschnitt 1 + 2, sie nutzen also offenbar nicht alle Abschnitte.

Die Rohbytes bestätigen die Zuordnung. Abschnitt 1 zeigt durchgehend das Muster
`X ff X 00` — vier Planes, von denen zwei identisch und eine konstant sind.
Abschnitt 4 zeigt Bytepaare wie `1f 1f`, `c0 c0`, `07 07`, passend zum
Wort-Interleave.

## Ressourcenübersicht nach dem Entpacken

| Ressource | Typ | entpackt | Deutung |
|---|---:|---:|---|
| `RETAL.00` 1, 2, 4, 5, 6, 7 | 1 | **32.000** | Vollbilder 320×200 |
| `RETAL.01` 4, 5, 6, 7 | 1 | **32.000** | Vollbilder 320×200 |
| `RETAL.01` 16, 17, 18 | 1 | 21.760 | 320×136 |
| `RETAL.00` 0 | 1 | 9.120 | 320×57 |
| `RETAL.00` 9 | 1 | 13.312 | 256×104 |
| `RETAL.00` 8 | 1 | 50.048 | mehr als ein Bildschirm |
| `RETAL.01` 2, 3 | 6 | 35.968 | Verbund, alle vier Abschnitte |
| `RETAL.01` 0, 1 | 6 | 18.560 / 25.728 | Verbund, Teilmenge |
| `RETAL.01` 8–15 | 0 | 2.359–41.075 | **Spieldaten, unentschlüsselt** |
| `RETAL.00` 15 | 0 | 7.839 | Overlay-Code |

## Offen

- **Die Typ-0-Ressourcen in `RETAL.01` (8–15)** sind der eigentliche
  Spielinhalt: 3D-Modelle, Terrain, Missionen. Zusammen 105.032 Byte entpackt.
  Sie durchlaufen keinen Typ-Handler, ihr Format steht also nicht im Loader —
  es muss über die auswertenden Routinen erschlossen werden.
  Ressource 9 ist entschlüsselt, siehe [MODEL-FORMAT.md](MODEL-FORMAT.md).
- Die Abschnitte der Typ-6-Ressourcen ergeben bei 320 Pixeln Breite kein Bild.
  Eine Korrelationsanalyse liefert 16 Byte pro Zeile (90,4 %), also 32 Pixel
  breite Kacheln — als Kontaktbogen gerendert entsteht aber kein erkennbares
  Motiv. Vermutlich Sprites mit eigener Kopfstruktur.
- Die krummen Typ-1-Größen (9.120, 13.312, 50.048, 10.760) sind noch keiner
  Auflösung sicher zugeordnet.
