---
status: accepted
date: 2026-11-01
---

# Support thinking models; default to deepseek-flash

Change the default model from `deepseek-chat` to `deepseek-flash` and default `context_window` to 1M. Assistant messages store provider-tagged reasoning data (`reasoning_content` for Chat Completions), returned unchanged in subsequent requests. Configure thinking and `reasoning_effort` through `NIB_THINKING=on|off` and `NIB_REASONING_EFFORT`; when unset, omit both fields and use server defaults, avoiding unfamiliar parameters for other OpenAI-compatible services. Compaction-summary requests always disable thinking so reasoning does not consume the small summary output budget.

**Why:** DeepSeek's current models are `deepseek-flash` and `deepseek-v4-pro`, with thinking on by default. Official docs require full `reasoning_content` in **all** subsequent requests carrying `tools` (including no-tool-call Turns and across user Turns), or return 400. nib always sends tools; previously reasoning was display-only and absent from history, causing errors with new models.

**Sources and confidence:**
- Primary (official docs, 2026, unversioned): [Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode), [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing). Parameters: `thinking: {type: "enabled"|"disabled"}` and `reasoning_effort: low|high|max`; parameters such as `temperature` have no effect in thinking mode.
- Measured: `deepseek-chat` worked on a tool task on 2026-11-01 without returning reasoning. It is absent from pricing pages; its current model mapping and thinking status remain unknown.
- Inference: returning reasoning grows context faster, but most should hit prefix caches, and compaction ([0007](0007-context-compaction.md)) summarizes it too.

**Verification (2026-11-01, local mock, no real API):** `tests/mock_llm.py` implements the official rule: tool-bearing requests with any assistant message missing `reasoning_content` return 400. Multi-Step Turns, resume, and compaction (`tests/test_session.py`) pass this rule; a manually constructed request missing reasoning confirms rejection; summary requests actually send `thinking: disabled`.

**Real API verification (2026-11-01, `deepseek-flash`, thinking on by default, `NIB_THINKING` unset):** A task delegating to two subagents used 2 parent Steps and multiple Steps in each child; every request carried tools and returned `reasoning_content`, without any 400. This is the first real evidence for the return rule; `deepseek-chat`'s current status remains unverified.

**Known limit:** Session logs written before this change lack assistant `reasoning_content`. Continuing these old Sessions with thinking models is expected to return API 400; start a new Session or use `NIB_THINKING=off`.

**When to reconsider:**
- Measurements show materially increased token cost from returned reasoning: consider disabling thinking by default or lowering effort;
- DeepSeek changes the return requirement.
