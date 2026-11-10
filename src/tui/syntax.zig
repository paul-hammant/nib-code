const std = @import("std");
const vaxis = @import("vaxis");

pub const Lang = enum { zig, js, python, shell, rust, go, c, cpp };

/// Lexer state carried from one code line to the next.
pub const State = enum(u3) { none, block_comment, triple_dq, triple_sq, backtick };

pub const Class = enum { plain, comment, string, keyword };

pub const Token = struct { start: usize, end: usize, class: Class };

const aliases = [_]struct { name: []const u8, lang: Lang }{
    .{ .name = "zig", .lang = .zig },
    .{ .name = "js", .lang = .js },
    .{ .name = "javascript", .lang = .js },
    .{ .name = "ts", .lang = .js },
    .{ .name = "typescript", .lang = .js },
    .{ .name = "jsx", .lang = .js },
    .{ .name = "tsx", .lang = .js },
    .{ .name = "python", .lang = .python },
    .{ .name = "py", .lang = .python },
    .{ .name = "sh", .lang = .shell },
    .{ .name = "bash", .lang = .shell },
    .{ .name = "shell", .lang = .shell },
    .{ .name = "zsh", .lang = .shell },
    .{ .name = "console", .lang = .shell },
    .{ .name = "rust", .lang = .rust },
    .{ .name = "rs", .lang = .rust },
    .{ .name = "go", .lang = .go },
    .{ .name = "c", .lang = .c },
    .{ .name = "h", .lang = .c },
    .{ .name = "cpp", .lang = .cpp },
    .{ .name = "c++", .lang = .cpp },
};

