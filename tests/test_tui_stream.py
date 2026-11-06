"""Incremental TUI output through a PTY, including a paused stream and live input."""
import contextlib
import json
import sys
from pathlib import Path
import tempfile
import threading
import time
from unittest.mock import patch

from test_interjections import Handler, Reply, fixture, finished, history, wait_for

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from screen import screen


class StreamReply(Reply):
    def __init__(self):
        self.prefix = "STREAM_BEGIN "
        self.chunks = ["中文🙂 " if i % 20 == 0 else "word " for i in range(400)]
        self.tail = " PAUSED_TAIL"
        self.end = " STREAM_END"
        super().__init__(self.prefix + "".join(self.chunks) + self.tail + self.end, gated=True)
        self.reasoning_done = threading.Event()
        self.continue_stream = threading.Event()
        self.paused = threading.Event()
        self.elapsed = 0


class StreamHandler(Handler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        reply = self.server.replies.get(timeout=5)
        reply.messages = body["messages"]
        reply.received.set()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event):
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()

        def text(value):
            emit({"choices": [{"delta": {"content": value}}]})

        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            emit({"choices": [{"delta": {"reasoning_content": "hidden thinking"}}]})
            if not reply.reasoning_done.wait(10):
                return
            text(reply.prefix)
            if not reply.continue_stream.wait(10):
                return
            start = time.monotonic()
            for chunk in reply.chunks:
                text(chunk)
                time.sleep(.001)
            text(reply.tail)
            reply.elapsed = time.monotonic() - start
            reply.paused.set()
            if not reply.release.wait(10):
                return
            text(reply.end)
            emit({"choices": [{"delta": {}, "finish_reason": "stop"}],
                  "usage": {"prompt_tokens": 100, "completion_tokens": 400}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()


def test_incremental_stream(tmp):
    reply = StreamReply()
    with patch("test_interjections.Handler", StreamHandler):
        with fixture(tmp, [reply]) as (terminal, home, _):
            terminal.send("stream test\r")
            wait_for(lambda: any("Thinking" in row for row in screen(terminal.read(), 120, 32)), "Thinking during reasoning")
            reply.reasoning_done.set()
            terminal.until(reply.prefix.strip().encode())
            wait_for(lambda: any("Generating response" in row for row in screen(terminal.read(), 120, 32)), "Generating response during text")
            assert not reply.paused.is_set(), "first fragment must appear before the rest is sent"
            terminal.send("\x1b[200~live-draft\x1b[201~")
            terminal.until(b"live-draft")
            start = len(terminal.read())
            reply.continue_stream.set()
            terminal.until(b"word")
            assert not reply.release.is_set(), "incremental text must not wait for completion"
            wait_for(reply.paused.is_set, "stream pause")
            terminal.until(b"PAUSED_TAIL")
            assert not finished(home, reply.text), "tail must display while the response is still open"
            output = terminal.read()[start:]
            frames = output.count(b"\x1b[?2026h")
            assert 1 < frames < len(reply.chunks) // 2, frames
            print(f"stream: {len(reply.chunks)} deltas in {reply.elapsed:.3f}s, {frames} frames, {len(output)} terminal bytes")
            reply.release.set()
            wait_for(lambda: finished(home, reply.text), "complete stream committed")
            terminal.until(b"STREAM_END")
            assert history(home)[-1]["content"] == reply.text
            assert terminal.child.poll() is None
            terminal.send("\x15")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-tui-stream-") as directory:
        test_incremental_stream(Path(directory) / "incremental")
        print("test_incremental_stream: ok")
