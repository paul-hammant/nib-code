#!/bin/sh
# tools/check_layers.sh — the reach of each module of the Aether port is its
# import list (sae's tests/check_layers.sh is the model). This pins the
# imports of every module (ae/main.ae and each ae/nib module; an unpinned one
# fails), so widening one is a reviewed change here, and checks the rules a
# single import list cannot: who may start a process, who may embed QuickJS,
# who may use the marked stand-ins, who reaches the network, and that the
# sandbox's host functions keep their `hide` veto line. The TUI's three
# exceptions (tui/open's launch, tui/reflect's flock, auth/models' GET) are
# each named with the calls they may make and why.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
fail=0

PINNED=""
expect_imports() {   # expect_imports FILE "a|b|..."
    PINNED="$PINNED $1"
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

# The TUI (ae/term underneath; no network, no process of its own except the
# exceptions named in the rules below).
U=ae/nib/tui
expect_imports ae/main.ae "nib.auth|nib.config|nib.config.env|nib.jsonx|nib.provider.types|nib.run_replay|nib.sandbox|nib.session|nib.sysgap|nib.tools|nib.tools.agent_input|nib.tools.background|nib.tools.jail|nib.tui|nib.tui.clock|nib.tui.live|std.fs|std.io|std.list|std.os|std.string|std.sync|std.worker|term|term.input"
expect_imports ae/nib/qjsgap/module.ae ""
# `/model`'s listing (src/auth/models.zig): one GET of the provider's /models.
expect_imports ae/nib/auth/models/module.ae "nib.jsonx|std.http.client|std.json|std.list|std.string|std.time"
expect_imports $U/module.ae "nib.auth|nib.auth.models|nib.config|nib.config.env|nib.jsonx|nib.provider.types|nib.session.skills|nib.session.tool_summary|nib.tools.changes|nib.tools.diff|nib.tui.agent_tree|nib.tui.app_queue|nib.tui.bill|nib.tui.clock|nib.tui.commands|nib.tui.editor|nib.tui.entry|nib.tui.format|nib.tui.frames|nib.tui.long_text|nib.tui.menu|nib.tui.mode|nib.tui.open|nib.tui.paths|nib.tui.port|nib.tui.prediction|nib.tui.provider_flow|nib.tui.reflect|nib.tui.sel_history|nib.tui.selection|nib.tui.status|nib.tui.tasks|nib.tui.title|nib.tui.transcript|nib.tui.tui_view|nib.tui.turn|nib.tui.turn_changes|nib.tui.turn_summary|nib.tui.viewport|std.fs|std.json|std.list|std.os|std.strbuilder|std.string|std.sync|term|term.input|term.screen"
# The Session's live port: the only TUI module that imports nib.session.
expect_imports $U/live/module.ae "nib.config|nib.jsonx|nib.msg|nib.provider|nib.provider.sink as psink|nib.provider.types|nib.sandbox|nib.session|nib.session.instructions|nib.session.log|nib.session.skills|nib.tools|nib.tools.background|nib.tools.changes|nib.tools.diff|nib.tools.jail|nib.tools.progress|nib.tui.app_queue|nib.tui.port|nib.tui.prediction|nib.tui.turn|std.list|std.os|std.string|std.sync|std.worker"
expect_imports $U/port/module.ae "nib.jsonx|nib.provider.types|nib.tui.app_queue|std.list|std.string|std.sync"
expect_imports $U/turn/module.ae "nib.jsonx|nib.tui.app_queue|std.sync"
expect_imports $U/app_queue/module.ae "nib.lock"
expect_imports $U/clock/module.ae "term"
expect_imports $U/frames/module.ae ""
expect_imports $U/mode/module.ae ""
# Drawing and text: no file system, process or network.
expect_imports $U/agent_tree/module.ae "nib.jsonx|nib.tools.progress|nib.tui.format|nib.tui.long_text|std.json|std.list|std.strbuilder|std.string|term.screen"
expect_imports $U/bill/module.ae "nib.tui.format|nib.tui.turn_summary|std.strbuilder|std.string|term.screen"
expect_imports $U/commands/module.ae "nib.provider.types|nib.tui.mode|std.strbuilder|std.string"
expect_imports $U/editor/module.ae "nib.tui.format|nib.tui.long_text|nib.tui.paths|std.strbuilder|std.string|term.input|term.screen"
expect_imports $U/entry/module.ae "nib.session.tool_summary|nib.tui.agent_tree|nib.tui.bill|nib.tui.format|nib.tui.intraline|nib.tui.label|nib.tui.long_text|nib.tui.markdown|nib.tui.smooth|nib.tui.turn_changes|std.list|std.strbuilder|std.string|term.screen"
expect_imports $U/format/module.ae "std.string|term.screen"
expect_imports $U/intraline/module.ae "std.string|term.screen"
expect_imports $U/label/module.ae "nib.session.tool_summary|std.list|std.strbuilder|std.string"
expect_imports $U/long_text/module.ae "std.string|term.screen"
expect_imports $U/markdown/module.ae "nib.tui.syntax|std.strbuilder|std.string|term.screen"
expect_imports $U/menu/module.ae "nib.config|nib.jsonx|nib.provider.types|nib.session.skills|nib.tui.commands|nib.tui.editor|nib.tui.paths|nib.tui.port|std.list|std.string"
expect_imports $U/sel_history/module.ae "nib.tui.entry|nib.tui.viewport|std.strbuilder|std.string|term.screen"
expect_imports $U/selection/module.ae "nib.tui.entry|nib.tui.sel_history|std.strbuilder|std.string|term|term.input|term.screen"
expect_imports $U/smooth/module.ae "std.string|term.screen"
expect_imports $U/status/module.ae "nib.provider.types|nib.tui.format|nib.tui.label|nib.tui.turn_summary|std.strbuilder|std.string|term.screen"
expect_imports $U/syntax/module.ae "std.string|term.screen"
expect_imports $U/tasks/module.ae "nib.tui.agent_tree|nib.tui.format|std.strbuilder|std.string"
expect_imports $U/transcript/module.ae "nib.jsonx|nib.msg|nib.sandbox.timing|nib.session.tool_summary|nib.tools.changes|nib.tools.diff|nib.tui.agent_tree|nib.tui.entry|nib.tui.label|nib.tui.long_text|nib.tui.smooth|nib.tui.turn_changes|nib.tui.viewport|std.json|std.list|std.strbuilder|std.string"
expect_imports $U/tui_view/module.ae "nib.provider.types|nib.tui.commands|nib.tui.editor|nib.tui.entry|nib.tui.format|nib.tui.sel_history|nib.tui.status|nib.tui.viewport|std.string|term.screen"
expect_imports $U/turn_changes/module.ae "nib.tools.changes|nib.tools.diff|nib.tui.long_text|std.list|std.strbuilder|std.string"
expect_imports $U/turn_summary/module.ae "nib.jsonx|std.string"
expect_imports $U/viewport/module.ae "nib.tui.entry|term.screen"
# File system (the @ completion walk, the title's git branch).
expect_imports $U/paths/module.ae "nib.lock|nib.tools.walk|std.fs|std.list|std.string|std.sync|std.worker"
expect_imports $U/title/module.ae "std.fs|std.strbuilder|std.string"
# The model calls are closures the app passes in (prediction) or the /model listing (provider_flow).
expect_imports $U/prediction/module.ae "nib.msg|nib.tui.editor|std.list|std.strbuilder|std.string|std.sync|std.worker"
expect_imports $U/provider_flow/module.ae "nib.auth.models|nib.config|std.list|std.strbuilder|std.string|std.sync|std.worker"
# Processes through tools/process: pbcopy/xclip and friends (clipboard), gh (reflect).
expect_imports $U/clipboard/module.ae "nib.tools.process|std.list|std.string"
expect_imports $U/reflect/module.ae "nib.jsonx|nib.sysgap|nib.tools.process|std.cryptography|std.fs|std.json|std.list|std.os|std.strbuilder|std.string|std.sync|std.worker"
# A clicked path's `open` command, detached (see the exception below).
expect_imports $U/open/module.ae "std.fs|std.list|std.map|std.os|std.strbuilder|std.string|std.worker"

# Every module is pinned: a new one needs its line above.
for f in ae/main.ae $(find ae/nib -name '*.ae' | sort); do
    case " $PINNED " in
        *" $f "*) ;;
        *) echo "FAIL $f has no expect_imports line"; fail=1 ;;
    esac
