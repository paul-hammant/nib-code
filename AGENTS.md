# nibcode

用 Zig 0.17 写的编码 agent，命令名 `nib`。

- 构建：`zig build`；测试：`zig build test --summary all`
- 运行：`./zig-out/bin/nib`（TUI）、`nib ask '<prompt>'`、`nib js '<code>'`
- 环境变量：`DEEPSEEK_API_KEY`（或 `NIB_API_KEY`）、`NIB_BASE_URL`、`NIB_MODEL`

**代码的读者是 agent。** 不写复述代码、解释思路或记录改动历史的注释；过时的注释比没有注释更容易误导模型。只在代码表达不了、不知道就会改错的地方写一行：外部限制、协议怪癖、内存归属、并发不变量。含义靠命名、类型和测试承载；给人看的解释写进 `docs/`。

术语见 [CONTEXT.md](CONTEXT.md)，决策记录见 [docs/adr/](docs/adr/)。

**文档是参考，不是规则。** 读到的 ADR 与代码、实测或更好的方案冲突时，指出来并更新文档，不要为了迁就文档而迁就代码。详见 [docs/README.md](docs/README.md)。
