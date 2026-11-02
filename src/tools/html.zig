const std = @import("std");

/// Readable Markdown from HTML: keeps headings, paragraphs, links, lists, code and tables;
/// drops scripts, styles, navigation, forms and embedded media. When the page has `<main>`
/// (or else `<article>`), only that part is converted. Relative links resolve against `base`.
pub fn toMarkdown(a: std.mem.Allocator, html: []const u8, base: []const u8) ![]u8 {
    var c: Converter = .{ .a = a, .base = base };
    try c.run(mainContent(html));
    const body = try c.finish();
    if (std.mem.startsWith(u8, body, "# ") or std.mem.indexOf(u8, body, "\n# ") != null) return body;
    const t = title(html) orelse return body;
    var heading_line: std.ArrayList(u8) = .empty;
    try heading_line.appendSlice(a, "# ");
    try decode(a, &heading_line, t);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ heading_line.items, if (body.len > 0) "\n\n" else "", body });
}

fn title(html: []const u8) ?[]const u8 {
    const open = findTag(html, 0, "title", false) orelse return null;
    const start = (std.mem.indexOfScalarPos(u8, html, open, '>') orelse return null) + 1;
    const end = findTag(html, start, "title", true) orelse return null;
    const t = std.mem.trim(u8, html[start..end], " \t\r\n");
    return if (t.len == 0) null else t;
}

const dropped = [_][]const u8{ "script", "style", "noscript", "template", "svg", "canvas", "iframe", "object", "head", "title", "nav", "aside", "form", "select", "dialog", "button" };
const max_href = 300;

fn mainContent(html: []const u8) []const u8 {
    for ([_][]const u8{ "main", "article" }) |tag| {
        const open = findTag(html, 0, tag, false) orelse continue;
        const start = std.mem.indexOfScalarPos(u8, html, open, '>') orelse continue;
        var end: ?usize = null;
        var pos = start;
        while (findTag(html, pos, tag, true)) |close| : (pos = close + 1) end = close;
        return html[start + 1 .. end orelse html.len];
    }
    return html;
}

/// Index of `<tag` or `</tag` followed by a delimiter, case-insensitive.
fn findTag(html: []const u8, from: usize, tag: []const u8, closing: bool) ?usize {
    var pos = from;
    while (std.mem.indexOfScalarPos(u8, html, pos, '<')) |lt| : (pos = lt + 1) {
        var i = lt + 1;
        if (closing) {
            if (i >= html.len or html[i] != '/') continue;
            i += 1;
        }
        if (i + tag.len > html.len or !std.ascii.eqlIgnoreCase(html[i .. i + tag.len], tag)) continue;
        if (i + tag.len == html.len) return lt;
        const after = html[i + tag.len];
        if (after == '>' or after == '/' or std.ascii.isWhitespace(after)) return lt;
    }
    return null;
}

const List = struct { ordered: bool, n: usize = 0 };

