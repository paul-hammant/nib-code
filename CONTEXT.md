# nibcode

一个用 Zig 写的编码 agent：模型通过写代码来行动，代码在宿主内嵌的沙箱里执行。

## 会话与回合

**Session**（会话）：
用户与 agent 的一次完整对话，从启动到退出。
_Avoid_: conversation, thread, chat

**Session log**（会话日志）：
一个 Session 里发生的一切的只追加记录；是唯一的事实来源，恢复、分叉、回放都从它重建。
_Avoid_: history, transcript（transcript 只指界面上显示的内容）

**Turn**（回合）：
从一条用户消息开始，到 agent 把控制权交还用户为止的全部过程。一个 Turn 包含一个或多个 Step。
_Avoid_: round。注意：pi 的 `turn_start` 指的是单次模型调用，相当于这里的 Step。

**Step**（步）：
一个 Turn 内的一次模型请求与响应，以及随后执行的 Run（如果有）。
_Avoid_: iteration, turn

## 执行

**Run**：
模型写的一段代码在一个全新 Sandbox 里的一次执行。也是模型 API 层面唯一的调用入口。
_Avoid_: eval, cell, code-mode call, PTC call

**Sandbox**（沙箱）：
一次 Run 所在的隔离执行环境，除 Tool 之外没有任何宿主能力，Run 结束即销毁。
_Avoid_: VM, REPL, kernel（这些词暗示跨 Run 的持久状态）

**Tool**（工具）：
宿主暴露给 Run 内脚本的一项能力，如 `tools.read`；每次调用都经过校验、审批并写入 Session log。`run` 本身不叫 Tool。
_Avoid_: function, programmatic tool, native tool

## 模型

**Provider**：
一个模型服务及其线路协议，如 OpenAI 兼容的 Chat Completions。
_Avoid_: backend, API（太宽泛）

**Reasoning**（推理内容）：
模型输出的思考过程；展示给用户，但不进入发给模型的历史。
_Avoid_: thinking（在本项目中两者同义，统一用 Reasoning）
