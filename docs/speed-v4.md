# speed-v4：超时、后台等待与 WS 续接

基线：`feat/speed-v1` 的 `b290edc88e974132a691e0c96a89e7b545a6c743`（speed-v3）。分析输入为 `/home/yang/myself/nib-bench/runs/formal-20261105/` 的全部 20 个 `*-nib-speed-v3` 主会话日志、calls 录制、agent NDJSON、result/invocation；没有运行真实模型。

## 1. 长模型请求与降级

### 正式日志证据

`b001-0007-console-tail-nib-speed-v3/nibhome/sessions/6befbb5a14befcf26ccce67f2451521d.jsonl` 第 31、32 行分别是 Step 20、21：前者 WS；后者 model_ms=869886、attempts=4、transport=sse、first_data_ms=2、max_gap_ms=4998。

原始 Step 21 **已经有** `transport_fallback:"InvalidResponse"`，并非 null；Step 22 也保留该值。缺的是触发事件的细节与降级时刻。旧 `fallbackError` 把响应内容校验错误 InvalidResponse 当成 WS 不兼容，导致整 Session 此后黏在 SSE。只看最终成功 transport 又会看不到同一步最早使用过 WS。

同目录 `agent.jsonl` 第 355–488 行给出的尝试序列是：

- attempt 1：WS，收到 17 条 reasoning 摘要 delta，随后 `WebSocketFallback`（第 428 行），预设退避 1000 ms。因为已经输出 reasoning，旧实现先退出，再以 SSE 重试。
- attempt 2：SSE，16 条 reasoning 摘要 delta，`InvalidResponse`（第 445 行），退避 2000 ms。
- attempt 3：SSE，16 条 reasoning 摘要 delta，`InvalidResponse`（第 462 行），退避 4000 ms。
- attempt 4：SSE，20 条 reasoning 摘要 delta，随后文本和 `git diff --check` 的工具调用，成功。

这不是“只有心跳”。预设退避共 7 秒；约 862.9 秒是请求、模型输出、解析等耗时。agent NDJSON 没有逐事件时间，旧日志也没有逐 attempt 时长或原始 SSE/WS 帧，因此无法再准确拆分各次耗时、每次内容静默长度，或定位 InvalidResponse 对应的原始字段。不能把最后一次的 max_gap_ms 当作四次尝试的最大间隔；first_data_ms=2 是整个 Step 首次活动，包含最早的 WS；code.first_ms=869782 也包含此前尝试和退避。agent.err 为空，calls 只录工具，不录 provider 帧，result/invocation 没有更多协议诊断。

后台 r4/b4 在该模型请求开始约 27 秒后完成（任务总耗时 37101 ms，agent NDJSON 第 416–417 行），但结果直到 Step 21 结束才在第 489 行交付。模型不知道已经排队的结果，摘要反复出现 Waiting/Getting the message/Awaiting arrival。根因还包括模型没有及时结束当前响应，而不仅是传输空闲检测。

另外，`b003-0036-grep-column` Step 11（主日志第 16 行）148915 ms、WS 单次成功、max_gap_ms=6008，保存了 67 个 reasoning 条目；`b003-0030-console-tail` Step 17（主日志第 25 行）60309 ms、max_gap_ms=5894，19 个 reasoning 条目，首段代码 60202 ms。可见这批长推理确有摘要输出，但不能据此保证所有正常推理都会持续发可见 reasoning delta。

### 修复

- 只有明确的 WS 握手、帧协议、消息过大错误才触发 Session 级 SSE 降级。连接失败、InvalidResponse 和响应字段解析失败沿用 WS 重连重试。
- 每次降级和 previous_response_not_found 原地全量重发立即持久化原因、Unix 毫秒时间与可用诊断；取消不会丢掉这条记录。最终 Step 仍保留降级原因与原始发生时间。
- 协议错误记录阶段、最后事件类型、output_index、条目数与 pending 数；不记录原始认证头或路由 token。
- 每个外层 attempt 记录起止时间、实际传输、是否增量、完整请求原因、错误、响应字节、内容字节和内容间隔。已流出 delta 后转 SSE 时，失败 attempt 仍正确记作 WS；下一 attempt 才是 SSE。最终失败的 diagnostic 也保存全部尝试。
- 新增内容空闲截止时间和总请求截止时间；WS/SSE、主模型、llm、摘要及子会话均继承。总截止时间通过取消并 join 整个请求实现，覆盖连接、发送、读头和响应读取。

### 阈值依据

对 381 个 attempts=1 的完整 Step，用 nearest-rank 统计：

- max_gap_ms：P50=2935、P90=5336、P95=5886、P99=7455、最大 9830 ms。它是响应字节间隔，含心跳。
- 350 个工具调用的 code_first_ms：P50=5365、P90=9158、P95=12227、P99=27797、最大 60202 ms。
- 最长单次成功请求 148915 ms，不能用 30/60 秒总上限杀掉它。

