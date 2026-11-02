---
status: proposed
date: 2026-11-01
---

# 支持 thinking 模型，默认模型改为 deepseek-flash

默认模型从 `deepseek-chat` 改为 `deepseek-flash`，`context_window` 默认改为 1M。assistant 消息保存 `reasoning_content`，此后每次请求原样回传。thinking 开关和 `reasoning_effort` 做成配置。

**为什么：** DeepSeek 当前的模型是 `deepseek-flash` 和 `deepseek-v4-pro`，thinking 默认开启。官方文档要求：请求带 `tools` 时，`reasoning_content` 必须在之后**所有**请求中完整回传（包括没有调用工具的轮次、跨用户轮次），否则返回 400。nib 每次请求都带 tools，而现在推理内容只用于显示、不进 history，切到新模型后会出错。

**事实来源与把握程度：**
- 一手（官方文档，2026，无版本号）：[Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)、[Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing)。开关写法为 `thinking: {type: "enabled"|"disabled"}` 加 `reasoning_effort: low|high|max`；thinking 模式下 `temperature` 等参数不生效。
- 实测：`deepseek-chat` 在 2026-11-01 带工具调用的任务中可用（未回传推理内容）。它在价格页上已不出现，现在对应哪个模型、是否开 thinking，未查到。
- 推测：回传推理内容会让上下文增长更快，但大部分会命中前缀缓存，压缩（[0007](0007-context-compaction.md)）也会一并总结掉。

**何时重新考虑：**
- 实测发现回传推理内容使 token 成本明显上升：考虑默认关闭 thinking，或调低 effort；
- DeepSeek 改变回传要求。
