<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="nib" width="96">
  </picture>
</p>

<h1 align="center">nib</h1>

<p align="center">English | <a href="README.zh-CN.md">中文</a></p>

nib is a coding agent written in Zig that works in Runs: one JavaScript script can read, edit and check a project.

## Install and sign in


Requires Zig 0.17.

```sh
git clone https://github.com/yyydddkkk/nib-code.git
cd nib-code
zig build -Doptimize=ReleaseFast --prefix ~/.local   # installs ~/.local/bin/nib
nib --version
```



**Codex (default).** Sign in to ChatGPT with the `codex` CLI first. nib reads `~/.codex/auth.json`, so no API key is needed. The default model is `gpt-6.1-sol`. See [docs/codex.md](docs/codex.md).

**DeepSeek (Chat Completions):**

```sh
NIB_PROVIDER=chat_completions DEEPSEEK_API_KEY=... nib
```

Provider, model and effort can also be set in `~/.nib/config.toml`. See [docs/config.md](docs/config.md).

## Your first request

Run it from your project directory:

```sh
nib
# Type: Explain the entry points in this project. Leave files unchanged.
```

Or ask once from the command line:

```sh
nib ask 'Explain the structure of this project'
nib --help
```

Enter sends, Shift+Enter adds a line, and Esc cancels. Send another instruction while work is running; messages awaiting delivery are marked queued and return to the input after cancellation. Model replies follow your language; fixed interface text is English.

Put global instructions in `~/.nib/AGENTS.md` and project conventions in the root `AGENTS.md`.

## Reading a Run

Each block represents one script execution. The title comes from actual tool calls, followed by changed files and line counts, read/search paths, and command results.

```text
  Run · edit 2 files · bash
    src/grep.zig +38 −9 · src/tools.zig +2 −1
    read src/grep.zig · read src/tools.zig · grep src
    └─ b1 bash zig build test · 1s · completed ✓ exit 0

  1 Run · 2 steps · 41s · 6.6k tokens · tool data 3.2MB → 18kB
```

`✓ exit 0` confirms the command beside it. A failed or timed out child is called out in the Run title; a script returning successfully does not certify every check inside it. A background Run shows `Run · r3 running` and updates the original block when its result arrives. A superseded command was replaced; that says nothing about whether a check passed.

Ctrl+O expands Changes / Result / Script, in that order. Scroll through the result; long diffs are labeled `Diff preview · 60 of … lines`. Turn totals appear once in a quiet footer. The bottom bar keeps the model and context percentage; `/status` has timing and cache details. Retrying removes the failed attempt's draft; Ctrl+O opens Details after a final error.

## Advanced capabilities

- **Code as the interface.** The model has one `run` entry point. Sandbox functions `read`, `edit`, `write`, `grep`, `glob`, `fetch` and `bash` can run concurrently and filter results in JS. Tools return their full data to JS; see the [Run output budget](docs/run-output.md).
- **Pure model calls.** `tools.llm` makes one call without tools or session history, suitable for concurrent classification, extraction and batch judgments.
- **Subagents.** `tools.agent` handles independent multistep work, returns failures as data, and lists changes. Use `resume: "a1"` to continue a task or `fork: true` to branch from the current context.
- **Background tasks.** agent/bash accept `background: true`; long Runs can also move to the background automatically. Results arrive automatically. Long-lived processes can use `detached: true`. `/tasks` lists ids, states and deadlines; `/stop <id>` stops a task and may leave partial changes. See [TUI task controls](docs/tui-ux.md).
- **Undo.** `/undo` restores the latest edited Turn’s edit/write changes, including subagents, and deletes created files. External changes refuse the whole undo. History lasts for this TUI session instance (up to 8 edited Turns); bash/script changes are outside its scope. Snapshot limits or failures leave editing available but make that Turn non-undoable. See [undo details and limits](docs/undo.md).
- **Reasoning effort.** `/effort` sets the ceiling. The model can lower its next Step's effort; failed Runs and interjections restore it.
- **Logs and replay.** Session logs record usage and timing, `scripts/stats.py` summarizes them, and `nib replay` replays recorded tools offline. See [replay](docs/replay.md).
- **Reflection.** `/reflect` reviews the harness and publishes issue drafts to the public repository `yyydddkkk/nib-code` by default. Set `NIB_ISSUE_REPO` to another repository or `off` to save reflections locally. Help and the menu show the current setting. See [reflection](docs/reflect.md).

```sh
nib -c                          # continue this directory's latest session
nib --resume <32-character-id>   # resume a specific session
nib --effort high               # effort for this process
nib ask --json '...'            # NDJSON event stream
nib replay <session-id> --all    # offline replay
```

Type `/` for commands grouped into Send / View / Session, and `/help` for all keys. User messages have a blue accent bar and a subtle background adapted to the terminal theme. Drag to select text and release to copy it; hold the mouse button and scroll to select across screens.

Version 0.5.0. This is a personal project and still changes quickly.

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
