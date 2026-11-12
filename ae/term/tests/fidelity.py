"""Replays the real renderer's output with upstream's scripts/screen.py.

test_pty.ae, run with TERM_FIDELITY_DIR=<dir>, leaves capture_<n>.bin (every
byte the terminal received up to frame n) and expected_<n>.txt ("cols rows"
then the grid's rows) there. Each capture, replayed by upstream's own
screen() at that size, must give the grid's rows.

Usage: python3 ae/term/tests/fidelity.py <dir>   (from the repository root)
"""
import importlib.util
import pathlib
import sys


def load_screen(root):
    path = root / "scripts" / "screen.py"
    spec = importlib.util.spec_from_file_location("upstream_screen", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.screen


def main():
    root = pathlib.Path(__file__).resolve().parents[3]
    screen = load_screen(root)
    out = pathlib.Path(sys.argv[1])
    expected_files = sorted(out.glob("expected_*.txt"), key=lambda p: int(p.stem.split("_")[1]))
    if not expected_files:
        print("fidelity: no frames in", out)
        return 1
    failed = 0
    for expected_file in expected_files:
        n = expected_file.stem.split("_")[1]
        lines = expected_file.read_text(encoding="utf-8").split("\n")
        cols, rows = map(int, lines[0].split())
        want = lines[1:1 + rows]
        got = screen((out / f"capture_{n}.bin").read_bytes(), cols, rows)
        if got == want:
            print(f"fidelity: frame {n} ({cols}x{rows}) replays to the grid")
            continue
        failed += 1
        print(f"fidelity: frame {n} ({cols}x{rows}) differs")
        for i, (w, g) in enumerate(zip(want, got)):
            mark = "  " if w == g else "! "
            print(f"  {mark}{i}: grid   |{w}|")
            if w != g:
                print(f"  {mark}{i}: replay |{g}|")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
