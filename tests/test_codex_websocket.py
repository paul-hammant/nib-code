"""Responses WebSocket prototype E2E; Python stdlib, local mocks and fake credentials only."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import sys

sys.dont_write_bytecode = True

from mock_llm_tool import codex_run

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def frame(payload, opcode=1, fin=True):
    size = len(payload)
    head = bytes([(0x80 if fin else 0) | opcode])
    if size < 126:
        return head + bytes([size]) + payload
    if size <= 65535:
        return head + b"\x7e" + struct.pack("!H", size) + payload
    return head + b"\x7f" + struct.pack("!Q", size) + payload


def receive(reader):
    head = reader.read(2)
    if not head:
        return None, None
    assert len(head) == 2 and head[0] & 0x80 and head[1] & 0x80, head
    size = head[1] & 127
    if size == 126:
        size = struct.unpack("!H", reader.read(2))[0]
    elif size == 127:
        size = struct.unpack("!Q", reader.read(8))[0]
    mask = reader.read(4)
    payload = reader.read(size)
    assert len(payload) == size
    return head[0] & 15, bytes(v ^ mask[i % 4] for i, v in enumerate(payload))


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, mode):
        self.mode, self.requests, self.handshakes = mode, [], []
        self.connections = self.posts = self.pongs = 0
        super().__init__(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        server = self.server
        server.connections += 1
        conn = server.connections
        server.handshakes.append(dict(self.headers))
        assert self.path == "/codex/responses"
        assert self.headers["OpenAI-Beta"] == "responses_websockets=2026-02-06"
        assert self.headers["x-codex-routing-hint"] == "model=gpt-6.1-terra"
        assert self.headers["authorization"] == "Bearer fake-ws-access"
        assert self.headers["chatgpt-account-id"] == "fake-ws-account"
        if server.mode == "handshake":
            self.send_response(426)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] +
                                     "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", "invalid" if server.mode == "bad-accept" else accept)
        if server.mode != "event-state":
            self.send_header("x-codex-turn-state", "mock-turn")
        self.end_headers()
        if server.mode == "bad-accept":
            self.close_connection = True
            return
        full = []
        count = 0
        try:
            while True:
                opcode, payload = receive(self.rfile)
                if opcode is None:
                    break
                if opcode == 10:
                    assert payload == b"ping"
                    server.pongs += 1
                    continue
                assert opcode == 1
                body = json.loads(payload)
                server.requests.append(dict(transport="websocket", connection=conn, body=body, at=time.monotonic()))
                assert body["type"] == "response.create"
                count += 1
                if server.mode == "missing" and count == 2:
                    assert body.get("previous_response_id")
                    self.event("error", status=400, error=dict(code="previous_response_not_found", message="gone"))
                    continue
                if body.get("previous_response_id"):
                    assert body["previous_response_id"] == f"resp-{conn}-{count-1}"
                    full += body["input"]
                else:
                    full = list(body["input"])
                if server.mode in ("protocol", "protocol-emitted") and count == 2:
                    if server.mode == "protocol-emitted":
                        self.event("response.reasoning_summary_text.delta", delta="before fallback")
                    self.wfile.write(b"\xc1\x00")
                    self.wfile.flush()
                    break
                if server.mode == "disconnect" and count == 2:
                    break
                if server.mode in ("content-heartbeats", "content-metadata", "request-progress", "content-progress", "invalid-response") and len(server.requests) == 1:
                    if server.mode == "invalid-response":
                        self.event("response.output_item.done", output_index=300, item={"type": "reasoning"})
                        continue
                    for _ in range(7 if server.mode == "content-progress" else 12):
                        if server.mode == "content-heartbeats":
                            self.wfile.write(frame(b"ping", opcode=9))
                            self.wfile.flush()
                        elif server.mode == "content-metadata":
                            self.event("response.metadata")
                        else:
                            self.event("response.reasoning_summary_text.delta", delta="thinking")
                        time.sleep(.2)
                    if server.mode != "content-progress":
                        continue
                if server.mode == "idle":
                    self.connection.settimeout(5)
                    self.rfile.read(1)
                    break
                if server.mode == "cancel":
                    self.event("response.output_text.delta", delta="partial answer")
                    self.connection.settimeout(5)
                    self.rfile.read(1)
                    break
                if server.mode == "event-state":
                    self.event("response.metadata", headers={"X-Codex-Turn-State": "event-turn"})
                self.wfile.write(frame(b"ping", opcode=9))
                self.wfile.flush()
                events, output = response(full, f"resp-{conn}-{count}", server.mode, body)
                for ev in events:
                    data = json.dumps(ev, ensure_ascii=False).encode()
                    # UTF-8 text split across frames, with an interleaved control frame.
                    cut = min(17, len(data))
                    self.wfile.write(frame(data[:cut], fin=False) + frame(b"", opcode=10) + frame(data[cut:], opcode=0))
                    self.wfile.flush()
                full += output
                if server.mode == "background-reconnect" and count == 2:
                    self.wfile.write(frame(struct.pack("!H", 1000), opcode=8))
                    self.wfile.flush()
                    break
        except (ConnectionError, TimeoutError, BrokenPipeError):
            pass
        self.close_connection = True

    def event(self, kind, **fields):
        self.wfile.write(frame(json.dumps(dict(type=kind, **fields)).encode()))
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.server.posts += 1
        self.server.requests.append(dict(transport="sse", body=body))
        events, _ = response(body["input"], "sse-response", self.server.mode, body)
        data = "".join("data: " + json.dumps(ev) + "\n\n" for ev in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def response(inputs, response_id, mode, body):
    tools = [i for i in inputs if i.get("type") in ("function_call_output", "custom_tool_call_output")]
    prompt = next((i["content"] for i in reversed(inputs) if i.get("role") == "user"), "")
    summary = "Summarize the conversation above" in prompt
    if not tools and not summary and prompt != "resumed":
        args = {"code": 'console.log("mock result🙂")'}
        if mode.startswith("background"):
            args["code"] = "await tools.sleep(1500); 'background-result🙂'"
        if mode == "fork":
            args["code"] = 'console.log(await tools.agent({prompt: "resumed", fork: true}))'
        if mode == "effort":
            args["effort"] = "low"
        item = dict(codex_run(body, args, "call1"), id="fc1", status="completed")
    else:
        text = "finished🙂" if not summary else "Earlier summary"
        if mode.startswith("background") and "background-result" not in prompt:
            text = "Waiting."
        item = dict(type="message", role="assistant", phase="final_answer", id="msg1", status="completed",
                    content=[dict(type="output_text", text=text)])
    events = [dict(type="response.created", response=dict(id=response_id, status="in_progress")),
              dict(type="response.output_item.added", output_index=0, item=item)]
    if item["type"] == "message":
        events.append(dict(type="response.output_text.delta", output_index=0, delta=item["content"][0]["text"]))
    else:
        key = "input" if item["type"] == "custom_tool_call" else "arguments"
        kind = "custom_tool_call_input" if key == "input" else "function_call_arguments"
        events.append(dict(type=f"response.{kind}.delta", output_index=0, delta=item[key]))
    events += [dict(type="response.output_item.done", output_index=0, item=item),
               dict(type="response.completed", response=dict(id=response_id, status="completed", output=[item],
                     usage=dict(input_tokens=100, output_tokens=10, input_tokens_details=dict(cached_tokens=50))))]
    if mode in ("ordered", "background-ordered"):
        output = [dict(type="reasoning", id="rs-first", summary=[], encrypted_content="fake-one"),
                  dict(type="message", role="assistant", phase="commentary",
                       content=[dict(type="output_text", text="Part one.")]),
                  dict(type="reasoning", id="rs-second", summary=[], encrypted_content="fake-two"), item]
        events = [dict(type="response.created", response=dict(id=response_id, status="in_progress"))]
        for index, value in enumerate(output):
            events.append(dict(type="response.output_item.added", output_index=index, item=value))
            if value["type"] == "message":
                events.append(dict(type="response.output_text.delta", output_index=index, delta=value["content"][0]["text"]))
            elif value["type"] in ("function_call", "custom_tool_call"):
                events.append(dict(type=f"response.{kind}.delta", output_index=index, delta=value[key]))
            events.append(dict(type="response.output_item.done", output_index=index, item=value))
        events.append(dict(type="response.completed", response=dict(id=response_id, status="completed", output=output,
                           usage=dict(input_tokens=100, output_tokens=10))))
        return events, output
    # Empty output messages and unsupported items exercise distinct continuation paths.
    if (mode in ("prefix", "unsupported") and item["type"] in ("function_call", "custom_tool_call")) or (mode == "background-prefix" and item.get("content", [{}])[0].get("text") == "Waiting."):
        empty = dict(type="message", role="assistant", content=[]) if mode != "unsupported" else dict(type="future_output")
        events.insert(-1, dict(type="response.output_item.done", output_index=1, item=empty))
        return events, [item, empty]
    return events, [item]


def read_log(home, session):
    return [json.loads(line) for line in (home / "sessions" / f"{session}.jsonl").read_text().splitlines()]


def run_case(tmp, mode, *, resume=None, home=None, extra=None):
    server = Mock(mode)
    home = home or tmp / mode
    home.mkdir(exist_ok=True)
    if mode.startswith("background"):
        (home / "config.toml").write_text("[limits]\nrun_background_after_ms = 50\nstream_idle_timeout_s = 1\n")
    if mode in ("content-heartbeats", "content-metadata", "request-progress", "content-progress"):
        (home / "config.toml").write_text("[limits]\nstream_idle_timeout_s = 3\nstream_content_timeout_s = " +
            ("3" if mode == "request-progress" else "1") + "\nrequest_timeout_s = " +
            ("1" if mode == "request-progress" else "3") + "\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "CODEX_"))}
    env.update(NIB_HOME=str(home), CODEX_HOME=str(tmp / "auth"), NIB_PROVIDER="codex", NIB_MODEL="gpt-6.1-terra",
               NIB_BASE_URL=f"http://127.0.0.1:{server.server_port}",
               NIB_REASONING_EFFORT="medium")
    if extra:
        env.update(extra)
    args = [str(BIN), "ask", "--json", "resumed" if resume else "roundtrip"]
    if resume:
        args += ["--resume", resume]
    try:
        result = subprocess.run(args, cwd=tmp, env=env, capture_output=True, timeout=15)
        assert result.returncode == 0 and result.stderr == b"", (mode, result.stdout, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        session = events[0]["start"]["session_id"]
        if mode.startswith("background"):
            assert [e["notice"] for e in events if "notice" in e] == ["Part one.Waiting." if mode == "background-ordered" else "Waiting."], events
            assert not any(e.get("delta", {}).get("text") == "Waiting." for e in events), events
        assert events[-1]["end"]["text"] == ("Part one.finished🙂" if mode in ("ordered", "background-ordered") else "finished🙂"), events
        steps = [r for r in read_log(home, session) if r.get("model_ms") is not None]
        return server, steps, session, home
    finally:
        server.close()



def test_tui_cancel(tmp):
    from test_interjections import Terminal, wait_for, finished
    server = Mock("cancel")
    home = tmp / "tui-cancel"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "CODEX_"))}
    env.update(NIB_HOME=str(home), CODEX_HOME=str(tmp / "auth"), NIB_PROVIDER="codex", NIB_MODEL="gpt-6.1-terra",
               NIB_CODEX_TRANSPORT="websocket", NIB_BASE_URL=f"http://127.0.0.1:{server.server_port}", TERM="xterm-256color")
    terminal = Terminal(tmp, env)
    try:
        terminal.send("roundtrip\r")
        terminal.until(b"answer")
        started = time.monotonic()
        terminal.send("\x1b")
        terminal.until(b"canceled")
        assert time.monotonic() - started < 2
        server.mode = "normal"
        terminal.send("resumed\r")
        wait_for(lambda: finished(home, "finished🙂"), "Turn after Esc")
        assert server.connections == 2 and len(server.requests) == 2
        assert "previous_response_id" not in server.requests[-1]["body"]
        # Same Session keeps the completed socket, but starts a fresh turn-state token.
        terminal.send("resumed\r")
        wait_for(lambda: len(server.requests) == 3, "same connection across Turns")
        assert server.connections == 2
        assert server.requests[-1]["body"]["previous_response_id"] == "resp-2-1"
        assert "client_metadata" not in server.requests[-1]["body"]
        wait_for(lambda: len(list((home / "sessions").glob("[0-9a-f]" * 32 + ".jsonl"))) == 1, "Session log")
        session = next((home / "sessions").glob("[0-9a-f]" * 32 + ".jsonl")).stem
        wait_for(lambda: len([r for r in read_log(home, session) if r.get("model_ms") is not None]) == 2,
                 "second completed Turn")
        terminal.send("/compact\r")
        wait_for(lambda: any(m.get("content", "").startswith("Earlier session summary:")
                             for r in read_log(home, session) for m in r.get("messages", [])), "manual compaction")
        assert len(server.requests) == 4 and "previous_response_id" not in server.requests[-1]["body"]
        assert not server.requests[-1]["body"].get("tools")
        terminal.send("resumed\r")
        wait_for(lambda: len(server.requests) == 5, "full request after compaction")
        assert server.connections == 2 and "previous_response_id" not in server.requests[-1]["body"]
        assert server.requests[-1]["body"]["input"][0]["content"].startswith("Earlier session summary:")
    finally:
        terminal.close()
        server.close()

def main():
    with tempfile.TemporaryDirectory(prefix="nib-ws-") as directory:
        tmp = Path(directory)
        (tmp / "auth").mkdir()
        (tmp / "auth/auth.json").write_text(json.dumps(dict(tokens=dict(access_token="fake-ws-access", account_id="fake-ws-account"))))
        server, steps, session, home = run_case(tmp, "normal")
        assert server.connections == 1 and len(server.requests) == 2
        first, second = [r["body"] for r in server.requests]
        assert "previous_response_id" not in first and second["previous_response_id"] == "resp-1-1"
        assert [i["type"] for i in second["input"]] == ["custom_tool_call_output"]
        assert second["client_metadata"]["x-codex-turn-state"] == "mock-turn"
        assert server.pongs >= 1
        assert [s["incremental"] for s in steps] == [False, True], steps
        assert steps[0]["full_reason"] == "first_request"
        assert all(s["transport"] == "websocket" and s["first_data_ms"] <= s["model_ms"] for s in steps)
        assert steps[1]["input_items"] == 1 and steps[1]["input_bytes"] == len(json.dumps(second["input"], ensure_ascii=False, separators=(",", ":")).encode())
        for mode in ("background", "background-prefix", "background-ordered", "background-reconnect"):
            background, bg_steps, _, _ = run_case(tmp, mode)
            assert len(background.requests) == len(bg_steps) == 3, (mode, background.requests, bg_steps)
            assert bg_steps[1]["messages"][-1]["waiting"] is True
            assert background.requests[2]["at"] - background.requests[1]["at"] > 1
            delta = background.requests[2]["body"]
            assert "background-result" in delta["input"][-1]["content"]
            if mode != "background-reconnect":
                assert delta["previous_response_id"] == "resp-1-2"
                assert len(delta["input"]) == 1 and delta["input"][0]["role"] == "user"
            else:
                assert "previous_response_id" not in delta
                assert len(delta["input"]) > 1
            assert background.connections == (2 if mode == "background-reconnect" else 1)
            for step, request in zip(bg_steps, background.requests):
                wire = request["body"]["input"]
                assert step["input_items"] == len(wire), (mode, step)
                assert step["input_bytes"] == len(json.dumps(wire, ensure_ascii=False, separators=(",", ":")).encode()), (mode, step)
                assert step["incremental"] == ("previous_response_id" in request["body"])
        resumed, resumed_steps, _, _ = run_case(tmp, "normal", resume=session, home=home)
        assert "previous_response_id" not in resumed.requests[0]["body"]
        assert any(i.get("type") == "custom_tool_call" for i in resumed.requests[0]["body"]["input"])
        assert any(i.get("type") == "custom_tool_call_output" for i in resumed.requests[0]["body"]["input"])
        assert resumed_steps[-1]["incremental"] is False
        for mode in ("ordered", "prefix", "unsupported", "effort", "content-heartbeats", "content-metadata", "request-progress", "content-progress", "invalid-response"):
            server, steps, _, _ = run_case(tmp, mode)
            if mode in ("ordered", "prefix", "unsupported", "effort", "content-progress"):
                assert len(server.requests) == 2 and server.connections == 1
                if mode == "content-progress":
                    assert steps[0]["model_ms"] > 1200 and steps[0]["attempts"] == 1
                    assert steps[0]["max_content_gap_ms"] < 1000
                assert steps[1]["incremental"] == (mode not in ("effort", "unsupported")), (mode, steps)
                assert steps[1].get("full_reason") == ("effort_changed" if mode == "effort" else "unsupported_output" if mode == "unsupported" else None)
            else:
                assert server.connections == 2 and server.posts == 0, (mode, server.requests)
                attempts = steps[0]["model_attempts"]
                assert len(attempts) == 2, (mode, attempts)
                expected = "InvalidResponse" if mode == "invalid-response" else "ModelRequestTimeout" if mode == "request-progress" else "StreamContentTimeout"
                assert attempts[0]["error_name"] == expected, (mode, attempts)
                assert attempts[1]["full_reason"] == "reconnect", attempts
                if mode == "invalid-response":
                    assert "output_index=300" in attempts[0]["detail"] and "output_item.done" in attempts[0]["detail"]
                else:
                    assert attempts[0]["content_bytes"] > 0 if mode == "request-progress" else attempts[0]["content_bytes"] == 0
        server, steps, _, _ = run_case(tmp, "fork")
        assert server.connections == 2 and len(server.requests) == 3
        first_by_connection = {}
        for request in server.requests:
            first_by_connection.setdefault(request["connection"], request["body"])
        assert all("previous_response_id" not in b for b in first_by_connection.values())
        assert len({b["prompt_cache_key"] for b in first_by_connection.values()}) == 1
        server, steps, _, _ = run_case(tmp, "missing")
        assert len(server.requests) == 3 and "previous_response_id" in server.requests[1]["body"]
        assert "previous_response_id" not in server.requests[2]["body"]
        assert steps[1]["transport_fallback"] == "previous_response_not_found" and not steps[1]["incremental"]
        for mode in ("handshake", "bad-accept", "protocol", "protocol-emitted"):
            server, steps, sid, case_home = run_case(tmp, mode)
            assert server.connections == 1 and server.posts >= 1, (mode, server.requests)
            assert steps[-1]["transport"] == "sse" and steps[-1]["transport_fallback"] and steps[-1]["transport_fallback_at"], (mode, steps)
            fallbacks = [r for r in read_log(case_home, sid) if r.get("transport_fallback") and "model_ms" not in r]
            assert len(fallbacks) == 1 and fallbacks[0]["transport_fallback_at"] <= steps[-1]["at"]
            if mode == "protocol-emitted":
                attempts = steps[-1]["model_attempts"]
                assert [a["transport"] for a in attempts] == ["websocket", "sse"], attempts
                assert attempts[0]["error_name"] == "WebSocketFallback" and attempts[0]["fallback_at"]
            if mode not in ("protocol", "protocol-emitted"):
                assert server.posts == 2
        server, steps, _, _ = run_case(tmp, "event-state")
        assert server.requests[1]["body"]["client_metadata"]["x-codex-turn-state"] == "event-turn"
        server, steps, _, _ = run_case(tmp, "disconnect")
        assert server.connections == 2 and "previous_response_id" not in server.requests[-1]["body"]
        assert steps[-1]["attempts"] == 2 and steps[-1]["transport"] == "websocket" and not steps[-1]["incremental"]
        for mode in ("cancel", "idle"):
            server = Mock(mode)
            case_home = tmp / mode
            case_home.mkdir()
            (case_home / "config.toml").write_text("[limits]\nstream_idle_timeout_s = 1\n")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "CODEX_"))}
            env.update(NIB_HOME=str(case_home), CODEX_HOME=str(tmp / "auth"), NIB_PROVIDER="codex", NIB_MODEL="gpt-6.1-terra",
                       NIB_CODEX_TRANSPORT="websocket", NIB_BASE_URL=f"http://127.0.0.1:{server.server_port}")
            child = subprocess.Popen([str(BIN), "ask", "--json", "roundtrip"], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                first = json.loads(child.stdout.readline())
                while True:
                    event = json.loads(child.stdout.readline())
                    if mode == "cancel" and "delta" in event:
                        break
                    if mode == "idle" and "retry" in event:
                        assert "idle timeout after 1s" in event["retry"]["reason"], event
                        break
                started = time.monotonic()
                child.send_signal(signal.SIGINT)
                stdout, stderr = child.communicate(timeout=2)
                assert time.monotonic() - started < 2 and child.returncode != 0 and not stderr
                assert "error" in json.loads(stdout.splitlines()[-1]), stdout
                assert not any(r.get("model_ms") is not None for r in read_log(case_home, first["start"]["session_id"]))
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                server.close()
        test_tui_cancel(tmp)
        print("Codex WebSocket E2E passed: reuse/delta, prefix/config reset, missing response replay, sticky SSE fallback, fragmentation/ping, turn-state, reconnect, SIGINT, idle timeout and full-history resume")


if __name__ == "__main__":
    main()
