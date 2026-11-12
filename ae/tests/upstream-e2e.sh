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

# The tests this slice is meant to pass, in whole or in part.
APPLY="tests/test_cli.py tests/test_providers.py tests/test_session.py tests/test_stream_idle.py
tests/test_effort.py tests/test_model.py tests/test_files.py tests/test_sandbox.py tests/test_limits.py
tests/test_background_bash.py tests/test_llm.py tests/test_undo.py"

files="$*"
[ -n "$files" ] || files=$APPLY
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/nib-e2e.XXXXXX")
pass=0
fail=0
for f in $files; do
    name=$(basename "$f" .py)
    if (cd tests && timeout 900 python3 "$name.py" > "$LOGS/$name.log" 2>&1); then
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
