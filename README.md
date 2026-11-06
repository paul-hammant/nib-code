# nib

English | [中文](README.zh-CN.md)

A coding agent written in Zig. Instead of calling tools one at a time, the model writes a JavaScript program. The program runs in an embedded QuickJS sandbox and can read files, search, edit and run tests in a single step. Only the results the model needs come back into the conversation.

```js
// One Run: read files concurrently, edit, then build and test; return only failures
const [a, b] = await Promise.all([tools.read({ path: "src/a.zig" }), tools.read({ path: "src/b.zig" })]);
await tools.edit({ path: "src/a.zig", old_text: "...", new_text: "..." });
const r = await tools.bash({ command: "zig build test" });
r.exit_code === 0 ? "ok" : r.output
```

Version 0.4.0. This is a personal project and still changes quickly.

## Features

- **Code as the interface.** The model has a single `run` tool. Each capability is a JS function in the sandbox: `read`, `edit`, `write`, `grep`, `glob`, `fetch`, `bash`. One Run can call many tools concurrently and filter their results in JS, so the model needs fewer round trips.
- **`tools.llm`.** Makes one clean model call with no tools and no conversation history. You can call it concurrently from JS, which suits batch judging, classification and extraction.
- **`tools.agent`.** Starts an independent sub-agent for multi-step work.
  - A failure comes back as data and does not affect other sub-agents in the same Run.
  - The result lists the files the sub-agent changed.
  - Pass `resume: "a1"` to continue an earlier sub-agent with its history intact.
- **Background tasks.** `agent` and `bash` accept `background: true`. The call returns a task id right away and the main model keeps working. The result arrives as a message in a later Step. Long-lived processes such as dev servers can use `detached: true`. Use `tools.stop({ id, reason })` with a nonblank reason to stop a task.
- **Per-Step reasoning effort.** The model can ask for lower effort on its next Step. Your setting is the upper bound. Effort is restored automatically after a failed Run or when you interject.
- **TUI.**
  - Interject while a turn is running.
  - `/undo` restores the latest turn's `edit`/`write` changes, including sub-agents, and deletes files it created. Conflicts refuse the entire undo. Available only in the current TUI session instance; bash/script changes are outside its scope. See [undo details and limits](docs/undo.md).
  - Sub-agents and background tasks appear as a status tree under their Run.
  - Each turn ends with a bill: model and tool time, tool bytes versus the bytes that reached the context, tokens, and cache hits.
  - Select text with the mouse to copy it.
- **Measurable and replayable.**
  - Session logs record the time, usage and tool data volume of every Step.
  - `scripts/stats.py` summarizes failures, where the time went, and round-trip structure.
  - Tool call arguments and results are recorded locally by default. `nib replay` re-runs any Run offline (see [docs/replay.md](docs/replay.md)).
  - `/reflect` has the model review the session log for problems in the harness itself and files issues automatically.

## Install

Requires Zig 0.17.

```sh
git clone https://github.com/yyydddkkk/nib-code.git
cd nib-code
zig build -Doptimize=ReleaseFast --prefix ~/.local   # installs ~/.local/bin/nib
nib --version
```

## Models

**Codex (default).** Sign in to ChatGPT with the `codex` CLI first. nib reads `~/.codex/auth.json`, so no API key is needed. The default model is `gpt-6.1-sol`. See [docs/codex.md](docs/codex.md).

**DeepSeek (Chat Completions):**

```sh
NIB_PROVIDER=chat_completions DEEPSEEK_API_KEY=... nib
```

Provider, model and effort can also be set in `~/.nib/config.toml`. See [docs/config.md](docs/config.md).

## Usage

```sh
nib                          # open the TUI
nib ask 'Explain the structure of this project'
nib ask --json '...'         # NDJSON event stream for scripts and other programs
nib -c                       # continue the latest session in this directory
nib --effort high            # reasoning effort for this process
nib replay <session-id> --all  # replay a session's recorded Runs offline and check they match
```

In the TUI, type `/` to list commands: `/new`, `/resume`, `/compact`, `/undo`, `/effort`, `/copy`, `/reflect`, `/js`, `/help`. Esc interrupts the current turn. ctrl+o expands a Run's script, output and diff.

Repeat `/undo` to undo earlier edited turns (up to 8 retained). It checks file hashes before restoring anything and tells the model to re-read restored files. Snapshots live under `NIB_HOME/sessions/<id>.undo/`: 16 MiB per file, 256 paths and 64 MiB of original contents per turn; writes that exceed undo limits are refused before changing a file. Exiting or switching sessions clears undo history; resumed sessions can undo only new turns.

Put global instructions in `~/.nib/AGENTS.md` and project conventions in `AGENTS.md` at the project root.

## Safety

Tool results are recorded by default in `~/.nib/sessions/<id>.calls.jsonl`. The file has mode 0600 and stays on your machine. It may contain data the model read but never sent back, such as `.env` files. To turn recording off, set `NIB_RECORD=off`.

bash has a check against mistakes. It refuses commands that escalate privileges, shut down the machine or delete system directories, and it won't read Codex credentials. It is a guard rail, not a security sandbox: **nib runs model-generated code with your user permissions.** Before you use nib on an important repository, commit or back up your working tree.

## Docs

The detailed docs are currently written in Chinese.

- [docs/README.md](docs/README.md): design principles, index of decision records (ADRs), and deferred ideas
- [docs/compromises.md](docs/compromises.md): compromises made for today's models and when to remove them
- [docs/releases/](docs/releases/): release notes
- [AGENTS.md](AGENTS.md): build and test commands and a code map for agents working on nib

## License

[MIT](LICENSE)
