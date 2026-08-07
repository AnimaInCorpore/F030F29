# The start menu

The second piece of task 7 (HUD, cockpit, menu system), after
[HUD.md](HUD.md). `src/menu.s` shows a title and two options, START and EXIT,
before the game loop runs, navigated with the arrow keys and confirmed with
Return.

## Why a new font

The only font in the tree before this was `f29.s`'s 4x5 hex-digit set —
enough for a numeric HUD readout, not for menu text. `tools/gen_menu_font.py`
generates an original 5x7 bitmap font (space, `0`-`9`, `A`-`Z`, plus a solid
block used as the selection cursor) in the same "one word per pixel, 0 = off,
-1 = on" convention the existing font uses, so `draw_char` is a straight
sequence of word copies with no bit unpacking. Run the script and paste its
output into `src/menu.s` when the font needs a change; it is not part of the
build.

Menu text draws at 2x2 pixels per font pixel (a 10x14 screen-pixel cell) so
it reads clearly at 320x240 — the HUD's font is tiny by design (a dense
numeric readout sitting over the 3D view), but title/option text at that size
would be hard to read on a menu screen with nothing else competing for
attention.

The glyph index is computed arithmetically in `draw_char` (space = 0,
`0`-`9` = 1..10, `A`-`Z` = 11..36, the cursor block = 37) rather than via a
second lookup table, so it depends on `menu_chars` being in exactly that
order — noted in both the generator and the table's own comment.

## Layout and navigation

Title "F29" centred near the top; START and EXIT left-aligned below it with a
solid cursor block to their left marking the current selection. Background is
a flat fill using the same blitter halftone trick `draw_horizon` uses for the
sky and ground, just one colour and, since it covers the whole screen rather
than one band at a time, two blitter runs instead of many (`Y_Count` is 16
bit and 320x240 words does not fit in one run).

Navigation reads `key_value`'s low byte, the raw IKBD scancode of the last
key event (see `src/keyboard.s` — no debounce of its own). `menu_update`
edge-detects by comparing it against what it was the previous frame, acting
only on a change:

- Up/Down move the selection between START and EXIT, wrapping.
- Return on START clears `menu_active`, which is the integration point —
  `f29.s`'s main loop checks it right after the VBL wait and skips straight
  to the buffer swap while the menu is up, so dismissing it just lets the
  existing per-frame render path run on the next iteration.
- Return on EXIT sets `menu_quit`, which the main loop checks before drawing
  and jumps straight to `m_end` on, ending the program the same way holding
  Space already did.

Return, not Space, confirms — Space is already "quit the whole program" at
the bottom of `f29.s`'s main loop, unconditionally and not edge-detected, so
using it as the menu's own confirm key would quit the instant START was
confirmed.

## Three real bugs, all the same shape

Every drawing routine below `menu_draw` needs a register some *caller*
higher up the chain also needs preserved across the call, and getting this
wrong doesn't fail to assemble or crash — it just quietly corrupts an address
partway through, which looked like three unrelated symptoms before the
pattern became obvious:

- **`menu_draw` keeps the screen base in `a2`** across several `draw_text`
  calls (`move.l a2,a0` before each one). `menu_clear` used `a2` internally
  as a scratch pointer to `Dst_Addr` — so by the time it returned, `a2` held
  a blitter register address instead of the screen base, and every glyph
  after that landed in I/O space instead of the framebuffer. Symptom: a
  completely black frame, background fill included, even though the fill
  code ran.
- **`draw_char` also used `a2`** as its internal row cursor — same collision,
  one level down. Fixed by moving it to `a3`/`a4`.
- **`draw_char` used `a1`** to look up the glyph data pointer, but
  `draw_text` keeps the string pointer in `a1` across the `bsr draw_char`
  call that draws each character. Symptom: only the first character of every
  string drew; the second read whatever byte `draw_char` had left `a1`
  pointing at in the font data table instead of the string's second
  character, which usually wasn't a valid letter and rendered as a blank
  cell.

None of this showed up reading the code — every routine's own logic is
correct in isolation. It only showed up rendering an actual frame and cropping
in on it, which is the same lesson [HUD.md](HUD.md) already recorded from a
different angle: verify the pixels, not the reasoning about the pixels.
`draw_char`'s and `menu_clear`'s doc comments now say explicitly which
registers a caller may rely on surviving the call.

Two smaller bugs from the same pass, worth a one-line mention: the halftone
fill only doubled a colour into a register's low word before writing it as a
longword (should be the same colour in both halves, built once as a compile-
time constant instead of at runtime — see `MENU_BG_FILL`), and the X-position
constants were plain pixel columns instead of pre-doubled byte offsets, unlike
`hud.s`'s established `HUD_AIRSPEED_X`-style convention.

## Verifying it

```bash
./tools/build-run.sh
bash tools/grab-frame.sh 1500 build/frame.png
```

Rendering is easy to check by eye (crop and upscale first — see the bugs
above and the same trap recorded in [HUD.md](HUD.md)). Input is not: nothing
in `tools/re/` or `tools/` drives keyboard input into a headless Hatari run,
so this was verified by writing the IKBD scancode directly into `key_value`'s
RAM address through Hatari's own debugger console, the same way a real key
press would arrive, then reading `menu_selection`/`menu_active`/`menu_quit`
back out and rendering a frame to confirm the redraw:

- Poking Down (`80`) moved the cursor from START to EXIT, on screen and in
  `menu_selection`.
- Poking Return with EXIT selected set `menu_quit`.
- Poking Return with START selected (the default) cleared `menu_active` and
  left `menu_quit` false, and the frame 250 VBLs later showed the ordinary
  horizon/HUD view, confirming the handoff back to the normal render path.

Two things worth knowing if repeating this: the poke has to land *after*
`menu_init` has run, or `menu_init` seeds `menu_prev_key` from the already-
poked value and the edge disappears before `menu_update` ever sees it as a
change. And `quit` inside a Hatari debugger breakpoint script does not resume
emulation the way `grab-frame.sh`'s single-breakpoint scripts make it look —
it drops to the interactive console, which blocks forever on a headless
run's closed stdin; `grab-frame.sh` gets away with it because the one line it
needs is already in the log by the time that happens and its outer `timeout`
silently kills the hang afterward. Chaining breakpoints needs `cont` instead,
and even `cont` re-enters the console immediately in this setup, so an
external `yes c |` feeding the process is what actually got a multi-
breakpoint run to completion.

## Open

- No OPTIONS entry — there is nothing functional yet for it to lead to.
- Cockpit panel (gauges, icons, static artwork) is the rest of task 7, not
  started — see [HUD.md](HUD.md)'s own Open section.
- The font is original but plain; no attempt made at matching the original's
  menu typography, which is exactly the kind of asset this project does not
  reproduce (see the README's Game data section).
