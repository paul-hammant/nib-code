"""Automatic whole-Run yielding, against local mocks without real credentials."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import unittest

from mock_agent import reply
from test_agent import alive
from test_interjections import Terminal
from test_llm import wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, cwd):
        self.cwd = cwd
        self.requests = []
        self.case = "overlap"
        self.provider = "chat_completions"
        self.release = threading.Event()
        self.followup = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        index = len(self.server.requests)
        self.server.requests.append(request)
        case = self.server.case
        code = None
        if case == "resume":
            code = "await tools.sleep(150); 'resumed-result'" if index == 0 else None
        elif index == 0:
            if case in ("cancel", "crash", "stop"):
                command = "echo $$ > worker.pid; sleep 30; echo should-not-finish"
                code = "const r=await tools.bash(" + json.dumps({"command": command}) + "); if(r.exit_code!==null) throw new Error('stop did not kill command'); r"
            elif case == "limit":
                code = "await tools.sleep(220); console.log('limit-result')"
            elif case == "reject":
                code = "await tools.sleep(200); throw new Error('late failure')"
            elif case == "budget":
                code = "console.log('prefix-before-yield'); await tools.sleep(200); console.log('x'.repeat(40000)); 'tail-result'"
            elif case == "multiple":
                code = "await tools.sleep(400); await tools.write({path:'first.txt',content:'first'}); 'first-result'"
            elif case == "slots":
                code = "await tools.sleep(2000); 'slot-result'"
            else:
                command = "sleep .45; printf bash-result"
                code = ("console.log('before-yield'); const r=await tools.bash(" + json.dumps({"command": command}) + "); "
                        "if(r.exit_code!==0) throw new Error('await result changed'); "
                        "await tools.write({path:'late.txt',content:r.output}); console.log('after-yield'); r")
        elif case in ("cancel", "crash"):
            self.server.followup.set()
            self.server.release.wait(10)
        elif case == "stop" and index == 1:
            code = "await tools.stop({id:'r1'})"
        elif case == "multiple" and index == 1:
            code = "await tools.sleep(180); await tools.write({path:'second.txt',content:'second'}); 'second-result'"
        elif case == "slots" and index < 9:
            code = "await tools.sleep(2000); 'slot-result'"
        elif case == "overlap" and index == 1:
            code = "await tools.write({path:'independent.txt',content:'done while waiting'}); 'independent-result'"
        if index > 0 and case not in ("cancel", "crash", "resume"):
            self.server.followup.set()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            reply(self, self.server.provider, code, "done" if code is None else "working")


class BackgroundRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = Path(self.tmp.name)
        self.home = self.cwd / "home"
        self.home.mkdir()
        self.config()
        self.server = Mock(self.cwd)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.env = dict(os.environ, NIB_HOME=str(self.home), NIB_PROVIDER="chat_completions",
                        NIB_API_KEY="mock", NIB_MODEL="mock",
                        NIB_BASE_URL=f"http://127.0.0.1:{self.server.server_port}")

    def tearDown(self):
        self.server.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def config(self, extra=""):
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 50\n" + extra)

    def launch(self, *args):
        return subprocess.Popen([str(BIN), "ask", "--json", "initial", *args], cwd=self.cwd,
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def finish(self, process, ok=True):
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode == 0, ok, stdout + stderr)
        self.assertEqual(stderr, "")
        events = [json.loads(line) for line in stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        rows = [json.loads(line) for line in (self.home / "sessions" / (session + ".jsonl")).read_text().splitlines() if line]
        return events, rows, session

    def results(self, rows):
        return [m for r in rows for m in r.get("messages", []) if m.get("background_kind") == "run"]

    def assert_overlap(self):
        events, rows, session = self.finish(self.launch())
        results = self.results(rows)
        self.assertEqual(len(results), 1)
        result = results[0]
        self.assertTrue(result["background_ok"])
        self.assertIn("before-yield\nafter-yield", result["content"])
        self.assertIn('"exit_code":0', result["content"])
        self.assertIn("bash-result", result["content"])
        completion = result["background_run"]
        self.assertEqual((completion["step"], completion["run_index"]), (1, 0))
        self.assertEqual([c["path"] for c in completion["changes"]], ["late.txt"])
        self.assertEqual([c["name"] for c in completion["calls"]], ["bash", "write"])
        self.assertEqual(completion["tool_bytes"], sum(c["result_bytes"] for c in completion["calls"]))
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertIn("continuing in background as r1", runs[0]["output"])
        self.assertNotIn("before-yield", runs[0]["output"])
        self.assertEqual(runs[0]["changes"], [])
        self.assertEqual([c["path"] for c in runs[1]["changes"]], ["independent.txt"])
        self.assertEqual((self.cwd / "late.txt").read_text(), "bash-result")
        self.assertLess((self.cwd / "independent.txt").stat().st_mtime_ns, (self.cwd / "late.txt").stat().st_mtime_ns)
        lifecycle = [e["background"] for e in events if "background" in e and e["background"]["kind"] == "run"]
        self.assertEqual([e["state"] for e in lifecycle], ["started", "finished"])
        self.assertEqual(events[-1]["end"]["text"], "done")
        replayed = subprocess.run([str(BIN), "replay", session, "--all", "--json"], cwd=self.cwd,
                                  env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(replayed.returncode, 0, replayed.stdout + replayed.stderr)
        replay_report = json.loads(replayed.stdout)
        self.assertEqual(replay_report["divergences"], 0, replay_report)
        self.assertEqual(replay_report["undetermined"], 0, replay_report)
        self.assertEqual(replay_report["matched"], 2, replay_report)
        report = json.loads(subprocess.check_output(["python3", str(ROOT / "scripts/stats.py"), str(self.home / "sessions"), "--json"]))
        self.assertEqual(report["background_runs"]["background_calls"], 1)
        self.assertGreaterEqual(report["background_runs"]["background_steps"]["median"], 1)

    def test_overlap_keeps_await_console_changes_and_replay(self):
        self.assert_overlap()

    def test_codex_overlap_keeps_await_console_changes_and_replay(self):
        self.server.provider = "codex"
        auth = self.cwd / "auth"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake", "account_id": "fake", "refresh_token": "fake", "id_token": "fake"}}))
        self.env.update(NIB_PROVIDER="codex", NIB_MODEL="gpt-6.1-sol", CODEX_HOME=str(auth))
        self.assert_overlap()

    def test_completed_resume_does_not_redeliver_results(self):
        _, _, session = self.finish(self.launch())
        self.server.case = "resume"
        self.server.requests.clear()
        _, rows, _ = self.finish(self.launch("--resume", session))
        results = self.results(rows)
        self.assertEqual([r["background_id"] for r in results], ["r1", "r2"])
        self.assertFalse(any("lost: process ended" in r["content"] for r in results))

    def test_step_limit_waits_for_delivery_without_extra_request(self):
        self.server.case = "limit"
        self.config("max_steps = 1\n")
        events, rows, _ = self.finish(self.launch(), ok=False)
        self.assertEqual(len(self.server.requests), 1)
        self.assertIn("limit-result", self.results(rows)[0]["content"])
        self.assertIn("waited for background tasks: run r1", events[-1]["error"]["message"])

    def test_late_failure_and_console_budget(self):
        for case in ("reject", "budget"):
            with self.subTest(case=case):
                self.server.case = case
                self.server.requests.clear()
                events, rows, _ = self.finish(self.launch())
                result = self.results(rows)[0]
                self.assertEqual(result["background_ok"], case == "budget")
                output = result["background_run"]["output"]
                self.assertLessEqual(len(output.encode()), 16 * 1024)
                if case == "reject":
                    self.assertIn("late failure", output)
                else:
                    self.assertIn("prefix-before-yield", output)
                    self.assertIn("tail-result", output)
                    self.assertIn("omitted", output)

    def test_multiple_runs_keep_changes_separate(self):
        self.server.case = "multiple"
        _, rows, _ = self.finish(self.launch())
        results = self.results(rows)
        self.assertEqual({r["background_id"] for r in results}, {"r1", "r2"})
        for result in results:
            expected = "first.txt" if result["background_id"] == "r1" else "second.txt"
            self.assertEqual([c["path"] for c in result["background_run"]["changes"]], [expected])

    def test_background_run_limit_keeps_ninth_run_foreground(self):
        self.server.case = "slots"
        events, rows, _ = self.finish(self.launch())
        starts = [e["background"] for e in events if e.get("background", {}).get("kind") == "run" and e["background"]["state"] == "started"]
        self.assertEqual(len(starts), 8)
        self.assertEqual(len(self.results(rows)), 8)
        runs = [e["run_end"]["output"] for e in events if "run_end" in e]
        self.assertIn("slot-result", runs[8])
        self.assertNotIn("continuing in background", runs[8])

    def test_stop_by_id_delivers_canceled_result(self):
        self.server.case = "stop"
        _, rows, _ = self.finish(self.launch())
        result = self.results(rows)[0]
        self.assertFalse(result["background_ok"])
        self.assertIn("run canceled", result["content"])
        self.assertFalse(alive(int((self.cwd / "worker.pid").read_text())))

    def test_cancel_cleans_process_and_resume_marks_lost(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
            with self.subTest(sig=sig):
                self.server.case = "crash" if sig == signal.SIGKILL else "cancel"
                self.server.requests.clear()
                self.server.followup.clear()
                self.server.release.clear()
                process = self.launch()
                self.assertTrue(self.server.followup.wait(5))
                pid = int((self.cwd / "worker.pid").read_text())
                process.send_signal(sig)
                stdout, _ = process.communicate(timeout=5)
                self.server.release.set()
                session = json.loads(stdout.splitlines()[0])["start"]["session_id"]
                if sig == signal.SIGKILL:
                    # SIGKILL cannot run Session cleanup; remove the orphan fixture ourselves.
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(pid, signal.SIGKILL)
                else:
                    self.assertFalse(alive(pid))
                self.server.case = "resume"
                self.server.requests.clear()
                _, rows, _ = self.finish(self.launch("--resume", session))
                results = self.results(rows)
                self.assertEqual(results[0]["background_id"], "r1")
                self.assertIn("lost: process ended", results[0]["content"])
                self.assertEqual(results[-1]["background_id"], "r2")
                self.assertIn("resumed-result", results[-1]["content"])

    def test_escape_cancels_background_run_in_tui(self):
        self.server.case = "cancel"
        terminal = Terminal(self.cwd, self.env)
        try:
            terminal.send("initial\r")
            self.assertTrue(self.server.followup.wait(5))
            terminal.until(b"r1 run")
            pid = int((self.cwd / "worker.pid").read_text())
            terminal.send("\x1b")
            wait_for(lambda: not alive(pid))
            terminal.until(b"canceled")
        finally:
            self.server.release.set()
            terminal.close()

    def test_small_run_stays_foreground(self):
        (self.home / "config.toml").write_text("[limits]\nrun_background_after_ms = 1000\n")
        _, rows, _ = self.finish(self.launch())
        self.assertEqual(self.results(rows), [])


if __name__ == "__main__":
    unittest.main()
