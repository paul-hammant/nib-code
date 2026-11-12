# contrib.quickjs: async global eval, a host-controlled interrupt, promise state

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its Sandbox slice.
**To:** aether, `contrib/quickjs` (0.909.0).
**Stand-in meanwhile:** `ae/nib/qjsgap/` (marked; mirrors `AeQjs`, delete when this lands).

nib runs each model-written script ("Run") in a fresh QuickJS runtime. Three
things it needs are in quickjs-ng but not exposed by `contrib.quickjs`:

## 1. Global eval with `JS_EVAL_FLAG_ASYNC`

A Run is a *script* with top-level `await` whose **completion value** is the
result (`const x = await tools.read(...); x.text.length` → `1234`).
`quickjs.eval` is sync global eval (top-level `await` is a SyntaxError);
`quickjs.eval_module` allows `await` but a module has no completion value.
Only `JS_Eval(ctx, src, len, name, JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC)`
does both: it returns a promise resolving to `{ value: <completion> }`.

Repro (0.909.0):

```aether
import contrib.quickjs
main() {
    q = quickjs.runtime(8192, 0)
    v, err = quickjs.eval(q, "const x = await Promise.resolve(2); x * 21", "<run>")
    println(err)   // SyntaxError: await is only valid in async functions ...
    m, err2 = quickjs.eval_module(q, "const x = await Promise.resolve(2); x * 21", "<run>")
    // m settles to undefined: the 42 is unreachable
}
```

Proposed: `quickjs.eval_async(q, code, filename) -> (int, string)`, the
promise handle (flag bit 4 in `qjs_eval`, say).

## 2. An interrupt the host controls

`set_time_limit(q, ms)` restarts its deadline at every entry. nib's budget is
cumulative: 5 minutes of *JS time* across the initial eval, every job run,
every result conversion, pausing while tools run on other threads; and a
cancel flag (Esc, SIGINT) must stop a busy loop at once. Two small additions
would cover it:

- `quickjs.set_cancel_cell(q, cell)`: a `std.sync` cell; nonzero interrupts.
- `quickjs.set_deadline_ns(q, monotonic_ns)` / `clear_deadline(q)`: an
  absolute deadline the host moves itself (0 = none), not reset per entry;
  plus `quickjs.interrupted(q) -> int` saying which fired (1 deadline, 2 cancel).

Note `qjs_to_string` does not call `enter_`, so today a stale per-entry
deadline can interrupt a later `to_string` immediately, and a `toString`
that loops forever is unbounded when the limit is 0.

- A second cell, `quickjs.set_stop_cell(q, cell)` (or a list of cells):
  nib's offline replay (`nib replay`) must stop a script the moment it
  diverges from its recording, the way upstream's interrupt handler returns
  `isInterrupted(st) or virtualStopped(st)`, without the Run reading as
  canceled (its text is whatever the script threw). The stand-in has it as
  `nibqjs_set_stop` (reason 3). Repro of the need, 0.912.0: a replayed
  script that catches the divergence and spins (`try { await tools.read({x:2}) }
  catch {} for(;;){}` against a recording of `read({x:1})`) can only be
  stopped by the 5-minute budget or by the cancel cell, which rewrites its
  outcome to "Error: run canceled".

## 3. Promise state and result

`quickjs.promise_state(q, h) -> int` (-1 not a promise, 0 pending,
1 fulfilled, 2 rejected) and `quickjs.promise_result(q, h) -> int` (a handle).
nib checks whether the Run's top-level promise rejected (pending timers are
then dropped while tool calls still drain) and reads the settled value.

## Also noticed

- quickjs-ng is pinned at 0.17.0; upstream nib pins 0.18. No behaviour nib's
  tests see differs, but a bump would keep the two engines the same.
- `qjs_to_string` returns "" both for an empty string and for a failed
  conversion; a `(string, err)` form would let a host tell them apart.
