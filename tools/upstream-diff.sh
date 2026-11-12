#!/bin/sh
# tools/upstream-diff.sh — what upstream changed in each ported file since
# the commit its PORT_STATUS.md row says it is ported through.
#   tools/upstream-diff.sh            commits per file (git log --oneline)
#   tools/upstream-diff.sh --diff     the diffs themselves
#   UPSTREAM_REF=upstream/main tools/upstream-diff.sh   (default: main, the mirror)
# Rows read: | `src/...` | lines | `ae/...` | <commit> | notes |, one upstream
# file per row; rows whose third column is not a 7+ hex commit are skipped.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
REF=${UPSTREAM_REF:-main}
mode=${1:-}
total=0
grep -E '^\| `src/' PORT_STATUS.md | while IFS='|' read -r _ up _lines _ae through _notes; do
    file=$(printf '%s' "$up" | tr -d ' `')
    commit=$(printf '%s' "$through" | tr -d ' `')
    case "$commit" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
        *) continue ;;
    esac
    log=$(git log --oneline "$commit..$REF" -- "$file" 2>/dev/null || true)
    if [ -z "$log" ]; then
        echo "up to date   $file ($commit)"
    else
        echo "OWES         $file since $commit:"
        echo "$log" | sed 's/^/             /'
        if [ "$mode" = "--diff" ]; then git diff "$commit..$REF" -- "$file"; fi
    fi
done
