# Terminal control in std: raw mode, window size, SIGWINCH, waiting on input

**For:** aether (`std.io` / `std.os` / `std.signal`). **From:** nib-code's
`ae/term` (the terminal layer under the Aether port of nib's TUI),
2026-11-12, Aether 0.909.0.

## Motivation

A full-screen terminal program (nib's TUI, any editor, pager or dashboard)
needs, on POSIX: raw mode with the original settings put back, the window
size and word when it changes, a wait for input that times out so a UI can
tick, and a guarantee that the terminal is restored however the program
ends. `std` has `io.is_terminal(fd)` and `io.fd_read_into`, nothing else of
this, so `ae/term/tty.c` carries a ~300-line C shim. Everything in it is
standard POSIX and belongs in `std`; the Aether side of `ae/term` would then
be pure Aether.

## What `ae/term/tty.c` does, which is what std should offer

| Need | Shim today | Proposed std shape |
|---|---|---|
| open the controlling terminal | `open("/dev/tty", O_RDWR\|O_NOCTTY\|O_CLOEXEC)` | `io.open_tty() -> (fd, err)` |
| raw mode | `tcgetattr`, clear IGNBRK BRKINT PARMRK ISTRIP INLCR IGNCR ICRNL IXON / OPOST / ECHO ECHONL ICANON ISIG IEXTEN, CS8, VMIN 1 VTIME 0, `tcsetattr(TCSANOW)` after `tcflush(TCIFLUSH)` | `io.raw_mode(fd) -> (*TermState, err)` and `io.restore(state)`: an owned handle (`type TermState = owned ptr drop restore`) |
| window size | `ioctl(TIOCGWINSZ)` | `io.terminal_size(fd) -> (cols, rows, err)` |
| resize notice | SIGWINCH handler writing a self-pipe | a waitable: `signal.watch(signal.SIGWINCH()) -> fd` (a self-pipe or signalfd/kqueue the caller can wait on), or the wait below reporting it |
| wait with timeout | `select` on the tty and the SIGWINCH pipe | `io.wait_readable(fds: int[], timeout_ms) -> int[]` |
| restore on any exit | a process-wide table of (fd, saved termios, bytes to write first), flushed by `atexit`, and by handlers for SIGTERM SIGHUP SIGINT SIGQUIT SIGABRT SIGSEGV SIGBUS SIGFPE SIGILL that restore then re-raise with the old disposition | `io.restore_on_exit(state, leave_bytes)`: std owns the table and the handlers, so two libraries in one program do not fight over the dispositions |
| tests: a pty | `posix_openpt`/`grantpt`/`unlockpt`/`ptsname`, `TIOCSWINSZ` | `os.openpty() -> (master, slave, err)`, `io.set_terminal_size(fd, cols, rows)` |

Two details worth keeping, both learned the hard way:

- **Use `select`, not `poll`, or special-case macOS:** macOS's `poll(2)`
  answers `POLLNVAL` for `/dev/tty`, so a program waiting on its
  controlling terminal never sees a key (found by `ae/term`'s pty test).
- **Restore with `TCSANOW`, not `TCSAFLUSH`:** `TCSAFLUSH` waits for the
  output to drain, which never happens after SIGHUP or when nobody reads
  the other end of a pty; a restore in a signal handler then hangs.

`std.signal` also lacks SIGWINCH (28 on Linux, macOS and the BSDs alike,
unlike SIGUSR1) and any way to install a handler.

## Windows

The console equivalent is `SetConsoleMode` with
`ENABLE_VIRTUAL_TERMINAL_INPUT` on the input handle and
`ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN` on the
output, `GetConsoleScreenBufferInfo` for the size, and
`WaitForSingleObject` + `ReadConsoleInputW` (which also delivers
`WINDOW_BUFFER_SIZE_EVENT`). The same std surface fits; `ae/term` has no
Windows backend yet.

## Ask

The table above as std API (names are suggestions), so `ae/term` can drop
`tty.c`.
