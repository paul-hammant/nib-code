# nibcode

用 Zig 0.17 写的编码 agent，命令名 `nib`。

- 会话统计：`python3 scripts/stats.py [日志文件或目录] [--since YYYY-MM-DD] [--cwd 目录] [--json]`，默认只读 `$NIB_HOME/sessions`（默认 `~/.nib/sessions`），用于发现故障和比较改动前后效果。
- 构建：`zig build`；测试：`zig build test --summary all`；端到端（本地 mock，无真实 key）：`zig build` 后 `python3 tests/test_session.py`、`python3 tests/test_codex.py`
- 安装到 `~/.local/bin/nib`：`zig build -Doptimize=ReleaseFast --prefix ~/.local`；版本号在 `build.zig.zon`，`nib --version` 查看。
- 运行：`./zig-out/bin/nib`（TUI）、`nib ask '<prompt>'`、`nib js '<code>'`；TUI 用 `/compact` 手动压缩上下文。
- 反思：TUI `/reflect [focus]` 让模型对照本会话日志（含子会话）只读地复盘 harness 的摩擦、建议和任务描述问题；正常结束的回答追加到 `$NIB_HOME/reflections.md`（每条带 UTC 时间、会话、cwd、模型、effort 表头），供批量分析后迭代。回答最后的 ```json 草稿（最多 3 个）随后**自动**发布为 GitHub issue，无需确认：目标仓库 `NIB_ISSUE_REPO`（默认 `yyydddkkk/nib-code`，设为 `off` 关闭），用用户自己的 `gh` 登录和环境；发布前按标题查重（已有则跳过），把当前项目路径替换成 `<project>`、HOME 替换成 `~`，像凭证的草稿（`sk-`、`ghp_`、`Bearer ` 等）不发布；每条结果显示在对话区并追加到 reflections.md。脱敏只是兜底，主要靠提示词要求草稿不含项目内容。提示词模板是 `src/tui/reflect.md`（编译时嵌入，改措辞改这个文件），占位符 `{{session_id}}`、`{{log_path}}`、`{{focus}}`。
- 推理强度：`nib --effort high` / `nib ask --effort high '<prompt>'`；TUI `/effort` 查询、`/effort high` 切换。支持 `default|off|none|minimal|low|medium|high|xhigh|max`（服务端支持因模型而异）；显式设置覆盖 thinking/effort 环境配置，`default` 清除覆盖。CLI 只影响当前进程；TUI `/effort <level>` 原子保存到 `$NIB_HOME/config.toml` 的顶层 `effort`，保留其他行，`default` 删除该键；保存失败不影响当前设置，只在对话区提示。子会话继承当前有效配置。
- 恢复：`nib -c` / `nib --continue` 继续当前目录最近的根会话（跳过子会话）；`nib --resume <32位小写十六进制ID>` 指定会话；`ask` 也支持这些选项，放在 prompt 前后均可。
- 默认 provider 是 Codex（环境和配置文件均未指定时为 `codex`）：读取 `$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`，无需 API key。默认 `gpt-6.1-sol` / 500000 tokens。模型、推理配置、恢复和凭证边界见 [docs/codex.md](docs/codex.md) 与 [ADR 0011](docs/adr/0011-provider-wire-protocols.md)。
- DeepSeek（Chat Completions）：`NIB_PROVIDER=chat_completions`，配 `DEEPSEEK_API_KEY`（或 `NIB_API_KEY`），默认模型 `deepseek-flash`。
- 用户目录：`NIB_HOME`，默认 `~/.nib`。全局指令 `AGENTS.md`、会话 `sessions/`、非秘密配置 `config.toml` 均放在此目录；不读取 XDG 路径，也不自动迁移旧文件。配置顶层支持 `provider`、`effort`，`[codex]` / `[chat_completions]` 支持 `model`、`base_url`、`context_window`；优先级为 CLI effort > 环境变量 > 文件 > 默认值。无项目配置文件，项目约定仍用 `AGENTS.md`。格式、凭证边界见 [docs/config.md](docs/config.md)。
- 环境变量：`NIB_PROVIDER`（`codex`/`chat_completions`）、`NIB_BASE_URL`、`NIB_MODEL`、`NIB_CONTEXT_WINDOW`（DeepSeek 默认 1000000）、`NIB_THINKING`（`on`/`off`，不设则用服务端默认）、`NIB_REASONING_EFFORT`（如 `low`/`high`/`max`）。

## 代码地图

目录按 [CONTEXT.md](CONTEXT.md) 的概念划分。`x.zig` 是该部分的入口和对外接口，`x/` 放它的内部实现；新代码放进所属概念的目录，不再往 `src/` 顶层平铺。

- `src/main.zig`：命令行入口，分派到 TUI、`ask`、`js`。
- `src/config.zig`：解析 `NIB_HOME/config.toml`、合并环境配置、解析用户目录与原子写回 effort。
- `src/session.zig`：Session 引擎（Turn、Step、压缩、取消）；`session/` 下是日志、指令拼接、事件。
- `src/provider.zig`：Provider 接口与配置；`provider/` 下是各线路协议和 SSE 解析。
- `src/sandbox.zig`：QuickJS Run 与宿主桥接。
- `src/tools.zig`：工具表（给模型看的 JS 说明集中在这里）、`Tools` 共享状态与调度。`tools/` 下每个工具族一个入口文件，函数名即工具名：`files.zig`（read/edit/write）、`search.zig`（grep/glob）、`web.zig`（fetch）、`bash.zig`、`agent.zig`；其余是它们的辅助模块。加工具：在 `tools/` 写入口函数，再在表里加一行。
- `src/tui.zig`：TUI 事件循环（按键、`/` 指令分派、Session 事件、后台 Turn）；`tui/` 下：`transcript.zig`（对话条目与折叠）、`viewport.zig`（滚动锚定）、`view.zig`（一帧的布局绘制）、`status.zig`（活动行与下边框元数据）、`menu.zig`（`/` 候选菜单）、`commands.zig`（指令表）、`reflect.zig` + `reflect.md`（/reflect 的提示词与 reflections.md 追加）、`editor.zig`（输入框、原子粘贴块与进程内草稿历史）、`long_text.zig`（长文本阈值与计数）、`markdown.zig`、`selection.zig`（鼠标选区、高亮与剪贴板复制）。
- `tests/`：端到端测试和 mock 服务器；`scripts/`：辅助脚本。

工具返回给 JS 的是完整数据，不能为保护模型上下文而悄悄截断或往正文里添加提示；否则 `read → JS 替换 → write` 会把截断标记写回文件，造成数据损坏。上下文截断只发生在 Session 把 Run 输出交给模型时（`tools.truncateMiddle`，保留首尾约 16 KiB），不改变 Run 内的数据。`read` 返回 `{ text, next_offset }`：按 offset/limit 原样返回请求的行，默认 2000 行，后续行起点单独放在 next_offset，EOF 时为 null；文件上限仍为 16 MiB。`bash` 的 `{ exit_code, output }` 中 output 原样返回，超过 16 MiB 报错并提示重定向到文件。工具自身明确约定的有界结果除外：grep 的文本/上下文行最多 500 字节，grep/glob 用 truncated 标记结果数量上限；fetch 的文本最多 1 MiB，返回 `{ url, status, content_type, text, truncated }`，truncated 明确表示正文不完整，提示不混入 text，下载超过 5 MiB 则报错。

Run 的默认 5 分钟超时只累计 QuickJS 执行片段（初始脚本、Promise jobs、工具结果解析/resolve、返回值序列化和错误转换），不计算等待工具完成的时间，也不在每次 await 后重置预算。它用于中断 JS 死循环；bash/fetch/agent 的执行时限由各自工具负责。等待时仍每 20 ms 检查取消，Esc/SIGINT/SIGTERM 不受计时暂停影响。搜索优先用 tools.grep/tools.glob，不在 bash 里调 rg/find/grep。写包含反引号、`${` 或反斜杠的文件/命令文本时，用 JSON 转义的双引号 JS 字符串，不用模板字符串或 String.raw；工具表的示例由 sandbox 测试逐字节验证。

**代码的读者是 agent。** 不写复述代码、解释思路或记录改动历史的注释；过时的注释比没有注释更容易误导模型。只在代码表达不了、不知道就会改错的地方写一行：外部限制、协议怪癖、内存归属、并发不变量。含义靠命名、类型和测试承载；给人看的解释写进 `docs/`。

术语见 [CONTEXT.md](CONTEXT.md)，决策记录见 [docs/adr/](docs/adr/)。

**文档是参考，不是规则。** 读到的 ADR 与代码、实测或更好的方案冲突时，指出来并更新文档，不要为了迁就文档而迁就代码。详见 [docs/README.md](docs/README.md)。

新会话按基础指令、全局 `$NIB_HOME/AGENTS.md`（默认 `~/.nib/AGENTS.md`）、项目 `AGENTS.md` 的顺序拼接 system，后者优先。项目目录是从 cwd 向上遇到的第一个 `.git` 标记所在目录；没有则用 cwd。只读取 `AGENTS.md`。恢复会话沿用日志中的原始 system，之后修改指令文件只影响新会话。

模型请求的两条线路共用 `src/provider/cancel.zig` 的 `std.Io.Select` 取消封装：请求任务实时写入 sink，另一个任务每 20 ms 检查 cancel 标志；取消时中断连接、发送或读取中的阻塞 I/O，并等待请求任务清理后返回 `error.Canceled`，无需等下一块数据。TUI Esc 与 ask SIGINT/SIGTERM 均走此路径，不设读超时，不改变重试策略；已流出的文本继续由原有 `commitInterrupted` 提交。

会话日志位于 `$NIB_HOME/sessions/<ID>.jsonl`（默认 `~/.nib/sessions/`）。日志只在完整 Step 后提交；取消（TUI 的 Esc、ask 收到 SIGTERM/SIGINT）时额外提交本轮用户消息和已流出的文本，TUI Esc / ask SIGINT 在末尾标记 `[interrupted by user]`，ask SIGTERM 标记 `[interrupted: process terminated]`，未完成的工具调用丢弃；恢复不重执行已提交的 Run；未完成 Step 可能已产生外部副作用，日志不回滚这些变化。

`nib ask --json '<prompt>'` 的 stdout 是 NDJSON：每行一个单键对象，按产生顺序输出并立即 flush；stderr 没有人类可读进度或颜色。prompt 为 `-` 时从 stdin 读到 EOF（普通 ask 也支持）。退出码成功 0，失败非 0。

- `{"start":{"session_id":"<32位小写十六进制>"}}`：Session 已初始化；恢复时沿用原 id。
- `{"delta":{"kind":"text|reasoning","text":"..."}}`：模型流式片段，包含中间 Step 的文本。
- `{"run_start":"<JS代码>"}`、`{"run_end":{"ok":true,"output":"...","changes":[...]}}`：一次 Run 的开始和结果；Run 失败可由模型继续处理。`changes` 列出这次 Run 里 edit/write 改动的文件：`{"path","added","removed","created","diff"}`，与 Run 开始前的内容比较（改了又改回的文件不列出）；`diff` 是带一行上下文的 `+`/`-`/` ` 行，超过 200 行截断。bash 和子会话的改动不在其中。
- `{"usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0}}`：本轮累计用量快照（含已报告的子会话用量），不是增量；用于中途显示与强制终止后的统计。
- `{"retry":{"attempt":1,"delay_ms":1000,"reason":"..."}}`、`{"notice":"..."}`：重试与通知。
- `{"end":{"text":"<最终回答>","usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0},"steps":1}}`：Turn 成功结束；usage 只统计本轮，含自动压缩和子会话。最终回答取这里的 text，不拼接所有 delta。
- `{"error":{"message":"...","usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0},"steps":0}}`：命令或 Turn 失败，没有 end；初始化失败时可能没有 start。usage/steps 保留失败前已报告的统计。错误文本供诊断，不作为稳定错误码。

事件结构与序列化定义在 `src/session/events.zig`。字符串中的换行经过 JSON 转义，每个物理行都是完整 JSON。

根会话可调用 `await tools.agent({ prompt, timeout_ms: 1800000 })`，返回 `{ text, usage }`；timeout_ms 可省略，默认 30 分钟，不计排队时间。超时错误包含实际耗时（含终止宽限）、子会话 id（未收到 start 时明确标为不可用）和检查半成品文件的提醒。子会话适合独立调查或任务，不适合需要跨文件协调的修改；`Promise.all` 并行派生，最多同时运行 4 个子会话（全部工具最多同时运行 8 个）。子会话独立读取指令文件，沿用 cwd 和有效 provider/模型配置（通过 stdin 管道传递，子会话跳过配置文件读取；Codex 凭证各自读取），不继承父会话历史。内部环境变量 `NIB_AGENT_DEPTH` 从 0 递增，深度达到 1 时，工具说明与实际 JS API 都移除 agent。`NIB_PARENT_SESSION_ID` 写入子会话日志首条记录的 `parent_session_id`。显式 `--resume` 子会话仍保留深度限制；`--continue` 跳过子会话。

bash 与子会话复用进程组执行器，取消和超时会清理整组；子 nib 先收到 SIGTERM，有 500 ms 取消自身工具，之后强制终止。用量按已收到的累计快照统计，无法推知服务端尚未报告的 token。路径写锁只协调当前进程内的 edit/write，不协调独立子会话或 bash 的写入。
