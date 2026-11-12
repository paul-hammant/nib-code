/* Grapheme segmentation and display width for ae/term's cell model.
 *
 * std.unicode exposes grapheme counting and slicing but not iteration or
 * display width (see asks/unicode-grapheme-width.md), so this shim calls the
 * utf8proc that libaether already vendors and links. The width rules follow
 * libvaxis's gwidth.zig, the library upstream nib renders with, so a cell
 * measures the same here as it did there.
 */
#include <string.h>
#include "std/unicode/utf8proc/utf8proc.h"

/* Byte offset where the grapheme cluster starting at `off` ends. Invalid
 * UTF-8 bytes are a cluster of one byte each, as libvaxis treats them. */
int aeterm_grapheme_end(const char *s, int len, int off) {
    if (off >= len) return len;
    utf8proc_int32_t prev = -1, cp;
    utf8proc_int32_t state = 0;
    int i = off;
    while (i < len) {
        utf8proc_ssize_t n = utf8proc_iterate((const utf8proc_uint8_t *)s + i, len - i, &cp);
        if (n <= 0) {
            /* an invalid byte: its own cluster, unless it ends one */
            return i == off ? off + 1 : i;
        }
        if (prev >= 0 && utf8proc_grapheme_break_stateful(prev, cp, &state)) return i;
        prev = cp;
        i += (int)n;
    }
    return len;
}

/* libvaxis eawToWidth: -1 for controls, 0 for marks and the zero-width set,
 * 2 for East Asian wide/fullwidth, else 1. */
static int cp_width(utf8proc_int32_t cp) {
    if (cp == 0) return 0;
    if (cp < 32 || (cp >= 0x7f && cp < 0xa0)) return -1;
    utf8proc_category_t gc = utf8proc_category(cp);
    if (gc == UTF8PROC_CATEGORY_MN || gc == UTF8PROC_CATEGORY_ME) return 0;
    switch (cp) {
    case 0x00ad: case 0x200b: case 0x200c: case 0x200d: case 0x2060:
    case 0x034f: case 0xfeff:
        return 0;
    }
    if (cp >= 0x180b && cp <= 0x180d) return 0;
    if (cp >= 0xfe00 && cp <= 0xfe0f) return 0;
    if (cp >= 0xe0100 && cp <= 0xe01ef) return 0;
    return utf8proc_charwidth(cp) >= 2 ? 2 : 1;
}

static int is_emoji_presentation(utf8proc_int32_t cp) {
    /* utf8proc has no Emoji_Presentation table. Every Emoji_Presentation
     * code point is East Asian Wide (cp_width gives it 2) except the
     * regional indicators, which are Neutral. */
    return cp >= 0x1f1e6 && cp <= 0x1f1ff;
}

/* Display width of s[off, off+len). method 0 = wcwidth (per code point),
 * 1 = unicode (per grapheme, as a terminal with mode 2027 measures). */
int aeterm_gwidth(const char *s, int off, int len, int method) {
    int end = off + len, total = 0;
    if (method == 0) {
        int i = off;
        utf8proc_int32_t cp;
        while (i < end) {
            utf8proc_ssize_t n = utf8proc_iterate((const utf8proc_uint8_t *)s + i, end - i, &cp);
            if (n <= 0) { i++; total += 1; continue; }
            int w = (cp >= 0x1f3fb && cp <= 0x1f3ff) ? 2 : cp_width(cp);
            if (w > 0) total += w;
            i += (int)n;
        }
        return total;
    }
    int g = off;
    while (g < end) {
        int gend = aeterm_grapheme_end(s, end, g);
        int width = 0, emoji_vs = 0, text_vs = 0, ri = 0, i = g;
        utf8proc_int32_t cp;
        while (i < gend) {
            utf8proc_ssize_t n = utf8proc_iterate((const utf8proc_uint8_t *)s + i, gend - i, &cp);
            if (n <= 0) { i++; if (width < 1) width = 1; continue; }
            i += (int)n;
            if (cp == 0xfe0f) { emoji_vs = 1; continue; }
            if (cp == 0xfe0e) { text_vs = 1; continue; }
            if (cp >= 0x1f1e6 && cp <= 0x1f1ff) ri++;
            if (is_emoji_presentation(cp)) emoji_vs = 1;
            int w = cp_width(cp);
            if (w > width) width = w;
        }
        if (text_vs) { if (width < 1) width = 1; }
        else if (emoji_vs || ri == 2) { if (width < 2) width = 2; }
        total += width;
        g = gend;
    }
    return total;
}

/* The code point at s[off]; -1 for an invalid sequence. */
int aeterm_codepoint_at(const char *s, int len, int off) {
    utf8proc_int32_t cp;
    if (off >= len) return -1;
    utf8proc_ssize_t n = utf8proc_iterate((const utf8proc_uint8_t *)s + off, len - off, &cp);
    return n <= 0 ? -1 : (int)cp;
}

/* Bytes the code point at s[off] occupies (1 for an invalid byte). */
int aeterm_codepoint_len(const char *s, int len, int off) {
    utf8proc_int32_t cp;
    if (off >= len) return 0;
    utf8proc_ssize_t n = utf8proc_iterate((const utf8proc_uint8_t *)s + off, len - off, &cp);
    return n <= 0 ? 1 : (int)n;
}
