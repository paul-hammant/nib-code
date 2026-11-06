# 用本机 Codex 登录运行 nib

其他 API key 服务与自定义站点见 [providers.md](providers.md)。Codex 是共享 Responses 协议上的 ChatGPT 登录与 WS 扩展；默认行为保持不变。

先通过 `codex` 完成 ChatGPT 登录，再运行：

```sh
nib
nib ask '你好'
nib ask --json '你好'
nib --continue
```

默认读取 `~/.codex/auth.json`，可用 `CODEX_HOME=/path/to/codex` 指定目录。无需 NIB_API_KEY；非秘密设置可放在 `$NIB_HOME/config.toml`（默认 `~/.nib/config.toml`）的 `[codex]` 段，见 [配置说明](config.md)。环境变量 NIB_BASE_URL、NIB_MODEL、NIB_CONTEXT_WINDOW 优先于文件，切换服务时清理不适用的旧覆盖。

默认模型 `gpt-6.1-sol`，窗口 500,000 tokens。显式选模型：

```sh
NIB_MODEL=gpt-6-sol NIB_REASONING_EFFORT=high nib ask '你好'
```

也可以写入 `~/.nib/config.toml`（设置 `NIB_HOME` 后则放在该目录）：

```toml
provider = "codex"
effort = "medium"

[codex]
model = "gpt-6.1-sol"
context_window = 500000
```

以上选择用于后续启动；环境变量仍可临时覆盖，`--effort` 的优先级最高。

本机 pi `catalog/providers/openai-codex.ts` 的列表（2026-11-01，一手源码）：

| 模型 | 默认窗口 |
|---|---:|
| gpt-6.1-terra、gpt-6.1-sol | 500,000 |
| gpt-6-astra、gpt-6-sol、gpt-6-luna | 272,000 |
| gpt-5.6-luna、gpt-5.6-sol、gpt-5.6-terra | 272,000 |

未知模型需设置 `context_window` 或 NIB_CONTEXT_WINDOW，避免猜测窗口。模型是否可用取决于账号。

也可以不用环境变量，直接控制当前进程的 effort：

```sh
nib --effort high
nib ask --effort high '你好'
```

TUI 用 `/effort` 查询，`/effort high` 切换，状态栏显示请求使用的 effort。

`--effort` 和 `/effort` 接受 `default|off|none|minimal|low|medium|high|xhigh|max`，具体档位是否可用由模型和服务端决定。显式档位会启用 thinking 并覆盖环境和文件配置；`off` 按模型能力关闭或降到最低档；`default` 清除 thinking/effort 覆盖，交由服务端决定。这里只显示客户端请求配置，不代表服务端确认的实际推理量。

TUI 切换只在空闲时处理，从后续 Turn 生效，子 agent 同步继承。`/effort <level>` 只原子更新 `$NIB_HOME/config.toml` 的顶层 `effort`，保留其他行与注释；`/effort default` 删除该键。CLI `--effort` 不落盘。优先级为 CLI effort > 环境变量 > 文件 > 默认值；恢复会话仍按本次启动的有效配置。摘要继续使用独立的最低推理策略。

NIB_THINKING=on 默认用 medium；NIB_REASONING_EFFORT 可显式指定服务端支持的 effort。NIB_THINKING=off 覆盖 effort：能关闭的模型用 none，sol/astra 用允许的最低档 low；未设置环境推理覆盖时使用文件 effort，再无配置则沿用服务端默认。

## effort 与 prompt 缓存

分析本机 `~/.nib/sessions` 中 Codex、`gpt-6.1-sol` 的实测日志：只比较同一 Turn 内相邻 Step，按请求实际使用的 effort 是否变化分组，计算后一个 Step 的 `prompt_cache_hit_tokens / prompt_tokens`，并对照切换前的命中率。

| 相邻 Step 的 effort | 后一个 Step 样本量 | 缓存命中率中位数 | 平均值 |
|---|---:|---:|---:|
| 相同 | 1,504 | 96% | — |
| 改变 | 12 | 0% | 15% |

例如 `high 99% → medium 0%`、`medium 96% → low 0% → low 99%`；切回之前用过的档位能部分恢复（47%–70%）。这些样本表明 Codex 的 prompt 缓存按 effort 分开；这是当前模型和线路的观测，不是服务端协议保证，也不能外推到 Chat Completions（如 DeepSeek）。

