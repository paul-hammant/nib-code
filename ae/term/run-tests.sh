#!/bin/sh
# Runs ae/term's tests: the specs, the replay of the real renderer's frames
# through upstream's scripts/screen.py, and the demo in a pty (restoring
# the terminal on quit, signals and a panic). Needs ae and python3.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/aeterm.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/frames"
failed=0
for spec in ae/term/tests/test_*.ae; do
    echo "== $spec"
    TERM_FIDELITY_DIR="$work/frames" ae run --lib ae "$spec" || failed=1
done
echo "== renderer fidelity (upstream scripts/screen.py)"
python3 -I ae/term/tests/fidelity.py "$work/frames" || failed=1
echo "== demo in a pty"
if ae build --lib ae ae/term/demo/demo.ae -o "$work/demo" >/dev/null; then
    python3 -I ae/term/tests/test_restore.py "$work/demo" || failed=1
else
    echo "demo: build failed"
    failed=1
fi
if [ "$failed" -ne 0 ]; then
    echo "ae/term: FAILED"
    exit 1
fi
echo "ae/term: all passing"
