---
status: accepted
date: 2026-11-01
---

# One process per Session, without a shared daemon

Each Session is an independent `nib` process, unlike jcode's single daemon hosting all Sessions with a client-only TUI. The Session engine (Turn loop, Provider, Run, Session log) is independent of the TUI and communicates through events, so it could move unchanged into a daemon later.

**Why:** jcode's daemon saves mainly runtime memory: pi uses about 80 MB per Session because each is a Node process (jcode README's own benchmark, a primary source but measured by jcode). Zig processes are already light; measured per-process overhead is comparable to jcode's incremental shared-server Session overhead below. One process per Session also isolates failures naturally: the OS reclaims all memory on exit, without jcode's shared-runtime ownership machinery in `docs/SESSION_RUNTIME_OWNERSHIP.md` (reservations, execution leases, tombstones, stale-event isolation).

**Measured (2026-11-01, ReleaseFast, locally):** 10 concurrent TUI processes each completed a Turn with a local mock server; idle PSS was about 3.08 MB each, 30.8 MB total; RSS about 6.5 MB each. One real HTTPS request to api.deepseek.com with TLS peaked at 7.6 MB RSS. Comparison: jcode README reports 71.3 MB for the first Session and about 3.3 MB PSS for each additional Session.

**Limits:** The TUI measurement used no TLS, one Turn of history, and no Runs. Methods, machines, and workloads differ from jcode; compare orders of magnitude only, not individual figures.

**What this gives up:** Three things directly enabled only by a shared server: cross-Session collaboration (file-change notifications, agent messaging), sharing expensive external processes such as MCP, and continuing active Turns after terminal closure.

**When to reconsider:**
- Multi-agent collaboration is needed; this need not mean a jcode-style daemon, as a lightweight message relay might suffice;
- MCP integration makes a separate MCP setup per Session a real burden;
- Users need tasks to continue after terminal closure;
- Real workloads with TLS, long histories, and executed Runs have materially higher per-process PSS than the figures above.
