"""Stream idle timeout E2E, using loopback mocks and temporary homes only.

Run after building the timeout implementation (about 90 seconds):
    zig build
    python3 tests/test_stream_idle.py
    python3 tests/test_stream_idle.py CodexTests.test_main_retries_idle_attempt
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

from mock_stream_idle import Mock
from test_llm import records

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


class StreamIdleTests:
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nib-stream-idle-" + self.provider + "-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        self.home = self.tmp / "nib"
        self.home.mkdir()
        (self.home / "config.toml").write_text("[limits]\nstream_idle_timeout_s = 1\n")
        auth = self.tmp / "codex"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake-idle-access", "account_id": "fake-idle-account",
            "refresh_token": "fake-idle-refresh", "id_token": "fake-idle-id"}}))
        self.server = Mock(self.provider)
        self.server.config_path = self.home / "config.toml"
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": .02}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_", "MOCK_"))}
        self.env.update(NIB_PROVIDER=self.provider, NIB_API_KEY="fake-idle-key",
                        NIB_BASE_URL=f"http://127.0.0.1:{self.server.server_port}",
                        NIB_MODEL="mock-idle-model", NIB_REASONING_EFFORT="high",
                        NIB_CONTEXT_WINDOW="128000", NIB_HOME=str(self.home),
                        CODEX_HOME=str(auth), HOME=str(self.tmp),
                        XDG_CONFIG_HOME=str(self.tmp / "config"),
                        XDG_DATA_HOME=str(self.tmp / "data"), NO_PROXY="127.0.0.1,localhost")

    def stop_server(self):
        self.server.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.assertFalse(self.server.errors, "\n".join(self.server.errors))

    def ask(self, prompt, *args, ok=True):
        result = subprocess.run([str(BIN), "ask", "--json", prompt, *args],
                                cwd=self.cwd, env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "", result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertIn("start", events[0], events)
        self.assertIn("end" if ok else "error", events[-1], events)
        session_id = events[0]["start"]["session_id"]
        log = self.home / "sessions" / (session_id + ".jsonl")
        return events, log, records(log)

    def assert_timeout(self, message):
        self.assertRegex(message, r"(?i)stream\s*idle\s*timeout")
        self.assertRegex(message, r"\b1\s*(?:s\b|second)")

    def assert_gap(self, step, minimum=100):
        gap = step.get("max_gap_ms")
        self.assertIs(type(gap), int, step)
        self.assertGreaterEqual(gap, minimum, step)
        self.assertLess(gap, 1000, step)
        self.assertLessEqual(gap, step["model_ms"], step)

    def test_main_retries_idle_attempt(self):
        events, _, log = self.ask("retry")
        self.assertEqual(events[-1]["end"]["text"], "complete")
        retries = [e["retry"] for e in events if "retry" in e]
        self.assertEqual([r["attempt"] for r in retries], [1], events)
        self.assert_timeout(retries[0]["reason"])
        attempts = self.server.observed("main")
        self.assertEqual(len(attempts), 2)
        self.assertLess(attempts[1]["at"] - attempts[0]["at"], 4, attempts)
        steps = [r for r in log if "model_ms" in r]
        self.assertEqual(len(steps), 1, log)
        self.assertEqual(steps[0]["attempts"], 2, steps)
        # Failed-attempt gaps and retry backoff must not leak into this metric.
        self.assert_gap(steps[0])
        self.assertFalse(any(r.get("diagnostic") for r in log), log)

    def test_content_and_request_deadlines(self):
        for prompt, expected in (("content-heartbeats", "StreamContentTimeout"),
                                 ("content-metadata", "StreamContentTimeout"),
                                 ("request-progress", "ModelRequestTimeout")):
            with self.subTest(prompt=prompt):
                with self.server.lock:
                    self.server.requests.clear()
                (self.home / "config.toml").write_text(
                    "[limits]\nstream_idle_timeout_s = 3\nstream_content_timeout_s = " +
                    ("3" if prompt == "request-progress" else "1") +
                    "\nrequest_timeout_s = " + ("1" if prompt == "request-progress" else "3") + "\n")
                events, _, log = self.ask(prompt)
                self.assertEqual(len([e for e in events if "retry" in e]), 1, events)
                step = next(r for r in log if "model_ms" in r)
                attempts = step["model_attempts"]
                self.assertEqual(len(attempts), 2)
                self.assertEqual(attempts[0]["error_name"], expected)
                self.assertGreater(attempts[0]["bytes"], 0)
                self.assertEqual(attempts[0]["content_bytes"] > 0, prompt == "request-progress")
                self.assertLess(attempts[0]["end_ms"] - attempts[0]["start_ms"], 2000)
                self.assertIsNone(attempts[1].get("error_name"))

    def test_reasoning_progress_extends_content_deadline(self):
        (self.home / "config.toml").write_text(
            "[limits]\nstream_idle_timeout_s = 3\nstream_content_timeout_s = 1\nrequest_timeout_s = 3\n")
        events, _, log = self.ask("content-progress")
        self.assertFalse(any("retry" in e for e in events), events)
        step = next(r for r in log if "model_ms" in r)
        self.assertGreater(step["model_ms"], 1200)
        self.assertLess(step["max_content_gap_ms"], 1000)
        self.assertGreater(step["model_attempts"][0]["content_bytes"], 0)

    def test_tools_llm_retries_after_partial_reply(self):
        events, _, log = self.ask("llm-retry")
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(len(runs), 1, events)
        self.assertTrue(runs[0]["ok"], runs)
        reply = json.loads(runs[0]["output"].removeprefix("result: "))
        self.assertEqual(reply["text"], "child complete", reply)
        self.assertEqual(reply["usage"]["prompt_tokens"], 100, reply)
        self.assertEqual(reply["usage"]["completion_tokens"], 7, reply)
        attempts = self.server.observed("llm")
        self.assertEqual(len(attempts), 2)
        # Leave scheduling slack while distinguishing the ten-second EOF fallback.
        self.assertLess(attempts[1]["at"] - attempts[0]["at"], 4, attempts)
        self.assertEqual(len(self.server.observed("main")), 1)
        self.assertEqual(len(self.server.observed("followup")), 1)
        self.assertFalse(any("retry" in e for e in events), events)
        self.assertNotIn("discarded partial reply", json.dumps(events))
        self.assertNotIn("discarded partial reply", json.dumps(log))
        self.assertEqual(events[-1]["end"]["text"], "outer complete")

    def test_exhausted_retries_fail_clearly(self):
        events, _, log = self.ask("exhausted", ok=False)
        self.assert_timeout(events[-1]["error"]["message"])
        retries = [e["retry"] for e in events if "retry" in e]
        self.assertEqual([r["attempt"] for r in retries], [1, 2, 3, 4], events)
        for retry in retries:
            self.assert_timeout(retry["reason"])
        self.assertEqual(len(self.server.observed("main")), 5)
        self.assertEqual(events[-1]["error"]["steps"], 0)
        diagnostics = [r["diagnostic"] for r in log if r.get("diagnostic")]
        if self.provider == "codex":
            self.assertEqual(len(diagnostics), 1, log)
        for diagnostic in diagnostics:
            self.assertEqual(diagnostic["error_name"], "StreamIdleTimeout")
            self.assertEqual(diagnostic["attempts"], 5)
            self.assert_timeout(diagnostic["message"])
        self.assertFalse(any("model_ms" in r for r in log), log)
        self.assertFalse(any(m.get("role") == "assistant"
                             for r in log for m in r.get("messages", [])), log)

    def assert_kept_alive(self, prompt):
        events, _, log = self.ask(prompt)
        self.assertEqual(events[-1]["end"]["text"], "complete")
        self.assertFalse(any("retry" in e for e in events), events)
        self.assertEqual(len(self.server.observed("main")), 1)
        steps = [r for r in log if "model_ms" in r]
        self.assertEqual(len(steps), 1, log)
        self.assertEqual(steps[0]["attempts"], 1, steps)
        self.assert_gap(steps[0])
        return steps[0]

    def test_first_body_wait_is_not_a_gap(self):
        events, _, log = self.ask('delayed-first-body')
        self.assertEqual(events[-1]['end']['text'], 'complete')
        step = next(r for r in log if 'model_ms' in r)
        self.assertGreaterEqual(step['first_data_ms'], 600, step)
        self.assert_gap(step, minimum=100)
        self.assertLess(step['max_gap_ms'], 500, step)
        self.assertEqual(step['attempts'], 1)

    def test_visible_partial_preserves_replay_boundary(self):
        safe = self.provider == 'codex'
        events, _, log = self.ask('visible-partial', ok=safe)
        attempts = self.server.observed('main')
        self.assertEqual(len(attempts), 2 if safe else 1, attempts)
        if safe:
            self.assertEqual(events[-1]['end']['text'], 'complete')
            self.assertNotIn('discarded visible partial', json.dumps(log))
            step = next(r for r in log if 'model_ms' in r)
            self.assertEqual(step['attempts'], 2)
            self.assert_gap(step)
        else:
            self.assert_timeout(events[-1]['error']['message'])
            self.assertFalse(any('retry' in e for e in events), events)
        self.assertTrue(any('discarded visible partial' in e.get('delta', {}).get('text', '')
                            for e in events), events)

    def test_summary_retries_without_committing_failed_text(self):
        self.env['NIB_CONTEXT_WINDOW'] = '32768'
        for index in range(3):
            self.ask('compact-seed', *(['--continue'] if index else []))
        events, _, log = self.ask('after compact', '--continue')
        attempts = self.server.observed('summary')
        self.assertEqual(len(attempts), 2, attempts)
        self.assertLess(attempts[1]['at'] - attempts[0]['at'], 4, attempts)
        self.assertTrue(any('compacted context:' in e.get('notice', '') for e in events), events)
        self.assertNotIn('discarded partial summary', json.dumps(log))
        self.assertNotIn('discarded partial summary', json.dumps(events))
        self.assertTrue(any(m.get('content', '').startswith('Earlier session summary:\nidle summary complete')
                            for r in log for m in r.get('messages', [])), log)
        self.assertEqual(events[-1]['end']['text'], 'complete')

    def test_child_inherits_timeout_without_rereading_config(self):
        events, _, _ = self.ask('agent-inherit')
        run = next(e['run_end'] for e in events if 'run_end' in e)
        self.assertTrue(run['ok'], run)
        child = json.loads(run['output'].removeprefix('result: '))
        self.assertTrue(child['ok'], child)
        self.assertEqual(child['text'], 'child complete', child)
        attempts = self.server.observed('agent')
        self.assertEqual(len(attempts), 2, attempts)
        self.assertLess(attempts[1]['at'] - attempts[0]['at'], 4, attempts)
        self.assertEqual(self.server.config_path.read_text(), '[limits]\nstream_idle_timeout_s = 0\n')
        self.assertEqual(events[-1]['end']['text'], 'outer complete')

    def test_pauses_shorter_than_timeout(self):
        self.assert_kept_alive("short-pauses")

    def test_heartbeats_keep_stream_alive(self):
        step = self.assert_kept_alive("heartbeats")
        self.assertGreaterEqual(step["model_ms"], 1200, step)

    def test_partial_bytes_without_newline_keep_stream_alive(self):
        step = self.assert_kept_alive("partial-bytes")
        self.assertGreaterEqual(step["model_ms"], 1200, step)

    def test_resume_log_without_max_gap(self):
        events, path, log = self.ask("short-pauses")
        session_id = events[0]["start"]["session_id"]
        for record in log:
            record.pop("max_gap_ms", None)
        path.write_text("".join(json.dumps(r) + "\n" for r in log))
        resumed, resumed_path, new_log = self.ask("resume", "--resume", session_id)
        self.assertEqual(resumed_path, path)
        self.assertEqual(resumed[-1]["end"]["text"], "complete")
        self.assertEqual(new_log[:len(log)], log)
        new_steps = [r for r in new_log[len(log):] if "model_ms" in r]
        self.assertEqual(len(new_steps), 1, new_log)
        self.assert_gap(new_steps[0])
        request = self.server.observed("main")[-1]["body"]
        messages = request.get("messages", request.get("input", []))
        self.assertTrue(any(m.get("role") == "assistant" and m.get("content") == "complete"
                            for m in messages), messages)


class ChatTests(StreamIdleTests, unittest.TestCase):
    provider = "chat_completions"


class CodexTests(StreamIdleTests, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
