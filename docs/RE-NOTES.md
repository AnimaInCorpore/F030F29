# Reverse-Engineering-Notizen: X.EXE

Werkzeuge in `tools/re/`:

```bash
python tools/re/mzinfo.py     # MZ-Header, Relocations, Segmentlayout
python tools/re/disasm.py     # rekursiver Disassembler -> re/listings/x.lst
python tools/re/codemap.py    # Code/Daten-Segmentierung per Fensteranalyse
```

## Umfang

| Datei | Größe | Code | Daten |
|---|---:|---:|---:|
| `X.EXE` (Load Module) | 68.128 B | **~50.976 B (74,8 %)** | ~17.152 B |
| `RETAL.00` | 239.200 B | — | 239.200 B |
| `RETAL.01` | 359.172 B | — | 359.172 B |

**Der gesamte Programmcode steckt in `X.EXE`** — rund **51 KB** x86-Realmode.
Bei gemessenen 2,14 Byte/Instruktion sind das grob **23.000–24.000
Instruktionen**.

`RETAL.00`/`.01` enthalten *keinen* Code. Die Fensteranalyse meldet zwar 11 %
bzw. 15 % „Code", aber kein einziger zusammenhängender Lauf ≥ 1 KB ist so
klassifiziert — verstreute 256-Byte-Fenster sind das Rauschmuster, nicht echter
Code. Die Opcode-Statistik bestätigt es:

| | `call` | `ret` | `mov r,rm` |
|---|---:|---:|---:|
| `X.EXE` | 1,91 % | 0,97 % | 1,98 % |
| `RETAL.00` | 0,29 % | 0,15 % | 0,14 % |
| `RETAL.01` | 0,23 % | 0,06 % | 0,09 % |

**Einschränkung dazu** (Befund aus der Dispatcher-Analyse, s. u.): die Aussage
gilt für die Dateien *wie gespeichert*. `RETAL.00`/`.01` sind ein
Ressourcenarchiv, und mindestens eine Ressource wird ausgeführt — der Loader
lädt Ressource 15 in einen 7.840-Byte-Puffer und ruft deren Offset 0 per
`lcall` auf. Die Dateien sind also ganz überwiegend Daten, enthalten aber
Overlay-Code. Die frühere Formulierung „reine Spieldaten" war zu absolut.

## Speicherlayout

Entry `0000:0000`. Die ersten 32 Byte bauen eine Segmenttabelle auf: ab `0xFC16`
stehen 9 Wörter mit *Größen* in Paragraphen, die Schleife bei `0x0012` rechnet
sie in-place in *Segmentbasen* um (`bx = [di]` lesen, `ax` schreiben,
`ax += bx`).

```
0000:0000  cli / cld
0000:0002  mov  dx, [2]          ; PSP: oberstes Speichersegment
0000:000C  mov  di, 0xFC16       ; Segmenttabelle, 9 Einträge
0000:000F  mov  cx, 9
0000:0012  mov  bx, [di] / stosw / add ax, bx / loop
0000:0019  mov  ss, [0xFC1C]     ; Stack aus Slot 3
0000:001D  mov  sp, 0xC00        ; 3 KB Stack
```

Ergebnis, relativ zur Ladeadresse:

| Slot | Basis | Größe | Zweck |
|---|---|---:|---|
| `FC16` | +0x0000 | — | Codesegment (= CS) |
| `FC18` | +0x0000 | 64 KB | Code/Daten |
| `FC1A` | +0x1000 | 64 KB | Rest-Segment (Ziel der 4 Relocations) |
| `FC1C` | +0x2000 | 64 KB | **Stack** (SP = 0xC00) |
| `FC1E` | +0x3000 | 63.360 B | Puffer |
| `FC20` | +0x3F78 | 12.000 B | Puffer |
| `FC22` | +0x4266 | 37.440 B | Puffer (`mov es,[0xFC22]` bei `0x0067`) |
| `FC24` | +0x4B8A | 36.096 B | Puffer |
| `FC26` | +0x5452 | 7.840 B | Puffer |
| Ende | +0x563C | | Gesamt **352.448 B** |

