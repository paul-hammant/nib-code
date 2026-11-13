"""The TUI's Running line names the tool a Run is in (upstream Sink.onToolActivity,
session/run.zig executeTimed). Ours, beside upstream's tests: it drives the built
binary through upstream's own PTY fixture and mock (tests/test_interjections.py,
used as a library, unchanged). Run from the repository root after aeb .build.ae:

    python3 ae/tests/tool_activity.py
"""
import os
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


def main():
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


if __name__ == "__main__":
    main()
