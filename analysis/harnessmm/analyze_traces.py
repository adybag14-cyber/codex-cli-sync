"""Separate complete provider usage, tool execution and local substitutions."""
from __future__ import annotations
import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re


def rows(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]


def analyze(root, arm):
    folder = root / 'trials' / arm
    status = json.loads((folder / 'status.json').read_text())
    hooks = rows(folder / 'model-requests.jsonl')
    pre = [row for row in hooks if row.get('hook_event_name') == 'PreModelRequest']
    post = [row for row in hooks if row.get('hook_event_name') == 'PostModelRequest']
    usage_rows = [row['token_usage'] for row in post if isinstance(row.get('token_usage'), dict)]
    totals = Counter()
    for usage in usage_rows:
        totals.update({key: value for key, value in usage.items() if isinstance(value, int)})
    rollouts = list((folder / 'home/sessions').rglob('*.jsonl'))
    timeline = []
    call_ids = set()
    calls = []
    outputs = {}
    events = rows(folder / 'events.jsonl')
    cli_usage = [row.get('usage') for row in events if row.get('type') == 'turn.completed']
    for rollout in rollouts:
        for row in rows(rollout):
            payload = row.get('payload', {})
            kind = payload.get('type')
            if row.get('type') == 'response_item' and kind in ('function_call', 'custom_tool_call'):
                call_id = payload.get('call_id')
                if call_id in call_ids:
                    continue
                call_ids.add(call_id)
                call = {'timestamp': row.get('timestamp'), 'call_id': call_id, 'name': payload.get('name'),
                        'native_reuse': bool(call_id and call_id.startswith('harnessmm_')),
                        'arguments': payload.get('arguments', payload.get('input'))}
                calls.append(call)
                timeline.append(call)
            if row.get('type') == 'response_item' and kind in ('function_call_output', 'custom_tool_call_output'):
                outputs[payload.get('call_id')] = payload.get('output')
    graph_calls = [call for call in calls if call['name'] == 'harnessmm_plan']
    reused = [call for call in calls if call['native_reuse']]
    graphs = Counter()
    for call in reused:
        match = re.fullmatch(r'harnessmm_(.+)_(\d+)', call['call_id'])
        if match:
            graphs[match[1]] += 1
    summary = {
        'arm': arm, 'state': status['state'], 'exit_code': status.get('exit_code'),
        'elapsed_seconds': status['elapsed_seconds'], 'binary_sha256': status['binary_sha256'],
        'model_request_attempts': len(pre), 'model_request_outcomes': len(post),
        'provider_statuses': dict(Counter(row.get('status', 'unknown') for row in post)),
        'requests_with_usage': len(usage_rows), 'requests_without_usage': len(post)-len(usage_rows),
        'complete_usage_known': len(pre) == len(post) == len(usage_rows),
        'provider_usage_sum': dict(totals), 'cli_turn_usage': cli_usage,
        'tool_calls': len(calls), 'tool_names': dict(Counter(call['name'] for call in calls)),
        'plan_authorship_calls': len(graph_calls), 'native_reused_actions': len(reused),
        'native_reused_actions_with_receipts': sum(call['call_id'] in outputs for call in reused),
        'graphs_executed': len(graphs), 'second_and_later_reuses': sum(max(0, count-1) for count in graphs.values()),
        'rollouts': [{'path': str(path), 'sha256': hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()} for path in rollouts],
    }
    (folder / 'tool-timeline.json').write_text(json.dumps(timeline, indent=2), encoding='utf-8')
    (folder / 'metrics.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    result = {arm: analyze(args.root, arm) for arm in ['baseline', 'harnessmm']}
    (args.root / 'comparison.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
