"""Evaluate solutions after both trials, using tests withheld from both actors."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import time


def execute(command, cwd, log, timeout=300):
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, encoding='utf-8', errors='replace',
                            timeout=timeout, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    log.write_text(result.stdout + result.stderr, encoding='utf-8')
    return {'command': command, 'exit_code': result.returncode, 'passed': result.returncode == 0,
            'elapsed_seconds': round(time.monotonic()-started, 3), 'log': str(log)}


def snapshot(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode()+b'\0')
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def judge(root, reference, arm):
    repo = root / 'work' / arm / 'repo'
    folder = root / 'judging' / arm
    folder.mkdir(parents=True, exist_ok=False)
    tests = folder / 'withheld'
    tests.mkdir()
    shutil.copyfile(repo / 'scripts/patch-codex-no-daemon.py', tests / 'patch-codex-no-daemon.py')
    shutil.copyfile(reference, tests / 'test-no-daemon-patch.py')
    checks = {}
    checks['withheld_behavior'] = execute([sys.executable, str(tests / 'test-no-daemon-patch.py'), '-v'], tests, folder / 'withheld.log')
    checks['repository_regressions'] = execute([sys.executable, str(repo / 'scripts/test-no-daemon-patch.py')], repo, folder / 'repository-tests.log')
    checks['upstream_compatibility'] = execute(['pwsh', '-NoProfile', '-File', str(repo / 'scripts/test-upstream-compatibility.ps1')], repo, folder / 'compatibility.log')
    checks['whitespace'] = execute(['git', 'diff', '--check'], repo, folder / 'diff-check.log')
    diff = subprocess.run(['git', 'diff', '--no-ext-diff'], cwd=repo, capture_output=True, check=True).stdout
    (folder / 'solution.patch').write_bytes(diff)
    status = subprocess.run(['git', 'status', '--short'], cwd=repo, capture_output=True, check=True).stdout
    (folder / 'git-status.txt').write_bytes(status)
    upstream = folder / 'upstream'
    upstream.mkdir()
    with tarfile.open(root / 'evidence/upstream-67f0994.tar') as archive:
        archive.extractall(upstream, filter='data')
    patch = ['pwsh', '-NoProfile', '-File', str(repo / 'scripts/patch-codex-windows-custom.ps1'), '-SourceRoot', str(upstream)]
    checks['complete_patch'] = execute(patch, repo, folder / 'complete-patch.log')
    first = snapshot(upstream)
    checks['patch_replay'] = execute(patch, repo, folder / 'patch-replay.log')
    second = snapshot(upstream)
    checks['idempotence'] = {'passed': first == second, 'first_source_sha256': first, 'replay_source_sha256': second}
    result = {'arm': arm, 'passed': all(check['passed'] for check in checks.values()), 'checks': checks,
              'solution_patch_sha256': hashlib.sha256(diff).hexdigest()}
    (folder / 'result.json').write_text(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--reference-tests', type=Path, required=True)
    args = parser.parse_args()
    results = [judge(args.root.resolve(), args.reference_tests.resolve(), arm) for arm in ['baseline', 'harnessmm']]
    (args.root / 'judging/results.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
