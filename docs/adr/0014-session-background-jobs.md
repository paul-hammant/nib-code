# 0014 Session-level background tasks and stopping by id

## Decision

Ordinary background bash/agent calls retain waiting semantics. Bash adds `background: true, detached: true`: Session owns the task across Runs and normal Turns, without blocking final answers or Step-limit cleanup. Default `timeout_ms: 0` means no deadline; concurrency and output limits still apply. `tools.stop({id,reason})` cancels and joins a background bash/agent, delivering its completion message once as usual. Finished tasks return `stopped:false`; unknown ids reject. Nonblank reason is required; otherwise reject and retain the task. Actual stops return a notice that canceling unfinished tests cannot produce a passing result.

Tasks retain separate Session-level `a1…` / `b1…` counters shared with foreground and `/js`; resume continues log high-water marks without restarting processes. Running detached tasks show `detached` in the tree; terminal states and result entries keep existing formats.

Completion only enters the inbox, delivered before the next Step without automatically starting idle Turns. Start and stop are ordinary tool calls using shared settlement/recording; result-message bytes count toward the receiving Step's output_bytes. Turn cancellation/failure and Session exit/switch clean up all tasks; ask exits its Session after returning, also cleaning up.

Detached tasks live as long as their shell process. All bash calls clean up their entire process group and deliver results when the shell exits, including successful exit; `nohup/&` cannot bypass cleanup. Detached services run in the foreground within the command. Stop, timeout, Turn cancellation/failure, and Session exit also clean up groups. Waiting uses standard-library child-process interfaces, without process-table scans or delayed group-leader reaping. stop waits for agent execution occupancy to release before returning, preserving task-id/child-Session mappings for reuse.

## Rationale

A formal local batch showed the model repeatedly canceling its own background tasks, leaving validation unfinished. Requiring reasons for every explicit stop avoids guessing which commands validate, while allowing stops for user requests, specific failures, or changed requirements. The host checks only nonblank reasons, not natural-language meaning; long duration or absent output alone does not prove a hang.

Issue #32's services and watch tasks need resource ownership across Turns, not cancellation bypasses. Making all background tasks nonblocking would change bounded delegation semantics and cancel them prematurely when ask returns. Explicit detached reuses existing task ids, concurrency limits, process-group execution, and inbox without adding idle automatic model requests or a pid interface.

## When to reconsider

Consider separate query/wait protocols or service management when idle output inspection, user-level task lists, interactive child Sessions, or survival across nib processes is needed; detached implies none of these.

## Extension: long Runs automatically move to the background

Models rarely set background for long commands, so foreground waits lose overlap with model reasoning. Move the entire Sandbox Run to the background rather than changing an already-awaited bash return object: at a configurable wall-time threshold while waiting for tools, commit a notification first, continue the script, and format final output into the inbox through the same formatter. Allocate a separate r ID, non-detached, reusing background lifecycle, cancellation, and Turn cleanup rules. Each Run owns cancellation, changes, llm call counts, timing, and recording buffers so later Runs cannot reset them; shared file observations retain only existing per-operation protections.

Without independent work, a tool-free reply or successful empty Run with no output/host calls makes Session wait locally for results; waiting markers exist only in local history. Pure JS work with output continues normally, avoiding mistaking useful computation for polling. See [0016](0016-superseded-bash.md) for supersession stopping individual old bash calls without changing Run continuations or other tools.

Run execution threads operate only their own sandbox and native tools; the Session main thread registers, polls, delivers events, and commits history. Calls recordings atomically append whole-Run buffers in completion order, so resume can no longer assume Step order. SHA-256 cross-Run references may target only written data no later than the current Step, preventing dangling references if resume deletes uncommitted later Steps. Full semantics: [run-output.md](../run-output.md#long-runs-automatically-move-to-the-background) and [session-log.md](../session-log.md#automatic-background-run-recording-and-statistics).
