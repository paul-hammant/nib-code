---
status: accepted
date: 2026-11-03
---

# tools.llm: a lightweight single-step map unit

Within a Run, `await tools.llm({ prompt, input, schema, model, effort })` returns `{ text, data, usage }`. The host calls the provider in the current process for one request/answer, without tools, Session history, or project instructions. input is separate from prompt; model defaults to the provider's small model at its own default effort (Session model/effort when the provider has none); an explicit model inherits the Session effort. This fits batch judgments, classification, and extraction such as `Promise.all(items.map(input => tools.llm({prompt: "Classify", input})))`.

**Why a separate name:** agent means doing work: an independent subprocess, multiple Steps, tools, and code investigation/modification. llm means computing a value: no subprocess startup, full agent prompt, or tool loop, filling the gap where agent is too heavy for small map tasks. Separate names expose capabilities and side-effect boundaries directly to callers/models rather than switching semantics through a mode parameter. Pure-function describes the execution boundary, not deterministic models or zero quota consumption.

**Requests and results:** Fixed short system, without AGENTS.md. Codex uses native `text.format` (`json_schema`, strict); Chat Completions uses `response_format.json_object` with schema prompt constraints. Submit schema unchanged, subject to server subsets (e.g. Codex strict objects require additionalProperties:false and complete required). The host checks JSON parsing, not full schema validation; on failure retry once with the parse error, then reject with at most 512 bytes of raw output. Without schema, data is null. Transient errors share provider retry/backoff with the main Session; cache key is `<session_id>:llm`. Usage follows the same Turn accumulation path as agent, including JSON repair requests; cancellation reuses interruptible provider I/O.

**Why conservative limits:** Codex consumes the user's subscription quota. A short map can amplify into hundreds of concurrent requests. Until costs and rate limits are understood, use 4 concurrent calls per process, 100 calls per Run, and 256 KiB total prompt + serialized input per call. Excess concurrency queues without counting queue time against request timeouts; call/byte excess rejects without silent truncation. Constants are centralized in `src/tools/llm.zig`; subagents also have llm, with independent per-process limits. Existing provider timeouts remain unchanged; Run JS budgets exclude network waits.

**Why no cross-Run state:** In-process variables or persistent model handles cannot be fully restored from logs, breaking `--resume` consistency and adding hidden-state ordering dependencies to future streaming execution/speculative prefetch. Runs remain stateless map/composition units; write intermediate JSON files as in [0003](0003-stateless-runs.md).

**Confidence and reconsideration:** Both wire protocols have only local mock verification for request format, concurrency, JSON repair, usage, and cancellation; mock latency is not real model performance. Reconsider quota budgets, connection reuse, or full schema validation when real batch tasks show overly tight limits, material connection overhead, or a need for stronger result guarantees. Defer stateful Session handles.
