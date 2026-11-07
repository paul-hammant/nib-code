# 0023: Two sandboxed hook events

Status: accepted

User-configured formatters and notifications need predictable boundaries without a general event framework. Hooks default off. V1 has only `after_edit` and `turn_end`, configured as single-line command arrays.

Commands run sequentially through `/bin/sh -c` in the project root, using bash's write sandbox and API-key filtering. Commands time out after 30 seconds; turn-end sequences share that deadline to bound CLI exit. Stop on the first failure. Successful execution is silent.

After-edit commands batch all edit/write changes once per settled Run. Paths are shell-quoted for `{files}` and newline-separated in `NIB_FILES`. Failures alone add command, exit code, and captured output to the model's Run result under `hook`, using the existing display budget. Child Sessions execute and report their own after-edit hooks, including background Runs. Hook writes do not participate in undo snapshots.

Turn-end commands run on a background thread only for root TUI/ask Sessions, including failure and cancellation. They receive status through the environment. Output is discarded and failures produce only a dim TUI notice. Shutdown joins outstanding threads; ask waits at most the remaining sequence deadline.

The Session log records command, event, exit code and duration without turn-end output. Replay never launches hooks. No additional events, command configuration, timeout settings, or hook changes to model prompts are introduced.
