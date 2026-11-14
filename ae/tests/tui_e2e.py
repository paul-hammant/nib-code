"""TUI behaviour upstream's Python tests do not reach, checked through the built
binary. Ours, beside upstream's tests: it drives the binary through upstream's
own PTY fixture and mock (tests/test_interjections.py, used as a library,
unchanged). Run from the repository root after aeb .build.ae:

    python3 ae/tests/tui_e2e.py

- tool_activity: the Running line names the tool a Run is in (upstream
  Sink.onToolActivity, session/run.zig executeTimed).
- login_masks_key: `nib login <service>` on a terminal reads the key with echo
  off (std.io.set_echo) and puts echo back.
- turn_end_hooks_joined: the turn_end hooks run on their own thread and
  quitting waits for them (upstream TurnJob, Session.finishHooks).
"""
import json
import os
import pty
import select
import subprocess
import termios
import time
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
os.chdir(ROOT / "tests")
import test_interjections as tui  # noqa: E402
from test_interjections import Reply, fixture, screen, wait_for  # noqa: E402

tui.BIN = Path(os.environ.get("NIB", ROOT / "target/build/bin/nib"))


def status_line(terminal):
    return next((line for line in screen(terminal.read(), 120, 32) if "turn " in line and "·" in line), "")


def tool_activity():
    # tools.llm is a tool with no background task, so only the tool activity
    # can name it: its request is held by the mock until released.
    with tempfile.TemporaryDirectory(prefix="nib-tool-activity-") as directory:
        tmp = Path(directory) / "case"
        llm = Reply("llm-answer", gated=True)
        replies = [Reply("ran", code="await tools.llm({prompt: 'p', input: 'i'})"), llm, Reply("done")]
        with fixture(tmp, replies) as (terminal, home, _):
            terminal.send("go\r")
            assert llm.received.wait(10), "tools.llm reached the mock"
            wait_for(lambda: "Running llm" in status_line(terminal), "Running llm: " + status_line(terminal))
            llm.release.set()
            wait_for(lambda: tui.finished(home, "done"), "turn committed")
    print("ok   the Running line names the active tool")


def turn_end_hooks_joined():
    with tempfile.TemporaryDirectory(prefix="nib-turn-end-") as directory:
        tmp = Path(directory) / "case"
        hooked = Path(directory) / "hooked"
        config = "[hooks]\nturn_end = " + json.dumps(["sleep 1; touch " + str(hooked)]) + "\n"
        with fixture(tmp, [Reply("done")], config=config) as (terminal, home, _):
            terminal.send("go\r")
            wait_for(lambda: tui.finished(home, "done"), "turn committed")
            assert not hooked.exists(), "the hook is still sleeping"
            terminal.close()
            assert hooked.exists(), "quitting waited for the turn_end hook"
    print("ok   quitting waits for the turn_end hooks")


def login_masks_key():
    key = "masked-key-4f2a9c"
    with tempfile.TemporaryDirectory(prefix="nib-login-mask-") as directory:
        home = Path(directory) / "home"
        home.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
        env.update(NIB_HOME=str(home), HOME=directory, TERM="xterm-256color")
        master, slave = pty.openpty()
        child = subprocess.Popen([str(tui.BIN), "login", "anthropic"], cwd=directory, env=env,
                                 stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        try:
            seen = b""

            def pump(until):
                nonlocal seen
                deadline = time.monotonic() + 10
                while until not in seen and time.monotonic() < deadline:
                    if select.select([master], [], [], .05)[0]:
                        seen += os.read(master, 4096)
                assert until in seen, seen

            pump(b"API key: ")
            echo_during = termios.tcgetattr(slave)[3] & termios.ECHO
            os.write(master, (key + "\r").encode())
            pump(b"key stored")
            assert child.wait(timeout=10) == 0, seen
            echo_after = termios.tcgetattr(slave)[3] & termios.ECHO
        finally:
            if child.poll() is None:
                child.kill()
            os.close(slave)
            os.close(master)
        assert echo_during == 0, "echo is off while the key is read"
        assert echo_after != 0, "echo is back on afterwards"
        assert key.encode() not in seen, "the key never reaches the screen: " + repr(seen)
        assert json.loads(next(Path(directory).rglob("auth.json")).read_text()) == {"keys": {"anthropic": key}}
    print("ok   nib login reads the key with echo off and restores it")


if __name__ == "__main__":
    tool_activity()
    login_masks_key()
    turn_end_hooks_joined()