const Converter = struct {
    a: std.mem.Allocator,
    base: []const u8,
    out: std.ArrayList(u8) = .empty,
    space: bool = false,
    pre: usize = 0,
    lists: std.ArrayList(List) = .empty,
    quote: usize = 0,
    link: ?struct { href: []const u8, start: usize } = null,
    row_cells: usize = 0,
    rows: usize = 0,
    /// Output positions of open emphasis marks.
    marks: std.ArrayList(usize) = .empty,

    fn run(c: *Converter, html: []const u8) !void {
        var i: usize = 0;
        while (i < html.len) {
            const lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            try c.text(html[i..lt]);
            if (lt == html.len) break;
            i = try c.tag(html, lt);
        }
    }

    /// Handles the markup at `html[lt]` and returns the index after it.
    fn tag(c: *Converter, html: []const u8, lt: usize) !usize {
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, lt + 4, "-->") orelse return html.len;
            return end + 3;
        }
        var i = lt + 1;
        const closing = i < html.len and html[i] == '/';
        if (closing) i += 1;
        const name_start = i;
        while (i < html.len and (std.ascii.isAlphanumeric(html[i]) or html[i] == '-')) i += 1;
        if (i == name_start) {
            if (i < html.len and (html[i] == '!' or html[i] == '?')) return (std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len - 1) + 1;
            try c.text("<");
            return lt + 1;
        }
        var lower: [16]u8 = undefined;
        const raw_name = html[name_start..i];
        const name = if (raw_name.len <= lower.len) std.ascii.lowerString(&lower, raw_name) else raw_name;
        const attrs_start = i;
        var quote: u8 = 0;
        while (i < html.len) : (i += 1) {
            if (quote != 0) {
                if (html[i] == quote) quote = 0;
            } else if (html[i] == '"' or html[i] == '\'') quote = html[i] else if (html[i] == '>') break;
        }
        const attrs = html[attrs_start..@min(i, html.len)];
        const next = @min(i + 1, html.len);

        if (!closing) for (dropped) |d| if (std.mem.eql(u8, name, d)) {
            if (attrs.len > 0 and attrs[attrs.len - 1] == '/') return next;
            const end = findTag(html, next, d, true) orelse return html.len;
            return (std.mem.indexOfScalarPos(u8, html, end, '>') orelse html.len - 1) + 1;
        };
        if (closing) {
            try c.closeTag(name);
        } else if (eql(name, "pre")) {
            try c.openPre(if (language(attrs).len > 0) attrs else innerCodeAttrs(html[next..]));
        } else try c.openTag(name, attrs);
        return next;
    }

    fn openTag(c: *Converter, name: []const u8, attrs: []const u8) !void {
        if (heading(name)) |level| {
            try c.block(2);
            for (0..level) |_| try c.out.append(c.a, '#');
            try c.out.append(c.a, ' ');
        } else if (eql(name, "p") or eql(name, "div") or eql(name, "section") or eql(name, "header") or eql(name, "footer") or eql(name, "figure") or eql(name, "dl") or eql(name, "table")) {
            try c.block(if (c.lists.items.len > 0) 1 else 2);
            if (eql(name, "table")) c.rows = 0;
        } else if (eql(name, "br")) {
            try c.newline();
        } else if (eql(name, "hr")) {
            try c.block(2);
            try c.out.appendSlice(c.a, "---");
            try c.block(2);
        } else if (eql(name, "ul") or eql(name, "ol")) {
            try c.block(if (c.lists.items.len > 0) 1 else 2);
            try c.lists.append(c.a, .{ .ordered = eql(name, "ol") });
        } else if (eql(name, "li")) {
            try c.block(1);
            const depth = c.lists.items.len;
            for (1..@max(depth, 1)) |_| try c.out.appendSlice(c.a, "  ");
            if (depth > 0 and c.lists.items[depth - 1].ordered) {
                const list = &c.lists.items[depth - 1];
                list.n += 1;
                try c.out.print(c.a, "{d}. ", .{list.n});
            } else try c.out.appendSlice(c.a, "- ");
        } else if (eql(name, "dt")) {
            try c.block(1);
        } else if (eql(name, "dd")) {
            try c.block(1);
            try c.out.appendSlice(c.a, ": ");
        } else if (eql(name, "blockquote")) {
            try c.block(2);
            c.quote += 1;
            try c.out.appendSlice(c.a, "> ");
        } else if (eql(name, "code")) {
            if (c.pre == 0) try c.inlineMark("`");
        } else if (eql(name, "strong") or eql(name, "b")) {
            try c.inlineMark("**");
        } else if (eql(name, "em") or eql(name, "i")) {
            try c.inlineMark("_");
        } else if (eql(name, "a")) {
            const href = attr(attrs, "href") orelse return;
            if (href.len == 0 or href.len > max_href or href[0] == '#' or std.mem.startsWith(u8, href, "javascript:")) return;
            try c.separate();
            c.link = .{ .href = href, .start = c.out.items.len };
            try c.out.append(c.a, '[');
        } else if (eql(name, "img")) {
            const alt = attr(attrs, "alt") orelse return;
            if (alt.len == 0) return;
            try c.separate();
            try c.out.appendSlice(c.a, "[image: ");
            try decode(c.a, &c.out, alt);
            try c.out.append(c.a, ']');
        } else if (eql(name, "tr")) {
            try c.block(1);
            c.row_cells = 0;
            try c.out.append(c.a, '|');
        } else if (eql(name, "td") or eql(name, "th")) {
            c.row_cells += 1;
            c.space = false;
            try c.out.append(c.a, ' ');
        }
    }

    fn openPre(c: *Converter, attrs: []const u8) !void {
        try c.block(2);
        try c.out.print(c.a, "```{s}\n", .{language(attrs)});
        c.pre += 1;
    }

    fn closeTag(c: *Converter, name: []const u8) !void {
        if (heading(name) != null or eql(name, "p") or eql(name, "table") or eql(name, "dl")) {
            try c.block(if (c.lists.items.len > 0) 1 else 2);
        } else if (eql(name, "div") or eql(name, "section") or eql(name, "li") or eql(name, "dd") or eql(name, "figure")) {
            try c.block(1);
        } else if (eql(name, "ul") or eql(name, "ol")) {
            if (c.lists.items.len > 0) _ = c.lists.pop();
            try c.block(if (c.lists.items.len > 0) 1 else 2);
        } else if (eql(name, "blockquote")) {
            c.quote -|= 1;
            try c.block(2);
        } else if (eql(name, "pre")) {
            if (c.pre == 0) return;
            c.pre -= 1;
            if (c.out.items.len > 0 and c.out.items[c.out.items.len - 1] != '\n') try c.out.append(c.a, '\n');
            try c.out.appendSlice(c.a, "```");
            try c.block(2);
        } else if (eql(name, "code")) {
            if (c.pre == 0) try c.out.append(c.a, '`');
        } else if (eql(name, "strong") or eql(name, "b")) {
            try c.closeMark("**");
        } else if (eql(name, "em") or eql(name, "i")) {
            try c.closeMark("_");
        } else if (eql(name, "a")) {
            const link = c.link orelse return;
            c.link = null;
            if (std.mem.trim(u8, c.out.items[link.start + 1 ..], " \n").len == 0) {
                c.out.shrinkRetainingCapacity(link.start);
                return;
            }
            try c.out.appendSlice(c.a, "](");
            try c.resolve(link.href);
            try c.out.append(c.a, ')');
        } else if (eql(name, "td") or eql(name, "th")) {
            try c.out.appendSlice(c.a, " |");
        } else if (eql(name, "tr")) {
            c.rows += 1;
            if (c.rows == 1 and c.row_cells > 0) {
                try c.out.appendSlice(c.a, "\n|");
                for (0..c.row_cells) |_| try c.out.appendSlice(c.a, " --- |");
            }
        }
    }

    fn text(c: *Converter, raw: []const u8) !void {
        if (raw.len == 0) return;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(c.a);
        try decode(c.a, &decoded, raw);
        if (c.pre > 0) return c.out.appendSlice(c.a, decoded.items);
        for (decoded.items) |ch| {
            if (std.ascii.isWhitespace(ch)) {
                c.space = true;
                continue;
            }
            if (c.space) try c.separate();
            try c.out.append(c.a, ch);
        }
    }

    fn separate(c: *Converter) !void {
        if (c.space and c.out.items.len > 0) switch (c.out.items[c.out.items.len - 1]) {
            ' ', '\n', '[', '(' => {},
            else => try c.out.append(c.a, ' '),
        };
        c.space = false;
    }

    fn inlineMark(c: *Converter, mark: []const u8) !void {
        try c.separate();
        try c.marks.append(c.a, c.out.items.len);
        try c.out.appendSlice(c.a, mark);
    }

    /// Markdown emphasis cannot span blocks or be empty: then the opening mark is removed.
    fn closeMark(c: *Converter, mark: []const u8) !void {
        const start = c.marks.pop() orelse return;
        if (start + mark.len > c.out.items.len) return;
        const inner = c.out.items[start + mark.len ..];
        if (std.mem.trim(u8, inner, " ").len == 0 or std.mem.indexOfScalar(u8, inner, '\n') != null) {
            c.out.replaceRangeAssumeCapacity(start, mark.len, "");
            return;
        }
        try c.out.appendSlice(c.a, mark);
    }

    fn newline(c: *Converter) !void {
        while (c.out.items.len > 0 and c.out.items[c.out.items.len - 1] == ' ') _ = c.out.pop();
        try c.out.append(c.a, '\n');
        c.space = false;
        if (c.quote > 0) try c.out.appendSlice(c.a, "> ");
    }

    /// Ends the current line and leaves `n` - 1 blank lines, without stacking.
    fn block(c: *Converter, n: usize) !void {
        c.space = false;
        if (c.pre > 0) return;
        while (c.out.items.len > 0 and (c.out.items[c.out.items.len - 1] == ' ' or c.out.items[c.out.items.len - 1] == '>')) _ = c.out.pop();
        if (c.out.items.len == 0) return;
        var have: usize = 0;
        while (have < c.out.items.len and c.out.items[c.out.items.len - 1 - have] == '\n') have += 1;
        while (have < n) : (have += 1) try c.out.append(c.a, '\n');
        if (c.quote > 0) try c.out.appendSlice(c.a, "> ");
    }

    fn resolve(c: *Converter, href: []const u8) !void {
        if (std.mem.indexOf(u8, href, "://") != null or std.mem.startsWith(u8, href, "mailto:")) return decode(c.a, &c.out, href);
        const scheme_end = (std.mem.indexOf(u8, c.base, "://") orelse return decode(c.a, &c.out, href)) + 3;
        const origin_end = std.mem.indexOfScalarPos(u8, c.base, scheme_end, '/') orelse c.base.len;
        if (std.mem.startsWith(u8, href, "//")) {
            try c.out.appendSlice(c.a, c.base[0 .. scheme_end - 2]);
        } else if (href[0] == '/') {
            try c.out.appendSlice(c.a, c.base[0..origin_end]);
        } else {
            const path_end = std.mem.indexOfAny(u8, c.base[origin_end..], "?#") orelse c.base.len - origin_end;
            const dir_end = if (std.mem.lastIndexOfScalar(u8, c.base[origin_end .. origin_end + path_end], '/')) |slash| origin_end + slash + 1 else origin_end;
            try c.out.appendSlice(c.a, c.base[0..dir_end]);
            if (dir_end == origin_end) try c.out.append(c.a, '/');
        }
        try decode(c.a, &c.out, href);
    }

    fn finish(c: *Converter) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var blank: usize = 0;
        var lines = std.mem.splitScalar(u8, c.out.items, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, " \t");
            if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ">")) {
                blank += 1;
                continue;
            }
            if (out.items.len > 0) try out.appendSlice(c.a, if (blank > 0) "\n\n" else "\n");
            blank = 0;
            try out.appendSlice(c.a, trimmed);
        }
        return out.items;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn heading(name: []const u8) ?usize {
    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') return name[1] - '0';
    return null;
}

