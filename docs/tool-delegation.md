# tools.llm 与 tools.agent：调用与实现

少量文件直接 read 最便宜。大量数据的单步判断、分类、抽取适合 llm，通常几秒；批量简单判断优先低成本模型和低 effort，强模型留给少量难题。agent 用于独立多步任务或提交前只读审查；每个子会话从零读代码，常消耗几千到几万 token、几十秒以上，不代替 read 或 llm。延迟与成本是量级提示，不是保证。

## 接口与限额

Run 中可调用 `await tools.llm({ prompt, input, schema, model, effort })`，返回 `{ text, data, usage }`，用于批量判断、分类和抽取；要执行操作或多步调查则用 `tools.agent`。prompt 必填，input 可省略；字符串原样传入，其他可 JSON 序列化值按 JSON 编码，与 prompt 分开，不继承会话历史、项目 AGENTS.md 或 nib system。model/effort 默认跟随有效配置，覆盖只影响本次调用。宿主在当前进程代发一次无工具请求，凭证不进入 JS；子 agent 也可用 llm。schema 可选对象：Codex 用 strict json_schema，Chat Completions 用 json_object 加提示约束；schema 仍受服务端支持的子集限制（如 Codex strict 对象的 additionalProperties:false / required）；宿主只验证合法 JSON，不做完整 schema 校验，返回解析后的 data（无 schema 时为 null）。JSON 解析失败附错误重试一次，仍失败 reject 并带有界原始输出片段；两次已报告 usage 都计入本轮累计用量，与 agent 共用归集路径，TUI/ask --json 更新 usage 快照，calls 记录名为 llm。缓存 key 使用 `<session_id>:llm`，与主会话隔离。

llm 限额常量在 `src/tools/llm.zig`：同进程最多 4 个并发调用，超出排队（不计请求超时）；每 Run 最多 100 次，第 101 次在沙箱入队前 reject，建议分批或先用 JS 过滤；单次 prompt + 序列化 input 合计最多 256 KiB（UTF-8 字节），超出 reject，不截断。请求超时沿用 provider（当前无额外读超时），限流/临时错误复用 `src/provider/retry.zig` 的主会话重试、退避与服务端延迟提示。Esc/SIGINT/SIGTERM 同时取消在途和排队调用。各 Run 仍是无状态沙箱，中间结果用 JSON 文件传递，见 [ADR 0013](adr/0013-llm-functions.md)。

根会话可调用 `await tools.agent({ prompt, timeout_ms: 1800000 })`，返回 `{ text, usage }`；timeout_ms 可省略，默认 30 分钟，不计排队时间。超时错误包含实际耗时（含终止宽限）、子会话 id（未收到 start 时明确标为不可用）和检查半成品文件的提醒。子会话适合独立调查或任务，不适合需要跨文件协调的修改；`Promise.all` 并行派生，最多同时运行 4 个子会话（全部工具最多同时运行 8 个）。子会话独立读取指令文件，沿用 cwd 和有效 provider/模型配置（通过 stdin 管道传递，子会话跳过配置文件读取；Codex 凭证各自读取），不继承父会话历史。内部环境变量 `NIB_AGENT_DEPTH` 从 0 递增，深度达到 1 时，工具说明与实际 JS API 都移除 agent。`NIB_PARENT_SESSION_ID` 写入子会话日志首条记录的 `parent_session_id`。显式 `--resume` 子会话仍保留深度限制；`--continue` 跳过子会话。

## 进度、用量与取消

llm 与 agent 的 usage 都计入本轮累计用量；Esc/SIGINT/SIGTERM 取消在途及排队调用。

子进程 NDJSON 在运行途中按完整行观察；最终输出仍按原路径解析和统计。进度使用受互斥锁保护、每个子 agent 仅保留最新快照的队列；工具线程只更新队列，不调用 Session sink。Run 线程在 sandbox 的 Promise/工具等待循环里约每 20 ms 尝试转发，转发不计入 JS 执行预算；eval 返回前已停止并 join 所有工具线程，之后清空队列。TUI 收到事件后复制数据到自身事件循环，正在运行的 agent Run 折叠显示进度汇总，ctrl+o 展开显示各子任务（prompt 前 40 个 Unicode 字符）；Run 结束恢复工具/耗时/改动摘要。

bash 与子会话复用进程组执行器，取消和超时会清理整组；子 nib 先收到 SIGTERM，有 500 ms 取消自身工具，之后强制终止。用量按已收到的累计快照统计，无法推知服务端尚未报告的 token。路径写锁只协调当前进程内的 edit/write，不协调独立子会话或 bash 的写入。

## 工具说明的生成

新会话构建 system 时，`src/tools.zig` 根据有效 provider 配置生成 llm 的模型列表：Codex 模型取自 `src/provider/codex.zig` 的目录；Chat Completions 至少提供 `src/provider/openai.zig` 的默认模型，另加入当前配置模型并去重。effort 说明只列常用的 low/medium/high，省略 model/effort 仍继承当前配置；完整档位与映射见 [config.md](config.md) 和 [codex.md](codex.md)。选择只在当前 provider 内进行，不隐式切换 provider。

工具说明中的模型名按 JSON 字符串编码，不直接插入原始配置文本。根会话与子会话使用同一生成路径，但子会话隐藏 agent；恢复会话仍沿用日志原始 system，不改写历史。架构理由见 [ADR 0010](adr/0010-subagents.md) 与 [ADR 0013](adr/0013-llm-functions.md)。
