---
status: accepted
date: 2026-11-01
---

# 一个 Provider 接口，两种线路协议

**决定：** `src/provider.zig` 定义 Config、Message、Reply、Usage 和 `stream`；内部选择 Chat Completions（原 DeepSeek/OpenAI 兼容线路）或 Codex Responses。只有 Config.fromEnv 读取 `NIB_PROVIDER`；agent、摘要、子 agent 都使用同一个接口和有效配置。现有默认 DeepSeek 行为保留。

Codex 通过 `$CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`）运行时读取 `tokens.access_token/account_id`，发送到 `https://chatgpt.com/backend-api/codex/responses`。请求带 Authorization、chatgpt-account-id、OpenAI-Beta 和 originator，使用 instructions、store:false、流式 input 和 `include:["reasoning.encrypted_content"]`。遇到 401，重新读取文件并只重试一次；再次失败提示运行 codex 登录。不实现 OAuth，也不刷新、轮换或保存共享 refresh_token。认证错误不输出响应正文或凭证解析内容。

Message 的 reasoning 是带 provider 标记的延续数据：Chat Completions 保存原始 reasoning_content，Responses 保存完整已完成 reasoning items 的 JSON（含 encrypted_content）。恢复界面从这些条目提取摘要，不显示密文。assistant phase 也保留。工具参数取 output_item.done 的完整值，避免执行尚未结束的参数。completed 才提交 Step；incomplete、failed、截断报错。两种协议都映射成既有 Usage，包含缓存命中。

Session log 首条记录包含 provider/model，每次提交记下本次模型。跨 provider 恢复明确拒绝，不尝试转换历史；Codex 恢复也拒绝不同模型，避免加密推理条目跨模型；Chat Completions 仍按当前配置选模型。旧日志缺 provider 时视为 Chat Completions，旧 reasoning_content 在重放时迁移，不改写文件。

**配置与摘要：** 默认 Codex 模型是 `gpt-6.1-sol`，窗口 500,000；模型和窗口来自 pi，见 [Codex 使用说明](../codex.md)。NIB_THINKING=on 在未设 effort 时用 medium，off 优先于 NIB_REASONING_EFFORT：支持关闭的模型用 none，pi 标记不能关闭的 sol/astra 用最低档 low；都未设置则保留服务端默认。摘要始终使用当前会话的同一模型，保留请求前缀以命中缓存，也避免把加密推理条目传给另一个模型；能关闭推理就关闭，否则用 low。

Codex 摘要不沿用原来的 32–2048-token 总输出限制：跟随 pi 不发送 max_output_tokens，保留服务端正常输出额度，摘要文字预算单独写进提示，为推理加摘要留空间。pi 模型目录 maxTokens 为 128000，实际额度由服务端决定；这不是可由客户端保证的硬上限。空摘要、截断、压缩无效沿用 [0007](0007-context-compaction.md)：自动压缩通知后继续，手动压缩报错，历史不替换。

子 agent 通过匿名 stdin 管道收到 prompt 和有效 Config，不通过 argv 或环境传 API key；Codex Config 的 api_key 为空，各进程独立读取登录文件。所有工具子进程的密钥环境清理和凭证路径拒绝见 [0006](0006-deny-dangerous-commands.md)。

**为什么：** 第二种协议的序列化、推理延续、认证和事件格式差异由实现承载，Session 无需了解协议；沿用现有日志提交和工具模型，不增加 OAuth 生命周期、模型发现服务或第二份会话存储。

**证据与边界（2026-11-01）：** 本机 pi 一手源码 `packages/ai/src/api/openai-codex-responses.ts`、`openai-responses-shared.ts`、`catalog/providers/openai-codex.ts`、`catalog/families/openai.ts`；[OpenAI Responses 条目文档](https://developers.openai.com/api/reference/resources/conversations/subresources/items/methods/create) 说明使用 output_item.done 的 encrypted_content 继续无状态会话。本地 Responses mock 验证请求头、文本、工具往返、两条推理数据、多轮恢复、摘要、子 agent、usage、401 和凭证隔离。模型列表是源码快照，不代表所有账号都可用；未知模型需显式设置 NIB_CONTEXT_WINDOW。

**验证（2026-11-01）：** `zig build test --summary all` 62/62 通过；`scripts/test_session.py`、`scripts/test_codex.py` 与 ReleaseFast 构建通过。Responses mock 额外覆盖超过 100KB 的加密条目、assistant phase、同模型摘要 low、空/截断摘要后继续，以及跨模型恢复拒绝。真实请求用 ReleaseFast 从临时空目录发出“你好。”，隔离全局/项目指令，不带仓库内容：gpt-6.1-sol 返回“你好！有什么我可以帮你的吗？”，1 Step，输入 479、输出 13 tokens，无 Run，stderr 为空。真实工具、长会话和压缩未额外调用服务，覆盖来自本地 mock。

**何时重新考虑：** 后端协议或模型窗口变更，出现第三种协议，或实际需要跨 provider 转换历史、OAuth 登录、服务器端压缩。
