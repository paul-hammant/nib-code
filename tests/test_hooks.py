"""Hooks through local mock providers; no real keys. Run after zig build."""
import io
import json
from pathlib import Path
import unittest
import tempfile
import shlex
from test_interjections import Reply, fixture, wait_for
import test_files


class Handler(test_files.MockHandler):
    requests = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.requests.append(json.loads(body))
        self.rfile = io.BytesIO(body)
        super().do_POST()


test_files.MockHandler = Handler


class Hooks(unittest.TestCase):
    setUp = test_files.FileTests.setUp
    start = test_files.FileTests.start
    finish = test_files.FileTests.finish

    def configure(self, after=(), end=()):
        Handler.requests.clear()
        (self.home / "config.toml").write_text(
            "[hooks]\nafter_edit = " + json.dumps(after) +
            "\nturn_end = " + json.dumps(end) + "\n")

    def edit(self):
        return ";".join(test_files.js_call("write", path=str(self.cwd / name), content="hello\n")
                        for name in ["a b", "c'你好"])

    def test_batch_and_silent_success(self):
        self.configure(["printf '%s\\n' \"$NIB_EVENT\" \"$NIB_FILES\" > files; printf '%s\\n' {files} > args; echo once >> count"])
        self.finish(self.start(self.edit()))
        self.assertEqual((self.cwd / "count").read_text(), "once\n")
        self.assertEqual((self.cwd / "args").read_text(), "a b\nc'你好\n")
        self.assertEqual((self.cwd / "files").read_text(), "after_edit\na b\nc'你好\n")
        result = next(m["content"] for m in Handler.requests[-1]["messages"] if m["role"] == "tool")
        self.assertNotIn('"hook"', result)

    def test_failure_reaches_model_and_ask(self):
        self.configure(["echo failed; exit 1", "touch should-not-run"])
        process = self.start(self.edit())
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, output + error)
        self.assertIn("hook echo failed; exit 1 · exit 1", output + error)
        result = next(m["content"] for m in Handler.requests[-1]["messages"] if m["role"] == "tool")
        self.assertIn('"hook":{"command":"echo failed; exit 1","exit_code":1,"output":"failed\\n"}', result)
        self.assertFalse((self.cwd / "should-not-run").exists())

    def test_turn_end_status(self):
        self.configure(end=["printf '%s:%s' \"$NIB_EVENT\" \"$NIB_TURN_STATUS\" > ended"])
        self.finish(self.start("console.log('ok')"))
        self.assertEqual((self.cwd / "ended").read_text(), "turn_end:completed")

    def test_unconfigured(self):
        self.finish(self.start(self.edit()))
        self.assertFalse((self.cwd / "count").exists())

    def test_failed_ask_turn_status(self):
        self.configure(end=["printf '%s' \"$NIB_TURN_STATUS\" > ended"])
        with (self.home / "config.toml").open("a") as config:
            config.write("[limits]\nmax_steps = 1\n")
        process = self.start("console.log('one step')")
        output, error = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0, output + error)
        self.assertEqual((self.cwd / "ended").read_text(), "failed")

    def test_child_hooks_report_once_and_only_root_turn_end(self):
        self.configure(["echo edit >> edits"], ["echo turn >> turns"])
        self.finish(self.start(test_files.js_call("agent", prompt=self.edit())))
        self.assertEqual((self.cwd / "edits").read_text(), "edit\n")
        self.assertEqual((self.cwd / "turns").read_text(), "turn\n")

    def test_cancelled_tui_turn_status(self):
        project = self.tmp / "cancel-tui"
        reply = Reply("waiting", gated=True)
        config = "[hooks]\nturn_end = " + json.dumps(["printf '%s' \"$NIB_TURN_STATUS\" > ended"]) + "\n"
        with fixture(project, [reply], config=config) as (terminal, _, _):
            terminal.send("wait\r")
            self.assertTrue(reply.received.wait(5))
            terminal.send("\x1b")
            wait_for(lambda: (project / "ended").exists(), "cancelled TUI hook")
            self.assertEqual((project / "ended").read_text(), "cancelled")

    def test_sandbox_denies_external_write(self):
        with tempfile.TemporaryDirectory(prefix="nib-hook-denied-", dir=Path.home()) as directory:
            target = Path(directory) / "denied"
            self.configure(["echo denied > " + shlex.quote(str(target))])
            self.finish(self.start(self.edit()))
            self.assertFalse(target.exists())
            result = next(m["content"] for m in Handler.requests[-1]["messages"] if m["role"] == "tool")
            self.assertIn('"hook"', result)

    def test_tui_hooks_and_status(self):
        project = self.tmp / "tui"
        code = test_files.js_call("write", path="edited", content="hello")
        # JSON strings are also valid strings in the supported TOML subset.
        config = "[hooks]\nafter_edit = [\"exit 1\"]\nturn_end = " + json.dumps(["printf '%s:%s' \"$NIB_EVENT\" \"$NIB_TURN_STATUS\" > ended; exit 1"]) + "\n"
        with fixture(project, [Reply(code=code), Reply("finished-hooks")], config=config) as (terminal, home, _):
            terminal.send("edit\r")
            wait_for(lambda: (project / "ended").exists(), "TUI turn-end hook")
            terminal.until(b"hook exit 1")
            terminal.until(b"hook turn_end")
            self.assertEqual((project / "ended").read_text(), "turn_end:completed")
            terminal.wait_turn("finished-hooks")
            terminal.send("/status\r")
            terminal.until(b"Hooks: after_edit 1")
            logs = [json.loads(line) for path in (home / "sessions").glob("*.jsonl") if ".calls." not in path.name for line in path.read_text().splitlines()]
            self.assertEqual([r["hook"]["event"] for r in logs if "hook" in r], ["after_edit", "turn_end"])


if __name__ == "__main__":
    unittest.main()
