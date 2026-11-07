---
status: accepted
date: 2026-11-06
---

# Two layers of isolation

Language-level isolation gives the Sandbox no host capabilities except Tools. System-level isolation restricts what bash can write, using the OS: Landlock on Linux, `sandbox-exec` on macOS. The system layer was deferred on 2026-11-01 in favor of the deny-list ([0006](0006-deny-dangerous-commands.md)) and implemented on 2026-11-06. The deny-list stays.

**Why:** With a bash Tool, language-level isolation cannot stop anything; model-written code runs with the user's permissions. Command-text matching prevents mistakes, not deliberate or accidental bypasses (variables, scripts). The OS enforces by effect instead of text.

## Decisions

- **Write-only restriction.** Reads and network stay open. Reads are needed by every build and search; restricting them breaks normal use and the model cannot exfiltrate anything the user's own tools could not. Blocking writes outside the project stops the damage that matters (clobbering dotfiles, other repositories, system state) while staying nearly invisible.
- **Writable roots:** the project directory (first cwd ancestor with `.git`, else cwd; linked worktrees add their gitdir and common dir so `git commit` works), temp dirs, a few devices, a cache allowlist, and user-configured extras. The cache list is the minimal set that keeps cargo, npm/pnpm/yarn/bun, go, gradle, maven, pip/uv and zig working; the full list is in [config.md](../config.md#sandbox). `$NIB_HOME` is excluded: nib writes it from its own unrestricted process, commands should not.
- **Child-only Landlock.** nib's own process is never restricted (it writes logs, undo snapshots, config). The restriction is applied after fork in the bash child. Zig's `std.process.spawn` has no pre-exec hook, so nib spawns itself as `nib __jail <roots>... -- bash -c …`; the helper calls `landlock_create_ruleset`/`add_rule`/`restrict_self` (raw syscalls, no dependency) with `PR_SET_NO_NEW_PRIVS`, then `exec`s bash in place. Landlock needs ABI 2 (kernel 5.19) because earlier ABIs always deny cross-directory rename, which would break `mv` inside the project. The handled rights are the write rights only; ABI 3 adds truncate. Rules for non-directory roots (`/dev/null`) are limited to file rights.
- **macOS:** `sandbox-exec -p` with a per-command SBPL profile: `(allow default) (deny file-write*)` then allow the roots. It is deprecated by Apple but is what Codex uses, and no replacement works for a CLI.
- **Scope.** Foreground bash, background bash and subagent Sessions. Children inherit the effective mode and roots through the stdin configuration envelope; each child sandboxes its own bash.
- **In-process tools.** edit/write cannot be restricted through the OS without restricting nib itself, so they check the canonical path (symlinks and `..` resolved) against the same roots and return an error as data.
- **Fallback.** If Landlock or `sandbox-exec` is unavailable (old kernel, Landlock disabled, nested sandbox), commands run unsandboxed: one dim notice per Session, a `sandbox_unavailable` record in the Session log, and `/status`. A command never fails because of the sandbox being unavailable.
- **No approvals.** The user decided against approving individual Tool calls (2026-11-01). A denied write returns the ordinary `EACCES`; nothing is injected into results and the bash result shape is unchanged (no `sandbox` field: it would cost tokens on every call, and tests and models rely on `{exit_code, output}`). Users widen the roots with `[sandbox].writable` or turn the sandbox off with `mode = "off"` / `NIB_SANDBOX=off`.

## Confidence

- Measured: unit tests for root construction, path checks, config; `tests/test_sandbox.py` on Linux (project writes, denied outside writes, temp dirs, caches, symlink escape, background bash, subagent, off switches).
- Unverified: behavior on a real macOS machine beyond CI, and individual toolchains that write outside the allowlist (they fail with permission errors; add the directory to `writable`).
- Known limits: reads and network are open; Unix-socket connects, ioctls, and anything inside the project (including `.git/hooks`) are not restricted; the sandbox does not stop a process that already holds an open descriptor outside the roots.

## When to reconsider

- Common toolchains break often enough that the allowlist grows unwieldy;
- Landlock availability on user machines is too low to matter;
- `sandbox-exec` is removed from macOS.
