"""Synthetic/corrupt/legacy log coverage; mock sessions live in test_session.py."""
from datetime import date
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('stats', ROOT / 'scripts/stats.py')
stats = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(stats)


class StatsTest(unittest.TestCase):
    def test_legacy_corrupt_compaction_and_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ('a' * 32 + '.jsonl')
            header = dict(cwd=directory, **{'from': 0}, messages=[dict(role='system', content='base')])
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(dict(
                code='await tools.bash({command: "git status; zig build"})'))))
            def step(start, output, **extra):
                return dict({'from': start, 'messages': [dict(role='user', content='hi'),
                    dict(role='assistant', tool_calls=[run]),
                    dict(role='tool', tool_call_id='r', content=output)]}, **extra)
            records = [header,
                       step(1, 'SyntaxError: unexpected token'),
                       dict({'from': 4, 'messages': [dict(role='assistant', content='done')]},
                            usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=4), ms=50),
                       {'from': 1, 'messages': [dict(role='user', content='summary')]},
                       step(2, 'Error: expected { code: string }', run_results=[dict(tool_call_id='r', ok=False)]),
                       {'from': 5, 'messages': [dict(role='assistant', content='[interrupted by user]')]}]
            path.write_text('garbage\n[]\n{"messages":null}\n' + '\n'.join(map(json.dumps, records)) +
                            '\n{"from":5,"messages":[17]}\n{"from":')
            report = stats.summarize([path])
            t = report['overall']
            self.assertEqual((t['sessions'], t['turns'], t['steps'], t['runs']), (1, 2, 3, 2))
            self.assertEqual((t['runs_failed'], t['runs_unknown'], t['run_failure_rate']), (1, 1, 1))
            self.assertEqual(report['usage']['total_tokens'], 12)
            self.assertEqual(report['usage']['cache_hit_rate'], .4)
            self.assertIsNone(t['avg_turn_ms'])
            self.assertEqual(report['tools'], {'bash': 2})
            self.assertEqual(report['errors']['interrupted']['count'], 1)
            self.assertEqual(report['errors']['js_syntax']['count'], 1)
            self.assertEqual(report['errors']['tool_arguments']['count'], 1)
            self.assertEqual(stats.summarize([path], cwd=Path(directory).resolve())['overall']['sessions'], 1)
            self.assertEqual(stats.summarize([path], cwd=ROOT)['overall']['sessions'], 0)
            os.utime(path, (0, 0))
            self.assertEqual(stats.summarize([path], since=date(2000, 1, 1))['overall']['sessions'], 0)
            cli = json.loads(subprocess.check_output(['python3', str(ROOT / 'scripts/stats.py'), '--json',
                                                     directory, str(path)]))
            self.assertEqual(cli['overall']['sessions'], 1)

    def test_diagnostics_do_not_match_read_source_or_successful_test_output(self):
        source = 'SyntaxError: test\nError: run timed out\nError: expected { x }\nCredentialAccessDenied'
        self.assertEqual(list(stats.diagnostics(json.dumps(dict(text=source, next_offset=None)))), [])
        self.assertEqual(list(stats.diagnostics(json.dumps(dict(exit_code=0, output='test \"Error: run timed out\" passed')))), [])
        cases = {'js_syntax': 'SyntaxError: x', 'run_timeout': 'Error: run timed out',
                 'subagent': 'Error: agent: subagent stopped due to timeout after 5 ms',
                 'tool_arguments': 'Error: read: expected { path: string }',
                 'denied': 'Error: CredentialAccessDenied', 'interrupted': 'Error: run canceled'}
        for name, text in cases.items():
            candidates = list(stats.diagnostics(text))
            self.assertTrue(any(stats.re.search(stats.ERRORS[name], s, stats.re.I) for s in candidates), name)
        self.assertIn('exit_code: 127', next(stats.diagnostics('{"exit_code":127,"output":"no command"}')))
        self.assertEqual(list(stats.diagnostics('result: "subagent: HTTP 400"')), ['subagent: HTTP 400'])

    def test_static_commands_skip_heredoc_and_redirects(self):
        command = "python3 - <<'PY'\nprint(1); not_a_command()\nPY\ngit status 2>&1; zig build"
        code = 'await tools.bash({timeout_ms: 100, command: ' + json.dumps(command) + '})'
        self.assertEqual(list(stats.commands(code)), ['python3', 'git', 'zig'])
        self.assertEqual(list(stats.commands("tools.bash({command: 'echo 你好'})")), ['echo'])


if __name__ == '__main__':
    unittest.main()
