#!/usr/bin/env python3
"""Read-only statistics for nib's append-only session logs (standard library only)."""
import argparse
import ast
from collections import Counter
from datetime import date, datetime
import json
import os
from pathlib import Path
import re
import shlex
from statistics import median
import warnings


TOKEN_KEYS = ('prompt_tokens', 'completion_tokens', 'prompt_cache_hit_tokens')
ERRORS = {
    'js_syntax': r'SyntaxError',
    'command_not_found': r'''["']?exit_code["']?\s*:\s*127\b''',
    'run_timeout': r'run (?:timed out|timeout)',
    'subagent': r'subagent(?::| stopped| failed|.*timeout)|AgentFailed|InvalidAgentOutput|MissingAgentResult',
    'tool_arguments': r'expected \{|arguments must be a JSON object',
    'denied': r'refused by nib|CredentialAccessDenied',
    'interrupted': r'\[interrupted(?: by user|: process terminated)\]|Error: run canceled',
    'provider_failure': None,
    'other_failure': None,
}
TOOL_CALL = re.compile(r'\btools\.([A-Za-z_$][\w$]*)\s*\(')
BASH_COMMAND = re.compile(r'''\btools\.bash\s*\(\s*\{[^{}]*?(?:["']?command["']?)\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`)''', re.S)


def number(value):
    return type(value) is int and value >= 0


def without_heredocs(command):
    lines = []
    delimiters = []
    for line in command.splitlines():
        if delimiters:
            if line.strip() == delimiters[0]:
                delimiters.pop(0)
            continue
        lines.append(line)
        delimiters.extend(m[1] for m in re.finditer(r'''<<-?\s*['"]?([A-Za-z_][\w]*)['"]?''', line))
    return '\n'.join(lines)


def diagnostics(text):
    for line in text.splitlines():
        line = line.removeprefix('result: ').strip()
        try:
            value = json.loads(line)
        except (ValueError, RecursionError):
            value = line
        if isinstance(value, dict):
            if 'exit_code' in value:
                if type(value['exit_code']) is int and value['exit_code'] != 0:
                    yield 'exit_code: ' + str(value['exit_code']) + ' ' + str(value.get('output', ''))[-160:]
                # A shell may return 0 after an earlier Python failure.
                for output_line in str(value.get('output', '')).splitlines():
                    if re.match(r'^\s*SyntaxError:', output_line):
                        yield output_line.strip()
            continue
        if not isinstance(value, str):
            continue
        if re.match(r'^(?:(?:\w*Error|error):|subagent(?::| stopped)|expected \{|CredentialAccessDenied|refused by nib|arguments must be)', value):
            yield value


def commands(code):
    for match in BASH_COMMAND.finditer(code):
        literal = match[1]
        try:
            if literal.startswith('`'):
                if '${' in literal:
                    continue
                command = literal[1:-1]
            else:
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', (SyntaxWarning, DeprecationWarning))
                    command = json.loads(literal) if literal.startswith('"') else ast.literal_eval(literal)
            lexer = shlex.shlex(without_heredocs(command).replace('\n', ';'), posix=True, punctuation_chars=';&|()')
            lexer.whitespace_split = True
            tokens = list(lexer)
        except (ValueError, SyntaxError):
            continue
        start = True
        for token in tokens:
            if token and all(c in ';&|()' for c in token):
                start = True
            elif start:
                if re.match(r'^[A-Za-z_][\w]*=', token) or token in ('env', 'sudo', 'command', 'exec', '!'):
                    continue
                if not token.isdecimal() and not re.match(r'^\d*[<>]', token):
                    yield Path(token).name
                start = False


