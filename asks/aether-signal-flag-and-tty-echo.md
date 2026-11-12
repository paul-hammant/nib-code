# std.os: SIGINT/SIGTERM as a flag, and terminal echo on stdin

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its Session slice.
**To:** aether, `std.os` / `std.signal` / `std.io` (0.909.0).
**Stand-in meanwhile:** `ae/nib/sysgap/` (`watch_signals`, `signal_received`,
`stdin_echo`; marked C, delete as each lands).

1. **Catching SIGINT and SIGTERM.** `nib ask` must survive Ctrl-C and
   `kill -TERM`: it stops the model request and the running tools, commits the
   partial answer with `[interrupted by user]` or `[interrupted: process
   terminated]`, prints the `{"error":…}` line with usage and timing, and
   exits nonzero within two seconds (upstream tests/test_session.py,
   test_background_bash.py `test_sigint_*`). std.signal has only the numbers;
   nothing installs a handler, so the default action kills the process and
   the log keeps no trace of the Turn.
   Repro: `ae run` a program that loops `sleep(100)` and prints on exit; send
   it SIGINT: it dies with 130 and never prints.
   Proposed: `os.signal_watch(signals: int[]) -> err` installing an
   async-signal-safe handler that only records the last number, and
   `os.signal_received() -> int` (0 none) to poll; or a std.sync cell the
   handler stores into. Restoring the default (`os.signal_reset(sig)`) for
   completeness.
2. **Turning terminal echo off for a secret.** `nib login` reads an API key
   from the terminal without echoing it (upstream src/auth/cli.zig
   readSecret). std.io has no termios.
   Proposed: `io.set_echo(fd, on) -> (changed, err)`: 0 and no error when fd
   is not a terminal; or a general `io.tty_mode(fd, raw|cooked|noecho)` that
   ae/term (the TUI slice) could share (see ae/term/asks/terminal-control.md).
