# 3D-Modellformat — RETAL.01 Ressource 9

```bash
python tools/re/models.py                              # Modelle auflisten
python tools/re/models.py --obj re/unpacked/m0.obj     # erstes Modell als .obj
```

## Wie die Ressourcen geladen werden

Die Typ-0-Ressourcen aus `RETAL.01` werden nicht über `mov ax,imm / call 0xD20B`
geladen wie die aus `RETAL.00`, sondern über den Einsprung `0xD20F`, bei dem der
Aufrufer `es` und `dx` selbst setzt. Die Sequenz steht bei `0xECF1`–`0xED8C`:

| Ressource | Laden | Parser |
|---|---|---|
| 8 | `mov ax,0x208` bei `0xECF1` | `0x75FC` |
| 9 | `mov ax,0x209` bei `0xED5B` | **`0x431A`** |
| 10 | `mov ax,0x20A` bei `0xED6F` | `0x438D` |
| 11 | `mov ax,0x20B` bei `0xED80` | `0x4490` |
| 12 | `mov ax,0x20C` bei `0xECE0` | — |

## Format

```
byte          Anzahl Vertices minus eins
n * 6 byte    Vertices: X, Y, Z als 16-Bit vorzeichenbehaftet, little endian
Flächensätze  Marker, Farbbyte, dann ein Wort je Ecke
```

Der **Marker kodiert die Eckenzahl** in Schritten von vier:

| Marker | Ecken | Satzlänge |
|---|---:|---:|
| `0x24` | 3 | 8 Byte |
| `0x28` | 4 | 10 Byte |
| `0x2C` | 5 ? | 12 Byte ? |

Also `Ecken = (Marker >> 2) - 6`, Satzlänge `2 + 2 * Ecken`.

Die Worte im Flächensatz sind **Byte-Offsets** in das Vertex-Array, keine
Indizes — Vertex *k* liegt bei Offset `6k`.

## Belege

**Quad.** Der erste Flächensatz `28 10 30 00 36 00 3c 00 42 00` referenziert die
Offsets 48, 54, 60, 66, also die Vertices 8–11. Das sind exakt die vier Punkte
`(±100, 130, ±100)` — ein Quadrat.

**Dreieck.** `24 16 00 00 1e 00 12 00` wird unmittelbar von einem Satz gefolgt,
der mit `28 05` beginnt. Das geht nur auf, wenn der `0x24`-Satz genau drei Worte
trägt.

**Vertexdaten.** Die ersten acht Vertices des ersten Modells sind
`(±50, ±130, ±45)` — ein achsenparalleler Quader, sofort als solcher lesbar.

**Gerendert.** Zwei Drahtgittermodelle wurden geprüft: Modell 2 (40 Vertices,
25 Flächen) ist ein Turm auf achteckigem Sockel mit Bodenplatte, Modell 9
(94 Vertices, 24 Flächen) ein Flugplatzgrundriss mit langer Landebahn und
Rollwegen. Beide Geometrien sind vollständig kohärent.

## Ergebnis

| | |
|---|---:|
| Modelle | 140 |
| Vertices | 2.492 |
| Flächen | 1.137 |
| davon Dreiecke | 332 |
| davon Quads | 804 |
| Farbindizes | 28 verschiedene |

Ausdehnungen sind plausibel: `200×260×200` für Gebäude, `1200×0×2600` für flache
Landebahnen, `40×100×30` für Kleinobjekte.

## Offen

**Rund 36 % der Ressource (14.829 Byte in 139 Lücken) werden noch nicht
geparst.** Die Ursache ist erkennbar an den Markern, die einen Modellabbruch
auslösen: neben `0x00` (95×, regulärer Abschluss) stehen dort `0x2C` (24×),
`0x1C` (14×) sowie vereinzelt `0x28`, `0x24`, `0x20`. Bei `0x28` und `0x24` sind
die Marker gesichert, der Abbruch kommt also aus der Referenzprüfung — vermutlich
verweisen manche Flächen auf Vertices ausserhalb des eigenen Arrays, etwa auf
gemeinsam genutzte Punkte.

Für `0x2C` und `0x1C` ist die Formel `(Marker >> 2) - 6` nicht belegt, sondern
nur extrapoliert. `0x1C` ergäbe damit eine Fläche mit einer Ecke, was keinen Sinn
ergibt — dort steht wahrscheinlich ein anderer Satztyp, etwa eine Linie, ein
Normalenvektor oder ein Objektkopf.

Klären lässt sich das über den Parser bei `0x431A` und die von ihm gerufenen
Routinen `0x446A`, `0x451A` und `0x44F8`, die bisher nur oberflächlich gelesen
sind. `0x431A` selbst legt pro Satz eine verkettete Struktur an und schreibt drei
Worte nach `[bp+0x0E]`, `[bp+0x12]`, `[bp+0x16]` — das ist die *Instanzierung*
von Objekten mit Position, nicht die Modellgeometrie.

## Die übrigen Typ-0-Ressourcen

| Ressource | entpackt | Struktur |
|---|---:|---|
| 8 | 13.520 | Parser `0x75FC`, ungeprüft |
| 10 | 21.065 | **7-Byte-Sätze**, Gruppen durch `0xFF` getrennt, ausgewählt über `[0xF3A2]` und `[0xE993]` — sieht nach Missions-/Szenariotabellen aus |
| 11 | 13.268 | Parser `0x4490` läuft ab Offset 0 über **nullterminierte Wortsätze** |
| 12–15 | 3.718 / 2.359 / 4.489 / 5.538 | ungeprüft |
