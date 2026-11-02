"""Run the frozen real-task pair sequentially in fresh Codex homes.

Authentication is copied privately for the child and never written to reports.
No production launcher, config, history, repository remote or release is changed.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HOOK = '''import datetime,json,sys
from pathlib import Path
event=json.load(sys.stdin)
event["observed_at"]=datetime.datetime.now(datetime.timezone.utc).isoformat()
with Path(sys.argv[1]).open("a",encoding="utf-8") as out:
    out.write(json.dumps(event,separators=(",",":"))+"\\n")
'''


def sha(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()


def atomic(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2), encoding='utf-8')
    temporary.replace(path)


def trust_owned_hooks(binary, home, cwd, env):
    """Approve only the freshly authored hooks in this private experiment home."""
    module_path = Path(__file__).resolve().parents[2] / 'scripts/test-windows-cli-runtime.py'
    spec = importlib.util.spec_from_file_location('local_app_server_probe', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    server = module.AppServer(binary, cwd, env)
    try:
        server.request('initialize', {'clientInfo': {'name': 'harnessmm-evaluation', 'version': '1.0'},
                                      'capabilities': {'experimentalApi': True}})
        server.send({'method': 'initialized'})
        listing = server.request('hooks/list', {'cwds': [str(cwd)]})
    finally:
        server.close()
    expected = (home / 'hooks.json').resolve()
    trusted = []
    for group in listing['data']:
        for hook in group['hooks']:
            if Path(hook['sourcePath']).resolve() != expected:
                continue
            trusted.append(hook)
    if not trusted:
        raise RuntimeError('The owned diagnostic hooks were not discovered')
    with (home / 'config.toml').open('a', encoding='utf-8') as out:
        for hook in trusted:
            out.write(f'\n[hooks.state.{json.dumps(hook["key"])}]\nenabled = true\ntrusted_hash = {json.dumps(hook["currentHash"])}\n')


def run_trial(root, arm, binary, auth_home, timeout):
    workspace = root / 'work' / arm
    folder = root / 'trials' / arm
    folder.mkdir(parents=True, exist_ok=False)
    home = folder / 'home'
    home.mkdir()
    if not (auth_home / 'auth.json').is_file():
        raise RuntimeError('File-based authentication is unavailable; no credential was read or exported.')
    hook = folder / 'request_hook.py'
    hook.write_text(HOOK, encoding='utf-8')
    hook_command = f'& "{sys.executable}" "{hook}" "{folder / "model-requests.jsonl"}"'
    config = '''model = "gpt-6-astra"
model_reasoning_effort = "max"
model_context_window = 870000
model_auto_compact_token_limit = 800000
approval_policy = "never"
sandbox_mode = "danger-full-access"
web_search = "disabled"
check_for_update_on_startup = false
cli_auth_credentials_store = "file"
[features]
code_mode = false
multi_agent = false
memories = false
hooks = true
'''
    if arm == 'harnessmm':
        config += 'harnessmm = true\n'
    hook_config = {'hooks': {event: [{'hooks': [{'type': 'command', 'command': hook_command}]}]
                             for event in ['PreModelRequest', 'PostModelRequest']}}
    (home / 'hooks.json').write_text(json.dumps(hook_config, indent=2), encoding='utf-8')
    (home / 'config.toml').write_text(config, encoding='utf-8')
    env = os.environ.copy()
    # Avoid inherited credentials/provider overrides changing one trial's route.
    for key in ['OPENAI_API_KEY', 'OPENAI_BASE_URL', 'CODEX_API_KEY', 'GITHUB_TOKEN', 'GH_TOKEN']:
        env.pop(key, None)
    env.update(CODEX_HOME=str(home), RUST_LOG='codex_core::harnessmm=info')
    env['PATH'] = str(binary.parent) + os.pathsep + env.get('PATH', '')
    trust_owned_hooks(binary, home, workspace, env)
    args = [str(binary), 'exec', '--json', '--skip-git-repo-check',
            '-C', str(workspace), '--output-last-message', str(folder / 'final.txt'), '-']
    prompt = (root / 'prompt.txt').read_text(encoding='utf-8')
    start = datetime.now(timezone.utc).isoformat()
    status = {'arm': arm, 'binary': str(binary), 'binary_sha256': sha(binary), 'model': 'gpt-6-astra',
              'reasoning_effort': 'max', 'prompt_sha256': hashlib.sha256(prompt.encode()).hexdigest(),
              'started_at': start, 'state': 'running', 'workspace': str(workspace)}
    started = time.monotonic()
    try:
        shutil.copyfile(auth_home / 'auth.json', home / 'auth.json')
        with (folder / 'events.jsonl').open('w', encoding='utf-8') as out, (folder / 'stderr.log').open('w', encoding='utf-8') as err:
            child = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=out, stderr=err, env=env,
                                     creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            status.update(pid=child.pid, command=args)
            atomic(folder / 'status.json', status)
            try:
                child.communicate(prompt.encode(), timeout=timeout)
                status.update(state='completed', exit_code=child.returncode)
            except subprocess.TimeoutExpired:
                # The process handle identifies this exact owned child, not the active Codex host.
                child.kill()
                child.wait(timeout=20)
                status.update(state='timed_out', exit_code=child.returncode)
    finally:
        status.update(finished_at=datetime.now(timezone.utc).isoformat(), elapsed_seconds=round(time.monotonic()-started, 3))
        atomic(folder / 'status.json', status)
        (home / 'auth.json').unlink(missing_ok=True)
    print(json.dumps(status), flush=True)
    return status


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--auth-home', type=Path, required=True)
    parser.add_argument('--timeout-seconds', type=int, default=2700)
    args = parser.parse_args()
    results = []
    for arm, binary in [('baseline', args.baseline), ('harnessmm', args.candidate)]:
        if (args.root / 'pause').exists():
            raise RuntimeError('Experiment paused before the next trial')
        results.append(run_trial(args.root.resolve(), arm, binary.resolve(), args.auth_home.resolve(), args.timeout_seconds))
    atomic(args.root / 'trial-results.json', results)


if __name__ == '__main__':
    main()
