---
status: accepted
date: 2026-11-01
---

# 一个 Provider 接口，两种线路协议

**决定：** `src/provider.zig` 定义 Config、Message、Reply、Usage 和 `stream`；内部选择 Chat Completions（原 DeepSeek/OpenAI 兼容线路）或 Codex Responses。`src/config.zig` 统一解析 `$NIB_HOME/config.toml`（默认 `~/.nib/config.toml`）与环境覆盖，CLI 再应用 effort；agent、摘要、子 agent 都使用同一个接口和有效配置。默认 provider 是 Codex，Chat Completions 仍支持 DeepSeek。配置与指令、会话统一放在 NIB_HOME，不读取或自动迁移 XDG 文件，格式见 [配置说明](../config.md)。

Codex 通过 `$CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`）运行时读取 `tokens.access_token/account_id`，发送到 `https://chatgpt.com/backend-api/codex/responses`。请求带 Authorization、chatgpt-account-id、OpenAI-Beta 和 originator，使用 instructions、store:false、流式 input 和 `include:["reasoning.encrypted_content"]`。遇到 401，重新读取文件并只重试一次；再次失败提示运行 codex 登录。不实现 OAuth，也不刷新、轮换或保存共享 refresh_token。认证错误不输出响应正文或凭证解析内容。

Message 的 reasoning 是带 provider 标记的延续数据：Chat Completions 保存原始 reasoning_content，Responses 保存完整已完成 reasoning items 的 JSON（含 encrypted_content）。恢复界面从这些条目提取摘要，不显示密文。assistant phase 也保留。Codex 默认使用 custom `run`（Lark grammar、直接 JS input），配置可回退 function；Chat Completions 保持 function。旧 function 历史原样保留，新旧结果按调用类型配对，不为了当前工具定义转换已有历史。内部 custom 以 `type:"custom"` 加规范化 `{code}` 复用 Session/日志/replay；effort 用可选首行 `// @run: {"effort":"low"}`。详情见 [custom Run 决策](0018-custom-run.md)。工具参数取 output_item.done 的完整值，避免执行尚未结束的参数。completed 才提交 Step；incomplete、failed、截断按错误性质重试或报错，保留服务端 code/message。Codex 可在已流出 delta 后重试，失败 partial 不提交；不重试或重试耗尽时只追加独立诊断，不进入模型历史。重试分类、退避和诊断格式见 [Codex 使用说明](../codex.md#流失败与重试)。两种协议都映射成既有 Usage，包含缓存命中。

Session log 首条记录包含 provider/model，每次提交记下本次模型。跨 provider 恢复明确拒绝，不尝试转换历史；Codex 恢复也拒绝不同模型，避免加密推理条目跨模型；Chat Completions 仍按当前配置选模型。旧日志缺 provider 时视为 Chat Completions，旧 reasoning_content 在重放时迁移，不改写文件。

**配置与摘要：** 默认 Codex 模型是 `gpt-6.1-sol`，窗口 500,000；模型和窗口来自 pi，见 [Codex 使用说明](../codex.md)。NIB_THINKING=on 在未设 effort 时用 medium，off 优先于 NIB_REASONING_EFFORT：支持关闭的模型用 none，pi 标记不能关闭的 sol/astra 用最低档 low；环境未设置推理覆盖时采用文件 effort，再无配置则保留服务端默认。显式 CLI effort 优先于环境与文件且不落盘；TUI `/effort` 原子保存顶层 effort、保留其他行，`default` 删除该键。摘要始终使用当前会话的同一模型，保留请求前缀以命中缓存，也避免把加密推理条目传给另一个模型；能关闭推理就关闭，否则用 low。

Codex 摘要不沿用原来的 32–2048-token 总输出限制：跟随 pi 不发送 max_output_tokens，保留服务端正常输出额度，摘要文字预算单独写进提示，为推理加摘要留空间。pi 模型目录 maxTokens 为 128000，实际额度由服务端决定；这不是可由客户端保证的硬上限。空摘要、截断、压缩无效沿用 [0007](0007-context-compaction.md)：自动压缩通知后继续，手动压缩报错，历史不替换。

子 agent 通过匿名 stdin 管道收到 prompt 和有效 Config，跳过配置文件读取，不通过 argv 或环境传 API key；Codex Config 的 api_key 为空，各进程独立读取登录文件。所有工具子进程的密钥环境清理和凭证路径拒绝见 [0006](0006-deny-dangerous-commands.md)。

**WebSocket 传输：** 0.4.0 起 Codex 默认 WS，显式 SSE 和 Session 级降级保留。独占连接、可丢弃续接状态及保序历史的取舍见 [0017](0017-codex-websocket.md)，协议和限制见 [Codex 传输](../codex.md#responses-websocket-传输)。

**为什么：** 第二种协议的序列化、推理延续、认证和事件格式差异由实现承载，Session 无需了解协议；沿用现有日志提交和工具模型，不增加 OAuth 生命周期、模型发现服务或第二份会话存储。

**证据与边界（2026-11-01）：** 本机 pi 一手源码 `packages/ai/src/api/openai-codex-responses.ts`、`openai-responses-shared.ts`、`catalog/providers/openai-codex.ts`、`catalog/families/openai.ts`；[OpenAI Responses 条目文档](https://developers.openai.com/api/reference/resources/conversations/subresources/items/methods/create) 说明使用 output_item.done 的 encrypted_content 继续无状态会话。本地 Responses mock 验证请求头、文本、工具往返、两条推理数据、多轮恢复、摘要、子 agent、usage、401 和凭证隔离。模型列表是源码快照，不代表所有账号都可用；未知模型需显式设置 `context_window` 或 NIB_CONTEXT_WINDOW。

**验证（2026-11-01）：** `zig build test --summary all` 62/62 通过；`tests/test_session.py`、`tests/test_codex.py` 与 ReleaseFast 构建通过。Responses mock 额外覆盖超过 100KB 的加密条目、assistant phase、同模型摘要 low、空/截断摘要后继续，以及跨模型恢复拒绝。真实请求用 ReleaseFast 从临时空目录发出“你好。”，隔离全局/项目指令，不带仓库内容：gpt-6.1-sol 返回“你好！有什么我可以帮你的吗？”，1 Step，输入 479、输出 13 tokens，无 Run，stderr 为空。真实工具、长会话和压缩未额外调用服务，覆盖来自本地 mock。

**何时重新考虑：** 三协议与数据化服务表的后续设计见 [0020](0020-providers.md)；后端协议或模型窗口变更，或实际需要跨 provider 转换历史、OAuth 登录、服务器端压缩。