done

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

# Exceptions, each as narrow as the code needs:
# - tui/open launches the user's `open` command for a clicked path, detached,
#   stdio to /dev/null (upstream open.zig). tools/process ties a child to a
#   Run (output capture, deadline, kill on cancel); a click is outside any Run
#   and must outlive none of that. Only os.spawn_proc_to, and os.wait on its
#   own worker to reap it.
# - tools/jail probes Landlock and execs the bash helper (`nib __jail`).
rule "a program is started only in tools/process (the jail's probe and exec helper aside)" \
    'os\.(run|run_capture|run_full|run_stdio|run_socket|run_pipe|spawn_proc|spawn_proc_to|exec|os_execv|run_supervised)[[:space:]]*\(' \
    "$T/process/|$T/jail/|$U/open/module.ae:[0-9]+:[[:space:]]*token, err = os\.spawn_proc_to\(prog, rest, env, sink\)"
only_calls() {   # only_calls FILE MODULE "allowed members|..." "why"
    used=$(grep -oE "(^|[^A-Za-z0-9_.])$2\.[a-z_]+[[:space:]]*\(" "$1" | sed -E "s/.*$2\.([a-z_]+).*/\1/" | sort -u | tr '\n' ' ')
    bad=""
    for m in $used; do
        case "|$3|" in *"|$m|"*) ;; *) bad="$bad $m" ;; esac
    done
    if [ -n "$bad" ]; then
        echo "FAIL $1 calls $2.(${bad# }) ($4 allows only: $(printf '%s' "$3" | sed 's/|/, /g'))"
        fail=1
    else
        echo "ok   $1 calls only $2.($(printf '%s' "$3" | sed 's/|/, /g')): $4"
    fi
}
only_calls $U/open/module.ae os "platform|spawn_proc_to|wait" "a detached launch"
rule "QuickJS is embedded only by the sandbox and grep's private matcher" \
    '^import contrib\.quickjs' "ae/nib/sandbox/module.ae|$T/grep/"
