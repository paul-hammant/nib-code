---
status: accepted
date: 2026-11-01
---

# 只暴露 run(code)：模型写 JS，跑在 QuickJS 里

模型 API 层面只有一个入口 `run(code)`。所有 Tool（read、bash……）都是 Sandbox 里的函数。系统提示里用合法的 JS 方法签名加注释来说明它们（解构参数带默认值，如 `async read({ path, offset = 1, limit = 2000 })`）；模型写的也是 JS，由内嵌的 QuickJS-ng 执行。

**为什么：** 代码驱动的主要收益在一次 Run 内部：读、搜、过滤、汇总的中间数据留在 Sandbox 里，只把结果交给模型，上下文不膨胀。选 JS 而非 Python，是因为 QuickJS 是纯 C 库，可以在进程内嵌入，开销很小，默认没有任何宿主能力；`async/await` 和 JSON 原生契合"编排 Tool 调用"。说明和代码用同一种语言：最初用 TS 类型声明描述签名（pi 的做法），但那样一边给 TS、一边要求"别写 TS"，信号自相矛盾，2026-11-01 改为 JS 方法签名。实测（字节数，2026-11-01）：旧 TS 声明 468 字节；JS 签名 441 字节，还多带了默认值等信息。中间试过"每个工具配一行完整调用示例"的写法，589 字节，偏长，弃用。说明是否合法由测试用 QuickJS 解析来保证。

**参考（来源与把握）：**
- pi codemode：QuickJS（wasm），签名用 TS 声明（一手：本地源码 `pi/packages/codemode`）
- jcode codemode：rquickjs 内嵌（一手：本地源码 `jcode/crates/jcode-codemode`）
- prime-agent：唯一工具 `python_repl`，常驻 CPython（一手：本地源码 `pa-core/src/prompts/layers/core.md`）
- DeepSeek Harness 的 PTC：只暴露 `run_code`，每段程序起一个新 Node 进程，后来删除了"原生调用和 PTC 混用"的模式（**二手**：第三方博客 redreamality.com，未经官方核实）

**把握程度：**
- 实测：QuickJS 嵌入、内存上限、无宿主能力、顶层 await、工具调用、超时中断（`src/js.zig` 中的测试）；完整的"模型调用 run → 执行 → 结果回传 → 回答"循环，用本地模拟服务器跑通（2026-11-01）。
- 实测：如果脚本里出现 TS 语法，QuickJS 的报错（如 `missing initializer for variable`）看不出原因。曾为此对 SyntaxError 加过提示，改用 JS 说明后撤掉了：先看真实模型是否还会写出 TS，有证据再加。
- 推测，未实测：DeepSeek 能稳定地按 JS 签名写出合法 JS；简单操作（如读一个文件）用 PTC 方式的 token 开销是否可接受。

**何时重新考虑：**
- 实测发现模型频繁写出 TS 语法或其他 QuickJS 不支持的语法，且看到报错后仍无法自我修正：先考虑给 SyntaxError 加提示，再考虑执行前剥离类型；
- 简单操作的 token 开销明显高于原生 tool calling：可以考虑为少数高频 Tool 恢复原生调用（混合模式）；
- 需要 Python 生态的任务占比很高：可以考虑把 Python 作为第二种运行时（经同一套 Tool 管线）。
