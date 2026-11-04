# 会话日志、恢复与计时

## 恢复会话

恢复：`nib -c` / `nib --continue` 继续当前目录最近的根会话（跳过子会话）；`nib --resume <32位小写十六进制ID>` 指定会话；`ask` 也支持这些选项，放在 prompt 前后均可。

新会话按基础指令、全局 `$NIB_HOME/AGENTS.md`（默认 `~/.nib/AGENTS.md`）、项目 `AGENTS.md` 的顺序拼接 system，后者优先。项目目录是从 cwd 向上遇到的第一个 `.git` 标记所在目录；没有则用 cwd。只读取 `AGENTS.md`。恢复会话沿用日志中的原始 system，之后修改指令文件只影响新会话。

## 工具录制与离线重放

主日志 `$NIB_HOME/sessions/<session_id>.jsonl` 保存模型消息和 Step；独立的 `<session_id>.calls.jsonl` 保存 Run 内工具的实际返回值与拒绝信息，权限为 `0600`。旁路录制默认开启，可关闭；主日志格式与恢复不依赖它。`nib replay` 只在新沙箱内重跑已保存的 JavaScript，以录制结果替代真实工具，不请求模型、不执行 bash 或文件写入。

重放定位的 `step` 是**整个会话中 assistant Step 的 1-based 序号**（包括无 Run 的最终回答，不随 Turn 重置），`run` 是该 assistant 消息中 `tool_calls` 的 **0-based 数组索引**；它们不是 `turn_step` 或 Run 内工具调用的 `index`。格式、命令、截断/去重和无法判定的情况见 [replay.md](replay.md)。

旁路文件可能含主日志未展示的完整文件内容、命令输出与秘密，不发送给 provider，也不作为 `/reflect` 的输入。反思提示只允许读指定主日志，不枚举 sessions 目录或读取旁路/兄弟/子会话日志；这是提示词约束，不是独立的文件访问控制。分享日志时分别检查两个文件，不因主日志已经脱敏就分享旁路文件。

## 实验标签（header）

日志首行是 header，根会话与子会话在新建时记录以下可选字段；旧日志缺失时仍可恢复。标签只用于记录和统计，不发送给 provider，也不改变执行、系统提示或工具说明。恢复会话保留原 header，不用当前构建或环境重算、回填或改写。

| 字段 | 含义 |
| --- | --- |
| `nib_version` | `build.zig.zon` 版本号加构建时注入的 git 短提交号，如 `0.1.0+abc1234`；无法取得提交号时仅版本号。 |
| `system_sha` | `system_template` 实际渲染结果（含 cwd、工具说明和生效补丁，不含全局/项目 AGENTS.md）的 SHA-256 前 12 位小写十六进制。因此 cwd、工具可用性或补丁变化也可能改变它，不只是模板文字修改。 |
| `patches_off` | `NIB_PATCHES_OFF` 实际禁用的已注册补丁 id，去重并排序；未知 id 忽略，`all` 展开为全部已注册 id。没有禁用项时省略字段。 |

## 提交与中断

会话日志位于 `$NIB_HOME/sessions/<ID>.jsonl`（默认 `~/.nib/sessions/`）。新写入的每条日志记录带 `at`（Unix 毫秒，追加时的墙上时钟时间），恢复兼容无时间戳的旧记录；`scripts/stats.py --since` 按记录时间筛选，无效或缺失 `at` 回退文件修改时间并报告数量。通常只在完整 Step 后提交；后台结果消息及其生命周期记录在下一次 Step 请求前独立提交。Codex 请求最终失败时另追加 `diagnostic: {error_name, message, attempts, step}` 诊断记录（message 保留服务端 code/reason），不提交用户消息或失败输出，不改变模型历史和 context_tokens，恢复时跳过；`scripts/stats.py` 将其计入 `errors.provider_failure`，不算 Step/token。取消（TUI 的 Esc、ask 收到 SIGTERM/SIGINT）时额外提交本轮用户消息和已流出的文本，TUI Esc / ask SIGINT 在末尾标记 `[interrupted by user]`，ask SIGTERM 标记 `[interrupted: process terminated]`，未完成的工具调用丢弃；恢复不重执行已提交的 Run；未完成 Step 可能已产生外部副作用，日志不回滚这些变化。

