# nibcode

用 Zig 0.17 写的编码 agent，命令名 `nib`。

- 构建：`zig build`；测试：`zig build test --summary all`
- 运行：`./zig-out/bin/nib`（TUI）、`nib ask '<prompt>'`、`nib js '<code>'`；TUI 用 `/compact` 手动压缩上下文。
- 推理强度：`nib --effort high` / `nib ask --effort high '<prompt>'`；TUI `/effort` 查询、`/effort high` 切换。支持 `default|off|none|minimal|low|medium|high|xhigh|max`（服务端支持因模型而异）；显式设置覆盖 thinking/effort 环境配置，`default` 清除覆盖。只影响当前进程，子会话继承。
- 恢复：`nib -c` / `nib --continue` 继续当前目录最近的根会话（跳过子会话）；`nib --resume <32位小写十六进制ID>` 指定会话；`ask` 也支持这些选项，放在 prompt 前后均可。
- 环境变量：`DEEPSEEK_API_KEY`（或 `NIB_API_KEY`）、`NIB_BASE_URL`、`NIB_MODEL`、`NIB_CONTEXT_WINDOW`（DeepSeek 默认 1000000）、`NIB_THINKING`（`on`/`off`，不设则用服务端默认）、`NIB_REASONING_EFFORT`（如 `low`/`high`/`max`）。默认模型 `deepseek-flash`
- Codex：`NIB_PROVIDER=codex ./zig-out/bin/nib`（或 `ask '你好'`）；读取 `$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`，无需 API key。默认 `gpt-6.1-sol` / 500000 tokens。模型、推理配置、恢复和凭证边界见 [docs/codex.md](docs/codex.md) 与 [ADR 0011](docs/adr/0011-provider-wire-protocols.md)。

**代码的读者是 agent。** 不写复述代码、解释思路或记录改动历史的注释；过时的注释比没有注释更容易误导模型。只在代码表达不了、不知道就会改错的地方写一行：外部限制、协议怪癖、内存归属、并发不变量。含义靠命名、类型和测试承载；给人看的解释写进 `docs/`。

术语见 [CONTEXT.md](CONTEXT.md)，决策记录见 [docs/adr/](docs/adr/)。

**文档是参考，不是规则。** 读到的 ADR 与代码、实测或更好的方案冲突时，指出来并更新文档，不要为了迁就文档而迁就代码。详见 [docs/README.md](docs/README.md)。

新会话按基础指令、全局 `$XDG_CONFIG_HOME/nib/AGENTS.md`（默认 `~/.config/nib/AGENTS.md`）、项目 `AGENTS.md` 的顺序拼接 system，后者优先。项目目录是从 cwd 向上遇到的第一个 `.git` 标记所在目录；没有则用 cwd。只读取 `AGENTS.md`。恢复会话沿用日志中的原始 system，之后修改指令文件只影响新会话。

会话日志位于 `$XDG_DATA_HOME/nib/sessions/<ID>.jsonl`（默认 `~/.local/share/nib/sessions/`）。日志只在完整 Step 后提交；取消（TUI 的 Esc、ask 收到 SIGTERM/SIGINT）时额外提交本轮用户消息和已流出的文本，末尾标记 `[interrupted by user]`，未完成的工具调用丢弃；恢复不重执行已提交的 Run；未完成 Step 可能已产生外部副作用，日志不回滚这些变化。

`nib ask --json '<prompt>'` 的 stdout 是 NDJSON：每行一个单键对象，按产生顺序输出并立即 flush；stderr 没有人类可读进度或颜色。prompt 为 `-` 时从 stdin 读到 EOF（普通 ask 也支持）。退出码成功 0，失败非 0。

- `{"start":{"session_id":"<32位小写十六进制>"}}`：Session 已初始化；恢复时沿用原 id。
- `{"delta":{"kind":"text|reasoning","text":"..."}}`：模型流式片段，包含中间 Step 的文本。
- `{"run_start":"<JS代码>"}`、`{"run_end":{"ok":true,"output":"..."}}`：一次 Run 的开始和结果；Run 失败可由模型继续处理。
- `{"usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0}}`：本轮累计用量快照（含已报告的子会话用量），不是增量；用于中途显示与强制终止后的统计。
- `{"retry":{"attempt":1,"delay_ms":1000,"reason":"..."}}`、`{"notice":"..."}`：重试与通知。
- `{"end":{"text":"<最终回答>","usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0},"steps":1}}`：Turn 成功结束；usage 只统计本轮，含自动压缩和子会话。最终回答取这里的 text，不拼接所有 delta。
- `{"error":{"message":"...","usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0},"steps":0}}`：命令或 Turn 失败，没有 end；初始化失败时可能没有 start。usage/steps 保留失败前已报告的统计。错误文本供诊断，不作为稳定错误码。

事件结构与序列化定义在 `src/events.zig`。字符串中的换行经过 JSON 转义，每个物理行都是完整 JSON。

根会话可调用 `await tools.agent({ prompt })`，返回 `{ text, usage }`；`Promise.all` 并行派生，最多同时运行 4 个子会话（全部工具最多同时运行 8 个）。子会话独立读取指令文件，沿用 cwd 和有效 provider/模型配置（通过 stdin 管道传递；Codex 凭证各自读取），不继承父会话历史。内部环境变量 `NIB_AGENT_DEPTH` 从 0 递增，深度达到 1 时，工具说明与实际 JS API 都移除 agent。`NIB_PARENT_SESSION_ID` 写入子会话日志首条记录的 `parent_session_id`。显式 `--resume` 子会话仍保留深度限制；`--continue` 跳过子会话。

bash 与子会话复用进程组执行器，取消和超时会清理整组；子 nib 先收到 SIGTERM，有 500 ms 取消自身工具，之后强制终止。用量按已收到的累计快照统计，无法推知服务端尚未报告的 token。路径写锁只协调当前进程内的 edit/write，不协调独立子会话或 bash 的写入。
