"""Verify the GitHub Actions archive digest and its workflow binding before extraction."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--metadata', type=Path, required=True)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--run', type=int, required=True)
parser.add_argument('--head', required=True)
args = parser.parse_args()
metadata = json.loads(args.metadata.read_text())
if metadata['workflow_run']['id'] != args.run or metadata['workflow_run']['head_sha'] != args.head:
    raise AssertionError('Unexpected Actions source binding')
with args.archive.open('rb') as source:
    actual = 'sha256:' + hashlib.file_digest(source, 'sha256').hexdigest()
if actual != metadata['digest']:
    raise AssertionError('Actions archive SHA-256 mismatch')
args.destination.mkdir(parents=True, exist_ok=True)
if any(args.destination.iterdir()):
    raise AssertionError('Refusing to overwrite an existing artifact download')
with zipfile.ZipFile(args.archive) as archive:
    for name in archive.namelist():
        if not (args.destination / name).resolve().is_relative_to(args.destination.resolve()):
            raise AssertionError('Archive path escapes destination')
    archive.extractall(args.destination)
(args.destination / 'artifact-provenance.json').write_text(json.dumps(metadata, indent=2))
print(json.dumps({'artifact_id': metadata['id'], 'run': args.run, 'sha256': actual, 'verified': True}))
