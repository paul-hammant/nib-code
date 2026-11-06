# tools.llm 与 tools.agent：调用与实现

TUI `/undo` 的快照由 edit/write 的实际写入路径记录，父 Turn 与子进程通过内部 stdin envelope 的 `undo_dir` 共用目录；默认新建、fork、resume 和后台 agent 均继承本次父 Turn 的目录。它不通过 `run_end.changes` 汇总，也不改变 changes 的统计口径；取消或失败后已完成的写入仍可撤销。详见 [undo.md](undo.md)。

少量文件直接 read 最便宜，不调用模型。大量数据的单步判断、分类、抽取适合 llm，通常几秒；批量简单判断优先低成本模型和低 effort，强模型留给少量难题。默认由主循环完成修改、构建、测试和串行审查。除非用户要求委派，agent 只用于能与主循环有用工作并行、结果可丢弃的独立只读调查。前台等子 agent 就是串行；后台启动后主循环无法继续，同样增加关键路径延迟。默认新建子会话从零读代码，fork 继承当前父上下文，接续保留子会话已有历史，不代替 read 或 llm。接口仍允许用户要求的实现委派，不加运行时禁令，也不改 model/effort 的继承默认值。

2026-11-04 的本地 `nib-bench/runs/smoke-20261104` 父日志说明了这个区别：timers 在 Step 1 派只读调查、Step 3 派文档修改，随后三次接续仍忙的 a1 都返回 AgentBusy，Step 11 又派 a3 实现核心调度，Step 17 才成功接续 a1 做审查。7 次调用并非 7 个新子会话，而是 3 次新建、1 次有效接续和 3 次 busy；主循环之后大量 sleep 等实现和测试。console-tail 在 Step 1 派核心捕获实现，Step 4 想询问尚未确定的 API、Step 29 想催结束，后两次接续都 busy；只有一个新子会话，父模型反复 sleep、查 diff 和编译日志。两者的实现均在关键路径上。原提示描述了新建/fork 的成本，却没有给出何时不委派的决策标准；全局 AGENTS.md 已有限制，因此只能从调用与等待记录推断行为，不能断言模型的内部动机。接续是完成后的新 Turn，不能给运行中的 agent 发消息；busy 后等待结果，不重复接续或派替代实现。

后台 bash/agent/Run 完成后自动投递结果。等这些结果不要调用 tools.sleep 或轮询文件；没有独立工作就给极短、无工具调用的回复，Session 在本地等 inbox 后继续 Turn。detached 服务的就绪探测可使用有界 sleep，服务启动与后台任务完成不是同一条件。sleep 不根据“存在后台任务”拒绝或改变行为，以免破坏这类合法等待及录制/重放语义。

