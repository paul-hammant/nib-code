"""`@` file completion through a PTY. Run after zig build."""
from pathlib import Path
import tempfile

from test_interjections import Reply, fixture, finished, wait_for, users
from screen import screen


def visible(terminal):
    return "\n".join(screen(terminal.read(), 120, 32))


def test_at_files(tmp):
    reply = Reply("done")
    with fixture(tmp, [reply]) as (terminal, home, _):
        (tmp / "src").mkdir()
        (tmp / "src" / "alpha.zig").write_text("")
        (tmp / "src" / "beta.zig").write_text("")
        (tmp / "ignored").mkdir()
        (tmp / "ignored" / "x.zig").write_text("")
        (tmp / "my dir").mkdir()
        (tmp / "my dir" / "a b.txt").write_text("")
        (tmp / ".gitignore").write_text("ignored/\n")
        terminal.send("look at a@b.com ")
        assert "src/" not in visible(terminal)
        terminal.send("@sr")
        wait_for(lambda: "  src/\n" in visible(terminal), "directory candidate")
        assert "ignored" not in visible(terminal)
        terminal.send("\t")
        terminal.send("al")
        wait_for(lambda: "src/alpha.zig" in visible(terminal) and "src/beta.zig" not in visible(terminal), "file candidate")
        terminal.send("\r")
        wait_for(lambda: "@src/alpha.zig " in visible(terminal), "accepted path")
        assert not reply.received.is_set(), "Enter accepted the completion and must not send"
        terminal.send("please\r")
        wait_for(lambda: finished(home, "done"), "committed reply")
        reply.received.wait(5)
        assert users(reply.messages)[-1] == "look at a@b.com @src/alpha.zig please", reply.messages


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-at-files-") as directory:
        test_at_files(Path(directory) / "at_files")
    print("at files: ok")
