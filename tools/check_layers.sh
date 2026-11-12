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
expect_imports ae/nib/jsonx/module.ae "std.json|std.strbuilder|std.string"
expect_imports ae/nib/lock/module.ae "std.sync"
expect_imports ae/nib/sysgap/module.ae "std.list|std.string"
expect_imports ae/nib/sandbox/module.ae "contrib.quickjs|nib.jsonx|nib.qjsgap|nib.sandbox.console|nib.sandbox.record|nib.sandbox.timing|std.intarr|std.list|std.os|std.strbuilder|std.string|std.sync|std.worker"
# The calls sidecar (record) writes one file through the stand-in; replay runs the sandbox with no tools.
expect_imports ae/nib/sandbox/record/module.ae "nib.jsonx|nib.lock|nib.sysgap|std.cryptography|std.fs|std.io|std.list|std.map|std.os|std.strbuilder|std.string"
expect_imports ae/nib/sandbox/replay/module.ae "nib.jsonx|nib.sandbox|std.intarr|std.json|std.list|std.string|std.sync"
expect_imports ae/nib/sandbox/console/module.ae "std.list|std.strbuilder|std.string"
expect_imports ae/nib/sandbox/timing/module.ae "nib.jsonx|std.list|std.os|std.string"
# Pure logic: no file system, process or network.
expect_imports $T/policy/module.ae "std.list|std.strbuilder|std.string"
expect_imports $T/secrets/module.ae "std.list|std.string"
expect_imports $T/diff/module.ae "std.list|std.string"
expect_imports $T/html/module.ae "std.strbuilder|std.string"
expect_imports $T/changes/module.ae "nib.tools.diff|std.list|std.strbuilder|std.string"
expect_imports $T/registry/module.ae "nib.jsonx|nib.lock|std.list|std.os|std.string|std.sync"
expect_imports $T/progress/module.ae "nib.jsonx|nib.lock|std.list|std.os|std.string"
expect_imports $T/background/module.ae "nib.jsonx|nib.lock|std.list|std.string|std.sync|std.worker"
# File system, no process.
expect_imports $T/atomic_file/module.ae "nib.sysgap|std.cryptography|std.fs|std.list|std.os|std.string"
expect_imports $T/file_state/module.ae "nib.lock|nib.sysgap|std.cryptography|std.fs|std.list|std.map|std.string|std.sync"
expect_imports $T/files/module.ae "nib.jsonx|nib.sysgap|nib.tools.atomic_file|nib.tools.file_state|nib.tools.jail|nib.tools.undo|std.fs|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/undo/module.ae "nib.jsonx|nib.sysgap|nib.tools.atomic_file|nib.tools.file_state|nib.tools.registry|std.cryptography|std.dir|std.fs|std.list|std.string|std.strbuilder|std.sync"
expect_imports $T/walk/module.ae "std.dir|std.fs|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/grep/module.ae "contrib.quickjs|nib.tools.walk|std.fs|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/search/module.ae "nib.jsonx|nib.tools.grep|nib.tools.walk|std.json|std.list|std.strbuilder|std.string"
# Processes.
expect_imports $T/process/module.ae "nib.sysgap|std.cryptography|std.fs|std.io|std.ipc|std.list|std.os|std.string|std.sync|std.worker"
expect_imports $T/bash/module.ae "nib.jsonx|nib.sysgap|nib.tools.jail|nib.tools.policy|nib.tools.process|nib.tools.progress|nib.tools.registry|nib.tools.secrets|std.list|std.os|std.string|std.sync"
# Images: file system only (store, read, hash, base64), no network or process.
expect_imports ae/nib/image/module.ae "nib.jsonx|nib.lock|nib.sysgap|nib.tools.atomic_file|std.bytes|std.cryptography|std.encoding|std.fs|std.list|std.strbuilder|std.string"
expect_imports $T/view/module.ae "nib.image|nib.jsonx|nib.sysgap|nib.tools.atomic_file|std.fs|std.list|std.string"
expect_imports $T/jail/module.ae "nib.tools.atomic_file|std.fs|std.list|std.os|std.string"
expect_imports $T/agent_sessions/module.ae "nib.lock|std.list|std.string"
expect_imports $T/agent_input/module.ae "nib.jsonx|nib.provider.types|std.json|std.list|std.strbuilder|std.string"
# A subagent is a child nib started through tools/process.
expect_imports $T/agent/module.ae "nib.jsonx|nib.lock|nib.provider.types|nib.tools.agent_input|nib.tools.agent_sessions|nib.tools.process|nib.tools.progress|nib.tools.secrets|std.json|std.list|std.os|std.strbuilder|std.string|std.sync"
expect_imports ae/nib/session/hooks/module.ae "nib.jsonx|nib.session.instructions|nib.tools.jail|nib.tools.process|nib.tools.secrets|std.list|std.os|std.string|std.sync"
expect_imports ae/nib/build_info/module.ae ""
expect_imports ae/nib/session/fork_history/module.ae "nib.msg|nib.provider.types|std.list|std.string"
expect_imports $T/web/module.ae "nib.jsonx|nib.tools.html|std.http.client|std.json|std.string|std.sync|std.worker"
expect_imports $T/llm_call/module.ae "nib.jsonx|nib.lock|nib.msg|nib.provider|nib.provider.sink|nib.provider.types|std.json|std.list|std.strbuilder|std.string|std.sync"
expect_imports $T/web_search/module.ae "nib.jsonx|nib.lock|nib.provider.sse|nib.provider.types|std.http.client|std.json|std.list|std.string|std.sync|std.time|std.worker"
expect_imports $T/module.ae "nib.image|nib.jsonx|nib.lock|nib.provider.types|nib.sandbox|nib.tools.agent|nib.tools.agent_input|nib.tools.agent_sessions|nib.tools.atomic_file|nib.tools.background|nib.tools.bash|nib.tools.changes|nib.tools.file_state|nib.tools.files|nib.tools.jail|nib.tools.llm_call|nib.tools.mcp_tool|nib.tools.progress|nib.tools.registry|nib.tools.search|nib.tools.undo|nib.tools.view|nib.tools.web|nib.tools.web_search|std.list|std.os|std.strbuilder|std.string|std.sync"

