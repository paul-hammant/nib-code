# 用本机 Codex 登录运行 nib

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

`tools.agent({ prompt, fork: true })` 创建独立子会话，但 Codex 请求的 `prompt_cache_key` 使用父会话的值，不改用新子会话 ID。fork 继承父会话压缩后的当前完整 history（含发起 fork 的当前 assistant 及 reasoning，之后补合成 tool results 和 user prompt），system/工具 schema 与父会话逐字节相同。共用 key 的目的，是让相同前缀的请求路由到同一缓存；**这是待实测假设，不是服务端命中保证**。目前没有真实 fork 对照实验确认缓存命中率、延迟或费用收益，不能把上面的相邻 Step effort 样本当成 fork 的证据。

model/effort 默认继承父配置，也可显式覆盖；两者不同时不再具有父前缀的缓存复用优势，共用 key 不改变这一点。Codex fork 适用与 resume 相同的模型一致性检查，覆盖 model 不能将父历史中的加密推理条目跨模型使用。后续可在同 model/effort、相同父前缀下对照父 key 与独立 key，记录首请求的 `prompt_cache_hit_tokens / prompt_tokens`、未缓存输入及耗时；结果不支持路由收益时重新考虑共用 key。完整语义及置信度见 [委派工具](tool-delegation.md) 与 [ADR 0015](adr/0015-agent-fork.md)。

## 摘要与会话恢复

摘要始终使用当前模型，保留原请求前缀和该模型的加密推理条目，以命中缓存并避免跨模型传递密文。能关闭推理时关闭，否则用 low。Codex 摘要不沿用 Chat Completions 的小额总输出限制：按 pi 的请求格式不发送 max_output_tokens，保留服务端正常输出额度；原 32–2048-token 预算只写进提示约束摘要文字，给推理留出空间（pi 目录 maxTokens 为 128000，实际限额仍由服务端决定）。空摘要、截断、压缩无效等失败，自动压缩发 notice 后继续；手动压缩报告错误。

会话记录 provider 和模型；跨 provider 恢复会拒绝，使用原 provider 或开新会话。Codex 恢复模型也要相同，以免加密推理条目跨模型；Chat Completions 恢复沿用原行为，采用当前模型配置。环境和配置文件均未指定 provider 时默认使用 Codex（2026-11-02 起，此前默认 DeepSeek）；设 `NIB_PROVIDER=chat_completions` 使用 Chat Completions 线路，默认 DeepSeek。

凭证缺失、格式错误或 401 会给出登录提示。401 只重新读取文件并重试一次，让 Codex CLI 已刷新的凭证生效；仍失败请运行 `codex` 重新登录。nib 不使用 refresh_token。凭证不进入会话日志、argv 或子进程环境。tools.agent 从 stdin 接收有效配置，跳过配置文件读取，各自读取 auth.json；bash 不继承常见密钥环境变量。read/edit/write 拒绝凭证文件，bash 拒绝引用凭证目录；这些是防误操作保护，不是系统沙箱，详见 [ADR 0006](adr/0006-deny-dangerous-commands.md)。

## 推理摘要与流活动

发送 `reasoning` 配置时同时请求 `summary: auto`，服务端提供的推理摘要沿用 reasoning delta 展示；未显式配置推理时不额外发送 reasoning。加密推理条目的日志存储与上下文回传保持不变。

TUI 在模型请求期间记录最后收到 SSE 行的时间，包括文本、推理摘要、工具参数、output_item 事件和心跳。连续 30 秒没有数据时，活动行追加 `· no data Ns`，收到新数据后清除。Turn 对连续数据的 TUI 活动通知按 1 秒节流，请求开始和结束仍立即通知；静默后收到数据会立即清除提示。这个计时独立于 thinking/writing 的阶段时长；Run 执行和重试等待不计入，每次请求重新计时，压缩请求同样显示。静默提示不表示连接已经断开，也不触发读超时或重试；仍可按 Esc 取消。活动通知仅用于 TUI，不新增 ask NDJSON 事件或日志内容。

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
