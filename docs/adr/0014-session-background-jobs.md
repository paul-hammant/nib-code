# 0014 会话级后台任务与按 id 停止

## 决定

普通后台 bash/agent 保留等待语义。bash 增加 `background: true, detached: true`：任务由 Session 持有，跨 Run 和正常 Turn 存活，不阻塞最终回答和 Step 上限收尾；默认 `timeout_ms: 0`（无截止时间），仍受并发和输出上限约束。`tools.stop({id,reason})` 取消并 join 一个后台 bash/agent，完成消息照常投递一次；已结束任务返回 `stopped:false`，未知 id reject。reason 必须非空白，否则 reject 且保留任务；实际停止时返回 notice，提醒取消未完成测试不能取得通过结果。

任务沿用会话级独立计数器 `a1…` / `b1…`，与前台和 `/js` 共用，恢复时延续日志高水位，不重启进程。树中运行中的 detached 任务显示 `detached`，终态和结果条目沿用已有格式。

完成只入 inbox，在下一次 Step 前投递，空闲时不自动发起 Turn。启动和 stop 是普通工具调用，走统一结算与录制；结果消息字节计入接收它的 Step 的 output_bytes。Turn 取消/失败、Session 退出/切换清理全部任务；ask 返回后退出 Session，也会清理。

detached 任务的生命周期就是其 shell 进程的生命周期。所有 bash 在 shell 退出时（包括成功退出）清理整个进程组并交付结果，`nohup/&` 不绕过清理；detached 服务在命令内前台运行。stop、超时、Turn 取消/失败、Session 退出也会清理进程组。等待使用标准库子进程接口，不扫描进程表、不延后回收组长。stop 等到 agent 的执行占用释放后返回，并保留任务 id 与子会话的对应关系供续用。

## 理由

本地正式批次出现模型反复取消自己的后台任务、验证始终未完成的问题。对所有显式 stop 要求理由，避免依赖命令名猜测哪些是验证任务；仍允许用户要求、具体失败或需求变化时停止。宿主只校验理由非空白，不审查自然语言含义；仅时间长、没有输出不证明进程卡住。

Issue #32 的服务和 watch 需要跨 Turn 的资源所有权，不是绕过取消。直接让所有后台任务不等待，会改变有限委派的语义，并在 ask 返回时提前取消它们。显式 detached 复用现有任务 id、并发限额、进程组执行器与 inbox，不增加空闲自动请求模型的策略或 pid 接口。

## 何时重新考虑

需要空闲时查看输出、用户级任务列表、可交互子会话或跨 nib 进程保活时，再考虑独立查询/等待协议或服务管理；detached 不暗示这些能力。

## 扩展：长 Run 自动转后台

模型很少主动为长命令设置 background，前台等待会失去与模型推理重叠的机会。采用整个 Sandbox Run 转后台，而不是改变已 await 的 bash 返回对象：达到可配置墙钟阈值且在等工具时先提交通知，原脚本继续，最终输出经同一个格式化器入 inbox。分配独立 r ID，非 detached，复用后台生命周期、取消与 Turn 收尾规则。每个 Run 独立拥有取消、changes、llm 调用计数、计时与录制缓冲，避免后续 Run 重置它们；共享的文件观察状态仅提供原有单次操作保护。

没有独立工作时，无工具回复或成功但无输出、无宿主调用的空 Run 使 Session 在本地等结果；waiting 标记只存在本地历史。保持有输出的纯 JS 计算正常继续，避免把有用工作误当作轮询。停止单条旧 bash 的取代机制另见 [0016](0016-superseded-bash.md)，不改变 Run 的 continuation 或其他工具。

Run 的执行线程只操作它自己的沙箱和原生工具；Session 主线程负责登记、轮询、事件投递和历史提交。calls 录制按完成顺序原子追加整个 Run 的缓冲，恢复不能再假定 Step 有序；SHA-256 跨 Run 引用只允许引用不晚于当前 Step 的已写入数据，防止恢复删除未提交的后续 Step 后留下悬空引用。完整语义见 [run-output.md](../run-output.md#长-run-自动转后台) 和 [session-log.md](../session-log.md#自动后台-run-的记录与统计)。
