# ae/term: a terminal layer for Aether

The terminal the Aether port of nib's TUI draws on. Upstream nib uses
[libvaxis](https://github.com/rockorager/libvaxis) (Zig); Aether has no
terminal UI library, so this is one, shaped like the part of libvaxis nib
uses so the TUI screens port line for line.

**It is standalone.** Nothing here imports the rest of nib, and nothing in
it knows about nib: it depends on Aether's `std` only. It can move out into
its own repository as an Aether TUI library without changes.

## Layout

| Module | What it is | libvaxis counterpart |
|---|---|---|
| `term` (`module.ae`, `tty.c`) | `Terminal`: a real one on a tty, an in-memory one for specs, same calls | `Vaxis`, `Loop`, `Tty` |
| `term.screen` (`screen/`) | cells, styles, colours, `Surface`, `Window`, printing segments, display width | `Cell`, `Screen`, `Window`, `gwidth`, `unicode` |
| `term.input` (`input/`) | events, key codes, `matches`, the input decoder, encoders | `Key`, `Mouse`, `Parser`, `event` |
| `term.render` (`render/`) | the diffing renderer | `Vaxis.render`, `ctlseqs` |
| `term.driver` (`driver/`) | spec verbs: `press`, `type_text`, `expect_screen`… | (none; sae's `saedriver` flavour) |
| `term.snapshot` (`snapshot/`) | upstream's `--- name WxH ---` snapshot files | (upstream `view.zig` `snapshot`) |
| `demo/demo.ae` | a box, styled text, events echoed, resize | |

Import with `--lib ae` (or `ae/` on the module path): `import term`,
`import term.screen`, `import term.input`.

## Use

```aether,fragment
t, err = term.open()                 // /dev/tty, raw mode; term.memory(80, 24) in specs
term.enter_alt_screen(t)
term.query_terminal(t, 1000)         // kitty keys, mode 2027 widths, ...
term.set_bracketed_paste(t, true)
term.set_mouse_mode(t, true)
while running {
    e = term.poll(t, 100)            // NoEvent after 100 ms with nothing
    match e {
        Winsize -> { term.resize(t, e.cols, e.rows) }
        Key -> { if input.matches(e, 99, input.CTRL) { running = false } }
        _ -> {}
    }
    w = term.window(t)
    screen.clear(w)
    screen.draw(screen.child(w, x_off: 1), [screen.seg("Thinking", screen.style(attrs: screen.DIM))])
    term.render(t)                   // only what changed, synchronized
}
term.close(t)
```

A spec drives the same program on `term.memory(cols, rows)`:

```aether,fragment
t = term.memory(80, 24)
driver.press(t, "ctrl+s")
driver.type_text(t, "hello")
app_step(t)                          // the program polls and renders
driver.expect_row_contains(t, "Thinking")
snaps, _ = snapshot.load("src/tui/layout_snapshots.txt")
normal, _ = snapshot.find(snaps, "normal")
driver.expect_screen(t, normal.body)
```

The in-memory terminal's clock is fake (`term.now_ms`, `term.advance`; an
empty `poll` moves it by its timeout), it records every byte it was sent
(`term.written`), the clipboard, the title and notifications, and it shows
what the last `render` drew (`term.shown_*`), not what is being drawn.
Driver input goes through the same decoder as a real terminal's: keys as
the kitty protocol encodes them when the terminal has it on (an in-memory
one does), legacy xterm bytes otherwise; `driver.send_bytes` sends raw bytes
the way upstream's pty tests write them.

Everything is passed explicitly: no module-level state. The C shim's
restore table (`tty.c`) is process-wide because signal dispositions are.

## What of libvaxis nib uses, and what is here

From a census of upstream `src/` (`vaxis.*` symbols and method calls):

| libvaxis, as nib uses it | here |
|---|---|
| `Window` (75 uses): `child` with negative offsets, `print`/`printSegment` with grapheme/word/none wrap and `commit = false` to measure, `readCell`, `writeCell`, `clear`, `fill`, `showCursor`/`hideCursor`, `gwidth` | `screen.child`, `screen.draw` / `draw_segment` (`print` is an Aether builtin), `win_read`, `win_write`, `clear`, `fill`, `show_cursor`, `hide_cursor`, `win_gwidth`; also `child_bordered`, `scroll`, `has_mouse`. Word wrap keeps libvaxis's quirks (the row counted after a broken segment's last line) |
| `Screen.init`, `screen.buf[i]` edits, `readCell`, `width_method` | `screen.surface`, `s.cells[i]`, `read_cell`, `width_method` |
| `Cell`, `Style` (fg, bg, ul, ul_style, bold, dim, italic, blink, reverse, invisible, strikethrough), `Color` (default, index, rgb), `Segment`, hyperlinks | all, colours as ints (`color_index`, `color_rgb`); OSC 8 links render |
| `gwidth.gwidth` (unicode and wcwidth methods), `unicode.graphemeIterator` | `screen.gwidth(s, method)`, `screen.grapheme_end`; libvaxis's own width test cases pass |
| `Vaxis`: `init`, `enterAltScreen`, `queryTerminal`, `setBracketedPaste`, `setMouseMode`, `queryColor`, `subscribeToColorSchemeUpdates`, `resize`, `render`, `window`, `copyToSystemClipboard`, `notify`, `caps.sgr_pixels` off | all (`sgr_pixels` is never turned on); `set_title` too |
| `Loop(Event)`: resize handler, `nextEvent`, `tryEvent`, `postEvent` | `poll(t, timeout_ms)`; posting app events is the TUI's own business (an actor or a queue of its own) |
| `Key` (`matches`, codepoint constants, `Modifiers`), `Mouse` (`Button`, `Type`), `Winsize`, `Color.Report`, `Color.Scheme`, paste start/end | all; key codes are kitty's (libvaxis's) values |
| input: legacy keys, kitty CSI u (all fields), SGR and X10 mouse, bracketed paste, focus, OSC 4/10/11/12 colour reports, OSC 52 paste, colour-scheme DSR, in-band resize, DA1/DECRPM/kitty capability replies | all |
| renderer: diff against the last frame, wide-grapheme skip cells, synchronized output, SGR standard/legacy, cursor, cursor shape | all, for the alternate screen |
| `Tty`: raw mode, `/dev/tty`, SIGWINCH, restore on exit | all, plus restore on SIGTERM/SIGHUP/SIGINT/SIGQUIT and on a panic or a crash (SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL) |

