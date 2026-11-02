---
status: accepted
date: 2026-11-01
---

# 只暴露 run(code)：模型写 JS，跑在 QuickJS 里

模型 API 层面只有一个入口 `run(code)`。所有 Tool（read、edit、bash……）都是 Sandbox 里的函数，以 TS 类型声明的形式写进系统提示；模型写的是 JS，由内嵌的 QuickJS-ng 执行。

**为什么：** 代码驱动的主要收益在一次 Run 内部：读、搜、过滤、汇总的中间数据留在 Sandbox 里，只把结果交给模型，上下文不膨胀。选 JS 而非 Python，是因为 QuickJS 是纯 C 库，可以在进程内嵌入，开销很小，默认没有任何宿主能力；`async/await` 和 JSON 原生契合"编排 Tool 调用"。用 TS 声明来描述签名、用 JS 来执行，避免了在 QuickJS 前面再加一个 TS 转译器。

**参考（来源与把握）：**
- pi codemode：QuickJS（wasm）+ TS 声明（一手：本地源码 `pi/packages/codemode`）
- jcode codemode：rquickjs 内嵌（一手：本地源码 `jcode/crates/jcode-codemode`）
- prime-agent：唯一工具 `python_repl`，常驻 CPython（一手：本地源码 `pa-core/src/prompts/layers/core.md`）
- DeepSeek Harness 的 PTC：只暴露 `run_code`，每段程序起一个新 Node 进程，后来删除了"原生调用和 PTC 混用"的模式（**二手**：第三方博客 redreamality.com，未经官方核实）

**把握程度：**
- 实测：QuickJS 嵌入、内存上限、无宿主能力（`src/js.zig` 中的测试）。
- 推测，未实测：DeepSeek 能稳定地按 TS 声明写出合法 JS；简单操作（如读一个文件）用 PTC 方式的 token 开销是否可接受。

**何时重新考虑：**
- 实测发现模型频繁写出 TS 语法或其他 QuickJS 不支持的语法，且错误反馈后仍无法自我修正；
- 简单操作的 token 开销明显高于原生 tool calling：可以考虑为少数高频 Tool 恢复原生调用（混合模式）；
- 需要 Python 生态的任务占比很高：可以考虑把 Python 作为第二种运行时（经同一套 Tool 管线）。
