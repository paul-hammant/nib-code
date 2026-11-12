# The Aether port of nib

This branch (`aether-port`) ports [yyydddkkk/nib-code](https://github.com/yyydddkkk/nib-code)
(Zig, MIT, © jackyyy) to [Aether](https://github.com/aether-lang-dev/aether).
It tracks upstream: `main` in this repository is a mirror of `upstream/main`
and is never committed to; the port follows it.

Ported through upstream commit: **a2dd439** (Release 0.13.0) for the files listed with it below.

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
| `src/sandbox/scheduler.zig` | 296 | `ae/nib/sandbox/module.ae` | a2dd439 | concurrency 8, completion order, timers, drain, stopped calls; no Host.poll/waiting yet (session) |
| `src/sandbox/native.zig` | 163 | `ae/nib/sandbox/module.ae` | a2dd439 | __log/__host as contrib.quickjs host functions with a `hide` veto line; installVirtual not yet |
| `src/sandbox/timer.zig` | 18 | `ae/nib/sandbox/module.ae` | a2dd439 |  |
| `src/sandbox/console.zig` | 181 | `ae/nib/sandbox/console/module.ae` | a2dd439 |  |
| `src/sandbox/timing.zig` | 168 | `ae/nib/sandbox/timing/module.ae` | a2dd439 | Execution epoch times live on process.Result |
| `src/sandbox/timer_test.zig` | 237 | `ae/tests/timer_test.ae` | a2dd439 | less the replay test |
| `src/sandbox/record.zig` | 510 | not yet |  | next: record/replay slice |
| `src/sandbox/replay.zig` | 303 | not yet |  | next: record/replay slice |
| `src/sandbox/virtual.zig` | 19 | not yet |  | next: record/replay slice |
| `src/tools.zig` | 813 | `ae/nib/tools/module.ae` | a2dd439 | table verbatim; only ported tools enter a Run's API; RunScope replaces the threadlocal; documentation() (llm/search options) waits for config/provider |
| `src/tools/files.zig` | 587 | `ae/nib/tools/files/module.ae` | a2dd439 | undo hooks not yet |
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
| `src/tools/process.zig` | 358 | `ae/nib/tools/process/module.ae` | a2dd439 | output to a file, not a pipe; no stdin input, line observer or tick hook yet (agent/progress slices); a signal reads as 128+n |
| `src/tools/bash.zig` | 433 | `ae/nib/tools/bash/module.ae` | a2dd439 | progress events (Tracker) not yet |
| `src/tools/bash/registry.zig` | 146 | `ae/nib/tools/registry/module.ae` | a2dd439 | supersession; start/finish log events not yet (session log) |
| `src/tools/bash/jail.zig` | 304 | `ae/nib/tools/jail/module.ae` | a2dd439 | Landlock in jail/landlock.c (stand-in); probe cached per Tools, not per process |
| `src/tools/background.zig` | 866 | `ae/nib/tools/background/module.ae` | a2dd439 | bash only; messages unformatted (session output.zig); agents and background Runs not yet |
| `src/tools/stop.zig` | 29 | `ae/nib/tools/module.ae` | a2dd439 | userStop (TUI) not yet |
| `src/tools/undo.zig` | 606 | not yet |  | next: needs the TUI Turn lifecycle; file tools have no undo hook yet |
| `src/tools/view.zig` | 92 | not yet |  | needs src/image.zig and the Session image store |
| `src/tools/progress.zig` | 249 | not yet |  | session/TUI slice |
| `src/tools/web.zig` | 161 | not yet |  | fetch: a later slice |
| `src/tools/html.zig` | 504 | not yet |  | with fetch |
| `src/tools/web_search.zig` | 404 | not yet |  | needs providers |
| `src/tools/llm.zig` | 246 | not yet |  | needs providers |
| `src/tools/agent.zig` | 497 | not yet |  | needs the session |
| `src/tools/agent/input.zig` | 90 | not yet |  |  |
| `src/tools/agent/sessions.zig` | 119 | not yet |  |  |
| `src/tools/mcp.zig` | 101 | not yet |  | with src/mcp* |
| `src/session*` | 5,300 | | | |
| `src/provider*` | 3,900 | | | less `codex_ws`, `websocket` |
| `src/config.zig` | 1,700 | | | |
| `src/mcp*` | 700 | | | |
| `src/replay.zig`, `src/image.zig`, `src/main.zig` | 1,200 | | | main: `nib js`, `nib __jail` only |
| `src/tui*` | 12,600 | | | needs the terminal layer (upstream uses libvaxis) |
| `src/auth*` | 1,500 | | | the API-key store only |
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
