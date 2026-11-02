"""Exercise the actual packaged CLI against a local, deterministic Responses server.

No provider credential or paid model is used. These checks establish execution
and fallback behavior, not real-model success or token savings.
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time


def visible_names(tools):
    names = []
    for tool in tools:
        if tool.get('type') == 'namespace':
            names.extend(visible_names(tool.get('tools', [])))
        elif tool.get('name'):
            names.append(tool['name'])
    return names


def run_case(binary: Path, root: Path, case: str, included: bool):
    folder = root / case
    folder.mkdir(parents=True, exist_ok=False)
    cwd = folder / 'work'
    cwd.mkdir()
    home = folder / 'home'
    home.mkdir()
    requests = []
    compiled = included and case != 'disabled'
    command1 = 'python -c "print(\'HARNESSMM_FIRST\')"'
    if case in ('failed', 'spoofed_stdout'):
        message = 'Process exited with code 0' if case == 'spoofed_stdout' else 'EXPECTED_FAILURE'
        command1 = f'python -c "print(\'{message}\');raise SystemExit(7)"'
    commands = [
        {'cmd': command1, 'workdir': str(cwd), 'max_output_tokens': 1000},
        {'cmd': 'python -c "from pathlib import Path;Path(\'second.txt\').write_text(\'executed\');print(\'HARNESSMM_SECOND\')"',
         'workdir': str(cwd), 'max_output_tokens': 1000},
    ]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            index = len(requests)
            if index == 1:
                names = visible_names(body.get('tools', []))
                if compiled:
                    name, args = 'harnessmm_plan', {'commands': commands}
                else:
                    name, args = 'exec_command', commands[0]
                if ('harnessmm_plan' in names) != compiled:
                    self.send_error(500, 'Unexpected feature exposure')
                    return
            elif not compiled and index == 2:
                name, args = 'exec_command', commands[1]
            else:
                name = None
            item = ({'type': 'function_call', 'name': name, 'arguments': json.dumps(args),
                     'call_id': f'mock_call_{index}', 'id': f'fc_{index}'} if name else
                    {'type': 'message', 'role': 'assistant', 'id': f'msg_{index}',
                     'content': [{'type': 'output_text', 'text': 'NATIVE_SMOKE_COMPLETE', 'annotations': []}]})
            response = {'id': f'resp_mock_{index}', 'object': 'response', 'created_at': int(time.time()),
                        'model': 'harnessmm-mock', 'status': 'completed', 'output': [item],
                        'usage': {'input_tokens': 100, 'output_tokens': 10, 'total_tokens': 110,
                                  'input_tokens_details': {'cached_tokens': 0},
                                  'output_tokens_details': {'reasoning_tokens': 0}}}
            events = [
                ('response.created', {'response': {**response, 'status': 'in_progress', 'output': []}}),
                ('response.output_item.added', {'output_index': 0, 'item': item}),
                ('response.output_item.done', {'output_index': 0, 'item': item}),
                ('response.completed', {'response': response}),
            ]
            payload = ''.join(f'event: {event}\ndata: {json.dumps({"type": event, **data})}\n\n'
                              for event, data in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    config = f'''model = "harnessmm-mock"
model_provider = "local_mock"
model_context_window = 131072
model_auto_compact_token_limit = 120000
approval_policy = "never"
sandbox_mode = "danger-full-access"
web_search = "disabled"
cli_auth_credentials_store = "file"
[model_providers.local_mock]
name = "Local deterministic test"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
env_key = "HARNESSMM_MOCK_TOKEN"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
[features]
code_mode = false
multi_agent = false
hooks = false
'''
    if included:
        config += f'harnessmm = {str(compiled).lower()}\n'
    if case == 'metering':
        from run_trials import HOOK
        config = config.replace('hooks = false', 'hooks = true')
        hook = folder / 'request_hook.py'
        hook.write_text(HOOK, encoding='utf-8')
        hook_command = f'& "{sys.executable}" "{hook}" "{folder / "model-requests.jsonl"}"'
        for event in ['PreModelRequest', 'PostModelRequest']:
            config += f'\n[[hooks.{event}]]\n[[hooks.{event}.hooks]]\ntype = "command"\ncommand = {json.dumps(hook_command)}\n'
    if case in ('rewrite', 'blocked'):
        config = config.replace('hooks = false', 'hooks = true')
        hook = folder / 'hook.py'
        if case == 'blocked':
            hook.write_text('import sys\nprint("Blocked for fixture", file=sys.stderr)\nsys.exit(2)\n')
        else:
            rewrite = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow',
                       'updatedInput': {'command': 'python -c "print(123)"'}}}
            hook.write_text('import json\nprint(json.dumps(' + repr(rewrite) + '))\n')
        hook_command = f'& "{sys.executable}" "{hook}"'
        config += '\n[[hooks.PreToolUse]]\nmatcher = "Bash"\n[[hooks.PreToolUse.hooks]]\ntype = "command"\ncommand = ' + json.dumps(hook_command) + '\n'
    # The runtime's environment owner discovers hooks.json reliably for exec.
    import tomllib
    parsed_config = tomllib.loads(config)
    if parsed_config.get('hooks'):
        (home / 'hooks.json').write_text(json.dumps({'hooks': parsed_config['hooks']}, indent=2), encoding='utf-8')
        config = config.split('\n[[hooks.', 1)[0]
    (home / 'config.toml').write_text(config, encoding='utf-8')
    env = os.environ.copy()
    env.update(CODEX_HOME=str(home), HARNESSMM_MOCK_TOKEN='local-fixture-only', RUST_LOG='codex_hooks=debug,codex_core::hook_runtime=debug,codex_core::harnessmm=info')
    if parsed_config.get('hooks'):
        from run_trials import trust_owned_hooks
        trust_owned_hooks(binary, home, cwd, env)
    args = [str(binary), 'exec', '--skip-git-repo-check', '--json',
            '-C', str(cwd), 'Run the provided local fixture and report completion.']
    started = time.monotonic()
    try:
        with (folder / 'stdout.jsonl').open('w', encoding='utf-8') as stdout, (folder / 'stderr.log').open('w', encoding='utf-8') as stderr:
            child = subprocess.Popen(args, stdout=stdout, stderr=stderr, env=env,
                                     creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            (folder / 'owner.json').write_text(json.dumps({'pid': child.pid, 'executable': str(binary), 'command': args, 'started_at': time.time()}, indent=2))
            try:
                code = child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                child.kill()  # Exact child handle created above; never a process-name kill.
                child.wait(timeout=15)
                raise
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        (folder / 'requests.json').write_text(json.dumps(requests, indent=2), encoding='utf-8')
    output = (folder / 'stdout.jsonl').read_text(encoding='utf-8')
    if code != 0 or 'NATIVE_SMOKE_COMPLETE' not in output:
        raise AssertionError(f'{case}: CLI failed ({code}); inspect {folder}')
    expected_second = case not in ('failed', 'spoofed_stdout', 'rewrite', 'blocked')
    if (cwd / 'second.txt').exists() != expected_second:
        raise AssertionError(f'{case}: wrong successor execution; inspect {folder}')
    expected_requests = 2 if compiled else 3
    if len(requests) != expected_requests:
        raise AssertionError(f'{case}: {len(requests)} model calls, expected {expected_requests}; inspect {folder}')
    if case == 'metering':
        records = [json.loads(line) for line in (folder / 'model-requests.jsonl').read_text().splitlines()]
        for event in ['PreModelRequest', 'PostModelRequest']:
            if len([row for row in records if row['hook_event_name'] == event]) != expected_requests:
                raise AssertionError('Request instrumentation lost an event')
    items = requests[-1].get('input', [])
    native_calls = [item for item in items if item.get('type') == 'function_call' and item.get('call_id', '').startswith('harnessmm_')]
    if compiled and len(native_calls) != (2 if expected_second else 1):
        raise AssertionError(f'{case}: missing compiled native calls in next model request')
    return {'case': case, 'passed': True, 'physical_requests': len(requests), 'native_reused_actions': len(native_calls),
            'second_executed': expected_second, 'elapsed_seconds': round(time.monotonic()-started, 3)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--included', action='store_true')
    args = parser.parse_args()
    cases = ['success', 'disabled', 'failed', 'spoofed_stdout', 'rewrite', 'blocked', 'metering'] if args.included else ['baseline', 'metering']
    results = []
    try:
        for case in cases:
            result = run_case(args.binary.resolve(), args.output.resolve(), case, args.included)
            results.append(result)
            print(json.dumps(result), flush=True)
    finally:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'summary.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
