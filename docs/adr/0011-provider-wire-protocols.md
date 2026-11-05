---
status: accepted
date: 2026-11-01
---

# 一个 Provider 接口，两种线路协议

**决定：** `src/provider.zig` 定义 Config、Message、Reply、Usage 和 `stream`；内部选择 Chat Completions（原 DeepSeek/OpenAI 兼容线路）或 Codex Responses。`src/config.zig` 统一解析 `$NIB_HOME/config.toml`（默认 `~/.nib/config.toml`）与环境覆盖，CLI 再应用 effort；agent、摘要、子 agent 都使用同一个接口和有效配置。默认 provider 是 Codex，Chat Completions 仍支持 DeepSeek。配置与指令、会话统一放在 NIB_HOME，不读取或自动迁移 XDG 文件，格式见 [配置说明](../config.md)。

Codex 通过 `$CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`）运行时读取 `tokens.access_token/account_id`，发送到 `https://chatgpt.com/backend-api/codex/responses`。请求带 Authorization、chatgpt-account-id、OpenAI-Beta 和 originator，使用 instructions、store:false、流式 input 和 `include:["reasoning.encrypted_content"]`。遇到 401，重新读取文件并只重试一次；再次失败提示运行 codex 登录。不实现 OAuth，也不刷新、轮换或保存共享 refresh_token。认证错误不输出响应正文或凭证解析内容。

Message 的 reasoning 是带 provider 标记的延续数据：Chat Completions 保存原始 reasoning_content，Responses 保存完整已完成 reasoning items 的 JSON（含 encrypted_content）。恢复界面从这些条目提取摘要，不显示密文。assistant phase 也保留。工具参数取 output_item.done 的完整值，避免执行尚未结束的参数。completed 才提交 Step；incomplete、failed、截断按错误性质重试或报错，保留服务端 code/message。Codex 可在已流出 delta 后重试，失败 partial 不提交；不重试或重试耗尽时只追加独立诊断，不进入模型历史。重试分类、退避和诊断格式见 [Codex 使用说明](../codex.md#流失败与重试)。两种协议都映射成既有 Usage，包含缓存命中。

Session log 首条记录包含 provider/model，每次提交记下本次模型。跨 provider 恢复明确拒绝，不尝试转换历史；Codex 恢复也拒绝不同模型，避免加密推理条目跨模型；Chat Completions 仍按当前配置选模型。旧日志缺 provider 时视为 Chat Completions，旧 reasoning_content 在重放时迁移，不改写文件。

**配置与摘要：** 默认 Codex 模型是 `gpt-6.1-sol`，窗口 500,000；模型和窗口来自 pi，见 [Codex 使用说明](../codex.md)。NIB_THINKING=on 在未设 effort 时用 medium，off 优先于 NIB_REASONING_EFFORT：支持关闭的模型用 none，pi 标记不能关闭的 sol/astra 用最低档 low；环境未设置推理覆盖时采用文件 effort，再无配置则保留服务端默认。显式 CLI effort 优先于环境与文件且不落盘；TUI `/effort` 原子保存顶层 effort、保留其他行，`default` 删除该键。摘要始终使用当前会话的同一模型，保留请求前缀以命中缓存，也避免把加密推理条目传给另一个模型；能关闭推理就关闭，否则用 low。

Codex 摘要不沿用原来的 32–2048-token 总输出限制：跟随 pi 不发送 max_output_tokens，保留服务端正常输出额度，摘要文字预算单独写进提示，为推理加摘要留空间。pi 模型目录 maxTokens 为 128000，实际额度由服务端决定；这不是可由客户端保证的硬上限。空摘要、截断、压缩无效沿用 [0007](0007-context-compaction.md)：自动压缩通知后继续，手动压缩报错，历史不替换。

子 agent 通过匿名 stdin 管道收到 prompt 和有效 Config，跳过配置文件读取，不通过 argv 或环境传 API key；Codex Config 的 api_key 为空，各进程独立读取登录文件。所有工具子进程的密钥环境清理和凭证路径拒绝见 [0006](0006-deny-dangerous-commands.md)。

**可选 WebSocket 传输（2026-11-04）：** Responses 保留同一线路协议，Codex 可通过 `[codex].transport` / `NIB_CODEX_TRANSPORT` 显式选择 WS，默认 SSE。Zig 0.17 标准库只有 HTTP 连接与升级所需接口，没有 WS 客户端；最小 RFC 6455 帧层复用 `std.http.Client` 的 TCP、代理、TLS/证书校验和池内连接所有权。Session 持有独占连接和可丢弃续接状态，日志始终保存完整历史。只有同连接、上次完成、非 input 参数相同、完整 input 包含上次 input + 输出前缀时，才发送 previous_response_id 与增量 input。压缩/取消/断线清除续接，恢复/fork 建独立状态；握手或协议错误在本 Session 记住 SSE 降级。协议证据、测试和边界见 [Codex 传输原型](../codex.md#responses-websocket-原型)。不引入预热线程。

**为什么：** 第二种协议的序列化、推理延续、认证和事件格式差异由实现承载，Session 无需了解协议；沿用现有日志提交和工具模型，不增加 OAuth 生命周期、模型发现服务或第二份会话存储。

**证据与边界（2026-11-01）：** 本机 pi 一手源码 `packages/ai/src/api/openai-codex-responses.ts`、`openai-responses-shared.ts`、`catalog/providers/openai-codex.ts`、`catalog/families/openai.ts`；[OpenAI Responses 条目文档](https://developers.openai.com/api/reference/resources/conversations/subresources/items/methods/create) 说明使用 output_item.done 的 encrypted_content 继续无状态会话。本地 Responses mock 验证请求头、文本、工具往返、两条推理数据、多轮恢复、摘要、子 agent、usage、401 和凭证隔离。模型列表是源码快照，不代表所有账号都可用；未知模型需显式设置 `context_window` 或 NIB_CONTEXT_WINDOW。

**验证（2026-11-01）：** `zig build test --summary all` 62/62 通过；`tests/test_session.py`、`tests/test_codex.py` 与 ReleaseFast 构建通过。Responses mock 额外覆盖超过 100KB 的加密条目、assistant phase、同模型摘要 low、空/截断摘要后继续，以及跨模型恢复拒绝。真实请求用 ReleaseFast 从临时空目录发出“你好。”，隔离全局/项目指令，不带仓库内容：gpt-6.1-sol 返回“你好！有什么我可以帮你的吗？”，1 Step，输入 479、输出 13 tokens，无 Run，stderr 为空。真实工具、长会话和压缩未额外调用服务，覆盖来自本地 mock。

**何时重新考虑：** 后端协议或模型窗口变更，出现第三种协议，或实际需要跨 provider 转换历史、OAuth 登录、服务器端压缩。
