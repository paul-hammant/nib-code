# Compiler: two modules with the same basename break each other's qualified types

**From:** the nib Aether port (`aether-port` branch of paul-hammant/nib-code), its Session slice.
**To:** aether, aetherc (0.909.0). For whoever is preparing the compiler-bug PR.
**Workaround meanwhile:** the port names its provider timing module
`nib.provider.model_timing` instead of `nib.provider.timing`, because
`nib.sandbox.timing` already exists.

When a program contains two modules whose last path component is the same
(`a.timing` and `b.timing`), a qualified type `timing.T` fails to resolve in
EVERY file that names one, even a file that imports only one of them.
Qualified calls (`timing.mk()`) resolve; only types (`as *timing.Call`)
break.

Repro (`ae run --lib . three.ae`):

```
a/timing/module.ae:  exports(Call, mk)   struct Call { n: int }   mk() -> ptr { … }
b/timing/module.ae:  exports(Model, mk2) struct Model { m: int }  mk2() -> ptr { … }
c/module.ae:         import a.timing
                     exports(get)
                     get() -> int { c = timing.mk() as *timing.Call
                                    return c.n }
three.ae:            import c
                     import b.timing
                     main() { println("${c.get()}")
                              m = timing.mk2() as *timing.Model
                              println("${m.m}") }
```

Result:

```
error[E0302]: unknown module 'timing' in the type 'timing.Model'   --> three.ae:5:22
error[E0302]: unknown module 'timing' in the type 'timing.Call'    --> ./c/module.ae:4:21
```

Expected: each file's `timing` means the module that file imports; it runs
and prints 1 and 2. With only `a.timing` in the program (`one.ae`) it works.
Probably the type-qualifier lookup is keyed by basename program-wide rather
than per importing file (compare the earlier basename-collision fix for
qualified calls, PR #2268).

**RESOLVED** in Aether 0.914.0 (aether #3694, 2026-11-14); the stand-in is removed from the port.