Not here, because nib does not use them: images (kitty graphics, sixel),
scaled text and explicit width (OSC 66), secondary cursors, mouse shapes,
the primary-screen (inline) renderer, `no_zwj` widths, vxfw widgets,
cursor-position reports (so `CSI 1;2R` is shift+F3, as without libvaxis's
pending-request tracking). libvaxis also starts a render on every frame
while the cursor is shown (its secondary-cursor check is inverted); this
renderer writes nothing for an unchanged frame.

## Windows

Not yet. `tty.c` compiles there and every call fails, so `term.open` says
"no terminal". The next step is a console backend: `SetConsoleMode` with
`ENABLE_VIRTUAL_TERMINAL_INPUT` / `ENABLE_VIRTUAL_TERMINAL_PROCESSING`, the
size from `GetConsoleScreenBufferInfo`, and `WaitForSingleObject` +
`ReadConsoleInputW` for input with a timeout and resize events; the
decoder, renderer and everything above stay as they are (Windows Terminal
and conhost read the same VT sequences, with legacy SGR). The in-memory
terminal works on Windows today.

## Tests

`ae/term/run-tests.sh` (from anywhere; needs `ae` and `python3`):

- `tests/test_screen.ae`, `test_input.ae`, `test_render.ae`,
  `test_terminal.ae`, `test_snapshot.ae`: specs (`std.spec`).
- `tests/test_pty.ae`: the real terminal on a pty this process holds both
  ends of: raw mode, reads decoded, a lone ESC, query replies interleaved
  with typing, SIGWINCH, close restoring the termios. It also leaves the
  bytes of rendered frames for:
- `tests/fidelity.py`: replays those bytes with upstream's
  `scripts/screen.py`, unchanged; each replay must equal the grid.
- `tests/test_restore.py`: the demo under a pty with a controlling
  terminal, as upstream's `tests/test_tui_*.py` run nib: it draws, takes
  keys, mouse and a resize, and the terminal comes back cooked with the
  modes off after `q`, SIGTERM, SIGHUP, SIGINT and a panic.

`screen.py` reads neither colon-separated SGR (`38:5:200`, `4:3`) nor
`CSI Ps SP q`, so the fidelity frames use legacy SGR for 256/RGB colours,
single underlines and no cursor shapes; the renderer's other forms are
pinned byte for byte in `test_render.ae`.

## Aether notes

Two compiler bugs (Aether 0.909.0) shape the code, each worked around where
it bites and written up in `asks/`: returning a local optional whose type
owns a string frees the string (`asks/optional-return-frees-string.md`; so
`poll` returns `Event` with a `NoEvent` variant and `read_cell` a
`(Cell, bool)`), and a local stored into slice elements in a loop is moved
by the first store (`asks/loop-store-moves-local.md`). The C shims and what
`std` should offer instead: `asks/terminal-control.md`,
`asks/unicode-grapheme-width.md`.

Names that differ from libvaxis because Aether reserves them: `draw`
(`print`), `type_text` (`type`), `send_bytes` (`send`), `push_event`
(`push`, which would shadow the slice method).
