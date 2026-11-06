---
status: accepted
date: 2026-11-01
---

# Every Run uses a fresh sandbox

Each Run creates a QuickJS runtime and context and destroys them on completion; variables do not persist across Runs. Scripts persist data across Turns by writing files through Tools.

**Why:** Resumed model context comes from the Session log (see [CONTEXT.md](../../CONTEXT.md)). A persistent kernel would hide some state in the process heap; restoring messages alone cannot restore those variables. Logs do not restore external file/command side effects either; this decision only prevents extra hidden persistent Run state. Code-driven execution mainly helps within a Run; cross-Run persistence is secondary. Files suffice when needed, without introducing a variable-store concept.

**Rejected alternatives:**
- Persistent REPL (prime-agent): RLM's "context as variables" feels more natural but sacrifices replayability.
- Explicit `store/load` variable storage, content-addressed in the log (proposed in discussion): combines both benefits but adds a concept; defer until a real need appears.

**Sources and confidence (2026-11-01):**
- Primary source: `src/sandbox.zig` creates runtime/context for each evaluation; `src/session.zig` and `src/session/log.zig` restore model context only.
- Inference, unmeasured: cross-Run state is not essential; files are sufficient.
- Not measured separately: QuickJS context creation time. The only current figure is 1.6 ms total for process startup + runtime creation + evaluation.

**When to reconsider:**
- Models repeatedly redo expensive work, especially subagent calls (each costs tokens);
- File-mediated data causes material extra tokens or errors on the model side.
