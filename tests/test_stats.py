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

    def test_timing_mixed_logs_and_json_text_sections(self):
        def run(call_id, code):
            return dict(id=call_id, function=dict(name='run', arguments=json.dumps(dict(code=code))))

        old = run('old', 'await tools.bash({command: "zig build"})')
        literal = run('literal', 'await tools.bash({command: "git status --short"}); await tools.read({path: "x"})')
        dynamic = run('dynamic', 'await tools.bash({command: cmd})')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed.jsonl'
            records = [dict(cwd=directory, **{'from': 0}, messages=[dict(role='system', content='base')]),
                       dict({'from': 1}, messages=[dict(role='user', content='old'),
                            dict(role='assistant', tool_calls=[old]), dict(role='tool', tool_call_id='old', content='ok')], ms=100),
                       dict({'from': 4}, messages=[dict(role='user', content='new'),
                            dict(role='assistant', tool_calls=[literal, dynamic]),
                            dict(role='tool', tool_call_id='literal', content='ok'),
                            dict(role='tool', tool_call_id='dynamic', content='ok')],
                            ms=300, model_ms=150, run_ms=100, first_data_ms=10, attempts=2,
                            code=[dict(tool_call_id='literal', first_ms=40, last_ms=90, progress=[[40, 1], [90, 100]]),
                                  dict(tool_call_id='dynamic', first_ms=60, last_ms=111)],
                            run_results=[dict(tool_call_id='dynamic', ok=False, run_ms=20),
                                         dict(tool_call_id='literal', ok=True, run_ms=80)],
                            calls=[dict(name='read', start_ms=10, end_ms=30, ok=True, run_index=1),
                                   dict(name='bash', start_ms=5, end_ms=65, ok=True, run_index=1),
                                   dict(name='bash', start_ms=0, end_ms=10, ok=False, run_index=0)], calls_omitted=3),
                       dict({'from': 8}, messages=[dict(role='assistant', content='done')], ms=0, model_ms=0,
                            run_ms=0, first_data_ms=0, attempts=1, code=[], calls=[], calls_omitted=0),
                       dict({'from': 9}, messages=[dict(role='user', content='no timing'), dict(role='assistant', content='ok')]) ]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            report = stats.summarize([path])
            timing = report['timing']
            self.assertEqual(report['overall']['steps'], 4)
            self.assertEqual(timing['step_ms'], dict(samples=3, median=100, p90=300))
            self.assertEqual(timing['model_ms'], dict(samples=2, median=75, p90=150))
            self.assertEqual(timing['run_ms'], dict(samples=2, median=50, p90=100))
            self.assertEqual(timing['run_result_ms'], dict(samples=2, median=50, p90=80))
            self.assertEqual(timing['first_data_ms']['median'], 5)
            self.assertEqual(timing['code_first_ms'], dict(samples=2, median=50, p90=60))
            self.assertEqual(timing['code_span_ms'], dict(samples=2, median=50.5, p90=51))
            self.assertEqual(timing['attempts'], dict(samples=2, median=1.5, p90=2))
            self.assertEqual(timing['streaming'], dict(samples=2, over_50_ms=1, ratio=.5))
            self.assertEqual((timing['calls_steps'], timing['calls_omitted']), (2, 3))
            self.assertEqual(timing['tools'], {'bash': dict(count=2, total_ms=70, median_ms=35),
                                              'read': dict(count=1, total_ms=20, median_ms=20)})
            self.assertEqual(timing['bash'], dict(heuristic=True, matched_calls=1, unmatched_calls=1,
                             top10=[dict(command='git status', count=1, total_ms=60, median_ms=60)]))
            cli = ['python3', str(ROOT / 'scripts/stats.py'), str(path)]
            json_report = json.loads(subprocess.check_output(cli + ['--json']))
            self.assertEqual(json_report['timing'], timing)
            text = subprocess.check_output(cli).decode()
            self.assertLessEqual(len(text.split('口径：\n', 1)[1].splitlines()) + 1, 5)
            self.assertLessEqual(len(json_report['notes']), 4)
            for snippet in ('计时 Timing', 'step_ms: samples=3 median=100.00 p90=300.00',
                            'model_ms: samples=2', 'run_result_ms: samples=2',
                            'code_first_ms: samples=2', 'code_span_ms: samples=2',
                            'code streaming (last-first > 50 ms): 1/2 = 50.00%',
                            'bash: count=2 total=70 ms median=35.00 ms', 'omitted=3',
                            'heuristic', 'unmatched=1', 'git status: count=1 total=60 ms'):
                self.assertIn(snippet, text)

    def test_since_timing_uses_only_selected_complete_steps_text_and_json(self):
        cutoff = int(datetime(2025, 1, 2).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'mixed-timing.jsonl'
            run = dict(id='r', function=dict(name='run', arguments=json.dumps(
                dict(code='tools.bash({command: "git status"})'))))

            def step(start, duration, span, **extra):
                return dict({'from': start}, ms=duration, model_ms=duration, run_ms=duration,
                            first_data_ms=duration, attempts=1, calls_omitted=1,
                            usage=dict(prompt_tokens=duration, completion_tokens=1, prompt_cache_hit_tokens=0),
                            code=[dict(tool_call_id='r', first_ms=duration, last_ms=duration + span)],
                            run_results=[dict(tool_call_id='r', ok=True, run_ms=duration)],
                            calls=[dict(name='bash', start_ms=0, end_ms=duration, ok=True, run_index=0)],
                            messages=[dict(role='user', content='hi'),
                                      dict(role='assistant', tool_calls=[run]),
                                      dict(role='tool', tool_call_id='r', content='ok'),
                                      dict(role='assistant', content='done')], **extra)

            poison = {key: value for key, value in step(1, 9000, 9000).items()
                      if key not in ('from', 'messages')}
            records = [dict(poison, at=cutoff, cwd=directory, **{'from': 0},
                            messages=[dict(role='system', content='base')]),
                       step(1, 1000, 1000, at=cutoff - 1),
                       step(5, 20, 50, at=cutoff),
                       step(9, 30, 51, at=cutoff + 1),
                       step(13, 40, 90, at=None),
                       dict({'from': 17}, messages=[dict(role='user', content='legacy no timing'),
                                                   dict(role='assistant', content='done')]),
                       dict(poison, at=cutoff, diagnostic=dict(message='provider failed')),
                       dict(poison, at=cutoff, **{'from': 19}, messages=[
                           dict(role='user', content='cancel'),
                           dict(role='assistant', content='[interrupted by user]')]),
                       dict(step(21, 9000, 9000, at=cutoff), repair=True),
                       dict(poison, at=cutoff, **{'from': 1},
                            messages=[dict(role='user', content='compacted'),
                                      dict(role='assistant', content='retained')])]
            path.write_text('\n'.join(map(json.dumps, records)) + '\n')
            for mtime, legacy_selected in ((0, False), (cutoff / 1000, True)):
                with self.subTest(mtime=mtime):
                    os.utime(path, (mtime,) * 2)
                    report = stats.summarize([path], date(2025, 1, 2))
                    timing = report['timing']
                    durations = [20, 30, 40] if legacy_selected else [20, 30]
                    count, total = len(durations), sum(durations)
                    steps = count + int(legacy_selected)
                    t = report['overall']
                    self.assertEqual((t['steps'], t['runs'], t['steps_with_ms'], t['steps_with_usage']),
                                     (steps, count, count, count))
                    self.assertEqual(report['usage']['total_tokens'], total + count)
                    self.assertEqual(report['tools'], {'bash': count})
                    self.assertEqual(report['errors']['provider_failure']['count'], 1)
                    self.assertEqual(report['errors']['interrupted']['count'], 1)
                    self.assertEqual(report['time_filter'], dict(selected_records_with_at=4,
                        selected_records_using_mtime=2 if legacy_selected else 0,
                        selected_steps_using_mtime=2 if legacy_selected else 0))
                    expected = dict(samples=count, median=30 if legacy_selected else 25,
                                    p90=40 if legacy_selected else 30)
                    for key in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms',
                                'first_data_ms', 'code_first_ms'):
                        self.assertEqual(timing[key], expected, key)
                    self.assertEqual(timing['attempts'], dict(samples=count, median=1, p90=1))
                    self.assertEqual(timing['code_span_ms'], dict(samples=count,
                        median=51 if legacy_selected else 50.5, p90=90 if legacy_selected else 51))
                    self.assertEqual(timing['streaming'], dict(samples=count, over_50_ms=count - 1,
                                                              ratio=(count - 1) / count))
                    self.assertEqual((timing['calls_steps'], timing['calls_omitted']), (count, count))
                    tool = dict(count=count, total_ms=total, median_ms=expected['median'])
                    self.assertEqual(timing['tools'], {'bash': tool})
                    self.assertEqual(timing['bash'], dict(heuristic=True, matched_calls=count,
                        unmatched_calls=0, top10=[dict(command='git status', **tool)]))
                    cli = [sys.executable, str(ROOT / 'scripts/stats.py'), str(path),
                           '--since', '2025-01-02']
                    self.assertEqual(json.loads(subprocess.check_output(cli + ['--json'])), report)
                    text = subprocess.check_output(cli).decode()
                    self.assertEqual(text, stats.text_report(report) + '\n')
                    for snippet in (f'Step {steps}；Run {count}', '计时 Timing',
                                    f'model_ms: samples={count}', f'median={expected["median"]:.2f}',
                                    'first_data_ms 是首次收到任何流数据',
                                    '--since 按记录 at', '缺失或无效 at 回退到文件修改时间'):
                        self.assertIn(snippet, text)
            excluded = stats.summarize([path], date(2025, 1, 2), cwd=ROOT)
            self.assertEqual(excluded['overall']['steps'], 0)
            self.assertEqual(excluded['timing'], stats.Timing().report())

    def test_timing_legacy_empty_and_invalid_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'legacy.jsonl'
            records = [dict({'from': 0}, messages=[dict(role='system', content='base')]),
                       dict({'from': 1}, messages=[dict(role='user', content='old'), dict(role='assistant', content='ok')], ms=42)]
            path.write_text('\n'.join(map(json.dumps, records)))
            report = stats.summarize([path])
            timing = report['timing']
            self.assertEqual(timing['step_ms'], dict(samples=1, median=42, p90=42))
            for key in ('model_ms', 'run_ms', 'run_result_ms', 'first_data_ms', 'code_first_ms', 'code_span_ms', 'attempts'):
                self.assertEqual(timing[key], dict(samples=0, median=None, p90=None))
            self.assertEqual(timing['tools'], {})
            self.assertEqual(timing['streaming'], dict(samples=0, over_50_ms=0, ratio=None))
            self.assertIn('model_ms: samples=0 median=n/a p90=n/a', stats.text_report(report))
            self.assertEqual(stats.summarize([])['timing']['step_ms']['samples'], 0)
        timing = stats.Timing()
        timing.add(dict(ms=True, model_ms=-1, run_ms='5', first_data_ms=1.2, attempts=None,
                        code=[None, {}, dict(first_ms=-1, last_ms=3), dict(first_ms=10, last_ms=9)],
                        run_results=[None, dict(run_ms=False)], calls_omitted=-1,
                        calls=[None, {}, dict(name='bash', start_ms=True, end_ms=10),
                               dict(name='read', start_ms=20, end_ms=10)]), {})
        report = timing.report()
        self.assertEqual(report['model_ms']['samples'], 0)
        self.assertEqual(report['code_first_ms']['samples'], 1)
        self.assertEqual(report['code_span_ms']['samples'], 0)
        self.assertEqual(report['tools'], {})
        self.assertEqual(report['calls_omitted'], 0)
        self.assertEqual(stats.distribution(list(range(1, 11))), dict(samples=10, median=5.5, p90=9))

    def test_bash_timing_literal_heuristic_and_unmatched(self):
        cases = [('tools.bash({command: "git status --short; zig build"})', 'git status'),
                 ("tools.bash({command: 'echo 你好'})", 'echo 你好'),
                 ('tools.bash({command: `zig build`})', 'zig build'),
                 ('tools.bash({command: "A=1 /usr/bin/git diff --stat"})', 'git diff'),
                 ('tools.bash({command: "pwd"})', 'pwd'),
                 ('tools.bash({command: cmd})', None),
                 ('tools.bash({command: "git " + subcommand})', None),
                 ('tools.bash({command: `git ${subcommand}`})', None),
                 ('tools.bash({command: "git $SUBCOMMAND"})', None),
                 ('tools.bash({command: "git status"}); tools.bash({command: dynamic})', None),
                 ('tools.bash({command: "echo \"broken"})', None)]
        for code, expected in cases:
            with self.subTest(code=code):
                self.assertEqual(stats.bash_timing_group(code), expected)
        timing = stats.Timing()
        result = dict(tool_call_id='r', run_ms=30)
        source = {'r': 'tools.bash({command: "git status"})'}
        timing.add(dict(run_results=[result], calls=[
            dict(name='bash', start_ms=0, end_ms=10, run_index=0),
            dict(name='bash', start_ms=10, end_ms=30, run_index=0),
            dict(name='bash', start_ms=0, end_ms=1, run_index=99),
            dict(name='bash', start_ms=0, end_ms=2, run_index=None)]), source)
        report = timing.report()
        self.assertEqual(report['bash']['matched_calls'], 0)
        self.assertEqual(report['bash']['unmatched_calls'], 4)
        self.assertEqual(report['tools']['bash']['count'], 4)

    def test_bash_timing_top10_by_total_duration(self):
        timing = stats.Timing()
        for i in range(12):
            timing.add(dict(run_results=[dict(tool_call_id='r')], calls=[
                dict(name='bash', start_ms=0, end_ms=i, run_index=0)]),
                {'r': 'tools.bash({command: ' + json.dumps('git cmd' + str(i)) + '})'})
        report = timing.report()['bash']
        self.assertEqual(report['matched_calls'], 12)
        self.assertEqual(len(report['top10']), 10)
        self.assertEqual(report['top10'][0]['command'], 'git cmd11')
        self.assertEqual(report['top10'][-1]['command'], 'git cmd2')
        timing.add(dict(run_results=[dict(tool_call_id='r')], calls=[
            dict(name='bash', start_ms=10, end_ms=30, run_index=0)]),
            {'r': 'tools.bash({command: "git cmd11 --extra"})'})
        self.assertEqual(timing.report()['bash']['top10'][0],
                         dict(command='git cmd11', count=2, total_ms=31, median_ms=15.5))

    def test_static_commands_skip_heredoc_and_redirects(self):
        command = "python3 - <<'PY'\nprint(1); not_a_command()\nPY\ngit status 2>&1; zig build"
        code = 'await tools.bash({timeout_ms: 100, command: ' + json.dumps(command) + '})'
        self.assertEqual(list(stats.commands(code)), ['python3', 'git', 'zig'])
        self.assertEqual(list(stats.commands("tools.bash({command: 'echo 你好'})")), ['echo'])


if __name__ == '__main__':
    unittest.main()
