# tools.llm 与 tools.agent：调用与实现

少量文件直接 read 最便宜。大量数据的单步判断、分类、抽取适合 llm，通常几秒；批量简单判断优先低成本模型和低 effort，强模型留给少量难题。agent 用于独立多步工作：几十行以上改动的提交前只读审查、先约定接口并划分负责文件的并行实现、需要大量读代码的调查；每个子会话从零读代码，常消耗几千到几万 token、几十秒以上，不代替 read 或 llm。延迟与成本是量级提示，不是保证。

## 接口与限额

Run 中可调用 `await tools.llm({ prompt, input, schema, model, effort })`，返回 `{ text, data, usage }`，用于批量判断、分类和抽取；要执行操作或多步调查则用 `tools.agent`。prompt 必填，input 可省略；字符串原样传入，其他可 JSON 序列化值按 JSON 编码，与 prompt 分开，不继承会话历史、项目 AGENTS.md 或 nib system。model/effort 默认跟随有效配置，覆盖只影响本次调用。宿主在当前进程代发一次无工具请求，凭证不进入 JS；子 agent 也可用 llm。schema 可选对象：Codex 用 strict json_schema，Chat Completions 用 json_object 加提示约束；schema 仍受服务端支持的子集限制（如 Codex strict 对象的 additionalProperties:false / required）；宿主只验证合法 JSON，不做完整 schema 校验，返回解析后的 data（无 schema 时为 null）。JSON 解析失败附错误重试一次，仍失败 reject 并带有界原始输出片段；两次已报告 usage 都计入本轮累计用量，与 agent 共用归集路径，TUI/ask --json 更新 usage 快照，calls 记录名为 llm。缓存 key 使用 `<session_id>:llm`，与主会话隔离。

