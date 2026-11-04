"""Background bash E2E against local provider mocks. Run after `zig build`."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import mock_agent
from mock_agent import reply
from mock_llm_tool import content
from test_agent import alive
from test_interjections import Terminal, history
from test_llm import records, wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def bash(command, **options):
    return "tools.bash(" + json.dumps({"command": command, "background": True, **options}) + ")"


def reply_codex_high_usage(handler, code, text):
    events = [
        {"type": "response.output_text.delta", "delta": text},
        {"type": "response.output_item.done", "output_index": 0, "item": {"type": "message"}},
        {"type": "response.output_item.done", "output_index": 1, "item": {
            "type": "function_call", "call_id": "agent_call", "name": "run",
            "arguments": json.dumps({"code": code})}},
        {"type": "response.completed", "response": {"status": "completed", "usage": {
            "input_tokens": 7000, "output_tokens": 20, "input_tokens_details": {"cached_tokens": 8}}}},
    ]
    data = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, case, cwd):
        self.case, self.cwd = case, cwd
        self.requests = []
        self.lock = threading.Lock()
        self.model_gate = threading.Event()
        self.child_gate = threading.Event()
        self.summary_seen = threading.Event()
        self.resume_launched = False
        super().__init__(("127.0.0.1", 0), Handler)

    def observed(self, prompt="initial"):
        with self.lock:
            return [r for r in self.requests if r["prompt"] == prompt]

    def waiting_command(self, name="worker"):
        started = self.cwd / (name + ".started")
        release = self.cwd / (name + ".release")
        return ("echo $$ > " + shlex.quote(str(started)) + "; while [ ! -f " +
                shlex.quote(str(release)) + " ]; do sleep .02; done; echo " + name + "-done")

    def first_code(self):
        if self.case == "overflow_ids":
            return ("for(let i=0;i<200;i++) await tools.glob({pattern:'*.missing'}); "
                    "await tools.agent({prompt:'child:foreground'}); "
                    "await tools.bash({command:'sleep 3.2'})")
        if self.case == "foreground_cancel":
            return ("await Promise.all([tools.bash({command:'sleep 30'}), "
                    "(async()=>{await tools.bash({command:'sleep 4'}); throw new Error('stop')})()])")
        if self.case in ("mixed", "resume_counters", "legacy_resume"):
            foreground = "await tools.agent({prompt:'child:foreground'}); "
            launches = ("const a = await tools.agent({prompt:'child:one',background:true}); " +
                        "const b = await " + bash(self.waiting_command()) + "; ")
            if self.case == "legacy_resume":
                return launches + "const c = await tools.agent({prompt:'child:one',background:true}); [a,b,c]"
            if self.case == "resume_counters":
                return (foreground + launches + foreground +
                        "await tools.bash({command:'sleep 5'}); [a,b]")
            return foreground + launches + "[a,b]"
        if self.case == "foreground_bash":
            commands = ["sleep 5; echo slow-one", "sleep 1; echo quick", "sleep 5; echo slow-two"]
            return "const results=[]; " + "; ".join(
                "results.push(await tools.bash(" + json.dumps({"command": command}) + "))"
                for command in commands) + "; results"
        if self.case == "child_bash":
            return "await tools.agent({prompt:'child:bash'})"
        if self.case == "run_failure":
            return "await " + bash(self.waiting_command()) + "; throw new Error('launching Run failed')"
        if self.case == "limit":
            return ("const ids=[]; for(let i=0;i<9;i++) { try { ids.push(await " +
                    bash(self.waiting_command("worker")) +
                    ") } catch(e) { ids.push({error:e.message}) } } ids")
        if self.case == "reject":
            return "try { await " + bash("sudo true") + " } catch(e) { e.message }"
        if self.case == "timeout":
            program = ("import os,time,pathlib; pathlib.Path('worker.started').write_text(str(os.getpid())); "
                       "time.sleep(30)")
            return "await " + bash(shlex.join([sys.executable, "-c", program]), timeout_ms=500)
        if self.case == "nonzero":
            return "await " + bash("echo failed; exit 7")
        if self.case == "long":
            return "await " + bash("python3 -c 'print(\"head:\" + \"z\" * 50000 + \":tail\")'")
        if self.case == "cancel":
            program = ("import os,time,pathlib; pathlib.Path('worker.started').write_text(str(os.getpid())); "
                       "time.sleep(30)")
            return "await " + bash(shlex.join([sys.executable, "-c", program]))
        return "await " + bash(self.waiting_command())


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        provider = "chat_completions" if "messages" in body else "codex"
        messages = body.get("messages", body.get("input", []))
        users = [content(m) for m in messages if m.get("role") == "user"]
        prompt = users[0]
        with self.server.lock:
            step = sum(r["prompt"] == prompt for r in self.server.requests)
            self.server.requests.append({"prompt": prompt, "step": step, "body": body, "messages": messages})
        code, text = None, "complete"
        if users[-1].startswith("Summarize the conversation above"):
            self.server.summary_seen.set()
            text = "s"
        elif prompt == "child:foreground":
            time.sleep(1.1)
            text = "foreground complete"
        elif prompt == "child:one":
            self.server.child_gate.wait(15)
            text = "child complete"
        elif prompt == "child:bash":
            if step == 0:
                code, text = "await " + bash("echo child-bash-done"), "child started"
            else:
                text = "child complete"
        elif prompt == "initial":
            if "resume" in users:
                if not self.server.resume_launched:
                    code = "await " + bash("echo resumed")
                    if self.server.case in ("resume_counters", "legacy_resume", "overflow_ids"):
                        code = ("await tools.agent({prompt:'child:foreground'}); "
                                "const a = await tools.agent({prompt:'child:one',background:true}); " +
                                "const b = await " + bash("echo resumed") + "; [a,b]")
                    self.server.resume_launched = True
                text = "resumed"
            elif step == 0:
                code, text = self.server.first_code(), "started"
            elif self.server.case in ("resume_counters", "legacy_resume") and step == 1:
                self.server.model_gate.wait(30)
            elif self.server.case in ("boundary", "compact") and step == 1:
                code, text = "42", "first continued step"
            elif self.server.case in ("boundary", "compact") and step == 2:
                if self.server.case == "boundary":
                    self.server.model_gate.wait(15)
                code, text = "43", "second continued step"
            else:
                text = "complete" if any(u.startswith("[background ") for u in users) else "early final"
                if self.server.case == "interjection" and step == 1:
                    self.server.model_gate.wait(15)
                if self.server.case == "max_steps" and step == 1:
                    code = "42"
            if self.server.case == "compact" and code is not None:
                text += "x" * 1000
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            if self.server.case == "compact" and provider == "codex" and code is not None:
                reply_codex_high_usage(self, code, text)
            elif self.server.case == "compact" and provider == "chat_completions" and code is not None:
                previous = mock_agent.USAGE
                mock_agent.USAGE = {"prompt_tokens": 7000, "completion_tokens": 20,
                                    "prompt_cache_hit_tokens": 8}
                try:
                    reply(self, provider, code, text)
                finally:
                    mock_agent.USAGE = previous
            else:
                reply(self, provider, code, text)


class BackgroundBashTests:
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nib-background-bash-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        self.home = self.tmp / "nib"
        self.home.mkdir()
        auth = self.tmp / "codex"
        auth.mkdir()
        (auth / "auth.json").write_text(json.dumps({"tokens": {
            "access_token": "fake", "account_id": "fake", "refresh_token": "fake", "id_token": "fake"}}))
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_", "MOCK_"))}
        self.env.update(NIB_PROVIDER=self.provider, NIB_API_KEY="fake", NIB_MODEL="mock-parent-model",
                        NIB_REASONING_EFFORT="high", NIB_CONTEXT_WINDOW="128000",
                        NIB_HOME=str(self.home), CODEX_HOME=str(auth), HOME=str(self.tmp), TERM="xterm-256color")

    def mock(self, case):
        mock = Mock(case, self.cwd)
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        self.env["NIB_BASE_URL"] = f"http://127.0.0.1:{mock.server_port}"

        def cleanup():
            mock.model_gate.set()
            mock.child_gate.set()
            for path in self.cwd.glob("*.started"):
                (self.cwd / (path.stem + ".release")).touch()
            mock.shutdown()
            mock.server_close()
            thread.join()
        self.addCleanup(cleanup)
        return mock

    def start(self, *args):
        process = subprocess.Popen([str(BIN), "ask", "--json", *(args or ("initial",))], cwd=self.cwd,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate()
        self.addCleanup(cleanup)
        return process

    def finish(self, process, ok=True):
        output, error = process.communicate(timeout=15)
        self.assertEqual(error, "")
        self.assertEqual(process.returncode == 0, ok, output)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertIn("end" if ok else "error", events[-1], events)
        return events

    def release(self, name="worker"):
        (self.cwd / (name + ".release")).touch()

    def completion(self, messages, id="b1"):
        return next(m for m in messages if content(m).startswith(f"[background bash {id} finished]\n"))

    def log(self, events):
        return records(self.home / "sessions" / (events[0]["start"]["session_id"] + ".jsonl"))

    def assert_progress_ids(self, events, expected):
        progress = [e["progress"] for e in events if "progress" in e]
        self.assertEqual({p["id"] for p in progress}, set(expected), progress)
        for p in progress:
            self.assertNotIn("agent", p)
            self.assertNotIn("background_id", p)
            self.assertIsInstance(p["id"], str)
            self.assertIs(type(p["background"]), bool)
            self.assertEqual((p["kind"], p["background"]), expected[p["id"]])

    def test_no_run_wait_and_result_metadata(self):
        mock = self.mock("basic")
        process = self.start()
        wait_for(lambda: len(mock.observed()) == 2)
        wait_for(lambda: (self.cwd / "worker.started").exists())
        self.assertIsNone(process.poll())
        self.release()
        events = self.finish(process)
        runs = [e["run_end"] for e in events if "run_end" in e]
        self.assertEqual(json.loads(runs[0]["output"].removeprefix("result: ")), {"id": "b1"})
        message = self.completion(mock.observed()[-1]["messages"])
        self.assertEqual(json.loads(content(message).split("\n", 1)[1]), {"exit_code": 0, "output": "worker-done\n"})
        self.assertNotIn("source", message)
        lifecycle = [e["background"] for e in events if "background" in e]
        self.assertEqual([(e["id"], e["kind"], e["state"]) for e in lifecycle],
                         [("b1", "bash", "started"), ("b1", "bash", "finished")])
        self.assertTrue(all("result" not in e for e in lifecycle))
        log = self.log(events)
        stored = [m for r in log for m in r.get("messages", []) if m.get("source") == "background"]
        self.assertEqual([(m["background_kind"], m["background_id"]) for m in stored], [("bash", "b1")])
        calls = [c for r in log for c in r.get("calls", []) if c["name"] == "bash"]
        self.assertEqual([(c["background"], c["id"]) for c in calls], [(True, "b1")])

    def test_two_steps_and_next_boundary(self):
        mock = self.mock("boundary")
        process = self.start()
        wait_for(lambda: len(mock.observed()) == 3)
        self.assertTrue(all(not any(content(m).startswith("[background bash") for m in r["messages"])
                            for r in mock.observed()))
        wait_for(lambda: (self.cwd / "worker.started").exists())
        self.release()
        wait_for(lambda: not alive(int((self.cwd / "worker.started").read_text())))
        mock.model_gate.set()
        events = self.finish(process)
        self.assertEqual(len(mock.observed()), 4)
        self.completion(mock.observed()[-1]["messages"])
        self.assertEqual(len([e for e in events if "run_end" in e]), 3)

    def test_completion_after_auto_compaction(self):
        self.env["NIB_CONTEXT_WINDOW"] = "8192"
        mock = self.mock("compact")
        process = self.start()
        wait_for(lambda: mock.summary_seen.is_set(), timeout=10)
        self.release()
        events = self.finish(process)
        self.assertTrue(any("compacted context" in e.get("notice", "") for e in events), events)
        self.completion(mock.requests[-1]["messages"])
        self.assertEqual(events[-1]["end"]["text"], "complete")

    def test_large_output_is_bounded(self):
        mock = self.mock("long")
        events = self.finish(self.start())
        message = self.completion(mock.observed()[-1]["messages"])
        self.assertLessEqual(len(content(message).encode()), 16 * 1024)
        self.assertIn("bytes omitted]", content(message))
        self.assertIn("head:", content(message))
        self.assertIn(":tail", content(message))
        self.assertEqual(events[-1]["end"]["text"], "complete")

    def test_nonzero_exit_is_result(self):
        mock = self.mock("nonzero")
        self.finish(self.start())
        result = json.loads(content(self.completion(mock.observed()[-1]["messages"])).split("\n", 1)[1])
        self.assertEqual(result, {"exit_code": 7, "output": "failed\n"})

    def test_timeout_is_delivered_and_process_group_stops(self):
        mock = self.mock("timeout")
        events = self.finish(self.start())
        result = json.loads(content(self.completion(mock.observed()[-1]["messages"])).split("\n", 1)[1])
        self.assertRegex(result["error"].lower(), "timed.out|timeout")
        self.assertFalse(next(e["background"]["ok"] for e in events
                              if e.get("background", {}).get("state") == "finished"))
        pid = int((self.cwd / "worker.started").read_text())
        wait_for(lambda: not alive(pid))

    def test_policy_rejection_does_not_start_background_job(self):
        mock = self.mock("reject")
        events = self.finish(self.start())
        self.assertFalse([e for e in events if "background" in e])
        self.assertIn("refused by nib", next(e["run_end"]["output"] for e in events if "run_end" in e))
        self.assertFalse([r for r in self.log(events) if r.get("background")])

    def test_failed_launching_run_does_not_cancel_started_job(self):
        mock = self.mock("run_failure")
        process = self.start()
        wait_for(lambda: (self.cwd / "worker.started").exists())
        self.release()
        events = self.finish(process)
        self.assertFalse(next(e["run_end"]["ok"] for e in events if "run_end" in e))
        self.assertTrue(any(e.get("background", {}).get("state") == "finished" for e in events))
        self.completion(mock.observed()[-1]["messages"])
        self.assertEqual(events[-1]["end"]["text"], "complete")

    def test_limit_rejects_ninth_without_starting_it(self):
        (self.home / "config.toml").write_text("[limits]\nagent_concurrency = 1\n")
        mock = self.mock("limit")
        process = self.start()
        wait_for(lambda: len(list(self.cwd.glob("*.started"))) == 1)
        # One command is reused, so eight jobs start and each appends to the same marker.
        wait_for(lambda: len([e for e in records(next((self.home / "sessions").glob("?" * 32 + ".jsonl")))
                              if e.get("background", {}).get("state") == "started"]) == 8)
        self.release()
        events = self.finish(process)
        output = next(e["run_end"]["output"] for e in events if "run_end" in e)
        self.assertIn("error", output)
        self.assertEqual(len([e for e in events if e.get("background", {}).get("state") == "started"]), 8)

    def test_ids_beyond_timing_capacity_survive_resume(self):
        mock = self.mock("overflow_ids")
        events = self.finish(self.start())
        rows = self.log(events)
        step = next(r for r in rows if r.get("calls_omitted"))
        self.assertEqual((len(step["calls"]), step["calls_omitted"]), (200, 2))
        self.assertTrue(all("id" not in c for c in step["calls"]))
        self.assertEqual(step["task_ids"], {"agent": 1, "bash": 1})
        self.assert_progress_ids(events, {"a1": ("agent", False), "b1": ("bash", False)})
        mock.child_gate.set()
        resumed = self.finish(self.start("--resume", events[0]["start"]["session_id"], "resume"))
        self.assert_progress_ids(resumed, {"a2": ("agent", False), "a3": ("agent", True), "b2": ("bash", True)})
        lifecycle = [e["background"] for e in resumed if e.get("background", {}).get("state") == "started"]
        self.assertEqual({e["id"] for e in lifecycle}, {"a3", "b2"})

    def test_failed_run_flushes_frontend_cancellation_before_run_end(self):
        self.mock("foreground_cancel")
        events = self.finish(self.start())
        updates = [(i, e["progress"]) for i, e in enumerate(events)
                   if e.get("progress", {}).get("prompt") == "sleep 30"]
        self.assertTrue(updates)
        self.assertEqual(updates[-1][1]["state"], "canceled", updates)
        end_index = next(i for i, e in enumerate(events) if "run_end" in e)
        self.assertLess(updates[-1][0], end_index)
        self.assertFalse(events[end_index]["run_end"]["ok"])

    def test_foreground_and_background_agents_share_ids_bash_is_independent(self):
        mock = self.mock("mixed")
        process = self.start()
        wait_for(lambda: (self.cwd / "worker.started").exists())
        mock.child_gate.set()
        self.release()
        events = self.finish(process)
        first = next(e["run_end"]["output"] for e in events if "run_end" in e)
        self.assertEqual(json.loads(first.removeprefix("result: ")), [{"id": "a2"}, {"id": "b1"}])
        lifecycle = [e["background"] for e in events if e.get("background", {}).get("state") == "started"]
        self.assertEqual([(e["id"], e["kind"]) for e in lifecycle], [("a2", "agent"), ("b1", "bash")])
        calls = [c for r in self.log(events) for c in r.get("calls", [])]
        self.assertEqual([(c["name"], c["id"], c.get("background", False)) for c in calls],
                         [("agent", "a1", False), ("agent", "a2", True), ("bash", "b1", True)])
        self.assert_progress_ids(events, {"a1": ("agent", False), "a2": ("agent", True), "b1": ("bash", True)})
        messages = mock.observed()[-1]["messages"]
        self.completion(messages, "b1")
        self.assertTrue(any(content(m).startswith("[background agent a2 finished]\n") for m in messages))
        logged = [m for r in self.log(events) for m in r.get("messages", [])
                  if m.get("source") == "background"]
        self.assertEqual({m["background_id"] for m in logged}, {"a2", "b1"})

    def test_foreground_bash_delays_progress_and_keeps_two_completed_ids(self):
        self.mock("foreground_bash")
        started = time.monotonic()
        process = self.start()
        pending, events, updates = b"", [], []
        deadline = started + 25
        fd = process.stdout.fileno()
        while time.monotonic() < deadline:
            if not select.select([fd], [], [], .1)[0]:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                event = json.loads(line)
                events.append(event)
                if "progress" in event:
                    p = event["progress"]
                    updates.append((time.monotonic() - started, p))
                    if p["state"] == "working":
                        self.assertIsNone(process.poll(), "progress was buffered until exit")
        else:
            self.fail("foreground bash did not finish within 25 seconds")
        output, error = process.communicate(timeout=5)
        self.assertEqual((process.returncode, output, error, pending), (0, "", "", b""))
        self.assertIn("end", events[-1])
        self.assertFalse(any("background" in e for e in events))
        self.assert_progress_ids(events, {"b1": ("bash", False), "b2": ("bash", False)})
        completed = {}
        for id in ("b1", "b2"):
            samples = [(stamp, p) for stamp, p in updates if p["id"] == id]
            elapsed = [p["elapsed_ms"] for _, p in samples]
            self.assertGreaterEqual(len(samples), 2, samples)
            self.assertGreaterEqual(elapsed[0], 3000, samples)
            self.assertEqual(elapsed, sorted(elapsed), samples)
            self.assertGreater(elapsed[-1], elapsed[0], samples)
            self.assertTrue(any(p["state"] == "working" for _, p in samples), samples)
            self.assertEqual(samples[-1][1]["state"], "done", samples)
            self.assertGreaterEqual(elapsed[-1], 4900, samples)
            completed[id] = samples[-1]
        self.assertGreaterEqual(updates[0][0], 2.8, updates)
        self.assertLess(completed["b1"][0], next(stamp for stamp, p in updates if p["id"] == "b2"))
        calls = [c for r in self.log(events) for c in r.get("calls", []) if c["name"] == "bash"]
        self.assertEqual([c.get("id") for c in calls], ["b1", None, "b2"])
        self.assertTrue(all(not c.get("background", False) for c in calls))
        self.assertTrue(all(c["ok"] for c in calls))
        for call in (calls[0], calls[2]):
            self.assertLessEqual(abs(completed[call["id"]][1]["elapsed_ms"] -
                                     (call["end_ms"] - call["start_ms"])), 500, call)
        result = json.loads(next(e["run_end"]["output"] for e in events if "run_end" in e)
                            .removeprefix("result: "))
        self.assertEqual(result, [{"exit_code": 0, "output": text + "\n"}
                                  for text in ("slow-one", "quick", "slow-two")])

    def check_killed_parent_resumes_independent_counters(self, legacy=False):
        mock = self.mock("legacy_resume" if legacy else "resume_counters")
        process = self.start()
        expected_calls = ["a1", "b1", "a2"] if legacy else ["a1", "a2", "b1", "a3", "b2"]

        def persisted():
            for path in (self.home / "sessions").glob("?" * 32 + ".jsonl"):
                calls = [c for r in records(path) for c in r.get("calls", [])]
                if [c.get("id") for c in calls] == expected_calls:
                    return path
            return None

        root_log = wait_for(persisted, timeout=15)
        wait_for(lambda: len(mock.observed()) == 2)
        process.kill()
        process.communicate(timeout=5)
        self.release()
        if legacy:
            mapping = {"b1": "b2", "a2": "a3"}
            rows = records(root_log)
            rows[1:] = [json.loads(re.sub(r"\b(?:b1|a2)\b", lambda m: mapping[m[0]], json.dumps(row)))
                        for row in rows[1:]]
            for row in rows:
                row.pop("task_ids", None)
            root_log.write_text("".join(json.dumps(row) + "\n" for row in rows))
        before = len(records(root_log))
        resumed = self.start("--resume", root_log.stem, "resume")
        wait_for(lambda: any(r.get("background", {}).get("id") == "a5" and
                             r["background"]["state"] == "started" for r in records(root_log)[before:]))
        mock.child_gate.set()
        events = self.finish(resumed)
        self.assertEqual(events[0]["start"]["session_id"], root_log.stem)
        lifecycle = [e["background"] for e in events if "background" in e]
        lost = {e["id"] for e in lifecycle if e["state"] == "lost"}
        self.assertEqual(lost, {"a1", "b2", "a3"} if legacy else {"a2", "b1"})
        for state in ("started", "finished"):
            self.assertEqual({e["id"] for e in lifecycle if e["state"] == state}, {"a5", "b3"})
        calls = [c for r in records(root_log)[before:] for c in r.get("calls", [])]
        self.assertEqual([(c["id"], c.get("background", False)) for c in calls],
                         [("a4", False), ("a5", True), ("b3", True)])
        self.assert_progress_ids(events, {"a4": ("agent", False), "a5": ("agent", True), "b3": ("bash", True)})
        messages = mock.observed()[-1]["messages"]
        self.completion(messages, "b3")
        self.assertTrue(any(content(m).startswith("[background agent a5 finished]\n") for m in messages))
        self.assertFalse(any(content(m).startswith(f"[background {kind} {id} finished]\n")
                             for m in messages for id in lost for kind in ("agent", "bash")))

    def test_killed_parent_resumes_max_ids_including_foreground_calls(self):
        self.check_killed_parent_resumes_independent_counters()

    def test_killed_parent_resumes_legacy_shared_counter_log(self):
        self.check_killed_parent_resumes_independent_counters(legacy=True)

    def test_subagent_can_launch_background_bash(self):
        mock = self.mock("child_bash")
        events = self.finish(self.start())
        child = mock.observed("child:bash")
        self.assertGreaterEqual(len(child), 2)
        self.completion(child[-1]["messages"])
        self.assertEqual(events[-1]["end"]["text"], "early final")
        logs = [r for path in (self.home / "sessions").glob("?" * 32 + ".jsonl")
                for r in records(path)]
        self.assertTrue(any(m.get("background_kind") == "bash" for r in logs
                            for m in r.get("messages", [])))

    def test_sigint_stops_background_process(self):
        self.mock("cancel")
        process = self.start()
        path = self.cwd / "worker.started"
        wait_for(lambda: path.exists())
        pid = int(path.read_text())
        process.send_signal(signal.SIGINT)
        self.finish(process, ok=False)
        wait_for(lambda: not alive(pid))

    def test_max_steps_stops_background_process(self):
        (self.home / "config.toml").write_text("[limits]\nmax_steps = 2\n")
        self.mock("max_steps")
        process = self.start()
        path = self.cwd / "worker.started"
        wait_for(lambda: path.exists())
        pid = int(path.read_text())
        events = self.finish(process, ok=False)
        self.assertIn("stopped after 2 steps", json.dumps(events[-1]))
        wait_for(lambda: not alive(pid))

    def test_killed_parent_marks_job_lost_and_advances_id_on_resume(self):
        mock = self.mock("resume")
        process = self.start()
        wait_for(lambda: (self.cwd / "worker.started").exists())
        root_log = wait_for(lambda: next((p for p in (self.home / "sessions").glob("?" * 32 + ".jsonl")
                                          if any(r.get("background", {}).get("state") == "started"
                                                 for r in records(p))), None))
        process.kill()
        process.communicate(timeout=5)
        self.release()
        resumed = self.start("--resume", root_log.stem, "resume")
        events = self.finish(resumed)
        lifecycle = [e["background"] for e in events if "background" in e]
        self.assertIn(("b1", "lost"), [(e["id"], e["state"]) for e in lifecycle])
        self.assertIn(("b2", "started"), [(e["id"], e["state"]) for e in lifecycle])
        self.assertIn(("b2", "finished"), [(e["id"], e["state"]) for e in lifecycle])
        self.assertFalse(any(content(m).startswith("[background bash b1 finished]")
                             for r in mock.observed() for m in r["messages"]))


class ChatTests(BackgroundBashTests, unittest.TestCase):
    provider = "chat_completions"

    def test_progress_updates_while_model_stream_is_stalled(self):
        mock = self.mock("boundary")
        process = self.start()
        wait_for(lambda: len(mock.observed()) == 3)
        fd = process.stdout.fileno()
        output = b""
        deadline = time.monotonic() + 4
        seen = False
        while time.monotonic() < deadline and not seen:
            if select.select([fd], [], [], .1)[0]:
                output += os.read(fd, 65536)
                lines = output.split(b"\n")
                seen = any(event.get("progress", {}).get("kind") == "bash" and
                           event["progress"].get("elapsed_ms", 0) >= 1000
                           for line in lines[:-1] if line for event in [json.loads(line)])
        self.assertTrue(seen, output[-2000:])
        self.assertEqual(len(mock.observed()), 3)
        self.release()
        mock.model_gate.set()
        rest, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, error)
        self.assertIn("end", json.loads((output + rest.encode()).splitlines()[-1]))

    def test_interjection_precedes_background_result(self):
        mock = self.mock("interjection")
        terminal = Terminal(self.cwd, self.env)
        self.addCleanup(terminal.close)
        terminal.send("initial\r")
        wait_for(lambda: len(mock.observed()) == 2)
        terminal.send("while waiting\r")
        terminal.until(b"queued")
        wait_for(lambda: (self.cwd / "worker.started").exists())
        self.release()
        wait_for(lambda: not alive(int((self.cwd / "worker.started").read_text())))
        mock.model_gate.set()
        request = wait_for(lambda: next((r for r in mock.observed()
                                         if any(content(m).startswith("[background bash b1 finished]")
                                                for m in r["messages"])), None))
        users = [content(m) for m in request["messages"] if m.get("role") == "user"]
        self.assertEqual(users[0:2], ["initial", "while waiting"])
        self.assertTrue(users[2].startswith("[background bash b1 finished]\n"), users)
        wait_for(lambda: history(self.home)[-1].get("content") == "complete")

    def test_escape_stops_background_process_group(self):
        self.mock("cancel")
        terminal = Terminal(self.cwd, self.env)
        self.addCleanup(terminal.close)
        terminal.send("initial\r")
        path = self.cwd / "worker.started"
        wait_for(lambda: path.exists())
        pid = int(path.read_text())
        terminal.send("\x1b")
        terminal.until(b"canceled")
        wait_for(lambda: not alive(pid))
        self.assertFalse(any(m.get("source") == "background" for m in history(self.home)))


class CodexTests(BackgroundBashTests, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
