"""Skills index on the local mock wire; no real model requests."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/nib"


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        home, data, project = [root / name for name in ("home", "data", "project")]
        for path in (home, data, project):
            path.mkdir()
        (project / ".git").mkdir()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        requests = root / "requests.jsonl"
        server = subprocess.Popen(["python3", str(ROOT / "tests/mock_llm.py"), str(port), str(requests)])
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.05)
            env = dict(os.environ, HOME=str(home), NIB_HOME=str(data), NIB_PROVIDER="chat_completions", NIB_MODEL="mock", NIB_API_KEY="mock", NIB_BASE_URL=f"http://127.0.0.1:{port}/v1")
            def ask(*args):
                result = subprocess.run([str(BIN), "ask", "child probe", *args], cwd=project, env=env, capture_output=True, timeout=20)
                assert result.returncode == 0, result.stderr
                return json.loads(requests.read_text().splitlines()[-1])["messages"][0]["content"]
            bare = ask()
            assert "<available_skills>" not in bare
            skill = project / ".nib/skills/example/SKILL.md"
            skill.parent.mkdir(parents=True)
            skill.write_text('---\nname: example\ndescription: "Example <task>"\n---\nFull instructions')
            for name, content in {
                "invalid": "---\nname: invalid\n---",
                "disabled": "---\ndescription: hidden\ndisable-model-invocation: true\n---",
            }.items():
                path = project / f".nib/skills/{name}/SKILL.md"
                path.parent.mkdir(parents=True)
                path.write_text(content)
            assert ask() == bare, "off-by-default skills must not change the system bytes"
            (data / "config.toml").write_text("[skills]\nexample = false\n")
            assert ask() == bare
            (data / "config.toml").write_text("[skills]\nexample = true\nmissing = true\ndisabled = true\n")
            system = ask()
            assert str(skill) in system and "Example &lt;task&gt;" in system
            assert "Full instructions" not in system
            logs = [p for p in (data / "sessions").glob("*.jsonl") if not p.name.endswith(".calls.jsonl")]
            session = next(p for p in logs if "<available_skills>" in p.read_text())
            metadata = json.loads(session.read_text().splitlines()[0])["skills"]
            assert metadata["count"] == 1 and metadata["found"] == 2 and metadata["missing"] == 1 and len(metadata["skipped"]) == 2, metadata
            assert {item["reason"] for item in metadata["skipped"]} == {"MissingDescription", "disable-model-invocation"}
            skill.unlink()
            assert ask("--resume", session.stem) == system
            assert "<available_skills>" not in ask()
            print("skills: passed")
        finally:
            server.terminate()
            server.wait()


def tui_toggles():
    import fcntl
    import struct
    import termios
    from test_interjections import Reply, fixture, wait_for

    with tempfile.TemporaryDirectory() as temp:
        for width in (60, 120, 160):
            directory = Path(temp) / str(width)
            reply = Reply("skills-tui-done")
            with fixture(directory, [reply]) as (terminal, home, _):
                fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, width, 0, 0))
                skill = directory / ".agents/skills/example/SKILL.md"
                skill.parent.mkdir(parents=True)
                skill.write_text("---\nname: example\ndescription: Example task\n---")
                terminal.send("/skills\r")
                terminal.until(b"Example task")
                terminal.until(b"off")
                terminal.send("/skills on example\r")
                config = home / "config.toml"
                wait_for(lambda: config.exists() and "example = true" in config.read_text(), "skill enabled")
                terminal.until(b"Applies to new sessions.")
                terminal.send("/new\r/status\r")
                terminal.until(b"Skills: 1 on")
                terminal.send("/skills off example\r")
                wait_for(lambda: "example = false" in config.read_text(), "skill disabled")
                terminal.send("check current session\r")
                terminal.until(reply.text.encode())
                assert "<available_skills>" in reply.messages[0]["content"], reply.messages
            print(f"skills TUI {width} columns: passed")


if __name__ == "__main__":
    main()
    tui_toggles()
