# speed-v6：custom Run 与脚本失败后继续

基于 speed-v5（02be65c），Codex 默认 custom/freeform `run`，Chat Completions 保持 function。没有新增依赖或第二种执行器；模型直接生成 JS，provider 在完整 output_item.done 到达后规范化成现有 `{code}`，用 `ToolCall.type = "custom"` 保留协议类型。SSE 与 WS 共用请求构造、解析与计时，custom input delta 也重置内容超时。

## 证据核对

`nib-bench/runs/formal-20261106/b002-0021-console-tail-nib-speed-v3/nibhome/sessions/7ee30febd3e7f0ec2f260215ef219efe.jsonl` 第 5 行（Turn Step 4）：JS 双引号 shell command 内含未转义真实换行，QuickJS 返回 `SyntaxError: unexpected end of string`、`at <run>:1:39`；工具尚未执行（tool_bytes=0）。Step 5 就回复无法完成，没有修正脚本或修改仓库。原错误有行列，但没有源码片段和继续提示。

同批 `b002-0020-console-tail-nib-speed-v5/nibhome/sessions/43a6161eacfa4d86e0b8fdfaaa3f023a.jsonl` 的 Step 1–3 全部 Run 成功，Step 4 直接回复未完成；主日志和 agent.err 没有 SyntaxError。它证实提前结束，但不能归因为脚本语法错误。

request-flags README 的原始表格中 grep 点 A（function）为 7/8 语法失败，E（仅 custom）为 2/8，G（summary/verbosity/context/custom 合并）为 0/8；“custom 单因素 0/8”与文件证据不符。custom 减少 JSON 转义负担，不是 JS 语法验证器，也没有稳定延迟收益保证。新 system 和 Run 失败输出简短要求修正脚本继续任务；SyntaxError 在原 QuickJS 栈后附附近最多 200 字节的源码行，避免长行再次挤占展示预算。

## effort 与历史取舍

两批正式主日志扫描到 942 + 890 = 1832 次 Run 参数，仅 1 + 1 次带 effort，均为 high。已有 effort 调度和用户上限有明确用途，因此不删除；也不增加低使用率的第二个 function 工具。custom 的可选第一行 `// @run: {"effort":"low"}` 是正常 JS 注释，原样留在源码、原始 output、规范化参数和 replay；仅第一行识别，严格解析 low/medium/high/default，非法 pragma 返回可修正错误。成功 Run 的声明复用现有一次性调度和用户 effort 上限；失败声明不降档。自动转后台的 Run 沿用原行为，不据未完成结果应用声明。

`[codex].run_tool = "custom"|"function"` 和 `NIB_CODEX_RUN_TOOL` 控制新请求的工具定义，默认 custom，环境优先，子会话继承有效 Config。回退只改变工具定义，不改写任何已保存调用。

旧 function 调用保持 arguments 的逐字内容（含历史 effort），结果仍为 function_call_output；custom 为 custom_tool_call/input 与 custom_tool_call_output。恢复用原 system、完整历史和独立 WS 状态，不追求跨进程 previous_response_id 续接。保留旧类型比成对转换更小，也避免改变 JSON 参数、丢失 effort 或让缓存前缀与旧请求不一致。工具定义从 function 换到 custom 的首次请求仍可能失去部分缓存，不能保证服务端命中。后续同连接用原始 output 规范化成一致前缀，仍增量续接。

Session、录制与 replay 无需格式迁移。参数进度沿用 ModelTiming 的通用字节采样：custom 统计原始 input，function 统计 JSON arguments；测试以实际线上字节为准。旧错误 Run 的 replay 可能因新增诊断文字而与历史展示输出不同，工具录制和源码仍可离线重放。

## 改动文件

