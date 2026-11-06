# TUI 任务管理与进展

`/tasks` 不调用模型，列出本进程在当前 Session 登记的后台 agent、bash 和自动转后台的 Run。每行显示 id、类型、状态、已运行时长、截止时间及简短描述；没有任务时显示一句提示。排队中的任务显示等待确定截止时间，开始执行后使用工具本身的 timeout；截止时间显示 UTC 时分秒和剩余秒数。detached 显示无截止时间（显式 timeout 仍由工具执行）。Run 没有墙钟截止时间，显示 `per-tool deadlines`，各工具原有截止时间继续生效。已完成任务的时长冻结，不会继续增加。

`/stop <id>` 在 Turn 运行时也立即受理。停止请求由 Session 线程处理，复用 tools.stop 的取消、join 和进程组清理，日志的 `task_stop` 记录理由 `user requested stop`；停止完成后提示可能留有部分改动。已完成任务返回 already finished，未知 id 显示错误。输入 `/stop ` 时，菜单按 id 前缀提供仍在运行的任务候选；无需让模型发起工具调用。切换 Session 后不再显示旧 Session 的任务；恢复不会重启进程。

Run 始终保留父标题。自动转后台时显示 `Run · r3 running`；结束后把改动、工具摘要和结果更新回原块。bash 被取代时显示 `b1 superseded by b2`，取代不代表验证通过或失败。父标题会提示子任务失败或超时，但不改变脚本的返回值。Ctrl+O 依次展开 Changes / Result / Script；结果全文可滚动查看，长 diff 标注 `Diff preview · 60 of … lines`。

活动行显示已知阶段：`Waiting for model`、`Generating response`、`Writing Run`、`Running bash zig build test`、`Waiting for r3 · 32s`，并保留整个 Turn 的累计时间。只有有内容的推理、文本、工具参数和工具状态/输出进度会更新最后活动；网络心跳、metadata、usage 和单纯经过的时间都不重置它。超过 30 秒无进展显示 `no progress 30s`，不预测 ETA。窄屏从右往左去掉字段，仍为单行。

重试显示 `Retrying · attempt 2/5 · rate limit`，移除失败尝试的流式草稿，保留此前成功的回答和排队插话。最终错误用一句说明加 Details，Ctrl+O 查看原始错误。取消仅显示一次恢复提示；未消费的排队消息回到输入框，已有草稿仍保留，并显示返回的消息数。

Turn 失败或取消后显示本轮直接 edit/write 修改的文件及 `type continue to resume`，有直接修改时另提示 `/undo to revert edit/write`。路径按首次修改去重，包括尚未交回 Run 结果的写入；不把子 agent 的修改当作根 Session 的直接修改。若运行过 bash，会注明 `bash changes untracked`；没有记录时显示 `no recorded edit/write changes`。取消不会回滚文件，下一次普通输入继续沿用 Session 上下文。

恢复提示仅由 TUI 生成，不进入模型历史；`nib ask`（包括非 TTY 和 NDJSON）不增加恢复提示，保留原来的输出通道和退出码，便于脚本继续解析。`run_end` 新增可选 `background_id` 用于关联自动后台 Run；NDJSON 的事件结构仍保持原格式。

底栏只显示模型和已有用量报告对应的 context 百分比；首次启动只显示模型。轮末页脚显示非零的 Run 数、步数、总时间、tokens 和工具数据量，详细模型/Run 耗时与缓存放在 `/status`（本地命令，运行时也可查看）。

用户消息使用 `›` 前缀、蓝色色条和按终端背景色生成的淡底色，兼容明暗主题。拖选时按住左键滚动可跨屏延伸，松开复制完整历史范围，包含滚出屏幕的行；选择期间暂停底部跟随。`/undo` 的范围与冲突处理见 [undo.md](undo.md)。