Die Puffer ab Slot 4 sind das Ziel für `RETAL.00`/`.01` — zusammen 156.736 Byte
Pufferfläche gegenüber 598.372 Byte Dateigröße, die Daten werden also
gestreamt oder entpackt, nicht komplett gehalten.

## Overlay-Dispatcher `lcall [0xFC14]`

35 Aufrufstellen. Der Far-Pointer wird zur Laufzeit gepatcht:

```
0000:0082  mov  dx, [0xFC26]         ; Zielsegment = Tabellenslot 8 (7.840 B)
0000:0086  mov  ax, 0x000F           ; Ressourcennummer 15
0000:0089  call 0xD20B               ; Loader
0000:008C  mov  ax, [0xFC26]
0000:0090  mov  word [0xFC14], 0     ; Offset := 0
0000:0096  mov  [0xFC16], ax         ; Segment := geladenes Segment
0000:0099  mov  ax, 0x06FF           ; Funktionscode
0000:009C  lcall far [0xFC14]        ; -> geladenes_segment:0000
```

`AX` ist ein Kommando in der Form AH = Funktion, AL = Parameter. Beobachtet:
`0x06FF`, `0x0100`, `0x05A0`, `0x0101`.

Der Loader bei `0xD20B` baut den Dateinamen dynamisch:

```
D22E  mov bl, [0xD2F2]     ; High-Byte der Ressourcennummer
D232  shr bl, 1
D239  mov al, bl
D23B  aam 0x0A             ; in zwei Dezimalziffern zerlegen
D23D  add ax, 0x3030       ; -> ASCII
D240  xchg al, ah
D242  mov [0xD3A2], ax     ; in "RETAL.00" einsetzen
D248  mov dx, 0xD395       ; -> "\RETAL", "RETAL.NN"
D24B  mov ax, 0x3D00       ; DOS open
```

`0xD3A2` ist exakt die Position der beiden Ziffern in `RETAL.00`. Damit ist
belegt: **`RETAL.NN` ist ein per Zweiziffern-Index adressiertes Ressourcenarchiv**,
und das High-Byte von `AX` wählt die Datei, das Low-Byte die Ressource darin.

Da dieser Dispatcher aus `X.EXE` herausführt, ist er von hier aus nicht weiter
auflösbar — er braucht zuerst das Archivformat (Task 3).

## Aufgelöste indirekte Sprünge

Alle Ziele liegen dokumentiert in [`re/seeds.txt`](../re/seeds.txt) und werden
von `disasm.py` automatisch eingelesen. Ergebnis: Abdeckung **8,2 % → 40,6 %**,
2.601 → 11.297 Instruktionen, 102 → 340 Call-Targets.

| Stelle | Art | Auflösung |
|---|---|---|
| `0xD2DA` | `call cs:[bx-0x2BC6]` | Tabelle `0xD43A`, **7 Einträge**. Alle Handler prüfen `cs:[0xD5C8]` gegen 4, `cx` = 0x2000/0x2880/0x0800/0x3C00 → **Pixelformat-Dispatcher** für CGA/Tandy/EGA/VGA, kein Entpacker |
| `0xD2EE` | `jmp ax` | `mov ax,0xD329` direkt davor — per Konstantenpropagation |
| `0x29D5` | `call [si]` | Tabelle `0x29EF`, bitweise durch `AL` gelaufen → max. 8 Einträge, **Subsystem-Init-Maske**. Bit 7 = `int 15h AX=C200`, PS/2-Maus |
| `0x5B8C` | `jmp ax` | Trampolintabelle **rückwärts** ab `0x5BE6`: Code 9 → `0x5BE6`, Code 0 → `0x5BD4` |
| `0x5B92` | `jmp bp` | Drei Glyphen-Renderer: `0x58FB`, `0x5852`, `0x599A` |
| `0xE4CC` | `jmp [bx]` | **Menü-Dispatcher**, Tabelle liegt inline hinter jeder Aufrufstelle. Drei Stellen gefunden: `0xC564` (7), `0xD754` (8), `0xE680` (7) |
| `0x8F26` | `call [bx-0x70C4]` | Basis `0x8F3C`, **4 Einträge** |
| `0xF263` | `call [bx-0x5929]` | Basis `0xA6D7`, **13 Einträge**, Index aus `[0xA720]` |

