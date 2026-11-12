# tools/mutate.py SRC TEST MUTS: applies each "old ==> new" line of MUTS (\n for
# newlines) to SRC in turn, runs the std.spec TEST, and says whether a test
# failed (KILLED) or not (SURVIVED); SRC is restored afterwards.
import sys, subprocess, shutil
src, test = sys.argv[1], sys.argv[2]
muts = [l.rstrip('\n').split(' ==> ') for l in open(sys.argv[3]) if ' ==> ' in l]
orig = open(src).read()
try:
    for a, b in muts:
        a = a.replace('\\n', '\n'); b = b.replace('\\n', '\n')
        if a not in orig:
            print('NOT FOUND:', a[:60]); continue
        open(src, 'w').write(orig.replace(a, b, 1))
        out = subprocess.run(['ae', 'run', '--lib', 'ae', test], capture_output=True, text=True)
        n = (out.stdout + out.stderr).count('✗')
        bad = out.returncode != 0 and n == 0
        print(('KILLED' if n or bad else 'SURVIVED'), n, '<-', a.strip()[:70])
finally:
    open(src, 'w').write(orig)
