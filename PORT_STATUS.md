# The Aether port of nib

This branch (`aether-port`) ports [yyydddkkk/nib-code](https://github.com/yyydddkkk/nib-code)
(Zig, MIT, © jackyyy) to [Aether](https://github.com/aether-lang-dev/aether).
It tracks upstream: `main` in this repository is a mirror of `upstream/main`
and is never committed to; the port follows it.

Ported through upstream commit: **a2dd439** (Release 0.13.0) for the files listed with it below.
`main` was fast-forwarded to upstream **7788541** on 2026-11-12; that delta touches only
`src/tui/view.zig` and docs (TUI slice), so every row here is current with it. Since then
`main` follows upstream to **a6917c6** (2026-11-13; docs only: ADR 0026, CONTEXT.md).

## How the tracking works

- `git fetch upstream && git checkout main && git merge --ff-only upstream/main` moves the mirror.
- Each row below names the upstream file, the Aether file that ports it, and
  the upstream commit that file is ported through. `git diff <commit>..main -- <file>`
  is what the port still owes for that file.
- The parity gate is upstream's own Python tests and mocks (`tests/`), unchanged,
  run against the Aether binary. Fixtures of ours sit beside them, never inside them.

## Layout

The Aether sources live under `ae/`, beside the Zig originals, which stay
untouched so `main` merges in cleanly:

```
ae/main.ae               the binary's entry (name set once, in .build.ae's output())
ae/nib/<concept>/        one module per upstream file or concept, imported as nib.<concept>
                         (the nib. prefix keeps them clear of std and aeb module names,
                         e.g. aeb's own `sandbox` SDK)
ae/nib/sandbox/          src/sandbox.zig, scheduler, native, timer -> module.ae;
                         console.zig, timing.zig -> sandbox/console, sandbox/timing
ae/nib/tools/            src/tools.zig and src/tools/*: one service module per tool family
ae/nib/qjsgap/           marked stand-in for contrib.quickjs gaps (asks/)
ae/term/                 the TUI's terminal layer (another slice)
ae/tests/<name>_test.ae  std.spec suites; upstream's inline Zig tests ported by name
tools/                   port maintenance scripts (upstream-diff.sh, check_layers.sh)
asks/                    what the port needs from Aether, written up for upstream
.build.ae, .tests.ae     aeb: `aeb .build.ae` builds target/build/bin/nib, `aeb .tests.ae` runs the suites
pins                     AE_PIN / AEB_REF the port is verified against
```

## Decisions (Paul, 2026-11-12)

- **Providers use API keys only**, as each vendor documents. Not ported, by
  policy: the Codex subscription sign-in (`src/auth/oauth.zig`, `login.zig`,
  `codex.zig`), the Codex WebSocket protocol (`src/provider/codex_ws.zig`,
  `websocket.zig`), the Codex backend provider, and the tests that need them
  (`tests/test_codex*.py`, `tests/test_provider_login.py`).
- **No recorded provider traffic.** Tests use hand-written mocks only: upstream's
  Python mocks, kept as they are, and fixtures of ours written from the public
  API documentation. Runs against real provider APIs are Paul's to make.
- **The TUI is in the first pass**, on a terminal interface with a real and an
  in-memory implementation, so specs drive it in-process and the session, the
  model and the clock can be mocked. Upstream's pseudo-terminal tests and
  layout snapshots still apply to the real one.
- `src/update` (the self-updater) is not ported at first: it downloads upstream's releases.
- Aether additions (a grant DSL for policy, containment on more platforms, an
  `--emit=lib` library build) are kept separable from the ported code.
- The port may be renamed `naeb` in time.

## Status

| Upstream | Lines | Aether | Ported through | Notes |
|---|---|---|---|---|
| `src/sandbox.zig` | 799 | `ae/nib/sandbox/module.ae` | a2dd439 | eval, Limits, prelude, syntax context; Host.record (settle at delivery, eval_end), Host.virtual |
| `src/sandbox/scheduler.zig` | 296 | `ae/nib/sandbox/module.ae` | a2dd439 | virtual selection in jobs_; concurrency 8, completion order, timers, drain, stopped calls; Host.poll's role is a 20 ms Session ticker (session) |
| `src/sandbox/native.zig` | 163 | `ae/nib/sandbox/module.ae` | a2dd439 | __log/__host as contrib.quickjs host functions with a `hide` veto line; installVirtual (__replayEpoch/Time/Random, "replay diverged"); the virtual stop interrupts JS through a stop cell in nib.qjsgap |
| `src/sandbox/timer.zig` | 18 | `ae/nib/sandbox/module.ae` | a2dd439 |  |
| `src/sandbox/console.zig` | 181 | `ae/nib/sandbox/console/module.ae` | a2dd439 |  |
| `src/sandbox/timing.zig` | 168 | `ae/nib/sandbox/timing/module.ae` | a2dd439 | Execution epoch times live on process.Result |
| `src/sandbox/timer_test.zig` | 237 | `ae/tests/timer_test.ae` | a2dd439 |  |
| `src/sandbox/record.zig` | 510 | `ae/nib/sandbox/record/module.ae` | a2dd439 | file via std.fs (flock, pwrite, ftruncate, fsync); dedup keys are sha256 hex |
| `src/sandbox/replay.zig` | 303 | `ae/nib/sandbox/replay/module.ae` | a2dd439 | Virtual.stopped is a std.sync cell, not a callback |
| `src/sandbox/virtual.zig` | 19 | `ae/nib/sandbox/module.ae` (VIRTUAL_PRELUDE) | a2dd439 |  |
| `src/tools.zig` | 813 | `ae/nib/tools/module.ae` | a2dd439 | table verbatim; only ported tools enter a Run's API; RunScope replaces the threadlocal; docs fill {{llm_limits}}/{{llm_options}}; search options wait for web search |
| `src/tools/files.zig` | 587 | `ae/nib/tools/files/module.ae` | a2dd439 | undo snapshots in edit/write |
| `src/tools/atomic_file.zig` | 243 | `ae/nib/tools/atomic_file/module.ae` | a2dd439 | on std.fs (stat, O_EXCL create, fchmod, fsync, move) |
| `src/tools/file_state.zig` | 247 | `ae/nib/tools/file_state/module.ae` | a2dd439 | flock path locks on std.fs |
| `src/tools/changes.zig` | 253 | `ae/nib/tools/changes/module.ae` | a2dd439 | Tracker per Run scope; Recovery |
| `src/tools/diff.zig` | 195 | `ae/nib/tools/diff/module.ae` | a2dd439 |  |
| `src/tools/search.zig` | 173 | `ae/nib/tools/search/module.ae` | a2dd439 |  |
| `src/tools/grep.zig` | 509 | `ae/nib/tools/grep/module.ae` | a2dd439 | one scanning thread (upstream 8); JS RegExp in a private QuickJS runtime; a running regex is bounded at 10 s, not interruptible by cancel |
| `src/tools/regex.zig` | 106 | `ae/nib/tools/grep/module.ae` | a2dd439 | libregexp via JS RegExp |
| `src/tools/walk.zig` | 385 | `ae/nib/tools/walk/module.ae` | a2dd439 |  |
| `src/tools/policy.zig` | 698 | `ae/nib/tools/policy/module.ae` | a2dd439 | rule for rule, same texts |
| `src/tools/secrets.zig` | 16 | `ae/nib/tools/secrets/module.ae` | a2dd439 |  |
| `src/tools/process.zig` | 358 | `ae/nib/tools/process/module.ae` | a2dd439 | output to a file, not a pipe; a 20 ms tick with the output byte count (progress); run_lines (a child nib: stdin input, stdout lines, TERM then KILL after a grace) through os.run_stdio, its stderr discarded; open_stdio for MCP; a signal reads as 128+n |
| `src/tools/bash.zig` | 433 | `ae/nib/tools/bash/module.ae` | a2dd439 | progress Tracker; ids reserved at start, snapshot after 3 s |
| `src/tools/bash/registry.zig` | 146 | `ae/nib/tools/registry/module.ae` | a2dd439 | supersession; started/superseded/finished log records |
| `src/tools/bash/jail.zig` | 304 | `ae/nib/tools/jail/module.ae` | a2dd439 | Landlock in jail/landlock.c (stand-in); probe cached per Tools, not per process |
| `src/tools/background.zig` | 866 | `ae/nib/tools/background/module.ae` | a2dd439 | bash, agents (start_agent, completion without usage, invocation-matched delivery) and adopted Runs (adopt_run, take_done_runs, enqueue_run with the run completion); typed inbox, started record, lost on resume, detached across Turns; a Run cannot stop itself |
| `src/tools/stop.zig` | 29 | `ae/nib/tools/module.ae`, `ae/nib/tui/live/module.ae` | a2dd439 | userStop is the TUI port's `user_stop_`; a stop requested during a Turn runs on a worker, not in Tools.poll |
| `src/tools/undo.zig` | 606 | `ae/nib/tools/undo/module.ae` | a2dd439 | Session wires begin/finish/undo; off for `nib ask` as upstream; /undo itself is the TUI's |
| `src/tools/view.zig` | 92 | `ae/nib/tools/view/module.ae` | a2dd439 | credential-path refusal as read; the Run's images in `RunScope.images` (`nib.image` Attached, 4 per Run, none from background Runs) |
| `src/tools/progress.zig` | 249 | `ae/nib/tools/progress/module.ae` | a2dd439 |  |
| `src/tools/web.zig` | 161 | `ae/nib/tools/web/module.ae` | a2dd439 | std.http.client on a worker, caller watches cancel/deadline; no response decompression (no accept-encoding is sent) and no environment proxy |
| `src/tools/html.zig` | 504 | `ae/nib/tools/html/module.ae` | a2dd439 | byte-identical to upstream on 310 differential inputs; a stale link offset leaves output alone where upstream would trap |
| `src/tools/web_search.zig` | 404 | `ae/nib/tools/web_search/module.ae` | a2dd439 | openai, anthropic, deepseek routes; no Codex (policy); transport errors carry std.http.client's text |
| `src/tools/llm.zig` | 246 | `ae/nib/tools/llm_call/module.ae` | a2dd439 | the gate is per Tools; subagent usage joins through the same cell |
| `src/tools/agent.zig` | 497 | `ae/nib/tools/agent/module.ae` | a2dd439 | a Ctx per call from the Tools (no threadlocal); the child is `self_exe ask --json --agent-input [--resume] -` via process.run_lines; background calls return status 2 and the tools module starts the job |
| `src/tools/agent/input.zig` | 90 | `ae/nib/tools/agent_input/module.ae` | a2dd439 | renamed (basenames); the Config's JSON spelling is the port's own (both ends are this binary); also the header's mcp_servers JSON |
| `src/tools/agent/sessions.zig` | 119 | `ae/nib/tools/agent_sessions/module.ae` | a2dd439 | renamed |
| `src/tools/mcp.zig` | 101 | `ae/nib/tools/mcp_tool/module.ae` | a2dd439 | renamed (basename `mcp` is the client's) |
| `src/session.zig` | 999 | `ae/nib/session/module.ae` | a2dd439 | Turn/Step loop, resume/continue, interrupted commits, auto compaction, Step-limit wait, undo wiring, the Run's viewed images on its tool message, fork init and per-Step fork snapshots, agent_session restore, skills, MCP (header mcp_servers, the log's on resume), hooks (turn_end on a Session-held thread, TurnJob), the calls recorder; user-message images (`turn_with_images`) |
| `src/session/run.zig` | 236 | `ae/nib/session/module.ae` | a2dd439 | execute + executeTimed: every Run on its own thread (RunJob) with its own timing, merged into the Step's; the waiting flag is the sandbox Host's `waiting` cell |
| `src/session/run_job.zig` | 116 | `ae/nib/session/module.ae` | a2dd439 | RunJob; its recorder is a fork of the Session's (begin at start, finish before done) |
| `src/session/log.zig` | 1402 | `ae/nib/session/log/module.ae` | a2dd439 | records are JSON text; tool summaries travel on the logged tool messages (the TUI reads them on resume); background ids and bash replacements are restored onto replayed messages, as upstream restoreToolSummaries |
| `src/session/output.zig` | 596 | `ae/nib/session/output/module.ae` | a2dd439 |  |
| `src/session/prompt.zig` | 322 | `ae/nib/session/prompt/module.ae` | a2dd439 |  |
| `src/session/profile.zig` | 58 | `ae/nib/session/profile/module.ae` | a2dd439 |  |
| `src/session/instructions.zig` | 49 | `ae/nib/session/instructions/module.ae` | a2dd439 |  |
| `src/session/compact.zig` | 175 | `ae/nib/session/compact/module.ae` | a2dd439 | withoutImages is `without_images` |
| `src/session/tool_summary.zig` | 249 | `ae/nib/session/tool_summary/module.ae` | a2dd439 | annotateViews takes the images as JSON text |
| `src/session/events.zig` | 182 | `ae/nib/session/module.ae` | a2dd439 | events are the NDJSON text they print as |
| `src/session/inbox.zig` | 278 | `ae/nib/tools/background/module.ae` | a2dd439 | bash results, FIFO, detached kept; user interjections (`enqueue_user`/`take_users`, kind "user") inserted before the next Step |
| `src/session/history.zig` | 130 | `ae/nib/session/fork_history/module.ae` | a2dd439 | renamed; messages are JSON texts, copies are fresh strings |
| `src/session/hooks.zig`, `skills.zig` | 538 | `ae/nib/session/hooks/module.ae`, `ae/nib/session/skills/module.ae` | a2dd439 | hooks run `cd <root>` inside the script (process.run has no cwd); skills: unlistable roots report NotDir/AccessDenied, disabled skills are reported in name order |
| `src/provider.zig` | 395 | `ae/nib/provider/types/module.ae`, `ae/nib/provider/module.ae` | a2dd439 | less Codex |
| `src/provider/retry.zig` | 331 | `ae/nib/provider/module.ae` | a2dd439 | no Codex Retry-After or stale-socket paths |
| `src/provider/anthropic.zig` | 444 | `ae/nib/provider/anthropic/module.ae` | a2dd439 | |
| `src/provider/responses.zig` | 1033 | `ae/nib/provider/responses/module.ae` | a2dd439 | SSE only; no Codex auth/WebSocket or web search |
| `src/provider/openai.zig` | 428 | `ae/nib/provider/openai/module.ae` | a2dd439 | HTTP errors other than 401 carry the body (64 KiB), as upstream |
| `src/provider/sse.zig` | 52 | `ae/nib/provider/sse/module.ae` | a2dd439 | plus fixed/live line sources |
| `src/provider/timing.zig` | 319 | `ae/nib/provider/timing/module.ae` | a2dd439 | |
| `src/provider/body.zig`, `cancel.zig`, `idle.zig` | 393 | `ae/nib/provider/http/module.ae` | a2dd439 | a request thread plus a polling reader on std.http.client |
| `src/provider/codex_ws.zig`, `websocket.zig` | 523 | not ported |  | policy: API keys only |
| `src/config.zig` | 1680 | `ae/nib/config/module.ae`, `ae/nib/config/env/module.ae` | a2dd439 | no Codex provider ([codex] validated and ignored); default service anthropic |
| `src/mcp.zig`, `src/mcp/*` | 700 | `ae/nib/mcp/module.ae`, `mcp/mcp_index`, `mcp/mcp_headers`, `mcp/mcp_transport` | a2dd439 | stdio over os.run_stdio (newline-delimited JSON-RPC; stderr discarded and cwd set by os.run_stdio; kill by pid, no process group); Streamable HTTP on std.http.client from a worker thread; no environment proxy |
| `src/main.zig` | 311 | `ae/main.ae` | a2dd439 | ask, js, login/logout, help, version, __jail; bare `nib` opens the TUI (`run_tui_`); `nib replay` with its three error texts; no update |
| `src/replay.zig` | 541 | `ae/nib/run_replay/module.ae` | a2dd439 | renamed (basename `replay` is the core's) |
| `src/image.zig` | 324 | `ae/nib/image/module.ae` | a2dd439 | images are JSON texts (the log's `images` entries); binary-safe reads; SHA-256 hash name; Attached/Target for the Run's images; pastedPath, and read_pasted for the TUI's stat-then-read |
| `src/tui.zig` | 1911 | `ae/nib/tui/module.ae` | 7788541 | the App; takes term, Session port and clock; app events through `nib.tui.app_queue`; the Ticker is the poll timeout; the clipboard reader is an instance field (upstream's test override) |
| `src/tui/view.zig` | 744 | `ae/nib/tui/tui_view/module.ae` | 7788541 | renamed (basename `view`); both snapshot files match cell for cell |
| `src/tui/transcript.zig`, `transcript/entry.zig`, `transcript/changes.zig`, `transcript/intraline.zig`, `transcript/label.zig` | 2634 | `ae/nib/tui/transcript`, `entry`, `turn_changes` (renamed), `intraline`, `label` | 7788541 | replayed tool summaries are read from the messages' `tool_summary` members |
| `src/tui/editor.zig` | 657 | `ae/nib/tui/editor/module.ae` | 7788541 | image blocks hold nib.image Images (JSON text); sent_images is their JSON array |
| `src/tui/markdown.zig`, `syntax.zig` | 1472 | `ae/nib/tui/markdown`, `syntax` | 7788541 | |
| `src/tui/viewport.zig`, `selection.zig`, `selection/history.zig` | 595 | `ae/nib/tui/viewport`, `selection`, `sel_history` (renamed) | 7788541 | the local clipboard tool is a closure the app supplies |
| `src/tui/status.zig`, `bill.zig`, `title.zig`, `format.zig`, `frames.zig`, `smooth.zig`, `long_text.zig`, `mode.zig` | 1076 | `ae/nib/tui/<same>`, `turn_summary` | 7788541 | times are ms from the app's clock |
| `src/tui/commands.zig`, `menu.zig`, `providers.zig` | 1133 | `ae/nib/tui/commands`, `menu`, `module.ae` | 7788541 | execute/select/providers live in the app; `/provider` is key entry only |
| `src/tui/provider_flow.zig` | 658 | `ae/nib/tui/provider_flow/module.ae` | 7788541 | API keys only: the Codex sign-in steps are not ported |
| `src/tui/prediction.zig`, `reflect.zig` | 798 | `ae/nib/tui/prediction`, `reflect` | 7788541 | the model call and gh are closures (specs replace them) |
| `src/tui/paths.zig`, `open.zig`, `clipboard.zig`, `agent_tree.zig`, `tasks.zig`, `turn.zig` | 1306 | `ae/nib/tui/<same>` | 7788541 | turn.zig's thread is the port's (`nib.tui.live`); clipboard checks with nib.image's probe |
| (new) | | `ae/nib/tui/port`, `live`, `clock`, `app_queue` | | the Session interface with its scripted (specs) and live (nib.session) implementations, the clock instance, the app event queue |
| `src/auth.zig`, `src/auth/store.zig`, `src/auth/cli.zig` | 601 | `ae/nib/auth/module.ae`, `ae/nib/auth/store/module.ae` | a2dd439 | API keys only: no tokens, no Codex login |
| `src/auth/oauth.zig`, `login.zig`, `codex.zig` | 798 | not ported | | policy |
| `src/auth/models.zig` | 92 | `ae/nib/auth/models/module.ae` | 7788541 | API keys only |
| `src/update*` | 140 | not ported | | |

`tools/upstream-diff.sh` lists, per row with a commit, what upstream changed
since (`--diff` for the diffs).

## Sandbox and Tools slice (2026-11-12)

**Tests.** `aeb .tests.ae` runs 20 std.spec suites (156 tests) plus
`ae/tests/workspace.sh` (workspace mode through the built binary), and
`tools/check_layers.sh` pins every module's imports. Every upstream inline
test of a ported file is ported under its upstream name, except: replay
tests (record/replay slice); bash progress (`Tracker`) tests; process stdin,
line-observer and inherit-key tests; allocation-failure tests; the tools.zig
tests about llm/agent/search/fork (their tools are not ported). Each module
was mutation-checked: a broken behaviour turns a test red.

**Engine.** contrib.quickjs is quickjs-ng 0.17.0; upstream builds 0.18.
No test here sees a difference. The JS budget is the same cumulative
measure, enforced through the stand-in's interrupt handler.

**Containment.** Tools are service modules; a module's imports are its
reach (`tools/check_layers.sh`): only `tools/process` (and the jail's probe
and helper exec) starts a program (since Aether 0.912.0 a compile error
elsewhere: every other std.os import hides the program starters), only the sandbox and grep's private
matcher embed QuickJS, nothing in this slice imports a network module. The
sandbox's two host functions open with a `hide os, worker, ...` veto line.

**Stand-ins (marked, each with an ask):** `ae/nib/qjsgap` (async eval,
interrupt, promise state: asks/aether-quickjs-async-eval-and-interrupt.md),
`ae/nib/tools/jail/landlock.c` (asks/aether-landlock-write-roots.md).

**Differences kept on purpose or by gap:** grep scans on one thread and
bounds a running regex at 10 s per file; bash output goes through a file;
a signalled bash reports 128+n, not `null`; the jail probe is cached per Tools.

**Upstream's Python tests for this slice** all drive `nib ask` (or the TUI)
against a mock model server, so they wait for the session and provider
slices: `tests/test_sandbox.py` (workspace mode: needs `ask --json`, config
`[sandbox]`, subagents for its child cases), `test_files.py` (file tools in a
Session: `ask --json`, NIB_HOME locks, multi-process edits),
`test_background_bash.py` (needs the inbox, `--resume`, Session ids),
`test_limits.py` (configured limits: config + llm + agent), `test_undo.py`
(TUI `/undo`). They run against the Aether binary unchanged once `nib ask`
speaks the mock's wire protocol.

**What the next slice (Session + Anthropic provider + `nib ask`) needs from
this one:** a `tools.Tools` per Session (`tools.new(home)`, set `data_home`,
`codex_home`, `workspace`, `extra_writable`, `env`, `self_exe`), a
`tools.new_scope(t, run_id)` per Run and `tools.host(scope)` for
`sandbox.eval`; `tools.docs(t)` for the system prompt (plus a
`documentation()` that fills `{{llm_limits}}`/`{{llm_options}}` once config
exists); `sandbox.Outcome` (text, logs, log entries/bytes, tool_bytes,
stopped) for session/output.zig's formatter; `tools.take_changes(scope)`;
`background.take_inbox` / `finish_turn` / `stop_all` for the Turn
lifecycle; and the hooks still missing here: Host.poll and waiting,
progress events, session-log records (bash start/supersede, background,
sandbox_unavailable), undo snapshots in edit/write.

## Session, provider and config slice (2026-11-12)

**What runs.** `nib ask [--json] [-c|--continue|--resume <id>] [--effort <level>]
<prompt|->` over Anthropic Messages, OpenAI Responses (openai, xai, custom
`responses` endpoints) and Chat Completions (deepseek, chat_completions,
custom), API keys only, streaming SSE on std.http.client; the append-only
Session log with resume, torn-tail repair and the session lock; automatic and
model-driven compaction; interrupted Turns (SIGINT/SIGTERM) committed with
their partial text; background bash across Steps and Turns with progress and
log records; tools.llm; undo snapshots (wired, off for `ask` as upstream);
`nib login`/`logout` storing keys in `$NIB_HOME/auth.json` (0600, atomic,
unknown fields kept); `--help` with the active provider.

**Unit tests.** `aeb .tests.ae`: 35 std.spec suites (about 430 tests) plus
workspace.sh and check_layers.sh. Every upstream inline test of a ported file
is ported under its upstream name, except those listed in each suite's
header (Codex, MCP, allocation failures, the Zig Record type). Each
module was mutation-checked.

**Upstream e2e (`ae/tests/upstream-e2e.sh`, tests unchanged)** at the end of this slice; the current table is in the headless features section below.

| Test | Result | Why not all of it |
|---|---|---|
| test_cli.py | pass | |
| test_files.py | pass | |
| test_providers.py | every protocol and provider passes round trip, cache usage, resume, provider mismatch, 401 without the key; fails at its `delegate` step | tools.agent (subagents) |
| test_sandbox.py | all but `test_subagent_inherits_the_sandbox` | tools.agent |
| test_session.py | every section passes except subagents, tools.fetch and `nib_version` | one script: it stops at the first (subagent stats); `nib_version` is `0.13.0-ae`, upstream's is the build.zig.zon version plus the git commit |
| test_stream_idle.py | Chat cases pass except two | tools.agent, tools.llm in a child; Codex classes excluded |
| test_background_bash.py | 30 of 38 non-TUI Chat cases (Linux; on macOS its `/proc` helper needs a stand-in) | tools.agent ids, the TUI; Codex classes excluded |
| test_llm.py | Chat cases pass except the child one, with one assertion set aside | its docs check requires `async agent(` in the prompt |
| test_limits.py | max-steps cases pass; LLM limits pass with the same assertion set aside | agent limits, `nib replay`, Codex classes |
| test_effort.py | the chat_completions half passes | its second half is Codex |
| test_model.py, test_undo.py, test_tui_*.py, test_at_files.py, test_interjections.py, test_prediction.py | pass (TUI slice) | |
| test_images.py | pass (its `View` cases; the TUI functions need the TUI's clipboard and paste, still stand-ins) | |
| test_mcp.py, test_web_search.py, test_stats.py | not yet | their slices (agents, Run backgrounding, TUI, hooks/skills, MCP, replay, web search) |
| test_codex.py, test_codex_websocket.py, test_provider_login.py | excluded | policy: no Codex sign-in or WebSocket |

**Lanes.** macOS arm64, ae-x64 (Ubuntu 22.04) and cachyos: unit suites green on all
three; e2e results as in the table on all three, except that on ae-x64 (kernel 5.15,
no Landlock ABI 2) test_sandbox's six workspace cases fail because bash runs
unsandboxed there, as upstream's would. On Linux test_background_bash runs
unpatched: every non-TUI Chat case passes except the four that need tools.agent.


**Differences kept on purpose or by gap.** No Codex provider: with nothing
configured the default service is anthropic (upstream: codex), a `[codex]`
section is validated and ignored. HTTP error bodies are never echoed, for
every protocol. The request runs on its own thread and an abandoned one ends
at the server's close or the client's whole-exchange timeout. No `Expect:
100-continue` is sent, as upstream (std.http.client skips interim 1xx
responses since Aether 0.910.0 in any case). Header `nib_version` is `0.13.0-ae`.

**What the TUI slice (src/tui*, on ae/term) needs from this one.**
`session.init(cfg, options)` (set `options.undo_enabled = 1` for the TUI),
`session.turn(s, text, sink, cancel)` with the Sink receiving every event as
the NDJSON text `ask --json` prints (step, delta, run_start, run_end with
changes and tool_summary, retry, notice, usage, progress, background),
`session.compact_now` for /compact, `session.undo` for /undo,
`config.load/save_model/save_effort/save_simple/model_entries`,
`auth.services/describe/set_key/sign_out` for /provider. Still to build for
it: Session `reopen`/`switchConfig`, user interjections (inbox users),
replayed tool summaries and bash replacements on restored messages (the log
keeps the records), activity callbacks (model started/data/script/waiting),
`/models` listing (src/auth/models.zig), and `Ctrl+C` routing to the cancel
cell instead of the process flag.

**Next after that.** Subagents (tools.agent, agent/input, agent/sessions,
session/history fork, `--agent-input`), automatic Run backgrounding
(run_job), hooks and skills, MCP, tools.fetch/web_search,
record/replay.

## TUI slice (2026-11-12)

**What runs.** Bare `nib` opens the TUI on the controlling terminal
(`ae/term`), over the real Session with undo on (`-c`/`--resume` reopen
one): streaming with the Thinking / Generating response / Running states,
Run blocks with tool summaries, background tasks and the agent tree,
interjections, Esc cancel with queued text returned to the input, the `/`
menu and every command (`/provider` with API keys only, `/model` with the
listed models, `/effort`, `/undo`, `/tasks`, `/stop`, `/skills`, `/status`,
`/simple`, `/new`, `/resume`, `/copy`, `/js`, `/compact`, `/reflect` with
NIB_ISSUE_REPO, `/mcp`), `@` path and `$` skill completion, input history,
paste blocks, input prediction, mouse selection with OSC 52 copy, hover,
clickable paths with `open`, Simple mode, resize.

**Design (Paul's requirement).** `nib.tui.new(terminal, port, clock, env)`:
the terminal is `term.open()` or `term.memory(cols, rows)`; the Session is a
`nib.tui.port.Port` (closures: the real one is `nib.tui.live` over
`nib.session`, specs use `port.scripted(cfg, home)`, which records Turns
and lets the spec emit events: "reasoning, then text, then a Run with these
results"); the clock is `nib.tui.clock` (`of_terminal`, so an in-memory
terminal's fake clock drives it). No module-level state. Specs drive the
app in-process (`term.driver` keys and mouse, `tui.step`, `tui.settle`): no
pty, no sleeps.

**Session-side hooks added for it** (small, in `nib.session` and
`nib.tools.background`): `Sink.on_activity` (model
started/data/script/waiting/finished, user_inserted; `nib ask` sets none),
`session.enqueue`/`take_queued` (user items in the background inbox,
FIFO, committed with the Step), `session.switch_config` (in place before
the first Step, else the port reopens), `turn_end_hooks` returning its
notice, `background.snapshot_json`/`waiting_json` for `/tasks` and the
waiting line.

**Unit tests.** 31 TUI std.spec suites (`tools/tui_tests.sh`, also in
`.tests.ae`): every upstream inline test of `src/tui*` and
`src/auth/models.zig` is ported under its name, except those listed in a
suite's header (allocation-failure and thread-ownership tests; the Codex
sign-in reply of provider_flow; `tui.zig`'s two queue-shutdown leak tests,
covered by "closed queues refuse events"). `tui_view_test.ae` compares
against upstream's `src/tui/layout_snapshots.txt` and
`simple_snapshots.txt`, whole text, headers included: **both match cell
for cell**. `tui_app_test.ae` adds in-process flow specs: streaming states,
a Run block opened by a click, interjection, Esc cancel, the `/` menu,
undo, Simple mode, mouse selection and copy, resize, and the app's first
frame against the upstream "normal" snapshot. Every module was
mutation-checked (`tools/mutate.py` for the app).

**Upstream e2e, unchanged (`ae/tests/upstream-e2e.sh`).**

| Test | macOS | ae-x64 | cachyos |
|---|---|---|---|
| test_tui_stream.py, test_tui_mouse.py, test_model.py, test_undo.py, test_interjections.py, test_at_files.py, test_prediction.py | pass | pass | pass |
| test_hooks.py, test_skills.py, test_skill_mentions.py (TUI parts included) | pass | pass except `test_sandbox_denies_external_write` (kernel 5.15: no Landlock ABI 2) | pass |
| TUI cases of test_background_agent/bash/run (escape, interjection, `/tasks`, `/stop`, step-limit result in the next TUI Turn) | their `/proc` helper needs Linux | pass | pass |
| test_images.py | whole file (its four `test_tui_*` functions since the 2026-11-13 parity follow-up) | | |
| test_replay.py | pass (20 of 20) | | |
| test_codex_websocket.py, test_provider_login.py | excluded: Codex by policy | | |

**Stand-ins and stubs (marked).** None left in this slice since the
2026-11-13 parity follow-up (images, `/mcp` connection state, tool activity
names, turn_end hooks on their own thread).

**Differences kept.** Terminal input and app events are two queues (term
and `app_queue`); upstream has one libvaxis loop. A stop requested during a
Turn runs at once on a worker (upstream: the Session's next poll). A model
switch before the first Step re-initializes the same log in place, as
upstream; after it the port opens a new Session.

**Asks.** `asks/aether-push-call-result-string.md` (`xs.push(f())` loses
the struct's strings), `asks/aether-qualified-slice-local.md` (`m.P[] xs =
[]` does not parse), `asks/aether-ptr-passed-as-string.md` (a `ptr` is
accepted for a `string` parameter), plus ae/term's.

## Run recording and offline replay slice (2026-11-12)

`nib.sandbox.record` (record.zig), `nib.sandbox.replay` (sandbox/replay.zig),
the virtual prelude and Host.record/Host.virtual hooks in `nib.sandbox`, the
Session's recorder (`<id>.calls.jsonl` beside the log; `NIB_RECORD=off`
disables it; each RunJob forks it), and `nib replay` (`nib.run_replay`,
src/replay.zig) with main.zig's three replay error texts.

**Tests.** Every inline test of record.zig, sandbox/replay.zig and replay.zig,
the record/replay tests of sandbox.zig and timer_test.zig's replay test, under
their upstream names (record_test, replay_test, run_replay_test,
sandbox_test, timer_test). Not portable: the FailingAllocator halves of two
record.zig tests (Aether has no allocation failure to inject); "eval end
counts creations..." fails its finish on IO instead. Each new module was
mutation-checked.

**Upstream e2e, unchanged.** test_replay.py: 20 of 20 on macOS. The replay
steps elsewhere pass on macOS: test_background_run
`test_overlap_keeps_await_console_changes_and_replay`, test_limits
`test_configured_run_output_budget`, test_web_search `test_deepseek`,
test_mcp `test_stdio_modern_and_legacy` and `test_subagent`.

**Stand-in.** nib.qjsgap gains a stop cell its interrupt honours (replay's
divergence stops a running script without it reading as canceled); written
into asks/aether-quickjs-async-eval-and-interrupt.md.

## Headless features slice (2026-11-13)

**What it adds.** Subagents: `tools.agent` (foreground and background, resume
by task id, fork with the Step's history and file versions, limits and the
concurrency gate), `nib ask --agent-input`, the child-Session registry and its
log records. Automatic Run backgrounding (every Run on its own thread; adopted
as rN after `run_background_after_ms` while waiting on tools). Hooks
(`after_edit`, `turn_end`) and skills (index, `$name` expansion). MCP (stdio and
Streamable HTTP, `tools.mcp`, `tools.mcp_schema`). `tools.fetch` (HTML to
Markdown) and `tools.search` (openai, anthropic, deepseek). Images and
`tools.view`. Run recording and `nib replay` (its own section above). Session
headers record `nib_version` as build.zig.zon's version plus the commit
(.build.ae writes it; `nib --version` keeps `0.13.0-ae`). Upstream's
`[providers.<id>] max_output` (8537d53) is ported; `main` was fast-forwarded to
upstream 8537d53 (two Config commits: dd82e39, 8537d53).

**Unit tests.** Every inline test of the ported files is in a std.spec suite
under its upstream name (agent, agent_input, agent_sessions, fork_history,
process stdin/line observer, hooks, skills, html, web, web_search, mcp, image,
view, record, replay, run_replay), each mutation-checked; `aeb .tests.ae` and
`tools/check_layers.sh` are green on macOS arm64, ae-x64 and cachyos (Aether
0.912.0; the code still builds as 0.909-compatible).

**Upstream e2e (`ae/tests/upstream-e2e.sh`, tests unchanged; exclusions and
their reasons are in the script).**

| Test | macOS arm64 | ae-x64 (Ubuntu 22.04, kernel 5.15) | cachyos |
|---|---|---|---|
| test_cli, test_providers, test_files, test_stream_idle, test_llm, test_limits, test_agent_fork, test_replay, test_web_search, test_stats, test_skills, test_skill_mentions, test_hooks* | pass | pass (*test_hooks: all but `test_sandbox_denies_external_write`, no Landlock ABI 2) | pass |
| test_session | stops at a `/proc` read (Linux-only helper); every section before it passes | pass | pass |
| test_sandbox | pass | workspace cases fail: no Landlock ABI 2 (bash runs unsandboxed, as upstream's) | pass |
| test_agent, test_agent_reuse, test_background_agent, test_background_run | the cases whose mock worker walks `/proc` fail | pass | pass |
| test_background_bash | `/proc` cases fail | all but 3 TUI-driven cases (below) | same 3 |
| test_mcp (unittest classes) | pass | all but `test_stdio_sandbox` (SandboxUnavailable: no Landlock ABI 2, as upstream) | pass |
| test_images (unittest classes) | pass | pass | pass |
| test_effort | its chat_completions half passes; the second half is Codex | same | same |
| test_codex, test_codex_websocket, test_provider_login | excluded: policy (Codex) | | |

test_mcp's `/mcp` terminal function and test_images' clipboard and paste
functions were left out of this run; both run since the parity follow-up below. (The three TUI `/js`
cases of test_background_bash pass since the follow-up below.)

**Stand-ins added (marked, each with an ask).** A child
nib's or MCP server's stderr is discarded and its cwd set through `sh -c`
(asks/aether-run-stdio-stderr.md); the QuickJS stand-in's stop cell for replay
(asks/aether-quickjs-async-eval-and-interrupt.md).

**Differences kept on purpose or by gap.** Chat Completions HTTP errors other
than 401 now carry the body, Responses ones say "Codex request failed (HTTP n)",
as upstream (the earlier slice never echoed bodies). MCP stdio servers are
killed by pid (os.run_stdio makes no process group). No environment proxy for
fetch, search or MCP HTTP. No response decompression in fetch (no
accept-encoding is sent).

## Follow-up: /js as a Run, check_layers on every module, Aether 0.912.0 (2026-11-13)

**`/js` is a Run.** As upstream (`session.run`, session/run.zig run +
runTimed), the TUI's `/js` goes through `nib.session.run`: the Run takes the
Session's next Run id, tools.llm usage joins the Session's, after-edit hooks
run, and an empty record commits the task id counters (`task_ids`), so a
resumed Session numbers its tasks after it. The TUI numbers the next Turn's
Runs after the `/js` Run, so later background progress attaches to its Run,
and `nib.tui.live`'s idle tick now drains the due progress snapshots
(upstream's `.tick` with no Turn). `tui_app_test.ae` has a spec for both.

**`tools/check_layers.sh`** pins the imports of every module (ae/main.ae and
every ae/nib module; an unpinned one fails). Who may start a program is the
compiler's rule since Aether 0.911.0 (`import ns hiding (...)`, aether
#3653): every std.os import outside tools/process and tools/jail hides
std.os's program starters (E0304 on use), and the script checks those lists.
The TUI's exceptions are named and narrow: tui/open keeps
`spawn_proc_to` alone (a detached `open` for a clicked path, outside any
Run); auth/models may only GET (the
`/model` listing), imported only by the app and its provider flow.

**Aether 0.912.0** (`pins`). aether #3655 (0.910.0) fixed both ae/term asks
(RESOLVED): ae/term's surface loops store one hoisted blank again; `poll ->
Event` with `NoEvent` and `read_cell -> (Cell, bool)` stay as the API, by
choice. Still worked around, not fixed in 0.912.0: `xs.push(f())` losing a
struct's strings, the module-basename collision, `m.P[] xs = []`, a `ptr`
passed as `string`, ipc.write_some's SIGPIPE, run_stdio's stderr and cwd.

**Upstream e2e (`ae/tests/upstream-e2e.sh`), files passing:**

| Host | Before | Now | Still failing |
|---|---|---|---|
| macOS arm64 | 21/30 | 23/30 | test_effort (Codex half); test_session, test_agent, test_agent_reuse, test_background_agent/bash/run: their mock workers read `/proc` |
| ae-x64 (Ubuntu 22.04, kernel 5.15) | 24/30 | 26/30 | test_effort (Codex half); test_sandbox, test_hooks `test_sandbox_denies_external_write`, test_mcp `test_stdio_sandbox`: no Landlock ABI 2 |
| cachyos | 26/30 | 29/30 | test_effort (Codex half) |

test_background_bash passes whole on both Linux hosts (its three TUI `/js`
and detached-idle cases included); on macOS no case that passed before
fails now. `aeb .tests.ae` is green on all three, `tools/tui_tests.sh` and
`ae/term/run-tests.sh` on macOS.

## Follow-up: parity gaps closed (2026-11-13)

Upstream had nothing new to port (its only commit since, a6917c6, is ADR 0026
and CONTEXT.md); `main` is fast-forwarded to it. Five marked stand-ins and
partial features of the port are gone, one commit each:

- **TUI images.** Ctrl+V and an empty or whitespace paste read the clipboard
  image through tui/clipboard (now checked with nib.image's probe and
  MAX_BYTES); a pasted path naming an image file (nib.image.pasted_path,
  read_pasted: stat before read) is stored under the Session's images
  directory; the editor holds nib.image Images; Enter sends them with the
  Turn (session.turn_with_images, the port's start_turn). The app owns its
  Clipboard instance, whose reader specs replace (upstream's test override).
  config.env.pairs gives children their environment; the `open` launcher
  had been handed the Env struct where a NAME=value list was expected.
  Unlocks test_images.py's four `test_tui_*` functions.
- **`/mcp` connection state.** nib.mcp.server_state, the port's mcp_state;
  `/mcp` shows " · failed: <error>" or " · <n> tools". `/new` reads [mcp]
  again (as [skills]); a failed reopen keeps the current config. Unlocks
  test_mcp.py's `tui_toggle`.
- **Tool activity names.** Each RunScope counts its calls in flight per
  tool; the Run's waiting loop reports a changed active tool, and the
  Running line names it. No upstream e2e covers it; ae/tests/tui_e2e.py
  (ours, upstream's PTY fixture used as a library) checks "Running llm".
- **Bash replacements on restored messages.** Replay restores background
  ids (run_results) and superseded bash rows (bash_replacements) onto the
  tool messages, as upstream restoreToolSummaries; both upstream tests are
  ported. No upstream e2e covers it.
- **turn_end hooks on their own thread.** The Session holds its hook jobs
  (an instance list, upstream TurnJob); close waits for them (finishHooks),
  so quitting the TUI waits for a running hook. `session.turn_end_hooks`
  is gone. ae/tests/tui_e2e.py checks the join.

`upstream-e2e.sh` runs test_images.py and test_mcp.py whole (the
`tui_only_functions_left_out` exclusion is gone); `.tests.ae` runs
ae/tests/tui_e2e.sh. Every new function was mutation-checked.

**Upstream e2e, files passing:**

| Host | Before | Now | Still failing |
|---|---|---|---|
| macOS arm64 | 23/30 | 23/30 | test_effort (Codex half); test_session, test_agent, test_agent_reuse, test_background_agent/bash/run: their mock workers read `/proc` |
| ae-x64 (Ubuntu 22.04, kernel 5.15) | 26/30 | 26/30 | test_effort (Codex half); test_sandbox, test_hooks `test_sandbox_denies_external_write`, test_mcp `test_stdio_sandbox`: no Landlock ABI 2 |
| cachyos | 29/30 | 29/30 | test_effort (Codex half) |

Counted as passing on rerun; the file counts stay. test_images and test_mcp now
pass whole (on ae-x64 test_mcp stops at `test_stdio_sandbox` before its
terminal function, as before). Timing-sensitive cases seen failing once and
then passing on reruns, on the old binary as on the new: on macOS
`test_two_steps_and_next_boundary`, `test_cross_process_child_log_lock_fails_then_releases`,
`test_interjections_and_background_results_keep_fifo`; on ae-x64
`test_step_limit_does_not_wait_for_detached_jobs` (5/5 on rerun).
`aeb .tests.ae`, `tools/tui_tests.sh` and `tools/check_layers.sh` are green
on all three hosts.

## Aether 0.914.0: workarounds removed (2026-11-14)

aether #3694 (0.914.0) fixed six of this port's asks; their stand-ins are
gone. `xs.push(f())` keeps the struct's strings (agent_tree pushes the row
directly); `commands.Choice[] x = []` parses, so `commands.no_choices()` is
deleted; `nib.provider.timing` has its upstream name again (the qualified-type
basename collision with `nib.sandbox.timing` is fixed); std.ipc never raises
SIGPIPE, so `sysgap.ignore_sigpipe` is deleted; `os.run_stdio` takes
`stderr_to:` and `cwd:`, so tools.process starts the program directly instead
of through `sh -c`; `ae run` exits non-zero when a spec fails, so
`tools/tui_tests.sh` reads the exit code alone. A `ptr` passed as a `string`
is now a compile error (E0202). Pins: AE_PIN 0.914.0.

Verified on 0.914.0: `aeb .tests.ae`, `tools/check_layers.sh`,
`tools/tui_tests.sh` green on macOS arm64, ae-x64 and cachyos; upstream e2e
cachyos 29/30 and ae-x64 29/30 (left: the Codex half of `test_effort`, by
policy). ae-x64 now runs Ubuntu's HWE kernel 6.8 (was 5.15), so Landlock ABI
2+ holds there and its sandbox cases pass. macOS unchanged at 23/30.

## Aether 0.915.0: nib.sysgap deleted (2026-11-14)

The two remaining stand-in asks are answered in 0.915.0 and `ae/nib/sysgap/`
(a C file and its Aether wrapper) is gone. std.fs gives `stat` (a `Stat` value
with inode, mode and nanosecond mtime), `lock_open`/`try_lock`, `create_exclusive`,
`fchmod`, `fd_fsync`, `fd_truncate`, `fd_size`, `fd_pwrite_all`, `move` (replaces
an existing target; the atomic-replace step) and `chmod`/`unlink`/
`create_dir_with_mode`; std.io gives `fd_close`/`fd_write` and `set_echo`;
std.os gives `environ` and `signal_watch`/`signal_received`/`signal_unwatch`.
Two small modules replace the rest: `nib.fserr` (`errname(kind)`: a std.fs
`KIND_*` to upstream's Zig error name, read with the errno behind a `KIND_IO`
for ReadOnlyFileSystem, DeviceBusy and FileTooBig) and `nib.sysenv` (the
environment as a `std.list`). `nib ask` owns its signal watch: the Turn's
poller thread holds the handle it was given and the watch lasts the process.
Masked key entry is `io.set_echo`, restoring what it found.

Not reproduced exactly: `fs.unlink` and `fs.create_dir_with_mode` report no
errno, so `/undo`'s "failed: path: <name>" after a failed unlink derives the
name from an lstat of the path (FileNotFound, NotDir, IsDir, else AccessDenied),
and the image store tells a missing parent from an existing directory by a stat
after the failed mkdir. The errno numbers behind KIND_IO are the POSIX ones
(Linux, macOS); Windows reports GetLastError codes there.

New check: `ae/tests/tui_e2e.py` `login_masks_key` runs `nib login anthropic`
on a pseudo-terminal and checks echo is off while the key is read, back on
afterwards, and the key never reaches the screen. SIGINT/SIGTERM during
`nib ask` are covered by upstream's `test_session.py` (the interrupted Turn
test) and `test_agent.py` (`check_cancel`). Pins: AE_PIN 0.915.0.