切换后的请求可能按未缓存计费整段上下文，上下文越大代价越高。Run 的 effort 仅作用于下一次模型请求；Run 失败或用户插话后会自动恢复用户档位，因此一次降档通常意味着两次缓存失效（切回旧档位可能部分命中）。Codex 新会话的 system 在 effort 说明旁用两句话陈述这个事实；Chat Completions 的 system 不加这句，也不作为 `NIB_PATCHES_OFF` 可关闭的补丁。提示改变会使新会话的 `system_sha` 改变，恢复会话仍沿用原始 system。

**删除条件：** 如果之后按上述方法统计显示切换 effort 不再导致缓存失效，就删除 system 中这句提示，并同步更新对应测试与本文。

## fork 与父缓存路由

`tools.agent({ prompt, fork: true })` 创建独立子会话，但 Codex 请求的 `prompt_cache_key` 使用父会话的值，不改用新子会话 ID。fork 继承父会话压缩后的当前完整 history（含发起 fork 的当前 assistant 及 reasoning，之后补合成 tool results 和 user prompt），system/工具 schema 与父会话逐字节相同。共用 key 的目的，是让相同前缀的请求路由到同一缓存。

2026-11-04 用 `gpt-6.1-sol`、默认 effort 做了两轮真实对照（同一任务，父会话先读文件，再分别以 `fork: true` / `false` 委派同一个问题）：

| 子会话 | 第一个请求 prompt | 缓存命中 | 子会话 Step | 子会话耗时 |
|---|---:|---:|---:|---:|
| fork，父上下文约 2k | 2,166 | 1,920（89%） | 2 | 5.8 s |
| 新建，同上 | 1,575 | 0 | 2 | 6.7 s |
| fork，父上下文约 6.6k | 6,814 | 6,528（96%） | 1（未重读文件） | 3.9 s |
| 新建，同上 | 1,579 | 0 | 2 | 7.9 s |

样本很少，只说明共用 key 时首请求能命中父前缀，不是服务端保证；上下文更大时的收益仍需 `stats.py` 的 `child_costs.by_creation` 持续观察。若之后统计显示 fork 首请求命中率不再明显高于新建子会话，就重新考虑共用 key。

model/effort 默认继承父配置，也可显式覆盖；两者不同时不再具有父前缀的缓存复用优势，共用 key 不改变这一点。Codex fork 适用与 resume 相同的模型一致性检查，覆盖 model 不能将父历史中的加密推理条目跨模型使用。后续可在同 model/effort、相同父前缀下对照父 key 与独立 key，记录首请求的 `prompt_cache_hit_tokens / prompt_tokens`、未缓存输入及耗时；结果不支持路由收益时重新考虑共用 key。完整语义及置信度见 [委派工具](tool-delegation.md) 与 [ADR 0015](adr/0015-agent-fork.md)。

## 摘要与会话恢复

摘要始终使用当前模型，保留原请求前缀和该模型的加密推理条目，以命中缓存并避免跨模型传递密文。能关闭推理时关闭，否则用 low。Codex 摘要不沿用 Chat Completions 的小额总输出限制：按 pi 的请求格式不发送 max_output_tokens，保留服务端正常输出额度；原 32–2048-token 预算只写进提示约束摘要文字，给推理留出空间（pi 目录 maxTokens 为 128000，实际限额仍由服务端决定）。空摘要、截断、压缩无效等失败，自动压缩发 notice 后继续；手动压缩报告错误。

会话记录 provider 和模型；跨 provider 恢复会拒绝，使用原 provider 或开新会话。Codex 恢复模型也要相同，以免加密推理条目跨模型；Chat Completions 恢复沿用原行为，采用当前模型配置。环境和配置文件均未指定 provider 时默认使用 Codex（2026-11-02 起，此前默认 DeepSeek）；设 `NIB_PROVIDER=chat_completions` 使用 Chat Completions 线路，默认 DeepSeek。

凭证缺失、格式错误或 401 会给出登录提示。401 只重新读取文件并重试一次，让 Codex CLI 已刷新的凭证生效；仍失败请运行 `codex` 重新登录。nib 不使用 refresh_token。凭证不进入会话日志、argv 或子进程环境。tools.agent 从 stdin 接收有效配置，跳过配置文件读取，各自读取 auth.json；bash 不继承常见密钥环境变量。read/edit/write 拒绝凭证文件，bash 拒绝引用凭证目录；这些是防误操作保护，不是系统沙箱，详见 [ADR 0006](adr/0006-deny-dangerous-commands.md)。

