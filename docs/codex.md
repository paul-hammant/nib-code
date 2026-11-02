# 用本机 Codex 登录运行 nib

先通过 `codex` 完成 ChatGPT 登录，再运行：

```sh
cd /home/yang/myself/nibcode
NIB_PROVIDER=codex ./zig-out/bin/nib
NIB_PROVIDER=codex ./zig-out/bin/nib ask '你好'
NIB_PROVIDER=codex ./zig-out/bin/nib ask --json '你好'
NIB_PROVIDER=codex ./zig-out/bin/nib --continue
```

默认读取 `~/.codex/auth.json`，可用 `CODEX_HOME=/path/to/codex` 指定目录。无需 NIB_API_KEY；已有 NIB_BASE_URL、NIB_MODEL、NIB_CONTEXT_WINDOW 覆盖仍会生效，切换服务时清理不适用的旧覆盖。

默认模型 `gpt-6.1-sol`，窗口 500,000 tokens。显式选模型：

```sh
NIB_PROVIDER=codex NIB_MODEL=gpt-6-sol NIB_REASONING_EFFORT=high ./zig-out/bin/nib ask '你好'
```

本机 pi `catalog/providers/openai-codex.ts` 的列表（2026-11-01，一手源码）：

| 模型 | 默认窗口 |
|---|---:|
| gpt-6.1-terra、gpt-6.1-sol | 500,000 |
| gpt-6-astra、gpt-6-sol、gpt-6-luna | 272,000 |
| gpt-5.6-luna、gpt-5.6-sol、gpt-5.6-terra | 272,000 |

未知模型需设置 NIB_CONTEXT_WINDOW，避免猜测窗口。模型是否可用取决于账号。

也可以不用环境变量，直接控制当前进程的 effort：

```sh
NIB_PROVIDER=codex ./zig-out/bin/nib --effort high
NIB_PROVIDER=codex ./zig-out/bin/nib ask --effort high '你好'
```

TUI 用 `/effort` 查询，`/effort high` 切换，状态栏显示请求使用的 effort。

`--effort` 和 `/effort` 接受 `default|off|none|minimal|low|medium|high|xhigh|max`，具体档位是否可用由模型和服务端决定。显式档位会启用 thinking 并覆盖环境配置；`off` 按模型能力关闭或降到最低档；`default` 清除 thinking/effort 覆盖，交由服务端决定。这里只显示客户端请求配置，不代表服务端确认的实际推理量。

TUI 切换只在空闲时处理，从后续 Turn 生效，子 agent 同步继承；不会写入持久配置，恢复会话时仍以本次启动参数和环境变量为准。摘要继续使用独立的最低推理策略。

NIB_THINKING=on 默认用 medium；NIB_REASONING_EFFORT 可显式指定服务端支持的 effort。NIB_THINKING=off 覆盖 effort：能关闭的模型用 none，sol/astra 用允许的最低档 low；未设置则沿用服务端默认。

摘要始终使用当前模型，保留原请求前缀和该模型的加密推理条目，以命中缓存并避免跨模型传递密文。能关闭推理时关闭，否则用 low。Codex 摘要不沿用 Chat Completions 的小额总输出限制：按 pi 的请求格式不发送 max_output_tokens，保留服务端正常输出额度；原 32–2048-token 预算只写进提示约束摘要文字，给推理留出空间（pi 目录 maxTokens 为 128000，实际限额仍由服务端决定）。空摘要、截断、压缩无效等失败，自动压缩发 notice 后继续；手动压缩报告错误。

会话记录 provider 和模型；跨 provider 恢复会拒绝，使用原 provider 或开新会话。Codex 恢复模型也要相同，以免加密推理条目跨模型；Chat Completions 恢复沿用原行为，采用当前模型配置。未设置 NIB_PROVIDER（或设 chat_completions）仍使用原 Chat Completions 线路，默认 DeepSeek。

凭证缺失、格式错误或 401 会给出登录提示。401 只重新读取文件并重试一次，让 Codex CLI 已刷新的凭证生效；仍失败请运行 `codex` 重新登录。nib 不使用 refresh_token。凭证不进入会话日志、argv 或子进程环境。tools.agent 从 stdin 接收有效配置，各自读取 auth.json；bash 不继承常见密钥环境变量。read/edit/write 拒绝凭证文件，bash 拒绝引用凭证目录；这些是防误操作保护，不是系统沙箱，详见 [ADR 0006](adr/0006-deny-dangerous-commands.md)。

本地验证（全为临时虚构凭证）：

```sh
zig build test --summary all
zig build
python3 scripts/test_session.py
python3 scripts/test_codex.py
zig build -Doptimize=ReleaseFast
```
