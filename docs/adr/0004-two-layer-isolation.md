---
status: deferred
date: 2026-11-01
---

# Two layers of isolation

**Deferred (2026-11-01):** The user decided to defer system-level sandboxing in favor of host-side rejection of dangerous commands; see [0006](0006-deny-dangerous-commands.md). Language-level isolation is implemented and retained. The original proposal follows for future reference.

Two layers: language-level isolation gives the Sandbox no host capabilities except Tools; system-level isolation restricts bash and file Tools with Landlock + bwrap on Linux. Initially support Linux only.

**Why:** With a bash Tool, language-level isolation cannot stop anything; the system layer is indispensable. Conversely, language-level isolation confines external effects to Tools, with each call validated and logged, providing one checkpoint for auditing and possible future restrictions.

**No approvals:** The user decided against approving individual Tool calls (2026-11-01). Safety relies solely on these two isolation layers and logs.

**Reference:** DeepSeek Harness relies on a system sandbox (bwrap + Landlock on Linux) and explicitly rejects `node:vm` as a security boundary (**secondary source**: third-party blog, unverified). Its reason is that vm shares all of Node's system capabilities; this does not apply to QuickJS without quickjs-libc.

**Confidence:**
- Measured: language layer. Tests in `src/sandbox.zig` confirm that `require/process/std/os/fetch` are absent.
- Unimplemented: system layer. The exact Landlock/bwrap combination, network restrictions, and availability on user machines remain unverified.

**When to reconsider:**
- bwrap or Landlock is widely unavailable on target machines;
- System restrictions frequently break common development tasks (builds, tests, package management), requiring revised boundaries.