/// Value of attribute `name` (lowercase) in a tag's attribute text, still entity-encoded.
fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and (std.ascii.isWhitespace(attrs[i]) or attrs[i] == '/')) i += 1;
        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '/') i += 1;
        const key = attrs[key_start..i];
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i >= attrs.len or attrs[i] != '=') {
            if (i == key_start) i += 1;
            continue;
        }
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        var value: []const u8 = "";
        if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
            const q = attrs[i];
            const end = std.mem.indexOfScalarPos(u8, attrs, i + 1, q) orelse attrs.len;
            value = attrs[i + 1 .. end];
            i = end + 1;
        } else {
            const start = i;
            while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) i += 1;
            value = attrs[start..i];
        }
        if (std.ascii.eqlIgnoreCase(key, name)) return std.mem.trim(u8, value, " \t\n");
    }
    return null;
}

/// Attributes of a `<code>` that directly follows, where highlighters put the language.
fn innerCodeAttrs(rest: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, rest, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "<code")) return "";
    const end = std.mem.indexOfScalar(u8, trimmed, '>') orelse return "";
    return trimmed[5..end];
}

fn language(attrs: []const u8) []const u8 {
    const class = attr(attrs, "class") orelse return "";
    var words = std.mem.tokenizeAny(u8, class, " \t");
    while (words.next()) |w| {
        for ([_][]const u8{ "language-", "lang-" }) |prefix|
            if (std.mem.startsWith(u8, w, prefix)) return w[prefix.len..];
    }
    return "";
}

const entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "amp", "&" },     .{ "lt", "<" },      .{ "gt", ">" },      .{ "quot", "\"" },
    .{ "apos", "'" },    .{ "nbsp", " " },    .{ "mdash", "—" },   .{ "ndash", "–" },
    .{ "hellip", "…" },  .{ "copy", "©" },    .{ "reg", "®" },     .{ "trade", "™" },
    .{ "lsquo", "‘" },   .{ "rsquo", "’" },   .{ "ldquo", "“" },   .{ "rdquo", "”" },
    .{ "times", "×" },   .{ "middot", "·" },  .{ "bull", "•" },    .{ "rarr", "→" },
    .{ "larr", "←" },    .{ "laquo", "«" },   .{ "raquo", "»" },   .{ "zwj", "" },
    .{ "zwnj", "" },
});

fn decode(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const amp = std.mem.indexOfScalarPos(u8, s, i, '&') orelse s.len;
        try out.appendSlice(a, s[i..amp]);
        if (amp == s.len) return;
        const semi = std.mem.indexOfScalarPos(u8, s, amp, ';');
        if (semi) |end| if (end - amp <= 10) {
            const name = s[amp + 1 .. end];
            if (name.len > 1 and name[0] == '#') {
                const cp = if (name[1] == 'x' or name[1] == 'X')
                    std.fmt.parseInt(u21, name[2..], 16) catch null
                else
                    std.fmt.parseInt(u21, name[1..], 10) catch null;
                if (cp) |code| {
                    var buf: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(code, &buf)) |n| {
                        try out.appendSlice(a, buf[0..n]);
                        i = end + 1;
                        continue;
                    } else |_| {}
                }
            } else if (entities.get(name)) |value| {
                try out.appendSlice(a, value);
                i = end + 1;
                continue;
            }
        };
        try out.append(a, '&');
        i = amp + 1;
    }
}

