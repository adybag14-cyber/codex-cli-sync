"""Prepare identical history-free pre-fix workspaces and reproduce the real failure."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

PROMPT = """Fix the failing Codex CLI Sync source-patching workflow in ./repo.

Both the Windows custom and Linux i686 builds fail against the supplied exact upstream source in ./upstream. The original failure is captured in ./failure.log. The upstream revision is 67f0994b532b8740f14b5b738af7b7b2a915b1d6. The repository contains the code that failed, not its later repair.

Diagnose and implement the smallest robust repository-owned fix. Preserve the documented custom behavior: local interactive launches use the embedded app server with daemon auto-start/attachment disabled, while explicit remote connection validation remains intact. Preserve support for previously supported source layouts, idempotent patch replay, and refusal of unknown or ambiguous layouts before source writes. Add focused regression coverage as needed, run the relevant existing tests, and demonstrate that the complete Windows patch applies and replays against the supplied upstream. A Rust rebuild is not required for this source-transform repair.

Work autonomously and use tools efficiently. Only change files inside ./repo; ./upstream is a disposable source fixture that may be patched to validate your fix. Run all commands within this trial workspace. Do not read outside this workspace, use personal memories or previous sessions, query GitHub or another network source for the answer, inspect other trials, or change global configuration. There is no remote configured intentionally. Do not publish, push, open a PR, or install software. The task is complete when the fix and tests are present and you report what changed, what passed, and any remaining limitation.
"""


def run(args, cwd, **kwargs):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=180,
                          creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), **kwargs)


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as source:
        source.extractall(destination, filter='data')


def tree_hash(root):
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob('*')):
        if path.is_file() and '.git' not in path.relative_to(root).parts:
            digest.update(path.relative_to(root).as_posix().encode() + b'\0')
            digest.update(hashlib.sha256(path.read_bytes()).digest())
            count += 1
    return {'sha256': digest.hexdigest(), 'files': count}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--repo-archive', type=Path, required=True)
    parser.add_argument('--upstream-archive', type=Path, required=True)
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    seed = args.root / 'reproduction'
    extract(args.repo_archive, seed / 'repo')
    extract(args.upstream_archive, seed / 'upstream')
    result = run(['pwsh', '-NoProfile', '-File', str(seed / 'repo/scripts/patch-codex-windows-custom.ps1'),
                  '-SourceRoot', str(seed / 'upstream')], seed)
    if result.returncode == 0 or 'Unsupported upstream source: interactive local launch' not in result.stdout + result.stderr:
        raise RuntimeError('The selected parent does not reproduce the declared failure: ' + (result.stdout + result.stderr)[-3000:])
    # Both arms see the exact same bytes, with the reproduction path generalized.
    failure = (result.stdout + result.stderr).replace(str(seed), '<trial-workspace>').replace(str(seed).replace('\\', '/'), '<trial-workspace>')
    (args.root / 'failure.log').write_text(failure, encoding='utf-8')
    (args.root / 'prompt.txt').write_text(PROMPT, encoding='utf-8')
    records = {}
    for arm in ['baseline', 'harnessmm']:
        workspace = args.root / 'work' / arm
        extract(args.repo_archive, workspace / 'repo')
        extract(args.upstream_archive, workspace / 'upstream')
        (workspace / 'failure.log').write_text(failure, encoding='utf-8')
        records[arm] = {'repository': tree_hash(workspace / 'repo'), 'upstream': tree_hash(workspace / 'upstream')}
        for command in [
            ['git', 'init', '-b', 'task'],
            ['git', 'config', 'user.name', 'HarnessMM evaluation'],
            ['git', 'config', 'user.email', 'evaluation@localhost'],
            ['git', 'config', 'core.autocrlf', 'false'],
            ['git', 'add', '.'],
            ['git', 'commit', '-m', 'Task input snapshot'],
        ]:
            outcome = run(command, workspace / 'repo')
            if outcome.returncode:
                raise RuntimeError(outcome.stdout + outcome.stderr)
    if records['baseline'] != records['harnessmm']:
        raise AssertionError('The two input trees differ')
    manifest = {'repository_parent': '2dc5bb138748bb9aac80e30dd0c773b2399f2a03',
                'upstream': '67f0994b532b8740f14b5b738af7b7b2a915b1d6',
                'prompt_sha256': hashlib.sha256(PROMPT.encode()).hexdigest(),
                'failure_sha256': hashlib.sha256(failure.encode()).hexdigest(),
                'reproduction_exit_code': result.returncode, 'arms': records}
    (args.root / 'input-manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
