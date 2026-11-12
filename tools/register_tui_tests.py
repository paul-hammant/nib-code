# Adds every ae/tests/tui_*_test.ae not yet in .tests.ae to its TUI block.
import glob
p = '.tests.ae'
s = open(p).read()
head = '        // The TUI (ae/nib/tui), upstream src/tui*.\n'
blk = ''
for f in sorted(glob.glob('ae/tests/tui_*_test.ae')):
    if '"%s"' % f in s:
        continue
    blk += '        aether.program_test() {\n            source("%s")\n            lib("ae")\n        }\n' % f
s = s.replace(head, head + blk)
open(p, 'w').write(s)
