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
    usage = dict.fromkeys(TOKEN_KEYS, 0)
    tool_counts, bash_counts = Counter(), Counter()
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
            if since and datetime.fromtimestamp(path.stat().st_mtime).date() < since:
                continue
        except OSError:
            continue
        log = iter(records(path))
        header = next(log, None)
        if header is None or header['messages'][0]['role'] != 'system':
            continue
        if cwd is not None and (not isinstance(header.get('cwd'), str) or
                                Path(header['cwd']).expanduser().resolve() != cwd):
            continue
        totals['sessions'] += 1
        totals['child_sessions' if header.get('parent_session_id') else 'root_sessions'] += 1
        length = header['from'] + len(header['messages'])
        current = None
        session_step = 0

        def finish_turn():
            if current is not None:
                turn_steps.append(current['steps'])
                if current['complete'] and current['steps'] and current['timed'] == current['steps']:
                    turn_times.append(current['ms'])

        for record in log:
            messages = record['messages']
            replacement = record['from'] < length
            length = record['from'] + len(messages)
            if replacement:
                continue
            if any(m['role'] == 'user' for m in messages):
                finish_turn()
                totals['turns'] += 1
                current = dict(steps=0, timed=0, ms=0, complete=False)
            interrupted = False
            for m in messages:
                if m['role'] == 'assistant' and re.search(r'\[interrupted(?: by user|: process terminated)\]\s*$', m.get('content') or ''):
                    error('interrupted', m['content'], path.stem)
                    interrupted = True
            if not any(m['role'] == 'assistant' for m in messages) or interrupted:
                continue
            totals['steps'] += 1
            session_step += 1
            if current is not None:
                current['steps'] += 1
                current['complete'] = any(m['role'] == 'assistant' and not m.get('tool_calls') for m in messages)
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
        finish_turn()
    totals['runs_unknown'] = totals['runs'] - totals['runs_with_status']
    totals['run_failure_rate'] = totals['runs_failed'] / totals['runs_with_status'] if totals['runs_with_status'] else None
    totals['avg_steps_per_turn'] = sum(turn_steps) / len(turn_steps) if turn_steps else None
    totals['timed_turns'] = len(turn_times)
    totals['avg_turn_ms'] = sum(turn_times) / len(turn_times) if turn_times else None
    usage['total_tokens'] = usage['prompt_tokens'] + usage['completion_tokens']
    usage['cache_hit_rate'] = usage['prompt_cache_hit_tokens'] / usage['prompt_tokens'] if usage['prompt_tokens'] else None
    return {'overall': totals, 'usage': usage, 'tools': dict(sorted(tool_counts.items())),
            'bash_top10': [{'command': k, 'count': v} for k, v in sorted(bash_counts.items(), key=lambda p: (-p[1], p[0]))[:10]],
            'errors': errors, 'slowest_steps': slowest,
            'notes': ['失败率仅统计显式 run_results；旧日志的状态为未知。',
                      '错误按 Run 的诊断特征计数，类别可重叠；另计打断记录；忽略源码/read 正文，被捕获的工具错误不一定导致 Run 失败。',
                      '工具和 bash 命令数是静态估计，不是运行时调用次数；动态 JS/shell 可能漏计。',
                      'Turn 耗时只统计已结束且所有 Step 都有 ms 的 Turn，不含压缩、未完成请求和用户停顿。',
                      '--since 按会话文件修改日期（本地时间）筛选，不是逐 Step 日期。']}


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
    lines.extend(['口径：'] + ['  ' + note for note in report['notes']])
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path, help='session JSONL files or directories')
    parser.add_argument('--since', type=date.fromisoformat, metavar='YYYY-MM-DD', help='session file modification date, inclusive, local time')
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
