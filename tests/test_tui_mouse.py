"""Mouse selection, scrolling and user cards through a PTY. Run after zig build."""
import base64
import contextlib
import os
from pathlib import Path
import re
import tempfile
from unittest.mock import patch

from test_interjections import Reply, fixture, finished, screen, wait_for


def mouse(button, col, row, release=False):
    return f"\x1b[<{button};{col + 1};{row + 1}{'m' if release else 'M'}"


def clipboard(terminal, start):
    def copied():
        output = terminal.read()[start:]
        matches = re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x1b\\", output)
        return base64.b64decode(matches[-1]).decode() if matches else None
    return wait_for(copied, "OSC 52 clipboard")


@contextlib.contextmanager
def terminal_fixture(tmp, reply):
    env = {key: value for key, value in os.environ.items()
           if key not in ("DISPLAY", "WAYLAND_DISPLAY")}
    with patch.dict(os.environ, env, clear=True):
        with fixture(tmp, [reply]) as (terminal, home, _):
            terminal.send("mouse test\r")
            wait_for(lambda: finished(home, reply.text), "committed reply")
            terminal.until(b"line-079")
            yield terminal


def test_cross_screen_selection(tmp):
    reply = Reply("\n".join(f"line-{i:03}" for i in range(80)))
    with terminal_fixture(tmp, reply) as terminal:
        for reverse in (True, False):
            if not reverse:
                terminal.send(mouse(64, 1, 1) * 10)
            start = len(terminal.read())
            terminal.send(mouse(0, 1, 20 if reverse else 1)
                          + mouse(64 if reverse else 65, 1, 10) * 8
                          + mouse(32, 8, 1 if reverse else 24)
                          + mouse(0, 8, 1 if reverse else 24, release=True))
            copied = clipboard(terminal, start)
            lines = re.findall(r"line-(\d{3})", copied)
            numbers = list(map(int, lines))
            assert len(numbers) > 32, copied
            assert numbers == list(range(numbers[0], numbers[-1] + 1)), copied
            assert "history" not in copied and "Message nib" not in copied, copied
            assert terminal.child.poll() is None


def test_background_report_and_user_card(tmp):
    reply = Reply("\n".join(f"line-{i:03}" for i in range(80)))
    with terminal_fixture(tmp, reply) as terminal:
        terminal.send(mouse(64, 1, 1) * 40)
        terminal.until("▎".encode())
        for color in ("0000/0000/0000", "ffff/ffff/ffff"):
            start = len(terminal.read())
            terminal.send(f"\x1b]11;rgb:{color}\x1b\\")
            wait_for(lambda: len(terminal.read()) > start, "theme redraw")
            assert terminal.child.poll() is None
        start = len(terminal.read())
        terminal.send(mouse(0, 5, 0) + mouse(32, 14, 0) + mouse(0, 14, 0, release=True))
        copied = clipboard(terminal, start)
        assert copied == "mouse test", repr(copied)


def test_click_and_ctrl_o_open_single_runs(tmp):
    replies = [Reply("first", code="/* script-one */ await tools.bash({command: 'echo out-one'}); 'ret-one'"), Reply("first-done"),
               Reply("second", code="/* script-two */ await tools.bash({command: 'echo out-two'}); 'ret-two'"), Reply("second-done")]
    with fixture(tmp, replies) as (terminal, home, _):
        for prompt, text in (("one", "first-done"), ("two", "second-done")):
            terminal.send(prompt + "\r")
            terminal.wait_turn(text)

        def view():
            return "\n".join(screen(terminal.read(), 120, 32))

        def title(index):
            rows = [i for i, line in enumerate(view().split("\n")) if "Run" in line and "Script" not in line]
            return rows[index]

        assert "Script" not in view()
        row = title(0)
        terminal.send(mouse(0, 10, row) + mouse(0, 10, row, release=True))
        wait_for(lambda: "script-one" in view(), "first Run opened by click")
        assert "script-two" not in view(), view()
        terminal.send("\x0f\x1b[6~")
        wait_for(lambda: "script-two" in view(), "latest Run opened by Ctrl+O")
        terminal.send("\x0f")
        wait_for(lambda: "script-two" not in view(), "latest Run closed by Ctrl+O")
        assert terminal.child.poll() is None


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-tui-mouse-") as directory:
        for test in (test_cross_screen_selection, test_background_report_and_user_card, test_click_and_ctrl_o_open_single_runs):
            test(Path(directory) / test.__name__)
            print(test.__name__ + ": ok")
