"""One-shot Run effort scheduling E2E on both mock provider wires.

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
RUN_COUNTS = [1, 1, 1, 3, 1, 1, 2, 2, 2, 1, 1, 0]
NEXT_REQUESTS = [
    (None, "default"),
    ("low", "model"),
    (None, "default"),
    ("medium", "model"),
    ("high", "model"),
    (None, "default"),
    (None, "guard"),
    (None, "guard"),
    ("medium", "model"),
    ("low", "model"),
    ("high", "model"),
    (None, "default"),
]
LEVELS = ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def expected_steps(provider, user_effort, *, cannot_disable=False):
    base = (("low" if cannot_disable else "none")
            if provider == "codex" and user_effort == "off" else user_effort)
    result = []
    for n, (declaration, source) in enumerate(NEXT_REQUESTS, 1):
        effort = base
        if declaration is not None:
            if (user_effort == "default" and declaration == "low") or (
                    user_effort != "default" and LEVELS.index(declaration) <= LEVELS.index(base)):
                effort = declaration
            else:
                source = "guard"
        result.append({"n": n, "effort": effort, "source": source})
    return result


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
    assert "start" in events[0] and "end" in events[-1], (label, events)
    expected = expected_steps(provider, user_effort, cannot_disable=env["NIB_MODEL"] == "gpt-6.1-sol")
    actual = [event["step"] for event in events if "step" in event]
    assert actual == expected, (label, actual, expected)
    assert events[-1]["end"]["steps"] == len(expected), (label, events[-1])
    assert events[-1]["end"]["text"] == "Effort schedule complete.", (label, events[-1])
    boundaries = [i for i, event in enumerate(events) if "step" in event] + [len(events)]
    assert not any("delta" in event or "run_start" in event for event in events[:boundaries[0]]), events
    for n, (start, end) in enumerate(zip(boundaries, boundaries[1:])):
        segment = events[start:end]
        starts = [event["run_start"] for event in segment if "run_start" in event]
        ends = [event["run_end"] for event in segment if "run_end" in event]
        assert len(starts) == len(ends) == RUN_COUNTS[n], (label, n, segment)
        assert all(isinstance(code, str) for code in starts), (label, starts)
    failed_runs = [event["run_end"] for event in events if "run_end" in event and not event["run_end"]["ok"]]
    assert len(failed_runs) == 4, (label, failed_runs)

    requests = read_jsonl(requests_path)[before:]
    assert len(requests) == len(expected), (label, requests)
    for step, request in zip(expected, requests):
        effort = step["effort"]
        if provider == "codex":
            body = request["body"]
            if effort == "default":
                assert "reasoning" not in body, (label, step, body)
            else:
                assert body["reasoning"]["effort"] == effort, (label, step, body)
        else:
            body = request
            assert body["reasoning_effort"] == (None if effort in ("default", "off") else effort), (label, step, body)
            assert body["has_reasoning_effort"] == (effort not in ("default", "off")), (label, step, body)
            if effort == "off":
                assert body["thinking"] == {"type": "disabled"}, (label, step, body)
        wire = json.dumps(body)
        assert "step_effort" not in wire and "effort_source" not in wire, (label, body)

    session_id = events[0]["start"]["session_id"]
    records = read_jsonl(Path(env["NIB_HOME"]) / "sessions" / (session_id + ".jsonl"))
    steps = [record for record in records if record["from"] > 0
             and not record.get("diagnostic") and not record.get("repair")]
    assert [(record["effort"], record["effort_source"]) for record in steps] == [
        (step["effort"], step["source"]) for step in expected], (label, steps)
    base = expected[0]["effort"]
    for record, step in zip(steps, expected):
        lowered = (step["source"] == "model" and (base == "default" or
                   LEVELS.index(step["effort"]) < LEVELS.index(base)))
        assert record["effort_downgraded"] is lowered, (label, record, step)
    assert [len(record.get("run_results", [])) for record in steps] == RUN_COUNTS, (label, steps)
    assert sum(not run["ok"] for record in steps for run in record.get("run_results", [])) == 4, (label, steps)


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
                    check_case(provider, env, cwd, requests_path, effort)
                check_case(provider, env, cwd, requests_path, "default", implicit=True)
                if provider == "codex":
                    check_case(provider, dict(env, NIB_MODEL="gpt-6.1-sol"), cwd, requests_path, "off")
                print(f"{provider} effort E2E passed: first Step, one-shot reset, last declaration, default, failed Run guard and user caps")
            finally:
                server.terminate()
                server.wait(timeout=5)


if __name__ == "__main__":
    main()
