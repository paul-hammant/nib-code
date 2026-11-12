"""Ours, beside upstream's tests (never inside them). Serves tests/mock_mcp.py's Streamable HTTP mock until killed: writes its URL to the file named by argv[1].
usage: mock_mcp_http.py URLFILE [--legacy] [--sse]"""
import os
import sys
import time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tests"))
from mock_mcp import HTTP  # noqa: E402

server = HTTP(legacy="--legacy" in sys.argv, sse="--sse" in sys.argv)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(server.url)
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    time.sleep(1)
