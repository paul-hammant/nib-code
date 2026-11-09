"""Loopback HTTP mocks without hostname resolution during bind."""
import http.server
import json
import socketserver


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


def is_prediction(body):
    """The TUI's out-of-Session next-message prediction request; mocks refuse it so scripted replies stay in order."""
    return "Predict the user's next message" in json.dumps(body)
