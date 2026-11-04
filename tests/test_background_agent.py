"""Background tools.agent E2E with gated local mocks. Run after `zig build`."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from mock_agent import USAGE, reply
from change_helpers import call, checked_bash, wait_command
from mock_llm_tool import content
from test_agent import alive
from test_interjections import Terminal, history
from test_llm import records, wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, case, cwd):
        self.case, self.cwd = case, cwd
        self.requests = []
        self.lock = threading.Lock()
        self.gates = {name: threading.Event() for name in ("one", "two", "three")}
        self.parent_gate = threading.Event()
        self.fifo_run = False
        super().__init__(("127.0.0.1", 0), Handler)

    def observed(self, prompt):
        with self.lock:
            return [r for r in self.requests if r["prompt"] == prompt]

    def code(self):
        def agent(name, **options):
            return "tools.agent(" + json.dumps({"prompt": "child:" + name, **options}) + ")"
        if self.case == "changes":
            return ("await " + call("write", path="shared.txt", content="parent\nkeep\n") + "; " +
                    "await " + agent("changes", background=True) + "; " +
                    checked_bash(wait_command("child.written") +
                                 " && printf 'external\nexternal-only\nkeep\n' > shared.txt && touch parent.written") +
                    checked_bash(wait_command("child.run-ended")) + "'parent finished'")
        if self.case == "concurrency":
            return ("await " + agent("one", background=True) + "; await Promise.all([" +
                    agent("two") + ", " + agent("three", background=True) + "])")
        if self.case in ("cancel", "limit"):
            return "await " + agent("worker", background=True)
        if self.case == "fifo":
            return "await " + agent("one", background=True)
        if self.case == "boundary":
            return "await " + agent("one", background=True)
        if self.case == "launch_error":
            return ("const started = await " + agent("one", background=True) +
                    "; try { await tools.agent({prompt: 4, background: true}) } " +
                    "catch (error) { console.log(error.message) }; started")
        if self.case == "run_failure":
            return "await " + agent("one", background=True) + "; throw new Error('launching Run failed')"
        if self.case == "failure":
            return "await " + agent("error", background=True)
        if self.case == "long":
            return "await " + agent("long", background=True)
        if self.case == "timeout":
            return "await " + agent("worker", background=True, timeout_ms=2200)
        return "await Promise.all([" + agent("one", background=True) + ", " + agent("two", background=True) + "])"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        provider = "chat_completions" if "messages" in body else "codex"
        messages = body.get("messages", body.get("input", []))
        prompt = next(content(m) for m in messages if m.get("role") == "user")
        with self.server.lock:
            step = sum(r["prompt"] == prompt for r in self.server.requests)
            self.server.requests.append(dict(prompt=prompt, body=body, messages=messages, step=step))
        code, text = None, "complete"
        if prompt == "initial":
            if step == 0:
                code, text = self.server.code(), "launching"
            elif step == 1:
                text = "complete" if any(content(m).startswith("[background agent ") for m in messages) else "early final"
                if self.server.case == "fifo":
                    self.server.parent_gate.wait(15)
                    if self.server.fifo_run:
                        code = "42"
                if self.server.case == "limit":
                    wait_for(lambda: (self.server.cwd / "worker.started").exists())
                if self.server.case == "boundary":
                    code = "42"
            elif step == 2 and self.server.case == "boundary":
                self.server.parent_gate.wait(15)
                code, text = "console.log('z'.repeat(50000)); 43", "second continued step"
        elif prompt == "child:changes":
            if step == 0:
                code = ("await " + call("write", path="shared.txt", content="child\nkeep\n") + "; " +
                        "await " + call("write", path="child-only.txt", content="owned\n") + "; " +
                        checked_bash("touch child.written; " + wait_command("parent.written")) +
                        "'child wrote'")
            else:
                (self.server.cwd / "child.run-ended").touch()
            text = "child complete"
        elif prompt == "child:error":
            data = json.dumps({"error": {"message": "background mock failure"}}).encode()
            self.send_response(400)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        elif prompt == "child:worker":
            if step == 0:
                command = shlex.join([sys.executable, str(ROOT / "tests/mock_agent.py"), "--worker", "cancel", "worker"])
                code = "await tools.bash(" + json.dumps({"command": command}) + ")"
            text = "worker finished"
        elif prompt == "child:long":
            text = "head:" + "z" * 50000 + ":tail"
        else:
            self.server.gates[prompt.split(":")[1]].wait(15)
            text = "done:" + prompt
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            reply(self, provider, code, text, effort="low" if self.server.case == "fifo" and prompt == "initial" and step == 1 else None)


class BackgroundTests:
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="nib-background-")
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()
        auth = self.tmp / "codex"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake", "account_id": "fake", "refresh_token": "fake", "id_token": "fake"}}))
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
        self.env.update(NIB_PROVIDER=self.provider, NIB_API_KEY="fake", NIB_MODEL="mock-parent-model",
                        NIB_HOME=str(self.home), CODEX_HOME=str(auth), HOME=str(self.tmp),
                        NIB_REASONING_EFFORT="high", NIB_CONTEXT_WINDOW="128000", TERM="xterm-256color")

    def mock(self, case):
        mock = Mock(case, self.cwd)
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        self.env["NIB_BASE_URL"] = f"http://127.0.0.1:{mock.server_port}"

        def cleanup():
            for gate in mock.gates.values():
                gate.set()
            mock.parent_gate.set()
            mock.shutdown()
            mock.server_close()
            thread.join()
        self.addCleanup(cleanup)
        return mock

    def start(self):
        process = subprocess.Popen([str(BIN), "ask", "--json", "initial"], cwd=self.cwd,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate()
            for path in self.cwd.glob("*.started"):
                for pid in json.loads(path.read_text()).values():
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)
        self.addCleanup(cleanup)
        return process

    def finish(self, process, ok=True):
        output, error = process.communicate(timeout=10)
        self.assertEqual(error, "")
        self.assertEqual(process.returncode == 0, ok, output)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertIn("end" if ok else "error", events[-1], events)
        return events

    def log(self, events):
        return records(self.home / "sessions" / (events[0]["start"]["session_id"] + ".jsonl"))

    def completions(self, messages):
        return [m for m in messages if content(m).startswith("[background agent ")]

    def test_background_changes_are_isolated_from_parent_and_external_writes(self):
        (self.cwd / "shared.txt").write_text("old\nkeep\n")
        mock = self.mock("changes")
        events = self.finish(self.start())
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 1, runs)
        self.assertTrue(runs[0]["ok"], runs)
        self.assertEqual(runs[0]["changes"], [
            {"path": "shared.txt", "added": 1, "removed": 1, "created": False,
             "diff": "-old\n+parent\n keep\n"},
        ])
        completions = self.completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(completions), 1, completions)
        heading, encoded = content(completions[0]).split("\n", 1)
        self.assertEqual(heading, "[background agent a1 finished]")
        result = json.loads(encoded)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["changes"], [
            {"path": "shared.txt", "added": 1, "removed": 1, "created": False},
            {"path": "child-only.txt", "added": 1, "removed": 0, "created": True},
        ])
        self.assertTrue((self.cwd / "child.run-ended").exists())
        self.assertEqual((self.cwd / "shared.txt").read_text(), "external\nexternal-only\nkeep\n")
        self.assertEqual((self.cwd / "child-only.txt").read_text(), "owned\n")

    def test_returns_immediately_and_delivers_each_completion(self):
        mock = self.mock("basic")
        process = self.start()
        wait_for(lambda: len(mock.observed("initial")) == 2)
        self.assertIsNone(process.poll())
        mock.gates["one"].set()
        wait_for(lambda: len(mock.observed("initial")) == 3)
        self.assertEqual(len(self.completions(mock.observed("initial")[-1]["messages"])), 1)
        self.assertIsNone(process.poll())
        mock.gates["two"].set()
        events = self.finish(process)
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(json.loads(runs[0]["output"].removeprefix("result: ")), [{"id": "a1"}, {"id": "a2"}])
        requests = mock.observed("initial")
        self.assertEqual(len(requests), 4)
        completions = self.completions(requests[-1]["messages"])
        self.assertEqual(len(completions), 2)
        for i, message in enumerate(completions, 1):
            self.assertEqual(message["role"], "user")
            heading, encoded = content(message).split("\n", 1)
            self.assertEqual(heading, f"[background agent a{i} finished]")
            result = json.loads(encoded)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["changes"], [])
            self.assertEqual(set(result), {"ok", "text", "changes"})
            self.assertNotIn("source", message)
            self.assertNotIn("background_id", message)
        progress = [e["background"] for e in events if "background" in e]
        self.assertTrue(all("result" not in e for e in progress), progress)
        for id in ("a1", "a2"):
            self.assertEqual([e["state"] for e in progress if e["id"] == id], ["started", "finished"])
        log = self.log(events)
        logged = [m for r in log for m in r.get("messages", []) if m.get("source") == "background" and m.get("background_kind") == "agent"]
        self.assertEqual([m["background_id"] for m in logged], ["a1", "a2"])
        calls = [c for r in log for c in r.get("calls", []) if c["name"] == "agent"]
        self.assertEqual([c["id"] for c in calls], ["a1", "a2"])
        self.assertTrue(all(c["background"] for c in calls))
        self.assertEqual(events[-1]["end"]["usage"], {k: 6 * v for k, v in USAGE.items()})
        for request in mock.requests:
            body = request["body"]
            effort = body.get("reasoning", {}).get("effort") if self.provider == "codex" else body.get("reasoning_effort")
            self.assertEqual(effort, "high", body)

    def child_logged(self, text):
        return any(text in path.read_text() for path in (self.home / "sessions").glob("?" * 32 + ".jsonl"))

    def test_two_continued_steps_insert_at_next_boundary(self):
        mock = self.mock("boundary")
        process = self.start()
        wait_for(lambda: len(mock.observed("initial")) == 3)
        self.assertEqual([len(self.completions(r["messages"])) for r in mock.observed("initial")], [0, 0, 0])
        mock.gates["one"].set()
        wait_for(lambda: self.child_logged("done:child:one"))
        mock.parent_gate.set()
        events = self.finish(process)
        requests = mock.observed("initial")
        self.assertEqual(len(requests), 4)
        self.assertEqual(len(self.completions(requests[-1]["messages"])), 1)
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 3)
        self.assertIn("bytes omitted]", runs[-1]["output"])
        self.assertLessEqual(len(runs[-1]["output"].encode()), 16 * 1024)
        logged = [m for r in self.log(events) for m in r.get("messages", []) if m.get("source") == "background" and m.get("background_kind") == "agent"]
        self.assertEqual([m["background_id"] for m in logged], ["a1"])

    def test_launch_error_keeps_prior_agent(self):
        mock = self.mock("launch_error")
        process = self.start()
        wait_for(lambda: len(mock.observed("initial")) == 2)
        mock.gates["one"].set()
        events = self.finish(process)
        self.assertIn("a1", next(e["run_end"]["output"] for e in events if "run_end" in e))
        self.assertEqual([e["background"]["state"] for e in events if "background" in e],
                         ["started", "finished"])
        self.assertEqual(len(self.completions(mock.observed("initial")[-1]["messages"])), 1)

    def test_failed_launching_run_does_not_cancel_started_agent(self):
        mock = self.mock("run_failure")
        process = self.start()
        wait_for(lambda: len(mock.observed("initial")) == 2)
        mock.gates["one"].set()
        events = self.finish(process)
        self.assertFalse(next(e["run_end"]["ok"] for e in events if "run_end" in e))
        self.assertEqual([e["background"]["state"] for e in events if "background" in e],
                         ["started", "finished"])
        self.assertEqual(len(self.completions(mock.observed("initial")[-1]["messages"])), 1)

    def test_completion_order_follows_finish_order(self):
        mock = self.mock("basic")
        process = self.start()
        wait_for(lambda: len(mock.observed("initial")) == 2)
        mock.gates["two"].set()
        wait_for(lambda: self.child_logged("done:child:two"))
        mock.gates["one"].set()
        events = self.finish(process)
        completed = [e["background"]["id"] for e in events
                     if e.get("background", {}).get("kind") == "agent" and e.get("background", {}).get("state") == "finished"]
        self.assertEqual(completed, ["a2", "a1"])

    def test_no_run_final_waits_for_pending_agent(self):
        mock = self.mock("fifo")
        process = self.start()
        wait_for(lambda: len(mock.observed("initial")) == 2)
        mock.parent_gate.set()
        time.sleep(.1)
        self.assertIsNone(process.poll())
        self.assertEqual(len(mock.observed("initial")), 2)
        mock.gates["one"].set()
        events = self.finish(process)
        self.assertEqual(events[-1]["end"]["text"], "complete")

    def test_large_result_message_uses_output_budget(self):
        mock = self.mock("long")
        events = self.finish(self.start())
        message = self.completions(mock.observed("initial")[-1]["messages"])[0]
        self.assertLessEqual(len(content(message).encode()), 16 * 1024)
        self.assertIn("bytes omitted]", content(message))
        self.assertIn("head:", content(message))
        self.assertIn(":tail", content(message))
        self.assertEqual(events[-1]["end"]["text"], "complete")

    def test_foreground_and_background_share_concurrency(self):
        (self.home / "config.toml").write_text("[limits]\nagent_concurrency = 1\n")
        mock = self.mock("concurrency")
        process = self.start()
        for index in range(3):
            wait_for(lambda: len([r for r in mock.requests if r["prompt"].startswith("child:")]) == index + 1)
            children = [r for r in mock.requests if r["prompt"].startswith("child:")]
            time.sleep(.1)
            self.assertEqual(len([r for r in mock.requests if r["prompt"].startswith("child:")]), index + 1)
            mock.gates[children[-1]["prompt"].split(":")[1]].set()
        events = self.finish(process)
        self.assertEqual(len(self.completions(mock.observed("initial")[-1]["messages"])), 2)
        self.assertEqual(events[-1]["end"]["text"], "complete")

    def test_failure_is_delivered_as_data(self):
        mock = self.mock("failure")
        events = self.finish(self.start())
        completion = self.completions(mock.observed("initial")[-1]["messages"])[0]
        result = json.loads(content(completion).split("\n", 1)[1])
        self.assertFalse(result["ok"], result)
        self.assertTrue(result["error"])
        self.assertEqual(set(result), {"ok", "text", "changes", "error"})
        self.assertFalse([e["background"] for e in events if e.get("background", {}).get("kind") == "agent" and e.get("background", {}).get("state") == "finished"][0]["ok"])

    def worker_pids(self):
        path = self.cwd / "worker.started"
        wait_for(lambda: path.exists() and path.stat().st_size)
        return json.loads(path.read_text()).values()

    def assert_stopped(self, pids):
        for pid in pids:
            wait_for(lambda: not alive(pid), timeout=3)

    def test_timeout_stops_child_and_delivers_failure(self):
        mock = self.mock("timeout")
        process = self.start()
        pids = list(self.worker_pids())
        self.finish(process)
        result = json.loads(content(self.completions(mock.observed("initial")[-1]["messages"])[0]).split("\n", 1)[1])
        self.assertFalse(result["ok"], result)
        self.assertRegex(result["error"].lower(), "timeout|timed.out")
        self.assert_stopped(pids)

    def test_max_steps_cancels_pending(self):
        (self.home / "config.toml").write_text("[limits]\nmax_steps = 2\n")
        self.mock("limit")
        process = self.start()
        pids = list(self.worker_pids())
        events = self.finish(process, ok=False)
        self.assertIn("stopped after 2 steps", json.dumps(events[-1]))
        self.assert_stopped(pids)

    def check_signal(self, sig):
        self.mock("cancel")
        process = self.start()
        pids = list(self.worker_pids())
        process.send_signal(sig)
        self.finish(process, ok=False)
        self.assert_stopped(pids)

    def test_sigint_cancels_pending(self):
        self.check_signal(signal.SIGINT)

    def test_sigterm_cancels_pending(self):
        self.check_signal(signal.SIGTERM)


class ChatTests(BackgroundTests, unittest.TestCase):
    provider = "chat_completions"

    def test_interjections_and_background_results_keep_fifo(self):
        mock = self.mock("fifo")
        mock.fifo_run = True
        terminal = Terminal(self.cwd, self.env)
        self.addCleanup(terminal.close)
        terminal.send("initial\r")
        wait_for(lambda: len(mock.observed("initial")) == 2)
        terminal.send("before background\r")
        terminal.until(b"queued")
        mock.gates["one"].set()
        wait_for(lambda: self.child_logged("done:child:one"))
        mock.parent_gate.set()
        request = wait_for(lambda: next((r for r in mock.observed("initial")
                                         if self.completions(r["messages"])), None))
        self.assertEqual(request["body"]["reasoning_effort"], "high")
        messages = request["messages"]
        users = [content(m) for m in messages if m.get("role") == "user"]
        self.assertEqual(users[0:2], ["initial", "before background"])
        self.assertTrue(users[2].startswith("[background agent a1 finished]\n"), users)
        self.assertEqual(len(users), 3)
        wait_for(lambda: any(m.get("content") == "complete" for p in (self.home / "sessions").glob("?" * 32 + ".jsonl")
                             for r in records(p) for m in r.get("messages", [])))
        logged = [m for p in (self.home / "sessions").glob("?" * 32 + ".jsonl") for r in records(p)
                  for m in r.get("messages", []) if m.get("source") == "background" and m.get("background_kind") == "agent"]
        self.assertEqual([m["background_id"] for m in logged], ["a1"])

    def test_escape_cancels_pending(self):
        self.mock("cancel")
        terminal = Terminal(self.cwd, self.env)
        self.addCleanup(terminal.close)
        terminal.send("initial\r")
        pids = list(self.worker_pids())
        terminal.send("\x1b")
        terminal.until(b"canceled")
        self.assert_stopped(pids)
        self.assertFalse(self.completions(history(self.home)))


class CodexTests(BackgroundTests, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
