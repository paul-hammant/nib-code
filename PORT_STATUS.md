# The Aether port of nib

This branch (`aether-port`) ports [yyydddkkk/nib-code](https://github.com/yyydddkkk/nib-code)
(Zig, MIT, © jackyyy) to [Aether](https://github.com/aether-lang-dev/aether).
It tracks upstream: `main` in this repository is a mirror of `upstream/main`
and is never committed to; the port follows it.

Ported through upstream commit: **none yet** (branch created at `a2dd439`, Release 0.13.0).

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
| `src/sandbox*` | 2,700 | | | on `contrib.quickjs` |
| `src/tools*` | 9,500 | | | tools as vetoed services |
| `src/session*` | 5,300 | | | |
| `src/provider*` | 3,900 | | | less `codex_ws`, `websocket` |
| `src/config.zig` | 1,700 | | | |
| `src/mcp*` | 700 | | | |
| `src/replay.zig`, `src/image.zig`, `src/main.zig` | 1,200 | | | |
| `src/tui*` | 12,600 | | | needs the terminal layer (upstream uses libvaxis) |
| `src/auth*` | 1,500 | | | the API-key store only |
| `src/update*` | 140 | not ported | | |
