# 0018 Codex custom Run reuses execution and history

Codex defaults to direct JavaScript custom-tool input, reducing function JSON-string escaping; Chat Completions keeps function calls. Grammar constrains only the outer form, neither validating JS nor guaranteeing latency or syntax-error rates. Only after complete output_item.done is source normalized to internal `{code}`, reusing Sandbox, Session, recording, and replay without a second executor.

Use one custom tool and explicit `NIB_CODEX_RUN_TOOL=function` fallback, avoiding a model choice between equivalent entry points.

History preserves each call's custom/function type and raw arguments, pairing results by type. Configuration switches neither convert old history nor lose old effort or encrypted reasoning. Tool-definition changes may still lose some cache; resume always uses full history and a new connection. Wire argument timing counts raw JS input / JSON arguments separately; normalized internal JSON lengths cannot be compared directly.

See [Codex custom Run](../codex.md#custom-run-tool) for configuration, protocol, and error diagnostics. Real endpoints and local mocks cover custom round trips and WS increments; fall back to function if compatibility or script errors worsen, retaining saved calls' original types.

Note: this ADR originally kept per-Step effort scheduling, expressed by an optional first line `// @run: {"effort":"low"}`. [ADR 0025](0025-model-profiles.md) removed it; the grammar is now just `SOURCE`, and old `// @run:` lines in history replay verbatim.
