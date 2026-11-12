#!/bin/sh
# Runs the TUI's std.spec suites; a suite fails on a non-zero exit or a
# "failing" summary line (std.spec under `ae run` may exit 0 on failures).
cd "$(dirname "$0")/.." || exit 1
fail=0
for f in ${@:-ae/tests/tui_*_test.ae ae/tests/auth_models_test.ae}; do
    out=$(ae run --lib ae "$f" 2>&1); rc=$?
    if [ $rc -ne 0 ] || printf '%s' "$out" | grep -qE '[0-9]+ failing|✗'; then
        echo "FAIL $f"; printf '%s\n' "$out" | grep -E '✗|failing|error' | head -5; fail=1
    else
        echo "ok   $f $(printf '%s' "$out" | grep -oE '[0-9]+ passing' | tail -1)"
    fi
done
exit $fail
