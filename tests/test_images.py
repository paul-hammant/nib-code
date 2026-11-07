"""Image attachments and tools.view on every wire protocol, resume, and TUI paste; local mocks only."""
import base64
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

from mock_providers import Mock
import test_interjections as tui
from test_interjections import Reply, fixture, history, wait_for

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"
PNG = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 640, 480) + b"\x08\x06\x00\x00\x00"
ENCODED = base64.b64encode(PNG).decode()
DATA_URL = "data:image/png;base64," + ENCODED


def walk(value):
    yield value
    if isinstance(value, dict):
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def contains_image(body):
    return any(isinstance(node, dict) and (node.get("type") in ("image", "input_image", "image_url")) for node in walk(body))


class View(unittest.TestCase):
    def run_view(self, name, protocol, key_env, custom_config=None, custom_run=False):
        tmp = Path(tempfile.mkdtemp(prefix="nib-images-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        shot = tmp / "shot.png"
        shot.write_bytes(PNG)
        mock = Mock(protocol, custom_run=custom_run, code=f"console.log(await tools.view({{path: {json.dumps(str(shot))}}}));")
        self.addCleanup(mock.close)
        home = tmp / "nib"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NIB_", "OPENAI_", "ANTHROPIC_", "DEEPSEEK_", "XAI_", "CODEX_"))}
        env.update(HOME=str(tmp), NIB_HOME=str(home), NIB_PROVIDER=name, NIB_BASE_URL=mock.url, NIB_API_KEY=mock.key)
        env[key_env] = mock.key
        if custom_config:
            home.mkdir()
            (home / "config.toml").write_text(custom_config.replace("{url}", mock.url))

        def ask(prompt, *args):
            result = subprocess.run([str(BIN), "ask", "--json", prompt, *args], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return [json.loads(line) for line in result.stdout.splitlines()]

        events = ask("view it")
        self.assertFalse(mock.errors, mock.errors)
        session = events[0]["start"]["session_id"]
        return tmp, home, mock, ask, session

    def log_text(self, home):
        return "\n".join(path.read_text() for path in (home / "sessions").glob("[0-9a-f]" * 32 + ".jsonl"))

    def test_anthropic_tool_result_content(self):
        tmp, home, mock, ask, session = self.run_view("anthropic", "anthropic_messages", "ANTHROPIC_API_KEY")
        result = mock.requests[1][2]["messages"][-1]["content"][0]
        self.assertEqual(result["type"], "tool_result")
        text, image = result["content"]
        self.assertIn("\"width\":640", text["text"])
        self.assertEqual(image["source"], {"type": "base64", "media_type": "image/png", "data": ENCODED})
        self.assertIn("cache_control", result)
        log = self.log_text(home)
        self.assertNotIn(ENCODED, log)
        self.assertIn('"media_type":"image/png"', log)
        directory = home / "sessions" / f"{session}.images"
        stored = list(directory.iterdir())
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0].read_bytes(), PNG)
        self.assertEqual(stored[0].stat().st_mode & 0o777, 0o600)
        before = len(mock.requests)
        ask("again", "--resume", session)
        self.assertTrue(contains_image(mock.requests[before][2]), "resume restores the stored image")
        stored[0].unlink()
        ask("again", "--resume", session)
        self.assertFalse(contains_image(mock.requests[-1][2]))
        self.assertIn("[image " + str(tmp / "shot.png") + " unavailable", json.dumps(mock.requests[-1][2]))
        self.assertFalse(mock.errors, mock.errors)

    def test_responses_tool_output_array(self):
        _, _, mock, _, _ = self.run_view("openai", "responses", "OPENAI_API_KEY", custom_run=True)
        output = next(item for item in mock.requests[1][2]["input"] if item.get("type") == "custom_tool_call_output")["output"]
        self.assertEqual(output[0]["type"], "input_text")
        self.assertEqual(output[1], {"type": "input_image", "image_url": DATA_URL})

    def test_responses_follow_up_message_for_other_hosts(self):
        _, _, mock, _, _ = self.run_view("xai", "responses", "XAI_API_KEY")
        items = mock.requests[1][2]["input"]
        index = next(i for i, item in enumerate(items) if item.get("type") == "function_call_output")
        self.assertIsInstance(items[index]["output"], str)
        follow = items[index + 1]
        self.assertEqual(follow["role"], "user")
        self.assertEqual(follow["content"][1], {"type": "input_image", "image_url": DATA_URL})

    def test_chat_completions_user_message_after_tool(self):
        config = '[providers.site]\nprotocol = "chat_completions"\nbase_url = "{url}"\nmodel = "m"\ncontext_window = 128000\napi_key_env = "SITE_KEY"\nvision = true\n'
        _, _, mock, _, _ = self.run_view("site", "chat_completions", "SITE_KEY", custom_config=config)
        messages = mock.requests[1][2]["messages"]
        index = next(i for i, message in enumerate(messages) if message["role"] == "tool")
        self.assertIsInstance(messages[index]["content"], str)
        follow = messages[index + 1]
        self.assertEqual(follow["role"], "user")
        self.assertEqual(follow["content"][-1], {"type": "image_url", "image_url": {"url": DATA_URL}})

    def test_model_without_vision_gets_data_not_pixels(self):
        _, _, mock, _, _ = self.run_view("deepseek", "chat_completions", "DEEPSEEK_API_KEY")
        request = mock.requests[1][2]
        self.assertFalse(contains_image(request))
        self.assertIn("does not support image input", json.dumps(request["messages"]))


def vision_config():
    return '[providers.site]\nprotocol = "chat_completions"\nbase_url = "{url}"\nmodel = "m"\ncontext_window = 128000\nvision = true\n'


def paste(terminal, text):
    terminal.send("\x1b[200~" + text + "\x1b[201~")


def test_tui_paste_path_attaches_image(tmp):
    shot = tmp.parent / (tmp.name + "-my shot.png")
    shot.write_bytes(PNG)
    reply = Reply("seen")
    with fixture(tmp, [reply], config=vision_config(), provider="site") as (terminal, home, _):
        paste(terminal, str(shot).replace(" ", "\\ "))
        terminal.until(b"[Image #1]")
        paste(terminal, "/does/not/exist.png")
        terminal.until(b"/does/not/exist.png")
        terminal.send(" describe\r")
        assert reply.received.wait(5)
        content = reply.messages[-1]["content"]
        assert content[0]["text"].startswith("[Image #1]") and content[0]["text"].endswith(" describe"), content
        assert "/does/not/exist.png" in content[0]["text"], content
        assert content[1] == {"type": "image_url", "image_url": {"url": DATA_URL}}, content
        wait_for(lambda: tui.finished(home, "seen"), "turn committed")
        rows = history(home)
        user = next(m for m in rows if m["role"] == "user")
        assert user["images"][0]["name"] == shot.name and user["images"][0]["width"] == 640, user
        assert ENCODED not in "".join(p.read_text() for p in (home / "sessions").glob("*.jsonl"))
        terminal.send("\x16")
        terminal.until(b"clipboard")
    shot.unlink()


def test_tui_refuses_images_without_vision(tmp):
    shot = tmp.parent / (tmp.name + "-shot.png")
    shot.write_bytes(PNG)
    with fixture(tmp, [Reply("never")]) as (terminal, home, _):
        paste(terminal, str(shot))
        terminal.until(b"has no image input")
        assert b"[Image #1]" not in terminal.read()
    shot.unlink()


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(View)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if not result.wasSuccessful():
        sys.exit(1)
    with tempfile.TemporaryDirectory(prefix="nib-tui-images-") as directory:
        base = Path(directory)
        for index, check in enumerate((test_tui_paste_path_attaches_image, test_tui_refuses_images_without_vision)):
            check(base / f"case{index}")
            print(check.__name__ + ": ok")
