"""Turn undo through the TUI and real child processes, using only local mock models."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
import threading
import time

from test_files import js_call
from test_interjections import Reply, Terminal, fixture, wait_for


def root_log(home, session=None):
    for path in (home / "sessions").glob("*.jsonl"):
        if ".calls." in path.name or (session and path.stem != session):
            continue
        records = [json.loads(line) for line in path.read_text().splitlines() if line]
        if records and not records[0].get("parent_session_id"):
            return path, records
    raise AssertionError("root log missing")


def history(home, session=None):
    _, records = root_log(home, session)
    messages = []
    for record in records:
        if record.get("messages"):
            messages[record["from"]:] = record["messages"]
    return messages


def done(terminal, home, text):
    wait_for(lambda: history(home)[-1].get("content") == text, text)
    terminal.until(text.encode())
    time.sleep(.15)


def undo(terminal, home, expected, session=None):
    before = len(history(home, session))
    terminal.send("/undo\r")
    wait_for(lambda: len(history(home, session)) >= before + 2, "undo result logged")
    text = history(home, session)[-1]["content"]
    assert expected in text, text
    return text


def test_files_and_history(tmp):
    first_code = ";".join([
        js_call("edit", path="a", old_text="old", new_text="first"),
        js_call("write", path="a", content="last of first Turn"),
        js_call("write", path="新目录/中文.txt", content="created"),
        js_call("write", path="二进制", content="replaced"),
    ])
    second_code = js_call("edit", path="a", old_text="last of first Turn", new_text="second")
    replies = [Reply(code=first_code), Reply("first-finished"),
               Reply(code=second_code), Reply("second-finished"), Reply("model-informed")]
    with fixture(tmp, replies) as (terminal, home, _):
        (tmp / "a").write_text("old")
        (tmp / "二进制").write_bytes(b"\x00\xff\x80before")
        (tmp / "untouched").write_text("keep")
        terminal.send("first\r")
        done(terminal, home, "first-finished")
        terminal.send("second\r")
        done(terminal, home, "second-finished")
        snapshots = list((home / "sessions").glob("*.undo/*/*.before"))
        assert len(snapshots) == 3, snapshots
        assert all(path.stat().st_mode & 0o777 == 0o600 for path in snapshots)
        text = undo(terminal, home, "restored:")
        assert "deleted:" not in text
        assert (tmp / "a").read_text() == "last of first Turn"
        text = undo(terminal, home, "deleted:")
        assert "中文.txt" in text and "二进制" in text, text
        assert (tmp / "a").read_text() == "old"
        assert (tmp / "二进制").read_bytes() == b"\x00\xff\x80before"
        assert not (tmp / "新目录/中文.txt").exists()
        assert (tmp / "untouched").read_text() == "keep"
        undo(terminal, home, "Nothing to undo")
        terminal.send("continue\r")
        done(terminal, home, "model-informed")
        assert any("[undo]" in m.get("content", "") for m in replies[-1].messages)
        assert all("source" not in m for m in replies[-1].messages)
        assert not list((home / "sessions").glob("*.undo/*"))


def test_conflict_and_busy(tmp):
    gated = Reply("busy-finished", gated=True)
    code = js_call("write", path="a", content="nib") + ";" + js_call("write", path="new", content="nib-new")
    replies = [Reply(code=code), Reply("edit-finished"), gated]
    with fixture(tmp, replies) as (terminal, home, _):
        (tmp / "a").write_text("old")
        terminal.send("edit\r")
        done(terminal, home, "edit-finished")
        (tmp / "a").write_text("external")
        text = undo(terminal, home, "no files changed")
        assert "skipped (external change" in text and str(tmp / "a") in text
        assert (tmp / "a").read_text() == "external"
        assert (tmp / "new").read_text() == "nib-new"
        (tmp / "a").write_text("nib")
        undo(terminal, home, "deleted:")
        assert (tmp / "a").read_text() == "old"
        assert not (tmp / "new").exists()
        terminal.send("busy\r")
        assert gated.received.wait(5)
        before = len(history(home))
        terminal.send("/undo\r")
        terminal.until(b"press Esc to stop it first")
        assert len(history(home)) == before
        assert not gated.release.is_set()
        gated.release.set()
        done(terminal, home, "busy-finished")


def test_agents(tmp):
    parent = js_call("edit", path="shared", old_text="old", new_text="parent")
    parent += ";" + js_call("agent", prompt="child-first")
    child = js_call("edit", path="shared", old_text="parent", new_text="child")
    child += ";" + js_call("write", path="child-new", content="child-created")
    resume = js_call("agent", prompt="child-resume", resume="a1")
    resumed_child = js_call("write", path="resumed-new", content="resumed")
    fork = js_call("agent", prompt="fork-child", fork=True)
    fork_child = js_call("write", path="fork-new", content="forked")
    replies = [Reply(code=parent), Reply(code=child), Reply("child-finished"), Reply("parent-finished"),
               Reply(code=resume), Reply(code=resumed_child), Reply("child-resumed"), Reply("resume-finished"),
               Reply(code=fork), Reply(code=fork_child), Reply("fork-child-finished"), Reply("fork-finished")]
    with fixture(tmp, replies) as (terminal, home, _):
        (tmp / "shared").write_text("old")
        terminal.send("parent\r")
        done(terminal, home, "parent-finished")
        assert (tmp / "shared").read_text() == "child"
        text = undo(terminal, home, "deleted:")
        assert "child-new" in text and "shared" in text, text
        assert (tmp / "shared").read_text() == "old"
        assert not (tmp / "child-new").exists()
        terminal.send("resume\r")
        done(terminal, home, "resume-finished")
        undo(terminal, home, "resumed-new")
        assert not (tmp / "resumed-new").exists()
        terminal.send("fork\r")
        done(terminal, home, "fork-finished")
        undo(terminal, home, "fork-new")
        assert not (tmp / "fork-new").exists()


def test_resume(tmp):
    replies = [Reply(code=js_call("write", path="a", content="first")), Reply("first-finished"),
               Reply(code=js_call("write", path="a", content="later")), Reply("later-finished"),
               Reply("resumed-informed")]
    with fixture(tmp, replies) as (terminal, home, env):
        (tmp / "a").write_text("original")
        terminal.send("first\r")
        done(terminal, home, "first-finished")
        undo(terminal, home, "restored:")
        terminal.send("later\r")
        done(terminal, home, "later-finished")
        log, _ = root_log(home)
        session = log.stem
        terminal.close()
        assert not list((home / "sessions").glob("*.undo"))
        next_terminal = Terminal(tmp, env)
        try:
            next_terminal.send("/resume " + session + "\r")
            next_terminal.until(b"resumed session")
            undo(next_terminal, home, "Restored sessions cannot undo earlier Turns", session)
            assert (tmp / "a").read_text() == "later"
            next_terminal.send("after resume\r")
            wait_for(lambda: history(home, session)[-1].get("content") == "resumed-informed", "resumed model")
            assert any("restored:" in m.get("content", "") for m in replies[-1].messages)
        finally:
            next_terminal.close()


def test_cancelled_turn(tmp):
    code = js_call("edit", path="a", old_text="old", new_text="changed") + "; await tools.sleep(30000)"
    with fixture(tmp, [Reply(code=code)]) as (terminal, home, _):
        (tmp / "a").write_text("old")
        terminal.send("edit and wait\r")
        wait_for(lambda: (tmp / "a").read_text() == "changed", "edit before cancellation")
        terminal.send("\x1b")
        terminal.until(b"canceled")
        undo(terminal, home, "restored:")
        assert (tmp / "a").read_text() == "old"


def test_limits_do_not_block_child_writes(tmp):
    bulk = "for (let i = 0; i < 300; i++) { const r = await tools.write({path: 'bulk-' + i, content: 'bulk'}); if (JSON.stringify(r) !== '{\"bytes\":4}') throw new Error(JSON.stringify(r)); }"
    replies = [Reply(code=js_call("write", path="earlier", content="keep")), Reply("earlier-finished"),
               Reply(code=js_call("agent", prompt="bulk")), Reply(code=bulk), Reply("child-finished"),
               Reply("bulk-finished"), Reply(code=js_call("write", path="newer", content="new")),
               Reply("newer-finished")]
    with fixture(tmp, replies) as (terminal, home, _):
        terminal.send("earlier\r")
        done(terminal, home, "earlier-finished")
        terminal.send("bulk\r")
        done(terminal, home, "bulk-finished")
        assert len(list(tmp.glob("bulk-*"))) == 300
        text = undo(terminal, home, "Turn exceeds undo path limit (256 files)")
        assert "earlier Turns cannot be undone across it" in text
        assert all(p.read_text() == "bulk" for p in tmp.glob("bulk-*"))
        assert (tmp / "earlier").read_text() == "keep"
        terminal.send("newer\r")
        done(terminal, home, "newer-finished")
        undo(terminal, home, "deleted:")
        assert not (tmp / "newer").exists()
        undo(terminal, home, "Turn exceeds undo path limit")
        assert (tmp / "earlier").exists()


def test_unwritable_snapshots_do_not_block_child_writes(tmp):
    gated = Reply(code=js_call("agent", prompt="write with unwritable snapshots"), gated=True)
    child = js_call("write", path="child-new", content="child")
    parent = "const r = await tools.edit({path: 'child-new', old_text: 'child', new_text: 'edited'}); if (JSON.stringify(r) !== '{\"replaced\":1}') throw new Error(JSON.stringify(r));"
    replies = [Reply(code=js_call("write", path="earlier", content="keep")), Reply("earlier-finished"),
               gated, Reply(code=child), Reply("child-finished"), Reply(code=parent), Reply("unwritable-finished")]
    with fixture(tmp, replies) as (terminal, home, _):
        terminal.send("earlier\r")
        done(terminal, home, "earlier-finished")
        terminal.send("unwritable\r")
        assert gated.received.wait(5)
        directory = next(p for p in (home / "sessions").glob("*.undo/*") if not list(p.iterdir()))
        directory.chmod(0o500)
        try:
            gated.release.set()
            done(terminal, home, "unwritable-finished")
            assert (tmp / "child-new").read_text() == "edited"
        finally:
            directory.chmod(0o700)
        undo(terminal, home, "undo snapshot could not be read or saved")
        undo(terminal, home, "earlier Turns cannot be undone across it")
        assert (tmp / "earlier").read_text() == "keep"
        assert (tmp / "child-new").read_text() == "edited"


def test_large_original_does_not_block_write(tmp):
    code = "const r = await tools.write({path: 'large', content: 'small'}); if (JSON.stringify(r) !== '{\"bytes\":5}') throw new Error(JSON.stringify(r));"
    with fixture(tmp, [Reply(code=code), Reply("large-finished")]) as (terminal, home, _):
        (tmp / "large").write_bytes(b"x" * (16 * 1024 * 1024 + 2))
        terminal.send("write\r")
        done(terminal, home, "large-finished")
        assert (tmp / "large").read_text() == "small"
        undo(terminal, home, "undo snapshot could not be read or saved")
        assert (tmp / "large").read_text() == "small"


def test_background_agent(tmp):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            messages = request["messages"]
            child = any(m.get("content") == "child-work" for m in messages)
            code = None
            if child:
                if not any(m["role"] == "tool" for m in messages):
                    code = js_call("write", path="后台.txt", content="background child")
                text = "child-finished"
            elif not any(m["role"] == "tool" for m in messages):
                code = js_call("agent", prompt="child-work", background=True)
                text = "started"
            elif any(m.get("content", "").startswith("[background agent ") for m in messages):
                text = "background-finished"
            else:
                text = "waiting"
            delta = {"content": text}
            if code is not None:
                delta["tool_calls"] = [{"index": 0, "id": "bg-run", "type": "function",
                                        "function": {"name": "run", "arguments": json.dumps({"code": code})}}]
            events = [{"choices": [{"delta": delta}]},
                      {"choices": [{"delta": {}, "finish_reason": "tool_calls" if code else "stop"}],
                       "usage": {"prompt_tokens": 100, "completion_tokens": 10}}]
            body = ("".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    tmp.mkdir()
    home = tmp / "home"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "DEEPSEEK_", "CODEX_"))}
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as mock:
        thread = threading.Thread(target=mock.serve_forever, daemon=True)
        thread.start()
        env.update(NIB_PROVIDER="chat_completions", NIB_API_KEY="mock",
                   NIB_BASE_URL=f"http://127.0.0.1:{mock.server_port}", NIB_HOME=str(home),
                   HOME=str(tmp), TERM="xterm-256color")
        terminal = Terminal(tmp, env)
        try:
            terminal.send("parent-work\r")
            done(terminal, home, "background-finished")
            assert (tmp / "后台.txt").read_text() == "background child"
            undo(terminal, home, "deleted:")
            assert not (tmp / "后台.txt").exists()
        finally:
            terminal.close()
            mock.shutdown()
            thread.join()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="nib-undo-") as directory:
        root = Path(directory)
        for test in (test_files_and_history, test_conflict_and_busy, test_agents, test_resume,
                     test_cancelled_turn, test_background_agent, test_limits_do_not_block_child_writes,
                     test_unwritable_snapshots_do_not_block_child_writes, test_large_original_does_not_block_write):
            test(root / test.__name__)
            print(test.__name__ + " passed")
