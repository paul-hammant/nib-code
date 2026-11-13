#!/bin/sh
# Runs ae/tests/tui_e2e.py (TUI checks upstream's Python tests do not reach)
# against the built binary.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 "$ROOT/ae/tests/tui_e2e.py"
