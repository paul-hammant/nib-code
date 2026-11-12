"""Serves tests/mock_mcp.py's Streamable HTTP mock until killed: writes its URL to the file named by argv[1].
usage: mock_mcp_http.py URLFILE [--legacy] [--sse]"""
import sys
import time
from mock_mcp import HTTP

server = HTTP(legacy="--legacy" in sys.argv, sse="--sse" in sys.argv)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(server.url)
import os
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    time.sleep(1)
