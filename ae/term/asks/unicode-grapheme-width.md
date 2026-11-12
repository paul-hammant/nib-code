# std.unicode: grapheme iteration and display width

**For:** aether (`std.unicode`). **From:** nib-code's `ae/term`,
2026-11-12, Aether 0.909.0.

## Motivation

A terminal cell holds one grapheme cluster, and a terminal draws it one or
two columns wide. Laying text out in cells needs (1) the next grapheme
boundary from a byte offset, (2) the display width of a cluster, measured
the way the terminal will measure it, and (3) the code point at an offset.

`std.unicode` has `grapheme_len` and `grapheme_substring`, which count and
slice but cannot iterate: walking a string with `grapheme_substring(s, i, 1)`
is O(n) per step. It has no width at all. So `ae/term/screen/unicode.c`
calls the utf8proc that libaether already vendors
(`utf8proc_grapheme_break_stateful`, `utf8proc_charwidth`,
`utf8proc_category`, `utf8proc_iterate`) through `#include
"std/unicode/utf8proc/utf8proc.h"`, which reaches into std's vendored copy.

## Proposed surface

```aether,fragment
// Byte offset where the grapheme cluster starting at `off` ends
// (an invalid byte is a cluster of its own). O(cluster).
unicode.grapheme_end(s: string, off: int) -> int

// Display columns of s, two ways, as terminals measure:
//   WIDTH_WCWIDTH: sum over code points (wcwidth(3): controls 0, combining
//     marks and the zero-width set 0, East Asian Wide/Fullwidth 2, else 1)
//   WIDTH_GRAPHEME: per cluster, the widest code point, 2 for an emoji
//     presentation sequence (VS16) or a regional-indicator pair, as a
//     terminal in mode 2027 does
unicode.display_width(s: string, method: int) -> int

// The code point at byte `off` and its UTF-8 length; -1/1 for an invalid byte.
unicode.codepoint_at(s: string, off: int) -> int
unicode.codepoint_len(s: string, off: int) -> int

// East Asian Width and Emoji_Presentation, for callers with their own rules.
unicode.east_asian_width(cp: int) -> int   // N, A, H, W, F, Na as constants
unicode.is_emoji_presentation(cp: int) -> bool
```

The width rules `ae/term` implements are libvaxis's `gwidth.zig` (which
nib's upstream renders with): see `ae/term/screen/unicode.c` for the exact
cases and `ae/term/tests/test_screen.ae` ("display width") for the
expected values, including ZWJ sequences, VS16, skin tones, flags and
zero-width characters.

One gap the shim papers over: utf8proc has no Emoji_Presentation table, so
a lone regional indicator is special-cased; the rest of Emoji_Presentation
is East Asian Wide, which `utf8proc_charwidth` already gives 2.

## Ask

The functions above in `std.unicode`, so `ae/term` stops including
`std/unicode/utf8proc/utf8proc.h` directly.