# - tui/reflect appends to $NIB_HOME/reflections.md under an exclusive flock,
#   as upstream reflect.zig does (two TUIs may reflect at once); std.fs has no
#   flock or positional write yet (asks/aether-fs-stat-flock-exclusive.md).
rule "the file stand-in is used only by the file, undo, process and view tools, the image store, the Session log, the calls recorder, the environment, main (signals, echo) and reflect's locked append" \
    '^import nib\.sysgap' "$T/atomic_file/|$T/file_state/|$T/files/|$T/undo/|$T/process/|$T/bash/|$T/view/|ae/nib/image/|ae/nib/session/log/|ae/nib/sandbox/record/|ae/nib/config/env/|ae/main.ae|$U/reflect/"
only_calls $U/reflect/module.ae sysgap "lock_open|try_lock|fd_size|pwrite_all|close|errname" "the locked append"
rule "the QuickJS stand-in is used only by the sandbox" \
    '^import nib\.qjsgap' "ae/nib/sandbox/module.ae"
# - auth/models lists the provider's models for `/model` (upstream
#   auth/models.zig): one GET, with the key the Session would send.
rule "only provider/http (the model request), auth/models (the /model listing), mcp_transport (Streamable HTTP MCP servers) tools/web_search (the search request) and tools/web (tools.fetch) reach the network" \
    '^import std\.(http|net|tcp|udp)' "ae/nib/provider/http/|ae/nib/auth/models/|ae/nib/mcp/mcp_transport/|$T/web/|$T/web_search/"
if grep -nE 'client\.request\(' ae/nib/auth/models/module.ae | grep -vqE 'client\.request\("GET", '; then
    echo "FAIL ae/nib/auth/models sends something other than a GET"; fail=1
else
    echo "ok   ae/nib/auth/models only GETs"
fi
rule "the /model listing is reached only from the TUI's app and its provider flow" \
    '^import nib\.auth\.models' "$U/module.ae|$U/provider_flow/"
rule "the TUI reaches the Session only through its live port" \
    '^import nib\.session$' "$U/live/|ae/main.ae|ae/nib/tools/agent/|ae/nib/session/"

# ae/term stands alone: nothing of nib.
if grep -rnE '^import nib\.' ae/term >/dev/null 2>&1; then echo "FAIL ae/term imports nib"; fail=1; else echo "ok   ae/term imports nothing of nib"; fi

# The sandbox's host functions open with the veto line.
n=$(grep -c 'hide os, worker, dispatch_, work_' ae/nib/sandbox/module.ae || true)
if [ "$n" -ge 2 ]; then echo "ok   the sandbox's host functions keep their hide line"; else echo "FAIL the sandbox's host functions lost their hide line"; fail=1; fi

exit $fail
