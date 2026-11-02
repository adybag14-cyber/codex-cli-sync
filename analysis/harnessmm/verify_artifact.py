"""Verify an Actions download and extract a side-by-side experimental package."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def verify(download, destination, variant, run, head):
    manifests = list(download.rglob('*.manifest.json'))
    if len(manifests) != 1:
        raise AssertionError('Require exactly one build manifest')
    manifest = read_json(manifests[0])
    if manifest['upstream_sha'] != '67f0994b532b8740f14b5b738af7b7b2a915b1d6':
        raise AssertionError('Unexpected upstream source')
    if manifest['patch_status'] != 'applied' or manifest['custom_patches_failed'] is not False:
        raise AssertionError('Custom patch contract did not pass')
    if manifest['harnessmm']['included'] != (variant == 'harnessmm') or manifest['harnessmm']['default_enabled'] is not False:
        raise AssertionError('Compiled variant mismatch')
    archives = list(download.rglob(manifest['artifact']['name']))
    if len(archives) != 1 or sha(archives[0]) != manifest['artifact']['sha256']:
        raise AssertionError('Downloaded ZIP does not match its manifest')
    destination.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(archives[0]) as archive:
        for name in archive.namelist():
            if not (destination / name).resolve().is_relative_to(destination.resolve()):
                raise AssertionError('Archive path escapes the experimental destination')
        archive.extractall(destination)
    layouts = list(destination.rglob('codex-package.json'))
    if len(layouts) != 1:
        raise AssertionError('Missing or ambiguous canonical package')
    package = layouts[0].parent
    layout = read_json(layouts[0])
    if layout['layoutVersion'] != 1 or layout['version'] != manifest['custom_version'] or layout['target'] != 'x86_64-pc-windows-msvc':
        raise AssertionError('Unexpected package layout/version/target')
    binary = package / layout['entrypoint']
    binary_hash = sha(binary)
    runtime = read_json(package / 'runtime-checks.json')
    daemon = read_json(package / 'no-daemon-checks.json')
    if runtime['executableSha256'] != binary_hash or runtime['passed'] < 30:
        raise AssertionError('Runtime evidence is not bound to the downloaded executable')
    if daemon['executableSha256'] != binary_hash or not daemon['ok'] or daemon['passed'] < 14:
        raise AssertionError('Missing source-bound daemon-free runtime evidence')
    reports = {}
    for name in ('request-metadata-test-selection.json', 'dynamic-tool-test-selection.json', 'guardian-test-selection.json'):
        report = read_json(package / name)
        valid = (report.get('ok') is True and report.get('passed', 0) > 0) if name.startswith('guardian-') else (
            report.get('passed') is True and report.get('selected_count', 0) > 0)
        if not valid:
            raise AssertionError(f'Invalid required test report: {name}')
        reports[name] = report
    if variant == 'harnessmm':
        paths = list(download.rglob('harnessmm-test-selection.json'))
        if len(paths) != 1:
            raise AssertionError('Missing native HarnessMM unit-test evidence')
        report = read_json(paths[0])
        if report.get('passed') is not True or report.get('selected_count', 0) < 3:
            raise AssertionError('HarnessMM native tests did not pass')
        reports[paths[0].name] = report
    env = os.environ.copy()
    env['CODEX_HOME'] = str(destination / 'verification-home')
    version = subprocess.check_output([str(binary), '--version'], env=env, text=True).strip()
    if version != 'codex-cli ' + manifest['custom_version']:
        raise AssertionError('Executable version differs from manifest')
    features = subprocess.check_output([str(binary), 'features', 'list'], env=env, text=True)
    match = [line for line in features.splitlines() if line.split()[:1] == ['harnessmm']]
    if bool(match) != (variant == 'harnessmm') or (match and match[0].split()[-1] != 'false'):
        raise AssertionError('Wrong native feature exposure or default')
    files = {str(path.relative_to(package)): sha(path) for path in sorted(package.rglob('*')) if path.is_file()}
    result = {'variant': variant, 'run_id': run, 'workflow_head': head, 'upstream_sha': manifest['upstream_sha'],
              'version': version, 'zip_sha256': sha(archives[0]), 'binary': str(binary), 'binary_sha256': binary_hash,
              'build_recipe_sha256': manifest['build_recipe_sha256'], 'package': str(package),
              'runtime_checks': runtime['passed'], 'daemon_checks': daemon['passed'], 'reports': reports, 'files': files,
              'passed': True}
    (destination / 'verification.json').write_text(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--download', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--variant', choices=['baseline', 'harnessmm'], required=True)
    parser.add_argument('--run', type=int, required=True)
    parser.add_argument('--head', required=True)
    args = parser.parse_args()
    result = verify(args.download.resolve(), args.destination.resolve(), args.variant, args.run, args.head)
    print(json.dumps({key: result[key] for key in ['variant', 'run_id', 'version', 'binary', 'binary_sha256', 'zip_sha256', 'passed']}, indent=2))
