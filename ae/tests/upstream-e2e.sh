#!/bin/sh
# ae/tests/upstream-e2e.sh — run upstream's Python end-to-end tests,
# unchanged, against the Aether binary. They hard-code zig-out/bin/nib, so
# that path is pointed at target/build/bin/nib (zig-out/ is gitignored).
# Every test drives local mocks only (tests/mock_*.py); none reaches a real
# provider.
#
#   ae/tests/upstream-e2e.sh            the tests listed as applying (APPLY)
#   ae/tests/upstream-e2e.sh FILE...    just those (e.g. tests/test_cli.py)
#   VERBOSE=1 ...                       print each failing test's output
#
# PORT_STATUS.md says which pass, which do not yet and why, and which are
# excluded by policy (Codex sign-in and WebSocket).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="$ROOT/target/build/bin/nib"
if [ ! -x "$BIN" ]; then
    echo "build first: aeb .build.ae" >&2
    exit 2
fi
mkdir -p zig-out/bin
ln -sf ../../target/build/bin/nib zig-out/bin/nib

# The tests that apply, one per line: FILE, then the tests left out of it
# (substrings of Class.method, run through ae/tests/run_upstream.py) and
# why. A file with nothing left out runs as upstream runs it.
#   Codex*/codex: policy (API keys only, no Codex sign-in or WebSocket)
#   tui_only_functions_left_out: matches no test id; going through run_upstream.py
#     runs only the unittest classes, leaving out the file's module-level
#     terminal functions (test_mcp: the /mcp menu; test_images: clipboard
#     and paste, still stand-ins in the TUI)
APPLY="tests/test_cli.py
tests/test_providers.py
tests/test_session.py
tests/test_files.py
tests/test_sandbox.py
tests/test_effort.py
tests/test_stream_idle.py|CodexTests
tests/test_llm.py|CodexTests
tests/test_limits.py|Codex
tests/test_agent.py|CodexTests
tests/test_agent_fork.py|CodexForkTests
tests/test_agent_reuse.py|CodexTests
tests/test_background_agent.py|CodexTests
tests/test_background_bash.py|CodexTests
tests/test_background_run.py|codex
tests/test_replay.py
tests/test_tui_stream.py
tests/test_tui_mouse.py
tests/test_model.py
tests/test_undo.py
tests/test_interjections.py
tests/test_at_files.py
tests/test_prediction.py
tests/test_hooks.py
tests/test_skills.py
tests/test_skill_mentions.py
tests/test_mcp.py|tui_only_functions_left_out
tests/test_web_search.py|test_codex
tests/test_images.py|tui_only_functions_left_out
tests/test_stats.py"

files=$(printf '%s\n' "$@")
[ $# -gt 0 ] || files=$APPLY
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/nib-e2e.XXXXXX")
pass=0
fail=0
old_ifs=$IFS
IFS='
'
for f in $files; do
    IFS=$old_ifs
    skips=""
    case "$f" in
        *"|"*) skips=${f#*|}; f=${f%%|*} ;;
        *) entry=$(printf '%s\n' "$APPLY" | grep -F "$f|" | head -1)
           [ -n "$entry" ] && skips=${entry#*|} ;;
    esac
    name=$(basename "$f" .py)
    if [ -n "$skips" ]; then
        # shellcheck disable=SC2086
        (cd tests && timeout 1800 python3 ../ae/tests/run_upstream.py "$name.py" $skips > "$LOGS/$name.log" 2>&1)
    else
        (cd tests && timeout 1800 python3 "$name.py" > "$LOGS/$name.log" 2>&1)
    fi
    if [ $? -eq 0 ]; then
        echo "pass $f"
        pass=$((pass + 1))
    else
        summary=$(tail -1 "$LOGS/$name.log")
        echo "FAIL $f ($summary)"
        fail=$((fail + 1))
        [ "${VERBOSE:-}" = 1 ] && sed 's/^/    /' "$LOGS/$name.log"
    fi
done
echo "$pass passed, $fail failed; logs in $LOGS"
[ "$fail" -eq 0 ]
