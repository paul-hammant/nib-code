#!/bin/sh
# Runs ae/tests/tool_activity.py (the TUI's Running line names the active
# tool) against the built binary.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 "$ROOT/ae/tests/tool_activity.py"