成本参考来自本次统计时本机 `~/.nib/sessions` 的全部 105 个子会话（0.2.0 时期，以 `gpt-6.1-sol` / `high` 为主，含少量模型/effort 覆盖；旧日志部分元数据缺失），不再只用 [#37](https://github.com/yyydddkkk/nib-code/issues/37) 中的 6 个样本。统计命令：

```sh
python3 scripts/stats.py ~/.nib/sessions --json
```

`child_costs` 的每子会话实测分布（p90 为 nearest-rank）：

| 指标 | 中位数 | p90 | 有效子会话数 |
| --- | ---: | ---: | ---: |
| 完整 Step 数 | 12 | 24 | 105 |
| 累计模型时间 | 179,088 ms（约 3 分钟） | 406,863 ms（约 7 分钟） | 87 |
| prompt token 总量（含缓存） | 299,991（约 30 万） | 825,096（约 83 万） | 101 |
| 未缓存 prompt token | 43,350（约 4.3 万） | 75,479（约 7.5 万） | 101 |

输入 token 是每次请求的累计量，含重复上下文；未缓存量逐 Step 用 `prompt_tokens - prompt_cache_hit_tokens` 计算，再按子会话累加。两者同时列出：未缓存部分通常是费用与延迟的主要驱动，但缓存输入也不等于免费，总 token 不是费用。模型时间不含工具执行，亦非端到端墙钟时间，因此这里实测的 p90 约 7 分钟，不沿用约 9 分钟的初始估计。缺字段不补零，表中各指标独立取有效样本，不应将不同指标的分位数相减；失败、取消日志只代表已记录成本的下界。

这批 105 个新建子会话的开头约 6 个只读 Step 消耗约 22% 时间，完整任务约 12 Step、3 分钟、29 万级累计 prompt tokens。fork 复用父上下文的动机是减少重复调查；这不是 fork 的实测节省比例，继承更长 history 的成本与实际缓存收益仍待对照验证。

### `child_costs` 分组与有效样本

`child_costs` 以每个带 `parent_session_id` 的入选子日志为一个样本，含前台和后台；接续仍属于同一子日志，不按每次 agent 调用拆分。`child_costs.by_creation` 按子 header 的创建信息分组：

| 组 | 判定口径 |
| --- | --- |
| `fork` | `forked_from` 是对象，含非空字符串 `session` 和非负整数 `message_count` |
| `new` | header 缺少 `forked_from`，包括没有此字段的旧日志 |
| `unknown` | 显式存在 `forked_from`，但结构或字段值无效 |

只输出实际出现的组；不能把 `unknown` 或旧日志缺字段视为已验证的 fork 对照样本。`child_costs.by_parent_system` 按父会话 `system_sha` 区分工具说明修改前后的实验，每个父 system 组内也有同口径的 `by_creation`。父标签通过本次输入日志中的 `parent_session_id` 关联；父日志缺失或标签无效时归 `unknown`，不回退到子 system。

全局、各父 system 组及各 `fork` / `new` / `unknown` 创建组均包含以下分布；每个指标分别输出 `{ samples, median, p90 }`，例如 `child_costs.by_creation.fork.first_request_cache_hit_rate.samples`：

| JSON 指标 | 每子会话的取值与入样条件 |
| --- | --- |
| `steps`（Step） | 已提交完整 Step 数，不计 header 中继承的父历史 |
| `model_ms` | 各完整 Step 的模型毫秒数之和，含重试/退避，不含工具执行，不是墙钟时间 |
| `prompt_tokens`（prompt） | 各完整 Step 的输入 token 之和，含缓存与重复上下文，不是费用 |
| `uncached_prompt_tokens`（uncached） | 逐 Step 的 `prompt_tokens - prompt_cache_hit_tokens` 之和；两字段均为非负整数且 cache ≤ prompt |
| `first_request_cache_hit_rate` | 首个完整 Step 的 `prompt_cache_hit_tokens / prompt_tokens`，两字段有效、cache ≤ prompt 且 prompt > 0；逐子会话等权，不是汇总 token 后的比值 |

这些分布仅纳入非零 Step、且所有完整 Step 都在筛选范围内的子会话。`sessions` 为入选子日志数，`full_range_sessions` 为上述全范围非零 Step 子会话数，`partial_range_sessions` 记录被 `--since` 等筛选截断的子会话，`no_step_sessions` 记录没有完整 Step 的子会话；后两类不进入分布，不能把截断片段当作整次成本。

`model_ms`、prompt 和 uncached 各自要求该子会话所有完整 Step 的对应字段有效，缺失不补零，也不加父会话 usage 或工具结果中的 usage。首请求命中率只检查首个完整 Step，不因后续 Step 缺字段而排除，也不以之后的有效 usage 替代缺失的首 Step。`samples` 是各指标的有效子会话数，因此同组各指标可能不同；无有效样本时为 0，`median` / `p90` 为 null，p90 使用 nearest-rank。失败、取消或仍运行的日志仍只是已记录成本的下界。这些分组提供观测而非自动选择阈值；口径及其他筛选行为见 [会话统计](session-log.md#会话统计)。

## 接口与限额

Run 中可调用 `await tools.llm({ prompt, input, schema, model, effort })`，返回 `{ text, data, usage }`，执行一次无工具模型请求。prompt 必填，input 可省略；字符串原样传入，其他可 JSON 序列化值按 JSON 编码，与 prompt 分开，不继承会话历史、项目 AGENTS.md 或 nib system。model/effort 默认跟随有效配置，覆盖只影响本次调用。宿主在当前进程代发一次无工具请求，凭证不进入 JS；子 agent 也可用 llm。schema 可选对象：Responses 用 strict json_schema，Chat Completions 用 json_object 加提示约束，Anthropic 用提示约束；schema 仍受服务端支持的子集限制（如 Responses strict 对象的 additionalProperties:false / required）；宿主只验证合法 JSON，不做完整 schema 校验，返回解析后的 data（无 schema 时为 null）。JSON 解析失败附错误重试一次，仍失败 reject 并带有界原始输出片段；两次已报告 usage 都计入本轮累计用量，与 agent 共用归集路径，TUI/ask --json 更新 usage 快照，calls 记录名为 llm。缓存 key 使用 `<session_id>:llm`，与主会话隔离。

llm 限额由 [config.toml 的 `[limits]`](config.md#limits) 配置：同进程并发调用默认 4，可配置，超出排队（不计请求超时）；每 Run 调用上限默认 100，可配置，超出时在沙箱入队前 reject；单次 prompt + 序列化 input 合计上限默认 256 KiB（UTF-8 字节），可配置，超出 reject，不截断。请求超时沿用 provider（当前无额外读超时），限流/临时错误复用 `src/provider/retry.zig` 的主会话重试、退避与服务端延迟提示。Esc/SIGINT/SIGTERM 同时取消在途和排队调用。各 Run 仍是无状态沙箱，中间结果用 JSON 文件传递，见 [ADR 0013](adr/0013-llm-functions.md)。

根会话可调用 `await tools.agent({ prompt, resume, fork, timeout_ms: 1800000, model, effort, background: false })`。fork 为可选 boolean，默认 false。resume 为可选字符串，可省略：不传则新建子会话（fork 决定是否继承父上下文）；传入当前父会话的 agent 任务 id（如 `a1`），接续该任务对应的子会话历史和原始 system，并追加本次 prompt。仅新建时分配任务 id；接续沿用原任务 id，不分配新 id。例如 `resume: "a1"` 的前台结果、后台启动确认和完成消息、progress 事件及 TUI tree 均使用 `a1`。每次仍启动独立的 nib 子进程、运行一个 Turn；内部通过 `nib ask --resume <内部子会话 ID>` 恢复，不是常驻 worker。默认新子会话独立读取指令文件，不继承父会话历史；`fork:true` 的区别如下。

`fork:true` 继承父会话压缩后的当前完整 history，而不是从原始日志重建被压缩丢弃的内容；system 和工具 schema 与父会话逐字节相同。截取点包含发起 fork 的当前 assistant 消息，包括 reasoning（Codex 的加密推理条目也保留）和工具调用。子会话先为该 assistant 的工具调用补齐合成 tool results，再追加本次 prompt 作为 user 消息；这些合成结果不是父 Run 尚未完成的真实结果，也不会在子会话重跑父 Run。

每次 fork 都新建独立子会话和新的 `aN` 任务 id，后续可用 `resume: "aN"` 接续；`fork` 与 `resume` 同时传入是参数错误（即使 `fork:false`），reject。fork 仍使用普通子 agent 的执行深度，不开放递归：虽然继承的 system/schema 仍描述 agent，运行时不能再调用 agent。子会话与父会话共享 cwd，没有独立 worktree；fork 也复制历史截取点已有的文件版本观察，继承内容不是未观察文件，直接 write 仍受过期检测；已有跨进程文件锁、原子替换和过期检测继续生效，但不提供工作区隔离，也不协调 bash 或用户编辑器的写入。

文件版本观察只在新建 fork 时复制，不写入会话日志；与普通恢复一致，后续 resume 重新开始观察。

fork 的 model/effort 可覆盖，默认继承产生当前 assistant 请求的实际有效配置（包括一次性的 Run effort），显式覆盖优先；只有 model 与 effort 都相同时才保留父前缀的缓存复用优势，改变任一项就失去这一优势。Responses/Messages 的 fork 与 resume 使用相同的模型一致性约束：不能把父历史中的密文或签名推理条目带到另一模型；覆盖 model 也不绕过此检查。Codex fork 的 `prompt_cache_key` 沿用父值，旨在路由到同一缓存；实际能否命中、节省多少仍是待实测假设，不是协议保证，见 [codex.md](codex.md#fork-与父缓存路由) 与 [ADR 0015](adr/0015-agent-fork.md)。

前台成功返回 `{ ok: true, id, text, usage, changes }`；子会话超时、崩溃、非零退出或 NDJSON error 返回 `{ ok: false, id, error, text, usage, changes }`，不会 reject，也不会取消同一 Run 中的其他子 agent。id 为任务 id（接续时沿用原 id），不是内部子会话 ID；工具返回值、错误诊断和后台结果不向模型暴露内部子会话 ID。只有参数错误（包括 resume 格式错误）和用户取消（Esc/SIGINT/SIGTERM）仍 reject。text 成功时取 end.text；失败时保留已收到的最终文本（text delta，不含思考或工具代码），没有则为空串。error 保留失败原因、实际耗时（含终止宽限）、任务 id 和文件可能不完整的诊断。usage 和 changes 只统计本次调用，不重复累计子会话之前的历史。

父会话日志持久化任务 id 到内部子会话 ID 的映射，恢复父会话时重建；模型只使用任务 id。只能接续当前父会话的 agent 任务：目标子会话日志的 `parent_session_id` 必须等于当前父会话 id；不存在的任务、非本会话 agent（包括非 agent 任务）或没有内部子会话映射的任务均返回 `ok:false`，不 reject；传入内部子会话 ID 也不能接续。父会话恢复后仍可接续其原有子会话，根会话或其他父会话的子会话不能接续，返回 `ok:false`。执行阶段在等待并发槽之前预留目标 agent；同一 agent 一次只允许一个在途调用（含排队、前台和后台），busy 时立即返回 `ok:false`，不排队、不分配新 id。预留在完成、失败或取消时释放，前台和后台共用；日志独占锁另外阻止跨进程同时接续，包括 CLI。失败、超时或取消不删除已有映射；内部子会话日志可恢复时仍可接续，尚未取得内部子会话 ID 的任务没有可接续映射。停止不回滚文件，日志或 changes 不保证包含中断前的全部改动。

timeout_ms 可省略，默认 30 分钟，不计排队时间。model/effort 省略时继承父会话的当前有效配置，接续时也不改为沿用子会话上次覆盖值；覆盖只影响本次子调用，不影响父会话或切换 provider，effort 沿用现有校验与映射。恢复的 provider 必须与日志一致，Responses/Messages 模型也必须相同（见 [providers.md](providers.md)）；父会话当前模型与子会话原模型不同时，省略 model 的接续调用仍受此约束。同时运行的子会话上限默认 4，可配置（全部工具最多同时运行 8 个）。子会话沿用 cwd、有效 provider/模型配置及限额（通过 stdin 管道传递，子会话跳过配置文件读取；Codex 凭证各自读取）。内部环境变量 `NIB_AGENT_DEPTH` 从 0 递增，深度达到 1 时，默认新建子会话的工具说明与实际 JS API 都移除 agent；fork 为保留父请求前缀不改写说明/schema，但运行时同样不能调用 agent。`NIB_PARENT_SESSION_ID` 写入新子会话日志首条记录的 `parent_session_id`。显式 `--resume` 子会话仍保留深度限制；`--continue` 跳过子会话。

`background` 可选，默认 false，保留上述前台等待行为。设为 true 时，调用在成功登记后台任务后立即返回 `{ id }` 启动确认；接续 `a1` 时仍为 `{ id: "a1" }`，busy、不存在或非本会话 agent 直接返回 `ok:false`，不登记后台任务。子会话由父会话持有，可跨 Run 继续工作；父模型可继续其他 Step，不需要额外的查询或等待工具。任务完成后，Session 在下一次主模型请求前，把 `[background agent <id> finished]` 和截断后的 `{ok,id,text,changes,error?}` JSON（id 与启动确认相同）作为 user 消息插入历史，不含 usage。结果不会在模型流式响应或 Run 执行中途插入，也不会当作用户新 Turn。若模型已给出无工具回答但仍有后台任务，Session 等待下一条 inbox 消息（后台结果或用户插话），按 FIFO 插入后发起新 Step；不必等待全部后台任务完成。

后台任务与前台调用共用 agent 并发限额、模型/effort 配置、超时和取消路径；同一父会话的各 Run 不会因各自沙箱退出而取消后台任务。父 Turn 取消或失败、Session 退出时停止并清理未完成任务，不留下脱离父会话的子进程；恢复会话保留已写入日志的结果，未完成任务不会重启，而是插入 `[background agent <id> lost: process ended]`。后台 agent 的启动/结果插入通过 `background` 事件报告，见 [ask-json.md](ask-json.md)；结果消息的日志来源标记与统计口径见 [session-log.md](session-log.md)。

`tools.bash({command, background: true})` 同样立即返回含 `id` 的启动确认；后台 bash 独立于 agent 并发限额。agent 与 bash 分别使用会话级编号 `a1、a2…` 和 `b1、b2…`：前后台 agent 仅在新建时分配，接续不递增编号、沿用原 id，所有 bash 在启动时分配，前台 bash 仍只在运行超过 3 秒时显示进度。计数跨 Run/Turn 保留；恢复时根据日志中的任务 id 分别取各前缀最大值继续编号，兼容旧的共用计数日志且不补空号。后台 bash 最多同时运行 8 个，超出时立即 reject 并给出明确错误，不排队；子 agent 内也可使用。结果在下一次主模型请求前作为带来源标记的 user 消息插入，恢复未完成任务时插入 lost 消息。后台 bash 的生命周期也通过 `background` 事件报告。

`tools.bash({command, background: true, detached: true})` 是会话级任务：跨 Run 和正常 Turn 存活，最终回答和 Step 上限收尾只等待普通后台任务，不等待 detached；停止提示只列实际等待的任务。detached 要求 `background:true`，默认 `timeout_ms:0`（无截止时间），也可显式指定正数超时；普通前台/后台 bash 默认 1800000 ms（30 分钟），Run 自动转后台不重置或缩短这个截止时间，显式正数 timeout_ms 始终优先。默认值的依据与清理边界见 [run-output.md](run-output.md#bash-执行时限)。它与其他 bash 共用 b 计数器、并发和输出上限。完成时只入 inbox，空闲时不自动发起 Turn；下一次 Step/Turn 消费一次。Turn 取消/失败、Session 退出或切换清理全部任务；ask 回答后退出 Session，因此不跨 ask 进程保活。恢复会话不重启进程，沿用 lost 消息。

`tools.stop({id,reason}) → {id,stopped,reason,notice?}` reason 必须是非空白字符串，否则 reject 且不停止任务。所有显式 stop 都要求给出具体理由，不猜测命令是否属于验证：时间长或没有输出本身不证明任务卡住；用户要求、已观察到的失败、需求变化仍可作为停止理由。取消未完成测试会丢弃本次测试进度，不能据此声称验证通过；启动新进程会重做未完成的工作。已写文件和编译缓存不会回滚。返回值保留 reason，实际停止时附带 notice 提醒。按现有 a/b id 取消并 join 单个后台 bash/agent，清理进程组。停止运行中的任务返回 `stopped:true`；已结束的已知任务返回 false，未知 id reject。并发停止同一任务只 join 一次，完成结果仍经原 inbox 路径投递一次。stop 返回前释放 agent 的执行占用；它不删除任务身份。启动和 stop 都经普通工具统一结算/录制出口，后台结果消息按 UTF-8 字节计入接收它的 Step 的 output_bytes。见 [ADR 0014](adr/0014-session-background-jobs.md)。

后台 agent/bash 的执行失败通常转换成结果消息；若后台工作线程自身出错，无法生成或写入 inbox 结果（例如分配失败），内部错误由轮询路径上报一次，该任务不再计入待结果集合，后续 Run 不会反复收到同一错误。

changes 汇总本次调用中子会话所有 Run（包括失败 Run）已收到的 `run_end.changes`，按路径首次出现顺序返回 `[{ path, added, removed, created }]`：同路径 added/removed 累加，created 取逻辑或，不含 diff 正文。每个 Run 也按本会话每次成功 edit/write 的紧邻 before/after 内容累加，不是 Run 或整个子会话起止文件的净 diff；改后又撤销仍累计两个方向，失败的工具调用不贡献改动。Run 的 diff 按操作拼接，操作间用 `…` 分隔，每路径整个 Run 限 200 行改动/上下文（不含省略标记），不影响完整计数；格式见 [ask-json.md](ask-json.md)。

Run 结束只取已记录的改动，不重新读盘。bash、外部进程、父/其他子会话和后台任务在两次 edit/write 之间或最后一次写入之后的改动不归入当前会话；后续操作读到这些内容时，可以在 diff 中显示为未改动的上下文。后台 agent 的改动只由其自己的 Run 记录，随该任务的结果 changes 返回，不归入启动它或同时运行的前台 Run；子会话的 changes 也不会把父会话或 bash 同期的改动算给自己。这些记录不是当前磁盘状态或文件所有权的证明。write 沿用 16 MiB 的 before 读取上限；已有文件的 before 超限或无法读取时，写入仍可成功，但该次操作不计入 changes。中断时尚未发出 run_end 的改动也可能不在汇总中，失败后仍须检查半成品文件。

## 进度、用量与取消

任意工具调用失败都不会取消同一 Run 的其他调用，不限于返回 `ok:false` 的子 agent。顶层 Run Promise fulfill 和 reject 都继续 drain 在途及排队工具、JS jobs 和 continuation 新发起的调用；顶层 reject 时，Run 仍报告原始拒绝原因。因此 `Promise.all` 中 read 或 llm reject 后，其他前台 agent 仍会工作到完成：父 Run 要承担其剩余等待时间与用量，用户仍可按 Esc 取消。

llm 与 agent 的 usage 都计入本轮累计用量。用户取消（Esc/SIGINT/SIGTERM）或 JS 执行超时会中止整个 Run 的在途及排队工具；单个工具超时、bash 被取代或按 id stop 不影响其他调用。若整个 Run 中止时还有未完成调用，Run 输出保留一行 `[stopped before completion: bash #0, agent #2]`，索引按该 Run 内全部工具调用的创建顺序从 0 开始，不是后台任务 id。输出预算和 JS 执行预算见 [run-output.md](run-output.md)。

子进程 NDJSON 在运行途中按完整行观察；最终输出仍按原路径解析和统计。进度使用受互斥锁保护、每次调用仅保留最新快照的队列（同任务 id 的各次调用分开记账）；工具线程只更新队列，不调用 Session sink。Run 线程在 sandbox 的 Promise/工具等待循环里约每 20 ms 尝试转发，转发不计入 JS 执行预算；eval 返回前已停止并 join 所有前台工具线程，后台 agent 由父会话持有，不随 Run 结束而 join；进度队列在 Turn 结束时清理，后台任务的原 Run 进度会继续显示到结果插入。TUI 收到事件后复制数据到自身事件循环，在发起任务的 Run 下方默认显示子任务树，每个任务固定一行，按创建顺序排列并按 id 原地更新；接续 `a1` 的 progress 事件和 tree 行仍标为 `a1`，不生成新的任务 id。agent 行为 `  ├─ a1 prompt 摘要 · 状态 · step N · 工具名 变更文件`，bash 行为 `  └─ b2 bash 命令摘要 · 已运行时间 · 状态`（分支符按行位置变化）。前台 bash 运行超过 3 秒才出现在所在 Run 下，此后每秒更新时间，结束后保留最终状态；不到阈值的命令不出现，Run 标题不变。时间小于 60 秒显示为 `42.3s`，否则为 `3m12s`。普通后台任务在结果送达前显示 `background`；detached 任务运行中显示 `detached`，结束或被停止后显示最终状态。prompt 和命令最多预览前 40 个 Unicode 字符；窄屏先缩短 prompt/命令，再缩短末尾文件信息，优先保留 id、状态和 step 或时间，不换行。ctrl+o 只切换 Run 代码、结果及 diff 的展开，不隐藏子任务树。Run 结束恢复工具/耗时/改动摘要，并保留最后收到的子任务状态；从历史恢复的 Run 不重建子任务树。后台结果条目使用相同 id：成功为 `✓ b2 bash · ok · 输出预览`，失败为 `✗ a2 agent · failed · 文本预览`，丢失为 `✗ a2 agent · lost`；ctrl+o 展开仍显示完整 JSON 结果，历史恢复也使用相同格式。工具名来自最近一次 Run，文件仅为 edit/write 报告的变更路径，不代表当前正在执行的命令或任务完成百分比。

bash 与子会话复用标准库子进程等待和进程组执行器。所有 bash（包括 detached）在 shell 退出时清理整组，包括成功返回和 `nohup/&`；主进程退出后只排空管道中已有输出，不等待同组后台子进程。detached 任务随 shell 退出而结束，服务在命令内前台运行；`server & exit 0` 会结束任务并清理服务。stop、超时、Turn 取消/失败、Session 退出同样清理进程组。取消和超时时，子 nib 先收到 SIGTERM，有 500 ms 取消自身工具，之后强制终止。用量按已收到的累计快照统计，无法推知服务端尚未报告的 token。文件工具的 `read` / `edit` / `write` 通过 `$NIB_HOME/locks/` 中按目标规范路径 SHA-256 命名的持久 advisory lock 文件，协调共用 NIB_HOME 的独立进程和子会话；相对路径与符号链接别名共用锁，释放时不 unlink。`edit` / `write` 使用同目录 `.nib-*` 临时文件加 rename 原子替换；会话记录 inode、size、纳秒 mtime，`write` 拒绝覆盖已观察文件的外部改动，重新 `read` 后可重试，未观察过的已有文件仍可直接写入。bash／用户编辑器不参与该锁，版本检查只能发现检查前已经发生的改动，不能消除检查到 rename 之间与不合作写入者的竞争。完整的权限、符号链接、硬链接及持久性边界见 [run-output.md](run-output.md#文件替换会话版本与跨进程协调)。

## 工具说明的生成

新会话构建 system 时，`src/tools.zig` 根据有效 provider 配置生成 llm 的模型列表：内置模型取自 `src/provider.zig` 的表（Codex 的原目录保留在 `src/provider/responses.zig`）；旧 Chat Completions 至少提供 `src/provider/openai.zig` 的默认模型，另加入当前配置模型并去重。effort 说明只列常用的 low/medium/high，省略 model/effort 仍继承当前配置；完整档位与映射见 [config.md](config.md) 和 [codex.md](codex.md)。选择只在当前 provider 内进行，不隐式切换 provider。

工具说明中的模型名按 JSON 字符串编码，不直接插入原始配置文本。根会话与默认新建子会话使用同一生成路径，但默认子会话隐藏 agent；fork 复用父 system/schema，不重新生成，agent 的不可递归边界由运行时执行。恢复会话仍沿用日志原始 system，不改写历史。架构理由见 [ADR 0010](adr/0010-subagents.md)、[ADR 0013](adr/0013-llm-functions.md) 与 [ADR 0015](adr/0015-agent-fork.md)。

## 自动后台 Run

长 Run 不依赖模型主动传 `background:true`；达到默认 10 秒的可配置阈值并仍在等工具时，整个脚本继续执行，模型先收到 `rN` 通知。已 await 的工具返回类型不变，console 和 edit/write changes 延后一起交付。后台 Run 与其他 Run 共享 cwd 和文件观察状态；模型可继续工作，无需轮询完成结果，edit/write 后重跑同一命令会按下节语义取代旧执行。详细的并发上限、文件冲突边界、取消、展示预算与恢复语义见 [run-output.md](run-output.md#长-run-自动转后台)。

`tools.stop` 同时接受其他后台 Run 的 `rN`；Run 不能 stop 自己。后台 Run 非 detached，最终回答和 Step 上限仍等待结果送达。Run 的后续代码也可以启动显式后台 bash/agent，沿用其各自的普通或 detached 语义。只有 Session 主线程向 sink 转发进度/用量/结果；后台沙箱与工具线程不调用前台 sink。

无工具调用的文本回复在仍有普通后台任务时一定提交为 waiting Step 并进入本地等待；不看文本长短、不识别“等待”关键词。一个 Step 的全部 Run 都成功、没有输出且没有任何实际宿主工具调用（例如空 Run 或仅打印空行）时，同样等待，不额外请求模型。有计算输出或实际调用过工具的 Run 仍按正常工作处理，不能把任意 git/read/stop 调用自动当作等待。后台结果或用户插话到达后再继续；detached 任务保持跨 Turn 语义。

## 同一命令取代过时执行

同一 Session 的 bash 启动时，只要仍在运行的旧 bash 属于更早的 Run、命令字符串及启动 cwd 完全相同，且旧 bash 启动后本 Session 的 edit/write 确实修改过文件，就自动停止旧 bash 的进程组。无需先等旧验证结果；修改后可直接再次启动同一验证。命令不按语言或用途分类，不解析 shell 的 cd、参数或重定向。相同 Run 内的并行调用不互相取代，无修改的重复调用不取代、不缓存结果；新旧任一方显式 detached 都不参与。

旧调用 resolve 为 `{superseded_by:"bN"}`，没有 exit_code、output 或 error：它表示已被更新的同一验证取代，不表示验证通过或失败。后台 bash 的消息带 `background_ok:true`；自动后台 Run 的 await 拿到同样的数据，脚本继续执行，Run 最终状态由脚本决定。需要检查退出码的脚本可用 `if (!r.superseded_by && r.exit_code !== 0) ...`；无条件检查退出码的旧脚本仍可能自行抛错。只取代该 bash，不停止整个 Run 或其余工具，继续脚本仍可产生副作用。

修改代数在成功 edit/write 后推进，与界面 changes 统计是否启用无关；最多读取 16 MiB 比较旧内容，无效 edit、失败写入、已确认内容相同的覆盖不计，创建空文件也计。旧内容超过读取上限或不可读时，成功 write 保守地计为修改。它是 Session 级记录，不推断文件依赖，因此任何 edit/write 都可能使旧命令过时；bash 自身副作用、用户编辑、其他 Session/子 agent 的写入无法据此识别。进程组清理沿用 stop/取消路径，20 ms 轮询观察停止标志，新执行不等旧进程自然退出。匹配的全部旧命令各取代一次；后台并发准入限额仍正常检查。停止前已产生的文件或其他副作用不会回滚。设计取舍见 [ADR 0016](adr/0016-superseded-bash.md)，独立启动/取代事件及统计见 [日志](session-log.md#bash-启动与取代事件)。

API key 服务的有效配置经 stdin 只传密钥环境变量名，各子进程独立读取；仅选定密钥进入 nib 子进程，bash 仍清除密钥。新增缓存写入用量字段见 [providers.md](providers.md)。
