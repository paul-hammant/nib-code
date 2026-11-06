---
status: accepted
date: 2026-11-05
---

# Provider 是数据，线路协议最多三种

**决定：** 保留小而美的服务集合。Provider 表保存服务身份与默认值；协议负责请求、响应、推理延续和用量。最多支持 `responses`、`chat_completions`、`anthropic_messages` 三种协议。Codex 是 Responses 加 ChatGPT 登录与专用 WebSocket 传输，不复制 Responses 的序列化与事件解析。Session、Sandbox 和 Run 不按服务增加分支。新增相同协议的服务只增加表项。

## 服务与模型

内置表项包含 id、显示名、protocol、base_url、api_key_env 列表、default_model 和少量带 context_window 的模型。快照日期为 2026-11-06；模型不是发现接口，也不保证账号有权限。

| id | 显示名 | protocol | base_url | 凭证 | 默认模型 |
| --- | --- | --- | --- | --- | --- |
| codex | Codex | responses | https://chatgpt.com/backend-api | CODEX_HOME/auth.json | gpt-6.1-sol |
| openai | OpenAI | responses | https://api.openai.com/v1 | OPENAI_API_KEY | gpt-6.1-sol |
| anthropic | Anthropic | anthropic_messages | https://api.anthropic.com | ANTHROPIC_API_KEY | claude-sonnet-5-5 |
| deepseek | DeepSeek | chat_completions | https://api.deepseek.com | DEEPSEEK_API_KEY | deepseek-flash |
| xai | xAI | responses | https://api.x.ai/v1 | XAI_API_KEY | grok-4.7 |

模型快照来源：用户提供的 models.dev api.json（获取日期 2026-11-06）。Anthropic 默认 claude-sonnet-5-5，列表 claude-opus-5-5、claude-sonnet-5-5、claude-haiku-5-5、claude-fable-5-1，窗口均为 1000000、最大输出 128000；OpenAI API 默认 gpt-6.1-sol，列表 gpt-6.1-sol/terra，窗口均为 1050000、最大输出 128000；xAI 默认 grok-4.7，列表 grok-4.7/4.6，窗口均为 500000。Codex 原有列表和窗口保持不变；DeepSeek 的 deepseek-flash/deepseek-v4-pro 窗口为 1000000。推理兼容规则来自 pi catalog/families/anthropic.ts。

## 配置与身份

顶层 `provider` 选择服务 id；NIB_PROVIDER 优先。NIB_MODEL、NIB_BASE_URL、NIB_CONTEXT_WINDOW 继续覆盖当前服务的字段。内置服务使用同名配置段，`[codex]` 的 transport、run_tool、reasoning_summary 保留。

自定义服务使用 `[providers.mysite]`，仅接受 protocol、base_url、model、context_window、api_key_env。id 使用非空 ASCII 字母、数字、下划线、短横线；禁止与内置或兼容 id 冲突。四个连接/模型字段必须齐全，api_key_env 可省略以支持无认证的本地服务。只保存环境变量名，秘密不得写入配置。只扩展现有 TOML 子集，不增加依赖；未知/重复段落或键、错误类型和缺失字段均报告配置路径及行号。

```toml
provider = "mysite"

[providers.mysite]
protocol = "chat_completions"
base_url = "https://models.example.com/v1"
model = "my-code-model"
context_window = 128000
api_key_env = "MYSITE_API_KEY"
```

旧 `provider = "chat_completions"`、`[chat_completions]`、NIB_API_KEY 优先于 DEEPSEEK_API_KEY 的行为原样保留，作为独立兼容身份映射到 DeepSeek 默认配置。旧日志中的 codex/chat_completions id 保持可恢复；不能把旧日志身份自动改成 deepseek。跨服务 id 恢复拒绝，即使协议相同。自定义服务 id 也写入日志并比较。带加密/签名延续数据的模型恢复保持模型一致性。

有效配置经现有匿名 stdin 管道传给子 agent，传 provider id、协议、非秘密字段和密钥环境变量名；每个进程独立读取环境密钥。凭证不经 argv、配置文件或日志。tools.llm 与摘要复用有效配置。

## Run、推理与用量

