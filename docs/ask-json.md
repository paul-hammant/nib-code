# ask 的 NDJSON 接口

`nib ask --json '<prompt>'` 的 stdout 是 NDJSON：每行一个单键对象，按产生顺序输出并立即 flush；stderr 没有人类可读进度或颜色。prompt 为 `-` 时从 stdin 读到 EOF（普通 ask 也支持）。退出码成功 0，失败非 0。

- `{"start":{"session_id":"<32位小写十六进制>"}}`：Session 已初始化；恢复时沿用原 id。
- `{"delta":{"kind":"text|reasoning","text":"..."}}`：模型流式片段，包含中间 Step 的文本。
- `{"run_start":"<JS代码>"}`、`{"run_end":{"ok":true,"output":"...","changes":[...]}}`：一次 Run 的开始和结果；Run 失败可由模型继续处理。`changes` 列出这次 Run 里 edit/write 改动的文件：`{"path","added","removed","created","diff"}`，与 Run 开始前的内容比较（改了又改回的文件不列出）；`diff` 是带一行上下文的 `+`/`-`/` ` 行，超过 200 行截断。bash 和子会话的改动不在其中。
- `{"progress":{"agent":1,"prompt":"检查测试","state":"working","step":3,"tools":["edit"],"files":["src/x.zig"],"usage":{"prompt_tokens":41000,"completion_tokens":200,"prompt_cache_hit_tokens":32000}}}`：当前 Run 内一个子 agent 的最新进度快照。`agent` 是本次 Run 内从 1 开始的注册编号（下次 Run 重置）；`prompt` 是完整子任务提示词；`state` 为 `queued|working|done|failed|canceled|timed_out`；`step` 从 1 开始，尚未收到模型活动时为 0；`tools` 是最近一次 `run_start` 代码中识别出的去重 `tools.<name>(...)` 调用名称，`files` 是该次 `run_end.changes` 的文件路径（新 Run 开始时清空）；`usage` 是这个子 agent 已报告的累计用量，显示 token 时取 prompt + completion，不重复加缓存 token。不是 token 增量，也不额外计入父会话用量。同一子 agent 的事件至少间隔一秒，中间状态合并为最新快照；整个 Run 结束时会丢弃尚未到发送时间的进度，因此不保证收到终态 progress，最终结果/用量仍以 `run_end` 和 `end/error` 为准。普通 ask 不显示此事件。
- `{"usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0}}`：本轮累计用量快照（含已报告的子会话用量），不是增量；用于中途显示与强制终止后的统计。
- `{"retry":{"attempt":1,"delay_ms":1000,"reason":"..."}}`、`{"notice":"..."}`：重试与通知。
- `{"end":{"text":"<最终回答>","usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0},"steps":1}}`：Turn 成功结束；usage 只统计本轮，含自动压缩和子会话。最终回答取这里的 text，不拼接所有 delta。
- `{"error":{"message":"...","usage":{"prompt_tokens":0,"completion_tokens":0,"prompt_cache_hit_tokens":0},"steps":0}}`：命令或 Turn 失败，没有 end；初始化失败时可能没有 start。usage/steps 保留失败前已报告的统计。错误文本供诊断，不作为稳定错误码。

`end` 和 `error` 还可带 `timing: {wall_ms, model_ms, run_ms, llm_calls, agent_calls}`。开始执行 Turn 后总会提供；命令解析或 Session 初始化失败、尚未开始 Turn 时省略。`wall_ms` 是整个 Turn 的单调墙钟耗时（含失败或取消前的等待、压缩和清理），`model_ms`、`run_ms` 分别是本轮已提交完整 Step 的同名日志字段之和，不包含未完成 Step；`llm_calls`、`agent_calls` 是这些 Step 内实际调度的宿主工具调用数，含返回错误的调用，不含子会话内部调用，不受日志 `calls` 的 200 条上限影响。计时单位为毫秒，计数为 0 时仍保留键。原有 `usage/steps` 口径不变，因此失败时可能包含未完成 Step 已报告的用量。普通 ask 不输出这组计时；Session 内部的 `turn_end` 快照不会作为额外 NDJSON 事件发出。

事件结构与序列化定义在 `src/session/events.zig`。字符串中的换行经过 JSON 转义，每个物理行都是完整 JSON。

会话提交与取消语义见 [session-log.md](session-log.md)，子会话调用约定见 [tool-delegation.md](tool-delegation.md)。
