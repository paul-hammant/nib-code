# speed-v5：摘要、验证顺序与展示预算

基于 speed-v4（13a7a1a），只落地 request-flags 已有证据支持的请求参数变化及正式批次暴露的重复工作问题。不增加 verbosity、context:all_turns、freeform 或其他请求选项；不改变 effort、store:false、加密 reasoning 及历史回传。证据在邻接 nib-bench 仓库的 `experiments/request-flags/README.md` 与 `runs/formal-20261105/`。

## 配置与行为

| 配置 | 环境变量 | 默认值 | 合法值 |
|---|---|---|---|
| `[codex].reasoning_summary` | `NIB_REASONING_SUMMARY` | `"off"` | `"off"`、`"auto"` |
| `[limits].run_output_bytes` | `NIB_RUN_OUTPUT_BYTES` | 16384 | 16384–16777216 字节 |

环境覆盖文件，有效配置经 stdin 继承到子会话。摘要关闭时请求完全省略 summary，effort 缺省时也不强加 effort；显式 auto 可单独开启摘要。SSE 与 WS 使用同一个 requestBody。没有摘要 delta 时 UI 不新增空块，ask JSON 仍可完成和保留加密 reasoning。

展示预算作用于前台 Run、自动后台 Run 结算及后台 bash/agent 消息；工具返回给 JS 的数据保持完整，64 KiB console 捕获上限不变。提高预算不会找回 console 捕获阶段已丢弃的正文。下限维持原有 16 KiB，以容纳现有分条标题和省略标记，不扩展为任意极小预算。新会话 system 随配置渲染 KiB（非整 KiB 时显示 bytes），恢复仍遵守原 system 不重写的约定。calls footer 保存预算，replay 按原预算输出；旧录制默认 16384。

## 提示文本

旧 system 展示提示：

```text
- The last expression and console.log output share 16 KiB per Run, truncated by console call and final result with markers; filter in JS first; tool results inside JS remain complete.
```

新 system（{s} 按配置替换为 16 KiB／32 KiB 等）：

```text
- The last expression and console.log output share {s} per Run, truncated by console call and final result with markers; tool results inside JS remain complete. Locate with grep, then read needed line ranges. Large multi-file output can exceed this display budget: batch reads or print only needed snippets.
- Before full builds/tests, finish implementation, known regression tests, expected results/fixtures and formatting; aim for one full validation. On failure, fix the failures and revalidate. Keep all necessary checks.
```

验证顺序此前只在通用脚本说明里提到 `make all independent edits, then build and test`，未明确测试代码、fixture 和格式化。新增提示要求先完成所有已知修改，尽量一次全量检查；失败后修复并复验，保留必要检查。

read 工具新增：

```text
Locate with grep first, then read needed line ranges; batch large multi-file output or print snippets to stay within the Run display budget.
```

bash 工具新增精简验证顺序提醒；原 `await tools.bash({command: "zig build test --summary all"})` 示例保留，逐字节测试继续校验。没有增加复杂示例，避免超过每工具 600 字符限制。新提示改变新会话 system_sha；恢复会话继续沿用原 system。

## 计时

后台 bash finished 新增 execution，记录 spawn 前到 wait 完成的 Unix 毫秒区间。自动后台 Run 的 completion/background_run 同样带 execution，calls 仍相对原 Run 开始；包含自动转后台之前的工具等待。结果送达与执行结束分开，主日志和 ask JSON 均保留。说明见 [session-log.md](session-log.md)；这些是附加字段，旧日志照常恢复。

bench 使用完整 calls 区间并集，不使用后台注册到送达的整段。旧批次自动后台 Run 从 calls footer + completion.calls 恢复；旧显式后台 bash 缺精确时钟，只能用终态 progress 耗时估计，或标为 unknown。两类情况不能声称具有新日志一样的精度。

## 验证与范围

`zig build`、`zig build test --summary all`（422/422）、`zig fmt --check src build.zig` 已通过。AGENTS.md 列出的 16 个 Python E2E 均通过：session、agent、agent_reuse、agent_fork、background_agent、background_bash、background_run、codex、llm、stats、effort、interjections、limits、replay、stream_idle、files。replay 旧 footer 字段集合 fixture 更新后，20 个测试复跑通过；新增断言覆盖默认无摘要／显式开启、加密历史续接、TUI 无空块、配置覆盖／无效值、32 KiB 展示与完整 JS 数据、原预算 replay、后台实际执行时间及事件落盘。

本次仅本地 mock 与离线数据；不调用真实付费模型。因此 request-flags 的 SSE 结果是采用该默认值的依据，并未测得 speed-v5 的真实 WS 端到端加速幅度。16／32 KiB 两变体仅展示预算不同，需后续正式对照才能选择。
