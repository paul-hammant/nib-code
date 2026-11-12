#!/bin/sh
# Workspace mode end to end with the built binary (ADR 0004): bash may write
# inside the project and temp dirs, not elsewhere; edit/write refuse outside
# paths as data. macOS goes through sandbox-exec, Linux through `nib __jail`
# (Landlock); where neither is available bash runs unsandboxed, as upstream,
# and this script says so and checks only edit/write.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NIB=${NIB:-$ROOT/target/build/bin/nib}
work=$(mktemp -d)
outside=$(mktemp -d "${HOME}/.nib-workspace-test.XXXXXX")
trap 'rm -rf "$work" "$outside"' EXIT
mkdir -p "$work/proj/.git"
cd "$work/proj"
out=$(NIB_SANDBOX=workspace "$NIB" js "const a = await tools.bash({command: 'echo in > inside.txt; echo out > $outside/x; echo done'}); const w = await tools.write({path: '$outside/y', content: 'y'}).catch(e => e.message); [a.output, w]")
echo "$out"
fail=0
[ "$(cat inside.txt)" = in ] || { echo "FAIL inside write"; fail=1; }
case "$out" in *"outside the project; the sandbox only allows writes"*) ;; *) echo "FAIL write not refused"; fail=1;; esac
[ ! -e "$outside/y" ] || { echo "FAIL write landed outside"; fail=1; }
if [ -e "$outside/x" ]; then
    case "$(uname)" in
        Darwin) echo "FAIL bash wrote outside under sandbox-exec"; fail=1 ;;
        *) echo "note: bash wrote outside: Landlock unavailable on this kernel?" ;;
    esac
else
    echo "ok   bash refused outside the project"
fi
[ $fail = 0 ] && echo "ok   workspace mode"
exit $fail
