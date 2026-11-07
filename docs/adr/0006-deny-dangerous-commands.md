---
status: accepted
date: 2026-11-01
---

# No approvals; reject dangerous commands on the host

nib does not approve individual Tool calls. System sandboxing, deferred when this was written, was added later ([0004](0004-two-layer-isolation.md)); the deny-list stays as a first guard. Before execution, bash commands pass through `src/tools/policy.zig`: dangerous categories are rejected, returning an error advising the model to ask the user to execute the command themselves if truly needed. No dialogs or user interruptions.

**Rejected categories (selected by the user, 2026-11-01):**
- Destructive deletion: recursive `rm` targeting `/`, `~`, `$HOME`, system directories, `.`, or `..`; `mkfs`, `dd of=/dev/*`, `shred`, `wipefs`, and partitioning tools.
- Privilege escalation and system operations: `sudo`, `su`, `doas`, `pkexec`, `shutdown`/`reboot`, etc., `systemctl`; executing downloads through shells (`curl … | sh`, `bash <(curl …)`, `sh -c "$(curl …)"`).

**Credential boundary:**
- Before launching any child process, `process.run` removes common API-key/token environment variables defined centrally in `src/tools/secrets.zig`, including caller-supplied environments, preserving ordinary variables. Child Sessions receive provider configuration through stdin JSON; API keys enter neither argv nor child environments. Codex configuration contains no login token.
- Bash command text rejects references to default `.codex`, `$CODEX_HOME`, and current custom credential directories, including wildcards and recursive scans. read/edit/write reject default and custom credential paths, using canonical paths to detect symlinks; credentials are not read then filtered.
- These protections prevent accidental credential disclosure/destruction. The OS write sandbox ([0004](0004-two-layer-isolation.md)) adds write containment, not read protection. Variable concatenation, arbitrary scripts, reads by other processes, and deliberate bypasses are outside guarantees. Environment cleanup covers only the maintained variable list.

**Explicitly allowed (selected by the user):** git operations (including `push --force`, `reset --hard`) and edit/write paths outside the working directory.

**Why:** Users do not want approval interruptions, but no approvals does not mean unrestricted dangerous operations. Host rejection prevents common catastrophic mistakes without interruptions.

**Confidence:**
- Measured: `src/tools/policy.zig` tests cover rejection and allowance. `rm -rf build`, `git push --force`, and `curl … | jq` pass; `bash -c 'rm -rf ~'`, `env FOO=1 rm -rf /`, and `timeout 10 rm -rf /` are rejected.
- Known limit: command-text pattern matching **prevents mistakes, not deliberate bypasses**. It misses `r''m -rf /`, variable-built commands, and commands in script files. Dangerous command text in heredoc bodies can be mistaken for execution; the model can use `write` instead.

**When to reconsider:**
- Normal development commands are wrongly rejected: adjust rules and add corresponding allowance tests;
- Rules miss an incident: evaluate additional rules versus reviving [0004](0004-two-layer-isolation.md)'s system sandbox.