# The Session + provider slice.
expect_imports ae/nib/auth/module.ae "nib.auth.store|nib.config|nib.config.env|nib.provider.types|std.list|std.string"
expect_imports ae/nib/auth/store/module.ae "nib.jsonx|nib.tools.atomic_file|std.fs|std.json|std.string"
expect_imports ae/nib/config/env/module.ae "nib.sysgap|std.list|std.string"
expect_imports ae/nib/config/module.ae "nib.auth.store|nib.config.env|nib.jsonx|nib.provider.types|nib.tools.atomic_file|std.fs|std.list|std.string"
expect_imports ae/nib/msg/module.ae "nib.jsonx|nib.provider.types|std.json|std.list|std.string"
expect_imports ae/nib/provider/anthropic/module.ae "nib.image|nib.jsonx|nib.msg|nib.provider.http|nib.provider.sink|nib.provider.sse|nib.provider.types|std.json|std.list|std.strbuilder|std.string"
expect_imports ae/nib/provider/http/module.ae "nib.lock|nib.provider.model_timing|std.http.client|std.list|std.string|std.sync|std.time|std.worker"
expect_imports ae/nib/provider/module.ae "nib.provider.anthropic|nib.provider.model_timing|nib.provider.openai|nib.provider.responses|nib.provider.sink|nib.provider.types|std.list|std.string|std.sync"
expect_imports ae/nib/provider/openai/module.ae "nib.image|nib.jsonx|nib.msg|nib.provider.http|nib.provider.sink|nib.provider.sse|nib.provider.types|std.json|std.list|std.strbuilder|std.string"
expect_imports ae/nib/provider/responses/module.ae "nib.image|nib.jsonx|nib.msg|nib.provider.http|nib.provider.sink|nib.provider.sse|nib.provider.types|std.json|std.list|std.strbuilder|std.string"
expect_imports ae/nib/provider/sink/module.ae "nib.provider.http|nib.provider.model_timing"
expect_imports ae/nib/provider/model_timing/module.ae "nib.jsonx|nib.provider.types|std.list|std.longarr|std.os|std.string"
expect_imports ae/nib/provider/sse/module.ae "nib.provider.http|std.string"
expect_imports ae/nib/provider/types/module.ae "nib.jsonx|std.list|std.string"
expect_imports ae/nib/session/compact/module.ae "nib.image|nib.jsonx|nib.msg|nib.provider.types|std.json|std.list|std.string"
expect_imports ae/nib/session/instructions/module.ae "std.fs|std.strbuilder|std.string"
expect_imports ae/nib/session/log/module.ae "nib.jsonx|nib.lock|nib.msg|nib.provider.types|nib.sysgap|std.dir|std.fs|std.json|std.list|std.string|std.time"
expect_imports ae/nib/session/module.ae "nib.build_info|nib.image|nib.jsonx|nib.lock|nib.mcp|nib.msg|nib.provider|nib.provider.model_timing as modeltiming|nib.provider.sink|nib.provider.types|nib.sandbox|nib.sandbox.record|nib.sandbox.timing|nib.session.compact|nib.session.fork_history|nib.session.hooks|nib.session.instructions|nib.session.log|nib.session.output|nib.session.profile|nib.session.prompt|nib.session.skills|nib.session.tool_summary|nib.tools|nib.tools.agent_input|nib.tools.agent_sessions|nib.tools.atomic_file|nib.tools.background|nib.tools.diff|nib.tools.progress|std.cryptography|std.fs|std.json|std.list|std.os|std.string|std.sync|std.worker"
# `nib replay`: reads the two Session files, replays through nib.sandbox.replay; no tools, no provider.
expect_imports ae/nib/run_replay/module.ae "nib.jsonx|nib.sandbox|nib.sandbox.replay|nib.session.output|std.fs|std.json|std.list|std.map|std.strbuilder|std.string"
expect_imports ae/nib/session/output/module.ae "nib.sandbox|nib.sandbox.console|std.list|std.strbuilder|std.string"
expect_imports ae/nib/session/profile/module.ae "std.string"
expect_imports ae/nib/session/skills/module.ae "nib.jsonx|std.dir|std.fs|std.list|std.os|std.strbuilder|std.string"
expect_imports ae/nib/session/prompt/module.ae "nib.sandbox|nib.session.output|nib.session.profile|std.cryptography|std.list|std.strbuilder|std.string"
expect_imports ae/nib/session/tool_summary/module.ae "nib.jsonx|nib.sandbox.timing|std.list|std.strbuilder|std.string"

