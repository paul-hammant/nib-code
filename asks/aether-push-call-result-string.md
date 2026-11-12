# Compiler: `xs.push(f())` loses the string fields of a struct returned by `f`

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its TUI slice.
**To:** aether, aetherc 0.909.0.
**Workaround meanwhile:** bind the call's result to a local, then push the local
(marked `// workaround: aether-push-call-result-string` in `ae/nib/tui/agent_tree`).

```
struct R { text: string  k: int }
mk(t: string) -> R { return R { text: "x ${t}", k: 3 } }
main() {
    next = make([]R, 0)
    next.push(mk("hi"))
    println("[${next[0].text}]")
}
```

Prints `[]`. Expected `[x hi]`. `next.push(R { text: "x hi", k: 3 })` and
`r = mk("hi")` then `next.push(r)` both print `[x hi]`. Probably the
temporary returned by the call is destroyed at the end of the statement
after the push copied its fields without retaining the string (the same
family as asks/../ae/term/asks/loop-store-moves-local.md).