Codex 保持 custom raw-JS Run 和 function 回退；OpenAI Responses 同样使用 custom，pi 的 openai-responses-shared 已支持 custom/grammar。xAI、Anthropic、Chat Completions 使用 function Run 的 `{code}`。历史逐调用保留类型，结果按调用类型配对，不因当前工具定义改写历史。

Responses 共用现有 Codex 的 output_item.done 完整工具参数、completed 结算、encrypted_content 与有序输出保存。普通服务走 `/responses` 与 Bearer API key；Codex 继续 `/codex/responses`、专用 headers、登录文件重读一次的 401 处理和 WS→SSE Session 级降级。普通服务绝不读取 Codex 凭证。错误仅含服务 id、状态和安全诊断，不泄露认证内容。

Anthropic 使用 `/v1/messages`、x-api-key、anthropic-version:2023-06-01。system 文本块与末尾可缓存的 user/system 内容放 ephemeral cache_control 断点，工具末项可作固定前缀断点；不在每个内容块滥加断点。tool_use 与 tool_result 按 id 配对，连续工具结果合并为 user 内容块。签名 thinking/redacted_thinking 完整保存在 provider 标记的 reasoning.data；流中累积 thinking_delta/signature_delta，不能用可读文本重建签名。恢复后按原始块顺序回传。

Anthropic Usage.prompt_tokens = input_tokens + cache_read_input_tokens + cache_creation_input_tokens；prompt_cache_hit_tokens = cache_read_input_tokens；新增默认零的 prompt_cache_write_tokens = cache_creation_input_tokens。completion_tokens = output_tokens。所有聚合、日志、子 agent 和统计透传新字段，旧日志缺字段按零读。message_start 输入用量与 message_delta 最终输出用量合并，不覆盖为零。

`/effort` 保留统一入口。Codex 现有 none/low 及默认映射不变；OpenAI Responses 按模型支持发送 reasoning.effort；xAI 无已验证映射时不发送 none/minimal。Chat Completions 保持既有 thinking/reasoning_effort 线路。Anthropic 按 pi 家族表区分 adaptive 与 budget：adaptive 用 thinking.type=adaptive 与 output_config.effort，minimal→low，明确支持的模型才用 xhigh/max；旧模型用 thinking.type=enabled 与 budget_tokens，并保证 max_tokens 留出输出空间。off 对不能关闭的模型用最低支持档位；default 保留服务默认。预算值以 pi reasoning.ts 的默认预算为准，不另创尺度。

重试复用现有 429/5xx、网络和超时分类、取消及截止时间。401 普通 API key 服务直接提示检查对应密钥环境变量；仅 Codex 允许重读登录文件一次。已输出可见增量的普通服务不自动重放，缓冲调用可安全重试。未完成的工具不执行、失败 Step 不提交。

## 验收与非目标

配置、请求体、现实 SSE fixtures 均需单测；本地 mock 覆盖文本、Run 往返、签名/密文延续、缓存读写用量、多轮恢复、401、子 agent 继承及跨 provider 拒绝。原有单测与 AGENTS.md 全部 e2e 必须通过。禁止用真实模型、付费请求或 nib-bench 验收此改动。

不做非 Codex OAuth、模型发现端点、provider marketplace、逐 provider UI、跨协议历史转换。/status 和 CLI 帮助显示服务 id，固定 UI 文案英文。

**来源：** 本机 pi `packages/ai/src/providers/{openai-codex,openai,anthropic,deepseek,xai}.ts`、同名 models wrapper、`catalog/providers`、`catalog/families` 及 `src/api/{openai-responses,openai-responses-shared,anthropic-messages,openai-completions}.ts`。本 ADR 已获批准；交付状态以代码与验证为准。

**实现取舍：** 自定义服务沿用现有枚举日志布局，以 provider=custom 与 custom_provider=<id> 组成完整身份，恢复/fork 同时比较；保留旧日志解析和旧 provider 名称。缓存写入字段默认零、序列化时为零省略，旧用量输出形状不变。自定义 Responses 采用 function Run 以适配未支持 custom 工具的站点；自定义 Chat Completions 不发送 DeepSeek 专用 thinking 字段。共享 Responses 实现在 responses.zig，Codex 的认证与 WS 扩展也留在该模块，不复制协议代码。Anthropic 逐消息 effort 沿用 pi 的 managed-effort 标记和 block_binding。验证只用本地 mock，未调用真实服务。
