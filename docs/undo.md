# `/undo`: revert file changes by Turn

Enter `/undo` while the TUI is idle to revert the latest not-yet-undone Turn that actually changed files through `tools.edit` / `tools.write`. Repeat to go further back. During an active Turn, the TUI says `Press Esc to stop the Turn before /undo.`; unfinished changes after stopping are included in that Turn's undo record. Question-only Turns consume no record.

```text
› /undo
[undo] Restoring files to their contents before the latest edited Turn. Re-read listed files before continuing.
restored: /project/src/main.zig
deleted: /project/new-file.txt
```

Each file retains its complete bytes before the Turn's first change. New files are represented as absent and deleted on undo, leaving any newly created empty directories. Chinese paths and raw binary contents can both be restored. Parent and subagent edit/write (including fork, resume, and background agents) share the parent Turn's record, independently of display-limited diffs or child `changes` summaries. Undo does not call git or modify working files untouched by edit/write in that Turn. `/js` is outside model Turns and creates no undo records.

## Conflicts and scope

Before execution, hold the existing cross-process file lock and check each file's canonical path, regular-file type, and current-byte SHA-256. Current contents must match the version recorded after nib's last successful edit/write in that Turn; other content appearing between two nib writes in the Turn also marks a conflict. Any conflict **rejects the whole Turn without changing any working files**, lists `skipped (external change or incomplete snapshot)` paths, and preserves the record for retry. Deleted paths, symlink replacements, oversized files, and unreadable files also cause rejection. Nonconflicting files are not reverted either.

Side effects from bash, formatters, scripts, user editors, and other independent Sessions are outside scope. Changes to tracked files cause the conflicts above; changes elsewhere remain untouched. External writes with identical per-file contents cannot be distinguished by hashes. Locks coordinate only nib file tools sharing NIB_HOME; external writers can still write after validation. As with edit/write, the race between the final check and atomic replacement cannot be eliminated. Stop external tasks that modify target files during undo, including detached bash.

Restoration starts only after all checks pass. Multi-file restoration is not a filesystem transaction: disk or permission errors midway report restored/deleted and failed paths; successful paths are marked undone, and retries handle the remainder. Incomplete snapshots are conservatively rejected, without guessing or overwriting. Restoration uses edit/write's same-directory temporary-file plus rename approach and preserves current target permissions; it does not restore timestamps, inodes, hard-link relationships, or directory metadata.

## History, resume, and storage

Before undo, commit a short message stating that the user requested undo and files should be reread before continuing. Then commit the result as a user message in model history and the main Session log, listing restored, deleted, or conflicting files. Both messages carry local-only `source:"undo"`, trigger no model request, count as no new Turn, and display as information entries after resume; their bodies reach the model in the next request. Recording intent first ensures a reminder to reread even if failure occurs after restoration but before result logging. Old conversation and token usage are not rolled back.

The first version's undo stack exists only in the **currently open TUI Session instance**. After exit, `/new`, or `/resume` switching, earlier Turns cannot be undone; resume rebuilds conversation and saved undo notices but does not load old snapshots. Without available records, explicitly show `Nothing to undo in this process. Restored sessions cannot undo earlier Turns.` New Turns after resume can be undone normally.

Snapshots live in `$NIB_HOME/sessions/<session-id>.undo/<turn-id>/`, with parent directories mode 0700 and raw snapshots/metadata mode 0600. `.before` stores original bytes; `.json` stores canonical paths, last-written SHA-256, and completion status. The cross-process lock file records that Turn's snapshot-failure reason; snapshot contents are not sent to the model. Each path stores original contents once per Turn. Limits:

- Undo snapshots support up to 16 MiB per file both before and after changes. File-tool read boundaries are unchanged; write can still overwrite large files whose snapshots cannot be read, and edit can still produce content larger than this limit.
- Each Turn's record allows 256 changed paths and 64 MiB of original snapshots; newly created empty files also consume a path.
- Retain the latest 8 finished edited Turns plus the active Turn, for at most 576 MiB of snapshot contents plus bounded path/hash metadata. Delete snapshots when evicting oldest records, successfully undoing, exiting, or switching Sessions.
- In undo-enabled TUIs and their subagents, unreadable/unsavable snapshots (including unwritable snapshot directories) or exceeded limits do not change edit/write behavior; JS results receive no added notice. Mark the current Turn incompletely undoable and record the reason, showing one short notice at Turn end. `/undo` explains the reason and rejects the whole Turn without partial restoration or skipping it to undo older Turns; subsequent complete records remain undoable. Ordinary `nib ask` creates no undo records.

Snapshot data resides mainly on disk; recording reuses existing before contents from file tools. Undo loads at most one Turn's 64 MiB original snapshots and reads current contents file by file. Crashes may leave snapshots; next opening the same Session in the TUI cleans them after acquiring the main log's exclusive lock, without restoring the undo stack. The project currently has no retention policy automatically deleting old Session logs; when deleting Session data, also delete the matching `.undo` directory. Cleaning the entire sessions directory covers it too. Snapshots may contain secrets; like tool recordings they stay local, and require inspection before sharing log directories.

Verification: `zig build test --summary all`; after `zig build`, run `python3 tests/test_undo.py`, using local mocks only.
