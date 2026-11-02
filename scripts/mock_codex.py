"""Local Codex Responses SSE mock. Usage: mock_codex.py PORT LOGFILE.

Only use fabricated credentials: requests (including headers) are logged verbatim.
MOCK_CODEX_AUTH names the temporary auth.json rotated by the 'rotate auth' probe.
"""
import http.server
import json
import os
from pathlib import Path
import sys
import threading
import time

LOG = open(sys.argv[2], "a")
LOCK = threading.Lock()
ATTEMPTS = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with LOCK:
            LOG.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
            LOG.flush()
            number = sum(ATTEMPTS.values())
        inputs = body.get("input", [])
        users = [item for item in inputs if item.get("role") == "user"]
        def content(item):
            value = item.get("content", "")
            return value if isinstance(value, str) else "".join(part.get("text", "") for part in value)
        prompt = content(users[-1]) if users else ""
        summary = "Summarize the conversation above" in prompt
        summary_empty = summary and any(content(item) == "summary empty" for item in users)
        summary_truncated = summary and any(content(item) == "summary truncated" for item in users)
        with LOCK:
            attempt = ATTEMPTS.get(prompt, 0)
            ATTEMPTS[prompt] = attempt + 1
        if prompt == "reject auth" or (prompt == "rotate auth" and attempt == 0):
            if prompt == "rotate auth":
                Path(os.environ["MOCK_CODEX_AUTH"]).write_text(json.dumps({"tokens": {
                    "access_token": "fake-access-rotated", "account_id": "fake-account-rotated",
                    "refresh_token": "fake-refresh-rotated", "id_token": "fake-id-rotated"}}))
            self.send_response(401)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"unauthorized"}}')
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        sequence = 0
        def event(kind, **fields):
            nonlocal sequence
            data = ("event: " + kind + "\ndata: " + json.dumps({"type": kind, "sequence_number": sequence, **fields}) + "\n\n").encode()
            sequence += 1
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            self.wfile.flush()
        output = []
        event("response.created", response={"id": f"resp_{number}", "status": "in_progress", "output": []})
        if not summary and body.get("reasoning", {}).get("effort") != "none":
            for part in range(2):
                item = {"id": f"rs_{number}_{part}", "type": "reasoning", "summary": [{"type": "summary_text", "text": "Mock reasoning."}],
                        "encrypted_content": f"fake-encrypted-{number}-{part}" + ("x" * 100000 if prompt == "large reasoning" else "")}
                index = len(output)
                event("response.output_item.added", output_index=index, item={"id": item["id"], "type": "reasoning", "summary": []})
                event("response.reasoning_summary_text.delta", item_id=item["id"], output_index=index, summary_index=0, delta="Mock reasoning.")
                event("response.output_item.done", output_index=index, item=item)
                output.append(item)
        last = inputs[-1] if inputs else {}
        if summary:
            text = "" if summary_empty else "Earlier work: completed mock tools. Continue the current user request."
        elif last.get("type") == "function_call_output":
            text = "Tool returned: " + last["output"]
        elif prompt in ("plain text", "large reasoning", "child probe", "rotate auth", "reject auth", "stream incomplete", "stream failed", "stream truncated"):
            text = "Mock text complete."
        else:
            code = 'await tools.bash({command: "echo hello from codex mock"})'
            if prompt == "delegate":
                code = 'await tools.agent({prompt: "child probe"})'
            elif prompt == "bash env":
                code = 'await tools.bash({command: "env | cut -d= -f1 | sort"})'
            elif prompt.startswith("read auth "):
                code = 'try { await tools.read({path: ' + json.dumps(prompt[len("read auth "):]) + '}) } catch (e) { e.message }'
            arguments = json.dumps({"code": code})
            index = len(output)
            item = {"id": f"fc_{number}", "type": "function_call", "call_id": f"call_{number}",
                    "name": "run", "arguments": arguments, "status": "completed"}
            event("response.output_item.added", output_index=index, item={**item, "arguments": "", "status": "in_progress"})
            for offset in range(0, len(arguments), 7):
                event("response.function_call_arguments.delta", item_id=item["id"], output_index=index, delta=arguments[offset:offset + 7])
            event("response.function_call_arguments.done", item_id=item["id"], output_index=index, arguments=arguments)
            event("response.output_item.done", output_index=index, item=item)
            output.append(item)
            text = None
        if text is not None:
            index = len(output)
            item = {"id": f"msg_{number}", "type": "message", "role": "assistant", "status": "completed",
                    "phase": "final_answer", "content": [{"type": "output_text", "text": text, "annotations": []}]}
            event("response.output_item.added", output_index=index, item={**item, "content": [], "status": "in_progress"})
            event("response.content_part.added", item_id=item["id"], output_index=index, content_index=0,
                  part={"type": "output_text", "text": "", "annotations": []})
            for offset in range(0, len(text), 9):
                event("response.output_text.delta", item_id=item["id"], output_index=index, content_index=0, delta=text[offset:offset + 9])
            event("response.output_text.done", item_id=item["id"], output_index=index, content_index=0, text=text)
            event("response.output_item.done", output_index=index, item=item)
            output.append(item)
        compacted = any(content(item).startswith("Earlier session summary:") for item in users)
        tokens = 100 if summary or compacted else int(os.environ.get("MOCK_PROMPT_TOKENS", "3300"))
        if prompt == "stream truncated":
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        status = "incomplete" if prompt == "stream incomplete" or summary_truncated else "failed" if prompt == "stream failed" else "completed"
        event("response." + status, response={"id": f"resp_{number}", "status": status, "output": output,
              "usage": {"input_tokens": tokens, "output_tokens": 20, "input_tokens_details": {"cached_tokens": 64}}})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
