"""Synthetic/corrupt/legacy log coverage; mock sessions live in test_session.py."""
from datetime import date, datetime
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

    def test_since_filters_resumed_steps_not_file_mtime(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'resumed.jsonl'
            header = dict(at=cutoff - 1000, cwd=directory, **{'from': 0},
                          messages=[dict(role='system', content='base')])
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(
                dict(code='tools.bash({command: "missing_command"})'))))
            old = dict(at=cutoff - 1, **{'from': 1}, ms=100,
                       usage=dict(prompt_tokens=100, completion_tokens=20, prompt_cache_hit_tokens=50),
                       messages=[dict(role='user', content='old'),
                                 dict(role='assistant', tool_calls=[run]),
                                 dict(role='tool', tool_call_id='r', content='SyntaxError: old')],
                       run_results=[dict(tool_call_id='r', ok=False)])
            new = dict(at=cutoff, **{'from': 4}, ms=20,
                       usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=4),
                       messages=[dict(role='assistant', content='done')])
            path.write_text('\n'.join(map(json.dumps, [header, old])) + '\n')
            os.utime(path, (cutoff / 1000 + 3600,) * 2)
            self.assertEqual(stats.summarize([path], date(2025, 1, 2))['overall']['steps'], 0)
            with path.open('a') as stream:
                stream.write(json.dumps(new) + '\n')
            for mtime in (0, cutoff / 1000 + 3600):
                with self.subTest(mtime=mtime):
                    os.utime(path, (mtime,) * 2)
                    report = stats.summarize([path], date(2025, 1, 2))
                    t = report['overall']
                    self.assertEqual((t['sessions'], t['turns'], t['steps'], t['runs']), (1, 1, 1, 0))
                    self.assertEqual((t['avg_steps_per_turn'], t['timed_turns']), (1, 0))
                    self.assertIsNone(t['avg_turn_ms'])
                    self.assertEqual(report['usage']['total_tokens'], 12)
                    self.assertEqual(report['tools'], {})
                    self.assertEqual(report['errors']['js_syntax']['count'], 0)
                    self.assertEqual(report['slowest_steps'][0]['step'], 2)
                    self.assertEqual(report['time_filter'], dict(selected_records_with_at=1,
                        selected_records_using_mtime=0, selected_steps_using_mtime=0))
            unfiltered = stats.summarize([path])
            self.assertEqual(unfiltered['overall']['avg_turn_ms'], 120)

    def test_since_legacy_and_invalid_timestamps_report_fallback(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'legacy.jsonl'
            header = {'from': 0, 'messages': [dict(role='system', content='base')]}
            for at in ('missing', None, True, '1735776000000', -1, 1.5):
                with self.subTest(at=at):
                    record = dict({'from': 1}, ms=30, messages=[
                        dict(role='user', content='hi'), dict(role='assistant', content='done')])
                    if at != 'missing':
                        record['at'] = at
                    path.write_text('\n'.join(map(json.dumps, [header, record])) + '\n')
                    os.utime(path, (cutoff / 1000,) * 2)
                    report = stats.summarize([path], date(2025, 1, 2))
                    self.assertEqual(report['overall']['steps'], 1)
                    self.assertEqual(report['overall']['avg_turn_ms'], 30)
                    self.assertEqual(report['time_filter'], dict(selected_records_with_at=0,
                        selected_records_using_mtime=1, selected_steps_using_mtime=1))
                    self.assertIn('1 条回退文件时间', stats.text_report(report))
                    os.utime(path, (cutoff / 1000 - 1,) * 2)
                    self.assertEqual(stats.summarize([path], date(2025, 1, 2))['overall']['steps'], 0)

    def test_since_mixed_records_diagnostics_interruptions_and_compaction(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            records = [dict(at=cutoff - 1000, **{'from': 0},
                            messages=[dict(role='system', content='base')]),
                       dict(at=cutoff - 1, **{'from': 1}, messages=[
                           dict(role='user', content='old'), dict(role='assistant', content='old')]),
                       dict(at=cutoff, **{'from': 1}, messages=[dict(role='user', content='summary')]),
                       dict(at=cutoff, diagnostic=dict(message='new failure')),
                       dict(at=cutoff - 1, diagnostic=dict(message='old failure')),
                       dict(diagnostic=dict(message='legacy failure')),
                       dict(at=cutoff - 1, **{'from': 2}, messages=[dict(role='user', content='old'),
                           dict(role='assistant', content='[interrupted by user]')]),
                       dict(at=cutoff, **{'from': 4}, messages=[dict(role='user', content='new'),
                           dict(role='assistant', content='[interrupted by user]')]),
                       dict({'from': 6}, ms=40, messages=[
                           dict(role='user', content='legacy'), dict(role='assistant', content='ok')])]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            os.utime(path, (cutoff / 1000,) * 2)
            report = stats.summarize([path], date(2025, 1, 2))
            self.assertEqual(report['errors']['provider_failure']['count'], 2)
            self.assertEqual(report['errors']['interrupted']['count'], 1)
            t = report['overall']
            self.assertEqual((t['sessions'], t['turns'], t['steps'], t['timed_turns']), (1, 2, 1, 1))
            self.assertEqual(t['avg_turn_ms'], 40)
            self.assertEqual(report['time_filter'], dict(selected_records_with_at=2,
                selected_records_using_mtime=2, selected_steps_using_mtime=1))

    def test_since_compaction_preserves_turn_without_recounting_retained_history(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'compact.jsonl'
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(
                dict(code='tools.read({path: "missing"})'))))
            retained = [dict(role='assistant', tool_calls=[run]),
                        dict(role='tool', tool_call_id='r', content='Error: missing file')]
            for first_at, expected_steps, expected_ms in ((cutoff, 2, 120), (cutoff - 1, 1, None)):
                with self.subTest(first_at=first_at):
                    records = [dict(at=cutoff - 100, **{'from': 0},
                                    messages=[dict(role='system', content='base')]),
                               dict(at=first_at, **{'from': 1}, ms=100, messages=[
                                   dict(role='user', content='hi')] + retained,
                                   usage=dict(prompt_tokens=100, completion_tokens=20, prompt_cache_hit_tokens=0)),
                               dict(at=cutoff, **{'from': 1}, messages=[
                                   dict(role='user', content='summary')] + retained),
                               dict(at=cutoff, **{'from': 4}, ms=20,
                                    messages=[dict(role='assistant', content='done')])]
                    path.write_text('\n'.join(map(json.dumps, records)) + '\n')
                    report = stats.summarize([path], date(2025, 1, 2))
                    t = report['overall']
                    self.assertEqual((t['turns'], t['steps'], t['avg_turn_ms']),
                                     (1, expected_steps, expected_ms))
                    self.assertEqual(t['runs'], expected_steps - 1)
                    self.assertEqual(report['errors']['other_failure']['count'], expected_steps - 1)
                    self.assertEqual(report['usage']['total_tokens'], 120 if expected_steps == 2 else 0)
                    self.assertEqual(report['time_filter']['selected_records_with_at'], expected_steps)

    def test_since_interruption_selects_an_existing_turn_without_its_old_step(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'interrupted.jsonl'
            run = dict(id='r', function=dict(name='run', arguments='{}'))
            records = [dict(at=cutoff - 100, **{'from': 0},
                            messages=[dict(role='system', content='base')]),
                       dict(at=cutoff - 1, **{'from': 1}, ms=100,
                            usage=dict(prompt_tokens=100, completion_tokens=20, prompt_cache_hit_tokens=0),
                            messages=[dict(role='user', content='hi'),
                                      dict(role='assistant', tool_calls=[run]),
                                      dict(role='tool', tool_call_id='r', content='SyntaxError: old')]),
                       dict(at=cutoff, **{'from': 4},
                            messages=[dict(role='assistant', content='[interrupted by user]')])]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path], date(2025, 1, 2))
            t = report['overall']
            self.assertEqual((t['turns'], t['steps'], t['timed_turns'], t['runs']), (1, 0, 0, 0))
            self.assertEqual(report['usage']['total_tokens'], 0)
            self.assertEqual(report['errors']['interrupted']['count'], 1)
            self.assertEqual(report['errors']['js_syntax']['count'], 0)
            self.assertEqual(report['time_filter']['selected_records_with_at'], 1)

    def test_since_session_selection_for_header_diagnostic_and_replacement(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'session.jsonl'
            header = dict(at=cutoff - 1, **{'from': 0}, messages=[dict(role='system', content='base')])
            old = dict(at=cutoff - 1, **{'from': 1}, messages=[
                dict(role='user', content='old'), dict(role='assistant', content='done')])
            replacement = dict(at=cutoff, **{'from': 1}, messages=[dict(role='user', content='summary')])
            diagnostic = dict(at=cutoff, diagnostic=dict(message='new failure'))
            cases = [([header, old, replacement], 0, 0, 0),
                     ([header, diagnostic], 1, 1, 1),
                     ([dict(header, at=cutoff)], 1, 0, 0)]
            for records, sessions, errors, timed_records in cases:
                with self.subTest(records=records):
                    path.write_text('\n'.join(map(json.dumps, records)) + '\n')
                    report = stats.summarize([path], date(2025, 1, 2))
                    t = report['overall']
                    self.assertEqual((t['sessions'], t['turns'], t['steps']), (sessions, 0, 0))
                    self.assertEqual(report['errors']['provider_failure']['count'], errors)
                    self.assertEqual(report['time_filter']['selected_records_with_at'], timed_records)

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

    def test_provider_diagnostic_is_not_a_step_or_context_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'diagnostic.jsonl'
            records = [dict(cwd=directory, **{'from': 0}, messages=[dict(role='system', content='base')]),
                       dict(diagnostic=dict(error_name='ProviderFailed',
                            message='Codex stream failed: invalid_prompt: bad request; the Step was not committed.',
                            attempts=1, step=1), **{'from': 0}, messages=[]),
                       dict({'from': 1}, messages=[dict(role='user', content='next'), dict(role='assistant', content='ok')],
                            usage=dict(prompt_tokens=10, completion_tokens=2, prompt_cache_hit_tokens=0))]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path])
            self.assertEqual(report['errors']['provider_failure']['count'], 1)
            self.assertIn('invalid_prompt', report['errors']['provider_failure']['examples'][0]['text'])
            self.assertEqual(report['overall']['steps'], 1)
            self.assertEqual(report['overall']['turns'], 1)
            self.assertEqual(report['usage']['total_tokens'], 12)

    def test_static_commands_skip_heredoc_and_redirects(self):
        command = "python3 - <<'PY'\nprint(1); not_a_command()\nPY\ngit status 2>&1; zig build"
        code = 'await tools.bash({timeout_ms: 100, command: ' + json.dumps(command) + '})'
        self.assertEqual(list(stats.commands(code)), ['python3', 'git', 'zig'])
        self.assertEqual(list(stats.commands("tools.bash({command: 'echo 你好'})")), ['echo'])


if __name__ == '__main__':
    unittest.main()
