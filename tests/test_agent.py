"""tools.agent contract E2E using only local mocks. Run after `zig build`.

    python3 tests/test_agent.py
    python3 tests/test_agent.py ChatTests.test_parallel_crash
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

from mock_agent import USAGE
from test_llm import records, wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def alive(pid):
    status = Path(f"/proc/{pid}/stat")
    try:
        return status.read_text().split()[2] != "Z"
    except FileNotFoundError:
        return False


class AgentTests:
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="nib-agent-" + self.provider + "-")
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        (self.cwd / "existing.txt").write_text("old\nkeep\n")
        (self.cwd / "read-only.txt").write_text("not changed\n")
        home = self.tmp / "nib"
        home.mkdir()
        auth = self.tmp / "codex"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake-agent-access", "account_id": "fake-agent-account",
            "refresh_token": "fake-agent-refresh", "id_token": "fake-agent-id"}}))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_", "MOCK_"))}
        self.env.update(NIB_PROVIDER=self.provider, NIB_API_KEY="fake-agent-key",
                        NIB_BASE_URL=f"http://127.0.0.1:{port}", NIB_MODEL="mock-parent-model",
                        NIB_THINKING="on", NIB_REASONING_EFFORT="high", NIB_CONTEXT_WINDOW="128000",
                        NIB_HOME=str(home), CODEX_HOME=str(auth), HOME=str(self.tmp))
        self.requests = self.tmp / "requests.jsonl"
        self.server_stderr = open(self.tmp / "server.stderr", "w+")
        self.addCleanup(self.server_stderr.close)
        self.server = subprocess.Popen([sys.executable, str(ROOT / "tests/mock_agent.py"),
                                        str(port), str(self.requests)], env=self.env,
                                       stdout=subprocess.DEVNULL, stderr=self.server_stderr)
        self.addCleanup(self.stop_server)

        def ready():
            if self.server.poll() is not None:
                self.server_stderr.seek(0)
                raise AssertionError(self.server_stderr.read())
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    return True
            except OSError:
                return False
        wait_for(ready)

    def stop_server(self):
        self.server.terminate()
        try:
            self.server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait()

    def start(self, case):
        process = subprocess.Popen([str(BIN), "ask", "--json", "agent-parent:" + case],
                                   cwd=self.cwd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)

        def cleanup():
            # A failing assertion must not leave fault workers or child nibs behind.
            if process.poll() is None:
                process.kill()
            process.communicate()
            for path in self.cwd.glob("*.started"):
                for pid in json.loads(path.read_text()).values():
                    if alive(pid):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
        self.addCleanup(cleanup)
        return process

    def ask(self, case):
        process = self.start(case)
        output, error = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, output + error)
        self.assertEqual(error, "")
        events = [json.loads(line) for line in output.splitlines()]
        self.assertIn("end", events[-1], events)
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 1, events)
        self.assertTrue(runs[0]["ok"], runs[0])
        return json.loads(runs[0]["output"].removeprefix("result: ")), events

    def assert_result(self, result, ok):
        self.assertEqual(set(result), {"ok", "text", "usage", "changes"} | (set() if ok else {"error"}), result)
        self.assertIs(result["ok"], ok)
        self.assertIsInstance(result["text"], str)
        self.assertEqual(set(result["usage"]), set(USAGE))
        self.assertIsInstance(result["changes"], list)
        for change in result["changes"]:
            self.assertEqual(set(change), {"path", "added", "removed", "created"}, change)
            self.assertIsInstance(change["created"], bool)
        if not ok:
            self.assertIsInstance(result["error"], str)
            self.assertTrue(result["error"])

    def assert_total_usage(self, events, results):
        expected = {key: 2 * value + sum(r["usage"][key] for r in results) for key, value in USAGE.items()}
        self.assertEqual(events[-1]["end"]["usage"], expected)

    def test_success_without_runs(self):
        result, events = self.ask("empty")
        self.assert_result(result, True)
        self.assertEqual(result["text"], "done:empty")
        self.assertEqual(result["changes"], [])
        self.assertEqual(result["usage"], USAGE)
        self.assert_total_usage(events, [result])

    def test_multiple_runs_merge_changes(self):
        result, events = self.ask("changes")
        self.assert_result(result, True)
        changes = {c["path"]: c for c in result["changes"]}
        self.assertEqual(len(changes), len(result["changes"]))
        self.assertEqual(changes, {
            "new.txt": {"path": "new.txt", "added": 3, "removed": 1, "created": True},
            str(self.cwd / "existing.txt"): {"path": str(self.cwd / "existing.txt"),
                                             "added": 2, "removed": 3, "created": False},
            "failed-run.txt": {"path": "failed-run.txt", "added": 1, "removed": 0, "created": True}})
        self.assertEqual((self.cwd / "new.txt").read_text(), "a\nc\n")
        self.assertEqual((self.cwd / "existing.txt").read_text(), "final\n")
        self.assertEqual((self.cwd / "bash-only.txt").read_text(), "bash-only")
        self.assertEqual((self.cwd / "failed-run.txt").read_text(), "kept\n")
        self.assertEqual(result["usage"], {key: 4 * value for key, value in USAGE.items()})
        self.assert_total_usage(events, [result])
        steps = [r for r in records(self.requests) if r["prompt"] == "agent-child:changes"]
        self.assertEqual([r["step"] for r in steps], [0, 1, 2, 3])

    def check_parallel(self, fault):
        results, events = self.ask("parallel:" + fault)
        self.assertEqual(len(results), 3)
        self.assert_result(results[0], False)
        self.assertIn("prelude:" + fault, results[0]["text"])
        self.assertGreaterEqual(results[0]["usage"]["prompt_tokens"], 100)
        self.assertEqual(results[0]["changes"], [{"path": fault + ".txt", "added": 1, "removed": 0, "created": True}])
        if fault == "timeout":
            self.assertRegex(results[0]["error"].lower(), r"timeout|timed.out")
        for peer, result in zip(("peer-a", "peer-b"), results[1:]):
            self.assert_result(result, True)
            self.assertEqual(result["text"], "done:" + peer)
            self.assertEqual(result["usage"], {key: 3 * value for key, value in USAGE.items()})
            self.assertEqual(result["changes"], [{"path": peer + ".txt", "added": 1, "removed": 0, "created": True}])
            self.assertTrue((self.cwd / (peer + ".done")).exists())
            self.assertFalse((self.cwd / (peer + ".term")).exists(), "sibling received SIGTERM")
        self.assert_total_usage(events, results)
        starts = [r["at"] for r in records(self.requests) if r["prompt"].startswith("agent-child:") and r["step"] == 0]
        self.assertEqual(len(starts), 3)
        self.assertLess(max(starts) - min(starts), 1.5)
        for path in self.cwd.glob("*.started"):
            for pid in json.loads(path.read_text()).values():
                wait_for(lambda: not alive(pid))

    def test_parallel_crash(self):
        self.check_parallel("crash")

    def test_parallel_timeout(self):
        self.check_parallel("timeout")

    def test_parallel_nonzero_exit(self):
        self.check_parallel("nonzero")

    def test_ndjson_error_resolves_with_partial_result(self):
        result, events = self.ask("error")
        self.assert_result(result, False)
        self.assertIn("Codex request failed (HTTP 400)" if self.provider == "codex" else "agent mock failure", result["error"])
        self.assertIn("prelude:error", result["text"])
        self.assertEqual(result["usage"], USAGE)
        self.assertEqual(result["changes"], [{"path": "error.txt", "added": 1, "removed": 0, "created": True}])
        self.assert_total_usage(events, [result])

    def check_options(self, options):
        result, _ = self.ask("options:" + json.dumps(options))
        self.assert_result(result, True)
        requests = records(self.requests)
        child = [r["body"] for r in requests if r["prompt"] == "agent-child:empty"]
        self.assertEqual(len(child), 1)
        self.assertEqual(child[0]["model"], options.get("model", "mock-parent-model"))
        expected_effort = options.get("effort", "high")
        for body, effort in [(child[0], expected_effort)] + [
                (r["body"], "high") for r in requests if r["prompt"].startswith("agent-parent:")]:
            if self.provider == "codex":
                self.assertEqual(body["reasoning"]["effort"], effort)
            else:
                self.assertEqual(body["thinking"], {"type": "enabled"})
                self.assertEqual(body["reasoning_effort"], effort)
        self.assertTrue(all(r["body"]["model"] == "mock-parent-model" for r in requests
                            if r["prompt"].startswith("agent-parent:")))

    def test_inherit_model_and_effort(self):
        self.check_options({})

    def test_override_model_only(self):
        self.check_options({"model": "gpt-6.1-terra" if self.provider == "codex" else "deepseek-flash"})

    def test_override_effort_only(self):
        self.check_options({"effort": "low"})

    def test_override_model_and_effort(self):
        self.check_options({"model": "gpt-6.1-terra" if self.provider == "codex" else "deepseek-flash", "effort": "medium"})

    def test_argument_errors_reject_without_spawning(self):
        results, _ = self.ask("invalid")
        self.assertEqual(len(results), 10)
        for result in results:
            self.assertFalse(result["resolved"], result)
            self.assertIsInstance(result["error"], str)
            self.assertTrue(result["error"])
        self.assertFalse(any(r["prompt"].startswith("agent-child:") for r in records(self.requests)))

    def check_cancel(self, sig):
        process = self.start("cancel")
        started = [self.cwd / (name + ".started") for name in ("cancel-a", "cancel-b", "cancel-c")]
        wait_for(lambda: all(path.exists() and path.stat().st_size for path in started))
        pids = {pid for path in started for pid in json.loads(path.read_text()).values()}
        process.send_signal(sig)
        output, error = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertEqual(error, "")
        events = [json.loads(line) for line in output.splitlines()]
        self.assertFalse(any("UNEXPECTED_AGENT_RESOLVE" in e.get("run_end", {}).get("output", "")
                             for e in events), events)
        self.assertIn("error", events[-1], events)
        self.assertFalse(any("end" in e for e in events), events)
        for event in events:
            if "run_end" in event:
                self.assertFalse(event["run_end"]["ok"], event)
        for pid in pids:
            wait_for(lambda: not alive(pid), timeout=3)

    def test_user_sigint_rejects_and_stops_children(self):
        self.check_cancel(signal.SIGINT)

    def test_user_sigterm_rejects_and_stops_children(self):
        self.check_cancel(signal.SIGTERM)


class ChatTests(AgentTests, unittest.TestCase):
    provider = "chat_completions"


class CodexTests(AgentTests, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
