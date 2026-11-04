"""Replay and /reflect privacy E2E, temporary NIB_HOME and local mock only.

Run after zig build: python3 tests/test_replay.py
"""
import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import stat
import subprocess
import tempfile
import threading
import unittest

from test_interjections import Terminal, wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.replies = queue.Queue()
        self.requests = []
        super().__init__(("127.0.0.1", 0), Handler)

    def reply(self, *, codes=(), text="mock finished"):
        self.replies.put((codes, text))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(body)
        codes, text = self.server.replies.get(timeout=5)
        delta = {"content": text, "reasoning_content": "mock reasoning"}
        if codes:
            delta["tool_calls"] = [
                {"index": n, "id": f"run-{len(self.server.requests)}-{n}", "type": "function",
                 "function": {"name": "run", "arguments": json.dumps({"code": code})}}
                for n, code in enumerate(codes)]
        events = [{"choices": [{"delta": delta}]},
                  {"choices": [{"delta": {}, "finish_reason": "tool_calls" if codes else "stop"}],
                   "usage": {"prompt_tokens": 100, "completion_tokens": 10}}]
        data = ("".join("data: " + json.dumps(event) + "\n\n" for event in events)
                + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(data)


class ReplayTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="nib-replay-")
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.cwd = self.tmp / "project"
        self.cwd.mkdir()
        (self.cwd / ".git").mkdir()
        self.home = self.tmp / "nib"
        self.home.mkdir()
        self.mock = Mock()
        thread = threading.Thread(target=self.mock.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.mock.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(self.mock.shutdown)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
        self.env.update(NIB_HOME=str(self.home), HOME=str(self.tmp), TERM="xterm-256color",
                        NIB_PROVIDER="chat_completions", NIB_API_KEY="local-mock-only",
                        NIB_MODEL="mock-replay", NIB_BASE_URL=f"http://127.0.0.1:{self.mock.server_port}")

    def command(self, *args, env=None, check=True):
        result = subprocess.run([str(BIN), *args], cwd=self.cwd, env=env or self.env,
                                text=True, capture_output=True, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, (args, result.stdout, result.stderr))
        return result

    def ask(self, codes, *, resume=None):
        self.mock.reply(codes=codes)
        self.mock.reply()
        args = ["ask", "--json", "record this mock session"]
        if resume:
            args += ["--resume", resume]
        events = [json.loads(line) for line in self.command(*args).stdout.splitlines()]
        return events[0]["start"]["session_id"]

    def calls_path(self, session):
        return self.home / "sessions" / f"{session}.calls.jsonl"

    def replay(self, session, *args, check=True):
        result = self.command("replay", session, "--json", *args, check=check)
        return json.loads(result.stdout)

    def record_files(self):
        (self.cwd / "sample.txt").write_text("alpha\nbeta\nalpha\n")
        return self.ask([
            'console.log(await tools.read({path: "sample.txt"})); '
            'console.log(await tools.grep({path: "sample.txt", pattern: "alpha"})); '
            'console.log(await tools.read({path: "sample.txt"}));',
            'console.log(await tools.bash({command: "printf side > side-effect; printf bash-output"}));',
        ])

    def test_all_and_session_global_step_indices_without_side_effects(self):
        session = self.record_files()
        self.ask(['console.log(await tools.read({path: "sample.txt"}));'], resume=session)
        path = self.calls_path(session)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        rows = jsonl(path)
        self.assertEqual([(r["step"], r["run"]) for r in rows if "meta" in r],
                         [(1, 0), (1, 1), (3, 0)])
        calls = [r for r in rows if "index" in r]
        self.assertEqual({r["name"] for r in calls}, {"read", "grep", "bash"})
        for row in calls:
            if isinstance(row.get("result"), dict):
                self.assertEqual(row["result"], {"same_as": row["sha256"]})
                self.assertNotIn("error", row)
            else:
                raw = row["result"] if row["ok"] else row["error"]
                self.assertEqual(hashlib.sha256(raw.encode()).hexdigest(), row["sha256"])
        self.assertTrue(any(isinstance(r.get("result"), dict) for r in calls), calls)
        for row in rows:
            self.assertNotIn("type", row)
            self.assertNotIn("same_as", row)
        for key in {(r["step"], r["run"]) for r in rows}:
            run_rows = [r for r in rows if (r["step"], r["run"]) == key]
            self.assertEqual(sum("meta" in r for r in run_rows), 1)
            self.assertEqual(set(run_rows[-1]), {"step", "run", "meta"})
            self.assertEqual(set(run_rows[-1]["meta"]), {"start_ms_epoch", "end"})
        (self.cwd / "sample.txt").unlink()
        (self.cwd / "side-effect").unlink()
        before = len(self.mock.requests)
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 3, report)
        self.assertEqual(report["matched"], 3, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual(report["differences"], [], report)
        self.assertEqual(report["undetermined"], 0, report)
        single = self.replay(session, "--run", "1:1")
        self.assertTrue(single["match"], single)
        self.assertIn("bash-output", single["output"])
        self.assertFalse(single["incomplete"], single)
        self.assertEqual(len(self.mock.requests), before)
        self.assertFalse((self.cwd / "sample.txt").exists())
        self.assertFalse((self.cwd / "side-effect").exists())

    def test_sleep_records_and_replays_without_real_wait(self):
        session = self.ask([
            'const pending = tools.sleep(80); '
            'console.log(await tools.sleep(5)); await pending; console.log("awake");'
        ])
        path = self.calls_path(session)
        rows = jsonl(path)
        calls = [r for r in rows if "index" in r]
        self.assertEqual([(r["index"], r["seq"], r["name"], r["args"]) for r in calls],
                         [(1, 0, "sleep", 5), (0, 1, "sleep", 80)])
        self.assertTrue(all(r["ok"] for r in calls))
        self.assertEqual(calls[0]["result"], "null")
        self.assertEqual(calls[1]["result"], {"same_as": calls[0]["sha256"]})
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["match"], report)
        self.assertIn("awake", report["output"])
        # Matching long recorded waits must not turn into real replay timers.
        for row in rows:
            if "index" in row:
                row["args"] = 2147483647
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        script = self.cwd / "sleep.js"
        script.write_text('console.log(await tools.sleep(2147483647)); '
                          'await tools.sleep(2147483647); console.log("awake");')
        report = self.replay(session, "--run", "1:0", "--script", str(script))
        self.assertIn("awake", report["output"])
        self.assertFalse(report["incomplete"], report)

    def test_worker_and_expired_sleep_replay_preserve_microtask_checkpoints(self):
        session = self.ask([
            'const p = tools.bash({command: "printf ready"}); await tools.sleep(0); '
            'let n = 0; for (let i = 0; i < 20000000; i++) n += i; '
            'const q = tools.sleep(0); console.log(await Promise.race(['
            'p.then(() => "worker").then(x => x).then(x => x), q.then(() => "timer")]));'
        ])
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["match"], report)
        self.assertFalse(report["incomplete"], report)

    def test_rejected_run_discards_sleep_without_fabricating_a_settlement(self):
        session = self.ask(['tools.sleep(2147483647); throw new Error("stop");'])
        rows = jsonl(self.calls_path(session))
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(rows[0]["meta"]["end"], "error")
        self.assertTrue(rows[0]["meta"]["incomplete"])
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["incomplete"], report)
        self.assertIsNone(report["match"])

    def test_record_off_creates_no_calls_file(self):
        self.env["NIB_RECORD"] = "off"
        (self.cwd / "sample.txt").write_text("off probe")
        session = self.ask(['console.log(await tools.read({path: "sample.txt"}));'])
        self.assertFalse(self.calls_path(session).exists())
        self.assertTrue((self.home / "sessions" / f"{session}.jsonl").exists())
        self.assertIn("No replay recording",
                      self.command("replay", session, "--all", check=False).stderr)

    def test_parent_and_child_have_separate_recordings(self):
        (self.cwd / "child.txt").write_text("child local result")
        self.mock.reply(codes=['console.log(await tools.agent({prompt: "child probe"}));'])
        self.mock.reply(codes=['console.log(typeof tools.agent, await tools.read({path: "child.txt"}));'])
        self.mock.reply(text="child finished")
        self.mock.reply(text="parent finished")
        events = [json.loads(line) for line in self.command("ask", "--json", "parent probe").stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        parent = jsonl(self.calls_path(session))
        agent = next(row for row in parent if row.get("name") == "agent")
        result = json.loads(agent["result"])
        self.assertTrue(result["ok"], result)
        children = [path for path in (self.home / "sessions").glob("*.calls.jsonl")
                    if path != self.calls_path(session)]
        self.assertEqual(len(children), 1)
        child = children[0].name.removesuffix(".calls.jsonl")
        self.assertEqual({row["name"] for row in jsonl(children[0]) if "name" in row}, {"read"})
        (self.cwd / "child.txt").unlink()
        before = len(self.mock.requests)
        self.assertEqual(self.replay(session, "--all")["matched"], 1)
        self.assertEqual(self.replay(child, "--all")["matched"], 1)
        self.assertEqual(len(self.mock.requests), before)

    def test_script_lookup_and_unrecorded_rejection(self):
        session = self.record_files()
        script = self.tmp / "lookup.js"
        script.write_text(
            'console.log((await tools.read({path: "sample.txt"})).text);\n'
            'console.log((await tools.read({path: "sample.txt"})).text);\n'
            'try { await tools.read({path: "never-recorded.txt"}); } '
            'catch (e) { console.log("MISS:" + e.message); }\n')
        (self.cwd / "sample.txt").unlink()
        report = self.replay(session, "--run", "1:0", "--script", str(script))
        self.assertGreaterEqual(report["output"].count("alpha"), 4, report)
        self.assertIn("not recorded", report["output"].lower(), report)
        self.assertFalse((self.cwd / "never-recorded.txt").exists())

    def test_first_argument_divergence(self):
        session = self.record_files()
        path = self.calls_path(session)
        rows = jsonl(path)
        first = next(r for r in rows if "index" in r)
        first["args"]["path"] = "tampered.txt"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        report = self.replay(session, "--run", "1:0", check=False)
        self.assertFalse(report["match"], report)
        self.assertTrue(report["divergence"], report)
        self.assertFalse(report["incomplete"], report)
        difference = report["divergence"]
        for detail in ("index 0", "expected name=read", 'args={"path":"tampered.txt"}',
                       "actual name=read", 'args={"path":"sample.txt"}'):
            self.assertIn(detail, difference)
        all_report = self.replay(session, "--all")
        self.assertEqual(all_report["divergences"], 1, all_report)
        self.assertEqual(all_report["differences"], [{"run": "1:0", "divergence": difference}])
        plain = self.command("replay", session, "--all")
        self.assertIn("replay 1:0: diff:", plain.stdout)
        self.assertIn(difference, plain.stdout)
        plain = self.command("replay", session, "--run", "1:0")
        self.assertIn("replay 1:0: diff", plain.stderr)

    def test_date_now_is_fixed_and_flagged(self):
        session = self.ask(['console.log("CLOCK", Date.now(), Date.now());'])
        first = self.replay(session, "--run", "1:0", check=False)
        second = self.replay(session, "--run", "1:0", check=False)
        self.assertTrue(first["uses_time"], first)
        self.assertFalse(first["uses_random"], first)
        self.assertEqual(first["output"], second["output"])
        clock = first["output"].split("CLOCK ", 1)[1].splitlines()[0].split()
        self.assertEqual(len(clock), 2, first)
        self.assertEqual(clock[0], clock[1], first)
        start = next(r for r in jsonl(self.calls_path(session)) if "meta" in r)
        self.assertEqual(int(clock[0]), start["meta"]["start_ms_epoch"])

    def test_zero_call_runs_and_output_differences(self):
        session = self.ask(['42', 'console.log("zero tools");'])
        rows = jsonl(self.calls_path(session))
        self.assertEqual(len(rows), 2, rows)
        self.assertTrue(all("meta" in row for row in rows))
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 2, report)
        self.assertEqual(report["matched"], 2, report)
        plain = self.command("replay", session, "--run", "1:0")
        self.assertIn("replay 1:0: match", plain.stderr)
        main = self.home / "sessions" / f"{session}.jsonl"
        records = jsonl(main)
        for record in records:
            for message in record.get("messages", []):
                if message.get("role") == "tool":
                    message["content"] = "changed output"
        main.write_text("".join(json.dumps(row) + "\n" for row in records))
        report = self.replay(session, "--all")
        self.assertEqual(report["divergences"], 2, report)
        self.assertEqual({d["run"] for d in report["differences"]}, {"1:0", "1:1"})
        self.assertTrue(all("differs" in d["divergence"] for d in report["differences"]))
        plain = self.command("replay", session, "--all")
        self.assertIn("replay 1:0: diff:", plain.stdout)
        self.assertIn("replay 1:1: diff:", plain.stdout)

    def test_missing_meta_and_explicit_termination(self):
        session = self.record_files()
        path = self.calls_path(session)
        rows = jsonl(path)
        unfinished = [r for r in rows if not ("meta" in r and r["run"] == 0)]
        path.write_text("".join(json.dumps(row) + "\n" for row in unfinished))
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["incomplete"], report)
        self.assertIsNone(report["match"])
        self.assertIsNone(report["end"])
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 2, report)
        self.assertEqual(report["undetermined"], 1, report)
        for end in ("timeout", "cancelled"):
            for row in rows:
                if "meta" in row and row["run"] == 0:
                    row["meta"]["end"] = end
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            report = self.replay(session, "--run", "1:0")
            self.assertEqual(report["end"], end)
            self.assertTrue(report["incomplete"], report)
            self.assertIsNone(report["match"])
            plain = self.command("replay", session, "--run", "1:0")
            self.assertIn(f"end={end}", plain.stderr)
            plain = self.command("replay", session, "--all")
            self.assertIn(f"end={end}", plain.stdout)

    def test_reject_text_is_not_deduplicated(self):
        session = self.ask([
            'for(let i=0;i<2;i++){try{await tools.read({path:"missing"});}'
            'catch(e){console.log(e.message);}}'
        ])
        calls = [r for r in jsonl(self.calls_path(session)) if "index" in r]
        self.assertEqual(len(calls), 2, calls)
        for row in calls:
            self.assertFalse(row["ok"])
            self.assertIsInstance(row["error"], str)
            self.assertNotIn("result", row)
            self.assertNotIn("same_as", row)
        self.assertEqual(calls[0]["error"], calls[1]["error"])
        report = self.replay(session, "--run", "1:0")
        self.assertTrue(report["match"], report)

    def test_kill_second_run_then_resume_discards_uncommitted_step(self):
        (self.cwd / "kept.txt").write_text("committed result")
        (self.cwd / "orphan.txt").write_text("orphan-only result")
        session = self.ask(['console.log(await tools.read({path: "kept.txt"}));'])
        path = self.calls_path(session)
        retained = path.read_bytes()
        main = self.home / "sessions" / f"{session}.jsonl"
        committed = main.read_bytes()
        self.mock.reply(codes=[
            'console.log(await tools.read({path: "orphan.txt"}));',
            'await tools.bash({command: "printf started > second-started; sleep 30"});',
        ])
        proc = subprocess.Popen([str(BIN), "ask", "--json", "crash this turn",
                                 "--resume", session], cwd=self.cwd, env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        try:
            wait_for(lambda: (self.cwd / "second-started").exists(), "second Run dispatched")
            rows = jsonl(path)
            self.assertEqual([(r["step"], r["run"]) for r in rows if "meta" in r],
                             [(1, 0), (3, 0)])
            self.assertTrue(path.read_bytes().startswith(retained))
            self.assertEqual(main.read_bytes(), committed)
        finally:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate(timeout=10)
        self.ask([
            'console.log(await tools.read({path: "orphan.txt"}));',
            'console.log(await tools.read({path: "kept.txt"}));',
        ], resume=session)
        rows = jsonl(path)
        self.assertTrue(path.read_bytes().startswith(retained))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual([(r["step"], r["run"]) for r in rows if "meta" in r],
                         [(1, 0), (3, 0), (3, 1)])
        resumed = [r for r in rows if r["step"] == 3 and "index" in r]
        self.assertIsInstance(resumed[0]["result"], str)
        self.assertIsInstance(resumed[1]["result"], dict)
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 3, report)
        self.assertEqual(report["matched"], 3, report)
        self.assertEqual(report["undetermined"], 0, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual([r["run"] for r in report["reports"]], ["1:0", "3:0", "3:1"])

    def test_ordinary_errors_with_pending_calls_are_incomplete_not_determined_diffs(self):
        (self.cwd / "sample.txt").write_text("settled")
        session = self.ask([
            'await Promise.all([tools.bash({command: "sleep 2"}), tools.read({path: "missing"})])',
            'await tools.read({path: "sample.txt"}); tools.bash({command: "sleep 2"}); '
            'throw new Error("missing highest index")',
            'tools.read({path: "missing"}); throw new Error("before dispatch")',
            'await tools.read({path: "missing"})',
            'throw new Error("no calls")',
            'await tools.read({path: "sample.txt"}); throw new Error("all settled")',
        ])
        rows = jsonl(self.calls_path(session))
        metas = [r["meta"] for r in rows if "meta" in r]
        self.assertEqual(len(metas), 6, rows)
        for index, meta in enumerate(metas):
            self.assertEqual(meta["end"], "error")
            if index < 3:
                self.assertIs(meta.get("incomplete"), True, meta)
            else:
                self.assertNotIn("incomplete", meta)
        self.assertEqual([r["index"] for r in rows if r["run"] == 0 and "index" in r], [1])
        self.assertEqual([r["index"] for r in rows if r["run"] == 1 and "index" in r], [0])
        self.assertFalse(any("index" in r for r in rows if r["run"] == 2))
        for index in range(6):
            report = self.replay(session, "--run", f"1:{index}")
            self.assertEqual(report["end"], "error", report)
            if index < 3:
                self.assertTrue(report["incomplete"], report)
                self.assertIsNone(report["match"], report)
                self.assertIsNotNone(report["divergence"], report)
            else:
                self.assertFalse(report["incomplete"], report)
                self.assertIs(report["match"], True, report)
                self.assertIsNone(report["divergence"], report)
        report = self.replay(session, "--all")
        self.assertEqual(report["total"], 6, report)
        self.assertEqual(report["matched"], 3, report)
        self.assertEqual(report["undetermined"], 3, report)
        self.assertEqual(report["divergences"], 0, report)
        self.assertEqual(len(report["differences"]), 3, report)

    def test_reflect_does_not_read_or_publish_calls(self):
        marker = "PRIVATE_CALLS_ONLY_7e4eb7d95c6b"
        fakebin = self.tmp / "bin"
        fakebin.mkdir()
        body_path = self.tmp / "published-body"
        args_path = self.tmp / "published-args"
        gh = fakebin / "gh"
        gh.write_text("""#!/bin/sh
if [ "$2" = list ]; then echo '[]'; exit 0; fi
printf '%s\\n' "$@" > "$FAKE_GH_ARGS"
cat > "$FAKE_GH_BODY"
echo https://example.invalid/issues/1
""")
        gh.chmod(0o700)
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + self.env.get("PATH", ""),
                   NIB_ISSUE_REPO="test/replay-privacy", FAKE_GH_BODY=str(body_path),
                   FAKE_GH_ARGS=str(args_path))
        self.mock.reply(text="baseline complete")
        terminal = Terminal(self.cwd, env)
        try:
            terminal.send("privacy baseline\r")
            def main_log():
                paths = list((self.home / "sessions").glob("*.jsonl"))
                return next((p for p in paths if not p.name.endswith(".calls.jsonl")
                             and "baseline complete" in p.read_text()), None)
            log = wait_for(main_log, "baseline committed")
            secret_result = json.dumps({"text": marker, "next_offset": None})
            secret_rows = [
                {"step": 1, "run": 0, "index": 0, "seq": 0, "name": "read",
                 "args": {"path": "private-only.txt"}, "ok": True, "result": secret_result,
                 "sha256": hashlib.sha256(secret_result.encode()).hexdigest(), "truncated": False},
                {"step": 1, "run": 0, "meta": {"start_ms_epoch": 1234, "end": "ok"}},
            ]
            calls = self.calls_path(log.stem)
            calls.write_text("".join(json.dumps(row) + "\n" for row in secret_rows))
            calls.chmod(0o600)
            self.mock.reply(codes=["console.log(await tools.read({path: " + json.dumps(str(log)) + "}));"])
            self.mock.reply(text="### Issue 草稿\n```json\n" + json.dumps([
                {"title": "Replay privacy regression probe", "body": "Synthetic harness-only evidence."}]) + "\n```")
            before = len(self.mock.requests)
            terminal.send("/reflect\r")
            wait_for(body_path.exists, "fake gh publication")
            terminal.until(b"filed")
            reflection_requests = self.mock.requests[before:]
            self.assertGreaterEqual(len(reflection_requests), 2)
            self.assertNotIn(marker, json.dumps(reflection_requests, ensure_ascii=False))
            prompt = next(m["content"] for m in reflection_requests[0]["messages"]
                          if m["role"] == "user" and "这是一次反思" in m.get("content", ""))
            self.assertIn(str(log), prompt)
            self.assertIn("只允许读取上面明确指定的本会话主日志路径", prompt)
            self.assertIn("不要枚举、glob 或搜索 sessions 目录", prompt)
            self.assertIn("`.calls.jsonl`", prompt)
            self.assertNotIn("parent_session_id 是", prompt)
            self.assertNotIn(marker, body_path.read_text())
            self.assertNotIn(marker, args_path.read_text())
            self.assertIn("Synthetic harness-only evidence.", body_path.read_text())
            self.assertNotIn(marker, (self.home / "reflections.md").read_text())
        finally:
            terminal.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
