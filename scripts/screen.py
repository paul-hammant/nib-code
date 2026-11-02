"""Rebuilds the final screen from a `script` capture. Usage: screen.py FILE [COLS ROWS]"""
import sys,re
s=open(sys.argv[1],'rb').read().decode('utf8','replace'); e=s.rfind('\x1b[?1049l'); s=s[:s.rfind('\x1b[J',0,e)] if e>0 else s
import unicodedata
W,Hh=(int(sys.argv[2]),int(sys.argv[3])) if len(sys.argv)>3 else (100,24)
rows=[[' ']*W for _ in range(Hh)];r=c=0;i=0
while i<len(s):
    ch=s[i]
    if ch=='\x1b':
        m=re.match(r'\x1b\[([0-9;?>]*)([A-Za-z@])',s[i:])
        if m:
            if m.group(2) in 'Hf' and '?' not in m.group(1):
                p=[int(x) if x else 1 for x in (m.group(1) or '1;1').split(';')]+[1]
                r,c=p[0]-1,p[1]-1
            elif m.group(2)=='C': c+=int(m.group(1) or 1)
            elif m.group(2)=='J' and m.group(1) in ('','2'): rows=[[' ']*W for _ in range(Hh)]
            i+=len(m.group(0));continue
        m=re.match(r'\x1b[\]_P].*?(\x1b\\|\x07)',s[i:],re.S)
        if m: i+=len(m.group(0));continue
        i+=2;continue
    if ch=='\r': c=0
    elif ch=='\n': r+=1
    elif ch>=' ' and 0<=r<Hh and 0<=c<W:
        rows[r][c]=ch; c+=2 if unicodedata.east_asian_width(ch) in 'WF' else 1
        if unicodedata.east_asian_width(ch) in 'WF' and c-1<W: rows[r][c-1]=''
    i+=1
for row in rows:
    t=''.join(row).rstrip()
    if t: print('|'+t)
