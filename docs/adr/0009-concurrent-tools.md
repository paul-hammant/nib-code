---
status: accepted
date: 2026-11-01
---

# Tool calls within a Run are truly concurrent, ordered by JS semantics

Host functions immediately return Promises; work normally executes on threads, resolving back on the Run thread because QuickJS is not thread-safe. `tools.sleep(ms)` is an exception: native sandbox event-loop timers, without processes, threads, or tool concurrency slots. See [run-output.md](../run-output.md#run-内延时与轮询) for waiting, cancellation, and draining. Scripts determine ordering: `Promise.all` is parallel, successive `await` is serial. The only extra rule is per-path locking for `edit` / `write` on the same path.

**Why:** Previously synchronous tools made `Promise.all` correct but nonconcurrent. Subagents ([0010](0010-subagents.md)) need parallel dispatch to be useful, so concurrency is prerequisite. Code already expresses ordering; no extra rules are needed.

**Rejected alternative:** DeepSeek Harness runs read-only operations concurrently but serializes side effects in submission order (**secondary**: unverified third-party blog). This changes `Promise.all` semantics by tool and adds a rule for models to remember.

**Implementation:** At most 8 tool worker threads per Run, with excess calls queued in the Run. Completion results enter a mutex-protected queue; only the Run thread calls QuickJS. Without pending jobs, wait at most 20 ms before checking cancellation; tool waits consume no JS budget. Whether the top-level Run Promise fulfills or rejects, drain in-flight/queued tools, JS jobs, and calls initiated by continuations until no work remains; rejection still reports the top-level Promise's original reason. No call failure cancels other calls, including non-agent tools. User cancellation or JS timeout stops all Run tools and sets `Tools.cancel`; individual tool timeouts, bash supersession, and id-based stop affect only their target, leaving other calls' drain unchanged. On interruption, reclaim completed-call data immediately, join remaining threads, then free call data and QuickJS. Path locks cover complete edit/write operations; resolve existing symlinks and canonicalize nonexistent paths through the nearest existing parent. Bash/other-process writes are outside these locks.

Thus a failed read in `Promise.all` does not stop parallel bash writes; even rejected Runs wait for foreground agents, paying remaining time/usage, while Esc remains available. User cancellation/JS timeout leaving unfinished calls adds `[stopped before completion: bash #0, agent #2]`; indices are 0-based creation order across all tool calls in that Run, not per-tool numbering.

Bash process-group startup, bounded output polling, cancellation, and reaping moved to `src/tools/process.zig` for later subagent reuse. Fixed an old flaw: continue polling process exit after output EOF so commands closing output remain cancelable and time-limited.

**Confidence:** Measured locally (2026-11-01, Debug, `src/tools.zig` tests): two `sleep 0.3` calls took 307 ms with Promise.all versus 611 ms with successive await. All 50 unit tests passed, covering JS exceptions, cancellation/timeouts during 12 calls, 16 parallel same-path edits, dangling symlink aliases, and post-EOF timeout; Session e2e passed. Primary source that day: Zig 0.17 `std/process.zig`, `std/start.zig` explicitly guarantee thread-safe Init.gpa; Debug/ReleaseSafe use SafeAllocator, libc-linked ReleaseFast/Small use c_allocator.

Follow-up verification that day: Debug/ReleaseFast passed 53 unit tests and e2e. ReleaseFast exposed and prompted a fix for null-terminated tool JSON buffers (primary: QuickJS `quickjs.h`'s `JS_ParseJSON` declaration).

**Timeout boundary (2026-11-02):** In a real user task, Run's total timeout stopped a normally working subagent at 5 minutes, leaving unfinished files. Run limits interrupt JS infinite loops, not tools with independent timeouts. Therefore accumulate nanoseconds of QuickJS execution segments: initial script, pending jobs, tool-result parsing/resolve, return serialization, and error conversion (getters/toString can execute JS). Pause while waiting on completion queues and resume deductions afterward; never reset per await. Cancellation checks are independent. This measures monotonic wall time of execution segments, not OS thread CPU time.

Measured locally that day: with a 100 ms Run budget, successive bash sleep 0.3 calls complete; two 60 ms JS busy loops across await still trigger cumulative timeout. Tests also cover pure infinite loops, cleaning up running/queued tools after timeout, and cancellation after waits longer than the budget. Script instructions now prefer native search and JSON-escaped double-quoted strings for file/command text. Special-character tool-table examples execute actual writes in the sandbox with byte-for-byte checks, avoiding String.raw's continued backtick/interpolation parsing.

**When to reconsider:**
- Models cause errors by running mutually dependent side effects concurrently in `Promise.all`.
