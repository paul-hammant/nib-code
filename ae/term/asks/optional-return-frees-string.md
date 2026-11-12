# Returning a local `T?` whose `T` owns a string returns freed memory

**For:** aether (compiler, ownership of optionals). **From:** nib-code's
`ae/term`, 2026-11-12, Aether 0.909.0 on macOS arm64.

## Repro

```aether
import std.string
struct Key { cp: int  text: string }
opt(s: string) -> Key? {
    k = Key { cp: 1, text: string.substring(s, 1, 2) }
    return k
}
main() {
    x = opt("xyz")
    y = string.substring("qqqqqqqqqqqqqqqqqqq", 0, 5)
    match x {
        none -> println("none")
        some(v) -> println("text=${v.text}   (expected y)")
    }
}
```

prints `text=qqqqq   (expected y)`: the string `x` holds was freed when
`opt` returned and `y` got the allocation.

The same happens for every shape that returns an optional a local holds:

- `let e: Key? = Key { ... }` then `return e`
- `e = mk()` (a `-> Key?` call) then `if e == none { return none }; return e`
- `match e { none -> ... some(v) -> { return v } }` (a `some` binding
  re-wrapped at the return)
- the same with a sum type (`Event?` where a variant owns a string), which
  is where `ae/term` met it: a decoder's `next() -> Event?`

Returning the struct literal directly (`return Key { ... }`) and returning a
plain `Key` local (`-> Key`) are fine; so is a sum `-> Event` from a local.

## Cause, as far as the generated C shows

For `return e` with `e: ae_opt_Key` the codegen copies `e` into
`_builder_ret` by value and then runs the scope's deferred
`_ae_drop_ae_opt_Key(&e)`, which releases `e.val.text`. The returned copy
shares that string. A plain struct local is moved on return (no drop); an
optional local is not.

## What `ae/term` does meanwhile

No optional of an owning type crosses a return: the decoder and `poll`
return `Event` with a `NoEvent` variant, and `read_cell` returns
`(Cell, bool)` instead of libvaxis's `?Cell`. Both comments point here; when
this is fixed they can go back to `Event?` and `Cell?`.

## Ask

Move an optional local on `return` exactly as a struct local is moved
(including when the return is inside a `match` arm or a loop), and add the
repro above to `tests/regression/`.
