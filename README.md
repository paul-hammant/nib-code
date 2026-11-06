<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="nib" width="96">
  </picture>
</p>

<h1 align="center">nib</h1>

<p align="center">English | <a href="README.zh-CN.md">中文</a></p>

A small, focused, quiet coding agent.

nib works in Runs: the model writes one JavaScript script that reads, edits and checks your project in a single step.

## Numbers

Against Codex CLI on the same model:

**12% faster · 44% cheaper · 32% fewer requests · 20/20 passed**

**Ten agents open:**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/bench-memory-dark.svg">
  <img src="docs/assets/bench-memory-light.svg" alt="Total idle RSS for ten instances: nib 38 MB; pi clean 1,134 MB; Codex CLI 1,164 MB; prime-agent 1,460 MB; Claude Code 1,750 MB; pi with extensions 1,984 MB; dsh 5,459 MB." width="880">
</picture>

5 MB static binary · no runtime dependencies.

*Nov 2026 · gpt-6.1-terra, medium · 20 runs vs Codex CLI 0.166.0 at API prices · memory of idle TUIs.*

[More numbers →](docs/benchmarks.md)

## Install

Linux and macOS, x86_64 and arm64:

```sh
curl -fsSL https://raw.githubusercontent.com/yyydddkkk/nib-code/main/install.sh | sh
```

Installs to `~/.local/bin`. Run it again to upgrade. `NIB_VERSION` pins a release, `NIB_INSTALL_DIR` changes the directory.

From source (Zig 0.17): `zig build -Doptimize=ReleaseFast --prefix ~/.local`

## Use

```sh
cd your-project
nib                          # interactive
nib ask 'explain the entry points'
nib -c                       # continue the last session here
```

Uses your Codex login by default; `/model` switches to Claude, OpenAI, DeepSeek, Grok or [your own endpoint](docs/providers.md).

Enter sends, Shift+Enter adds a line, Esc cancels. Type `/` for commands: `/model`, `/effort`, `/undo`, `/tasks`, `/skills`, `/status`.

Project conventions go in `AGENTS.md`; personal ones in `~/.nib/AGENTS.md`.

## A Run

```text
  Run · edit 2 files · bash
    src/grep.zig +38 −9 · src/tools.zig +2 −1
    read src/grep.zig · read src/tools.zig · grep src
    └─ b1 bash zig build test · 1s · completed ✓ exit 0

  1 Run · 2 steps · 41s · 6.6k tokens
```

One block per script: what changed, what was read, what ran. Ctrl+O shows the diff, result and script.

## Safety

nib runs model-written code with your permissions. bash refuses obviously destructive commands, but it is a guard rail, not a sandbox — commit before you start. Sessions and tool results are logged locally in `~/.nib/sessions` (mode 0600); `NIB_RECORD=off` stops tool recording.

## More

[Docs](docs/README.md) · [Providers](docs/providers.md) · [Config](docs/config.md) · [Releases](docs/releases/) · [MIT](LICENSE)
