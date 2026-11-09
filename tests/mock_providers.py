"""Local wire fixtures for Responses, Messages and Chat Completions; fake keys only."""
from mock_http import ThreadingHTTPServer
import http.server
import json
import threading


class Mock:
    def __init__(self, protocol, custom_run=False, key="fake-provider-key", code=None, models=None, codex=False):
        self.protocol, self.custom_run, self.key, self.code, self.codex = protocol, custom_run, key, code, codex
        self.searches = []
        self.models = models
        self.gets = []
        self.requests = []
        self.errors = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                owner.gets.append((self.path, dict(self.headers)))
                expected = "/v1/models" if owner.protocol == "anthropic_messages" else "/models"
                if owner.models is None or self.path.split("?")[0] != expected:
                    return self.send_error(404)
                body = json.dumps({"data": owner.models}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                try:
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    owner.requests.append((self.path, dict(self.headers), body))
                    owner.serve(self, body)
                except Exception as error:
                    owner.errors.append(repr(error))
                    self.send_error(500)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def serve_search(self, h, body):
        """Web search fixtures: Responses SSE, Messages JSON, DeepSeek JSON. Query "nosearch" never searches."""
        self.searches.append((h.path, dict(h.headers), body))
        if self.protocol == "responses":
            query = body["input"][0]["content"][0]["text"]
            events = []
            if query != "nosearch":
                sources = [{"type": "url", "url": "https://a.dev/1"}, {"type": "url", "url": "https://b.dev/2"}]
                events.append({"type": "response.output_item.done", "item": {"type": "web_search_call", "action": {"type": "search", "sources": sources}}})
            note = {"type": "url_citation", "url": "https://b.dev/2", "title": "B page"}
            events.append({"type": "response.output_item.done", "item": {"type": "message", "content": [{"type": "output_text", "text": "answer for " + query, "annotations": [note]}]}})
            payload, kind = "".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n", "text/event-stream"
        elif self.protocol == "anthropic_messages":
            query = body["messages"][0]["content"]
            content = [{"type": "text", "text": "answer for " + query, "citations": [{"type": "web_search_result_location", "url": "https://b.dev/2", "title": "B page", "cited_text": "quote"}]}]
            if query != "nosearch":
                hits = [{"type": "web_search_result", "url": "https://a.dev/1", "title": "A page", "page_age": "May 1, 2026"}]
                content = [{"type": "server_tool_use", "name": "web_search", "input": {"query": query}}, {"type": "web_search_tool_result", "content": hits}] + content
            payload, kind = json.dumps({"content": content}), "application/json"
        else:
            hits = [{"title": "A page", "url": "https://a.dev/1", "snippet": "snip", "summary": "sum", "date": None}, {"title": "B page", "url": "https://b.dev/2", "snippet": "only snippet", "summary": None, "date": "2026-01-02"}]
            payload, kind = json.dumps({"results": hits[:body["count"]]}), "application/json"
        data = payload.encode()
        h.send_response(200)
        h.send_header("Content-Type", kind)
        h.send_header("Content-Length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)

    def serve(self, h, body):
        tools_list = body.get("tools") or []
        first = tools_list[0] if tools_list and isinstance(tools_list[0], dict) else {}
        if h.path.endswith("/v1/tools/search") or str(first.get("type", "")).startswith("web_search"):
            return self.serve_search(h, body)
        expected = {"responses": "/codex/responses" if self.codex else "/responses", "anthropic_messages": "/v1/messages", "chat_completions": "/chat/completions"}[self.protocol]
        assert h.path == expected, h.path
        assert bool(h.headers.get("chatgpt-account-id")) == self.codex
        if self.protocol == "anthropic_messages":
            assert h.headers["anthropic-version"] == "2023-06-01"
            assert h.headers.get("x-api-key", "") == self.key
            messages = body["messages"]
            assert body["system"][-1]["cache_control"] == {"type": "ephemeral"}
        else:
            assert self.codex or h.headers.get("Authorization", "") == (f"Bearer {self.key}" if self.key else "")
            messages = body.get("input", body.get("messages"))
        users = [m for m in messages if m.get("role") == "user"]
        def content(m):
            c = m.get("content", "")
            return c if isinstance(c, str) else " ".join(b.get("text", "") for b in c)
        prompt = " ".join(content(m) for m in users)
        if "unauthorized" in prompt:
            h.send_response(401)
            h.end_headers()
            h.wfile.write(b'{"error":"fake-key-must-not-be-echoed"}')
            return
        child = "child" in prompt or "pure" in prompt
        tool_result = any(m.get("type") in ("function_call_output", "custom_tool_call_output") or m.get("role") == "tool" or any(b.get("type") == "tool_result" for b in m.get("content", []) if isinstance(b, dict)) for m in messages)
        again = "again" in prompt
        tool = not child and not tool_result and not again
        answer = "child answer" if child else "mock answer"
        code = 'console.log(await tools.agent({prompt:"child"})); console.log(await tools.llm({prompt:"pure"}));' if "delegate" in prompt else (self.code or 'console.log("roundtrip");')
        if tool_result and not child:
            if self.protocol == "responses":
                assert any(m.get("type") == "reasoning" and m.get("encrypted_content") == "opaque-response" for m in messages)
            elif self.protocol == "anthropic_messages":
                assert any(b.get("signature") == "opaque-signature" for m in messages for b in m.get("content", []) if isinstance(b, dict))
        h.send_response(200)
        h.send_header("Content-Type", "text/event-stream")
        h.end_headers()
        def event(value):
            h.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            h.wfile.flush()
        if self.protocol == "responses":
            if body.get("tools"):
                assert body["tools"][0]["type"] == ("custom" if self.custom_run else "function")
            event({"type": "response.created", "response": {"id": "response-1", "status": "in_progress"}})
            items = [{"type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "opaque-response"}]
            if tool:
                items.append({"type": "custom_tool_call" if self.custom_run else "function_call", "id": "ctc_1" if self.custom_run else "fc_1", "call_id": "call_1", "name": "run", **({"input": code} if self.custom_run else {"arguments": json.dumps({"code": code})})})
            else:
                items.append({"type": "message", "id": "msg_1", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": answer, "annotations": []}]})
                event({"type": "response.output_text.delta", "delta": answer, "output_index": 1})
            for i, item in enumerate(items):
                event({"type": "response.output_item.added", "output_index": i, "item": item})
                event({"type": "response.output_item.done", "output_index": i, "item": item})
            event({"type": "response.completed", "response": {"id": "response-1", "status": "completed", "usage": {"input_tokens": 100, "output_tokens": 10, "input_tokens_details": {"cached_tokens": 8, "cache_write_tokens": 4}}}})
        elif self.protocol == "anthropic_messages":
            event({"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": body["model"], "usage": {"input_tokens": 88, "output_tokens": 1, "cache_read_input_tokens": 8, "cache_creation_input_tokens": 4}}})
            blocks = [{"type": "thinking", "thinking": "", "signature": ""}, {"type": "tool_use", "id": "call_1", "name": "run", "input": {}}] if tool else [{"type": "text", "text": ""}]
            for i, block in enumerate(blocks):
                event({"type": "content_block_start", "index": i, "content_block": block})
                if block["type"] == "thinking":
                    event({"type": "content_block_delta", "index": i, "delta": {"type": "thinking_delta", "thinking": "reason"}})
                    event({"type": "content_block_delta", "index": i, "delta": {"type": "signature_delta", "signature": "opaque-signature"}})
                elif block["type"] == "tool_use":
                    args = json.dumps({"code": code})
                    for fragment in (args[:9], args[9:]):
                        event({"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": fragment}})
                else:
                    event({"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": answer}})
                event({"type": "content_block_stop", "index": i})
            event({"type": "message_delta", "delta": {"stop_reason": "tool_use" if tool else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 10}})
            event({"type": "message_stop"})
        else:
            delta = {"reasoning_content": "reason"}
            if tool:
                delta["tool_calls"] = [{"index": 0, "id": "call_1", "type": "function", "function": {"name": "run", "arguments": json.dumps({"code": code})}}]
            else:
                delta["content"] = answer
            event({"choices": [{"index": 0, "delta": delta}]})
            event({"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 10, "prompt_cache_hit_tokens": 8}})
            h.wfile.write(b"data: [DONE]\n\n")
