# std.fs / std.os: stat with inode and mode, flock, O_EXCL with a mode, environ

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its Tools slice.
**To:** aether, `std.fs` and `std.os` (0.909.0).
**Stand-in meanwhile:** `ae/nib/sysgap/` (marked C; delete as each lands).

nib's file tools (read/edit/write) detect external changes, lock across
processes and replace files atomically while keeping their permissions
(docs/run-output.md "File replacement, Session versions, and cross-process
coordination"). What std.fs lacks for that:

1. **A full stat.** `fs.file_stat` gives kind, size and a seconds mtime. nib
   compares `(inode, size, mtime in ns)` to see whether a file changed since
   the Session last read it, and copies the mode bits onto the replacement.
   Proposed: `fs.stat(path, follow) -> (*Stat, err)` with kind, mode (07777),
   ino, dev, size, mtime_ns (and nlink), `lstat` when follow is 0.
   Repro of the gap: two writes in the same second of equal size are
   indistinguishable to `fs.file_stat`; there is no way to read a file's mode.
2. **Advisory locks.** nib coordinates edits with other nib processes through
   `flock(LOCK_EX)` on `$NIB_HOME/locks/<sha256>`, polled with LOCK_NB so a
   wait stays cancelable. Proposed: `fs.lock_open(path) -> (fd, err)`,
   `fs.try_lock(fd, exclusive) -> (int, err)`, `fs.unlock(fd)`; plus
   `fs.fd_size` / `ftruncate` (exists) on that fd (undo keeps a failure code
   in the lock file's length).
3. **Exclusive creation with a mode.** Atomic replacement creates
   `.nib-<random>` beside the target with `O_CREAT|O_EXCL` and mode 0600 (or the
   creation mode), writes, `fchmod`s to the old mode, optionally `fsync`s, then
   renames. Proposed: `fs.create_exclusive(path, mode) -> (fd, err)` and
   `fs.fd_write_all`, `fs.fchmod`, `fs.fsync` on fds (fsync exists for handles).
4. **The errno behind an error.** nib's tool errors carry Zig's names
   (`FileNotFound`, `NotDir`, `SymLinkLoop`, `IsDir`, `AccessDenied`); a
   structured kind per call (as `fs.copy`/`realpath` already return) would do.
5. **The environment as a list** (`std.os`): building a child's environment
   without the credential variables needs every `NAME=value`; std.os has
   only `getenv`. Proposed: `os.environ() -> list of strings`.

Also seen, not blocking: `os.wait` reports a signalled child as 128+signo, the
same as `exit 128+n`; upstream nib reports `exit_code: null` for a signal.
A `(code, signal)` form would let it. And `os.spawn_proc_to` has no cwd
(nib does not need one: children inherit its cwd).

## Added by the Session slice (2026-11-12)

6. **Positional writes on a locked fd.** The Session log
   (`ae/nib/session/log`) holds `$NIB_HOME/sessions/<id>.jsonl` under
   `flock(LOCK_EX)` for the Session's life and writes every record at its own
   offset with `pwrite`, so a torn last line left by a crash is overwritten
   by the repair record instead of being appended after. `fs.pwrite` exists for
   `fs.open` handles, but a handle cannot be flocked and an fd from (2) cannot
   be pwritten. Proposed: `fs.fd_pwrite_all(fd, data, offset) -> err` (and
   `fs.fd_fsync(fd)`). Stand-in: `sysgap.pwrite_all`.

**RESOLVED** in Aether 0.915.0 (std.fs stat, locks, O_EXCL and fd ops, std.os.environ; 2026-11-14); the stand-in is removed from the port.
