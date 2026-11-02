"""Session E2E checks against mock_llm.py. Run after `zig build`. No API key needed."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def read_requests(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def replay(path):
    history, records = [], []
    for line in path.read_text().splitlines():
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("repair"):
            continue
        messages = [dict(message) for message in record["messages"]]
        for message in messages:
            if "reasoning" in message:
                reasoning = message.pop("reasoning")
                assert reasoning["provider"] == "chat_completions"
                message["reasoning_content"] = reasoning["data"]
        history[record["from"]:] = messages
        records.append(record)
    return history, records


def valid_messages(messages):
    assert messages[0]["role"] == "system"
    i = 1
    while i < len(messages):
        msg = messages[i]
        assert msg["role"] in ("user", "assistant"), msg
        for call in msg.get("tool_calls", []):
            i += 1
            assert messages[i]["role"] == "tool"
            assert messages[i]["tool_call_id"] == call["id"]
        i += 1


with tempfile.TemporaryDirectory(prefix="nib-session-e2e-") as directory:
    tmp = Path(directory)
    requests_path = tmp / "requests.jsonl"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, NIB_PROVIDER="chat_completions", NIB_API_KEY="mock", NIB_BASE_URL=f"http://127.0.0.1:{port}",
               NIB_CONTEXT_WINDOW="128000", XDG_DATA_HOME=str(tmp / "data"),
               XDG_CONFIG_HOME=str(tmp / "config"), CODEX_HOME=str(tmp / "codex"), HOME=str(tmp))
    server = subprocess.Popen(["python3", str(ROOT / "scripts/mock_llm.py"), str(port), str(requests_path)],
                              env=dict(env, MOCK_PROMPT_TOKENS="3300"), stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.02)
        else:
            raise AssertionError("mock did not start")

        project = tmp / "project"
        project.mkdir()
        (project / ".git").write_text("gitdir: /unused\n")
        (project / "AGENTS.md").write_text("PROJECT_MARKER")
        cwd = project / "sub"
        cwd.mkdir()
        global_agents = tmp / "config/nib/AGENTS.md"
        global_agents.parent.mkdir(parents=True)
        global_agents.write_text("GLOBAL_MARKER")

        def ask(*args, workdir=cwd, window="128000", ok=True, input=None):
            result = subprocess.run([str(BIN), "ask", *args], cwd=workdir,
                                    env=dict(env, NIB_CONTEXT_WINDOW=window), capture_output=True, timeout=10, input=input)
            assert (result.returncode == 0) == ok, result.stderr.decode()
            return result

        ask("first")
        paths = list((tmp / "data/nib/sessions").glob("*.jsonl"))
        assert len(paths) == 1
        log = paths[0]
        first, _ = replay(log)
        system = first[0]["content"]
        assert system.index("You are nib") < system.index("GLOBAL_MARKER") < system.index("PROJECT_MARKER")
        global_agents.write_text("CHANGED_GLOBAL")
        ask("--continue", "second")
        req = read_requests(requests_path)[-2]["messages"]
        assert req == first + [{"role": "user", "content": "second"}]
        assert req[0]["content"] == system
        ask("third", "--resume", log.stem)
        safe, _ = replay(log)
        ask("reject1", "-c", ok=False)
        assert replay(log)[0] == safe
        ask("reject2", "-c", ok=False)
        safe, _ = replay(log)
        assert safe[-1]["role"] == "tool"
        ask("recovered", "-c")
        assert read_requests(requests_path)[-2]["messages"] == safe + [{"role": "user", "content": "recovered"}]
        safe, _ = replay(log)
        ask("truncated", "-c", ok=False)
        assert replay(log)[0] == safe
        with log.open("a") as stream:
            stream.write('{"from":\n{"repair":')
        ask("after crash", "--resume", log.stem)
        assert read_requests(requests_path)[-2]["messages"] == safe + [{"role": "user", "content": "after crash"}]
        assert '"repair":true' in log.read_text()
        with log.open() as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ask("locked", "--resume", log.stem, ok=False)
        other = tmp / "other"
        other.mkdir()
        ask("no session", "-c", workdir=other, ok=False)
        ask("one", workdir=other, window="4096")
        result = ask("two", "--continue", workdir=other, window="4096")
        assert b"compacted context:" in result.stderr
        compact_log = next(p for p in (tmp / "data/nib/sessions").glob("*.jsonl") if p != log)
        compacted, records = replay(compact_log)
        replacements = [r for r in records[1:] if r["messages"][0].get("content", "").startswith("Earlier session summary:")]
        assert len(replacements) == 1
        assert replacements[0]["context_tokens"] <= 2048
        assert compacted[1]["content"].startswith("Earlier session summary:")
        ask("three", "-c", workdir=other, window="4096")
        assert read_requests(requests_path)[-2]["messages"] == compacted + [{"role": "user", "content": "three"}]
        def events(result):
            assert result.stderr == b"", result.stderr
            assert result.stdout.endswith(b"\n")
            parsed = [json.loads(line) for line in result.stdout.splitlines()]
            assert all(len(event) == 1 for event in parsed), parsed
            return parsed

        streamed = events(ask("--json", "-", input=b"stdin prompt\nsecond line"))
        session_id = streamed[0]["start"]["session_id"]
        assert len(session_id) == 32 and all(c in "0123456789abcdef" for c in session_id)
        final = streamed[-1]["end"]
        assert final["steps"] == 2 and final["usage"] == {
            "prompt_tokens": 6600, "completion_tokens": 30, "prompt_cache_hit_tokens": 192}
        assert "hello from bash" in final["text"], final
        assert any(e.get("delta", {}).get("kind") == "reasoning" for e in streamed)
        assert any("run_start" in e for e in streamed)
        assert any(e.get("run_end", {}).get("ok") for e in streamed)
        assert read_requests(requests_path)[-2]["messages"][-1]["content"] == "stdin prompt\nsecond line"
        assert (tmp / "data/nib/sessions" / (session_id + ".jsonl")).exists()
        resumed = events(ask("--resume", session_id, "--json", "json resume"))
        assert resumed[0]["start"]["session_id"] == session_id
        failed = events(ask("reject1", "--json", ok=False))
        assert "start" in failed[0] and "error" in failed[-1]
        assert not any("end" in e for e in failed)
        assert events(ask("--json", ok=False))[0]["error"]["message"] == "MissingPrompt"
        json_cwd = tmp / "json"
        json_cwd.mkdir()
        compact_json = events(ask("json compact", "--json", workdir=json_cwd, window="4096"))
        assert any("notice" in e for e in compact_json)
        print("JSON E2E passed: NDJSON events, stdin, final text/usage/steps, resume, errors and notices")
        before = len(read_requests(requests_path))
        delegated = events(ask("--json", "delegate"))
        parent_id = delegated[0]["start"]["session_id"]
        final = delegated[-1]["end"]
        assert final["usage"] == {"prompt_tokens": 19800, "completion_tokens": 90, "prompt_cache_hit_tokens": 576}, final
        assert final["steps"] == 2
        assert "child alpha" in final["text"] and "child beta" in final["text"]
        children = [r for r in read_requests(requests_path)[before:] if r["messages"][-1].get("content", "").startswith("child ")]
        assert len(children) == 2
        assert abs(children[0]["received"] - children[1]["received"]) < .25
        child_steps = [r for r in read_requests(requests_path)[before:]
                       if next(m["content"] for m in reversed(r["messages"]) if m["role"] == "user").startswith("child ")]
        intervals = []
        for name in ("child alpha", "child beta"):
            steps = [r["received"] for r in child_steps
                     if next(m["content"] for m in reversed(r["messages"]) if m["role"] == "user") == name]
            intervals.append((min(steps), max(steps)))
        span = max(end for _, end in intervals) - min(start for start, _ in intervals)
        serial = sum(end - start for start, end in intervals)
        print(f"Two children first-to-second request: parallel span={span*1000:.1f} ms, summed work={serial*1000:.1f} ms")
        for request in children:
            assert "async agent({" not in request["messages"][0]["content"]
        run_output = next(e["run_end"]["output"] for e in delegated if "run_end" in e)
        returned = json.loads(run_output.removeprefix("result: "))
        for child in returned:
            result = json.loads(child["text"].split("result: ", 1)[1])
            assert result["agent"] == "undefined" and "agent" not in result["keys"]
            assert child["usage"]["prompt_tokens"] == 6600
        child_logs = [p for p in (tmp / "data/nib/sessions").glob("*.jsonl")
                      if replay(p)[1][0].get("parent_session_id") == parent_id]
        assert len(child_logs) == 2
        before = len(read_requests(requests_path))
        many = events(ask("delegate_many", "--json"))[-1]["end"]
        assert many["usage"]["prompt_tokens"] == 46200
        children = [r for r in read_requests(requests_path)[before:]
                    if r["messages"][-1].get("content", "").startswith("child ")]
        assert len(children) == 6
        starts = sorted(r["received"] for r in children)
        assert starts[3] - starts[0] < .25 and starts[4] - starts[0] >= .3, starts
        failed_child = events(ask("--json", "delegate_failure"))[-1]["end"]
        assert "HTTP 400" in failed_child["text"]
        assert failed_child["usage"] == {"prompt_tokens": 9900, "completion_tokens": 50, "prompt_cache_hit_tokens": 256}
        human = ask("delegate")
        assert b"in=19800" in human.stderr and b"out=90" in human.stderr
        print("Subagent E2E passed: concurrent results, usage including failure, parent log, hidden API and four-child cap")

        pidfile = tmp / "child-bash.pid"
        parent = subprocess.Popen([str(BIN), "ask", "--json", "delegate_cancel " + str(pidfile)],
                                  cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(500):
                if pidfile.exists():
                    break
                assert parent.poll() is None
                time.sleep(.01)
            else:
                raise AssertionError("child bash did not start")
            bash_pid = int(pidfile.read_text())
            nib_children = set()
            for task in Path(f"/proc/{parent.pid}/task").iterdir():
                try:
                    nib_children.update(map(int, (task / "children").read_text().split()))
                except FileNotFoundError:
                    pass
            assert nib_children
            parent.terminate()
            output, errors = parent.communicate(timeout=5)
            assert parent.returncode != 0 and errors == b"", errors
            cancellation = json.loads(output.splitlines()[-1])["error"]
            assert cancellation["usage"] == {"prompt_tokens": 6600, "completion_tokens": 40, "prompt_cache_hit_tokens": 128}, cancellation
            for pid in nib_children | {bash_pid}:
                status = Path(f"/proc/{pid}/stat")
                assert not status.exists() or status.read_text().split()[2] == "Z", (pid, status.read_text())
            print("Subagent cancellation E2E passed: parent, child nib and running bash terminate")
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.wait()

        before = len(read_requests(requests_path))
        stalled = subprocess.Popen([str(BIN), "ask", "--json", "delegate_stall"],
                                   cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(500):
                if any(r["messages"][-1]["role"] == "tool" and
                       next(m["content"] for m in reversed(r["messages"]) if m["role"] == "user") == "child stall2"
                       for r in read_requests(requests_path)[before:]):
                    break
                assert stalled.poll() is None
                time.sleep(.01)
            else:
                raise AssertionError("child did not enter stalled HTTP read")
            stalled.terminate()
            output, errors = stalled.communicate(timeout=5)
            assert stalled.returncode != 0 and errors == b"", errors
            failure = json.loads(output.splitlines()[-1])["error"]
            assert failure["usage"] == {"prompt_tokens": 6600, "completion_tokens": 40, "prompt_cache_hit_tokens": 128}, failure
            print("Forced child termination E2E passed: completed usage survives stalled HTTP")
        finally:
            if stalled.poll() is None:
                stalled.kill()
                stalled.wait()

        startup = []
        for _ in range(10):
            started = time.monotonic()
            probe = subprocess.Popen([str(BIN), "ask", "--json", "-"], cwd=cwd,
                                     env=dict(env, NIB_AGENT_DEPTH="1", NIB_PARENT_SESSION_ID=parent_id),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                probe.stdin.write(b"child probe")
                probe.stdin.close()
                assert "start" in json.loads(probe.stdout.readline())
                startup.append((time.monotonic() - started) * 1000)
                remaining = probe.stdout.read()
                assert "end" in json.loads(remaining.splitlines()[-1])
                assert probe.stderr.read() == b"" and probe.wait(timeout=5) == 0
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
        print(f"Child startup to start event (10 runs, includes log sync; no TLS): median={sorted(startup)[5]:.2f} ms, range={min(startup):.2f}–{max(startup):.2f} ms")
        root_logs = [p for p in (tmp / "data/nib/sessions").glob("*.jsonl")
                     if replay(p)[1][0].get("cwd") == str(cwd) and
                     replay(p)[1][0].get("parent_session_id") is None]
        latest_root = max(root_logs, key=lambda p: p.stat().st_mtime_ns)
        continued = events(ask("--json", "-c", "after delegation"))
        assert continued[0]["start"]["session_id"] == latest_root.stem
        resumed_child = events(ask("--json", "--resume", child_logs[0].stem, "child resumed"))
        child_output = next(e["run_end"]["output"] for e in resumed_child if "run_end" in e)
        assert json.loads(child_output.removeprefix("result: "))["agent"] == "undefined"
        print("Subagent resume E2E passed: --continue skips children, explicit child resume retains depth")
        for request in read_requests(requests_path):
            valid_messages(request["messages"])
        for path in (tmp / "data/nib/sessions").glob("*.jsonl"):
            valid_messages(replay(path)[0])
        print("Session E2E passed: resume/id/cwd, frozen AGENTS, failed Steps, truncated stream, crash repair, lock, automatic compaction and replay")
    finally:
        server.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            server.wait(timeout=3)
        if server.poll() is None:
            server.kill()
            server.wait()
