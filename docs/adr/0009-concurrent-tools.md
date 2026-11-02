---
status: accepted
date: 2026-11-01
---

# Run 内工具调用真正并发，顺序按 JS 语义

宿主函数立即返回一个 Promise，实际工作在线程上执行，完成后回到 Run 所在的线程 resolve（QuickJS 不是线程安全的）。执行顺序完全由脚本决定：`Promise.all` 就并行，依次 `await` 就串行。唯一的额外规则：对同一路径的 `edit` / `write` 按路径加锁。

**为什么：** 现在工具调用同步执行，`Promise.all` 结果正确但不并发。子 agent（[0010](0010-subagents.md)）要靠并行分派才有价值，并发是它的前提。顺序已经由代码表达，不需要再加规则。

**被否决的方案：** DeepSeek Harness 的规则：只读操作并行，有副作用的操作按提交顺序串行（**二手**：第三方博客，未核实）。它让 `Promise.all` 的语义因工具而异，模型需要额外记住一条规则。

**实现选择：** 每个 Run 最多 8 个工具工作线程，超出的调用留在 Run 队列；完成结果进入互斥锁保护的队列，Run 线程独自调用 QuickJS。没有 pending job 时最多等待 20 ms，再检查取消和截止时间。停止时设置 `Tools.cancel`，已完成调用立即回收数据；停止时先 join 全部剩余线程，再释放调用数据和 QuickJS。路径锁覆盖 edit/write 的完整操作，已有路径解析符号链接，尚不存在的路径由最近存在的父目录规范化；不约束 bash 或其他进程的文件写入。

bash 的进程组启动、限时输出轮询、取消和回收移入 `src/process.zig`，供后续子 agent 复用。调整了旧实现的一个漏洞：输出 EOF 后仍继续轮询进程退出，关闭输出的命令也能取消和超时。

**把握程度：** 实测（2026-11-01，本机 Debug，`src/tools.zig` 测试）：两个 `sleep 0.3`，Promise.all 为 307 ms，依次 await 为 611 ms。50 项单元测试通过，覆盖 JS 异常、12 个调用执行期间取消/超时、16 个同路径并行 edit、悬空符号链接别名和 EOF 后超时；Session 端到端测试通过。一手源码（同日，Zig 0.17 `std/process.zig`、`std/start.zig`）：Init.gpa 明确保证线程安全；Debug/ReleaseSafe 使用 SafeAllocator，本项目链接 libc 的 ReleaseFast/Small 使用 c_allocator。

后续验证（同日）：Debug/ReleaseFast 均通过 53 项单元测试与端到端测试；ReleaseFast 暴露并修正了工具 JSON 缓冲的零结尾要求（一手源码：QuickJS `quickjs.h` 的 `JS_ParseJSON` 声明）。

**何时重新考虑：**
- 观察到模型在 `Promise.all` 里并行做了互相依赖的副作用操作并因此出错。