# The MCP client (not yet in the Session): pure index/header logic, then the transport (the only reach to MCP servers: a child through tools/process, or HTTP).
expect_imports ae/nib/mcp/mcp_index/module.ae "nib.jsonx|std.json|std.list|std.strbuilder|std.string"
expect_imports ae/nib/mcp/mcp_headers/module.ae "nib.jsonx|std.encoding|std.json|std.list|std.string"
expect_imports ae/nib/mcp/mcp_transport/module.ae "nib.build_info|nib.jsonx|nib.lock|nib.mcp.mcp_headers|nib.provider.sse|nib.provider.types|nib.tools.jail|nib.tools.process|nib.tools.secrets|std.fs|std.http.client|std.ipc|std.json|std.list|std.os|std.string|std.sync|std.worker"
expect_imports ae/nib/mcp/module.ae "nib.jsonx|nib.lock|nib.mcp.mcp_headers|nib.mcp.mcp_index|nib.mcp.mcp_transport|nib.provider.types|std.json|std.list|std.string|std.sync"
expect_imports $T/mcp_tool/module.ae "nib.image|nib.jsonx|nib.mcp|std.encoding|std.json|std.string"

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

rule "a program is started only in tools/process (and the jail's probe and exec helper, and the TUI's open launcher for a clicked path)" \
    'os\.(run|run_capture|run_full|run_stdio|run_socket|run_pipe|spawn_proc|spawn_proc_to|exec|os_execv|run_supervised)[[:space:]]*\(' \
    "$T/process/|$T/jail/|ae/nib/tui/open/"
rule "QuickJS is embedded only by the sandbox and grep's private matcher" \
    '^import contrib\.quickjs' "ae/nib/sandbox/module.ae|$T/grep/"
rule "the file stand-in is used only by the file, undo, process and view tools, the image store, the Session log, the calls recorder, the environment and main (signals, echo)" \
    '^import nib\.sysgap' "$T/atomic_file/|$T/file_state/|$T/files/|$T/undo/|$T/process/|$T/bash/|$T/view/|ae/nib/image/|ae/nib/session/log/|ae/nib/sandbox/record/|ae/nib/config/env/|ae/main.ae|ae/nib/tui/reflect/"
rule "the QuickJS stand-in is used only by the sandbox" \
    '^import nib\.qjsgap' "ae/nib/sandbox/module.ae"
rule "only provider/http (the model request), auth/models (the /model listing), mcp_transport (Streamable HTTP MCP servers) tools/web_search (the search request) and tools/web (tools.fetch) reach the network" \
    '^import std\.(http|net|tcp|udp)' "ae/nib/provider/http/|ae/nib/auth/models/|ae/nib/mcp/mcp_transport/|$T/web/|$T/web_search/"
rule "the TUI reaches the Session only through its live port" \
    '^import nib\.session$' "ae/nib/tui/live/|ae/main.ae|ae/nib/tools/agent/|ae/nib/session/"

# ae/term stands alone: nothing of nib.
if grep -rnE '^import nib\.' ae/term >/dev/null 2>&1; then echo "FAIL ae/term imports nib"; fail=1; else echo "ok   ae/term imports nothing of nib"; fi

# The sandbox's host functions open with the veto line.
n=$(grep -c 'hide os, worker, dispatch_, work_' ae/nib/sandbox/module.ae || true)
if [ "$n" -ge 2 ]; then echo "ok   the sandbox's host functions keep their hide line"; else echo "FAIL the sandbox's host functions lost their hide line"; fail=1; fi

exit $fail