def distribution(values):
    values = sorted(values)
    return dict(samples=len(values), median=median(values) if values else None,
                p90=values[(9 * len(values) + 9) // 10 - 1] if values else None)


def bash_timing_group(code):
    if TOOL_CALL.findall(code).count('bash') != 1:
        return None
    matches = list(BASH_COMMAND.finditer(code))
    if len(matches) != 1:
        return None
    match = matches[0]
    if not re.match(r'\s*[,}]', code[match.end():]):
        return None
    literal = match[1]
    try:
        if literal.startswith('`'):
            if '${' in literal or '\\' in literal:
                return None
            command = literal[1:-1]
        else:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', (SyntaxWarning, DeprecationWarning))
                command = json.loads(literal) if literal.startswith('"') else ast.literal_eval(literal)
        lexer = shlex.shlex(without_heredocs(command).replace('\n', ';'), posix=True, punctuation_chars=';&|()')
        lexer.whitespace_split = True
        words = []
        for token in lexer:
            if token and all(c in ';&|()' for c in token):
                break
            if not words and (re.match(r'^[A-Za-z_][\w]*=', token) or token in ('env', 'sudo', 'command', 'exec', '!')):
                continue
            if re.search(r'[$`<>]', token):
                return None
            words.append(Path(token).name if not words else token)
            if len(words) == 2:
                break
        return ' '.join(words) or None
    except (ValueError, SyntaxError):
        return None


class Timing:
    def __init__(self):
        self.values = {key: [] for key in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms',
                                         'first_token_ms', 'code_first_ms', 'code_span_ms', 'attempts')}
        self.tools = {}
        self.bash = {}
        self.calls_steps = self.calls_omitted = self.bash_unmatched = 0

    def add(self, record, sources):
        for key in ('model_ms', 'run_ms', 'first_token_ms', 'attempts'):
            if number(record.get(key)):
                self.values[key].append(record[key])
        if number(record.get('ms')):
            self.values['step_ms'].append(record['ms'])
        code = record.get('code')
        for item in code if isinstance(code, list) else []:
            if not isinstance(item, dict):
                continue
            first, last = item.get('first_ms'), item.get('last_ms')
            if number(first):
                self.values['code_first_ms'].append(first)
                if number(last) and last >= first:
                    self.values['code_span_ms'].append(last - first)
        results = record.get('run_results')
        results = results if isinstance(results, list) else []
        for result in results:
            if isinstance(result, dict) and number(result.get('run_ms')):
                self.values['run_result_ms'].append(result['run_ms'])
        if number(record.get('calls_omitted')):
            self.calls_omitted += record['calls_omitted']
        calls = record.get('calls')
        if not isinstance(calls, list):
            return
        self.calls_steps += 1
        bash_per_run = Counter(c.get('run_index') for c in calls
                               if isinstance(c, dict) and c.get('name') == 'bash' and number(c.get('run_index')))
        for call in calls:
            if not isinstance(call, dict):
                continue
            name, start, end = call.get('name'), call.get('start_ms'), call.get('end_ms')
            if not isinstance(name, str) or not name or not number(start) or not number(end) or end < start:
                continue
            duration = end - start
            self.tools.setdefault(name, []).append(duration)
            if name != 'bash':
                continue
            index = call.get('run_index')
            group = None
            if number(index) and index < len(results) and bash_per_run[index] == 1:
                result = results[index]
                call_id = result.get('tool_call_id') if isinstance(result, dict) else None
                source = sources.get(call_id) if isinstance(call_id, str) else None
                if source is not None:
                    group = bash_timing_group(source)
            if group is None:
                self.bash_unmatched += 1
            else:
                self.bash.setdefault(group, []).append(duration)

    def report(self):
        def tool_summary(values):
            return dict(count=len(values), total_ms=sum(values), median_ms=median(values))
        spans = self.values['code_span_ms']
        streamed = sum(span > 50 for span in spans)
        return dict({key: distribution(values) for key, values in self.values.items()},
                    calls_steps=self.calls_steps, calls_omitted=self.calls_omitted,
                    tools={name: tool_summary(values) for name, values in sorted(self.tools.items())},
                    streaming=dict(samples=len(spans), over_50_ms=streamed,
                                   ratio=streamed / len(spans) if spans else None),
                    bash=dict(heuristic=True, matched_calls=sum(map(len, self.bash.values())),
                              unmatched_calls=self.bash_unmatched,
                              top10=[dict(command=name, **tool_summary(values)) for name, values in
                                     sorted(self.bash.items(), key=lambda p: (-sum(p[1]), p[0]))[:10]]))


def records(path):
    try:
        with path.open(encoding='utf-8', errors='replace') as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if not isinstance(record, dict) or record.get('repair'):
                    continue
                diagnostic = record.get('diagnostic')
                if isinstance(diagnostic, dict) and isinstance(diagnostic.get('message'), str):
                    yield record
                    continue
                messages = record.get('messages')
                if not number(record.get('from')) or not isinstance(messages, list) or not messages:
                    continue
                if not all(isinstance(m, dict) and m.get('role') in ('system', 'user', 'assistant', 'tool')
                           and (m.get('content') is None or isinstance(m['content'], str))
                           and (m.get('tool_calls') is None or isinstance(m['tool_calls'], list)) for m in messages):
                    continue
                yield record
    except OSError:
        return


def summarize(paths, since=None, cwd=None):
    totals = dict(sessions=0, root_sessions=0, child_sessions=0, turns=0, steps=0, runs=0,
                  runs_failed=0, runs_with_status=0, runs_unknown=0, steps_with_usage=0,
                  steps_with_ms=0, timed_turns=0)
    cutoff_ms = int(datetime.combine(since, datetime.min.time()).timestamp() * 1000) if since else None
    time_filter = dict(selected_records_with_at=0, selected_records_using_mtime=0,
                       selected_steps_using_mtime=0)
    usage = dict.fromkeys(TOKEN_KEYS, 0)
    tool_counts, bash_counts = Counter(), Counter()
    timing = Timing()
    errors = {name: {'count': 0, 'examples': []} for name in ERRORS}
    slowest, turn_steps, turn_times = [], [], []

    def error(name, text, session):
        item = errors[name]
        item['count'] += 1
        example = {'session_id': session[:8], 'text': ' '.join(text.split())[:180]}
        if len(item['examples']) < 2 and example not in item['examples']:
            item['examples'].append(example)

    for path in paths:
        try:
            mtime_ms = path.stat().st_mtime * 1000
        except OSError:
            continue
        log = iter(records(path))
        header = next(log, None)
        if header is None or not header.get('messages') or header['messages'][0]['role'] != 'system':
            continue
        if cwd is not None and (not isinstance(header.get('cwd'), str) or
                                Path(header['cwd']).expanduser().resolve() != cwd):
            continue
        def selected(record):
            at = record.get('at')
            return cutoff_ms is None or (at if number(at) else mtime_ms) >= cutoff_ms

        session_selected = selected(header)
        length = header['from'] + len(header['messages'])
        current = None
        session_step = 0

        def finish_turn():
            if current is not None and current['selected']:
                totals['turns'] += 1
                turn_steps.append(current['steps'])
                if (current['complete'] and current['steps'] and
                        current['steps'] == current['full_steps'] == current['timed']):
                    turn_times.append(current['ms'])

        for record in log:
            include = selected(record)
            has_at = number(record.get('at'))
            diagnostic = isinstance(record.get('diagnostic'), dict)
            if not diagnostic:
                messages = record['messages']
                replacement = record['from'] < length
                length = record['from'] + len(messages)
                if replacement:
                    continue
            if include:
                session_selected = True
                time_filter['selected_records_with_at' if has_at else 'selected_records_using_mtime'] += 1
            if diagnostic:
                if include:
                    error('provider_failure', record['diagnostic']['message'], path.stem)
                continue
            if any(m['role'] == 'user' for m in messages):
                finish_turn()
                current = dict(steps=0, full_steps=0, timed=0, ms=0, complete=False, selected=False)
            if current is not None and include:
                current['selected'] = True
            interrupted = False
            for m in messages:
                if m['role'] == 'assistant' and re.search(r'\[interrupted(?: by user|: process terminated)\]\s*$', m.get('content') or ''):
                    if include:
                        error('interrupted', m['content'], path.stem)
                    interrupted = True
            if not any(m['role'] == 'assistant' for m in messages) or interrupted:
                continue
            session_step += 1
            if current is not None:
                current['full_steps'] += 1
                current['complete'] = any(m['role'] == 'assistant' and not m.get('tool_calls') for m in messages)
            if not include:
                continue
            totals['steps'] += 1
            if not has_at:
                time_filter['selected_steps_using_mtime'] += 1
            if current is not None:
                current['steps'] += 1
            u = record.get('usage')
            if isinstance(u, dict) and all(number(u.get(k)) for k in TOKEN_KEYS):
                totals['steps_with_usage'] += 1
                for key in TOKEN_KEYS:
                    usage[key] += u[key]
            ms = record.get('ms')
            if number(ms):
                totals['steps_with_ms'] += 1
                if current is not None:
                    current['timed'] += 1
                    current['ms'] += ms
                slowest.append({'session_id': path.stem[:8], 'step': session_step, 'ms': ms})
                slowest.sort(key=lambda s: s['ms'], reverse=True)
                del slowest[5:]
            statuses = record.get('run_results')
            statuses = {r['tool_call_id']: r['ok'] for r in statuses
                        if isinstance(r, dict) and isinstance(r.get('tool_call_id'), str)
                        and type(r.get('ok')) is bool} if isinstance(statuses, list) else {}
            outputs = {m['tool_call_id']: m.get('content') or '' for m in messages
                       if m['role'] == 'tool' and isinstance(m.get('tool_call_id'), str)}
            sources = {}
            for m in messages:
                for call in m.get('tool_calls') or []:
                    if not isinstance(call, dict) or not isinstance(call.get('function'), dict):
                        continue
                    function = call['function']
                    if function.get('name') != 'run':
                        continue
                    totals['runs'] += 1
                    call_id = call.get('id')
                    ok = statuses.get(call_id) if isinstance(call_id, str) else None
                    if ok is not None:
                        totals['runs_with_status'] += 1
                        totals['runs_failed'] += not ok
                    try:
                        args = json.loads(function.get('arguments', ''))
                    except (ValueError, TypeError, RecursionError):
                        args = None
                    code = args.get('code') if isinstance(args, dict) else None
                    if isinstance(code, str):
                        if isinstance(call_id, str):
                            sources[call_id] = code
                        tool_counts.update(TOOL_CALL.findall(code))
                        bash_counts.update(commands(code))
                    text = outputs.get(call_id, '') if isinstance(call_id, str) else ''
                    candidates = list(diagnostics(text))
                    matched = False
                    for name, pattern in ERRORS.items():
                        example = next((s for s in candidates if pattern and re.search(pattern, s, re.I)), None)
                        if example is not None:
                            error(name, example, path.stem)
                            matched = True
                    if not matched and (ok is False or candidates):
                        error('other_failure', candidates[0] if candidates else text, path.stem)
            timing.add(record, sources)
        finish_turn()
        if session_selected:
            totals['sessions'] += 1
            totals['child_sessions' if header.get('parent_session_id') else 'root_sessions'] += 1
    totals['runs_unknown'] = totals['runs'] - totals['runs_with_status']
    totals['run_failure_rate'] = totals['runs_failed'] / totals['runs_with_status'] if totals['runs_with_status'] else None
    totals['avg_steps_per_turn'] = sum(turn_steps) / len(turn_steps) if turn_steps else None
    totals['timed_turns'] = len(turn_times)
    totals['avg_turn_ms'] = sum(turn_times) / len(turn_times) if turn_times else None
    usage['total_tokens'] = usage['prompt_tokens'] + usage['completion_tokens']
    usage['cache_hit_rate'] = usage['prompt_cache_hit_tokens'] / usage['prompt_tokens'] if usage['prompt_tokens'] else None
    return {'overall': totals, 'usage': usage, 'time_filter': time_filter, 'tools': dict(sorted(tool_counts.items())),
            'bash_top10': [{'command': k, 'count': v} for k, v in sorted(bash_counts.items(), key=lambda p: (-p[1], p[0]))[:10]],
            'errors': errors, 'slowest_steps': slowest, 'timing': timing.report(),
            'notes': ['失败率仅统计显式 run_results；旧日志的状态为未知。',
                      'Step/Run、用量和错误只统计入选记录；token 为有效 usage 的 prompt + completion，不重复加缓存命中，缓存命中率以 prompt 为分母，缺失 usage 不补零。',
                      '错误按 Run 的诊断特征计数，类别可重叠；另计打断记录和未提交的 provider 失败诊断；忽略源码/read 正文，被捕获的工具错误不一定导致 Run 失败。',
                      '工具和 bash 命令数是静态估计，不是运行时调用次数；动态 JS/shell 可能漏计。',
                      'Turn 数包含区间内有非诊断记录的 Turn，平均步数只计入选 Step；耗时只平均已结束、全部 Step 入选且都有 ms 的 Turn，不含压缩、未完成请求和用户停顿。',
                      '--since 按记录 at（Unix 毫秒）筛选，含指定日期的本地午夜；缺失或无效 at 回退到文件修改时间。会话数包含 header 或非替换记录入选的会话。',
                      '时间来源计数只含入选的非 header、非修复、非压缩替换记录（含诊断和打断）；步骤回退数只含完整 Step。',
                      f"时间来源：{time_filter['selected_records_with_at']} 条按 at，{time_filter['selected_records_using_mtime']} 条回退文件时间（其中 {time_filter['selected_steps_using_mtime']} 个完整 Step）。",
                      '计时各项 samples 只含有效的显式字段；缺失不补零。median 为中位数，p90 使用 nearest-rank。',
                      'first_token_ms is onData first stream activity（可能为 SSE heartbeat），不是独立 token 通道。',
                      'model_ms 含 provider 重试/退避；run_ms 是每 Step 的 Run 总耗时，run_result_ms 是单 Run 耗时。',
                      'code_first_ms 是 Step 开始至首段代码的等待；code_span_ms 是 last_ms-first_ms；streaming 比例为 span > 50 ms 的样本比例。',
                      '工具计时来自运行时 calls（含失败）；总耗时可能因并行重叠，calls_omitted 是日志上限丢弃数。',
                      'bash 计时 Top 10 按总耗时排序，只用保存的 JS 字面量首两个 shell 单词启发式分组；多调用/动态调用不强行关联，列为 unmatched；不是 shell 子命令耗时。']}


def text_report(report):
    t, u = report['overall'], report['usage']
    def fmt(value, suffix=''):
        return 'n/a' if value is None else f'{value:.2f}{suffix}'
    def pct(value):
        return fmt(None if value is None else 100 * value, '%')
    token_total = str(u['total_tokens']) if t['steps_with_usage'] else 'n/a'
    lines = [f"会话 {t['sessions']}（根 {t['root_sessions']} / 子 {t['child_sessions']}）；Turn {t['turns']}；Step {t['steps']}；Run {t['runs']}",
             f"Run 失败 {t['runs_failed']}/{t['runs_with_status']} = {pct(t['run_failure_rate'])}（状态未知 {t['runs_unknown']}）",
             f"Token {token_total}（prompt {u['prompt_tokens']} / completion {u['completion_tokens']}）；缓存命中 {pct(u['cache_hit_rate'])}；usage 覆盖 {t['steps_with_usage']}/{t['steps']} Step",
             f"每 Turn 平均 {fmt(t['avg_steps_per_turn'])} Step；平均耗时 {fmt(t['avg_turn_ms'], ' ms')}（完整计时 {t['timed_turns']}/{t['turns']} Turn，{t['steps_with_ms']} Step）",
             '工具（静态调用点）：' + (', '.join(f'{k} {v}' for k, v in report['tools'].items()) or '无'),
             'bash 命令 Top 10：' + (', '.join(f"{v['command']} {v['count']}" for v in report['bash_top10']) or '无'), '错误分类：']
    for name, item in report['errors'].items():
        lines.append(f"  {name}: {item['count']}")
        lines.extend(f"    [{e['session_id']}] {e['text']}" for e in item['examples'])
    lines.append('最慢的 5 个 Step：')
    lines.extend(f"  {s['session_id']}  {s['ms']} ms" for s in report['slowest_steps'])
    if not report['slowest_steps']:
        lines.append('  无计时记录')
    timing = report['timing']
    lines.append('耗时构成 / 计时 Timing（ms，attempts 为次数；缺失字段不补零）：')
    for name in ('step_ms', 'model_ms', 'run_ms', 'run_result_ms', 'first_token_ms', 'code_first_ms', 'code_span_ms', 'attempts'):
        item = timing[name]
        lines.append(f"  {name}: samples={item['samples']} median={fmt(item['median'])} p90={fmt(item['p90'])}")
    streaming = timing['streaming']
    lines.append(f"  code streaming (last-first > 50 ms): {streaming['over_50_ms']}/{streaming['samples']} = {pct(streaming['ratio'])}")
    lines.append(f"  工具运行时计时（calls Step={timing['calls_steps']}, omitted={timing['calls_omitted']}）：")
    for name, item in timing['tools'].items():
        lines.append(f"    {name}: count={item['count']} total={item['total_ms']} ms median={fmt(item['median_ms'])} ms")
    if not timing['tools']:
        lines.append('    无计时记录')
    bash = timing['bash']
    lines.append(f"  bash 计时 Top 10（heuristic 字面量首两个单词；matched={bash['matched_calls']}, unmatched={bash['unmatched_calls']}）：")
    for item in bash['top10']:
        lines.append(f"    {item['command']}: count={item['count']} total={item['total_ms']} ms median={fmt(item['median_ms'])} ms")
    if not bash['top10']:
        lines.append('    无可匹配计时记录')
    lines.extend(['口径：'] + ['  ' + note for note in report['notes']])
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path, help='session JSONL files or directories')
    parser.add_argument('--since', type=date.fromisoformat, metavar='YYYY-MM-DD', help='record date, inclusive, local time; legacy records fall back to file modification time')
    parser.add_argument('--cwd', type=Path, help='exact session working directory')
    parser.add_argument('--json', action='store_true', help='emit JSON instead of text')
    args = parser.parse_args()
    inputs = args.paths or [Path(os.environ.get('NIB_HOME', '~/.nib')).expanduser() / 'sessions']
    paths = set()
    for path in inputs:
        path = path.expanduser()
        if path.is_dir():
            paths.update(p.resolve() for p in path.glob('*.jsonl') if p.is_file())
        elif path.is_file():
            paths.add(path.resolve())
    report = summarize(sorted(paths), args.since, args.cwd.expanduser().resolve() if args.cwd else None)
    print(json.dumps(report, ensure_ascii=False, indent=2) if args.json else text_report(report))


if __name__ == '__main__':
    main()
