---
status: accepted
date: 2026-11-01
---

# 子 agent：tools.agent 派生一个独立的 nib 子进程

Run 里可以调用 `await tools.agent({ prompt, resume, timeout_ms: 1800000, model, effort, background: false })`；resume 为可选字符串，可省略以新建子会话，传入时使用当前父会话的 agent 任务 id，如 `a1`，timeout_ms 默认 30 分钟。仅新建时分配任务 id；接续沿用原任务 id，不分配新 id。每次调用仍启动一个独立的 `nib` 子进程，跑完一个完整 Turn。前台成功返回 `{ ok: true, id, text, usage, changes }`，子会话失败返回 `{ ok: false, id, error, text, usage, changes }`；id 是任务 id，接续时沿用原 id。只有参数错误和用户取消仍 reject，单个子会话失败不取消同一 Run 的其他任务。model/effort 省略时继承父会话当前有效配置，接续时也不沿用子会话上次覆盖值；覆盖只影响本次子调用且不切换 provider，effort 沿用现有校验与映射，语义同 tools.llm。接续仍遵守 provider 一致、Codex 模型一致的恢复约束。父子之间通过 `nib ask --json` 的 NDJSON 事件流通信。新建不继承父会话历史，接续保留子会话已有历史与原始 system。成功登记后台任务后返回 `{ id }`，完成消息含同一 id、不含 usage；接续 `a1` 的前台结果、后台启动和完成、progress 事件及 TUI tree 均沿用 `a1`；返回值、错误诊断和后台结果均不向模型暴露内部子会话 ID，见 [tool-delegation.md](../tool-delegation.md)。

**接续与互斥：** 父会话日志持久化任务 id 到内部子会话 ID 的映射；resume 解析当前父会话已有 agent 任务的映射，再用新进程执行 `nib ask --resume <内部子会话 ID>`，不是保留常驻 worker。不存在的任务、非本会话 agent（包括非 agent 任务）或没有映射的任务均返回 `ok:false`，不 reject、不登记后台任务；传入内部子会话 ID 也不能接续。仅允许接续日志 `parent_session_id` 等于当前父会话 id 的子会话；父会话恢复后重建映射，仍可接续原有子会话。根会话或其他父会话的子会话不能接续，返回 `ok:false`。执行阶段先预留目标 agent，再等待并发槽；同一 agent 一次只允许一个在途调用（含排队、前台和后台），busy 时立即返回 `ok:false`，不排队、不登记后台任务、不分配新 id。预留在完成、失败、取消时释放，前台和后台共用。日志独占锁另外防止跨进程同时接续，包括 CLI。失败、超时和取消保留已有映射，日志可恢复的子会话仍可接续；新建任务在取得内部子会话 ID 前失败则没有可接续映射。usage/changes 仅涵盖本次调用，不累计已有历史。停止不回滚文件，中断前的改动不保证全部记录在日志或 changes 中。

**为什么：** 代码驱动最有价值的能力之一是把工作分出去并行做，例如 `Promise.all(tasks.map(t => tools.agent({ prompt: t })))`。用子进程而不是线程，和 [0005](0005-process-per-session.md) 一致：故障隔离、退出即回收内存、取消复用进程组终止；Zig 进程启动只要毫秒级。返回最终结果而不是常驻加消息，概念最少，并且与 JS 的 `await` / `Promise.all` 天然契合。

**实现选择：** 深度上限 1，`NIB_AGENT_DEPTH` 传给子进程；工具表按深度同时生成说明和 JS API，子会话完全不暴露 agent。同时最多运行 4 个子 agent，超出排队（全部工具上限 8）。用当前可执行文件启动 `nib ask --json -`，prompt 与有效 provider 配置通过 stdin JSON 发送，子进程跳过配置文件读取，避免文件变化导致配置漂移、命令行长度限制和密钥环境继承（见 [0011](0011-provider-wire-protocols.md)）；共用 `src/tools/process.zig` 的进程组、20 ms 轮询、超时和回收，stdin 写入也受取消/超时约束。

**实施时的调整与理由：**
- 嵌套进程组不会随外层组自动被杀。父进程先给子 nib 的组发 SIGTERM，子 nib 取消自己的工具组；500 ms 后再 SIGKILL。仍在阻塞 HTTP 的子 nib 也能被强制回收。
- 在原先的开始/结束/错误事件之外，增加累计 `usage` 事件；错误事件也带 usage/steps。子会话卡在网络中被杀时，父会话仍能计入此前已报告的用量；无法推知服务端尚未报告的 token。
- 子会话日志首条记录写 `parent_session_id`。普通 `--continue` 跳过子会话，防止中断后误接续委派任务；显式恢复子会话保留深度限制。

