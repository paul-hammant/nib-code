# MCP tools

MCP servers extend nib with tools. Servers are off by default. Configure them in
`$NIB_HOME/config.toml`, then enable them with `/mcp on <id>` (or `[mcp]` switches).
`/mcp` lists configured servers, switches, and the last known tool count or failure.
`/mcp off <id>` disables a server for new Sessions. Changes are saved atomically,
preserving comments and other settings.

```toml
[mcp]
github = true
docs = false

[mcp.github]
command = "github-mcp-server"
args = ["stdio"]
env = ["GITHUB_TOKEN"]

[mcp.docs]
url = "https://example.com/mcp"
header_env = "DOCS_MCP_TOKEN"
```

Each server requires exactly one of `command` and `url`. IDs follow custom-provider
rules: letters, digits, `_`, `-`; built-in service IDs are reserved. `args` and `env`
are single-line string arrays for stdio only. `header_env` is HTTP only: its value
names an environment variable whose value becomes `Authorization: Bearer …`.
Configuration and Session snapshots contain names, never environment values.
URLs must be HTTP(S) without embedded credentials. Redirects are not followed.
Missing authentication variables fail the server without exposing their values.

## Context and switches

Only enabled servers are discovered. New Sessions append a compact index:

```text
github.search_issues(query: string, state?: "open"|"closed") — Search issues.
```

The index includes at most 40 tools per server, reports the omitted count, collapses
nested objects to `{…}`, and limits signatures and first-sentence descriptions.
Full schemas stay outside the prompt. No MCP index is added when all servers are
off. Server errors appear as short failure lines; other servers remain usable.

Switches apply to new Sessions. Current and resumed Sessions retain their original
system prompt and MCP configuration snapshot; `/new` loads current configuration.
Old logs without an MCP snapshot enable no servers. Subagents inherit the parent
configuration and own independent connections. Credentials are read from the
process environment, not stored in Session logs by nib; server tool content itself
is recorded like all other tool output.

## Run API

```js
const schema = await tools.mcp_schema("github.search_issues");
const result = await tools.mcp("github.search_issues", {query: "is:open"});
console.log(result);
```

`mcp_schema` returns the full input JSON Schema. `mcp` returns
`{ok, content, structured?, error?}`. Text content items are joined with newlines;
`structured` carries `structuredContent`. Image items use the normal Session image
store and the four-images-per-Run limit; models without vision receive
`[image omitted]`. Other content types receive short summaries.
`isError`, JSON-RPC errors, unavailable servers, and transport failures return
`ok:false`; malformed tool arguments reject. Unsupported requests for sampling,
roots, or elicitation are refused; there are no resources or prompts in v1.

Tool results remain complete inside JS and use the normal Run display budget.
Each wire message has a hard 16 MiB limit; exceeding it fails instead of silently
truncating data. Each request has a 60-second deadline, including HTTP reads and
stdio writes; stdio discovery uses a two-second probe before legacy fallback.
Cancellation interrupts I/O and closes failed connections. Calls are serialized
within a Session. TUI Run details show each MCP call with its target, elapsed time,
and failure state. Calls/results use the normal recording and offline replay path.

## Protocol detection and lifecycle

The preferred protocol is [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28).
Each server is probed with `server/discover`, carrying the modern per-request
version, client identity, and empty client capabilities. HTTP also sends
`MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name` where required; valid
`x-mcp-header` schema annotations are mirrored into encoded `Mcp-Param-*` headers.
Invalid annotated HTTP tools are excluded. Modern results requesting unsupported
client interaction fail as data.

For stdio, a non-modern RPC error or a silent probe triggers legacy initialization;
a silent probe starts a fresh process before the handshake. For HTTP, a 4xx response
without a recognized modern protocol error triggers the legacy handshake. Modern
version errors do not trigger legacy fallback. The client supports modern
`2026-07-28`; a modern server advertising no supported modern version fails clearly.
Legacy initialization offers `2025-11-25`, accepts `2025-11-25`, `2025-06-18`,
`2025-03-26`, or `2024-11-05`, then sends `notifications/initialized`. Streamable
HTTP preserves `Mcp-Session-Id`. Deprecated HTTP+SSE endpoints are not supported.
Detection is cached for each live connection and repeated after reconnection.

The prompt index requires discovery before the model's first request. Discovery
uses short-lived connections. Persistent stdio processes start lazily on the first
Run call, are shared across Runs, and stop on Session exit. The server's state
folder survives. Catalogs are paginated and refreshed before each schema lookup or
call, so `notifications/tools/list_changed` and HTTP catalog changes take effect on
the next use. There is no background notification stream or polling loop.

## Stdio environment and sandbox

Stdio servers use `$NIB_HOME/mcp/<id>/` as cwd, with HOME unchanged. Use an absolute
command path or a command available on PATH; file arguments are relative to the
state directory. This gives servers a writable state directory without changing
their home-directory lookup behavior.

Only PATH, HOME, LANG, LC_ALL, LC_CTYPE, TMPDIR, TZ, SYSTEMROOT and explicitly named
`env` variables are passed through. Credential stripping applies before explicit
allowlisted variables are added, so a deliberately named `GITHUB_TOKEN` reaches
that server. Unlisted environment values and nib's provider credentials do not.
Servers use the bash OS write sandbox with the normal project/temp/cache/extra
writable roots plus their state directory. If the configured sandbox is unavailable,
stdio startup fails; `[sandbox] mode = "off"` explicitly disables the write sandbox
for both bash and MCP. Network and filesystem reads retain bash's existing policy.
