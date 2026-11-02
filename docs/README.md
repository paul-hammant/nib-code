# nibcode 文档

这里的文档是**参考和指引，不是规则**。写下它们是为了记住"当时为什么这么选"，而不是阻止后来者做得更好。

## 怎么读、怎么写这些文档

1. **ADR 记录的是理由，不是命令。** 每份 ADR 写清楚：决定是什么、为什么、把握多大、什么情况下该重新考虑。想推翻一个决定，不需要先"说服文档"，只要看"何时重新考虑"里的前提是否还成立。
2. **事实标注来源和日期。** 区分：实测 / 一手来源（官方文档、源码）/ 二手来源 / 推测。二手和推测的内容，可能是错的。
3. **不在文档里写"必须""禁止"。** 真正不能破的约束交给测试来保证。文档里的数字是观察值，变化大时值得停下来想一想，但不是禁令。
4. **代码和实测说了算，文档负责解释。** 发现文档和现实不一致时，指出来，并在同一次改动里更新或废弃文档。过时的文档比没有文档更有害。
5. **短。** 一份 ADR 尽量一屏以内。写得越长，越容易被当成规范。

这些原则同样适用于 agent：读到的文档是背景信息，与证据冲突时应当提出，而不是照做。

## 我们说的"极简"

极简指优雅的设计和架构，不是死守代码行数。我们用这几条来判断：

- **概念少，而且各管一件事。** Session、Turn、Step、Run、Tool 各有明确边界（见 [CONTEXT.md](../CONTEXT.md)）。要加新概念时，先问能不能用已有概念表达。
- **模块深。** 接口简单，复杂性藏在内部。例如界面只需要 `Session.turn`、`Session.compact` 和一个事件 `Sink`。
- **同一件事只在一处定义。** 例如每个 Tool 的名字、给模型看的说明和实现入口登记在 `tools.zig` 的同一张表里，说明由表生成；实现放在 `tools/` 下。
- **说法前后一致。** 例如要模型写 JS，给它看的接口说明也用 JS。
- **不为还没出现的需求设计，没有证据不加特例。**

代码行数只是一个观察指标：突然膨胀时值得回头审视设计，但它本身不是目标。

## 索引

- [CONTEXT.md](../CONTEXT.md)：术语表，统一我们说话用的词
- [adr/](adr/)：架构决策记录
  - [0001 Zig，从零开始](adr/0001-zig-from-scratch.md)
  - [0002 只暴露 run(code)：模型写 JS，跑在 QuickJS 里](adr/0002-run-code-only.md)
  - [0003 每次 Run 都是全新的沙箱](adr/0003-stateless-runs.md)
  - [0004 两层隔离](adr/0004-two-layer-isolation.md)（暂缓：系统层沙箱不做，语言层已实现）
  - [0005 一个 Session 一个进程](adr/0005-process-per-session.md)
  - [0006 不审批，宿主侧拒绝危险命令](adr/0006-deny-dangerous-commands.md)
  - [0007 保持 system 稳定，按完整 Step 压缩上下文](adr/0007-context-compaction.md)
  - [0008 支持 thinking 模型，默认 deepseek-flash](adr/0008-thinking-models.md)
  - [0009 Run 内工具调用真正并发，顺序按 JS 语义](adr/0009-concurrent-tools.md)
  - [0010 子 agent：tools.agent 派生独立 nib 子进程](adr/0010-subagents.md)
  - [0011 一个 Provider 接口，两种线路协议](adr/0011-provider-wire-protocols.md)
  - [0012 新增 grep、glob、fetch，搜索用 Zig 原生实现](adr/0012-search-and-fetch-tools.md)
- [codex.md](codex.md)：使用本机 Codex 登录、配置与凭证边界

## 没写成 ADR 的选择

这些容易撤回，记一笔即可：

