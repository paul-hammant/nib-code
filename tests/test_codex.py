"""Codex Responses E2E with fabricated credentials. Run after `zig build`.

    python3 tests/test_codex.py
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


def auth(path, token="fake-access-initial", account="fake-account-initial"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"tokens": {"access_token": token, "account_id": account,
                                         "refresh_token": "fake-refresh", "id_token": "fake-id"}}))


def replay(path):
    history, records = [], []
    for line in path.read_text().splitlines():
        record = json.loads(line)
        records.append(record)
        if not record.get("repair"):
            history[record["from"]:] = record["messages"]
    return history, records


with tempfile.TemporaryDirectory(prefix="nib-codex-e2e-") as directory:
    tmp = Path(directory)
    auth_path = tmp / "codex/auth.json"
    auth(auth_path)
    requests_path = tmp / "requests.jsonl"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("NIB_", "DEEPSEEK_", "OPENAI_", "CODEX_"))}
    env.update(NIB_PROVIDER="codex", NIB_BASE_URL=f"http://127.0.0.1:{port}",
               CODEX_HOME=str(auth_path.parent), HOME=str(tmp), XDG_DATA_HOME=str(tmp / "data"),
               XDG_CONFIG_HOME=str(tmp / "config"))
    cwd = tmp / "project"
    cwd.mkdir()
    server = subprocess.Popen(["python3", str(ROOT / "tests/mock_codex.py"), str(port), str(requests_path)],
                              env=dict(env, MOCK_CODEX_AUTH=str(auth_path)), stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                time.sleep(.02)
        else:
            raise AssertionError("Codex mock did not start")

        def requests():
            return [json.loads(line) for line in requests_path.read_text().splitlines()]

        def ask(prompt, *args, ok=True, overrides=None, workdir=cwd):
            result = subprocess.run([str(BIN), "ask", "--json", prompt, *args], cwd=workdir,
                                    env=dict(env, **(overrides or {})), capture_output=True, timeout=20)
            assert result.stderr == b"", result.stderr
            events = [json.loads(line) for line in result.stdout.splitlines()]
            assert events and all(len(event) == 1 for event in events), result.stdout
            assert (result.returncode == 0) == ok, events
            assert ("end" if ok else "error") in events[-1], events
            return events

        ask("plain text", "--effort", "high", overrides={"NIB_THINKING": "off"})
        assert requests()[-1]["body"]["reasoning"]["effort"] == "high"
        ask("plain text", "--effort", "off")
        assert requests()[-1]["body"]["reasoning"]["effort"] == "low"
        ask("plain text", "--effort", "default", overrides={"NIB_REASONING_EFFORT": "high"})
        assert "reasoning" not in requests()[-1]["body"]
        invalid = ask("plain text", "--effort", "hgh", ok=False)
        assert "--effort" in invalid[-1]["error"]["message"]

        plain = ask("plain text")
        assert plain[-1]["end"]["text"] == "Mock text complete."
        assert "".join(e["delta"]["text"] for e in plain if e.get("delta", {}).get("kind") == "text") == "Mock text complete."
        assert plain[-1]["end"]["usage"] == {"prompt_tokens": 3300, "completion_tokens": 20, "prompt_cache_hit_tokens": 64}
        assert any(e.get("usage", {}).get("prompt_cache_hit_tokens") == 64 for e in plain)
        request = requests()[-1]
        headers, body = {k.lower(): v for k, v in request["headers"].items()}, request["body"]
        assert request["path"] == "/codex/responses", request
        assert headers["authorization"] == "Bearer fake-access-initial"
        assert headers["chatgpt-account-id"] == "fake-account-initial"
        assert headers["openai-beta"] == "responses=experimental" and headers["originator"] == "nib"
        assert body["model"] == "gpt-6.1-sol" and body["store"] is False and body["stream"] is True
        assert "You are nib" in body["instructions"]
        assert "reasoning.encrypted_content" in body["include"]
        assert "messages" not in body
        tool = body["tools"][0]
        assert tool["type"] == "function" and tool["name"] == "run" and tool["strict"] is False
        assert "description" in tool and "parameters" in tool and "function" not in tool
        session = plain[0]["start"]["session_id"]
        history, records = replay(tmp / f"data/nib/sessions/{session}.jsonl")
        assert records[0]["provider"] == "codex" and records[0]["model"] == "gpt-6.1-sol"
        reasoning = history[-1]["reasoning"]
        assert reasoning["provider"] == "codex"
        items = json.loads(reasoning["data"])
        assert len(items) == 2 and all(item["encrypted_content"].startswith("fake-encrypted-") for item in items)
        assert items[0]["summary"] == [{"type": "summary_text", "text": "Mock reasoning."}]
        ask("plain text", "--resume", session)
        assert all(item in requests()[-1]["body"]["input"] for item in items)
        assert next(item for item in requests()[-1]["body"]["input"] if item.get("role") == "assistant")["phase"] == "final_answer"
        disabled = ask("plain text", overrides={"NIB_MODEL": "gpt-6.1-terra", "NIB_THINKING": "off"})
        assert requests()[-1]["body"]["reasoning"]["effort"] == "none"
        assert not any(e.get("delta", {}).get("kind") == "reasoning" for e in disabled)

        before = len(requests())
        ask("plain text", overrides={"NIB_MODEL": "gpt-6.1-sol", "NIB_THINKING": "off"})
        assert requests()[-1]["body"]["reasoning"]["effort"] == "low"
        large = ask("large reasoning")
        large_id = large[0]["start"]["session_id"]
        large_history, _ = replay(tmp / f"data/nib/sessions/{large_id}.jsonl")
        assert len(json.loads(large_history[-1]["reasoning"]["data"])[0]["encrypted_content"]) > 100000
        ask("plain text", "--resume", large_id)
        assert json.loads(large_history[-1]["reasoning"]["data"])[0] in requests()[-1]["body"]["input"]

        before = len(requests())
        tool_events = ask("tool roundtrip")
        assert tool_events[-1]["end"]["steps"] == 2
        assert tool_events[-1]["end"]["usage"] == {"prompt_tokens": 6600, "completion_tokens": 40, "prompt_cache_hit_tokens": 128}
        assert "hello from codex mock" in tool_events[-1]["end"]["text"]
        steps = requests()[before:]
        second_input = steps[1]["body"]["input"]
        call = next(item for item in second_input if item.get("type") == "function_call")
        result = next(item for item in second_input if item.get("type") == "function_call_output")
        assert result["call_id"] == call["call_id"] and json.loads(call["arguments"])["code"]
        assert any(item.get("encrypted_content") for item in second_input)
        print("Codex stream, request headers/schema, tools, encrypted reasoning resume and cache usage passed")

        before = len(requests())
        delegated = ask("delegate", overrides={"NIB_MODEL": "gpt-6-sol", "NIB_REASONING_EFFORT": "high"})
        assert delegated[-1]["end"]["usage"]["prompt_tokens"] == 9900
        steps = requests()[before:]
        assert len(steps) == 3
        for request in steps:
            assert request["body"]["model"] == "gpt-6-sol" and request["body"]["reasoning"]["effort"] == "high"
            assert {k.lower(): v for k, v in request["headers"].items()}["authorization"] == "Bearer fake-access-initial"
        assert sum("async agent({" not in r["body"]["instructions"] for r in steps) == 1

        before = len(requests())
        compact_dir = tmp / "compact"
        compact_dir.mkdir()
        for index in range(3):
            ask(f"compact {index}", overrides={"NIB_CONTEXT_WINDOW": "4096"}, workdir=compact_dir,
                *(["--continue"] if index else []))
        summaries = [r["body"] for r in requests()[before:] if not r["body"].get("tools")]
        assert summaries and all(body["reasoning"]["effort"] == "low" and body["model"] == "gpt-6.1-sol" for body in summaries), summaries
        assert all("max_tokens" not in body and "max_output_tokens" not in body for body in summaries)
        assert all("Keep the summary within" in body["input"][-1]["content"] for body in summaries)
        for scenario in ("summary empty", "summary truncated"):
            failure_dir = tmp / scenario.replace(" ", "-")
            failure_dir.mkdir()
            ask(scenario, overrides={"NIB_CONTEXT_WINDOW": "4096"}, workdir=failure_dir)
            continued = ask("continue after summary failure", "--continue", overrides={"NIB_CONTEXT_WINDOW": "4096"}, workdir=failure_dir)
            assert any("automatic compaction failed, continuing" in event.get("notice", "") for event in continued), continued
            assert "end" in continued[-1]
        print("Codex child configuration and automatic compaction with the same model and minimal reasoning passed")

        before = len(requests())
        ask("rotate auth")
        rotated = requests()[before:]
        assert len(rotated) == 2
        assert {k.lower(): v for k, v in rotated[1]["headers"].items()}["authorization"] == "Bearer fake-access-rotated"
        assert {k.lower(): v for k, v in rotated[1]["headers"].items()}["chatgpt-account-id"] == "fake-account-rotated"
        before = len(requests())
        failed = ask("reject auth", ok=False)
        assert len(requests()) - before == 2
        message = failed[-1]["error"]["message"].lower()
        assert "codex" in message and ("login" in message or "log in" in message)
        for contents in (None, "not-json fake-invalid-secret", json.dumps({"tokens": {"access_token": "fake-invalid-secret"}})):
            if contents is None:
                auth_path.unlink()
            else:
                auth_path.write_text(contents)
            before = len(requests())
            failed = ask("plain text", ok=False)
            assert len(requests()) == before
            message = failed[-1]["error"]["message"].lower()
            assert "codex" in message and ("login" in message or "log in" in message), failed
            assert "fake-invalid-secret" not in json.dumps(failed)
        auth(auth_path)
        blocked = ask("read auth " + str(auth_path))
        assert "fake-access-initial" not in json.dumps(blocked)
        assert "denied" in blocked[-1]["end"]["text"].lower(), blocked
        checked = ask("bash env", overrides={"NIB_API_KEY": "fake-nib-secret", "DEEPSEEK_API_KEY": "fake-deepseek-secret", "OPENAI_API_KEY": "fake-openai-secret"})
        output = next(event["run_end"]["output"] for event in checked if "run_end" in event)
        for key in ("NIB_API_KEY", "DEEPSEEK_API_KEY", "OPENAI_API_KEY"):
            assert key not in output, output
        cross = ask("plain text", "--resume", session, ok=False, overrides={"NIB_PROVIDER": "chat_completions", "NIB_API_KEY": "mock"})
        message = cross[-1]["error"]["message"]
        assert "SessionProviderMismatch" in message or "different provider" in message, cross
        log = tmp / f"data/nib/sessions/{session}.jsonl"
        committed = log.read_bytes()
        for prompt in ("stream incomplete", "stream failed", "stream truncated"):
            failed = ask(prompt, "--resume", session, ok=False)
            assert not any("end" in event for event in failed), failed
            assert log.read_bytes() == committed, prompt
        before = len(requests())
        changed_model = ask("plain text", "--resume", session, ok=False, overrides={"NIB_MODEL": "gpt-6-sol"})
        assert "different model" in changed_model[-1]["error"]["message"]
        assert len(requests()) == before
        print("Codex 401 reread, repeated-401 login guidance, credentials and tool isolation passed")
    finally:
        server.terminate()
        server.wait(timeout=5)
