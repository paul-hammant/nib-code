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
        history[record["from"]:] = record["messages"]
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
    env = dict(os.environ, NIB_API_KEY="mock", NIB_BASE_URL=f"http://127.0.0.1:{port}",
               NIB_CONTEXT_WINDOW="128000", XDG_DATA_HOME=str(tmp / "data"),
               XDG_CONFIG_HOME=str(tmp / "config"), HOME=str(tmp))
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
        assert "hello from bash" in final["text"]
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
        assert events(ask("--json", ok=False)) == [{"error": {"message": "MissingPrompt"}}]
        json_cwd = tmp / "json"
        json_cwd.mkdir()
        compact_json = events(ask("json compact", "--json", workdir=json_cwd, window="4096"))
        assert any("notice" in e for e in compact_json)
        print("JSON E2E passed: NDJSON events, stdin, final text/usage/steps, resume, errors and notices")
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