模型请求的两条线路共用 `src/provider/cancel.zig` 的 `std.Io.Select` 取消封装：请求任务实时写入 sink，另一个任务每 20 ms 检查 cancel 标志；取消时中断连接、发送或读取中的阻塞 I/O，并等待请求任务清理后返回 `error.Canceled`，无需等下一块数据。TUI Esc 与 ask SIGINT/SIGTERM 均走此路径，不设读超时，不改变重试策略；已流出的文本继续由原有 `commitInterrupted` 提交。

## 后台任务结果

`tools.agent({prompt, background: true})` 与 `tools.bash({command, background: true})` 启动前同步追加独立的 `background: {id, kind: "agent"|"bash", state: "started"}` 记录；结果消息插入后追加 `state: "finished", ok` 记录，恢复发现未完成任务时追加 `state: "lost"`。agent 和 bash 分别使用会话级计数器：`a1、a2…` 与 `b1、b2…`，前台与后台共用各自类型的计数器。恢复扫描所有后台 `started/finished/lost` 记录和 `calls[].id`，按前缀分别取最大值继续分配；旧的共用计数日志也按此规则恢复，不补空号。这些记录带 `at` 和 `turn_step`，不改变历史或 context_tokens。结果在下次主模型请求前单独提交为一条 user 消息：`source: "background"`、`background_kind`、`background_id`、`background_ok`；可选的 `background_ok` 记录任务是否成功，供 TUI 在正文 JSON 截断后正确回放。agent 正文为 `[background agent a1 finished]\n` 后接截断后的 `{ok,text,changes,error?}` JSON，不含 usage；bash 正文结果恰为 `{exit_code,output}` 或 `{error}`，无 `ok` 字段。恢复时未完成任务不会重启，插入 `[background agent a1 lost: process ended]` 或对应的 bash 消息。来源字段只保存在日志中，不发送给 provider；正文会发送给模型。后台消息不发起新 Turn。旧 `background_agent` 日志仍可统计。

## Step 计时字段

完整 Step 的可选计时字段（旧日志缺失时正常恢复）：`model_ms` 是模型请求总耗时，包含重试和退避，`attempts` 是实际尝试数；`first_data_ms` 是 provider.Sink.onData 首次收到任何 SSE 数据（含心跳、元数据）相对 Step 开始的时间，不代表首个模型内容 token。`code` 每个 run 一条 `{tool_call_id, first_ms, last_ms, progress}`，首尾时间相对 Step 开始，`progress` 是 `[ms, 累计参数 UTF-8 字节数]` 数组；接收时按到达顺序写入每调用最多 1024 点的固定缓冲，超出后按 stride 跳采，finish 时一次均匀抽样成最多 32 点并保留首尾；Codex 按 output_index、Chat Completions 按工具 index 跟踪，最终一次性参数如实记录 `first_ms == last_ms`，不推断未收到的片段。重试只保留成功请求的 code，first_data_ms 保留所有尝试中最早 onData 时间。`run_ms` 为此 Step 各 Run 从 sandbox 开始到 `session/output.zig` 格式化完成的总耗时，`run_results[].run_ms` 为单次耗时；未进入 sandbox 的调用无单次 run_ms。`calls` 最多保留 200 个宿主工具调用 `{name, start_ms, end_ms, ok, run_index}`，时间相对各自 Run 开始，run_index 是 run_results 的零起始下标，超出条数记 `calls_omitted`；ok 表示工具返回成功/错误，不等同于 bash 命令退出码。子 agent 只计父进程侧的调用，不追加参数或结果正文。`calls[]` 的可选 `id` 保存已分配的会话级任务编号：前台 agent 启动即分配，前台 bash 仅运行超过 3 秒开始上报进度时分配，短 bash 不含此字段；恢复依靠这些 id 避免前台编号回退。完整 Step、压缩及中断提交另保存可选 `task_ids: {agent, bash}`，数值为各类型已分配编号的高水位；恢复同时取其最大值，避免任务超过 `calls[]` 的 200 条明细上限时丢失续号信息。旧日志可省略。后台 agent/bash 的启动调用另带 `background: true` 和 `id`；该调用计时仅到启动返回，不表示后台任务执行耗时。所有计时使用单调 awake 时钟、毫秒单位；固定容量缓冲复用现有调度/完成路径，不新增锁或逐片段分配，不预取或推测执行。

## 工具字节度量

