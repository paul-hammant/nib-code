"""Local ChatGPT OAuth issuer for sign-in tests; fabricated tokens only."""
import base64
from mock_http import ThreadingHTTPServer
import hashlib
import http.server
import json
import threading
import time
import urllib.parse


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt(plan="plus", account="acc-mock", exp=None):
    claims = {"email": "user@example.test", "exp": exp or int(time.time()) + 3600,
              "https://api.openai.com/auth": {"chatgpt_account_id": account, "chatgpt_plan_type": plan}}
    return f"{b64(b'{}')}.{b64(json.dumps(claims).encode())}.sig"


class Issuer:
    def __init__(self, polls_before_approval=1):
        self.requests = []
        self.challenges = {}
        self.authorizations = []
        self.polls_left = polls_before_approval
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, status, value):
                body = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                parts = urllib.parse.urlsplit(self.path)
                if parts.path != "/oauth/authorize":
                    return self.send_error(404)
                query = {k: v[0] for k, v in urllib.parse.parse_qs(parts.query).items()}
                owner.authorizations.append(query)
                owner.challenges["browser-code"] = query["code_challenge"]
                self.reply(200, {"ok": True})

            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"])).decode()
                if "json" in self.headers.get("Content-Type", ""):
                    body = json.loads(raw)
                else:
                    body = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
                owner.requests.append((self.path, self.headers.get("Content-Type"), body))
                if self.path == "/oauth/token":
                    if body.get("grant_type") == "refresh_token":
                        if body.get("refresh_token") not in ("old-refresh", "cli-refresh"):
                            return self.reply(400, {"error": "invalid_grant"})
                        return self.reply(200, {"access_token": jwt(), "refresh_token": "refreshed-refresh", "id_token": jwt()})
                    challenge = owner.challenges.get(body.get("code"))
                    digest = b64(hashlib.sha256(body.get("code_verifier", "").encode()).digest())
                    if body.get("grant_type") != "authorization_code" or body.get("client_id") != "app_EMoamEEZ73f0CkXaXp7hrann" or challenge != digest:
                        return self.reply(400, {"error": "invalid_grant"})
                    return self.reply(200, {"id_token": jwt(), "access_token": jwt(), "refresh_token": "issued-refresh"})
                if self.path == "/api/accounts/deviceauth/usercode":
                    return self.reply(200, {"device_auth_id": "dev-1", "user_code": "ABCD-1234", "interval": "1"})
                if self.path == "/api/accounts/deviceauth/token":
                    if owner.polls_left > 0:
                        owner.polls_left -= 1
                        return self.reply(403, {"error": "pending"})
                    verifier = "device-verifier"
                    owner.challenges["device-code"] = b64(hashlib.sha256(verifier.encode()).digest())
                    return self.reply(200, {"authorization_code": "device-code", "code_challenge": owner.challenges["device-code"], "code_verifier": verifier})
                self.send_error(404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
