---
status: proposed
date: 2026-11-01
---

# 子 agent：tools.agent 派生一个独立的 nib 子进程

Run 里可以调用 `await tools.agent({ prompt })`。每个子 agent 是一个独立的 `nib` 子进程，跑完一个完整 Turn，返回 `{ text, usage }`。父子之间通过 `nib ask --json` 的 NDJSON 事件流通信。上下文只通过 `prompt` 传递；更多数据由 JS 拼进 prompt，或写成文件后把路径告诉子 agent。

**为什么：** 代码驱动最有价值的能力之一是把工作分出去并行做，例如 `Promise.all(tasks.map(t => tools.agent({ prompt: t })))`。用子进程而不是线程，和 [0005](0005-process-per-session.md) 一致：故障隔离、退出即回收内存、取消复用进程组终止；Zig 进程启动只要毫秒级。返回最终结果而不是常驻加消息，概念最少，并且与 JS 的 `await` / `Promise.all` 天然契合。

**防止失控：** 默认递归深度 1（只有根会话能派生）；同时运行的子 agent 数量有上限；子 agent 的用量计入父 Turn；子 agent 的 Session log 记录父会话 id。

**被否决的方案：**
- 同进程线程：省一次 TLS 握手、共享连接，但要处理线程安全，一个子 agent 崩溃会带崩父会话。
- 常驻子 agent 加消息（prime-agent 的 `rlm.spawn` + `agent_message`，一手：本地源码 `pa-core/src/prompts/layers/core.md`）：更强，但要引入句柄、消息路由和生命周期。

**依赖：** [0009](0009-concurrent-tools.md) 的工具并发；`nib ask --json`。

**把握程度：** 推测，未实测。深度和并发上限的具体数值、每个子进程一次 TLS 握手的实际开销，实现时再测。

**何时重新考虑：**
- 出现子 agent 需要在中途与父会话交流的真实任务：考虑常驻子 agent 加消息；
- 子进程的启动加握手开销在实测中占比明显：考虑同进程方案或连接复用。
