---
status: accepted
date: 2026-11-01
---

# Run 内工具调用真正并发，顺序按 JS 语义

宿主函数立即返回一个 Promise，实际工作在线程上执行，完成后回到 Run 所在的线程 resolve（QuickJS 不是线程安全的）。执行顺序完全由脚本决定：`Promise.all` 就并行，依次 `await` 就串行。唯一的额外规则：对同一路径的 `edit` / `write` 按路径加锁。

**为什么：** 现在工具调用同步执行，`Promise.all` 结果正确但不并发。子 agent（[0010](0010-subagents.md)）要靠并行分派才有价值，并发是它的前提。顺序已经由代码表达，不需要再加规则。

**被否决的方案：** DeepSeek Harness 的规则：只读操作并行，有副作用的操作按提交顺序串行（**二手**：第三方博客，未核实）。它让 `Promise.all` 的语义因工具而异，模型需要额外记住一条规则。

**实现选择：** 每个 Run 最多 8 个工具工作线程，超出的调用留在 Run 队列；完成结果进入互斥锁保护的队列，Run 线程独自调用 QuickJS。没有 pending job 时最多等待 20 ms，再检查取消；等待工具的时间不消耗 JS 执行预算。停止时设置 `Tools.cancel`，已完成调用立即回收数据；停止时先 join 全部剩余线程，再释放调用数据和 QuickJS。路径锁覆盖 edit/write 的完整操作，已有路径解析符号链接，尚不存在的路径由最近存在的父目录规范化；不约束 bash 或其他进程的文件写入。

bash 的进程组启动、限时输出轮询、取消和回收移入 `src/tools/process.zig`，供后续子 agent 复用。调整了旧实现的一个漏洞：输出 EOF 后仍继续轮询进程退出，关闭输出的命令也能取消和超时。

**把握程度：** 实测（2026-11-01，本机 Debug，`src/tools.zig` 测试）：两个 `sleep 0.3`，Promise.all 为 307 ms，依次 await 为 611 ms。50 项单元测试通过，覆盖 JS 异常、12 个调用执行期间取消/超时、16 个同路径并行 edit、悬空符号链接别名和 EOF 后超时；Session 端到端测试通过。一手源码（同日，Zig 0.17 `std/process.zig`、`std/start.zig`）：Init.gpa 明确保证线程安全；Debug/ReleaseSafe 使用 SafeAllocator，本项目链接 libc 的 ReleaseFast/Small 使用 c_allocator。

后续验证（同日）：Debug/ReleaseFast 均通过 53 项单元测试与端到端测试；ReleaseFast 暴露并修正了工具 JSON 缓冲的零结尾要求（一手源码：QuickJS `quickjs.h` 的 `JS_ParseJSON` 声明）。

**超时边界（2026-11-02）：** 用户提供的真实任务中，子 agent 正常工作到 5 分钟却被 Run 总时限停止，留下未完成文件。Run 时限的目的是中断 JS 死循环，不是再次限制已有独立超时的工具，因此改为累计 QuickJS 执行片段的纳秒耗时：初始脚本、pending jobs、工具结果解析/resolve、返回值序列化和错误转换（getter/toString 也可能运行 JS）。等待完成队列时预算暂停，恢复执行时继续扣除，不能每次 await 都重置；取消检查独立于预算。这里计量的是执行片段的单调墙钟时间，不是操作系统线程 CPU 时间。

实测（同日，本地单元测试）：Run 预算 100 ms，依次 await 两个 sleep 0.3 的 bash 正常返回；跨 await 的两段 60 ms JS 忙循环仍触发累计超时；纯死循环、超时后清理运行中/排队工具、等待超过预算后取消均有覆盖。写脚本的说明也改为优先原生搜索工具、用 JSON 转义双引号字符串承载文件/命令文本；工具表中的特殊字符示例在 sandbox 中真实 write 后逐字节验证，避免 String.raw 仍解析反引号和插值的陷阱。

**何时重新考虑：**
- 观察到模型在 `Promise.all` 里并行做了互相依赖的副作用操作并因此出错。