- `src/provider.zig`、`src/config.zig`：默认 custom 与回退配置，配置校验和子会话有效配置继承。
- `src/provider/codex.zig`、`src/provider/codex_ws.zig`：custom schema、历史配对、input 流/计时、WS 前缀规范化与流错误信息。
- `src/session/effort.zig`、`src/session/run.zig`：首行 effort 解析与既有 Run 执行/调度衔接。
- `src/session/prompt.zig`、`src/session/output.zig`、`src/sandbox.zig`：继续修正提示与语法错误源码片段。
- `tests/mock_codex.py`、`tests/mock_llm_tool.py`、`tests/test_codex.py`、`tests/test_codex_websocket.py`：按实际工具定义发 mock 事件，新增 custom、恢复/回退和 replay 验证。
- `docs/config.md`、`docs/codex.md`、`docs/session-log.md`、`docs/adr/0011-provider-wire-protocols.md`、本文：配置、协议、日志和证据说明。

`src/provider/timing.zig`、Session 日志加载和 replay 执行器继续复用原实现，未增加第二套数据格式。

## 验证

`zig build`、`zig build test --summary all`（427/427）和 `zig fmt --check src build.zig` 已通过。Codex SSE mock 验证 custom 请求 schema、流式及 final-only input 的 UTF-8 进度、有序原始历史、脚本语法/运行错误后修复、错误与成功 Run 的离线 replay、旧 function 恢复到 custom 及反向回退。WS mock 覆盖 custom 正常及有序输出增量、完整历史恢复、effort 改变后完整请求、缺失 previous_response_id 重发和既有降级/取消/截止时间行为。配置单测覆盖默认、文件、环境优先及非法类型/值；effort mock 对两种 provider 跑全档位护栏。

AGENTS.md 所列 16 个 Python e2e 加 `test_codex_websocket.py` 共 17 个程序全部通过：session、agent、agent_reuse、agent_fork、background_agent、background_bash、background_run、codex、codex_websocket、llm、stats、effort、interjections、limits、replay、stream_idle、files。完整本地检查输出保存在 `/tmp/nib-speed-v6-checks/`。

配套 bench 变体路径为 `/home/yang/myself/nib-bench/bins/speed-v6`（WebSocket/custom 包装器）和 `.real`（ReleaseFast）。由 `nib-bench/build-nib.py` 在临时 clone 从本提交构建，不切换共享检出；manifest、实际包装器本地 WS mock 和 `--fake` 结果单独记录在 nib-bench 仓库 README/`bins/speed-v6.json`，与 nibcode 分开提交。

真实验证使用当前工作区 Debug 二进制，仅做同一个临时目录文件写入/读回任务，模型固定 `gpt-6.1-terra`、effort medium，没有 fast/service_tier 覆盖，没有真实 bench 或其他模型任务。第一次请求已收到 custom input delta，但完整 Step 提交前流失败；在 retry 事件后立即取消，没有执行 Run。没有采到足够底层错误，无法区分网络/服务端断流与事件解码，第二次未复现；实现补足这两条错误路径的区别信息，不输出原始事件正文。

第二次任务 2 个 Step 成功（各 1 次请求），墙钟 4488 ms。首步 WS 完整 input 1 项/435 字节，custom Run 的原始源码 276 字节；参数进度 2286–3322 ms。写入含反引号、`${literal}`、反斜杠、引号及真实换行的 payload.txt，读回逐字一致，最终回复 verified。第二步 `transport=websocket`、`incremental=true`，input 仅 1 项/135 字节；原始 output 为 custom_tool_call/message，内部 type=custom，stderr 为空。累计 3 次真实请求（1 次失败取消 + 2 次成功），没有再次验证或自动重试。

本地原始记录：失败 `/tmp/nib-speed-v6-real-oxlsm72p/`，成功 `/tmp/nib-speed-v6-real-j86pltqt/`（含 summary.json、events.jsonl、隔离 NIB_HOME 日志和测试文件）。不包含凭证文件；未提交完整真实日志或密文。小样本只证明端点和增量协议可用，不证明失败率或速度改善。
