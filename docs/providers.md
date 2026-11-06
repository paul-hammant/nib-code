# Providers

服务身份与线路协议分开：`codex`、`openai`、`anthropic`、`deepseek`、`xai` 是服务；`responses`、`chat_completions`、`anthropic_messages` 是仅有的三种线路。内置服务定义在 `src/provider.zig` 的 `definitions`；服务 id 枚举也由表生成。新增相同线路的普通 API key 服务只增加表项，不扩展 Session 或 UI。

## 内置服务

| id | 协议 | 默认 base_url | 凭证 | 默认模型 / 窗口 |
| --- | --- | --- | --- | --- |
| `codex` | responses，Codex 登录与 WS 扩展 | `https://chatgpt.com/backend-api` | `CODEX_HOME/auth.json` | `gpt-6.1-sol` / 500000 |
| `openai` | responses，SSE | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `gpt-6.1-sol` / 1050000 |
| `anthropic` | anthropic_messages，SSE | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5` / 1000000 |
| `deepseek` | chat_completions，SSE | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` | `deepseek-flash` / 1000000 |
| `xai` | responses，SSE | `https://api.x.ai/v1` | `XAI_API_KEY` | `grok-4.7` / 500000 |

模型快照：用户提供的 models.dev `api.json`，获取日期 **2026-11-06**。OpenAI 列表为 gpt-6.1-sol、gpt-6.1-terra，均 1050000 窗口、128000 最大输出。Anthropic 列表为 claude-opus-5-5、claude-sonnet-5-5、claude-haiku-5-5、claude-fable-5-1，均 1000000 窗口、128000 最大输出。xAI 列表为 grok-4.7、grok-4.6，均 500000 窗口。DeepSeek 保留 deepseek-flash、deepseek-v4-pro，均 1000000 窗口。Codex 使用原有列表、窗口与默认值，见 [codex.md](codex.md)。这是一份短目录，不保证账号权限，不调用模型发现端点。

例如在 `$NIB_HOME/config.toml` 中切换：

```toml
provider = "anthropic"
effort = "high"

[anthropic]
model = "claude-sonnet-5-5"
```

在环境中设置 `ANTHROPIC_API_KEY`。也可以仅通过环境选择：`NIB_PROVIDER=openai`，配 `OPENAI_API_KEY`。环境覆盖不写回文件。模型未知时提供 context_window 或 NIB_CONTEXT_WINDOW；旧 chat_completions 的未知模型仍沿用 1000000 默认值。

## OpenAI 兼容站点与自托管

```toml
provider = "mysite"

[providers.mysite]
protocol = "chat_completions"
base_url = "https://models.example.com/v1"
model = "my-code-model"
context_window = 128000
api_key_env = "MYSITE_API_KEY"
```

将密钥放进环境 `MYSITE_API_KEY`，配置只保存变量名。`protocol`、`base_url`、`model`、`context_window` 四项必填；无认证本地服务省略 api_key_env。api_key_env 是环境变量名，不是密钥。id 使用 ASCII 字母、数字、下划线、短横线，与内置 id 或 `custom` 冲突会报错。

Chat Completions 向 base_url 追加 `/chat/completions`；Responses 追加 `/responses`；Anthropic Messages 追加 `/v1/messages`，因此 Messages 的 base_url 使用服务根地址。三者均允许尾部 `/`。自定义 Responses 使用 function Run，兼容未提供 custom 工具的站点。

只扩展现有 TOML 子集为 `[providers.<id>]`，不支持一般嵌套表或数组；重复段落、重复/未知键、类型错误、缺少必填字段均报告路径和行号。内置服务仍用 `[openai]` 等同名段落，仅覆盖 model/base_url/context_window；Codex 额外选项见原文档。

## Effort 与推理延续

`/effort`、`--effort`、顶层 effort 与原有环境优先级继续适用。

- Codex：保留已有模型映射、custom Run/function 回退、登录凭证及 WS→SSE 降级。
- OpenAI Responses：发送 reasoning.effort；off 对已知不能关闭推理的模型使用 low，其余用 none。默认不覆盖服务端 effort。
- xAI Responses：发送已选择的 effort；没有已验证的 off/none/minimal 映射时省略该字段，显示 server default。
- DeepSeek 与旧 chat_completions：保留 thinking.type 与 reasoning_effort。自定义 Chat Completions 只发送 reasoning_effort，off 映射 none，不发送 DeepSeek 专用 thinking 对象。
- Anthropic：模型家族规则来自 pi `catalog/families/anthropic.ts`。新列表均为 adaptive，并支持逐消息 output_config effort；顶层 effort 固定 low，历史与当前 effort 通过消息标记发送，thinking 使用 block_binding 的 drop_block。minimal 映射 low；支持的模型保留 xhigh/max。Haiku 5.5 可以关闭；Opus/Sonnet 5.5 和 Fable 5.1 的 off 使用 low。旧预算模型使用 pi 的 low=2048、medium=8192、high=16384 预算，保留至少 1024 输出 tokens，总输出不超过 128000。

Codex/OpenAI 使用 custom raw-JS Run；xAI、Anthropic、Chat Completions 与自定义服务使用 `{code}` function Run。历史调用类型和结果配对原样保留。Responses 保存完整有序输出及 encrypted_content；Anthropic 保存完整内容块，包括 thinking 签名和 redacted_thinking，工具结果按 tool_use id 配对。只有完整响应返回工具调用，截断或未结束的输入不执行。

Anthropic 在 system、最后 user/tool_result 和最后工具定义使用 ephemeral cache_control 断点。输入 tokens 为 input_tokens + cache_read_input_tokens + cache_creation_input_tokens；cache hit 对应 read，cache write 单独记录。message_start 与 message_delta 用量合并，避免最终输出用量覆盖输入缓存计数。

## 凭证、恢复与错误

子 agent 经匿名 stdin 继承有效配置，跳过配置文件；传变量名，各进程独立从环境读取选定密钥。只有选定密钥可进入 nib 子进程；bash 清除内置和当前自定义密钥。密钥不进入 argv、会话日志或配置文件。Codex 仍独立读登录文件；非 Codex 服务不支持订阅 OAuth。

旧 `provider = "chat_completions"`、`[chat_completions]` 及 `NIB_API_KEY` 优先于 `DEEPSEEK_API_KEY` 保持兼容；`deepseek` 使用自己的服务身份与 DEEPSEEK_API_KEY。旧会话 id 不自动转换。跨服务恢复拒绝，即使协议相同。自定义日志使用 `provider:"custom"` 与 `custom_provider:"mysite"` 共同表达身份，恢复与 fork 比较二者。Responses/Messages 恢复还要求模型相同，以保护密文与签名延续。

401 提示检查当前服务的密钥环境变量，不输出认证响应正文；仅 Codex 重读登录文件一次。429/5xx、网络、取消和三个超时复用现有策略。普通服务已输出可见增量后不自动重放；缓冲的 llm/摘要可以重试。规则见 [codex.md](codex.md#流失败与重试)。

`nib --help` 和 `/status` 显示有效服务 id，`/status` 也显示缓存写入 tokens。没有逐服务 UI、模型市场、自动发现或非 Codex OAuth。