默认值：已有字节空闲 `stream_idle_timeout_s=300` 保持；新增 `stream_content_timeout_s=120`，只由非空 reasoning/文本/工具参数 delta 重置；新增 `request_timeout_s=300`，持续摘要也不能无限延长。120 秒约是已观察最大首段代码等待的两倍，300 秒约是最长单次成功请求的两倍。配置范围均为 1–3600 秒。内容/请求超时沿用既有重试次数、退避及 Chat 可见 delta 的重放边界。

官方 Codex CLI rust-v0.166.0 的依据：

- [model-provider-info/src/lib.rs#L71](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/model-provider-info/src/lib.rs#L71)：默认 stream idle=300000 ms；WS connect=15000 ms；stream/request retry 默认分别 5/4。
- [codex-api/src/sse/responses.rs#L579](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/sse/responses.rs#L579)：对 eventsource 解析后的下一 SSE 事件使用 idle timeout；SSE 注释心跳不会成为业务事件。
- [codex-api/src/endpoint/responses_websocket.rs#L793](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-api/src/endpoint/responses_websocket.rs#L793)：接收 WS 下一消息使用 idle timeout；发送也使用超时。
- [codex-client/src/provider.rs#L86](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/codex-client/src/provider.rs#L86)：stream request 的 timeout 为 None。**300 秒总请求上限是 nib 的选择，不能冒称 CLI 的默认总超时。** CLI 的活动超时本身也不能解决持续发送 reasoning 摘要的等待循环。

这不是整 Step 的 300 秒上限。最多 5 次尝试，每次重新计时；若每次都有内容、接近总截止时间才失败，累计仍可达约 1515 秒。因此不声称一定消除原有 869 秒样本的长尾；等待修复和新诊断需要下一次正式批次验证。

## 2. 模型停止自己的后台验证

逐条核对 calls 录制，实际是 **6/20 个 run、18 次 stop，全部 stopped=true**，而非 5 个：

- b003-0031-timers：6 次，主 Step 13/16/21/25/30/32；calls 第 33/42/51/59/70/73 行，依次 r1/b2/r2/b4/b5/r3；waiting=0。
- b001-0011-timers：5 次，Step 10/11/16/21/23；waiting=2。
- b004-0039-bash-amp：3 次，Step 9/12/15；waiting=0。
- b005-0051-timers：2 次；b005-0057-bash-amp、b004-0040-console-tail 各 1 次。

b003-0031 的主日志第 9、13–15 行等文本看似“测试仍在运行”，实际上同一 assistant 响应还带 `console.log('')`、git status 或 stop 的 run 调用，**不是无工具调用的短回复**。既有本地等待分支要求 tool_calls.len=0，因此 waiting=0 符合代码，并非文本长度或 phase 错误。模型把文字与一个空 Run 或工具调用绑定，绕过等待；stop 又没有任何理由参数和取消代价说明。

修复：

- 提示明确要求立即结束响应，不要用 run/console.log 模拟文字回复；原有无工具调用回复无论长短都进入本地等待。
- 对全部 Run 都成功、无输出、无实际宿主工具调用的 Step 同样本地等待，保存 waiting 标记；有效的纯 JS 计算输出仍继续，避免阻塞 queued fork 等独立工作。
- stop 改为 `tools.stop({id,reason})`，reason 必须非空白，否则 reject 且不取消。说明、拒绝信息和实际停止后的 notice 都提醒：取消未完成测试不能得到通过结果，重启会重复工作；不会回滚已经写入的文件或缓存。
- 不依赖命令名或静默时长猜测“正常验证”。所有显式 stop 一致要求理由，允许具体失败、需求变化和用户要求；不自动审查理由的自然语言含义。进程组清理、join、接续身份与完成投递规则沿用现有实现。

mock 覆盖无工具回复、空行 Run、缺少/空白理由保留正在运行的任务、带理由停止及后续 resume/replay。原有 queued fork 和后台边界测试证明纯 JS 输出没有被错误拦住。

## 3. WS 增量命中

正式批次共 383 个 Step：264 个 WS incremental、117 个 WS full、2 个 SSE。264/381=69.29% 是包含首步的 WS 命中率。

117 个 full 的可观察分布：

- 20 个是各 run 首步。
- 1 个可确定为重连：b001-0003-grep-column Step 8（主日志第 10 行），attempts=2，agent NDJSON 的 retry 原因为 EndOfStream；连接重建后发完整历史。
- 剩余 96 个单次请求都紧随含文本的 assistant 输出：87 个前步同时有工具调用、9 个前步是 waiting 回复。
- 上述 96 个里，33 个请求前插入过后台结果（24 个前步含工具，9 个 waiting）；其余 63 个没有这种插入。
- 全批次没有 effort 变化或历史压缩替换。重连那一对也紧随文本+工具输出，若只按前步内容关联会被误计进 88 个文本+工具样本。

旧逻辑将服务端多个 message 的 delta 合并为一段展示文本，reasoning 全部先放到前面，最后再重建 function_call。服务端输出若是 reasoning → commentary → reasoning → call，或多条不同 phase 的 message，本地重建就不再等于保存的服务端 output 前缀。后台 user 消息和 waiting 标记本来就是后缀/本地元数据，问题出在它们之前的输出重建。旧日志没有保存原始有序 output 或 baseline，因此不能把这 96 个历史请求逐一还原到首个不同下标，也不能把“前面插入后台结果”直接断言为唯一原因。

修复按服务端顺序保存完整输出，在下一请求、恢复和 fork 中使用同一规范化路径回放。message 保留各自 role/content/phase（含空消息），function_call 保留必要字段，reasoning 原样保留；展示仍可合并。通过 `reasoning.includes_output` 标记新格式，旧日志的推理数组仍按原方式恢复，估算 token 不重复计算。未知输出条目保持原来的全量重建回退。

新增 full_reason；实际前缀不匹配还记录零起始 mismatch_index。首步、effort、压缩、重连、scope、缺失 response、属性变化和未知输出均有明确原因。`scripts/stats.py --group-by full_reason [--json]` 可按完整 Step 分组；成功增量归 incremental，旧字段缺失归 unknown。

mock 证明交错 reasoning/commentary、拆分多消息、空消息、waiting 回复加后台结果可严格后缀续接；配置变化、压缩、重连、未知输出仍走相应全量路径。没有跑付费批次，**没有 speed-v4 真实增量命中率或性能结论**。

## 改动范围

- provider：`provider.zig`、`provider/{idle,body,cancel,openai,codex,codex_ws,retry,timing}.zig`；配置 `config.zig`。
- Session：`session.zig`、`session/{run,prompt,log,history,compact}.zig`；工具 `tools.zig`、`tools/stop.zig`；统计 `scripts/stats.py`。
- 测试：stream idle mock、新截止时间与 WS 回归、后台 Run 等待、全部 stop 调用/返回 fixture、fork/reuse/replay 兼容、统计分组。
- 文档：配置、Codex 线路、Session log、工具委派、Run 输出、ADR 0014、0.3.0 接口说明及本文。

## 验证与产物

- `zig build`、`zig build test --summary all`（419/419）、`zig fmt --check src build.zig`、`git diff --check` 通过。
- 全部 17 个 Python 测试程序通过：test_session、test_agent、test_agent_reuse、test_agent_fork、test_background_agent、test_background_bash（95 项）、test_background_run、test_codex、test_codex_websocket、test_llm、test_stats、test_effort、test_interjections、test_limits、test_replay、test_stream_idle（26 项）、test_files。均为本地 mock/虚构凭证。验证日志保存在 `/tmp/nib-speed-v4-evidence/verified/`，results.json 列出各程序最近成功结果；修复后复跑受影响项，复用其他已通过结果。
- 交付路径：`/home/yang/myself/nib-bench/bins/speed-v4`；实际 ReleaseFast 程序为同目录 `speed-v4.real`，包装器固定设置 NIB_CODEX_TRANSPORT=websocket。构建使用 build-nib.py 的临时本地 clone，复制 content-addressed zig-pkg、隔离 Zig 缓存，不切换源检出。
- 来源提交、包装器/实际二进制 SHA256、构建时间及参数以 `/home/yang/myself/nib-bench/bins/speed-v4.json` 为准；nib-bench 的 Speed v4 README 段记录独立构建后的 manifest 校验、ReleaseFast 本地 WS mock 与 `--fake` 四任务检查。fake 批次路径为 `/home/yang/myself/nib-bench/runs/smoke-speed-v4-fake/`。fake 仅验证基准驱动，实际二进制另用虚构凭证的本地 mock 验证。
- nibcode 与 nib-bench 分别提交，均带指定 Co-Authored-By；没有 push、PR 或真实付费模型调用。

## 遗留风险

- 120 秒没有可见内容的合法静默推理，或 300 秒仍未完成的合法请求，会被中断；可在 limits 调高。持续摘要可延长内容空闲但不能延长总请求上限，重试累计仍可能很长。
- stop 是有意的接口变化：仓库内调用已更新；自定义脚本必须提供 reason。恢复会话保持旧 system，模型若用旧签名会收到明确拒绝提示，不会被悄悄取消任务。
- 旧日志没有 provider 原始帧和逐 attempt 时间，无法补造此次 InvalidResponse 的具体字段或各次耗时；新诊断解决后续可观测性。
- 新日志含新增字段和完整有序输出标记，读取应使用 speed-v4；不保证旧二进制能读取新格式。
- 本次只用本地 mock/fake；真实 TLS/代理/网关和正式模型批次没有验证，也不保证提示变化能完全阻止模型以其他工具重复轮询或提供形式化理由后停止测试。