/// `info` is the text after the opening fence; only its first word counts.
pub fn langFromInfo(info: []const u8) ?Lang {
    const trimmed = std.mem.trim(u8, info, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t{") orelse trimmed.len;
    const word = trimmed[0..end];
    for (aliases) |a| if (std.ascii.eqlIgnoreCase(a.name, word)) return a.lang;
    return null;
}

const zig_keywords = [_][]const u8{
    "addrspace", "align",       "allowzero", "and",    "anyframe",    "anytype",        "asm",         "async",    "await",    "break",
    "callconv",  "catch",       "comptime",  "const",  "continue",    "defer",          "else",        "enum",     "errdefer", "error",
    "export",    "extern",      "fn",        "for",    "if",          "inline",         "linksection", "noalias",  "noinline", "nosuspend",
    "opaque",    "or",          "orelse",    "packed", "pub",         "resume",         "return",      "struct",   "suspend",  "switch",
    "test",      "threadlocal", "try",       "union",  "unreachable", "usingnamespace", "var",         "volatile", "while",
};

const js_keywords = [_][]const u8{
    "abstract", "async",     "await",      "break",    "case",   "catch",      "class",     "const",   "continue",  "debugger",
    "declare",  "default",   "delete",     "do",       "else",   "enum",       "export",    "extends", "finally",   "for",
    "function", "if",        "implements", "import",   "in",     "instanceof", "interface", "let",     "namespace", "new",
    "private",  "protected", "public",     "readonly", "return", "static",     "super",     "switch",  "this",      "throw",
    "try",      "typeof",    "var",        "void",     "while",  "with",       "yield",
};

const python_keywords = [_][]const u8{
    "and",  "as",     "assert",   "async",   "await", "break", "class",  "continue", "def",    "del",
    "elif", "else",   "except",   "finally", "for",   "from",  "global", "if",       "import", "in",
    "is",   "lambda", "nonlocal", "not",     "or",    "pass",  "raise",  "return",   "try",    "while",
    "with", "yield",
};

const shell_keywords = [_][]const u8{
    "if",       "then",    "else", "elif",     "fi",     "for",    "while", "until",    "do",    "done",
    "case",     "esac",    "in",   "function", "select", "return", "break", "continue", "local", "export",
    "readonly", "declare",
};

const rust_keywords = [_][]const u8{
    "as",     "async", "await",  "break", "const",  "continue", "crate", "dyn",    "else",   "enum",
    "extern", "fn",    "for",    "if",    "impl",   "in",       "let",   "loop",   "match",  "mod",
    "move",   "mut",   "pub",    "ref",   "return", "self",     "Self",  "static", "struct", "super",
    "trait",  "type",  "unsafe", "use",   "where",  "while",
};

const go_keywords = [_][]const u8{
    "break",  "case",   "chan",   "const", "continue", "default",   "defer", "else",    "fallthrough", "for",
    "func",   "go",     "goto",   "if",    "import",   "interface", "map",   "package", "range",       "return",
    "select", "struct", "switch", "type",  "var",
};

const c_keywords = [_][]const u8{
    "auto",   "break",   "case",  "const",    "continue", "default",  "do",     "else",   "enum",   "extern",
    "for",    "goto",    "if",    "inline",   "register", "restrict", "return", "sizeof", "static", "struct",
    "switch", "typedef", "union", "volatile", "while",
};

const cpp_extra_keywords = [_][]const u8{
    "catch",    "class",    "constexpr", "delete",   "explicit", "final",     "friend", "mutable",  "namespace", "new",
    "noexcept", "nullptr",  "operator",  "override", "private",  "protected", "public", "template", "this",      "throw",
    "try",      "typename", "using",     "virtual",
};

fn isKeyword(lang: Lang, word: []const u8) bool {
    const lists: []const []const []const u8 = switch (lang) {
        .zig => &.{&zig_keywords},
        .js => &.{&js_keywords},
        .python => &.{&python_keywords},
        .shell => &.{&shell_keywords},
        .rust => &.{&rust_keywords},
        .go => &.{&go_keywords},
        .c => &.{&c_keywords},
        .cpp => &.{ &c_keywords, &cpp_extra_keywords },
    };
    if (word.len < 2 or word.len > 12) return false;
    for (lists) |list| for (list) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

fn hasBlockComments(lang: Lang) bool {
    return switch (lang) {
        .js, .rust, .go, .c, .cpp => true,
        .zig, .python, .shell => false,
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn isIdentCont(lang: Lang, c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c) or (lang == .shell and (c == '-' or c == '.' or c == '/'));
}

fn isShellBoundary(c: u8) bool {
    return std.mem.indexOfScalar(u8, " \t;|&(){}!", c) != null;
}

const Found = struct { end: usize, class: Class, state: State = .none };

/// Scans a quoted string starting at `at`; null when it does not close on this line.
fn quoted(text: []const u8, at: usize, quote: u8, escapes: bool) ?usize {
    var j = at + 1;
    while (j < text.len) {
        if (escapes and text[j] == '\\') {
            j += 2;
        } else if (text[j] == quote) {
            return j + 1;
        } else j += 1;
    }
    return null;
}

/// Rust `'x'` and `'\n'`; lifetimes like `'a` are not strings.
fn rustChar(text: []const u8, at: usize) ?usize {
    if (at + 2 >= text.len) return null;
    if (text[at + 1] == '\\') {
        var j = at + 3;
        while (j < text.len and j < at + 12) : (j += 1) if (text[j] == '\'') return j + 1;
        return null;
    }
    const n = std.unicode.utf8ByteSequenceLength(text[at + 1]) catch return null;
    const close = at + 1 + n;
    return if (close < text.len and text[close] == '\'') close + 1 else null;
}

/// Continuation of a multi-line construct from the start of a line.
fn resume_(lang: Lang, state: State, text: []const u8, from: usize) Found {
    switch (state) {
        .block_comment => {
            const at = std.mem.indexOfPos(u8, text, from, "*/") orelse return .{ .end = text.len, .class = .comment, .state = .block_comment };
            return .{ .end = at + 2, .class = .comment };
        },
        .triple_dq, .triple_sq => {
            const delim: []const u8 = if (state == .triple_dq) "\"\"\"" else "'''";
            var j = from;
            while (j < text.len) {
                if (text[j] == '\\') {
                    j += 2;
                } else if (std.mem.startsWith(u8, text[j..], delim)) {
                    return .{ .end = j + 3, .class = .string };
                } else j += 1;
            }
            return .{ .end = text.len, .class = .string, .state = state };
        },
        .backtick => {
            var j = from;
            while (j < text.len) {
                if (lang == .js and text[j] == '\\') {
                    j += 2;
                } else if (text[j] == '`') {
                    return .{ .end = j + 1, .class = .string };
                } else j += 1;
            }
            return .{ .end = text.len, .class = .string, .state = .backtick };
        },
        .none => unreachable,
    }
}

fn tokenAt(lang: Lang, text: []const u8, i: usize) ?Found {
    const c = text[i];
    const next: u8 = if (i + 1 < text.len) text[i + 1] else 0;
    switch (c) {
        '/' => {
            if (lang == .python or lang == .shell) return null;
            if (next == '/') return .{ .end = text.len, .class = .comment };
            if (next == '*' and hasBlockComments(lang)) {
                const r = resume_(lang, .block_comment, text, i + 2);
                return .{ .end = r.end, .class = .comment, .state = r.state };
            }
            return null;
        },
        '#' => {
            if (lang == .python or (lang == .shell and (i == 0 or isShellBoundary(text[i - 1]) or text[i - 1] == ' ' or text[i - 1] == '\t'))) {
                return .{ .end = text.len, .class = .comment };
            }
            return null;
        },
        '\\' => {
            if (lang == .zig and next == '\\' and std.mem.trim(u8, text[0..i], " \t").len == 0) return .{ .end = text.len, .class = .string };
            return null;
        },
        '"', '\'' => {
            if (lang == .python and next == c and i + 2 < text.len and text[i + 2] == c) {
                const state: State = if (c == '"') .triple_dq else .triple_sq;
                const r = resume_(lang, state, text, i + 3);
                return .{ .end = r.end, .class = .string, .state = r.state };
            }
            if (lang == .rust and c == '\'') {
                const end = rustChar(text, i) orelse return null;
                return .{ .end = end, .class = .string };
            }
            const escapes = !(lang == .shell and c == '\'');
            const end = quoted(text, i, c, escapes) orelse return null;
            return .{ .end = end, .class = .string };
        },
        '`' => {
            if (lang != .js and lang != .go) return null;
            const r = resume_(lang, .backtick, text, i + 1);
            return .{ .end = r.end, .class = .string, .state = r.state };
        },
        else => {
            if (!isIdentStart(c)) return null;
            if (i > 0 and (isIdentCont(lang, text[i - 1]) or text[i - 1] == '.' or (lang == .shell and !isShellBoundary(text[i - 1])))) return null;
            var e = i + 1;
            while (e < text.len and isIdentCont(lang, text[e])) e += 1;
            if (!isKeyword(lang, text[i..e])) return null;
            if (lang == .shell and e < text.len and !isShellBoundary(text[e])) return null;
            return .{ .end = e, .class = .keyword };
        },
    }
}

/// Extends a token end so that it never splits a grapheme cluster.
fn clusterEnd(text: []const u8, end: usize) usize {
    if (end == 0 or end >= text.len or text[end] < 0x80) return end;
    var it = vaxis.unicode.graphemeIterator(text[end - 1 ..]);
    const first = it.next() orelse return end;
    return @max(end, end - 1 + first.bytes(text[end - 1 ..]).len);
}

/// Tokens cover the whole line; adjacent plain text is one token.
pub const Lexer = struct {
    lang: Lang,
    state: State,
    text: []const u8,
    pos: usize = 0,

    pub fn init(lang: Lang, state: State, text: []const u8) Lexer {
        return .{ .lang = lang, .state = state, .text = text };
    }

    pub fn next(self: *Lexer) ?Token {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        var found: ?Found = null;
        if (self.state != .none) {
            found = resume_(self.lang, self.state, self.text, start);
        } else found = tokenAt(self.lang, self.text, start);
        if (found) |f| {
            self.state = f.state;
            self.pos = clusterEnd(self.text, f.end);
            return .{ .start = start, .end = self.pos, .class = f.class };
        }
        var i = start + 1;
        while (i < self.text.len) {
            if (tokenAt(self.lang, self.text, i) != null) break;
            i += 1;
        }
        self.pos = clusterEnd(self.text, i);
        return .{ .start = start, .end = self.pos, .class = .plain };
    }
};

/// The state after `text`, for the next line.
pub fn advance(lang: Lang, state: State, text: []const u8) State {
    var lx = Lexer.init(lang, state, text);
    while (lx.next()) |_| {}
    return lx.state;
}

const testing = std.testing;

const Want = struct { class: Class, text: []const u8 };

fn expectTokens(lang: Lang, state: State, text: []const u8, want: []const Want) !void {
    var lx = Lexer.init(lang, state, text);
    for (want) |w| {
        const t = lx.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(w.class, t.class);
        try testing.expectEqualStrings(w.text, text[t.start..t.end]);
    }
    try testing.expect(lx.next() == null);
}

test "info strings map aliases and ignore unknown languages" {
    try testing.expectEqual(Lang.zig, langFromInfo("zig").?);
    try testing.expectEqual(Lang.zig, langFromInfo("  ZIG title=x").?);
    try testing.expectEqual(Lang.js, langFromInfo("tsx").?);
    try testing.expectEqual(Lang.js, langFromInfo("javascript").?);
    try testing.expectEqual(Lang.python, langFromInfo("py").?);
    try testing.expectEqual(Lang.shell, langFromInfo("console").?);
    try testing.expectEqual(Lang.rust, langFromInfo("rs{1}").?);
    try testing.expectEqual(Lang.cpp, langFromInfo("c++").?);
    try testing.expectEqual(Lang.c, langFromInfo("h").?);
    try testing.expect(langFromInfo("") == null);
    try testing.expect(langFromInfo("text") == null);
    try testing.expect(langFromInfo("zigg") == null);
}

test "zig: keywords, strings with escapes, comments, multiline strings" {
    try expectTokens(.zig, .none, "pub fn main() void { // hi", &.{
        .{ .class = .keyword, .text = "pub" },
        .{ .class = .plain, .text = " " },
        .{ .class = .keyword, .text = "fn" },
        .{ .class = .plain, .text = " main() void { " },
        .{ .class = .comment, .text = "// hi" },
    });
    try expectTokens(.zig, .none, "const s = \"a\\\"b\"; const c = '\\'';", &.{
        .{ .class = .keyword, .text = "const" },
        .{ .class = .plain, .text = " s = " },
        .{ .class = .string, .text = "\"a\\\"b\"" },
        .{ .class = .plain, .text = "; " },
        .{ .class = .keyword, .text = "const" },
        .{ .class = .plain, .text = " c = " },
        .{ .class = .string, .text = "'\\''" },
        .{ .class = .plain, .text = ";" },
    });
    try expectTokens(.zig, .none, "    \\\\line one // not a comment", &.{
        .{ .class = .plain, .text = "    " },
        .{ .class = .string, .text = "\\\\line one // not a comment" },
    });
    try expectTokens(.zig, .none, "x.error y", &.{.{ .class = .plain, .text = "x.error y" }});
    try expectTokens(.zig, .none, "iffy elsewhere", &.{.{ .class = .plain, .text = "iffy elsewhere" }});
}

test "unterminated single-line strings stay plain" {
    try expectTokens(.zig, .none, "say \"oops", &.{.{ .class = .plain, .text = "say \"oops" }});
    try expectTokens(.shell, .none, "echo don't", &.{.{ .class = .plain, .text = "echo don't" }});
}

test "block comments carry across lines" {
    try expectTokens(.c, .none, "a /* b", &.{
        .{ .class = .plain, .text = "a " },
        .{ .class = .comment, .text = "/* b" },
    });
    try testing.expectEqual(State.block_comment, advance(.c, .none, "a /* b"));
    try expectTokens(.c, .block_comment, "still */ return x; /* y */ z", &.{
        .{ .class = .comment, .text = "still */" },
        .{ .class = .plain, .text = " " },
        .{ .class = .keyword, .text = "return" },
        .{ .class = .plain, .text = " x; " },
        .{ .class = .comment, .text = "/* y */" },
        .{ .class = .plain, .text = " z" },
    });
    try testing.expectEqual(State.none, advance(.c, .block_comment, "end */"));
    try testing.expectEqual(State.block_comment, advance(.rust, .block_comment, "no end"));
    try testing.expectEqual(State.none, advance(.zig, .none, "/* not zig"));
    try testing.expectEqual(State.none, advance(.python, .none, "/* not python"));
}

test "javascript: template strings span lines, keywords, comments" {
    try expectTokens(.js, .none, "const t = `a${b}", &.{
        .{ .class = .keyword, .text = "const" },
        .{ .class = .plain, .text = " t = " },
        .{ .class = .string, .text = "`a${b}" },
    });
    try testing.expectEqual(State.backtick, advance(.js, .none, "const t = `a${b}"));
    try expectTokens(.js, .backtick, "mid \\` still` + 1 // c", &.{
        .{ .class = .string, .text = "mid \\` still`" },
        .{ .class = .plain, .text = " + 1 " },
        .{ .class = .comment, .text = "// c" },
    });
    try testing.expectEqual(State.none, advance(.js, .backtick, "mid \\` still`"));
    try expectTokens(.go, .none, "x := `C:\\`", &.{
        .{ .class = .plain, .text = "x := " },
        .{ .class = .string, .text = "`C:\\`" },
    });
}

test "python: hash comments, triple quotes across lines, strings" {
    try expectTokens(.python, .none, "def f(): # note 'x'", &.{
        .{ .class = .keyword, .text = "def" },
        .{ .class = .plain, .text = " f(): " },
        .{ .class = .comment, .text = "# note 'x'" },
    });
    try expectTokens(.python, .none, "s = \"\"\"doc", &.{
        .{ .class = .plain, .text = "s = " },
        .{ .class = .string, .text = "\"\"\"doc" },
    });
    try testing.expectEqual(State.triple_dq, advance(.python, .none, "s = \"\"\"doc"));
    try expectTokens(.python, .triple_dq, "more # not comment \"\"\" and 'q' # c", &.{
        .{ .class = .string, .text = "more # not comment \"\"\"" },
        .{ .class = .plain, .text = " " },
        .{ .class = .keyword, .text = "and" },
        .{ .class = .plain, .text = " " },
        .{ .class = .string, .text = "'q'" },
        .{ .class = .plain, .text = " " },
        .{ .class = .comment, .text = "# c" },
    });
    try testing.expectEqual(State.triple_sq, advance(.python, .none, "'''x"));
    try testing.expectEqual(State.none, advance(.python, .none, "'''x''' + ''"));
    try testing.expectEqual(State.triple_dq, advance(.python, .triple_dq, "no close \\\"\"\""));
}

test "shell: comments only at word start, quotes, keywords" {
    try expectTokens(.shell, .none, "echo $# a#b # c", &.{
        .{ .class = .plain, .text = "echo $# a#b " },
        .{ .class = .comment, .text = "# c" },
    });
    try expectTokens(.shell, .none, "if x; then echo 'a\\' \"b\\\"c\"", &.{
        .{ .class = .keyword, .text = "if" },
        .{ .class = .plain, .text = " x; " },
        .{ .class = .keyword, .text = "then" },
        .{ .class = .plain, .text = " echo " },
        .{ .class = .string, .text = "'a\\'" },
        .{ .class = .plain, .text = " " },
        .{ .class = .string, .text = "\"b\\\"c\"" },
    });
    try expectTokens(.shell, .none, "git --for x-if in", &.{
        .{ .class = .plain, .text = "git --for x-if " },
        .{ .class = .keyword, .text = "in" },
    });
}

test "rust: lifetimes are not chars, char literals and keywords" {
    try expectTokens(.rust, .none, "fn f<'a>(x: &'a str) -> char { 'x' }", &.{
        .{ .class = .keyword, .text = "fn" },
        .{ .class = .plain, .text = " f<'a>(x: &'a str) -> char { " },
        .{ .class = .string, .text = "'x'" },
        .{ .class = .plain, .text = " }" },
    });
    try expectTokens(.rust, .none, "let c = '\\n'; let e = 'é';", &.{
        .{ .class = .keyword, .text = "let" },
        .{ .class = .plain, .text = " c = " },
        .{ .class = .string, .text = "'\\n'" },
        .{ .class = .plain, .text = "; " },
        .{ .class = .keyword, .text = "let" },
        .{ .class = .plain, .text = " e = " },
        .{ .class = .string, .text = "'é'" },
        .{ .class = .plain, .text = ";" },
    });
}

test "c and cpp: preprocessor is plain, cpp adds keywords" {
    try expectTokens(.c, .none, "#include <a.h> // x", &.{
        .{ .class = .plain, .text = "#include <a.h> " },
        .{ .class = .comment, .text = "// x" },
    });
    try expectTokens(.c, .none, "class", &.{.{ .class = .plain, .text = "class" }});
    try expectTokens(.cpp, .none, "class", &.{.{ .class = .keyword, .text = "class" }});
    try expectTokens(.cpp, .none, "return 0;", &.{
        .{ .class = .keyword, .text = "return" },
        .{ .class = .plain, .text = " 0;" },
    });
}

test "go keywords" {
    try expectTokens(.go, .none, "func main() { go f() }", &.{
        .{ .class = .keyword, .text = "func" },
        .{ .class = .plain, .text = " main() { " },
        .{ .class = .keyword, .text = "go" },
        .{ .class = .plain, .text = " f() }" },
    });
}

test "tokens never split a grapheme cluster and cover the line" {
    const text = "x = \"a\"\u{301} y // é";
    var lx = Lexer.init(.python, .none, text);
    var at: usize = 0;
    while (lx.next()) |t| {
        try testing.expectEqual(at, t.start);
        try testing.expect(t.end > t.start);
        at = t.end;
    }
    try testing.expectEqual(text.len, at);
    lx = Lexer.init(.python, .none, text);
    _ = lx.next();
    const second = lx.next().?;
    try testing.expectEqualStrings("\"a\"\u{301}", text[second.start..second.end]);
}
