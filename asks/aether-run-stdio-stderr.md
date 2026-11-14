# Ask: os.run_stdio with the child's stderr discarded (or to a file)

**From:** the Aether port of nib, tools.agent. **Aether:** 0.909.0.

`os.run_stdio(prog, argv, env)` gives the child this process's stderr. nib
starts a subagent (a child `nib ask --json --agent-input -`) that way and, as
upstream does (`.stderr = .ignore`), must not let the child hold this
process's stderr: when the parent is killed, whoever reads the parent's
stderr (a test harness's `communicate()`, a pipeline) waits until every child
has exited, because the child still holds the write end.

Repro: a parent that `run_stdio`s `sh -c 'sleep 30'` and is then SIGKILLed;
`python3 -c "import subprocess; p = subprocess.Popen([parent], stderr=subprocess.PIPE); ...; p.kill(); p.communicate(timeout=5)"`
times out after the kill (upstream's tests/test_background_bash.py and
test_agent_reuse.py "killed parent" cases do exactly this).

Wanted: a variant or option taking the child's stderr disposition (inherit,
null, or a file path), e.g. `os.run_stdio_to(prog, argv, env, stderr_path)`
with "" meaning /dev/null.

Stand-in: `nib.tools.process.run_lines` runs the child through
`/bin/sh -c 'exec "$@" 2>/dev/null' sh <argv…>` (exec keeps the pid, so
TERM/KILL still reach the child).

**RESOLVED** in Aether 0.914.0 (aether #3694, 2026-11-14); the stand-in is removed from the port.
