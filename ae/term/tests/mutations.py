"""Shows the tests can fail: each mutation below breaks one behaviour of
ae/term, the named checks run, and every one of them must fail; the file
is restored after each. Prints one line per mutation; exits 1 if any check
passed with its behaviour broken.

Usage: python3 ae/term/tests/mutations.py [name-substring...]   (from the repo root)
"""
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[3]
os.chdir(root)
SP = tempfile.mkdtemp(prefix="aeterm-mut.")
def spec(name):
    return ["ae", "run", "--lib", "ae", f"ae/term/tests/{name}"]
def fidelity():
    d = f"{SP}/mutfid"; os.makedirs(d, exist_ok=True)
    for f in os.listdir(d): os.remove(os.path.join(d, f))
    r = subprocess.run(spec("test_pty.ae"), env={**os.environ, "TERM_FIDELITY_DIR": d}, capture_output=True, text=True, timeout=120)
    r2 = subprocess.run(["python3", "-I", "ae/term/tests/fidelity.py", d], capture_output=True, text=True)
    return r2.returncode, r2.stdout
def restore_py():
    b = subprocess.run(["ae", "build", "--lib", "ae", "ae/term/demo/demo.ae", "-o", f"{SP}/mutdemo"], capture_output=True, text=True)
    r = subprocess.run(["python3", "-I", "ae/term/tests/test_restore.py", f"{SP}/mutdemo"], capture_output=True, text=True, timeout=200)
    return r.returncode, r.stdout
M = [
 ("render: covered cells not marked", "ae/term/render/module.ae", "            r.skipped[j] = 1\n", "            r.skipped[j] = 0\n", ["test_render.ae", "fidelity"]),
 ("render: no reposition after a skip", "ae/term/render/module.ae", "        if unchanged {\n            reposition = true\n", "        if unchanged {\n            reposition = false\n", ["test_render.ae", "fidelity"]),
 ("render: every frame redrawn", "ae/term/render/module.ae", "unchanged = !r.refresh && _same(lastc, cell)", "unchanged = false && _same(lastc, cell)", ["test_render.ae", "test_pty.ae"]),
 ("render: dim not re-set after 22", "ae/term/render/module.ae", '        if wd {\n            strbuilder.append(sb, "\\x1b[2m")\n        }\n', "", ["test_render.ae"]),
 ("render: CUP off by one", "ae/term/render/module.ae", '"\\x1b[${row + 1};${col + 1}H"', '"\\x1b[${row + 1};${col}H"', ["test_render.ae", "fidelity"]),
 ("input: kitty modifiers not minus one", "ae/term/input/module.ae", "return (if m > 0 { m - 1 } else { 0 }), release, true", "return m, release, true", ["test_input.ae"]),
 ("input: mouse not zero-based", "ae/term/input/module.ae", "return Mouse { col: x - 1, row: y - 1,", "return Mouse { col: x, row: y,", ["test_input.ae", "test_pty.ae"]),
 ("input: lone ESC not waited for", "ae/term/input/module.ae", "            if eof {\n                return key(ESCAPE), 1\n            }\n            return NoEvent {}, 0", "            return key(ESCAPE), 1", ["test_input.ae"]),
 ("input: paste markers swapped", "ae/term/input/module.ae", "    if num == 200 {\n        return PasteStart {}", "    if num == 201 {\n        return PasteStart {}", ["test_input.ae"]),
 ("screen: word wrap row quirk dropped", "ae/term/screen/module.ae", "            if has_break {\n                soft_wrapped = false\n                row = row + 1", "            if false {\n                soft_wrapped = false\n                row = row + 1", ["test_screen.ae"]),
 ("screen: no clipping above a parent", "ae/term/screen/module.ae", "|| w.parent_y_off + row < 0", "", ["test_screen.ae"]),
 ("unicode: VS16 not wide", "ae/term/screen/unicode.c", "else if (emoji_vs || ri == 2)", "else if (ri == 2)", ["test_screen.ae"]),
 ("tty: fatal signal does not restore", "ae/term/tty.c", "    int saved_errno = errno;\n    restore_all();", "    int saved_errno = errno;", ["restore_py"]),
 ("tty: ISIG left on", "ae/term/tty.c", "ECHO | ECHONL | ICANON | ISIG | IEXTEN", "ECHO | ECHONL | ICANON | IEXTEN", ["test_pty.ae"]),
 ("tty: no SIGWINCH notice", "ae/term/tty.c", "    if (winch_pipe[1] >= 0) (void)!write(winch_pipe[1], &b, 1);", "    (void)b;", ["test_pty.ae", "restore_py"]),
 ("term: alternate screen not left", "ae/term/module.ae", '        strbuilder.append(sb, "\\x1b[?1049l")', "", ["test_terminal.ae", "test_pty.ae", "restore_py"]),
 ("term: query caps ignored", "ae/term/module.ae", "    if what == input.CAP_KITTY_KEYBOARD {\n        t.cap_kitty_keyboard = true", "    if what == input.CAP_KITTY_KEYBOARD {\n        t.cap_kitty_keyboard = false", ["test_pty.ae"]),
 ("term: fake clock stands still", "ae/term/module.ae", "            t.clock = t.clock + timeout_ms", "            t.clock = t.clock", ["test_terminal.ae"]),
 ("snapshot: row count not checked", "ae/term/snapshot/module.ae", "        if count != h.rows {", "        if false {", ["test_snapshot.ae"]),
 ("driver: screen diff blind", "ae/term/driver/module.ae", "    if got == body {\n        return \"\"", "    if true {\n        return \"\"", ["test_terminal.ae"]),
]
only = sys.argv[1:]
survived = 0
for name, path, old, new, checks in M:
    if only and not any(o in name for o in only): continue
    p = root / path
    src = p.read_text()
    if old not in src:
        print(f"?? {name}: pattern not found")
        survived += 1
        continue
    p.write_text(src.replace(old, new, 1))
    try:
        res = []
        for c in checks:
            if c == "fidelity": rc, out = fidelity()
            elif c == "restore_py": rc, out = restore_py()
            else:
                r = subprocess.run(spec(c), capture_output=True, text=True, timeout=180); rc = r.returncode
            res.append(f"{c}:{'FAILS' if rc != 0 else 'passes!'}")
            survived += rc == 0
        print(f"{name}: " + ", ".join(res), flush=True)
    finally:
        p.write_text(src)
sys.exit(1 if survived else 0)
