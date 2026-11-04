# nib

用 Zig 写的编码 agent。模型不逐个调用工具，而是写一段 JavaScript，在内嵌的 QuickJS 沙箱里一次完成读文件、搜索、修改、跑测试，只把需要的结果带回对话。

```js
// 模型的一次 Run：并发读文件，修改，然后构建和测试，只返回失败的部分
const [a, b] = await Promise.all([tools.read({ path: "src/a.zig" }), tools.read({ path: "src/b.zig" })]);
await tools.edit({ path: "src/a.zig", old_text: "...", new_text: "..." });
const r = await tools.bash({ command: "zig build test" });
r.exit_code === 0 ? "ok" : r.output
```

当前版本 0.3.0，个人项目，仍在快速迭代。

## 特点

- **代码驱动**：只有一个 `run` 工具，模型可以调用的能力都是沙箱里的 JS 函数：`read`、`edit`、`write`、`grep`、`glob`、`fetch`、`bash`。一个 Run 里可以并发调用多个工具，在 JS 里过滤结果，减少和模型来回的次数。
- **`tools.llm`**：一次干净的模型推理，不带工具、不带上下文，可以在 JS 里并发调用，适合批量判断、分类、抽取。
- **`tools.agent`**：派生独立的子 agent 处理多步任务。失败时作为数据返回，不影响同一个 Run 里的其他子 agent，结果里附带它改过的文件。
- **后台任务**：`agent` 和 `bash` 可以传 `background: true`，立即返回任务 id，主模型继续工作；结果在之后的 Step 里作为消息到达。
- **逐步调度推理强度**：模型可以为下一步声明更低的 effort。用户的设置是上限，Run 失败或用户插话后自动恢复。
- **TUI**：回合进行中可以插话；子 agent 和后台任务在 Run 下方显示为状态树；每轮结束显示账单（推理与工具耗时、工具数据量与进入上下文的字节数、token、缓存命中）；用鼠标选中文本即可复制。
- **可度量、可重放**：会话日志记录每个 Step 的耗时、用量和工具数据量，`scripts/stats.py` 用来统计失败、耗时构成和往返结构。工具调用的参数和结果默认录制在本地，`nib replay` 可以离线重新执行任意 Run，见 [docs/replay.md](docs/replay.md)。`/reflect` 让模型对照日志复盘 harness 本身的问题，并自动提 issue。

## 安装

需要 Zig 0.17。

```sh
git clone https://github.com/yyydddkkk/nib-code.git
cd nib-code
zig build -Doptimize=ReleaseFast --prefix ~/.local   # 安装到 ~/.local/bin/nib
nib --version
```

## 接入模型

**Codex（默认）**：先用 `codex` 命令行完成 ChatGPT 登录，nib 会读取 `~/.codex/auth.json`，不需要 API key。默认模型 `gpt-6.1-sol`。详见 [docs/codex.md](docs/codex.md)。

**DeepSeek（Chat Completions）**：

```sh
NIB_PROVIDER=chat_completions DEEPSEEK_API_KEY=... nib
```

provider、模型和 effort 也可以写进 `~/.nib/config.toml`，见 [docs/config.md](docs/config.md)。

## 使用

```sh
nib                          # 打开 TUI
nib ask '解释一下这个项目的结构'
nib ask --json '...'         # NDJSON 事件流，供脚本和其他程序调用
nib -c                       # 继续当前目录最近的会话
nib --effort high            # 本次进程的推理强度
nib replay <会话ID> --all     # 离线重放该会话录制的 Run，检查结果是否一致
```

TUI 里输入 `/` 列出指令：`/new`、`/resume`、`/compact`、`/effort`、`/copy`、`/reflect`、`/js`、`/help`。Esc 中断当前回合，ctrl+o 展开 Run 的脚本、输出和 diff。

全局指令放在 `~/.nib/AGENTS.md`，项目约定放在项目根目录的 `AGENTS.md`。

## 安全

工具调用的结果默认录制在 `~/.nib/sessions/<id>.calls.jsonl`（权限 0600，只在本地），其中可能包含模型读过但没有回传的内容，比如 `.env`；不需要时设置 `NIB_RECORD=off`。

bash 有一层防误操作的检查：拒绝提权、关机、删除系统目录等命令，不读取 Codex 凭证。它是防止失误的护栏，不是安全沙箱，**nib 以你的用户权限运行模型生成的代码**。在重要的仓库上使用前，请确认工作区有提交或备份。

## 文档

- [docs/README.md](docs/README.md)：设计原则、决策记录（ADR）索引和暂缓的想法
- [docs/compromises.md](docs/compromises.md)：为当下做的妥协及其删除条件
- [docs/releases/](docs/releases/)：版本说明
- [AGENTS.md](AGENTS.md)：给参与开发的 agent 看的构建、测试命令和代码地图

## 许可证

[MIT](LICENSE)
