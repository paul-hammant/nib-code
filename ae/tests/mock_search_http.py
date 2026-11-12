"""Ours, beside upstream's tests (never inside them). A local web-search provider mock for web_search_test.ae: the fixtures of tests/mock_providers.py's serve_search over real HTTP. Writes its URL to argv[1]; appends one JSON line {path, headers, body} per request to argv[2].
Query "nosearch" never searches; "slow" sleeps 3 s; "http500" answers 500."""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body}) + "\n")
        if self.path.endswith("/responses"):
            query = body["input"][0]["content"][0]["text"]
        elif self.path.endswith("/v1/messages"):
            query = body["messages"][0]["content"]
        else:
            query = body["query"]
        if query == "slow":
            time.sleep(3)
        if query == "http500":
            return self.send(500, "application/json", b'{"error":"boom"}')
        if self.path.endswith("/responses"):
            events = []
            if query != "nosearch":
                sources = [{"type": "url", "url": "https://a.dev/1"}, {"type": "url", "url": "https://b.dev/2"}]
                events.append({"type": "response.output_item.done", "item": {"type": "web_search_call", "action": {"type": "search", "sources": sources}}})
            note = {"type": "url_citation", "url": "https://b.dev/2", "title": "B page"}
            events.append({"type": "response.output_item.done", "item": {"type": "message", "content": [{"type": "output_text", "text": "answer for " + query, "annotations": [note]}]}})
            payload, kind = "".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n", "text/event-stream"
        elif self.path.endswith("/v1/messages"):
            content = [{"type": "text", "text": "answer for " + query, "citations": [{"type": "web_search_result_location", "url": "https://b.dev/2", "title": "B page", "cited_text": "quote"}]}]
            if query != "nosearch":
                hits = [{"type": "web_search_result", "url": "https://a.dev/1", "title": "A page", "page_age": "May 1, 2026"}]
                content = [{"type": "server_tool_use", "name": "web_search", "input": {"query": query}}, {"type": "web_search_tool_result", "content": hits}] + content
            payload, kind = json.dumps({"content": content}), "application/json"
        else:
            hits = [{"title": "A page", "url": "https://a.dev/1", "snippet": "snip", "summary": "sum", "date": None}, {"title": "B page", "url": "https://b.dev/2", "snippet": "only snippet", "summary": None, "date": "2026-01-02"}]
            payload, kind = json.dumps({"results": hits[:body["count"]]}), "application/json"
        self.send(200, kind, payload.encode())

    def send(self, code, kind, data):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write("http://127.0.0.1:%d" % server.server_address[1])
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    time.sleep(1)