### Menü-Dispatcher im Detail

Das Muster wiederholt sich im ganzen Programm:

```
D74A  mov  cl, 8           ; Zahl der Menüpunkte
D74C  call 0xE49F          ; Taste lesen und prüfen
D74F  jae  0xD74A          ; ungültig -> nochmal
D751  call 0xE4C5          ; dispatchen
D754  dw   D872, E199, DC02, E106, DCB5, D766, E6F3, 74CA   ; inline
```

`0xE49F` liest eine Taste, rechnet `'1'..'9','0'` in Index 0..9 um (`sub al,0x30`,
`'0'` wird zu 10, dann `dec ax`) und prüft mit `cmp al,cl`. `0xE4C5` macht
`pop bx / add bx,ax / jmp [bx]` — die Rücksprungadresse *ist* die Tabellenbasis.

Tabellenlängen sind statisch belegbar: bei `0xC564` durch `jb 0xC572` an
`0xC55F` (macht `0xC572` zu Code), bei `0xE680` dadurch, dass ab `0xE68E` die
Inline-String-Routine beginnt, bei `0xD754` durch `mov cl,8`.

## Inline-String-Idiom

Der Hauptgrund für die anfangs niedrige Abdeckung war nicht die Sprungtabellen,
sondern dieses Muster: `call` auf eine Textroutine, direkt gefolgt vom String.
Die Routine holt mit `pop si` die Rücksprungadresse als Stringzeiger und kehrt
mit `jmp si` hinter das Stringende zurück. **Ende = Byte mit gesetztem Bit 7.**

```
5B59  pop  si              ; si = Rücksprungadresse = Stringzeiger
5B5A  call 0x5BCA
5B5D  call 0x5B6E          ; String abarbeiten
5B60  jmp  si              ; hinter dem String weiter
```

Wer das nicht kennt, disassembliert ab dem `call` in die Stringbytes hinein und
entgleist. `disasm.py` erkennt solche Routinen selbst: es scannt das gesamte
Image nach `call rel16`, gruppiert nach Ziel, und stuft ein Ziel als
Inline-String-Routine ein, wenn es ≥ 3 Aufrufstellen hat und bei ≥ 80 % davon
Text mit Bit-7-Ende folgt. Der Scan läuft über Rohbytes statt über gefundene
Aufrufstellen — sonst wäre er zirkulär, denn interessant sind gerade die noch
nicht erreichten Routinen.

Gefunden: `0x5B4C`, `0x5B51`, `0x5B56`, `0x5B62`, `0xAE0A`. Aktuell 50 Strings
mit 1.647 Byte.

Der Textinterpreter ist selbst kompakt: Zeichen < 0x20 sind Steuercodes
(0..9 über die Trampolintabelle, 10..31 verschieben `dx`), 0x20..0x67 gehen an
den vorgewählten Glyphen-Renderer in `bp`, und **Zeichen ≥ 0x68 sind Tokens**,
die über `[0x5BF0 + 2*Zeichen]` (effektiv ab `0x5CC0`) auf Phrasen im
String-Pool zeigen. Deshalb tauchten in der ersten Stringsuche nur Fragmente wie
`SCENARI` oder `FIRE AND FORGE` auf — der letzte Buchstabe trägt Bit 7.

