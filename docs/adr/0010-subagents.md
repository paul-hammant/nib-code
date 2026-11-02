---
status: accepted
date: 2026-11-01
---

# 子 agent：tools.agent 派生一个独立的 nib 子进程

Run 里可以调用 `await tools.agent({ prompt })`。每个子 agent 是一个独立的 `nib` 子进程，跑完一个完整 Turn，返回 `{ text, usage }`。父子之间通过 `nib ask --json` 的 NDJSON 事件流通信。上下文只通过 `prompt` 传递；更多数据由 JS 拼进 prompt，或写成文件后把路径告诉子 agent。

**为什么：** 代码驱动最有价值的能力之一是把工作分出去并行做，例如 `Promise.all(tasks.map(t => tools.agent({ prompt: t })))`。用子进程而不是线程，和 [0005](0005-process-per-session.md) 一致：故障隔离、退出即回收内存、取消复用进程组终止；Zig 进程启动只要毫秒级。返回最终结果而不是常驻加消息，概念最少，并且与 JS 的 `await` / `Promise.all` 天然契合。

**实现选择：** 深度上限 1，`NIB_AGENT_DEPTH` 传给子进程；工具表按深度同时生成说明和 JS API，子会话完全不暴露 agent。同时最多运行 4 个子 agent，超出排队（全部工具上限 8）。用当前可执行文件启动 `nib ask --json -`，prompt 与有效 provider 配置通过 stdin JSON 发送，避免命令行长度限制和密钥环境继承（见 [0011](0011-provider-wire-protocols.md)）；共用 `src/process.zig` 的进程组、20 ms 轮询、超时和回收，stdin 写入也受取消/超时约束。

**实施时的调整与理由：**
- 嵌套进程组不会随外层组自动被杀。父进程先给子 nib 的组发 SIGTERM，子 nib 取消自己的工具组；500 ms 后再 SIGKILL。仍在阻塞 HTTP 的子 nib 也能被强制回收。
- 在原先的开始/结束/错误事件之外，增加累计 `usage` 事件；错误事件也带 usage/steps。子会话卡在网络中被杀时，父会话仍能计入此前已报告的用量；无法推知服务端尚未报告的 token。
- 子会话日志首条记录写 `parent_session_id`。普通 `--continue` 跳过子会话，防止中断后误接续委派任务；显式恢复子会话保留深度限制。

子会话结束后解析其 NDJSON，返回最终 text 和 usage；共用执行器的 8 MiB 输出上限，子会话时限随 Run 为 5 分钟。父 Turn 累计子会话成功、失败及取消前已报告的用量，CLI 和 TUI 使用同一累计值。父子共享 cwd 和文件系统，不共享历史；路径锁限于各自进程，不协调跨会话写入。

**被否决的方案：**
- 同进程线程：省一次 TLS 握手、共享连接，但要处理线程安全，一个子 agent 崩溃会带崩父会话。
- 常驻子 agent 加消息（prime-agent 的 `rlm.spawn` + `agent_message`，一手：本地源码 `pa-core/src/prompts/layers/core.md`）：更强，但要引入句柄、消息路由和生命周期。

**依赖：** [0009](0009-concurrent-tools.md) 的工具并发；`nib ask --json`。

**把握程度：** 实测（2026-11-01，本机 Debug，`scripts/test_session.py` + `mock_llm.py`）：两个含 `sleep 0.3` 的子会话，首个请求至第二个请求的并行跨度 552.7 ms，各自耗时合计 1104.6 ms；父 Turn 输入用量 6600 → 19800、输出 30 → 90。6 个子会话分两批运行，最多 4 个；深度过滤、结果、日志关联、失败用量、取消中正在运行的 bash、卡住 HTTP 后的强杀用量及恢复行为均通过检查。Debug/ReleaseFast 的 53 项单元测试和 Session 端到端测试通过。

子进程启动至 start 事件（10 次，含 Session 日志同步，不含模型请求/TLS）：Debug 中位数 11.82 ms，范围 8.82–19.83 ms；ReleaseFast 中位数 1.30 ms，范围 0.85–1.48 ms。测量脚本采用相同的当前可执行文件、stdin 和深度环境变量。路径锁、深度及取消均不提供系统层隔离；父进程直接被 SIGKILL 时无法执行清理。真实 HTTPS 握手尚未测量，不能把本地 HTTP 测量当成真实模型延迟。

**真实 API 验证（2026-11-01，`deepseek-flash`，ReleaseFast）：** 任务是"派两个子 agent 并行：一个总结 src/js.zig 的并发设计，一个总结 src/tools.zig 的工具表设计，最后合并成一段话"。
- 模型自己在一段脚本里写出 `Promise.all([tools.agent(...), tools.agent(...)])`，并把两个结果整理成结构化对象返回，父会话只用 2 个 Step。
- 用量：整个 Turn 输入 46,283 token（缓存命中 25,216，约 54%），输出 2,472。两个子 agent 输入 19,607 + 21,349，约占 89%，主要花在读入 18–28 KB 的源文件并在多个 Step 中重复携带。按 flash 价格不到 1 美分。
- 结果质量：抽查代码确认了 20 ms 等待、`root_only` 与 `makeApi(depth)` 过滤、16 KB 截断、5 分钟超时等说法；有一处错误（把 "still awaiting something that can never settle" 说成"仍在校验中"类错误），父会话没有发现。子 agent 的结果可用，但不是不会错。
- 观察到的缺口：`nib ask` 在子 agent 运行期间没有进度显示（开始/结束、步数、token），长任务时用户无法知道发生了什么。

**何时重新考虑：**
- 出现子 agent 需要在中途与父会话交流的真实任务：考虑常驻子 agent 加消息；
- 子进程的启动加握手开销在实测中占比明显：考虑同进程方案或连接复用。
