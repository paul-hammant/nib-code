# 0024: Opt-in MCP tools

Status: accepted

MCP servers provide tools that command-line programs cannot always expose directly.
Keep them opt-in, per server, using the existing skills switch semantics and atomic
config persistence. There is no plugin API. Resources, prompts, sampling, roots,
elicitation, OAuth discovery, and deprecated HTTP+SSE transport are outside v1.

New Sessions discover enabled tools through short-lived connections and append only
a bounded signature/description index. Full schemas are fetched through
`tools.mcp_schema`; `tools.mcp` returns complete data, attaches images through the
existing image store, and records calls using the normal Run/replay machinery.
Configuration snapshots preserve switches and endpoints across resume and child
Sessions without copying credential values into logs.

Support current stable MCP 2026-07-28 and the initialization-based era through
2025-11-25. Probe each server with `server/discover`. Modern requests carry version,
identity and empty capabilities in params `_meta`; HTTP mirrors required metadata
and validated parameter annotations in headers. A stdio non-modern error or probe
timeout falls back to initialization; HTTP falls back on non-modern 4xx responses.
Recognized modern protocol errors never select legacy semantics. Legacy servers
negotiate down through supported versions and retain `Mcp-Session-Id` on HTTP.
See [protocol detection](../mcp.md#protocol-detection-and-lifecycle) for exact rules.

A Session owns its client and serializes calls, avoiding a second multiplexing
scheduler. Persistent stdio processes start on first Run use and are cleaned up with
their process groups on Session exit or transport failure. Discovery connections
close after index construction. Every use re-lists tools, including pagination;
this also handles list-change notifications without another background reader or
HTTP subscription service. The cost is a list round trip before each call.

Stdio cwd is the server's state directory under NIB_HOME; HOME remains unchanged.
Reuse bash's OS write sandbox and roots, adding only that directory. Filter the
environment to basic process variables and explicitly named server credentials.
Reuse existing SSE parsing, cancellation, image limits, and Run display budgeting.
Timeouts and oversized wire messages fail explicitly; tool data is never silently
truncated inside JS. [MCP reference](../mcp.md) defines configuration and limits.
