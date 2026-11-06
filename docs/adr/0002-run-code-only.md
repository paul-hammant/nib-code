---
status: accepted
date: 2026-11-01
---

# Expose only run(code): the model writes JS for QuickJS

The model API has one entry point, `run(code)`. All Tools (read, bash, etc.) are functions in the Sandbox. The system prompt describes them with valid JS method signatures and comments (destructured arguments with defaults, e.g. `async read({ path, offset = 1, limit = 2000 })`); models write JS executed by embedded QuickJS-ng.

**Why:** Code-driven execution mainly helps within a Run: intermediate read/search/filter/aggregation data stays in the Sandbox and only results reach the model, avoiding context growth. JS was chosen over Python because QuickJS is a low-overhead pure C library embedded in-process, without host capabilities by default; async/await and JSON naturally fit Tool orchestration. Descriptions and code use the same language: initial TS declarations (pi's approach) gave contradictory signals by showing TS while forbidding it, so changed to JS method signatures on 2026-11-01. Measured bytes that day: old TS declarations 468; JS signatures 441 with extra default-value information. An intermediate full-call-example-per-tool form used 589 bytes and was discarded as too long. Tests parse descriptions with QuickJS to ensure validity.

**Data/display boundary:** Tools return complete data to JS; context-protecting truncation occurs only when Session delivers Run output to the model: `tools.truncateMiddle` retains about 16 KiB total head/tail. Never middle-truncate read/bash results or insert notices: JS uses them for replacement/writeback, turning display markers into file contents and causing irreversible corruption.

- `read({ path, offset = 1, limit = 2000 })` returns `{ text, next_offset }`, preserving requested lines and newlines. next_offset is the next page's 1-based line number, or null at EOF. The 16 MiB file limit is unchanged; pagination stays outside text.
- `bash` still returns `{ exit_code, output }` with complete output; beyond 16 MiB it terminates the process group and errors, asking for output redirection to a file rather than returning partial success.
- Explicitly bounded results differ from full content: grep keeps its 500-byte line limit; grep/glob flag result-count limits with truncated; fetch keeps its 1 MiB text limit with a separate `truncated` boolean, without text markers. Downloads over 5 MiB error. Scripts should check completeness before using results.

**References (sources and confidence):**
- pi codemode: QuickJS (wasm), TS signatures (primary: local `pi/packages/codemode` source).
- jcode codemode: embedded rquickjs (primary: local `jcode/crates/jcode-codemode` source).
- prime-agent: sole tool `python_repl`, persistent CPython (primary: local `pa-core/src/prompts/layers/core.md` source).
- DeepSeek Harness PTC: only `run_code`, fresh Node process per program, later removed mixed native/PTC mode (**secondary**: third-party redreamality.com blog, not officially verified).

**Confidence:**
- Measured: embedded QuickJS, memory limits, absent host capabilities, top-level await, Tool calls, timeout interruption (`src/sandbox.zig` tests); complete model run call → execution → result return → answer loop passed local mocks (2026-11-01).
- Measured: QuickJS errors for TS syntax (e.g. `missing initializer for variable`) do not explain the cause. A SyntaxError hint was added then removed after switching to JS descriptions: observe whether real models still write TS before adding it back.
- Measured (2026-11-01, deepseek-chat, one task: list the 5 largest files under /tmp): all 5 scripts were valid JS without TS syntax; last-Step input 1848 tokens, 1664 cached (about 90%). Too small a sample for more than preliminary evidence.
- Observation: the model mostly used `tools.bash` + `console.log`, delegating sorting/filtering to shell pipelines and probing through 5 Runs rather than combining Steps. This example did not demonstrate fewer Steps from code-driven execution; assess more complex coding tasks.
- Inference, unmeasured: whether overall PTC token overhead for simple operations is acceptable (only final-Step usage was recorded then; later changed to Turn accumulation).

**When to reconsider:**
- Models frequently produce TS or other unsupported syntax and cannot self-correct from errors: consider SyntaxError hints first, then pre-execution type stripping;
- Simple-operation token overhead is materially higher than native tool calling: consider native calls for a few frequent Tools (hybrid mode);
- Python-ecosystem tasks become common: consider Python as a second runtime through the same Tool pipeline.
