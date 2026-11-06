# TUI 任务管理与进展

`/tasks` 不调用模型，列出本进程在当前 Session 登记的后台 agent、bash 和自动转后台的 Run。每行显示 id、类型、状态、已运行时长、截止时间及简短描述；没有任务时显示一句提示。排队中的任务显示等待确定截止时间，开始执行后使用工具本身的 timeout；截止时间显示 UTC 时分秒和剩余秒数。detached 显示无截止时间（显式 timeout 仍由工具执行）。Run 没有墙钟截止时间，显示 `per-tool deadlines`，各工具原有截止时间继续生效。已完成任务的时长冻结，不会继续增加。

`/stop <id>` 在 Turn 运行时也立即受理。停止请求由 Session 线程处理，复用 tools.stop 的取消、join 和进程组清理，日志的 `task_stop` 记录理由 `user requested stop`；停止完成后提示可能留有部分改动。已完成任务返回 already finished，未知 id 显示错误。输入 `/stop ` 时，菜单按 id 前缀提供仍在运行的任务候选；无需让模型发起工具调用。切换 Session 后不再显示旧 Session 的任务；恢复不会重启进程。

原 Run 自动转后台后显示中性 `→ run background → r3`，结果条目携带 `source Run → r3`。bash 被取代时显示 `→ b1 superseded by b2`，状态树显示同一取代者。取代不代表验证通过或失败。恢复日志保留这些语义。

活动行按阶段显示 `waiting model`（等待模型）、`model output`（推理或正文）、`generating run`（工具参数增量）、`tools bash zig build test`（工具执行）、`waiting tasks r3 32s`（本地等待后台结果），以及整个 Turn 的累计秒数。只有有内容的推理、文本、工具参数和工具状态/输出进度会更新最后活动；网络心跳、metadata、usage 和单纯经过的时间都不重置它。超过 30 秒无进展显示 `no progress Ns`，不预测 ETA。窄屏从右往左去掉字段，仍为单行；工具名过长时按完整字素截断。

Turn 失败或取消后，在账单之后显示一行恢复提示：原因类别（模型连接/请求、工具/脚本、超时、用户取消，或 Step 上限）、本轮直接 edit/write 修改过的文件，以及 `type 继续 to continue`。路径按首次修改去重，包括尚未交回 Run 结果的写入；不把子 agent 的修改当作根 Session 的直接修改。若运行过 bash，会注明 `bash changes untracked`，不猜测 shell 改动了什么；没有记录时明确显示 `no recorded edit/write changes`。取消不会回滚文件，下一次普通输入继续沿用 Session 上下文。

恢复提示仅由 TUI 生成，不进入模型历史；`nib ask`（包括非 TTY 和 NDJSON）不增加恢复提示，保留原来的输出通道和退出码，便于脚本继续解析。`run_end` 新增可选 `background_id` 用于关联自动后台 Run；NDJSON 的事件结构仍保持原格式。
