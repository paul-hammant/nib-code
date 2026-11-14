# Ask: std.ipc.write_some / write raise SIGPIPE on a full pipe whose reader died

**From:** the Aether port of nib (`paul-hammant/nib-code`, branch `aether-port`), tools.agent.
**Aether:** 0.909.0, macOS arm64.

## Motivation

A subagent is a child `nib` started with `os.run_stdio`; the parent writes the
child's input (prompt, config, possibly a long forked history) to `to_child_fd`
on a worker thread, while the main thread enforces a deadline and kills the
child. `std/ipc/module.ae` documents that a write to "a socket or a pipe whose
peer has gone" is "an error, not SIGPIPE", and `write_some` likewise "(an
error, not SIGPIPE)". When the pipe is *full* and the reader is then killed,
the blocked writer instead takes SIGPIPE and the whole process exits 141.

(Writing to a pipe whose reader is already gone, when the pipe has room,
does return `"ipc.write_some: Broken pipe"` as documented.)

## Repro

```aether
import std.os
import std.ipc
import std.list
import std.string
import std.worker
import std.sync

main() {
    argv = list.list_new()
    list.list_add(argv, "-c")
    list.list_add(argv, "sleep 5")
    to_fd, _from_fd, pid, _err = os.run_stdio("sh", argv, null)
    big = "xxxxxxxxxxxxxxxx"
    k = 0
    while k < 13 {
        big = "${big}${big}"
        k = k + 1
    }
    done = sync.atomic_new(0)
    worker.run_detached(|| {
        off = 0
        n = string.length(big)
        while off < n {
            ipc.wait_writable(to_fd, 50)
            wrote, werr = ipc.write_some(to_fd, big, off)
            if werr != "" {
                println("err ${werr}")
                break
            }
            off = off + wrote
        }
        sync.atomic_store(done, 1)
        return null
    })
    sleep(100)
    os.kill(pid, 9)
    os.wait_pid(pid)
    while sync.atomic_load(done) == 0 { sleep(5) }
    println("survived")
}
```

Expected: `err ipc.write_some: Broken pipe`, then `survived`.
Found: nothing printed, exit status 141 (SIGPIPE). `ipc.write` behaves the same.

## Stand-in

`ae/nib/sysgap/sysgap.c` `nibsys_ignore_sigpipe()` (`signal(SIGPIPE, SIG_IGN)`),
called by `nib.tools.process.run_lines` before it spawns. Remove it once
std.ipc's pipe writes cannot raise SIGPIPE (e.g. block SIGPIPE on the writing
thread and consume a pending one with sigtimedwait, or MSG_NOSIGNAL-style
handling for pipes).

**RESOLVED** in Aether 0.914.0 (aether #3694, 2026-11-14); the stand-in is removed from the port.
