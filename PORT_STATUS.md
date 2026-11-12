# The Aether port of nib

This branch (`aether-port`) ports [yyydddkkk/nib-code](https://github.com/yyydddkkk/nib-code)
(Zig, MIT, © jackyyy) to [Aether](https://github.com/aether-lang-dev/aether).
It tracks upstream: `main` in this repository is a mirror of `upstream/main`
and is never committed to; the port follows it.

Ported through upstream commit: **a2dd439** (Release 0.13.0) for the files listed with it below.
`main` was fast-forwarded to upstream **7788541** on 2026-11-12; that delta touches only
`src/tui/view.zig` and docs (TUI slice), so every row here is current with it.

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
| `src/sandbox.zig` | 799 | `ae/nib/sandbox/module.ae` | a2dd439 | eval, Limits, prelude, syntax context; record/replay hooks not yet |
| `src/sandbox/scheduler.zig` | 296 | `ae/nib/sandbox/module.ae` | a2dd439 | concurrency 8, completion order, timers, drain, stopped calls; Host.poll's role is a 20 ms Session ticker (session) |
| `src/sandbox/native.zig` | 163 | `ae/nib/sandbox/module.ae` | a2dd439 | __log/__host as contrib.quickjs host functions with a `hide` veto line; installVirtual not yet |
| `src/sandbox/timer.zig` | 18 | `ae/nib/sandbox/module.ae` | a2dd439 |  |
| `src/sandbox/console.zig` | 181 | `ae/nib/sandbox/console/module.ae` | a2dd439 |  |
| `src/sandbox/timing.zig` | 168 | `ae/nib/sandbox/timing/module.ae` | a2dd439 | Execution epoch times live on process.Result |
| `src/sandbox/timer_test.zig` | 237 | `ae/tests/timer_test.ae` | a2dd439 | less the replay test |
| `src/sandbox/record.zig` | 510 | not yet |  | next: record/replay slice |
| `src/sandbox/replay.zig` | 303 | not yet |  | next: record/replay slice |
| `src/sandbox/virtual.zig` | 19 | not yet |  | next: record/replay slice |
| `src/tools.zig` | 813 | `ae/nib/tools/module.ae` | a2dd439 | table verbatim; only ported tools enter a Run's API; RunScope replaces the threadlocal; docs fill {{llm_limits}}/{{llm_options}}; search options wait for web search |
| `src/tools/files.zig` | 587 | `ae/nib/tools/files/module.ae` | a2dd439 | undo snapshots in edit/write |
| `src/tools/atomic_file.zig` | 243 | `ae/nib/tools/atomic_file/module.ae` | a2dd439 | on nib.sysgap (stand-in) |
| `src/tools/file_state.zig` | 247 | `ae/nib/tools/file_state/module.ae` | a2dd439 | flock path locks on nib.sysgap (stand-in) |
| `src/tools/changes.zig` | 253 | `ae/nib/tools/changes/module.ae` | a2dd439 | Tracker per Run scope; Recovery |
| `src/tools/diff.zig` | 195 | `ae/nib/tools/diff/module.ae` | a2dd439 |  |
| `src/tools/search.zig` | 173 | `ae/nib/tools/search/module.ae` | a2dd439 |  |
| `src/tools/grep.zig` | 509 | `ae/nib/tools/grep/module.ae` | a2dd439 | one scanning thread (upstream 8); JS RegExp in a private QuickJS runtime; a running regex is bounded at 10 s, not interruptible by cancel |
| `src/tools/regex.zig` | 106 | `ae/nib/tools/grep/module.ae` | a2dd439 | libregexp via JS RegExp |
| `src/tools/walk.zig` | 385 | `ae/nib/tools/walk/module.ae` | a2dd439 |  |
| `src/tools/policy.zig` | 698 | `ae/nib/tools/policy/module.ae` | a2dd439 | rule for rule, same texts |
| `src/tools/secrets.zig` | 16 | `ae/nib/tools/secrets/module.ae` | a2dd439 |  |
| `src/tools/process.zig` | 358 | `ae/nib/tools/process/module.ae` | a2dd439 | output to a file, not a pipe; a 20 ms tick with the output byte count (progress); no stdin input or line observer yet (agent slice); a signal reads as 128+n |
| `src/tools/bash.zig` | 433 | `ae/nib/tools/bash/module.ae` | a2dd439 | progress Tracker; ids reserved at start, snapshot after 3 s |
| `src/tools/bash/registry.zig` | 146 | `ae/nib/tools/registry/module.ae` | a2dd439 | supersession; started/superseded/finished log records |
| `src/tools/bash/jail.zig` | 304 | `ae/nib/tools/jail/module.ae` | a2dd439 | Landlock in jail/landlock.c (stand-in); probe cached per Tools, not per process |
| `src/tools/background.zig` | 866 | `ae/nib/tools/background/module.ae` | a2dd439 | bash only: typed inbox, started record, lost on resume, detached across Turns; agents and background Runs not yet |
| `src/tools/stop.zig` | 29 | `ae/nib/tools/module.ae`, `ae/nib/tui/live/module.ae` | a2dd439 | userStop is the TUI port's `user_stop_`; a stop requested during a Turn runs on a worker, not in Tools.poll |
| `src/tools/undo.zig` | 606 | `ae/nib/tools/undo/module.ae` | a2dd439 | Session wires begin/finish/undo; off for `nib ask` as upstream; /undo itself is the TUI's |
| `src/tools/view.zig` | 92 | not yet |  | needs src/image.zig and the Session image store |
| `src/tools/progress.zig` | 249 | `ae/nib/tools/progress/module.ae` | a2dd439 | agent kinds wait for tools.agent |
| `src/tools/web.zig` | 161 | not yet |  | fetch: a later slice |
| `src/tools/html.zig` | 504 | not yet |  | with fetch |
| `src/tools/web_search.zig` | 404 | not yet |  | needs providers |
| `src/tools/llm.zig` | 246 | `ae/nib/tools/llm_call/module.ae` | a2dd439 | the gate is per Tools (subagents will share it) |
| `src/tools/agent.zig` | 497 | not yet |  | needs the session |
| `src/tools/agent/input.zig` | 90 | not yet |  |  |
| `src/tools/agent/sessions.zig` | 119 | not yet |  |  |
| `src/tools/mcp.zig` | 101 | not yet |  | with src/mcp* |
| `src/session.zig` | 999 | `ae/nib/session/module.ae` | a2dd439 | Turn/Step loop, resume/continue, interrupted commits, auto compaction, Step-limit wait, undo wiring; no fork, reopen/switchConfig (TUI), skills, MCP, images |
| `src/session/run.zig` | 236 | `ae/nib/session/module.ae` | a2dd439 | execute; no automatic Run backgrounding |
| `src/session/run_job.zig` | 116 | not yet |  | automatic Run backgrounding (rN): next |
| `src/session/log.zig` | 1402 | `ae/nib/session/log/module.ae` | a2dd439 | records are JSON text; tool summaries/bash replacements not restored onto replayed messages (the TUI needs them) |
| `src/session/output.zig` | 596 | `ae/nib/session/output/module.ae` | a2dd439 |  |
| `src/session/prompt.zig` | 322 | `ae/nib/session/prompt/module.ae` | a2dd439 |  |
| `src/session/profile.zig` | 58 | `ae/nib/session/profile/module.ae` | a2dd439 |  |
| `src/session/instructions.zig` | 49 | `ae/nib/session/instructions/module.ae` | a2dd439 |  |
| `src/session/compact.zig` | 175 | `ae/nib/session/compact/module.ae` | a2dd439 | no image placeholders |
| `src/session/tool_summary.zig` | 249 | `ae/nib/session/tool_summary/module.ae` | a2dd439 | no annotateViews (images) |
| `src/session/events.zig` | 182 | `ae/nib/session/module.ae` | a2dd439 | events are the NDJSON text they print as |
| `src/session/inbox.zig` | 278 | `ae/nib/tools/background/module.ae` | a2dd439 | bash results, FIFO, detached kept; user interjections (`enqueue_user`/`take_users`, kind "user") inserted before the next Step |
| `src/session/history.zig` | 130 | not yet |  | fork (subagents): next |
| `src/session/hooks.zig`, `skills.zig` | 538 | not yet |  | next slice |
| `src/provider.zig` | 395 | `ae/nib/provider/types/module.ae`, `ae/nib/provider/module.ae` | a2dd439 | less Codex |
| `src/provider/retry.zig` | 331 | `ae/nib/provider/module.ae` | a2dd439 | no Codex Retry-After or stale-socket paths |
| `src/provider/anthropic.zig` | 444 | `ae/nib/provider/anthropic/module.ae` | a2dd439 | no images |
| `src/provider/responses.zig` | 1033 | `ae/nib/provider/responses/module.ae` | a2dd439 | SSE only; no Codex auth/WebSocket, images or web search |
| `src/provider/openai.zig` | 428 | `ae/nib/provider/openai/module.ae` | a2dd439 | no images; HTTP errors never echo the body |
| `src/provider/sse.zig` | 52 | `ae/nib/provider/sse/module.ae` | a2dd439 | plus fixed/live line sources |
| `src/provider/timing.zig` | 319 | `ae/nib/provider/model_timing/module.ae` | a2dd439 | renamed: asks/aether-module-basename-collision.md |
| `src/provider/body.zig`, `cancel.zig`, `idle.zig` | 393 | `ae/nib/provider/http/module.ae` | a2dd439 | a request thread plus a polling reader on std.http.client |
| `src/provider/codex_ws.zig`, `websocket.zig` | 523 | not ported |  | policy: API keys only |
| `src/config.zig` | 1680 | `ae/nib/config/module.ae`, `ae/nib/config/env/module.ae` | a2dd439 | no Codex provider ([codex] validated and ignored); default service anthropic |
| `src/mcp*` | 700 | | | |
| `src/main.zig` | 311 | `ae/main.ae` | a2dd439 | ask, js, login/logout, help, version, __jail; bare `nib` opens the TUI (`run_tui_`); no replay, update |
| `src/replay.zig`, `src/image.zig` | 900 | not yet | | |
| `src/tui.zig` | 1911 | `ae/nib/tui/module.ae` | 7788541 | the App; takes term, Session port and clock; app events through `nib.tui.app_queue`; the Ticker is the poll timeout; images are a marked stand-in |
| `src/tui/view.zig` | 744 | `ae/nib/tui/tui_view/module.ae` | 7788541 | renamed (basename `view`); both snapshot files match cell for cell |
| `src/tui/transcript.zig`, `transcript/entry.zig`, `transcript/changes.zig`, `transcript/intraline.zig`, `transcript/label.zig` | 2634 | `ae/nib/tui/transcript`, `entry`, `turn_changes` (renamed), `intraline`, `label` | 7788541 | replayed tool summaries are read from the messages' `tool_summary` members |
| `src/tui/editor.zig` | 657 | `ae/nib/tui/editor/module.ae` | 7788541 | image blocks over an editor-local Image (stand-in for nib.image) |
| `src/tui/markdown.zig`, `syntax.zig` | 1472 | `ae/nib/tui/markdown`, `syntax` | 7788541 | |
| `src/tui/viewport.zig`, `selection.zig`, `selection/history.zig` | 595 | `ae/nib/tui/viewport`, `selection`, `sel_history` (renamed) | 7788541 | the local clipboard tool is a closure the app supplies |
| `src/tui/status.zig`, `bill.zig`, `title.zig`, `format.zig`, `frames.zig`, `smooth.zig`, `long_text.zig`, `mode.zig` | 1076 | `ae/nib/tui/<same>`, `turn_summary` | 7788541 | times are ms from the app's clock |
| `src/tui/commands.zig`, `menu.zig`, `providers.zig` | 1133 | `ae/nib/tui/commands`, `menu`, `module.ae` | 7788541 | execute/select/providers live in the app; `/provider` is key entry only |
| `src/tui/provider_flow.zig` | 658 | `ae/nib/tui/provider_flow/module.ae` | 7788541 | API keys only: the Codex sign-in steps are not ported |
| `src/tui/prediction.zig`, `reflect.zig` | 798 | `ae/nib/tui/prediction`, `reflect` | 7788541 | the model call and gh are closures (specs replace them) |
| `src/tui/paths.zig`, `open.zig`, `clipboard.zig`, `agent_tree.zig`, `tasks.zig`, `turn.zig` | 1306 | `ae/nib/tui/<same>` | 7788541 | turn.zig's thread is the port's (`nib.tui.live`); clipboard's image check is a stand-in for nib.image |
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
and helper exec) starts a program, only the sandbox and grep's private
matcher embed QuickJS, nothing in this slice imports a network module. The
sandbox's two host functions open with a `hide os, worker, ...` veto line.

**Stand-ins (marked, each with an ask):** `ae/nib/qjsgap` (async eval,
interrupt, promise state: asks/aether-quickjs-async-eval-and-interrupt.md),
`ae/nib/sysgap` (stat, flock, O_EXCL, environ: asks/aether-fs-stat-flock-exclusive.md),
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
header (Codex, images, MCP, allocation failures, the Zig Record type). Each
module was mutation-checked.

**Upstream e2e (`ae/tests/upstream-e2e.sh`, tests unchanged).**

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
| test_images.py | not yet | images and tools.view (not TUI-driven) |
| test_mcp.py, test_replay.py, test_web_search.py, test_stats.py | not yet | their slices (agents, Run backgrounding, TUI, hooks/skills, MCP, replay, web search) |
| test_codex.py, test_codex_websocket.py, test_provider_login.py | excluded | policy: no Codex sign-in or WebSocket |

**Lanes.** macOS arm64, ae-x64 (Ubuntu 22.04) and cachyos: unit suites green on all
three; e2e results as in the table on all three, except that on ae-x64 (kernel 5.15,
no Landlock ABI 2) test_sandbox's six workspace cases fail because bash runs
unsandboxed there, as upstream's would. On Linux test_background_bash runs
unpatched: every non-TUI Chat case passes except the four that need tools.agent.

**Stand-ins (marked, each with an ask).** `ae/nib/sysgap` grows pwrite
(asks/aether-fs-stat-flock-exclusive.md item 6), SIGINT/SIGTERM as a polled
flag and stdin echo (asks/aether-signal-flag-and-tty-echo.md).
`nib.provider.model_timing` is named to dodge
asks/aether-module-basename-collision.md.

**Differences kept on purpose or by gap.** No Codex provider: with nothing
configured the default service is anthropic (upstream: codex), a `[codex]`
section is validated and ignored. HTTP error bodies are never echoed, for
every protocol. The request runs on its own thread and an abandoned one ends
at the server's close or the client's whole-exchange timeout. No `Expect:
100-continue` is ever sent (std.http.client returns an interim 100 as the
final response). Header `nib_version` is `0.13.0-ae`.

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
(run_job), hooks and skills, MCP, tools.fetch/web_search, images and
tools.view, record/replay.

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
| test_images.py | not TUI-driven: images and tools.view are not ported | | |
| test_replay.py, test_codex_websocket.py, test_provider_login.py | excluded: replay not ported; Codex by policy | | |

**Stand-ins and stubs (marked).** Images: Ctrl+V and an empty paste say
"No image in clipboard", pasted image paths are pasted as text, the
editor's Image and clipboard's PNG check stand in for `nib.image`. MCP:
`/mcp` reads no servers. Tool activity names (upstream onToolActivity) are
not emitted; the Running line uses the Run's progress. Hooks run after a
TUI Turn on the Turn's worker, not a thread of their own.

**Differences kept.** Terminal input and app events are two queues (term
and `app_queue`); upstream has one libvaxis loop. A stop requested during a
Turn runs at once on a worker (upstream: the Session's next poll). A model
switch before the first Step re-initializes the same log in place, as
upstream; after it the port opens a new Session.

**Asks.** `asks/aether-push-call-result-string.md` (`xs.push(f())` loses
the struct's strings), `asks/aether-qualified-slice-local.md` (`m.P[] xs =
[]` does not parse), `asks/aether-ptr-passed-as-string.md` (a `ptr` is
accepted for a `string` parameter), plus ae/term's.
