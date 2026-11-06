---
status: accepted
date: 2026-11-01
---

# Zig, from scratch

nibcode is implemented from scratch in Zig (currently 0.17.0). pi, jcode, prime-agent, and DeepSeek Harness are design references only; no code is reused.

**Why:** None of the three local reference projects use Zig (pi uses TS; jcode and prime-agent use Rust), so extending them would effectively mean rewriting. Their size (about 930,000 lines for jcode and 620,000 for prime-agent, source counted with `wc -l` on 2026-11-01) also conflicts with necessary minimalism. Zig offers nearly cost-free C interoperability (QuickJS, possibly tree-sitter later), a single static binary, per-Turn arena memory, fast startup, and low memory use.

**Confidence:**
- Measured: QuickJS-ng links after compiling just 4 C files; libvaxis main supports 0.17; `nib js` averages 1.6 ms with peak RSS 3.7 MB (see the measurements in [docs/README.md](../README.md)).
- Known cost (measured): std changes quickly. In 0.17 alone, `Allocator.dupeZ` became `dupeSentinel`, and translate-c could not translate QuickJS compound-literal macros (`JS_UNDEFINED`).
- Inference: performance benefits mainly concern startup, memory, and parallel agents; model latency dominates individual tasks, limiting the language's impact.

**When to reconsider:**
- Keeping up with Zig upgrades consistently costs more than implementing features;
- Essential capabilities remain absent from Zig's ecosystem and cannot be supplied by C libraries (e.g. HTTP/2 is needed but unsupported by `std.http`).
