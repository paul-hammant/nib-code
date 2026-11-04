"""Child-session reuse E2E with gated local mocks. Run after `zig build`.

    python3 tests/test_agent_reuse.py
"""
import fcntl
import http.server
import json
import signal
import subprocess
import threading
import unittest

from mock_agent import reply
from mock_llm_tool import content
from test_background_agent import BIN, BackgroundTests
from test_llm import records, wait_for


def agent(prompt, session=None, background=False):
    args = {"prompt": "child:" + prompt}
    if session is not None:
        args["session"] = session
    if background:
        args["background"] = True
    return "tools.agent(" + json.dumps(args) + ")"


def settled(call):
    return ("(async () => { try { return {resolved: true, value: await " + call +
            "} } catch (error) { return {resolved: false, error: error.message} } })()")


def completions(messages):
    return [json.loads(content(m).split("\n", 1)[1]) for m in messages
            if content(m).startswith("[background agent ")]


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, parent):
        self.parent = parent
        self.requests = []
        self.errors = []
        self.lock = threading.Lock()
        self.holding = threading.Event()
        self.release = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)

    def observed(self, prompt):
        with self.lock:
            return [r for r in self.requests if r["prompt"] == prompt]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.server.errors.append(repr(error))
            self.send_error(500, str(error))

    def respond(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        provider = "chat_completions" if "messages" in body else "codex"
        messages = body.get("messages", body.get("input", []))
        users = [i for i, m in enumerate(messages) if m.get("role") == "user"]
        first, last = content(messages[users[0]]), users[-1]
        prompt = first if first == "initial" else content(messages[last])
        step = sum(m.get("role") == "tool" or m.get("type") == "function_call_output"
                   for m in messages[last + 1:])
        with self.server.lock:
            self.server.requests.append(dict(prompt=prompt, messages=messages, body=body))
        code, text = None, "done:" + prompt
        if prompt == "initial":
            code = self.server.parent(messages)
            text = "parent complete"
        elif prompt in ("child:seed", "child:fail") and step == 0:
            code = 'console.log("child-history-marker"); await tools.write({path: "child-note.txt", content: "kept"})'
        elif prompt == "child:fail":
            data = json.dumps({"error": {"message": "reusable child mock failure"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        elif prompt == "child:hold":
            self.server.holding.set()
            if not self.server.release.wait(15):
                raise AssertionError("test did not release held child request")
        elif prompt not in ("child:seed", "child:next", "child:last"):
            raise AssertionError("forbidden prompt executed: " + prompt)
        reply(self, provider, code, text)


class ReuseTests:
    setUp = BackgroundTests.setUp
    start = BackgroundTests.start
    finish = BackgroundTests.finish

    def mock(self, parent):
        mock = Mock(parent)
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        self.env["NIB_BASE_URL"] = "http://127.0.0.1:" + str(mock.server_port)

        def cleanup():
            mock.release.set()
            mock.shutdown()
            mock.server_close()
            thread.join(timeout=3)
        self.addCleanup(cleanup)
        return mock

    def script(self, *codes):
        codes = iter(codes)
        return lambda messages: next(codes, None)

    def outputs(self, events):
        runs = [e["run_end"] for e in events if "run_end" in e]
        for run in runs:
            self.assertTrue(run["ok"], run)
        return [json.loads(r["output"].removeprefix("result: ")) for r in runs]

    def session_path(self, session):
        self.assertIsInstance(session, str)
        self.assertRegex(session, r"^[0-9a-f]{32}$")
        return self.home / "sessions" / (session + ".jsonl")

    def assert_failure(self, result):
        self.assertIs(result["ok"], False, result)
        self.assertIsInstance(result["error"], str)
        self.assertTrue(result["error"], result)
        self.session_path(result["session"])

    def assert_settled_failure(self, result):
        if result["resolved"]:
            self.assert_failure(result["value"])
        else:
            self.assertIsInstance(result["error"], str)
            self.assertTrue(result["error"], result)

    def assert_history(self, mock, prompt, previous):
        requests = mock.observed("child:" + prompt)
        self.assertEqual(len(requests), 1, requests)
        messages = requests[0]["messages"]
        self.assertEqual([content(m) for m in messages if m.get("role") == "user"],
                         ["child:" + p for p in previous + [prompt]])
        self.assertTrue(any("child-history-marker" in m.get("output", content(m)) for m in messages
                            if m.get("role") == "tool" or m.get("type") == "function_call_output"), messages)
        for prior in previous:
            self.assertTrue(any(m.get("role") == "assistant" and content(m) == "done:child:" + prior
                                for m in messages), messages)

    def assert_single_child_log(self, session, events, prompts):
        path = self.session_path(session)
        logs = list((self.home / "sessions").glob("?" * 32 + ".jsonl"))
        self.assertEqual(set(logs), {path, self.session_path(events[0]["start"]["session_id"])})
        rows = records(path)
        self.assertEqual(rows[0]["parent_session_id"], events[0]["start"]["session_id"])
        self.assertEqual([content(m) for row in rows for m in row.get("messages", [])
                          if m.get("role") == "user"], ["child:" + p for p in prompts])

    def resume_parent(self, session):
        process = subprocess.Popen([str(BIN), "ask", "--json", "--resume", session, "initial"],
                                   cwd=self.cwd, env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate()
        self.addCleanup(cleanup)
        return process

    def test_resumed_parent_can_continue_original_child(self):
        mock = self.mock(self.script("await " + agent("seed")))
        original = self.finish(self.start())
        child = self.outputs(original)[0]["session"]
        parent = original[0]["start"]["session_id"]
        mock.parent = self.script("await " + agent("next", child))
        events = self.finish(self.resume_parent(parent))
        resumed = self.outputs(events)[0]
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual(child, resumed["session"])
        self.assertEqual(parent, events[0]["start"]["session_id"])
        self.assert_history(mock, "next", ["seed"])
        self.assert_single_child_log(child, events, ["seed", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def check_canceled_continuation(self, background):
        mock = self.mock(self.script("await " + agent("seed")))
        original = self.finish(self.start())
        child = self.outputs(original)[0]["session"]
        parent = original[0]["start"]["session_id"]
        mock.parent = self.script("await " + agent("hold", child, background=background))
        process = self.resume_parent(parent)
        self.assertTrue(mock.holding.wait(5), "continuation never started")
        process.send_signal(signal.SIGINT)
        self.finish(process, ok=False)
        mock.release.set()
        mock.parent = self.script("await " + agent("next", child))
        events = self.finish(self.resume_parent(parent))
        resumed = self.outputs(events)[0]
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual(child, resumed["session"])
        self.assert_single_child_log(child, events, ["seed", "hold", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_canceled_foreground_continuation_can_resume(self):
        self.check_canceled_continuation(False)

    def test_canceled_background_continuation_can_resume(self):
        self.check_canceled_continuation(True)

    def test_sequential_reuse_across_runs_appends_same_log(self):
        snapshot = {}

        def parent(messages):
            if not snapshot:
                snapshot["stage"] = 1
                return ("const first = await " + agent("seed") +
                        "; await tools.write({path: 'session.json', content: JSON.stringify(first)}); first")
            if snapshot["stage"] == 1:
                first = json.loads((self.cwd / "session.json").read_text())
                snapshot.update(stage=2, log=self.session_path(first["session"]).read_bytes())
                return "await " + agent("next", first["session"])
            return None

        mock = self.mock(parent)
        events = self.finish(self.start())
        first, second = self.outputs(events)
        self.assertIs(first["ok"], True)
        self.assertIs(second["ok"], True)
        self.assertEqual(first["session"], second["session"])
        self.assertEqual(second["text"], "done:child:next")
        self.assertEqual(second["changes"], [])
        self.assert_history(mock, "next", ["seed"])
        self.assert_single_child_log(first["session"], events, ["seed", "next"])
        log = self.session_path(first["session"]).read_bytes()
        self.assertTrue(log.startswith(snapshot["log"]))
        self.assertGreater(len(log), len(snapshot["log"]))
        self.assertFalse(mock.errors, mock.errors)

    def test_foreground_failure_returns_reusable_session(self):
        mock = self.mock(self.script(
            "const failed = await " + agent("fail") +
            "; const resumed = await tools.agent({prompt: 'child:next', session: failed.session}); [failed, resumed]"))
        events = self.finish(self.start())
        failed, resumed = self.outputs(events)[0]
        self.assert_failure(failed)
        self.assertEqual(failed["text"], "done:child:fail")
        self.assertTrue(failed["changes"])
        self.assertIs(resumed["ok"], True)
        self.assertEqual(failed["session"], resumed["session"])
        self.assert_history(mock, "next", ["fail"])
        self.assert_single_child_log(failed["session"], events, ["fail", "next"])
        self.assertFalse(mock.errors, mock.errors)

    def test_invalid_session_ids_reject_before_execution(self):
        invalid = [4, False, [], {}, "", "a" * 31, "a" * 33, "g" * 32, "A" * 32,
                   "../" + "a" * 29]
        args = [{"prompt": "child:forbidden", "session": session, "background": background}
                for background in (False, True) for session in invalid]
        code = ("await Promise.all(" + json.dumps(args) + ".map(async args => { try { "
                "return {resolved: true, value: await tools.agent(args)} "
                "} catch (error) { return {resolved: false, error: error.message} } }))")
        mock = self.mock(self.script(code))
        results = self.outputs(self.finish(self.start()))[0]
        self.assertEqual(len(results), len(args))
        for result in results:
            self.assertIs(result["resolved"], False, result)
            self.assertTrue(result["error"], result)
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertEqual(len(list((self.home / "sessions").glob("?" * 32 + ".jsonl"))), 1)
        self.assertFalse(mock.errors, mock.errors)

    def test_missing_and_foreign_sessions_do_not_execute_prompt(self):
        mock = self.mock(self.script("await " + agent("seed")))
        original = self.finish(self.start())
        child = self.outputs(original)[0]["session"]
        foreign_parent = original[0]["start"]["session_id"]
        paths = [self.session_path(s) for s in (child, foreign_parent)]
        before = [p.read_bytes() for p in paths]
        sessions = ["0" * 32, child, foreign_parent]
        mock.parent = self.script("await Promise.all([" + ",".join(
            settled(agent("forbidden", session)) for session in sessions) + "])",
            "await Promise.all([" + ",".join(agent("forbidden", session, background=True)
                                             for session in sessions) + "])")
        events = self.finish(self.start())
        failures, started = self.outputs(events)
        for result in failures:
            self.assert_settled_failure(result)
        self.assertCountEqual(started, [{"id": "a1"}, {"id": "a2"}, {"id": "a3"}])
        delivered = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(delivered), 3)
        for result in delivered:
            self.assert_failure(result)
        self.assertEqual({r["session"] for r in delivered}, set(sessions))
        self.assertEqual([p.read_bytes() for p in paths], before)
        self.assertFalse(self.session_path(sessions[0]).exists())
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)

    def check_background_reuse(self, first_prompt):
        state = {"stage": 0}

        def parent(messages):
            done = completions(messages)
            if state["stage"] == 0:
                state["stage"] = 1
                return "await " + agent(first_prompt, background=True)
            if state["stage"] == 1 and done:
                state.update(stage=2, first=done[0])
                return "await " + agent("next", done[0]["session"])
            if state["stage"] == 2:
                state["stage"] = 3
                return "await " + agent("last", state["first"]["session"], background=True)
            return None

        mock = self.mock(parent)
        events = self.finish(self.start())
        started, resumed, last_started = self.outputs(events)
        self.assertEqual(started, {"id": "a1"})
        self.assertEqual(last_started, {"id": "a2"})
        done = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(done), 2)
        first, last = done
        if first_prompt == "fail":
            self.assert_failure(first)
        else:
            self.assertIs(first["ok"], True)
        self.assertIs(resumed["ok"], True)
        self.assertIs(last["ok"], True)
        self.assertEqual(first["session"], resumed["session"])
        self.assertEqual(first["session"], last["session"])
        self.assert_history(mock, "next", [first_prompt])
        self.assert_history(mock, "last", [first_prompt, "next"])
        self.assert_single_child_log(first["session"], events, [first_prompt, "next", "last"])
        self.assertFalse(mock.errors, mock.errors)

    def test_background_completion_session_reuses_in_both_modes(self):
        self.check_background_reuse("seed")

    def test_background_failure_session_is_reusable(self):
        self.check_background_reuse("fail")

    def test_background_overlap_rejects_same_session_contenders(self):
        state = {"stage": 0}

        def parent(messages):
            if state["stage"] == 0:
                state["stage"] = 1
                return ("const seed = await " + agent("seed") +
                        "; await tools.write({path: 'session.json', content: JSON.stringify(seed)}); "
                        "const started = await tools.agent({prompt: 'child:hold', session: seed.session, background: true}); "
                        "({seed, started})")
            if state["stage"] == 1:
                if not mock.holding.wait(5):
                    raise AssertionError("background child did not acquire session")
                session = json.loads((self.cwd / "session.json").read_text())["session"]
                state.update(stage=2, session=session)
                return "await Promise.all([" + settled(agent("forbidden", session)) + "," + agent(
                    "forbidden", session, background=True) + "])"
            done = completions(messages)
            if state["stage"] == 2 and any(r.get("text") == "done:child:hold" for r in done):
                state["stage"] = 3
                return "await " + agent("next", state["session"])
            return None

        mock = self.mock(parent)
        process = self.start()
        wait_for(lambda: any(not r["ok"] for request in mock.observed("initial")
                             for r in completions(request["messages"])))
        self.assertIsNone(process.poll(), "locked contenders must fail before holder finishes")
        self.assertFalse(mock.observed("child:forbidden"))
        mock.release.set()
        events = self.finish(process)
        initial, contenders, resumed = self.outputs(events)
        self.assertEqual(initial["started"], {"id": "a1"})
        self.assert_settled_failure(contenders[0])
        self.assertEqual(contenders[1], {"id": "a2"})
        done = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(done), 2)
        failed = next(r for r in done if not r["ok"])
        self.assert_failure(failed)
        self.assertEqual(failed["session"], initial["seed"]["session"])
        holder = next(r for r in done if r["ok"])
        self.assertEqual(holder["session"], initial["seed"]["session"])
        self.assertIs(resumed["ok"], True)
        self.assertEqual(resumed["session"], holder["session"])
        self.assert_history(mock, "next", ["seed", "hold"])
        self.assert_single_child_log(holder["session"], events, ["seed", "hold", "next"])
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)

    def test_external_log_lock_fails_without_executing_then_reuses(self):
        state = {"stage": 0}

        def parent(messages):
            if state["stage"] == 0:
                state["stage"] = 1
                return ("const seed = await " + agent("seed") +
                        "; await tools.write({path: 'session.json', content: JSON.stringify(seed)}); seed")
            if state["stage"] == 1:
                session = json.loads((self.cwd / "session.json").read_text())["session"]
                path = self.session_path(session)
                lock = open(path, "r+")
                self.addCleanup(lock.close)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                state.update(stage=2, session=session, path=path, lock=lock, before=path.read_bytes())
                return "await Promise.all([" + settled(agent("forbidden", session)) + "," + agent(
                    "forbidden", session, background=True) + "])"
            if state["stage"] == 2 and completions(messages):
                state.update(stage=3, after=state["path"].read_bytes())
                fcntl.flock(state["lock"], fcntl.LOCK_UN)
                return "await " + agent("next", state["session"])
            return None

        mock = self.mock(parent)
        events = self.finish(self.start())
        seed, contenders, resumed = self.outputs(events)
        self.assert_settled_failure(contenders[0])
        self.assertEqual(contenders[1], {"id": "a1"})
        delivered = completions(mock.observed("initial")[-1]["messages"])
        self.assertEqual(len(delivered), 1)
        self.assert_failure(delivered[0])
        self.assertEqual(delivered[0]["session"], seed["session"])
        self.assertEqual(state["before"], state["after"])
        self.assertIs(resumed["ok"], True)
        self.assertEqual(seed["session"], resumed["session"])
        self.assert_history(mock, "next", ["seed"])
        self.assert_single_child_log(seed["session"], events, ["seed", "next"])
        self.assertFalse(mock.observed("child:forbidden"))
        self.assertFalse(mock.errors, mock.errors)


class ChatTests(ReuseTests, unittest.TestCase):
    provider = "chat_completions"


class CodexTests(ReuseTests, unittest.TestCase):
    provider = "codex"


if __name__ == "__main__":
    unittest.main(verbosity=2)
