# TUI 任务管理与进展

`/tasks` 不调用模型，列出本进程在当前 Session 登记的后台 agent、bash 和自动转后台的 Run。每行显示 id、类型、状态、已运行时长、截止时间及简短描述；没有任务时显示一句提示。排队中的任务显示等待确定截止时间，开始执行后使用工具本身的 timeout；截止时间显示 UTC 时分秒和剩余秒数。detached 显示无截止时间（显式 timeout 仍由工具执行）。Run 没有墙钟截止时间，显示 `per-tool deadlines`，各工具原有截止时间继续生效。已完成任务的时长冻结，不会继续增加。

`/stop <id>` 在 Turn 运行时也立即受理。停止请求由 Session 线程处理，复用 tools.stop 的取消、join 和进程组清理，日志的 `task_stop` 记录理由 `user requested stop`；停止完成后提示可能留有部分改动。已完成任务返回 already finished，未知 id 显示错误。输入 `/stop ` 时，菜单按 id 前缀提供仍在运行的任务候选；无需让模型发起工具调用。切换 Session 后不再显示旧 Session 的任务；恢复不会重启进程。

原 Run 自动转后台后显示中性 `→ run background → r3`，结果条目携带 `source Run → r3`。bash 被取代时显示 `→ b1 superseded by b2`，状态树显示同一取代者。取代不代表验证通过或失败。恢复日志保留这些语义。