完整 Step 顶层另有可选 `tool_bytes`、`output_bytes`，分别为该 Step 各 Run 的同名字段之和；`run_results[]` 保存每个 Run 的可选 `tool_bytes`、`output_bytes`。它们与现有 Step 顶层计时字段并列，不嵌套到 `timing` 对象。旧日志缺失字段仍可恢复，不把缺失当作零。

- `sandbox.Outcome.tool_bytes` 在宿主工具结果交给 JS 时累计：成功按序列化 JSON 的 UTF-8 字节数，错误按错误文本的 UTF-8 字节数计量。无论 JS 是否使用或 await 结果都计入；未产生交回 JS 的结果计 0。`agent` 只计父 Run 收到的返回对象，不累加子会话内部工具数据。
- `output_bytes` 是 `session/output.format` 格式化后交给模型的 tool result 实际 UTF-8 字节数，包含 16 KiB 预算内的截断标记、错误、`no output`、条目标签和分隔符等。harness 拒绝执行的 Run 也记录其返回文本的 `output_bytes`，`tool_bytes` 为 0。
- 后台 agent/bash 只计启动时交回 JS 的 `{id}`；之后插入的结果消息不经过 Run，不计入这两个字段。
- `calls[]` 的 `dispatched` 默认为 true；入队前被限额拒绝的调用记录为 false，仍计入错误文本字节，但不增加原有的 llm/agent 实际调度次数。
- `calls[]` 新增可选 `result_bytes`，口径与单次宿主调用贡献的 `tool_bytes` 相同。旧明细可为 null 或省略；新记录中取消时尚未结算的调用为 0。超过 200 条的明细仍按 `calls_omitted` 省略，不影响 Run/Step 的字节总数。

## Turn 账单

TUI 在每个 Turn 的内容后追加一行淡色账单，例如：

```text
12 steps · 3m10s · think 1m40 · tools 1m20 · 3.2M→18k B · 45k tok (91% cached) · llm ×8 · agent ×1
```

宽度不足时从右向左移除整个字段，不换行；llm/agent 次数为 0 时不显示。失败或取消时开头为 `failed` 或 `canceled`，Step 数、think/tools 和调用次数只计已提交的完整 Step。总耗时是整个 Turn 的单调墙钟时间，不是 Step 耗时之和；think/tools 分别复用 Step 的 `model_ms`/`run_ms`。token 数使用完成 Step 后的本轮累计 usage（prompt + completion，包含截至该点已报告的压缩和委派用量），缓存率为 prompt_cache_hit_tokens / prompt_tokens。取消或失败的未完成 Step 不纳入账单，但墙钟仍包含其等待时间。

`TurnSummary.timing` 的 `tool_bytes`、`output_bytes` 为本轮已提交完整 Step 的同名字段之和，0 也保留键；失败和取消仍沿用上述完整 Step 口径。TUI 在 tools 后显示 `3.2M→18k B`（tool_bytes → output_bytes），`B` 表示字节，`k`/`M` 为十进制缩写；`tool_bytes=0` 时省略此字段。

Session 累计这些数据并通过 `turn_end` 按值传给 TUI，TUI 不跨线程读取统计；账单只是界面条目，不写入模型历史，恢复旧会话时不重建。`ask --json` 的 `end/error.timing` 与账单计时相同，详见 [ask-json.md](ask-json.md)。

## Step effort 字段

完整 Step 还记录可选 `effort`、`effort_source` 和 `effort_downgraded`。`effort` 是实际请求档位，未指定服务端档位为 `default`；`effort_source` 为 `model|default|guard`，分别表示模型声明生效、用户默认（含 Run 显式 default）、护栏回退。`effort_downgraded` 仅在模型声明实际低于用户有效档位时为 true；服务端 default 下接受的 low 也按降档声明计。等档声明来源可为 model，但不算降档。重试沿用同一档位，压缩不产生 Step effort 记录。旧日志缺字段仍可恢复。

