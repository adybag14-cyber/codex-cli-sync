"""One bounded watcher for this experiment's exact CI run IDs."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--deadline-seconds', type=int, default=14400)
parser.add_argument('runs', nargs='+')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
deadline = time.monotonic() + args.deadline_seconds
pending = set(args.runs)
reported_jobs = set()
while pending and time.monotonic() < deadline:
    if (args.output / 'pause').exists():
        break
    for run in list(pending):
        result = subprocess.run(['gh', 'run', 'view', run, '--repo', 'adybag14-cyber/codex-cli-sync',
                                 '--json', 'status,conclusion,headSha,url,jobs'], capture_output=True, text=True, timeout=45,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if result.returncode:
            continue
        record = json.loads(result.stdout)
        record['observed_at'] = datetime.now(timezone.utc).isoformat()
        path = args.output / f'{run}.json'
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(record, indent=2))
        temporary.replace(path)
        for job in record.get('jobs', []):
            key = (run, job['databaseId'])
            if job['status'] == 'completed' and key not in reported_jobs:
                reported_jobs.add(key)
                print(json.dumps({'run': run, 'job': job['name'], 'conclusion': job['conclusion']}), flush=True)
        if record['status'] == 'completed':
            pending.remove(run)
            print(json.dumps({'run': run, 'conclusion': record['conclusion'], 'url': record['url']}), flush=True)
    if pending:
        time.sleep(30)
(args.output / 'watcher-result.json').write_text(json.dumps({'remaining': sorted(pending), 'finished': not pending}))
