---
status: accepted
date: 2026-11-01
---

# Add grep, glob, and fetch; implement search natively in Zig

Three tools methods: grep (regex file contents), glob (list matching files), fetch (http(s) GET, HTML to Markdown). Structured results allow further JS filtering/grouping before read.

**Why:**
- **grep / glob:** bash returns strings requiring parsing; structured path/line/column/text compose directly within Runs, a distinctive PTC benefit. The user's machine lacked ripgrep; rg was only Claude Code's shell function, unavailable in nib bash. A logged Session had already called rg.
- **fetch:** Development needs documentation, e.g. Zig 0.17 changed many APIs that model memory gets wrong. curl returns token-heavy raw HTML.

**Implementation (references: pi grep.ts/find.ts, oh-my-pi fetch.ts/grep.ts/glob.ts, jcode webfetch.rs; no reused code):**
- **No external programs.** pi invokes rg/fd, downloading if missing; nib downloads no executables and implements everything in Zig:
  - `src/tools/walk.zig`: traversal, .gitignore, glob matching shared by glob, grep's glob filter, and .gitignore.
  - `src/tools/grep.zig`: up to 8 search threads claiming files by index, preserving sequential-scan order/results after truncation.
  - `src/tools/regex.zig`: wraps QuickJS libregexp.
- **Regex is JS RegExp**, matching Run syntax without new dependencies.
  - multiline enables line-based ^/$.
  - ASCII matches bytes; valid non-ASCII UTF-8 converts to UTF-16 first, supporting Chinese patterns.
  - Case-sensitive literal search uses indexOf fast paths.
  - Report first match per line only; line and UTF-8 byte column are 1-based, converting UTF-16 positions to bytes.
  - text excerpts around match start without an excerpt-start column; column always references the original line, not excerpt offset. Mark omitted sides with …; text/context lines cap at 500 bytes including markers, preserving UTF-8 characters. Context still takes line beginnings; short lines remain verbatim.
  - QuickJS interrupt callbacks pass Esc cancellation into libregexp, including catastrophic backtracking.
- **Skip rules:**
  - Skip .git, .gitignore matches, symlinks (no following), binary files (NUL in first 8 KB), files over 16 MB.
  - Read .gitignore up to repository root, honoring root rules from subdirectories.
  - Include hidden files needed for development, e.g. .github/.
- **fetch:**
  - Accept prefers `text/markdown` (from oh-my-pi); documentation sites such as DeepSeek increasingly return Markdown directly.
  - `src/tools/html.zig` converts HTML. Prefer `<main>`, then `<article>`, converting only that region; drop script/style/nav/aside/form and other nonbody elements (list from jcode); resolve relative links absolutely.
  - Download cap 5 MiB, error beyond; JS text cap 1 MiB with separate truncated boolean, no notices inside text. Only Session delivery truncates Run output to roughly 16 KiB head/tail, preserving JS data ([0002](0002-run-code-only.md)).
  - Follow at most 5 redirects; reject binary content.
  - Requests run in `std.Io` concurrent tasks canceled by timeout/Esc, interrupting stuck reads too. Measured: server stalled 3 seconds, timeout_ms: 300, whole Turn ended in 0.78 seconds.

**Security boundaries:**
- grep/glob skip symlinks and default/custom Codex credentials, matching read checks; direct credential grep rejects.
- fetch supports only http/https GET, without cookies/authentication headers.
- fetch **allows** localhost/private addresses (user decision, 2026-11-01): bash curl already accesses them, so blocking adds no security boundary and breaks local servers.
- Pages may contain model instructions (prompt injection), not technically preventable. Descriptions identify results as untrusted external reference data, never instructions. Models may also exfiltrate data in URLs, outside guarantees. Credential boundaries ([0006](0006-deny-dangerous-commands.md)) at least prevent credential-file reads.

**Confidence:**
- Measured:
  - Full grep of local `~/myself` (several large repositories): about 100 ms; nibcode src search: about 1 ms.
  - Real example.com, ziglang.org/download, DeepSeek fetches: HTTPS/redirects work; DeepSeek tables convert correctly.
  - Unit tests cover glob, .gitignore, credential skipping, UTF-8, context, truncation, HTML; `tests/test_session.py` mocks cover redirects, Accept, HTML conversion, timeout interruption.
- Known limits:
  - Only per-directory .gitignore; no `.git/info/exclude`, global excludes, .ignore.
  - Traverse the entire tree before searching, even for small limits.
  - Multiline matches report starting line only.
  - Lightweight HTML conversion runs no JS, so client-rendered bodies are unavailable.
  - No web search.

**When to reconsider:**
- Large-directory search slows materially: search during traversal or parallelize traversal.
- Frequent client-rendered sites: consider llms.txt discovery or reader services (oh-my-pi supports jina, etc.).
- Search engines needed: separate search tool with external API.
