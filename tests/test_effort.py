"""Constant per-Step effort E2E on both mock provider wires: the run tool takes no effort,
legacy effort arguments and a first-line `// @run:` comment are inert, and logs with the
removed scheduling fields still resume.

Run after the updated binary is built: python3 tests/test_effort.py
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"
RUN_OK = [True, True, True, False, True]


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def base_effort(provider, user_effort, cannot_disable):
    if provider == "codex" and user_effort == "off":
        return "low" if cannot_disable else "none"
    return user_effort


def check_case(provider, env, cwd, requests_path, user_effort, *, implicit=False):
    before = len(read_jsonl(requests_path)) if requests_path.exists() else 0
    args = [] if implicit else ["--effort", user_effort]
    case_env = dict(env)
    if user_effort == "default" and not implicit:
        case_env["NIB_REASONING_EFFORT"] = "high"
    result = subprocess.run([str(BIN), "ask", "--json", "effort schedule", *args],
                            cwd=cwd, env=case_env, capture_output=True, timeout=30)
    label = (provider, user_effort, implicit)
    assert result.returncode == 0 and result.stderr == b"", (label, result.stdout, result.stderr)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert events and all(len(event) == 1 for event in events), (label, events)
    base = base_effort(provider, user_effort, env["NIB_MODEL"] == "gpt-6.1-sol")
    expected = [{"n": n, "effort": base} for n in range(1, len(RUN_OK) + 2)]
    actual = [event["step"] for event in events if "step" in event]
    assert actual == expected, (label, actual, expected)
    assert events[-1]["end"]["text"] == "Effort schedule complete.", (label, events[-1])
    run_ends = [event["run_end"] for event in events if "run_end" in event]
    assert [run["ok"] for run in run_ends] == RUN_OK, (label, run_ends)
    assert "3" in run_ends[2]["output"], (label, run_ends[2])

    requests = read_jsonl(requests_path)[before:]
    assert len(requests) == len(expected), (label, requests)
    for request in requests:
        if provider == "codex":
            body = request["body"]
            if base == "default":
                assert "reasoning" not in body, (label, body)
            else:
                assert body["reasoning"]["effort"] == base, (label, body)
            tools = json.dumps(body.get("tools", []))
        else:
            body = request
            assert body["reasoning_effort"] == (None if base in ("default", "off") else base), (label, body)
            if base == "off":
                assert body["thinking"] == {"type": "disabled"}, (label, body)
            tools = json.dumps(body.get("tools", []))
        wire = json.dumps(body)
        assert "effort" not in tools and "@run" not in tools, (label, tools)
        assert "run's effort" not in wire and "effort-specific" not in wire, (label, body)
        assert "step_effort" not in wire and "effort_source" not in wire, (label, body)

    session_id = events[0]["start"]["session_id"]
    log_path = Path(env["NIB_HOME"]) / "sessions" / (session_id + ".jsonl")
    records = read_jsonl(log_path)
    steps = [record for record in records if record["from"] > 0
             and not record.get("diagnostic") and not record.get("repair")]
    assert [record["effort"] for record in steps] == [base] * len(expected), (label, steps)
    assert not any("effort_source" in record or "effort_downgraded" in record for record in steps), (label, steps)
    return session_id, log_path, records


def check_legacy_resume(provider, env, cwd, session_id, log_path, records):
    for record in records:
        if "effort" in record:
            record["effort_source"] = "model"
            record["effort_downgraded"] = True
        for message in record.get("messages", []):
            if message.get("role") == "assistant":
                message["step_effort"] = {"effort": "low", "source": "guard"}
    log_path.write_text("".join(json.dumps(record) + "\n" for record in records))
    result = subprocess.run([str(BIN), "ask", "--json", "--resume", session_id, "effort schedule"],
                            cwd=cwd, env=env, capture_output=True, timeout=30)
    assert result.returncode == 0 and result.stderr == b"", (provider, result.stdout, result.stderr)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert events[-1]["end"]["text"] == "Effort schedule complete.", (provider, events[-1])


def main():
    for provider, mock in (("chat_completions", "mock_llm.py"), ("codex", "mock_codex.py")):
        with tempfile.TemporaryDirectory(prefix="nib-effort-e2e-") as directory:
            tmp = Path(directory)
            requests_path = tmp / "requests.jsonl"
            cwd = tmp / "project"
            cwd.mkdir()
            (cwd / ".git").write_text("gitdir: /unused\n")
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_", "MOCK_"))}
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            env.update(NIB_PROVIDER=provider, NIB_CODEX_TRANSPORT="sse", NIB_API_KEY="fake-key",
                       NIB_BASE_URL=f"http://127.0.0.1:{port}", NIB_CONTEXT_WINDOW="128000",
                       NIB_MODEL="gpt-6.1-terra" if provider == "codex" else "mock-model",
                       HOME=str(tmp), NIB_HOME=str(tmp / "nib"), CODEX_HOME=str(tmp / "codex"),
                       XDG_DATA_HOME=str(tmp / "data"), XDG_CONFIG_HOME=str(tmp / "config"))
            credentials = tmp / "codex/auth.json"
            credentials.parent.mkdir()
            credentials.write_text(json.dumps({"tokens": {"access_token": "fake-access", "account_id": "fake-account"}}))
            server = subprocess.Popen(["python3", str(ROOT / "tests" / mock), str(port), str(requests_path)],
                                      env=env, stdout=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.1):
                            break
                    except OSError:
                        assert server.poll() is None, "mock exited"
                        time.sleep(.02)
                else:
                    raise AssertionError("mock did not start")
                for effort in ("high", "medium", "low", "default", "off", "none", "minimal", "xhigh", "max"):
                    case = check_case(provider, env, cwd, requests_path, effort)
                check_case(provider, env, cwd, requests_path, "default", implicit=True)
                if provider == "codex":
                    check_case(provider, dict(env, NIB_MODEL="gpt-6.1-sol"), cwd, requests_path, "off")
                check_legacy_resume(provider, env, cwd, *case)
                print(f"{provider} effort E2E passed: constant user effort, inert legacy declarations and legacy log resume")
            finally:
                server.terminate()
                server.wait(timeout=5)


if __name__ == "__main__":
    main()
