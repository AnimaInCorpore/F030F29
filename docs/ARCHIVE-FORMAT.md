# Archivformat RETAL.00 / RETAL.01

Vollständig dekodiert und verifiziert. Extraktor: `tools/re/unpack.py`.

```bash
python tools/re/unpack.py --extract     # -> re/resources/
```

## Aufbau

Die Archive haben **keinen eigenen Header**. Der Index liegt in `X.EXE`.

Bei `0xD3A5` steht ein Wort-Array mit je einem Zeiger pro Archivdatei. Es hat
genau zwei Einträge — `0xD3A9` ist bereits der `int 21h`-Wrapper, das begrenzt
die Tabelle:

| Adresse | Wert | Archiv |
|---|---|---|
| `0xD3A5` | `0xFC4A` | `RETAL.00` |
| `0xD3A7` | `0xFC8E` | `RETAL.01` |

Jeder Zeiger führt auf ein Array aus **4-Byte-Einträgen**:

```
Byte 0..2   Dateioffset, 24 Bit little endian
Byte 3      Ressourcentyp
```

Die **Länge** einer Ressource ist `offset[i+1] - offset[i]`. Deshalb trägt jedes
Array einen zusätzlichen Sentinel-Eintrag, dessen Offset der Dateigröße
entspricht — und nur der begrenzt die Tabelle, eine Eintragszahl wird nirgends
gespeichert.

Beide Sentinels stimmen exakt:

| Archiv | Sentinel | Dateigröße | Ressourcen |
|---|---:|---:|---:|
| `RETAL.00` | 239.200 | 239.200 | 16 |
| `RETAL.01` | 359.172 | 359.172 | 19 |

Summe aller Ressourcen: 598.372 Byte = Summe beider Dateien. Keine Lücken,
keine Überlappungen.

## Ressourcennummern

Die vom Spiel verwendete Nummer ist 16 Bit (Loader bei `0xD2F0`):

```
D2F0  mov bx, <resnum>      ; Immediate wird von 0xD20F selbst beschrieben
D2F3  mov si, 0x01FF
D2F6  and si, bx            ; si = resnum & 0x1FF        -> Index
D2F8  xor bx, si            ; bx = resnum & 0xFE00
D2FA  xchg bl, bh           ; bx = (resnum & 0xFE00) >> 8 -> Archivauswahl
D2FC  shl si, 1
D2FE  shl si, 1             ; si = 4 * Index
D300  add si, [bx-0x2C5B]   ; + Zeiger aus der Tabelle bei 0xD3A5
D304  lodsw / mov dx,ax     ; dx  = Offset Bit 0..15
D307  lodsw                 ; al  = Offset Bit 16..23
D30A  mov cl, al            ; cx:dx = 24-Bit-Offset für LSEEK
D30C  mov [0xD2CF], ah      ; Typbyte -> Immediate von `mov bx,imm` bei 0xD2CE
```

- **Bits 0..8**: Index innerhalb des Archivs (max. 512 Ressourcen)
- **Bits 9..15**: Archivauswahl — `0x0000` = `RETAL.00`, `0x0200` = `RETAL.01`

Beispiel: `AX = 0x000F` → `RETAL.00`, Ressource 15.

## Ressourcentyp

Das Typbyte wird bei `0xD30C` **direkt in das Immediate** von `mov bx,imm` an
`0xD2CE` geschrieben, dort mit `and bl,0x0F / shl bl,1` maskiert und dispatcht
über die 7-Einträge-Tabelle bei `0xD43A`. Der Typ wählt also die
Nachbearbeitung beim Laden:

| Typ | Handler | Bedeutung |
|---|---|---|
| 0 | `0xD524` = `ret` | **keine Konvertierung**, Daten werden unverändert übernommen |
| 1 | `0xD448` | `cx` = 0x2000, Plane-Umbau |
| 2 | `0xD456` | |
| 3 | `0xD496` | Bitplane-Expansion über `mov bx,0x8000 / shl al,1 / rcr bx,1` |
| 4 | `0xD4C7` | |
| 5 | `0xD4F2` | |
| 6 | `0xD525` | Kette: `cx`=0x2000→`D448`, 0x2880→`D456`, 0x0800→`D448`, 0x3C00→`D496` |

Alle Handler prüfen `cs:[0xD5C8]` gegen 4 — das ist die Grafikadapterklasse.
Die Typen sind also **Pixelformat-Konvertierungen** für CGA / Tandy / EGA / VGA.

Für den Falcon-Port sind die Handler 1–6 damit weitgehend irrelevant: sie
erzeugen das Pixelformat einer PC-Grafikkarte. Interessant ist, welches
Quellformat sie *erwarten* — das ist das Format in der Datei.

## Ressourcenverzeichnis

### RETAL.00 — 239.200 Byte, 16 Ressourcen