## 流活动

推理摘要默认关闭，可按[推理摘要配置](#推理摘要)开启。加密推理条目原样回传；日志同时保留服务端有序输出，避免 commentary 和 reasoning 交错时重排前缀，见 [会话日志](session-log.md#step-传输字段)。

TUI 的最后活动时间只由真实推理、正文、工具参数增量和工具进度更新；传输心跳、metadata、usage 和纯计时更新不算进展。超过 30 秒无进展，活动行追加 `· no progress Ns`，内容到达后清除。活动行显示等待模型、生成 Run、执行工具或等待后台任务，以及整个 Turn 的累计耗时；后台等待显示任务 id 和运行时长，不提供 ETA。活动通知只用于 TUI，不新增 ask NDJSON 事件。传输字节与内容超时仍使用下文和 [config.md](config.md) 的独立计时，不受这项显示改动影响。详细交互见 [tui-ux.md](tui-ux.md)。

## 流失败与重试

流中的 `error`、`response.failed`、`response.incomplete` 保留服务端 code/message 或 incomplete reason，报错格式为 `Codex stream failed: <code>: <message>; the Step was not committed.`；message 按 UTF-8 边界截到约 300 字节。

`context_length_exceeded`、`insufficient_quota`、`usage_not_included`、`invalid_prompt` 和请求类 4xx（429 除外）不重试。`server_error`、限流、过载/服务不可用、未知 code 和 `IncompleteResponse` 断流最多尝试 5 次，默认等待 1、2、4、8 秒；限流消息里的 `try again in Xs` / `Xms` 可覆盖本次等待，支持小数。沿用既有 retry 事件和 TUI 提示。

Codex 即使已经流出文本或推理也可重试；失败尝试的 delta 已显示，不回滚，因此界面可能出现重复片段。重试使用相同请求，清空用于取消提交的失败 partial；成功时只提交成功尝试的完整 Step，最终回答取 `end.text`，不要拼接所有 delta。Chat Completions 仍只在没有流出 delta 时重试。

不重试或重试耗尽后，日志另追加 `diagnostic`（`error_name`、含 code/message 的 `message`、`attempts`、失败的 `step`）。诊断不进入模型上下文，不改变已提交消息或 context_tokens；恢复忽略它，`scripts/stats.py` 将其单独计入 `errors.provider_failure`，不增加 Step 或 token。取消仍走原有中断提交路径。

本地验证（全为临时虚构凭证）：

```sh
zig build test --summary all
zig build
python3 tests/test_session.py
python3 tests/test_codex.py
zig build -Doptimize=ReleaseFast
```


## Responses WebSocket 传输

默认使用 Responses WebSocket，配置为：

```toml
[codex]
transport = "websocket"
```

设 `NIB_CODEX_TRANSPORT=sse nib ask '任务'` 或 `[codex] transport = "sse"` 可强制 HTTP POST + SSE，环境变量优先于文件。握手/协议失败后本 Session 自动降级 SSE。默认值与已验证的 v7 bench 配置一致；其余默认值为 custom Run、16 KiB 展示预算、关闭 reasoning summary。配置随有效 Config 传给子会话；`tools.llm` 单次调用持有独立的临时状态，不共享主 Session 的 socket。

### 协议与来源

以官方 [openai/codex rust-v0.166.0](https://github.com/openai/codex/tree/rust-v0.166.0) 为准：

- [codex-client/src/provider.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-client/src/provider.rs#L91)：Responses 路径不变，http/https 对应 ws/wss。nib 在 `https://chatgpt.com/backend-api/codex/responses` 发 GET Upgrade，经 TLS 后读写 WS 帧；本地 mock 用 http。
- [core/src/client.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/client.rs#L1635)：非 input 字段相同，当前 input 以上次 input 加完成输出为前缀，才续接。请求继续带 store:false、prompt_cache_key、reasoning.encrypted_content；握手采用 `OpenAI-Beta: responses_websockets=2026-02-06`、Authorization、chatgpt-account-id、originator、session-id、x-client-request-id，`x-codex-routing-hint` 为 `model=<model>`（未启用 fast，不加 tier）。
- [codex-api/src/common.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/common.rs#L333)：每个文本消息为扁平的 `{"type":"response.create", ...}`，不是外包 response 对象。`previous_response_id` 与缩短后的 input 一起发送；`generate:false` 只用于预热。nib 不实现可选预热，因此首请求包含握手耗时。
- [codex-api/src/endpoint/responses_websocket.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/endpoint/responses_websocket.rs)：沿用 Responses JSON 事件；顶层 error 可含 status/status_code 和嵌套 error.code/message。previous_response_not_found、websocket_connection_limit_reached 可恢复。turn-state 从握手响应头或 [response.metadata.headers](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/sse/responses.rs#L214) 获取，后续同 Turn 请求放在 client_metadata["x-codex-turn-state"]。每个新 Turn 清空旧 token。
- [core/src/session/startup_prewarm.rs](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/core/src/session/startup_prewarm.rs)：官方有后台预热/交接；其等待策略不直接照搬到 nib。

本机 jcode 的 ws_input.rs / openai_ws_connect.rs 与 pi 的 getCachedWebSocketInputDelta 用于交叉参考；发生分歧以该官方 tag 为准。

### 生命周期、失败与限制

每个 Session 串行使用一个独占 WS 连接；后台 agent 是独立子进程，fork/resume 不复制连接或 response id。上一响应成功后保存非 input 属性、已发送的完整 input 和规范化后的服务端有序输出。完整输出按顺序随 Session 日志保存：message 规范化为 role/content/phase（含空消息），function_call 保留 type/call_id/name/arguments，custom_tool_call 保留 type/call_id/name/input，reasoning 保留原条目。后续请求回放同一有序输出，不从合并后的展示文本重建；恢复和 fork 同样保序。实际前缀不匹配或未知输出条目时发送完整 input。无服务端 id 时也发完整 input。压缩前后清除续接，effort/instructions/tools/schema 等改变时由属性匹配拒绝续接；凭证、模型、端点或缓存 key 改变时关闭旧连接。

previous_response_not_found 在尚未输出 delta 的增量请求上只补发一次完整 input；不重复执行 Run。完整重发仍失败时交回错误。websocket_connection_limit_reached、断流、空闲超时沿用最多 5 次重试，下次新连接发完整 input。只有明确的握手失败（含不支持升级或无效 accept）、WS 协议或超大帧错误记住 Session 级 SSE 降级；连接错误和响应内容校验失败保持 WS 重试，不因 InvalidResponse 改用 SSE。每次降级立即持久化原因、时间及协议诊断；发生于可见 delta 后先走已有重试清理 partial，再请求 SSE，因此 UI 仍可能显示失败尝试的片段，日志只提交成功结果。

沿用 provider/cancel.zig 的取消并 join：Esc/SIGINT 中断阻塞 I/O，丢弃连接，后续 Turn 全量发送。取消不等待 close 握手；正常收到 close 回复 close 后重连。空闲超时使用 provider/idle.zig，在 TLS/HTTP 缓冲之下监测读操作，帧、ping/pong、元数据均算字节活动；另外以 120 秒限制无内容停顿，以 300 秒限制单次尝试，总超时不受心跳或持续摘要延长。三个值均可配置，见 [config.md](config.md)。

帧层支持随机客户端 mask、短/16/64 位长度、文本分片、ping/pong/close、UTF-8 与控制帧校验。服务端单消息上限 16 MiB；超过或收到二进制/扩展帧则降级 SSE，不截断数据。不协商压缩/扩展。TLS、证书与代理行为复用 std.http.Client；本机真实 ChatGPT 网关已验证 custom Run 与增量续接，v7 也已用于正式 bench，这不覆盖所有代理、长空闲连接与账号策略。没有连接池并发复用，一个 Session 同时只允许现有的一个主模型请求。传输决策见 [ADR 0017](adr/0017-codex-websocket.md)。

后台 Run 完成消息只追加到已提交历史末尾；等待回复的本地 waiting 标记不进入线上 input，因此后续可只发后台 user 消息。前缀不一致仍全量发送。后台等待不运行流空闲计时器；服务器关闭闲置连接时，下一 Step 走已有重试，新连接清除 previous response 并发送完整历史。

本地测试：`python3 tests/test_codex_websocket.py` 覆盖增量、前缀/配置变化、缺失 response 重发、握手/协议降级、帧分片和 ping/pong、turn-state、重连、fork、恢复、SIGINT、Esc 后继续、跨 Turn 复用、后台等待期间无额外请求、后台消息的增量/前缀回退、闲置连接关闭重连及空闲超时、心跳/元数据无内容超时、持续推理请求总超时、交错多条消息的精确增量续接。日志与统计字段见 [session-log.md](session-log.md#step-传输字段)。

### 比较实际传输

性能对照使用同一 ReleaseFast 二进制、模型和 effort；记录源码提交、包装器及实际二进制哈希。bench 会清理外部 NIB_* 环境变量，传输对照需由包装器分别设置 `NIB_CODEX_TRANSPORT=sse` / `websocket`。新建独立 Session、交错运行，并分开观察冷首步和后续 Step。

`python3 scripts/stats.py <日志目录> --group-by transport --json` 可比较实际线路的 model_ms、first_data_ms、code_first_ms，并核对 incremental、input_items/input_bytes、transport_fallback；按 full_reason 分组可观察全量发送的原因。降级 SSE 的 Step 包含先前 WS 成本，不是纯 SSE 对照。任务成功率、Step、token/cache 和总墙钟一起判断；mock 耗时不证明性能收益。详细口径见 [日志](session-log.md#step-传输字段)。

## 推理摘要

默认不发送 `reasoning.summary`，保留 effort、`include:["reasoning.encrypted_content"]`、`store:false` 及历史 reasoning；SSE 和 WebSocket 共用请求构造。没有摘要时 TUI 不增加空块，`ask --json` 不产生空的 reasoning delta；加密 reasoning 仍用于续接。

要恢复可读摘要，配置 `[codex] reasoning_summary = "auto"`（写成段内键），或设置 `NIB_REASONING_SUMMARY=auto`；`off` 显式关闭，环境优先。即使 effort 交由服务端默认，`auto` 也会发送 `reasoning:{summary:"auto"}`。

关闭摘要的依据是本地 request-flags 对照中首工具参数更早到达，reasoning tokens 未见稳定下降；这不是关闭推理，也不保证整个任务等量提速。实验数据保存在相邻 `nib-speed-notes/`，默认值可按用户对可读摘要的偏好调整。

## custom Run 工具

默认使用 Responses custom 工具，模型直接输出 JavaScript，省去 function 参数里 JSON 字符串的额外转义。工具使用 Lark grammar（`SOURCE: /[\s\S]+/`），接受可选首行 `// @run: {"effort":"low"}`；grammar 只限定外层形式，不校验 JavaScript 语法。effort 的用户上限、单次生效和失败护栏不变，见 [配置](config.md#逐-step-effort-调度)。`[codex] run_tool = "function"` 或 `NIB_CODEX_RUN_TOOL=function` 回退到旧 function 工具；Chat Completions 保持原协议。

历史按每次调用自身类型编码：新 custom 调用和结果为 `custom_tool_call` / `custom_tool_call_output`，旧 function 调用和结果保持 `function_call` / `function_call_output`。恢复旧日志时不把旧 JSON code/effort 转成 custom；反向回退时也不改写已有 custom。这样保留原参数字节、加密 reasoning 和缓存前缀，只在本次工具定义变化处产生预期差异。恢复本来就新建连接并发送完整历史；同连接工具配置不变时，规范化的 custom output 能参与既有 WS 前缀判断，后续仍只发送增量结果。

内部和主日志继续以 `tool_calls[].function.arguments` 的 JSON `{code}` 承载可执行源码，custom 调用额外以 `type:"custom"` 区分；原始 Responses output 同样保留。Run 执行、fork、恢复与离线 replay 共用已有链路。参数到达计时记录线上载荷：custom 是原始 JS input 的 UTF-8 字节，function 是 JSON arguments 字节；两者不能直接按规范化 JSON 长度比较。

Run 语法或运行错误的模型输出会提示修正脚本并继续任务；SyntaxError 保留 QuickJS `<run>:行:列`，追加附近最多 200 字节的 UTF-8 源码行片段。这些提示不强制模型继续，也不能解决所有提前结束行为。历史、effort 与转义取舍见 [ADR 0018](adr/0018-custom-run.md)。协议参照 [OpenAI custom tools](https://developers.openai.com/api/docs/guides/function-calling#custom-tools) 和本地 Codex CLI 0.166 trace。
