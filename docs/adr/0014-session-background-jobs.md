# 0014 会话级后台 bash 与按 id 停止

## 决定

普通后台 bash/agent 保留等待语义。bash 增加 `background: true, detached: true`：任务由 Session 持有，跨 Run 和正常 Turn 存活，不阻塞最终回答和 Step 上限收尾；默认 `timeout_ms: 0`（无截止时间），仍受并发和输出上限约束。`tools.stop({id})` 取消并 join 一个后台 bash/agent，完成消息照常投递一次；已结束任务返回 `stopped:false`，未知 id reject。

任务沿用会话级独立计数器 `a1…` / `b1…`，与前台和 `/js` 共用，恢复时延续日志高水位，不重启进程。树中运行中的 detached 任务显示 `detached`，终态和结果条目沿用已有格式。

完成只入 inbox，在下一次 Step 前投递，空闲时不自动发起 Turn。启动和 stop 是普通工具调用，走统一结算与录制；结果消息字节计入接收它的 Step 的 output_bytes。Turn 取消/失败、Session 退出/切换清理全部任务；ask 返回后退出 Session，也会清理。

detached 任务的生命周期就是其 shell 进程的生命周期。所有 bash 在 shell 退出时（包括成功退出）清理整个进程组并交付结果，`nohup/&` 不绕过清理；detached 服务在命令内前台运行。stop、超时、Turn 取消/失败、Session 退出也会清理进程组。等待使用标准库子进程接口，不扫描进程表、不延后回收组长。stop 等到 agent 的执行占用释放后返回，并保留任务 id 与子会话的对应关系供续用。

## 理由

Issue #32 的服务和 watch 需要跨 Turn 的资源所有权，不是绕过取消。直接让所有后台任务不等待，会改变有限委派的语义，并在 ask 返回时提前取消它们。显式 detached 复用现有任务 id、并发限额、进程组执行器与 inbox，不增加空闲自动请求模型的策略或 pid 接口。

## 何时重新考虑

需要空闲时查看输出、用户级任务列表、可交互子会话或跨 nib 进程保活时，再考虑独立查询/等待协议或服务管理；detached 不暗示这些能力。