const testing = std.testing;

fn expectMarkdown(expected: []const u8, html: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try toMarkdown(arena.allocator(), html, "https://ziglang.org/documentation/master/index.html"));
}

test "keeps structure and drops page chrome" {
    try expectMarkdown(
        \\# Title
        \\
        \\Some **bold** and _em_ text with `code`.
        \\
        \\- one
        \\- two [link](https://ziglang.org/learn/)
        \\  1. nested
        \\
        \\```zig
        \\const x = 1;
        \\if (a < b) {}
        \\```
        \\
        \\| A | B |
        \\| --- | --- |
        \\| 1 | 2 |
    ,
        \\<html><head><title>T</title><style>body{}</style></head><body>
        \\<nav><a href="/">Home</a></nav>
        \\<h1>Title</h1>
        \\<p>Some <b>bold</b> and <em>em</em>
        \\   text with <code>code</code>.</p>
        \\<script>if (a < b) alert("x")</script>
        \\<ul><li>one</li><li>two <a href="/learn/">link</a><ol><li>nested</li></ol></li></ul>
        \\<pre><code class="language-zig">const x = 1;
        \\if (a &lt; b) {}
        \\</code></pre>
        \\<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
        \\<form><input name="q"><button>Go</button></form>
        \\</body></html>
    );
}

test "prefers main content and resolves links and entities" {
    try expectMarkdown(
        \\Fish &amp; chips — [rel](https://ziglang.org/documentation/master/std.html) [abs](https://x.dev/a) [proto](https://cdn.dev/x) 中文 é
    ,
        \\<header>Site</header><main><p>Fish &amp;amp; chips &mdash;
        \\<a href="std.html">rel</a> <a href="https://x.dev/a">abs</a> <a href="//cdn.dev/x">proto</a>
        \\<a href="#top"></a> 中文 &#233;</p></main><footer>F</footer>
    );
    try expectMarkdown("# Page\n\na < b, [image: chart]", "<title>Page</title><p>a < b, <img src=x.png alt=\"chart\"></p><!-- note -->");
    try expectMarkdown("x\n\n| a |\n| --- |\n\ny", "<p>x<b><table><tr><td>a</td></tr></table></b>y<i> </i></p>");
}