运行中逐行收集 NDJSON，返回本次调用已收到的 text、usage 和本次所有 Run 的 changes；changes 按路径累加 added/removed、created 取逻辑或，不含 diff，只覆盖 edit/write，不覆盖 bash，也不是起止文件的净 diff。共用执行器的 8 MiB 输出上限，子会话独立的 timeout_ms 默认 30 分钟，从进程执行阶段计时，不含并发槽排队。Run 等待子会话时不消耗 JS 执行预算（见 [0009](0009-concurrent-tools.md)）。父 Turn 累计子会话成功、失败及取消前已报告的用量，CLI 和 TUI 使用同一累计值。父子共享 cwd 和文件系统，不共享父会话历史；文件工具通过共享 NIB_HOME 的规范路径 advisory lock 协调独立进程和子会话，bash 不参与该锁，边界见 [run-output.md](../run-output.md#文件替换会话版本与跨进程协调)。

**超时诊断与任务边界（2026-11-02）：** 用户报告真实子任务被旧 5 分钟限制停止并留下半成品；统一总时限既误杀合法任务，也掩盖停止原因。改为每次委派显式可配时限，默认 30 分钟，保留 SIGTERM → 500 ms 宽限 → SIGKILL。父进程从任务映射或 start 事件保留内部子会话 ID；面向模型的超时错误给出实际耗时（含宽限）、配置时限、任务 id 和文件可能不完整的诊断，不暴露内部子会话 ID。若新建调用在 start 事件前就停止、尚未取得内部子会话 ID，则没有可接续映射；强杀产生的不完整 NDJSON 尾行不覆盖超时诊断，已完整收到的 usage 仍累计。

ask 的信号处理记录收到的信号：SIGTERM 的日志标记为 `[interrupted: process terminated]`，SIGINT 和 TUI Esc 仍为 `[interrupted by user]`，不再把父进程停止误记为用户主动取消。子会话看不到彼此历史，缺少跨文件协调，相互依赖的修改可能产生不兼容的实现。停止不回滚文件，更长的默认时限也不保证任务完成。

实测（同日，本地 mock）：1600 ms 的显式委派超时覆盖运行中 bash 的清理、半成品文件提醒、实际耗时/id、卡住 HTTP 后强杀及已报告用量保留；SIGINT/SIGTERM 流式中断的不同标记和恢复均通过。未实际等待默认的 30 分钟。

**被否决的方案：**
- 同进程线程：省一次 TLS 握手、共享连接，但要处理线程安全，一个子 agent 崩溃会带崩父会话。
- 常驻子 agent 加消息（prime-agent 的 `rlm.spawn` + `agent_message`，一手：本地源码 `pa-core/src/prompts/layers/core.md`）：更强，但要引入句柄、消息路由和生命周期。

**依赖：** [0009](0009-concurrent-tools.md) 的工具并发；`nib ask --json`。

**把握程度：** 实测（2026-11-01，本机 Debug，`tests/test_session.py` + `mock_llm.py`）：两个含 `sleep 0.3` 的子会话，首个请求至第二个请求的并行跨度 552.7 ms，各自耗时合计 1104.6 ms；父 Turn 输入用量 6600 → 19800、输出 30 → 90。6 个子会话分两批运行，最多 4 个；深度过滤、结果、日志关联、失败用量、取消中正在运行的 bash、卡住 HTTP 后的强杀用量及恢复行为均通过检查。Debug/ReleaseFast 的 53 项单元测试和 Session 端到端测试通过。

子进程启动至 start 事件（10 次，含 Session 日志同步，不含模型请求/TLS）：Debug 中位数 11.82 ms，范围 8.82–19.83 ms；ReleaseFast 中位数 1.30 ms，范围 0.85–1.48 ms。测量脚本采用相同的当前可执行文件、stdin 和深度环境变量。路径锁、深度及取消均不提供系统层隔离；父进程直接被 SIGKILL 时无法执行清理。真实 HTTPS 握手尚未测量，不能把本地 HTTP 测量当成真实模型延迟。

**真实 API 验证（2026-11-01，`deepseek-flash`，ReleaseFast）：** 任务是"派两个子 agent 并行：一个总结 src/js.zig 的并发设计，一个总结 src/tools.zig 的工具表设计，最后合并成一段话"。
- 模型自己在一段脚本里写出 `Promise.all([tools.agent(...), tools.agent(...)])`，并把两个结果整理成结构化对象返回，父会话只用 2 个 Step。
- 用量：整个 Turn 输入 46,283 token（缓存命中 25,216，约 54%），输出 2,472。两个子 agent 输入 19,607 + 21,349，约占 89%，主要花在读入 18–28 KB 的源文件并在多个 Step 中重复携带。按 flash 价格不到 1 美分。
- 结果质量：抽查代码确认了 20 ms 等待、`root_only` 与 `makeApi(depth)` 过滤、16 KB 截断、当时的 5 分钟超时（现已由上述独立时限取代）等说法；有一处错误（把 "still awaiting something that can never settle" 说成"仍在校验中"类错误），父会话没有发现。子 agent 的结果可用，但不是不会错。
- 观察到的缺口：`nib ask` 在子 agent 运行期间没有进度显示（开始/结束、步数、token），长任务时用户无法知道发生了什么。

**何时重新考虑：**
- 出现子 agent 需要在中途与父会话交流的真实任务：考虑常驻子 agent 加消息；
- 子进程的启动加握手开销在实测中占比明显：考虑同进程方案或连接复用。
