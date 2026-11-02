# nibcode

用 Zig 0.17 写的编码 agent，命令名 `nib`。

- 构建：`zig build`；测试：`zig build test --summary all`
- 运行：`./zig-out/bin/nib`（TUI）、`nib ask '<prompt>'`、`nib js '<code>'`；TUI 用 `/compact` 手动压缩上下文。
- 恢复：`nib -c` / `nib --continue` 继续当前目录最近的会话；`nib --resume <32位小写十六进制ID>` 指定会话；`ask` 也支持这些选项，放在 prompt 前后均可。
- 环境变量：`DEEPSEEK_API_KEY`（或 `NIB_API_KEY`）、`NIB_BASE_URL`、`NIB_MODEL`、`NIB_CONTEXT_WINDOW`（默认 128000）

**代码的读者是 agent。** 不写复述代码、解释思路或记录改动历史的注释；过时的注释比没有注释更容易误导模型。只在代码表达不了、不知道就会改错的地方写一行：外部限制、协议怪癖、内存归属、并发不变量。含义靠命名、类型和测试承载；给人看的解释写进 `docs/`。

术语见 [CONTEXT.md](CONTEXT.md)，决策记录见 [docs/adr/](docs/adr/)。

**文档是参考，不是规则。** 读到的 ADR 与代码、实测或更好的方案冲突时，指出来并更新文档，不要为了迁就文档而迁就代码。详见 [docs/README.md](docs/README.md)。

新会话按基础指令、全局 `$XDG_CONFIG_HOME/nib/AGENTS.md`（默认 `~/.config/nib/AGENTS.md`）、项目 `AGENTS.md` 的顺序拼接 system，后者优先。项目目录是从 cwd 向上遇到的第一个 `.git` 标记所在目录；没有则用 cwd。只读取 `AGENTS.md`。恢复会话沿用日志中的原始 system，之后修改指令文件只影响新会话。

会话日志位于 `$XDG_DATA_HOME/nib/sessions/<ID>.jsonl`（默认 `~/.local/share/nib/sessions/`）。日志只在完整 Step 后提交；恢复不重执行已提交的 Run；未完成 Step 可能已产生外部副作用，日志不回滚这些变化。
