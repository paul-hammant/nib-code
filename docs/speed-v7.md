# speed-v7：同一验证取代过时执行

基于 feat/speed-v1 的 5031125（speed-v6）。这是 Session 的通用 bash 机制，不识别 nib-bench、项目、语言、测试框架或特定命令；没有新增配置与依赖。

## 取代条件与结果

新 bash 执行登记时，在同 Session 的活动命令中查找：旧 Run 序号严格更早、command 字节完全相同、启动 cwd 完全相同、旧命令启动后修改代数推进、新旧都不是 detached。匹配的全部旧命令只取代一次。同 Run 内的并行命令、无修改的重复、不同命令/cwd 均保留；不做结果缓存。修改代数来自本 Session 成功的 edit/write，与供界面展示的 changes 是否启用无关。可比较时，内容相同不计，创建空文件也计；write 读取旧内容的上限仍为 16 MiB，旧内容过大或不可读时成功写入保守计作修改。bash、用户和其他 Session/子 agent 的修改不进入该代数。

停止复用 process.run 的取消标志与进程组清理，不引入另一套 kill 逻辑。新执行继续启动，旧执行通常在 20 ms 轮询内观察取消并清理。旧 bash resolve 为 `{superseded_by:"bN"}`，不 reject、不伪造 exit_code。显式后台 bash 作为 background_ok:true 消息投递；自动后台 Run 中原 await 得到同样的数据，后续 JS 正常继续。Run 的结果和 ok 仍由脚本决定，只等待它继续发起的真实工作，不再等待被取代命令自然结束。检查退出码的代码应先排除 superseded_by；旧脚本若无条件断言 exit_code，仍可能自己抛错。

所有 bash 启动即预留稳定 bN id（短命令仍不显示进度）；id、背景任务、工具计时和取代日志相互对应，恢复也能续号。登记表使用执行栈上的节点，进程清理后移除；取消与 Turn/Session 收尾仍由原 worker join 路径负责。正常后台并发限额仍在启动准入时检查，不因取代绕过限额。

## 提示文本

system 的旧限制片段：

```text
Do only independent work meanwhile;
Avoid changing files the task may use; reread after completion.
```

新片段：

```text
Continue useful work meanwhile;
After edit/write changes, rerun the same command/cwd directly: older Run bash stops with {superseded_by}, not failure. Do not wait for the stale result.
```

自动转后台通知同样把 `Do only independent work meanwhile;` 改为 `Continue useful work meanwhile;`，将末尾 `Avoid changing files this Run may use.` 替换为上述新片段的取代说明。原有“无独立工作时简短回复，Session 本地等待”及不轮询提示保留。

bash 工具说明（旧）：

```js
  // cwd; merged stderr; group killed on return (nohup/& too); killed:exit_code:null.
  // >16 MiB:redirect. >256 words except heredocs:script.
  // background:{id}, auto-message. detached needs background, spans Turns/shell lifetime; stop/timeout/cancel/failure/exit cleans up.
  // Auto-bg keeps await/output. No polling/pending logs. Idle:reply; Session waits.
  // Full checks:code, known regression tests, fixtures/expectations, fmt first; fix failures, revalidate.
  // Example: await tools.bash({command: "zig build test --summary all"})
  async bash({ command, timeout_ms, background = false, detached = false }) {}, // → { exit_code, output } or { id }; timeout_ms: detached 0, else 1800000 (30 min)
```

bash 工具说明（新）：

```js
  // cwd; merged stderr; group cleanup (nohup/& too).
  // >16 MiB:redirect. >256 words except heredocs:script.
  // background:{id}, auto-message. detached requires background, spans Turns; stop/timeout/cancel/exit cleans up.
  // Auto-bg keeps await/output. No polling/logs. Idle:reply to wait.
  // After edit/write, rerun same command/cwd: older Run stops, returns {superseded_by}, not failure; no detached.
  // Full checks:finish code/tests/fixtures/fmt; fix and rerun.
  // Example: await tools.bash({command: "sh checks.sh"})
  async bash({ command, timeout_ms, background = false, detached = false }) {}, // → { exit_code, output }, { superseded_by } or { id }; timeout_ms: 1800000 (30 min), detached:0
```

工具表示例改为通用 `sh checks.sh`，逐字节解析测试同步；说明仍满足仓库的 600 字符限制。

## 日志、统计与改动文件

主日志新增独立 `bash.started/finished/superseded` 事件。取代事件含旧 id、新 id、旧 Run 及已运行 elapsed_ms；事件不应用到消息历史，不计 Step/Turn/失败。恢复、离线 replay 与测试辅助读取器均跳过其历史应用。stats.py 的 `bash_superseded` 按入选事件计数，文本显示“Bash 被取代次数”。日志字段和时钟边界见 session-log.md。

- 执行与状态：src/tools/bash/registry.zig（新增）、src/tools/bash.zig、src/tools/background.zig、src/tools/progress.zig、src/tools/files.zig、src/tools.zig。
- 提示、日志与重放：src/session/prompt.zig、src/session/run.zig、src/session/log.zig、src/replay.zig、scripts/stats.py。
- mock/统计与旧预期：tests/test_background_run.py、test_background_bash.py、test_session.py、test_codex.py、test_stats.py、test_replay.py；相关 Zig 文件中的单测。
- 文档：docs/ask-json.md、session-log.md、tool-delegation.md、本文。
- nib-bench 独立改动：metrics.py、report.py、tests/test_bench.py、README.md、bins/speed-v7 与 bins/speed-v7.json。

bench 每个 result.json 新增 verification.shell/validation 的 started、superseded、max_running、right_censored；报告显示每 run 的中位数和样本数。验证分类仅为离线命令词启发式，不影响宿主取代。nib 新事件能覆盖未提交 Step，旧录制只能统计已结算调用下界，缺失并发/取代为 null。Codex 从 exec_command、runtime 和 write_stdin 的原始 payload 关联 session_id，轮询不重复计启动；缺终点截到 agent 退出，最大并发可能高估，无法证明取代则保持 null。

## 验证与构建

- zig build、zig build test --summary all（429/429）、zig fmt --check src build.zig。
- AGENTS.md 列出的 16 个 Python mock 端到端脚本；新增用例覆盖显式后台 bash、自动后台 Run 的取代和 await 继续、无修改/no-op、不同命令、detached、取代后取消、退出清理、日志/统计/恢复/replay。不同 cwd 和同 Run 边界由单测覆盖。
- nib-bench 的 unittest discover：24 项；fake 批次 smoke-speed-v7-fake：8/8，包括 speed-v7 标签与 Codex，result.json 和报告均包含新指标。
- ReleaseFast 产物：/home/yang/myself/nib-bench/bins/speed-v7，临时本地 clone 编译；包装器强制 WebSocket + custom Run，默认 16 KiB 展示、reasoning summary 关闭，与 speed-v6 相同。精确来源提交、编译器与 SHA-256 见相邻 speed-v7.json。共享源码检出不切换。

上述构建、格式检查、单测和 16 个端到端脚本均通过。首次全套发现的短命令编号、未提交 Step 日志预期已同步；background_bash（95 项）和 replay（20 项）整文件复验通过。

## 已知边界

不跟踪 bash 的文件副作用或外部编辑；修改判断是 Session 级别，不分析命令依赖，任意 edit/write 都可使命令过时。停止不回滚已产生的副作用，原 Run 的后续代码仍能写文件。取代 marker 不能被当作验证通过；需要退出码的脚本应分支处理。新主日志含完整命令，分享时检查敏感参数。没有运行真实付费模型或正式性能 bench，mock/fake 通过不证明速度收益。
