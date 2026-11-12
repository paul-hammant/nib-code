#!/bin/sh
# tools/check_layers.sh — the reach of each module of the Aether port is its
# import list (sae's tests/check_layers.sh is the model). This pins every
# service module's imports, so widening one is a reviewed change here, and
# checks the rules a single import list cannot: who may start a process, who
# may embed QuickJS, who may use the marked stand-ins, that nothing in this
# slice reaches the network, and that the sandbox's host functions keep their
# `hide` veto line.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
fail=0

expect_imports() {   # expect_imports FILE "a|b|..."
    got=$(grep -E '^import ' "$1" | sed 's/^import //' | sort | tr '\n' '|')
    want=$(printf '%s' "$2" | tr '|' '\n' | sort | tr '\n' '|')
    if [ "$got" = "$want" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1 imports changed:"
        echo "       expected: $want"
        echo "       found:    $got"
        fail=1
    fi
}

T=ae/nib/tools
expect_imports ae/nib/jsonx/module.ae "std.json|std.string"
expect_imports ae/nib/lock/module.ae "std.sync"
expect_imports ae/nib/sysgap/module.ae "std.list|std.string"
expect_imports ae/nib/sandbox/module.ae "contrib.quickjs|nib.jsonx|nib.qjsgap|nib.sandbox.console|nib.sandbox.timing|std.list|std.os|std.strbuilder|std.string|std.sync|std.worker"
expect_imports ae/nib/sandbox/console/module.ae "std.list|std.strbuilder|std.string"
expect_imports ae/nib/sandbox/timing/module.ae "nib.jsonx|std.list|std.os|std.string"
# Pure logic: no file system, process or network.
expect_imports $T/policy/module.ae "std.list|std.strbuilder|std.string"
expect_imports $T/secrets/module.ae "std.list|std.string"
expect_imports $T/diff/module.ae "std.list|std.string"
expect_imports $T/changes/module.ae "nib.tools.diff|std.list|std.strbuilder|std.string"
expect_imports $T/registry/module.ae "nib.lock|std.list|std.os|std.string|std.sync"
expect_imports $T/background/module.ae "nib.jsonx|nib.lock|std.list|std.string|std.sync|std.worker"
# File system, no process.
expect_imports $T/atomic_file/module.ae "nib.sysgap|std.cryptography|std.fs|std.list|std.os|std.string"
expect_imports $T/file_state/module.ae "nib.lock|nib.sysgap|std.cryptography|std.fs|std.list|std.map|std.string|std.sync"
expect_imports $T/files/module.ae "nib.jsonx|nib.sysgap|nib.tools.atomic_file|nib.tools.file_state|nib.tools.jail|std.fs|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/walk/module.ae "std.dir|std.fs|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/grep/module.ae "contrib.quickjs|nib.tools.walk|std.fs|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/search/module.ae "nib.jsonx|nib.tools.grep|nib.tools.walk|std.json|std.list|std.strbuilder|std.string"
# Processes.
expect_imports $T/process/module.ae "nib.sysgap|std.cryptography|std.fs|std.list|std.os|std.string|std.sync|std.worker"
expect_imports $T/bash/module.ae "nib.jsonx|nib.sysgap|nib.tools.jail|nib.tools.policy|nib.tools.process|nib.tools.registry|nib.tools.secrets|std.list|std.os|std.string|std.sync"
expect_imports $T/jail/module.ae "nib.tools.atomic_file|std.fs|std.list|std.os|std.string"
expect_imports $T/module.ae "nib.jsonx|nib.lock|nib.sandbox|nib.tools.atomic_file|nib.tools.background|nib.tools.bash|nib.tools.changes|nib.tools.file_state|nib.tools.files|nib.tools.jail|nib.tools.registry|nib.tools.search|std.list|std.os|std.strbuilder|std.string|std.sync"

rule() {   # rule "what" "pattern" "allowed path regex"
    hits=$(grep -rnE "$2" --include='*.ae' ae/nib ae/main.ae 2>/dev/null \
          | grep -vE "^($3)" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
    if [ -n "$hits" ]; then
        echo "FAIL $1:"
        echo "$hits" | sed 's/^/       /'
        fail=1
    else
        echo "ok   $1"
    fi
}

rule "a program is started only in tools/process (and the jail's probe and exec helper)" \
    'os\.(run|run_capture|run_full|run_stdio|run_socket|run_pipe|spawn_proc|spawn_proc_to|exec|os_execv|run_supervised)[[:space:]]*\(' \
    "$T/process/|$T/jail/"
rule "QuickJS is embedded only by the sandbox and grep's private matcher" \
    '^import contrib\.quickjs' "ae/nib/sandbox/module.ae|$T/grep/"
rule "the file stand-in is used only by the file and process tools" \
    '^import nib\.sysgap' "$T/atomic_file/|$T/file_state/|$T/files/|$T/process/|$T/bash/"
rule "the QuickJS stand-in is used only by the sandbox" \
    '^import nib\.qjsgap' "ae/nib/sandbox/module.ae"
rule "nothing in this slice reaches the network" \
    '^import std\.(http|net|tcp|udp)' "^$"

# The sandbox's host functions open with the veto line.
n=$(grep -c 'hide os, worker, dispatch_, work_' ae/nib/sandbox/module.ae || true)
if [ "$n" -ge 2 ]; then echo "ok   the sandbox's host functions keep their hide line"; else echo "FAIL the sandbox's host functions lost their hide line"; fail=1; fi

exit $fail
