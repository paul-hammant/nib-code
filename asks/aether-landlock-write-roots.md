# A write-only Landlock restriction for one child

**From:** the nib Aether port, its bash containment (upstream jail.zig, ADR 0004).
**To:** aether, `std.sandbox` (0.909.0).
**Stand-in meanwhile:** `ae/nib/tools/jail/landlock.c` (marked; Linux only).

nib's opt-in workspace mode restricts what bash can *write*: the project,
temp dirs, a cache allowlist. Reads, processes and the network stay open on
purpose (a build needs them). `std.sandbox.spawn_socket`'s kernel layer holds
reads, process creation and the network as well, through a grant list, so it
is a different contract; nib's `nib __jail <root>... -- <command>` helper
instead makes the three Landlock syscalls itself (handled = the write rights,
plus REFER from ABI 2 and TRUNCATE from ABI 3; a path-beneath rule per root,
file rights only for non-directories; PR_SET_NO_NEW_PRIVS; restrict_self) and
execs the command.

Proposed, in std.sandbox: `sandbox.landlock_abi() -> int` (0: none,
-1: disabled) and `sandbox.restrict_writes(roots: list) -> string` (""
or why not), to call in a child before `os.execv`; or a `spawn` variant that
applies it between fork and exec, which would also remove the need for the
helper re-exec. macOS needs nothing (sandbox-exec with an SBPL profile).