assistant 消息的可选 `step_effort: {effort, source}` 保存界面元数据，让压缩重写后保留的历史 Run 仍显示原来的请求档位；日志恢复以完整 Step 顶层 effort 字段为准。这些元数据不发送给 provider，不影响恢复后的调度；每个新 Turn 首步仍用本次用户设置。调度护栏见 [config.md](config.md#逐-step-effort-调度)。

## 会话统计

会话统计：`python3 scripts/stats.py [日志文件或目录] [--since YYYY-MM-DD] [--cwd 目录] [--group-by version|system|patches] [--json]`，默认只读 `$NIB_HOME/sessions`（默认 `~/.nib/sessions`），用于发现故障和比较改动前后效果。文本和 JSON 均包含“耗时构成”：Step/model/run 的中位数与 p90、首段代码前等待和参数生成跨度、运行时各工具调用次数/总耗时/中位耗时，以及参数到达跨度严格大于 50 ms 的 run 比例；每项列出有效样本数，旧日志缺字段不补零。bash 耗时 Top 10 按保存的 JS 命令字面量前两个 shell 单词启发式分组，无法可靠关联的动态/多调用列为 unmatched，不把整个 bash 耗时分摊给 shell 子命令。

“工具数据度量”（JSON `tool_data`）独立累计 Step 顶层 `tool_bytes`、`output_bytes` 的有效样本数和总字节，不与 Run/calls 相加，也不从其他层回填。`output_tool_ratio` 按 `run_results[]` 中两字段有效且 `tool_bytes>0` 的 Run，统计各自 `output_bytes/tool_bytes` 的中位数、p90（nearest-rank）和样本数，不是总量之比，比例可大于 1。工具占比按有效 `calls[].result_bytes` 的总和为分母，按 name 汇总字节和调用数；明细被省略时覆盖有限，不代表全部工具数据。旧日志缺失字段跳过，不补零；明细总字节为零时占比为 n/a。

`--group-by version|system|patches` 分别按 header 的 `nib_version`、`system_sha`、`patches_off` 分组，总体报告保留，每组分别输出核心报告；JSON 使用 `group_by` 和 `groups`。缺失标签的旧日志归 `unknown`；新版 header 有版本或系统哈希但省略 `patches_off` 时归 `none`，补丁列表按排序后的集合分组。

完整 Step 新增可选 `turn_step`（Turn 内从 1 开始的 Step 序号），只用于识别日志中的 Turn 边界，运行中插话不会另起 Turn；恢复后新 Turn 从 1 开始。旧日志缺少该字段时仍按 user 消息估算边界（排除后台结果消息），可能把插话算成新 Turn。

JSON `agents` 和 `bash_calls` 分别统计 agent、bash 的前台/后台调用及 `background_steps` 分布。前台数取有效 `calls[]`；agent 只计根会话，bash 也计子会话；`dispatched=false` 不计；后台数优先取独立 `background.started` 记录，旧日志回退 `calls[]` 的 `background: true` 和 `id`。`background_steps` 按 id 关联 started、finished/lost 和 `source=background` 的结果消息；旧日志兼容 `background_agent`。统计启动 Step 之后、消息插入之前已完成的主模型 Step 数（中位数、p90、样本数），排除启动 Step 和使用结果的请求。多个后台任务各自计样本；只统计同一会话、范围全入选且未中断的完整配对，过滤缺口与不完整配对不补零。

“往返结构”（JSON `round_trips`）包含每 Turn 入选 Step 数的中位数/p90（nearest-rank、含零步 Turn），写→仅验证相邻对次数/全部相邻对，以及连续写的不同文件对次数/有效连续写对；每项给出样本数。相邻对限同一 Turn，不跨过滤或取消断点；验证沿用 bash 首两词启发式（build/test/fmt/check/diff 等），多 Run/调用必须全部是可识别验证 bash，动态或复合 shell 保守跳过。写路径只取直接 edit/write 的完整字面量，按 cwd 规范化；两步文件集合不相交才计“不同文件”，缺失/动态路径跳过，不推断 bash 的文件副作用。

耗时构成的 `timing.effort.by_effort` 按完整 Step 的顶层 effort 分组，列出 Step 数、model_ms 分布（含中位数和样本数）、prompt/cache token 总量与缓存命中率。缺 effort 的旧记录跳过，缺计时仍计 Step；缓存率为有效 prompt/cache 成对字段的总和之比，不是各 Step 比例的平均。

各档 `downgraded` 及跨档 `timing.effort.downgraded` 给出降档后的 Run 失败率：分母是有 Run 的降档 Step 数，分子是该 Step 响应后执行的任一 Run 显式 `ok=false` 的 Step 数，不关联后一个 Step，也不把无 Run 的最终回答放入分母。未知 Run 状态仍入分母并单列 `steps_with_unknown_run_status`。降档按 `effort_source=model` 且 `effort_downgraded=true` 判定；缺少后一字段的过渡记录按 model 来源推断，显式 false 排除等档声明。

机器事件接口见 [ask-json.md](ask-json.md)。