llm 限额由 [config.toml 的 `[limits]`](config.md#limits) 配置：同进程并发调用默认 4，可配置，超出排队（不计请求超时）；每 Run 调用上限默认 100，可配置，超出时在沙箱入队前 reject，建议分批或先用 JS 过滤；单次 prompt + 序列化 input 合计上限默认 256 KiB（UTF-8 字节），可配置，超出 reject，不截断。请求超时沿用 provider（当前无额外读超时），限流/临时错误复用 `src/provider/retry.zig` 的主会话重试、退避与服务端延迟提示。Esc/SIGINT/SIGTERM 同时取消在途和排队调用。各 Run 仍是无状态沙箱，中间结果用 JSON 文件传递，见 [ADR 0013](adr/0013-llm-functions.md)。

根会话可调用 `await tools.agent({ prompt, timeout_ms: 1800000, model, effort })`，成功返回 `{ ok: true, text, usage, changes }`；子会话超时、崩溃、非零退出或 NDJSON error 返回 `{ ok: false, error, text, usage, changes }`，不会 reject，也不会取消同一 Run 中的其他子 agent。只有参数错误和用户取消（Esc/SIGINT/SIGTERM）仍 reject。text 成功时取 end.text；失败时保留已收到的最终文本（text delta，不含思考或工具代码），没有则为空串。error 保留原失败信息，并带实际耗时（含终止宽限）、子会话 id（未收到 start 时明确标为不可用）和检查半成品文件的提醒。timeout_ms 可省略，默认 30 分钟，不计排队时间。model/effort 同 llm：省略则继承，覆盖子会话有效配置，只在当前 provider 内选择，effort 沿用现有校验与映射，不影响父会话。并行实现前先写接口约定，告诉每个子 agent 负责哪些文件，收到结果后检查 changes 是否越界或冲突；`Promise.all` 并行派生，同时运行的子会话上限默认 4，可配置（全部工具最多同时运行 8 个）。子会话独立读取指令文件，沿用 cwd 和有效 provider/模型配置及限额（通过 stdin 管道传递，子会话跳过配置文件读取；Codex 凭证各自读取），不继承父会话历史。内部环境变量 `NIB_AGENT_DEPTH` 从 0 递增，深度达到 1 时，工具说明与实际 JS API 都移除 agent。`NIB_PARENT_SESSION_ID` 写入子会话日志首条记录的 `parent_session_id`。显式 `--resume` 子会话仍保留深度限制；`--continue` 跳过子会话。

`background` 可选，默认 false，保留上述前台等待行为。设为 true 时，调用在登记后台任务后立即返回含 `id` 的启动确认，子会话由父会话持有，可跨 Run 继续工作；父模型可继续其他 Step，不需要额外的查询或等待工具。任务完成后，Session 在下一次主模型请求前，把 `[background agent <id> finished]` 和截断后的 `{ok,text,changes,error?}` JSON 作为 user 消息插入历史，不含 usage。结果不会在模型流式响应或 Run 执行中途插入，也不会当作用户新 Turn。若模型已给出无工具回答但仍有后台任务，Session 等待下一条 inbox 消息（后台结果或用户插话），按 FIFO 插入后发起新 Step；不必等待全部后台任务完成。

后台任务与前台调用共用 agent 并发限额、模型/effort 配置、超时和取消路径；同一父会话的各 Run 不会因各自沙箱退出而取消后台任务。父 Turn 取消或失败、Session 退出时停止并清理未完成任务，不留下脱离父会话的子进程；恢复会话保留已写入日志的结果，未完成任务不会重启，而是插入 `[background agent <id> lost: process ended]`。后台 agent 的启动/结果插入通过 `background` 事件报告，见 [ask-json.md](ask-json.md)；结果消息的日志来源标记与统计口径见 [session-log.md](session-log.md)。

`tools.bash({command, background: true})` 同样立即返回含 `id` 的启动确认；后台 bash 独立于 agent 并发限额。agent 与 bash 分别使用会话级编号 `a1、a2…` 和 `b1、b2…`：前后台 agent 在启动时分配，后台 bash 在启动时分配，前台 bash 仅运行超过 3 秒、开始显示进度时分配。计数跨 Run/Turn 保留；恢复时从后台生命周期记录和前台 `calls[].id` 分别取各前缀最大值继续编号，兼容旧的共用计数日志且不补空号。后台 bash 最多同时运行 8 个，超出时立即 reject 并给出明确错误，不排队；子 agent 内也可使用。结果在下一次主模型请求前作为带来源标记的 user 消息插入，恢复未完成任务时插入 lost 消息。后台 bash 的生命周期也通过 `background` 事件报告。

changes 汇总子会话所有 Run（包括失败 Run）已收到的 `run_end.changes`，按路径首次出现顺序返回 `[{ path, added, removed, created }]`：同路径 added/removed 累加，created 取逻辑或，不含 diff 正文。这是各 Run 的累计行改动量，不是起止文件的净 diff；只涵盖 edit/write，不包含 bash 或外部进程改动。中断时尚未发出 run_end 的改动也可能不在汇总中，失败后仍须检查半成品文件。

## 进度、用量与取消

llm 与 agent 的 usage 都计入本轮累计用量；Esc/SIGINT/SIGTERM 取消在途及排队调用。

子进程 NDJSON 在运行途中按完整行观察；最终输出仍按原路径解析和统计。进度使用受互斥锁保护、每个任务仅保留最新快照的队列；工具线程只更新队列，不调用 Session sink。Run 线程在 sandbox 的 Promise/工具等待循环里约每 20 ms 尝试转发，转发不计入 JS 执行预算；eval 返回前已停止并 join 所有前台工具线程，后台 agent 由父会话持有，不随 Run 结束而 join；进度队列在 Turn 结束时清理，后台任务的原 Run 进度会继续显示到结果插入。TUI 收到事件后复制数据到自身事件循环，在发起任务的 Run 下方默认显示子任务树，每个任务固定一行，按创建顺序排列并按 id 原地更新。agent 行为 `  ├─ a1 prompt 摘要 · 状态 · step N · 工具名 变更文件`，bash 行为 `  └─ b2 bash 命令摘要 · 已运行时间 · 状态`（分支符按行位置变化）。前台 bash 运行超过 3 秒才出现在所在 Run 下，此后每秒更新时间，结束后保留最终状态；不到阈值的命令不出现，Run 标题不变。时间小于 60 秒显示为 `42.3s`，否则为 `3m12s`。后台任务在结果送达前显示 `background`，送达后显示最终状态。prompt 和命令最多预览前 40 个 Unicode 字符；窄屏先缩短 prompt/命令，再缩短末尾文件信息，优先保留 id、状态和 step 或时间，不换行。ctrl+o 只切换 Run 代码、结果及 diff 的展开，不隐藏子任务树。Run 结束恢复工具/耗时/改动摘要，并保留最后收到的子任务状态；从历史恢复的 Run 不重建子任务树。后台结果条目使用相同 id：成功为 `✓ b2 bash · ok · 输出预览`，失败为 `✗ a2 agent · failed · 文本预览`，丢失为 `✗ a2 agent · lost`；ctrl+o 展开仍显示完整 JSON 结果，历史恢复也使用相同格式。工具名来自最近一次 Run，文件仅为 edit/write 报告的变更路径，不代表当前正在执行的命令或任务完成百分比。

bash 与子会话复用进程组执行器，取消和超时会清理整组；子 nib 先收到 SIGTERM，有 500 ms 取消自身工具，之后强制终止。用量按已收到的累计快照统计，无法推知服务端尚未报告的 token。路径写锁只协调当前进程内的 edit/write，不协调独立子会话或 bash 的写入。

## 工具说明的生成

新会话构建 system 时，`src/tools.zig` 根据有效 provider 配置生成 llm 的模型列表：Codex 模型取自 `src/provider/codex.zig` 的目录；Chat Completions 至少提供 `src/provider/openai.zig` 的默认模型，另加入当前配置模型并去重。effort 说明只列常用的 low/medium/high，省略 model/effort 仍继承当前配置；完整档位与映射见 [config.md](config.md) 和 [codex.md](codex.md)。选择只在当前 provider 内进行，不隐式切换 provider。

工具说明中的模型名按 JSON 字符串编码，不直接插入原始配置文本。根会话与子会话使用同一生成路径，但子会话隐藏 agent；恢复会话仍沿用日志原始 system，不改写历史。架构理由见 [ADR 0010](adr/0010-subagents.md) 与 [ADR 0013](adr/0013-llm-functions.md)。
