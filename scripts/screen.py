"""Rebuilds the final screen from a `script` capture. Usage: screen.py FILE [COLS ROWS]"""
import re
import sys
import unicodedata


def screen(data, width=100, height=24):
    """Return every row, including blank rows, for capture assertions.

    >>> screen(b'hello\x1b[2;2Hworld', 8, 2)
    ['hello', ' world']
    >>> screen('你a\x1b[1;3Hb'.encode(), 5, 1)
    ['你b']
    >>> screen(b'keep\x1b[H\x1b[J\x1b[?1049l', 8, 1)
    ['keep']
    """
    s = data.decode('utf8', 'replace')
    end = s.rfind('\x1b[?1049l')
    clear = s.rfind('\x1b[H\x1b[J', 0, end)
    if end >= 0:
        s = s[:clear if clear >= 0 else end]
    rows = [[' '] * width for _ in range(height)]
    r = c = i = 0
    while i < len(s):
        ch = s[i]
        if ch == '\x1b':
            m = re.match(r'\x1b\[([0-9;?>]*)([A-Za-z@])', s[i:])
            if m:
                args, op = m.groups()
                if op in 'Hf' and '?' not in args:
                    p = [int(x) if x else 1 for x in (args or '1;1').split(';')] + [1]
                    r, c = p[0] - 1, p[1] - 1
                elif op == 'C':
                    c += int(args or 1)
                elif op == 'J' and args in ('', '2'):
                    rows = [[' '] * width for _ in range(height)]
                i += len(m.group(0))
                continue
            m = re.match(r'\x1b[\]_P].*?(\x1b\\|\x07)', s[i:], re.S)
            if m:
                i += len(m.group(0))
                continue
            i += 2
            continue
        if ch == '\r':
            c = 0
        elif ch == '\n':
            r += 1
        elif ch >= ' ' and 0 <= r < height and 0 <= c < width:
            rows[r][c] = ch
            wide = unicodedata.east_asian_width(ch) in 'WF'
            c += 2 if wide else 1
            if wide and c - 1 < width:
                rows[r][c - 1] = ''
        i += 1
    return [''.join(row).rstrip() for row in rows]


if __name__ == '__main__':
    w, h = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (100, 24)
    with open(sys.argv[1], 'rb') as capture:
        for row in screen(capture.read(), w, h):
            if row:
                print('|' + row)