## Betriebssystem-Schnittstelle

Bemerkenswert schmal — das Spiel greift fast alles direkt an der Hardware ab:

| Interrupt | Stellen | Zweck |
|---|---:|---|
| `int 21h` | 4 | `AH=30h` DOS-Version, `AH=3Fh` read, `AH=3Eh` close, `AH=4Eh` findfirst |
| `int 10h` | 5 | BIOS-Videomodus |
| `int 00h` | 1 | Division durch Null |

Zentraler `int 21h`-Wrapper: `sub_0000_D3A9`. Dateinamen im Klartext bei
`0xD39F` (`\RETAL`, `RETAL.00`) und `0xDABB` (`\RETAL\RETAL.LOG`). `RETAL.01`
kommt nicht als Literal vor — die Endziffer wird offenbar hochgezählt.

Der `.LOG`-Leser sitzt bei `0xDBB4`: liest bis 64 KB, schliesst, vergleicht dann
gegen `cx = 0x30B` = 779 Byte — exakt die Größe von `RETAL.LOG`.

## Bekannte Datenbereiche in X.EXE

| Offset | Inhalt |
|---|---|
| `0x2E8F` | Tastaturtabellen (`1234567890-=`, `qwertyuiop[]`, …) |
| `0x30A3` | Kopierschutz: `PILOT AUTHORISATION`, `WHICH SECTOR DOES THIS … CONCERN?` |
| `0x5DEE` | Missionsauswahl: `SCENARIO`, `FIRE AND FORGET`, `TEST RANGE`, `RED ARMY` |
| `0x7118` | Pilotenlog, Ränge, Medaillen (`PURPLE HEART` … `MEDAL OF HONOUR`) |
| `0x734A` | Basisnamen und -beschreibungen (`GROOM LAKE`, `USAF RAMSTEIN`, …) |
| `0x8D62` | Rufzeichen (`RETALIATOR`, `HOUR GLASS`, `SAVIOUR`, …) |
| `0xD6A7` | Hauptmenü (`RETALIATOR`, `1: ENROL TO…`) |
| `0xD771` | `RETALIATOR TOP GUN` |
| `0xFC10` | Segmenttabelle (s. o.) |

## Offene Punkte

Verbleibende indirekte Sprünge, nach Hebelwirkung sortiert:

| Stelle(n) | Art | Warum offen |
|---|---|---|
| 35× `lcall [0xFC14]` | Overlay | Führt aus `X.EXE` heraus. Braucht erst das Archivformat |
| 11× `call bp` | dynamisch | `bp` wird über mehrere Basisblöcke hinweg gesetzt, einfache Konstantenpropagation reicht nicht |
| 2× `jmp si` (`0x5B60`, `0x5B66`) | Inline-String | Kein fester Zielort — Rücksprung hinter den jeweiligen String. Wird bereits korrekt behandelt, nur nicht als „Ziel" auflösbar |
| 2× `call di` (`0x3393`, `0x33B3`) | dynamisch | noch nicht analysiert |
| `call bx` (`0x9849`), `jmp bx` (`0x9E48`) | dynamisch | noch nicht analysiert |
| `call [bp+0x2C]`, `call [bp+0x49]`, `call [bx+0xE]`, `jmp [bx+si+5]` | stapel-/strukturrelativ | Zeiger aus Datenstrukturen, brauchen Typanalyse |

Sonstiges:

- Videomodus-Setup bei `0x6392`/`0x63BB` analysieren (EGA/VGA/Tandy).
- `lcall 0x14E8:0x1E2A` bei `0xA973` prüfen — vermutlich fehlinterpretierte
  Daten, das Segment passt zu keinem Tabelleneintrag.
- Die Fensteranalyse schätzt ~50.976 Byte Code. Erreicht sind 27.629 Byte
  davon 1.647 Byte Inline-Strings, also **~26.000 Byte Code ≈ 51 % des
  geschätzten Codes**.
