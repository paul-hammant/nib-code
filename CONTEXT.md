# nibcode

一个用 Zig 写的编码 agent：模型通过写代码来行动，代码在宿主内嵌的沙箱里执行。

## 会话与回合

**Session**（会话）：
用户与 agent 的一段完整对话，可通过 Session log 在进程退出后恢复。一个进程一次只持有一个 Session。
_Avoid_: conversation, thread, chat

**Session log**（会话日志）：
一个 Session 的模型上下文的只追加记录，是模型上下文的唯一事实来源。恢复从它重建 system、已完成的 Step 和压缩后的上下文；它不记录完整界面事件，也不能撤销或重放文件、命令的外部副作用。
_Avoid_: history, transcript（transcript 只指界面上显示的内容）

**Turn**（回合）：
从一条用户消息开始，到 agent 把控制权交还用户为止的全部过程。一个 Turn 包含一个或多个 Step。
_Avoid_: round。注意：pi 的 `turn_start` 指的是单次模型调用，相当于这里的 Step。

**Step**（步）：
一个 Turn 内的一次模型请求与响应，以及随后执行的全部 Run（如果有）。Step 完整后才提交日志；首个 Step 同时提交该 Turn 的用户消息。
_Avoid_: iteration, turn

**Subagent**（子 agent）：
父 Session 委派一个任务后创建的独立 Session，完成一个 Turn 后把最终回答与用量交还父 Session。任务上下文由委派的 prompt 表达，不继承父 Session 的对话历史。
_Avoid_: worker（仅指工具工作线程）, 常驻 agent

## 执行

**Run**：
模型写的一段代码在一个全新 Sandbox 里的一次执行。也是模型 API 层面唯一的调用入口。
_Avoid_: eval, cell, code-mode call, PTC call

**Sandbox**（沙箱）：
一次 Run 所在的隔离执行环境，除 Tool 之外没有任何宿主能力，Run 结束即销毁。
_Avoid_: VM, REPL, kernel（这些词暗示跨 Run 的持久状态）

**Tool**（工具）：
宿主暴露给 Run 内脚本的一项能力，如 `tools.read`；调用参数经过宿主校验。Session log 记录 Run 代码与最终返回给模型的结果，不逐项记录脚本内部的 Tool 调用。`run` 本身不叫 Tool。
_Avoid_: function, programmatic tool, native tool

## 模型

**Provider**：
一个模型服务及其线路协议，如 OpenAI 兼容的 Chat Completions。
_Avoid_: backend, API（太宽泛）

**Reasoning**（推理内容）：
模型输出的思考摘要与后续请求需要的推理数据。按 provider 保存并回传；可读内容展示给用户，加密条目只用于延续会话。
_Avoid_: thinking（在本项目中两者同义，统一用 Reasoning）

**Context compaction**（上下文压缩）：
用摘要替换较早的模型上下文，保留 system 和近期完整的 Turn 或 Step。Session log 追加替换记录，原始记录仍在文件里；恢复使用最新替换结果。
_Avoid_: 清空会话、删除日志
