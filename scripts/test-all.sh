#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
workers=${1:-4}
if ! [[ $workers =~ ^[1-9][0-9]*$ ]]; then
    echo 'Usage: scripts/test-all.sh [positive worker count]' >&2
    exit 2
fi
logs=$(mktemp -d "${TMPDIR:-/tmp}/nib-e2e.XXXXXX")
export logs
list="$logs/tests"
grep -oE 'tests/test_[[:alnum:]_]+\.py' AGENTS.md | awk '!seen[$0]++' > "$list"
if [[ ! -s $list ]]; then
    echo 'No e2e tests selected' >&2
    exit 2
fi
SECONDS=0
xargs -P "$workers" -n 1 bash -c '
    test_file=$1
    log="$logs/$(basename "$test_file").log"
    if python3 "$test_file" > "$log" 2>&1; then
        rm "$log"
    else
        echo "FAIL: $test_file"
        cat "$log"
    fi
' _ < "$list"
failed=$(find "$logs" -name '*.log' | wc -l | tr -d ' ')
total=$(wc -l < "$list" | tr -d ' ')
echo "$total scripts, $failed failed, ${SECONDS}s (${workers} workers)"
if (( failed )); then
    echo "Failure logs: $logs"
    exit 1
fi
rm -r "$logs"
