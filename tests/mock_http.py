"""Loopback HTTP mocks without hostname resolution during bind."""
import http.server
import socketserver


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]
