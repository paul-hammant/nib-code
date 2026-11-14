# Type checker: a `ptr` is accepted where a `string` parameter is declared

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its TUI slice.
**To:** aether, aetherc 0.909.0.

The TUI passed a parsed JSON node (`ptr`) to `jsonx.long_of(text: string)`
by mistake; it compiled, ran, and read garbage (an interjection id never
matched). The checker should have refused the argument.

```
import std.json
takes(text: string) -> int { return 7 }
main() {
    v, _e = json.parse("{\"a\":1}")
    println("${takes(v)}")
}
```

`ae run hole.ae` prints `7`. Expected: E0200, *Argument 1 'text' of 'takes':
expected string, got ptr*. (`string` to `ptr` at an extern is the documented
decay; the other direction into an Aether `string` parameter has no
conversion behind it: the callee treats the node as an AetherString.)

**RESOLVED** in Aether 0.914.0 (aether #3694, 2026-11-14); the stand-in is removed from the port.