| # | resnum | Offset | Länge | Typ |
|---:|---|---:|---:|---:|
| 0 | `0x0000` | 0 | 7.138 | 1 |
| 1 | `0x0001` | 7.138 | 21.268 | 1 |
| 2 | `0x0002` | 28.406 | 18.598 | 1 |
| 3 | `0x0003` | 47.004 | 3.214 | 3 |
| 4 | `0x0004` | 50.218 | 25.461 | 1 |
| 5 | `0x0005` | 75.679 | 19.423 | 1 |
| 6 | `0x0006` | 95.102 | 18.373 | 1 |
| 7 | `0x0007` | 113.475 | 30.530 | 1 |
| 8 | `0x0008` | 144.005 | 31.240 | 1 |
| 9 | `0x0009` | 175.245 | 8.222 | 1 |
| 10 | `0x000A` | 183.467 | 10.177 | 1 |
| 11 | `0x000B` | 193.644 | 8.205 | 2 |
| 12 | `0x000C` | 201.849 | 2.748 | 3 |
| 13 | `0x000D` | 204.597 | 14.483 | 4 |
| 14 | `0x000E` | 219.080 | 13.039 | 5 |
| **15** | `0x000F` | 232.119 | **7.081** | **0** |

### RETAL.01 — 359.172 Byte, 19 Ressourcen

| # | resnum | Offset | Länge | Typ |
|---:|---|---:|---:|---:|
| 0–3 | `0x0200`–`0x0203` | 0 | 17.452 / 22.541 / 23.622 / 23.428 | 6 |
| 4–7 | `0x0204`–`0x0207` | 87.043 | 30.862 / 27.243 / 22.163 / 27.106 | 1 |
| 8–15 | `0x0208`–`0x020F` | 194.417 | 13.207 / 40.092 / 20.793 / 13.051 / 3.711 / 2.382 / 4.499 / 5.559 | 0 |
| 16–18 | `0x0210`–`0x0212` | 297.711 | 21.353 / 18.894 / 21.214 | 1 |

## Das Overlay: RETAL.00 Ressource 15

Die einzige ausführbare Ressource. Sie wird beim Start nach Segmentslot 8
geladen (7.840 Byte Puffer, Ressource ist 7.081 Byte) und per
`lcall [0xFC14]` an Offset 0 aufgerufen. Der Einsprung ist ein
Lehrbuch-Treiberprolog:

```
0000  pushf
0001  push ds / bx / bp / es / cx / si / di
0008  mov  bx, cs
000A  mov  ds, bx
000C  mov  es, bx              ; DS = ES = CS, selbstgenügsam
000E  sub  bh, bh
0010  mov  bl, ah              ; AH = Funktionscode
0012  shl  bl, 1
0014  cld
0015  call word ptr [bx+0xC5E] ; Dispatch
```

Das bestätigt die aus den Aufrufstellen abgeleitete Konvention **`AH` =
Funktion, `AL` = Parameter**. Beobachtete Aufrufe: `0x06FF`, `0x0100`, `0x05A0`,
`0x0101`.

**Offen:** Die Sprungtabelle liegt nicht statisch bei Offset `0xC5E` — die Werte
dort sind keine gültigen Codezeiger, und eine Suche nach einem Lauf plausibler
Zeiger findet nur ein sich wiederholendes 4er-Datenmuster bei `0x18E4`. Das
Displacement wird also zur Laufzeit angepasst, oder `DS` zeigt beim Dispatch
nicht auf den Ressourcenanfang. Zu klären, bevor die 35 `lcall [0xFC14]`-Stellen
aufgelöst werden können (Task 8).

Die übrigen Typ-0-Ressourcen in `RETAL.01` sind **nicht** ausführbar — bei
Offset 0 steht dort kein sinnvoller Code. Typ 0 heißt „unverändert laden", nicht
„ist Code".

## Endianness und Ausrichtung für den 68030

Die Daten sind durchgehend x86-little-endian und byteweise gepackt. Der 68030
ist big-endian, und der 68000 trappt bei ungeraden Wort-/Langwortzugriffen —
der 68030 verzeiht sie, zahlt aber mit Takten.

Die Konvertierung gehört deshalb **offline in den Asset-Build**, nicht in die
Laufzeit. Vorbild ist `f030dsp3d/tools/wavefront2object.js`, das `.obj` in ein
68k-natives `.o3d` übersetzt.

Zu beachten:

- **Feldweise, nicht blind.** Ein pauschaler 16-Bit-Byteswap über eine ganze
  Ressource zerstört Bytefelder — Bitmaps, Text, RLE-Ströme, in denen die
  Bytefolge strukturell ist. Getauscht werden darf nur, was als Wort- oder
  Langwortfeld identifiziert ist. Das setzt voraus, dass das *innere* Format
  jeder Ressource bekannt ist — der Container allein reicht nicht.
- **Ausrichtung ist der zweite Gewinn.** Wortfelder auf gerade, Langwortfelder
  auf durch 4 teilbare Adressen legen. Das kostet etwas Platz und spart bei
  jedem Zugriff.
- **24-Bit-Offsets zu 32 Bit** aufweiten. Der 68030 hat keinen Vorteil von
  3-Byte-Feldern, und `move.l` ist ein Befehl statt drei.
- **Lizenzlage.** Konvertierte Assets dürfen nicht mitgeliefert werden, sonst
  wird das Originalmaterial weiterverbreitet. Der Konverter muss also auf dem
  Rechner des Nutzers laufen — beim Installieren oder beim ersten Start, mit
  Cache. Das erhält das „bring your own data"-Modell.
