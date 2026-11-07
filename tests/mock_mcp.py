"""Tiny modern/legacy stdio and Streamable HTTP MCP servers; fake secrets only."""
import argparse
import base64
import json
import os
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler
from mock_http import ThreadingHTTPServer

MODERN = "2026-07-28"
LEGACY = "2025-11-25"
PNG = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 640, 480) + b"\x08\x06\x00\x00\x00"


class Server:
    def __init__(self, legacy=False, record=None):
        self.legacy, self.record = legacy, record
        self.changed = False
        self.initialized = False

    def respond(self, request, headers=None):
        method, params = request["method"], request.get("params", {})
        if self.record:
            with open(self.record, "a") as log:
                log.write(json.dumps({"request": request, "headers": dict(headers or {}), "pid": os.getpid(), "cwd": os.getcwd(), "env": {k: os.environ.get(k) for k in ("MCP_TEST_TOKEN", "NIB_API_KEY", "MCP_UNLISTED")}}) + "\n")
        def result(value):
            if not self.legacy:
                value["resultType"] = "complete"
            return {"jsonrpc": "2.0", "id": request["id"], "result": value}
        def error(code, message):
            return {"jsonrpc": "2.0", "id": request["id"], "error": {"code": code, "message": message}}
        if method == "server/discover":
            if self.legacy:
                return error(-32602, "Initialize first")
            assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == MODERN
            return result({"supportedVersions": [MODERN], "capabilities": {"tools": {}}, "serverInfo": {"name": "mock", "version": "1"}})
        if method == "initialize":
            assert self.legacy
            self.initialized = True
            assert params["capabilities"] == {}
            return result({"protocolVersion": LEGACY, "capabilities": {"tools": {"listChanged": True}}, "serverInfo": {"name": "mock", "version": "1"}})
        if method == "notifications/initialized":
            return None
        if self.legacy:
            assert self.initialized
            if headers:
                assert headers.get("Mcp-Session-Id") == "mock-session"
        else:
            assert params["_meta"]["io.modelcontextprotocol/clientCapabilities"] == {}
            if headers:
                assert headers.get("Mcp-Method") == method
                if method == "tools/call":
                    assert headers.get("Mcp-Name") == params["name"]
        if method == "tools/list":
            if params.get("cursor") == "page2":
                return result({"tools": [{"name": "second", "description": "Second page.", "inputSchema": {"type": "object"}}], "ttlMs": 0, "cacheScope": "private"})
            names = ["echo", "fail", "rpc_error", "change", "image", "large", "env", "sandbox"] + (["added"] if self.changed else [])
            return result({"tools": [{"name": name, "description": "Echo the input. Unneeded detail.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string", "x-mcp-header": "Text"}}, "required": ["text"]}} for name in names], "nextCursor": "page2", "ttlMs": 0, "cacheScope": "private"})
        if method == "tools/call":
            name, args = params["name"], params["arguments"]
            if name == "rpc_error":
                return error(-32000, "mock RPC failure")
            if name == "change":
                self.changed = True
            text = args.get("text", "")
            if headers and not self.legacy and text and text.isascii() and "\n" not in text and text.strip() == text:
                assert headers.get("Mcp-Param-Text") == text
            if name == "large":
                text = "X" * 25000
            if name == "env":
                text = json.dumps({"allowed": os.environ.get("MCP_TEST_TOKEN"), "github": os.environ.get("GITHUB_TOKEN"), "key": os.environ.get("NIB_API_KEY"), "unlisted": os.environ.get("MCP_UNLISTED"), "home": os.environ.get("HOME"), "cwd": os.getcwd()})
            if name == "sandbox":
                try:
                    with open(args["path"], "w") as f:
                        f.write("must not write")
                    text = "wrote"
                except PermissionError:
                    text = "denied"
            content = [{"type": "text", "text": text}]
            if name == "image":
                content += [{"type": "image", "data": base64.b64encode(PNG).decode(), "mimeType": "image/png"}]
            return result({"content": content, "structuredContent": {"echo": text}, "isError": name == "fail"})
        return error(-32601, "Method not found")


class HTTP:
    def __init__(self, legacy=False, sse=False):
        self.core, self.sse = Server(legacy), sse
        self.requests, self.errors = [], []
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    owner.requests.append((request, dict(self.headers)))
                    assert self.headers.get("Authorization") == "Bearer fake-mcp-token"
                    reply = owner.core.respond(request, self.headers)
                    code = 400 if legacy and request["method"] == "server/discover" else 202 if reply is None else 200
                    data = b"" if reply is None else json.dumps(reply).encode()
                    if sse and code == 200:
                        data = b": keep alive\r\n\r\nevent: message\r\ndata: " + data + b"\r\n\r\n"
                    self.send_response(code)
                    self.send_header("Content-Type", "text/event-stream" if sse and code == 200 else "application/json")
                    if legacy:
                        self.send_header("Mcp-Session-Id", "mock-session")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except Exception as exc:
                    owner.errors.append(repr(exc))
                    self.send_error(500)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/mcp"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--record")
    options = parser.parse_args()
    server = Server(options.legacy, options.record)
    for line in sys.stdin:
        request = json.loads(line)
        reply = server.respond(request)
        if reply:
            print(json.dumps(reply), flush=True)
        if request["method"] == "tools/call" and request["params"]["name"] == "change":
            print(json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}), flush=True)


if __name__ == "__main__":
    main()
