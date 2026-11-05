"""Loopback SSE timing probes shared by the chat and Codex idle-timeout tests."""
import contextlib
import http.server
import json
import threading
import time
import traceback

from mock_llm_tool import content


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, provider):
        self.provider = provider
        self.requests = []
        self.errors = []
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        super().__init__(("127.0.0.1", 0), Handler)

    def handle_error(self, request, client_address):
        with self.lock:
            self.errors.append(traceback.format_exc())

    def observed(self, kind):
        with self.lock:
            return [r for r in self.requests if r["kind"] == kind]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def chunk(self, data):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    def frame(self, kind=None, **fields):
        if kind is not None:
            fields = {"type": kind, **fields}
        return ("data: " + json.dumps(fields) + "\n\n").encode()

    def delta(self, text):
        if self.server.provider == "codex":
            return self.frame("response.output_text.delta", delta=text)
        return self.frame(choices=[{"delta": {"content": text}}])

    def complete(self, text, code=None, prompt_tokens=100):
        if self.server.provider == "codex":
            if code is None:
                item = {"type": "message", "role": "assistant",
                        "content": [{"type": "output_text", "text": text}]}
            else:
                item = {"type": "function_call", "call_id": "idle_call",
                        "name": "run", "arguments": json.dumps({"code": code})}
            self.chunk(self.frame("response.output_item.done", output_index=0, item=item))
            self.chunk(self.frame("response.completed", response={"status": "completed",
                                  "usage": {"input_tokens": prompt_tokens, "output_tokens": 7}}))
        else:
            delta = {} if code is None else {"tool_calls": [{"index": 0, "id": "idle_call",
                    "type": "function", "function": {"name": "run",
                    "arguments": json.dumps({"code": code})}}]}
            self.chunk(self.frame(choices=[{"delta": delta,
                                  "finish_reason": "stop" if code is None else "tool_calls"}],
                                  usage={"prompt_tokens": prompt_tokens, "completion_tokens": 7}))
            self.chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body.get("messages", body.get("input", []))
        child = not body.get("tools")
        users = [content(m) for m in messages if m.get("role") == "user"]
        prompt = users[-1] if users else ""
        tool_result = any(m.get("role") == "tool" or m.get("type") == "function_call_output"
                          for m in messages)
        summary = prompt.startswith("Summarize the conversation above")
        kind = ("summary" if summary else "agent" if prompt == "idle-agent-child" else
                "llm" if child else "followup" if tool_result else "main")
        with self.server.lock:
            attempt = sum(r["kind"] == kind for r in self.server.requests) + 1
            self.server.requests.append({"kind": kind, "attempt": attempt,
                                         "body": body, "path": self.path, "at": time.monotonic()})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.wfile.flush()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.stream(prompt, kind, attempt)

    def stream(self, prompt, kind, attempt):
        if prompt == "content-progress":
            for _ in range(7):
                self.chunk(self.frame("response.reasoning_summary_text.delta", delta="thinking") if self.server.provider == "codex"
                           else self.frame(choices=[{"delta": {"reasoning_content": "thinking"}}]))
                self.server.stopping.wait(.2)
        if prompt in ("content-heartbeats", "content-metadata", "request-progress") and attempt == 1:
            for _ in range(12):
                if prompt == "content-heartbeats":
                    data = b": heartbeat\n\n"
                elif prompt == "content-metadata":
                    data = self.frame("response.metadata") if self.server.provider == "codex" else self.frame(choices=[])
                else:
                    data = (self.frame("response.reasoning_summary_text.delta", delta="thinking") if self.server.provider == "codex"
                            else self.frame(choices=[{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "thinking"}}]}}]))
                self.chunk(data)
                self.server.stopping.wait(.2)
            return
        if kind == "main" and prompt == "agent-inherit":
            self.server.config_path.write_text("[limits]\nstream_idle_timeout_s = 0\n")
            self.complete("", code='await tools.agent({prompt: "idle-agent-child"})')
            return
        if kind == "summary":
            if attempt == 1:
                self.chunk(self.delta("discarded partial summary"))
                self.server.stopping.wait(10)
            else:
                self.chunk(self.delta("idle summary complete"))
                self.complete("idle summary complete")
            return
        if prompt == "compact-seed":
            text = "seed history " + "x" * 16000 if attempt == 1 else "seed complete"
            self.chunk(self.delta(text))
            self.complete(text, prompt_tokens=26000 if attempt == 3 else 100)
            return
        if prompt == "delayed-first-body":
            self.server.stopping.wait(.65)
            self.chunk(self.delta("complete"))
            self.server.stopping.wait(.15)
            self.complete("complete")
            return
        if (prompt == "visible-partial" or kind == "agent") and attempt == 1:
            self.chunk(self.delta("discarded visible partial") if kind == "main" else b": child ready\n\n")
            self.server.stopping.wait(10)
            return
        if kind == "main" and prompt == "llm-retry":
            code = ('const reply = await tools.llm({prompt: "idle-child", input: "payload"}); '
                    'reply')
            self.complete("", code=code)
            return
        if kind == "followup":
            self.chunk(self.delta("outer complete"))
            self.complete("outer complete")
            return
        if (prompt == "retry" and attempt == 1) or prompt == "exhausted" or (kind == "llm" and attempt == 1):
            if kind == "llm":
                self.chunk(self.delta("discarded partial reply"))
            elif prompt == "retry":
                self.chunk(b": failed attempt bytes\n\n")
            # No terminal frame: a missing idle watchdog must not look like success.
            self.server.stopping.wait(10)
            return
        if prompt == "heartbeats":
            for _ in range(4):
                self.chunk(b": heartbeat\n\n")
                self.server.stopping.wait(.35)
        elif prompt == "partial-bytes":
            frame = self.delta("complete")
            # No newline (and therefore no SSE event) for longer than the timeout.
            for part in (frame[:1], frame[1:3], frame[3:5], frame[5:7]):
                self.chunk(part)
                self.server.stopping.wait(.35)
            self.chunk(frame[7:])
            self.complete("complete")
            return
        else:
            self.chunk(b": ready\n\n")
            self.server.stopping.wait(.2)
        text = "child complete" if kind in ("llm", "agent") else "complete"
        self.chunk(self.delta(text))
        if prompt == "short-pauses":
            self.server.stopping.wait(.25)
        self.complete(text)