- Provider 支持 Codex Responses（默认，gpt-6.1-sol）与 Chat Completions（DeepSeek），见 [0011](adr/0011-provider-wire-protocols.md)。
- TUI 用 libvaxis。`/` 指令：`/help`、`/new`、`/resume <id>`、`/compact`、`/effort [level]`、`/copy`、`/js <code>`，定义在 `src/tui/commands.zig` 的一张表里，`/help`、候选列表和参数候选都由它生成。输入 `/` 时在输入框上方按前缀列出候选：↑↓ 选择，Tab 补全，Enter 执行（需要参数的指令先补全再等参数），Esc 关闭。`/resume` 的候选是当前目录下有用户消息的会话（最近的在前），没说过话的空会话不列出，`-c` 同样跳过它们。`/help` 和 `/copy` 在回合进行中也能用；`/copy` 通过终端的 OSC 52 写剪贴板，终端不支持时不会生效。回合进行中，状态栏最前面显示转圈指示、当前阶段（thinking / writing / running / retrying / compacting）和该阶段已用秒数。Run 和推理默认各折叠成一行（Run 显示状态、用到的工具、耗时和改动的文件，如 `src/a.zig +3 −1`；超过两个文件时显示总数），ctrl+o 全部展开或收起，展开后在脚本和输出下方显示带颜色的 diff（最多 60 行）。改动只统计 edit/write，按 Run 开始前的内容比较；bash 和子会话的改动看不到，改动信息也不写进会话日志，恢复会话后的历史 Run 不显示。TUI 开启了鼠标上报：滚轮滚动对话区；左键拖动按屏幕行连续选中文字并反色高亮，松开即复制，显示 `copied N chars`。反向拖动同样支持，宽字符只复制一次，每行去掉行尾空格，屏幕行之间保留换行。复制先发送终端 OSC 52（可用于 SSH）；有图形会话时再通过 stdin 写入 `wl-copy`（Wayland），否则使用 `xsel` 或 `xclip`（X11）。本地剪贴板程序不可用或失败时仍保留 OSC 52 尝试；终端可能禁用或不支持 OSC 52。单击、滚动或窗口尺寸变化会清除选区；流式输出时选区不跟随文本，只复制松开时的屏幕内容。操作：PgUp/PgDn 翻半屏，shift+↑↓ 滚 3 行；向上翻看时视口按顶部条目锚定，新内容到达不推移画面，回到底部后恢复跟随。输入框中 shift+enter / alt+enter / ctrl+j 换行，粘贴内容中的回车不会提交；光标在首行按 ↑、末行按 ↓ 翻阅本次会话的输入历史（不跨进程保存）。assistant 文本渲染基础 Markdown：代码围栏（含未闭合的）、行内代码、粗体、标题。
- 会话持久化、恢复和项目指令已实现（2026-11-01，一手源码：`src/session.zig`、`src/session/log.zig`、`src/session/instructions.zig`、`src/main.zig`）。日志按完整 Step 同步落盘；详细行为见根目录 [AGENTS.md](../AGENTS.md)，端到端检查可运行 `zig build` 后执行 `python3 tests/test_session.py`。

## 暂缓的想法

想到了、但现在不做的事。每条写清楚为什么暂缓、什么时候再考虑，避免遗忘，也避免被误当成已定的计划。

- **跨进程保存输入历史。** 现在只在本次会话内可翻阅。等实际使用中需要时再做。

Run 内工具并发、`nib ask --json` 和 `tools.agent` 均已实现，见 ADR 0009–0010；NDJSON 格式与调用约定见 [AGENTS.md](../AGENTS.md)。`zig build` 后执行 `python3 tests/test_session.py` 可检查会话恢复、机器事件、子 agent 并发/深度/用量/取消及启动开销（全程本地 mock，无真实 key）。其他被搁置的方案记在对应 ADR 里：系统层沙箱（[0004](adr/0004-two-layer-isolation.md)）、守护进程（[0005](adr/0005-process-per-session.md)）、跨 Run 的变量存储（[0003](adr/0003-stateless-runs.md)）、混合原生工具调用和 Python 运行时（[0002](adr/0002-run-code-only.md)）。

## 度量

这些是观察值，不是目标或禁令。数字会变，以最新实测为准，每次更新请写日期。

| 项目 | 实测值 | 警报线 | 测量方式 |
|---|---|---|---|
| 源码行数（`src/` + `build.zig`，含测试） | 3766（2026-11-01，实现工具并发、NDJSON 与子 agent 后） | — | `wc -l build.zig src/**/*.zig`（zsh） |
| TUI 单帧 draw 耗时，5000 条目、100×24 | 底部跟随 102.5 → 29.7 µs；上翻 1200 行 1149.5 → 57.2 µs（2026-11-01，ReleaseFast，加高度缓存前 → 后） | — | 预热后每组 32 帧，5 组平均值取中位数，只测 draw（feat/tui-polish 的报告） |
| `nib js '1+1'` 平均耗时（含进程启动） | 1.6 ms（2026-11-01，ReleaseFast） | — | 循环 100 次取平均 |
| 工具 Promise.all / 依次 await：两个 sleep 0.3 | 307 / 611 ms（2026-11-01，Debug） | — | `src/tools.zig` 测试，见 ADR 0009 |
| 子进程启动至 NDJSON start（含日志同步，不含 TLS） | Debug 中位数 11.82 ms；ReleaseFast 中位数 1.30 ms（2026-11-01） | — | `tests/test_session.py`，10 次，见 ADR 0010 |
| 上述命令峰值 RSS | 3.7 MB（2026-11-01） | — | `/usr/bin/time -f %M` |
| 二进制体积（ReleaseFast，strip 后） | 1.9 MB（2026-11-01） | — | `strip` 后 `ls -l` |
| TUI 进程空闲 PSS（一轮对话后，无 TLS） | 3.08 MB/进程，10 个合计 30.8 MB（2026-11-01，ReleaseFast） | — | 10 个 TUI 对本地模拟服务器各聊一轮，读 `/proc/<pid>/smaps_rollup` 的 `Pss` |
| 一次 HTTPS 请求峰值 RSS（含 TLS） | 7.6 MB（2026-11-01，ReleaseFast） | — | `/usr/bin/time -f %M nib ask hi`（无效 key，收到 401） |
