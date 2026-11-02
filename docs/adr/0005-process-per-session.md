---
status: accepted
date: 2026-11-01
---

# 一个 Session 一个进程，不做共享守护进程

每个 Session 是一个独立的 `nib` 进程。不学 jcode 的"单个守护进程托管所有 Session、TUI 只是客户端"。但 Session 引擎（回合循环、Provider、Run、Session log）不依赖 TUI，只通过事件流与界面交互，以后若需要守护进程，引擎可以原样搬进去。

**为什么：** jcode 用守护进程省内存，主要省的是运行时：pi 每个 Session 约 80 MB，是因为每个都是一个 Node 进程（数字来自 jcode README 自己的基准测试，属于一手资料，但是 jcode 一方的测量）。Zig 进程本身就很轻，实测每个进程的开销已经和 jcode 在共享服务端里"每增加一个 Session"的开销同一量级，见下。一个 Session 一个进程，还带来天然的故障隔离：进程退出，操作系统就回收全部内存，也不需要 jcode `docs/SESSION_RUNTIME_OWNERSHIP.md` 里那一整套共享运行时的所有权机制（预留、执行租约、墓碑、过时事件隔离）。

**实测（2026-11-01，ReleaseFast，本机）：** 10 个 TUI 进程同时运行，各自和本地模拟服务器完成一轮对话后，空闲时 PSS 每个约 3.08 MB，合计 30.8 MB；RSS 每个约 6.5 MB。一次真实的 HTTPS 请求（到 api.deepseek.com，带 TLS）峰值 RSS 为 7.6 MB。对照：jcode README 公布第一个 Session 71.3 MB，之后每个约 3.3 MB（PSS）。

**局限：** 上述 TUI 测量没有走 TLS，历史只有一轮，也没有执行 Run；和 jcode 的测法、机器、负载都不同，只能比量级，不能逐项比较。

**放弃了什么：** 只有共享服务端才能直接做到的三件事：跨 Session 协作（通知文件变更、agent 之间发消息）、多个 Session 共用 MCP 这类昂贵的外部进程、关掉终端后正在进行的 Turn 继续跑。

**何时重新考虑：**
- 要做多 agent 协作。注意，这不一定意味着要上 jcode 式守护进程，一个只负责转发消息的轻量协调进程也可能够用；
- 接入了 MCP，而且每个 Session 各起一套 MCP 已经成了实际负担；
- 用户需要"关掉终端，任务继续跑"；
- 带 TLS、长历史、执行过 Run 的真实负载下，每个进程的 PSS 明显高于上面的量级。
