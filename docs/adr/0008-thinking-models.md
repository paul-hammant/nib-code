---
status: accepted
date: 2026-11-01
---

# 支持 thinking 模型，默认模型改为 deepseek-flash

默认模型从 `deepseek-chat` 改为 `deepseek-flash`，`context_window` 默认改为 1M。assistant 消息保存带 provider 标记的 reasoning 数据（Chat Completions 对应 `reasoning_content`），此后每次请求原样回传。thinking 开关和 `reasoning_effort` 做成配置（`NIB_THINKING=on|off`、`NIB_REASONING_EFFORT`）；不配置时请求里不出现这两个字段，由服务端用默认值，其他 OpenAI 兼容服务也不会收到不认识的参数。压缩的摘要请求固定关闭 thinking，否则推理会占掉很小的摘要输出预算。

**为什么：** DeepSeek 当前的模型是 `deepseek-flash` 和 `deepseek-v4-pro`，thinking 默认开启。官方文档要求：请求带 `tools` 时，`reasoning_content` 必须在之后**所有**请求中完整回传（包括没有调用工具的轮次、跨用户轮次），否则返回 400。nib 每次请求都带 tools，而现在推理内容只用于显示、不进 history，切到新模型后会出错。

**事实来源与把握程度：**
- 一手（官方文档，2026，无版本号）：[Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)、[Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing)。开关写法为 `thinking: {type: "enabled"|"disabled"}` 加 `reasoning_effort: low|high|max`；thinking 模式下 `temperature` 等参数不生效。
- 实测：`deepseek-chat` 在 2026-11-01 带工具调用的任务中可用（未回传推理内容）。它在价格页上已不出现，现在对应哪个模型、是否开 thinking，未查到。
- 推测：回传推理内容会让上下文增长更快，但大部分会命中前缀缓存，压缩（[0007](0007-context-compaction.md)）也会一并总结掉。

**验证（2026-11-01，本地 mock，未连真实 API）：** `tests/mock_llm.py` 按官方规则实现：带 tools 的请求里只要有 assistant 消息缺 `reasoning_content` 就返回 400。nib 的多步 Turn、恢复、压缩（`tests/test_session.py`）都在这条规则下通过；手工构造缺失推理的请求确认 mock 会拒绝；摘要请求实际发出 `thinking: disabled`。

**真实 API 验证（2026-11-01，`deepseek-flash`，thinking 默认开启，未设 `NIB_THINKING`）：** 一个派两个子 agent 的任务，父会话 2 个 Step、两个子会话各多个 Step，每个请求都带 tools 并回传 `reasoning_content`，全程没有 400。这是回传规则的第一份真实证据；`deepseek-chat` 的现状仍未查证。

**已知局限：** 这次改动之前写下的 Session log 里，assistant 消息没有 `reasoning_content`。用 thinking 模型 `--continue` 这类旧会话，预计会被 API 以 400 拒绝，需要开新会话（或 `NIB_THINKING=off`）。

**何时重新考虑：**
- 实测发现回传推理内容使 token 成本明显上升：考虑默认关闭 thinking，或调低 effort；
- DeepSeek 改变回传要求。
