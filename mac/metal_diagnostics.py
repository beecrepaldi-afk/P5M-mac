#!/usr/bin/env python3
"""Collect existing macOS Metal history and export a P5M-only numeric report."""
import argparse
import datetime as dt
import json
import math
import platform
import re
import subprocess
import sys
from pathlib import Path

PROCESS_NAMES = frozenset(('chiaki', 'P5M', 'p5m'))
METRICS = {
    'gpu_ms': ('Presented Frame Stats', 'On-GPU Walltime Stats'),
    'render_to_completion_ms': ('Presented Frame Stats', 'End-to-end Walltime Stats (Total)'),
    'gpu_done_to_completion_ms': ('Presented Frame Stats', 'GPU Done-to-Completion Walltime Stats'),
    'drawable_wait_ms': ('Presented Frame Stats', 'Next Drawable Wait Walltime Stats'),
    'on_glass_interval_ms': (None, 'Frame-On-Glass Interval Stats'),
}


def date(value):
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError('Dates must include a timezone, for example -03:00 or Z.')
    return parsed.astimezone(dt.timezone.utc)


def number(value):
    # Nunca copie campos arbitrários do trace para o relatório compartilhável.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError('Invalid numeric metric in timeline.')
    if not math.isfinite(value) or value < 0:
        raise ValueError('Invalid numeric metric in timeline.')
    return value


def summarize(data, start, end):
    if end <= start:
        raise ValueError('End must be later than start.')
    if not isinstance(data, list):
        raise ValueError('Expected the metalperftrace overview JSON process list.')
    groups = []
    for process in data:
        if process.get('Process') not in PROCESS_NAMES:
            continue
        for layer in process.get('Layers', []):
            rows = []
            boundary_rows = 0
            for row in layer.get('Stats Timeline', []):
                a, b = date(row['Start Date']), date(row['End Date'])
                if b <= start or a >= end:
                    continue
                # Não invente contagens fracionárias no segundo cortado pela janela.
                if a < start or b > end:
                    boundary_rows += 1
                    continue
                if b <= a:
                    raise ValueError('Invalid timeline interval.')
                rows.append(row)
            if not rows:
                continue
            duration = sum(number(r['Total Duration (sec)']) for r in rows)
            if duration <= 0:
                continue
            presented = sum(number(r['Presented Frame Stats']['Frame Count']) for r in rows)
            skipped = sum(number(r['Skipped Frame Stats']['Frame Count']) for r in rows)
            item = {
                'sample_seconds': duration, 'samples': len(rows),
                'excluded_boundary_samples': boundary_rows,
                'presented_frames': presented, 'presented_fps': presented / duration,
                'skipped_frames': skipped, 'skipped_fps': skipped / duration,
                'timeline': [],
            }
            for row in rows:
                seconds = number(row['Total Duration (sec)'])
                item['timeline'].append({
                    'offset_seconds': (date(row['Start Date']) - start).total_seconds(),
                    'duration_seconds': seconds,
                    'presented_frames': number(row['Presented Frame Stats']['Frame Count']),
                    'presented_fps': number(row['Presented Frame Stats']['Frame Count']) / seconds if seconds else None,
                    'skipped_frames': number(row['Skipped Frame Stats']['Frame Count']),
                })
            for label, (container, key) in METRICS.items():
                values = [(r[container] if container else r).get(key, {}) for r in rows]
                count = sum(number(v.get('Count', 0)) for v in values)
                item[label] = {
                    'samples': count,
                    'mean': sum(number(v.get('Total (ms)', 0)) for v in values) / count if count else None,
                    'max': max((number(v.get('Max (ms)', 0)) for v in values if v.get('Count', 0)), default=None),
                }
            groups.append(item)
    if not groups:
        raise ValueError('No complete P5M timeline samples in the requested interval.')
    # Grupos separados: dois processos ou camadas não viram um FPS somado fictício.
    return {'schema_version': 1, 'requested_seconds': (end - start).total_seconds(), 'groups': groups}


def tool():
    if platform.system() != 'Darwin' or int(platform.mac_ver()[0].split('.')[0]) < 27:
        raise ValueError('Collection requires macOS 27 or later.')
    executable = Path('/usr/bin/metalperftrace')
    if not executable.is_file():
        raise ValueError('metalperftrace is unavailable on this system.')
    return str(executable)


def run_tool(arguments):
    result = subprocess.run([tool(), *arguments], capture_output=True, text=True, check=False)
    if result.returncode:
        # stderr pode conter nomes de processos e caminhos; preserve-o só localmente.
        raise ValueError('metalperftrace failed. Run the documented command locally for details.')
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    collect = sub.add_parser('collect', help='Collect already recorded OS history; does not start a session.')
    collect.add_argument('--last', required=True, help='History duration, such as 5m or 1h.')
    collect.add_argument('--directory', required=True, type=Path)
    analyze = sub.add_parser('analyze', help='Analyze only an explicitly chosen visible interval.')
    source = analyze.add_mutually_exclusive_group(required=True)
    source.add_argument('--timeline', type=Path, help='Existing overview JSON with Stats Timeline.')
    source.add_argument('--trace', type=Path, help='Local .atrc trace; invokes overview.')
    analyze.add_argument('--start', required=True, help='ISO date with timezone.')
    analyze.add_argument('--end', required=True, help='ISO date with timezone.')
    analyze.add_argument('--output', required=True, type=Path, help='Sanitized numeric JSON report.')
    args = parser.parse_args(argv)
    try:
        if args.command == 'collect':
            if not re.fullmatch(r'[1-9][0-9]*[smhd]', args.last):
                raise ValueError('History duration must be a positive integer followed by s, m, h or d.')
            run_tool(['collect', '--last', args.last, '--json', str(args.directory)])
            print('Collected existing history locally. Keep raw traces private.')
            return 0
        start, end = date(args.start), date(args.end)
        if end <= start:
            raise ValueError('End must be later than start.')
        if args.timeline:
            raw = args.timeline.read_text()
        else:
            raw = run_tool(['overview', '--json', '--json-include-timeline', '--predicate',
                            'processName == "chiaki" OR processName == "P5M" OR processName == "p5m"',
                            str(args.trace)])
        report = summarize(json.loads(raw), start, end)
        args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
        print('Saved P5M-only numeric report. Groups remain separate; no process or layer IDs exported.')
        return 0
    except (ValueError, OSError, KeyError, TypeError, AttributeError):
        # Nenhum erro imprime caminho, linha bruta ou identificador do usuário.
        print('Unable to produce report. Check tool availability, timezone, interval and timeline schema.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
