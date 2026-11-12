"""The demo program in a real pseudo-terminal, the way upstream's
tests/test_tui_*.py drive nib: what it draws (replayed with upstream's
scripts/screen.py), keys and resizes reaching it, and the terminal coming
back as it was however the program ends: quitting, SIGTERM, SIGHUP, a panic.

Usage: python3 ae/term/tests/test_restore.py <demo binary>   (from the repo root)
"""
import fcntl
import importlib.util
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("upstream_screen", ROOT / "scripts" / "screen.py")
_screen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_screen)
screen = _screen.screen

COLS, ROWS = 60, 14


class Terminal:
    def __init__(self, binary, *args):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.cooked = termios.tcgetattr(self.slave)
        bootstrap = ("import fcntl, os, sys, termios; fcntl.ioctl(0, termios.TIOCSCTTY, 0); "
                     "os.execv(sys.argv[1], sys.argv[1:])")
        self.child = subprocess.Popen([sys.executable, "-c", bootstrap, binary, *args],
                                      stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                      start_new_session=True)
        self.output = b""
        self.lock = threading.Condition()
        self.reader = threading.Thread(target=self.drain, daemon=True)
        self.reader.start()

    def drain(self):
        while True:
            if not select.select([self.master], [], [], 0.05)[0]:
                if self.child.poll() is not None and not select.select([self.master], [], [], 0.2)[0]:
                    break
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            with self.lock:
                self.output += chunk
                self.lock.notify_all()

    def until(self, predicate, what, timeout=10):
        with self.lock:
            if not self.lock.wait_for(lambda: predicate(self.output), timeout=timeout):
                raise AssertionError(f"waiting for {what}: {screen(self.output, COLS, ROWS)}")

    def shows(self, text, cols=COLS, rows=ROWS):
        self.until(lambda out: any(text in row for row in screen(out, cols, rows)), repr(text))

    def send(self, data):
        os.write(self.master, data.encode() if isinstance(data, str) else data)

    def wait(self):
        try:
            return self.child.wait(timeout=10)
        finally:
            self.reader.join(timeout=2)

    def restored(self):
        # The master reports the slave's termios; the slave itself may be
        # revoked once its session leader has gone (macOS).
        now = termios.tcgetattr(self.master)
        lbits = termios.ECHO | termios.ICANON | termios.ISIG | termios.IEXTEN
        return ((now[3] & lbits) == (self.cooked[3] & lbits)
                and (now[0] & termios.ICRNL) == (self.cooked[0] & termios.ICRNL)
                and (now[1] & termios.OPOST) == (self.cooked[1] & termios.OPOST))

    def close(self):
        if self.child.poll() is None:
            self.child.kill()
            self.child.wait()
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass


def check(name, fn, binary):
    try:
        fn(binary)
        print(f"  ok   {name}")
        return True
    except (AssertionError, OSError, subprocess.TimeoutExpired) as e:
        print(f"  FAIL {name}: {e}")
        return False


def left_cleanly(term):
    tail = term.output[-200:]
    assert b"\x1b[H\x1b[J\x1b[?1049l" in tail, f"no clear + leave alternate screen at the end: {tail!r}"
    assert b"\x1b[?2004l" in tail, "bracketed paste left on"
    assert b"\x1b[?1002;1003;1004;1006;1016l" in tail, "mouse left on"
    assert term.restored(), "termios not restored"


def draws_keys_and_resizes(binary):
    term = Terminal(binary)
    try:
        term.shows("ae/term demo")
        term.shows(f"{COLS}x{ROWS}")
        term.send("x")
        term.shows('key x text="x"')
        term.send("\x1b[<0;5;6M")
        term.shows("mouse press button=0 at 4,5")
        assert not term.restored(), "raw while running"
        fcntl.ioctl(term.master, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 50, 0, 0))
        term.shows("50x12", 50, 12)
        term.send("q")
        assert term.wait() == 0, "q quits with 0"
        left_cleanly(term)
    finally:
        term.close()


def restores_on(sig):
    def run(binary):
        term = Terminal(binary, "--hang")
        try:
            term.shows("ae/term demo")
            term.child.send_signal(sig)
            code = term.wait()
            assert code == -sig, f"ended by the signal ({code})"
            left_cleanly(term)
        finally:
            term.close()
    return run


def restores_on_panic(binary):
    term = Terminal(binary, "--panic")
    try:
        code = term.wait()
        assert code != 0, "a panic fails the program"
        assert b"panicking with the terminal in raw mode" in term.output, "the panic was reported"
        left_cleanly(term)
    finally:
        term.close()


def main():
    binary = sys.argv[1]
    cases = [
        ("draws, takes keys, mouse and resizes, quits cleanly", draws_keys_and_resizes),
        ("SIGTERM restores the terminal", restores_on(signal.SIGTERM)),
        ("SIGHUP restores the terminal", restores_on(signal.SIGHUP)),
        ("SIGINT from outside restores the terminal", restores_on(signal.SIGINT)),
        ("a panic restores the terminal", restores_on_panic),
    ]
    print("ae/term demo in a pty")
    results = [check(name, fn, binary) for name, fn in cases]
    passed = sum(results)
    print(f"  {passed} passing" + (f", {len(results) - passed} failing" if passed != len(results) else ""))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
