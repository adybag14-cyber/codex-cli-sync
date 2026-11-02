"""Bounded, fail-fast continuation from CI artifacts through the frozen experiment.

The separate single CI watcher supplies run status. This owner only reads those
checkpoints and performs the already-authorized local qualification and trials.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback

from analyze_traces import analyze
from judge_task import judge
from native_smoke import run_case
from run_trials import atomic, run_trial
from verify_artifact import verify


class Coordinator:
    def __init__(self, args):
        self.args = args
        self.root = args.root.resolve()
        self.deadline = time.monotonic() + 18000
        self.status = {'state': 'running', 'started_at': datetime.now(timezone.utc).isoformat(),
                       'pid': os.getpid(), 'executable': sys.executable, 'command': sys.argv,
                       'baseline_run': args.baseline_run, 'candidate_run': args.candidate_run}
        self.path = self.root / 'coordinator-status.json'
        self.heartbeat = 0
        self.update('starting')

    def update(self, phase, **fields):
        self.status.update(phase=phase, updated_at=datetime.now(timezone.utc).isoformat(), **fields)
        atomic(self.path, self.status)
        print(json.dumps({'phase': phase, **fields}), flush=True)

    def admission(self):
        if (self.root / 'pause').exists():
            raise RuntimeError('Experiment paused before the next operation')
        if time.monotonic() > self.deadline:
            raise TimeoutError('Coordinator reached its five-hour deadline')

    def artifact_ready(self, run, variant, head):
        self.update('waiting_for_artifact', run=run, variant=variant)
        while True:
            self.admission()
            path = self.root / 'ci' / f'{run}.json'
            if path.exists():
                state = json.loads(path.read_text())
                if state['headSha'] != head:
                    raise AssertionError('CI checkpoint belongs to another source head')
                matches = [job for job in state['jobs'] if job['name'] == f'build ({variant})']
                if matches:
                    job = matches[0]
                    if job['conclusion'] in ('failure', 'cancelled', 'timed_out'):
                        raise RuntimeError(f'{variant} build did not qualify: {job["conclusion"]}')
                    passed = {step['name'] for step in job['steps'] if step['conclusion'] == 'success'}
                    if {'Build and validate exact arm', 'Retain build and evidence'} <= passed:
                        return
            if time.monotonic()-self.heartbeat >= 60:
                self.heartbeat = time.monotonic()
                self.update('waiting_for_artifact', run=run, variant=variant)
            time.sleep(10)

    def qualify(self, run, variant, head):
        self.artifact_ready(run, variant, head)
        self.admission()
        download = self.root / 'downloads' / f'{variant}-{run}'
        destination = self.root / 'packages' / f'{variant}-{head[:12]}'
        if (destination / 'verification.json').exists():
            result = json.loads((destination / 'verification.json').read_text())
            from verify_artifact import sha
            if result['workflow_head'] != head or result['binary_sha256'] != sha(Path(result['binary'])):
                raise AssertionError('A retained package changed')
            return result
        # A connector download is delivered by unpack_actions.py. Keeping the
        # transport outside this owner avoids gh's observed large-artifact stall.
        if not (download / 'artifact-provenance.json').exists():
            self.update('download_required', run=run, variant=variant, head=head,
                        artifact_name=f'harnessmm-ab-{variant}')
            while not (download / 'artifact-provenance.json').exists():
                self.admission()
                time.sleep(10)
        provenance = json.loads((download / 'artifact-provenance.json').read_text())
        if provenance['workflow_run']['id'] != run or provenance['workflow_run']['head_sha'] != head:
            raise AssertionError('Delivered artifact is not bound to the expected workflow head')
        self.update('verifying', run=run, variant=variant)
        return verify(download, destination, variant, run, head)

    def smoke(self, package, included):
        variant = package['variant']
        self.update('native_smoke', variant=variant)
        output = self.root / 'native-smoke' / package['workflow_head'] / variant
        cases = ['success', 'disabled', 'failed', 'spoofed_stdout', 'rewrite', 'blocked', 'post_blocked', 'changed_context', 'metering'] if included else ['baseline', 'metering']
        if (output / 'summary.json').exists():
            retained = json.loads((output / 'summary.json').read_text())
            if [row['case'] for row in retained] == cases and all(row['passed'] for row in retained):
                return retained
            raise AssertionError('Retained smoke evidence is incomplete')
        attempt = output
        if output.exists():
            serial = 2
            while (output / f'attempt-{serial}').exists():
                serial += 1
            attempt = output / f'attempt-{serial}'
        results = []
        for case in cases:
            self.admission()
            results.append(run_case(Path(package['binary']), attempt, case, included))
        atomic(output / 'summary.json', results)
        return results

    def run(self):
        baseline = self.qualify(self.args.baseline_run, 'baseline', self.args.baseline_head)
        baseline_smoke = self.smoke(baseline, False)
        candidate = self.qualify(self.args.candidate_run, 'harnessmm', self.args.candidate_head)
        if baseline['version'] != candidate['version']:
            raise AssertionError('The two arms advertise different Codex versions')
        candidate_smoke = self.smoke(candidate, True)
        self.admission()
        self.update('native_provider_preflight')
        preflight = self.root / 'native-provider-preflight'
        (preflight / 'work/harnessmm').mkdir(parents=True, exist_ok=False)
        prompt = ('Call harnessmm_plan directly once with these two literal commands in order: '
                  'python -c "print(111)" and python -c "print(222)". '
                  'Let the native harness execute both. Then reply exactly NATIVE_PROVIDER_OK. '
                  'Do not use other tools or change any files.\n')
        (preflight / 'prompt.txt').write_text(prompt)
        preflight_status = run_trial(preflight, 'harnessmm', Path(candidate['binary']), self.args.auth_home, 300)
        preflight_metrics = analyze(preflight, 'harnessmm')
        if preflight_status.get('exit_code') != 0 or preflight_metrics['native_reused_actions_with_receipts'] != 2:
            raise AssertionError('Native reuse has not passed the real-provider preflight')
        if (preflight / 'trials/harnessmm/final.txt').read_text().strip() != 'NATIVE_PROVIDER_OK':
            raise AssertionError('Native provider preflight did not finish as expected')
        results = []
        for arm, package in [('baseline', baseline), ('harnessmm', candidate)]:
            self.admission()
            self.update('real_task', variant=arm)
            results.append(run_trial(self.root, arm, Path(package['binary']), self.args.auth_home, 2700))
        atomic(self.root / 'trial-results.json', results)
        self.admission()
        self.update('independent_judging')
        judgments = [judge(self.root, self.args.reference_tests, arm) for arm in ['baseline', 'harnessmm']]
        atomic(self.root / 'judging/results.json', judgments)
        self.update('trace_analysis')
        metrics = {arm: analyze(self.root, arm) for arm in ['baseline', 'harnessmm']}
        atomic(self.root / 'comparison.json', metrics)
        result = {'state': 'completed', 'baseline': baseline, 'candidate': candidate,
                  'baseline_smoke': baseline_smoke, 'candidate_smoke': candidate_smoke,
                  'native_provider_preflight': preflight_metrics, 'trials': results,
                  'judgments': judgments, 'metrics': metrics}
        atomic(self.root / 'coordinator-result.json', result)
        self.update('completed', state='completed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--baseline-run', type=int, required=True)
    parser.add_argument('--baseline-head', required=True)
    parser.add_argument('--candidate-run', type=int, required=True)
    parser.add_argument('--candidate-head', required=True)
    parser.add_argument('--auth-home', type=Path, required=True)
    parser.add_argument('--reference-tests', type=Path, required=True)
    coordinator = Coordinator(parser.parse_args())
    try:
        coordinator.run()
    except BaseException as error:
        coordinator.update('stopped', state='failed', error=str(error))
        traceback.print_exc()
        raise SystemExit(1)
