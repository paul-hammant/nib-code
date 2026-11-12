# Parser: a typed local of a qualified struct's slice type does not parse

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its TUI slice.
**To:** aether, aetherc 0.909.0.
**Workaround meanwhile:** `xs = make([]m.P, 0)` (or a module function that
returns an empty slice, `commands.no_choices()` in `ae/nib/tui/commands`).

```
m/module.ae:  exports(P, mk)  struct P { n: int }  mk(n: int) -> P { return P { n: n } }
main.ae:      import m
              main() {
                  m.P[] xs = []
                  xs.push(m.mk(1))
                  println("${xs.len}")
              }
```

`ae run --lib . main.ae`:

```
error[E0100]: Expected statement in block
  --> main.ae:3:9
3 |     m.P[] xs = []
```

Expected: `1`. `P[] xs = []` inside module `m` parses, and so does a
parameter or field typed `m.P[]`; only the statement form with a qualified
element type is refused (the parser seems to read `m.P` as an expression).
