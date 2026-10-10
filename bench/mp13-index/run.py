#!/usr/bin/env python3
"""Bounded, resumable, same-payload index comparison through Kenshou."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent
POLICY = HERE.parent / 'mp12-cell/policy.json'
SETTINGS = ['shared_buffers=128MB', 'fsync=on', 'synchronous_commit=on',
            'full_page_writes=on', 'wal_level=replica']
CASES = [('fresh', True, 'none', 0), ('existing-category-browse', False, 'category', 1)]


def read(path):
    return json.loads(Path(path).read_text())


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, data):
    path = Path(path)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def remaining(root):
    budget = read(root / 'budget.json')
    return max(0, budget['started_epoch'] + budget['budget_seconds'] - time.time())


def stop(process):
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def command(args, log, timeout=120, environment=None):
    with log.open('a') as output:
        return subprocess.run(list(map(str, args)), stdout=output, stderr=subprocess.STDOUT,
                              timeout=timeout, env=environment).returncode


def verified(session_file):
    """Verify every completed slice; never hide failed or unfinished slices."""
    session = read(session_file)
    rows = []
    for trial in session['slices']:
        if trial['state'] != 'verified' or trial.get('cellOutcome') != 'completed':
            continue
        tree = Path(trial['fetchedPath'])
        manifest = read(tree / 'manifest.json')
        if digest(tree / 'manifest.json') != trial['manifestSha256'].removeprefix('sha256:'):
            raise ValueError('manifest digest differs from the journal')
        for artifact in manifest['artifacts']:
            path = tree / artifact['path']
            if not path.is_relative_to(tree) or '..' in Path(artifact['path']).parts:
                raise ValueError('invalid sealed artifact path')
            if path.stat().st_size != artifact['bytes'] or digest(path) != artifact['sha256'].removeprefix('sha256:'):
                raise ValueError('sealed artifact hash mismatch')
        for path in tree.glob('output/*/run-result.json'):
            result = read(path)
            summary = result['summaries']['measurements']
            measure = summary['measurements']
            probe = summary['write-probe']
            if result['outcome'] != 'passed' or measure['grade'] != 'benchmark' or measure['gradeReasons']:
                raise ValueError('completed trial failed the measurement contract')
            if probe['durability'] != 'on,on,on' or not probe['durable_drained']:
                raise ValueError('trial lacks durable progress')
            before, after = summary['streams-before'], summary['streams-after']
            expected = probe['calls'] * probe['workload']['width'] if probe['workload']['fresh'] else 0
            if after['stream_rows'] - before['stream_rows'] != expected:
                raise ValueError('fresh/existing stream inventory delta differs')
            if after['all_version'] - before['all_version'] != probe['events']:
                raise ValueError('global stream version delta differs')
            if after['stats_reset'] != before['stats_reset']:
                raise ValueError('statistics reset during the trial')
            counters = {key: after[key] - before[key] for key in ['inserted', 'updated', 'hot_updated', 'newpage_updated']}
            if any(value < 0 for value in counters.values()) or counters['hot_updated'] > counters['updated']:
                raise ValueError('invalid stream statistics boundaries')
            if counters['inserted'] != expected:
                raise ValueError('stream insertion statistics are incomplete')
            rows.append({'runId': result['runId'], 'path': str(path.parent),
                         'manifestSha256': digest(tree / 'manifest.json'), 'resultSha256': digest(path),
                         'rawPrefix': f"gs://{session['resultsBucket']}/runs/{manifest['runId']}/",
                         'comparison': result['comparison'], 'compatibility': result['compatibility'],
                         'cohort': result['cohort'], 'fingerprint': result['fingerprint'],
                         'measurements': measure, 'writeProbe': probe, 'indexSetup': summary['index-setup'],
                         'streamsBefore': before, 'streamsAfter': after, 'streamDeltas': counters})
    return rows


def plan(template, case, pairs, calibration=False, proof=False):
    name, fresh, mode, hz = case
    document = copy.deepcopy(template)
    document['planId'] = str(uuid.uuid4())
    document['runs'] = []
    for pair in range(pairs):
        arms = ['baseline', 'candidate'] if pair % 2 == 0 else ['candidate', 'baseline']
        if proof:
            arms = ['baseline']
        for arm in arms:
            entry = copy.deepcopy(template['runs'][0])
            identifier = str(uuid.uuid4())
            position = pair * 2 + (0 if arm == arms[0] else 1)
            entry.update(ordinal=len(document['runs']) + 1, runId=identifier, estimateMinutes=2)
            group = 'mp13-index/' + ('calibration' if calibration else name)
            entry['trial'] = {'group': group, 'arm': arm, 'index': pair, 'of': pairs}
            spec = entry['spec']
            spec.update(runId=identifier, scenarioRevision=4, seed=7 + pair,
                        phases={'warmUpSeconds': 10, 'steadySeconds': 61, 'drainSeconds': 10},
                        timeoutSeconds=180,
                        comparison={'group': group, 'arm': arm, 'trial': pair, 'position': position})
            spec['knobs'].update({'mp12.mode': mode, 'mp12.fresh': fresh, 'mp12.width': 1,
                                  'mp12.append-batch': 1, 'mp12.checkpoint-batch': 1, 'mp12.offered': 0,
                                  'mp13.index-layout': 'category-only' if calibration or arm == 'baseline' else 'category-name',
                                  'mp13.catalog': 20000, 'mp13.browse-hz': hz})
            document['runs'].append(entry)
    document['estimateMinutes'] = 2 * len(document['runs'])
    return document


def audit(operator, root, session_file, descriptor):
    """Actual remote phase and instance state, not log size or PID activity."""
    session = read(session_file) if session_file.exists() else {'slices': []}
    slices = session['slices']
    active = next((x for x in slices if x['state'] not in ['verified', 'failed', 'rejected']), None)
    status = None
    if active and active.get('submission'):
        uri = f"gs://{session['controlBucket']}/cells/{session['cell']}/submissions/{active['cellRun']}/status.json"
        result = subprocess.run(['gcloud', 'storage', 'cat', uri], capture_output=True, text=True, timeout=20)
        if result.returncode == 0:
            status = json.loads(result.stdout)
    names = [descriptor['instances']['postgres']] + descriptor['instances']['drivers']
    states = []
    for name in names:
        result = subprocess.run(['gcloud', 'compute', 'instances', 'describe', name,
                                 '--project', descriptor['project'], '--zone', descriptor['zone'],
                                 '--format=value(status)'], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise ValueError('could not verify instance power state')
        states.append(result.stdout.strip())
    snapshot = {'at': time.time(), 'remaining_seconds': remaining(root),
                'verified': sum(x['state'] == 'verified' for x in slices),
                'active_run': active.get('cellRun') if active else None,
                'phase': status.get('phase') if status else None,
                'instance_states': states}
    with (root / 'remote-progress.jsonl').open('a') as output:
        output.write(json.dumps(snapshot) + '\n')
    print(json.dumps(snapshot), flush=True)
    return snapshot


def execute(operator, root, payload, cell, name, document, descriptor):
    out = root / name
    out.mkdir(exist_ok=True)
    plan_file, session_dir = out / 'plan.json', out / 'session'
    if plan_file.exists():
        if read(plan_file) != document:
            raise ValueError('saved plan inputs changed')
    else:
        write(plan_file, document)
    journal = session_dir / 'session.json'
    if journal.exists() and read(journal)['slices'] and all(x['state'] == 'verified' for x in read(journal)['slices']):
        rows = verified(journal)
        if len(rows) != len(document['runs']):
            raise ValueError('saved verified-trial count differs from the plan')
        return rows
    if remaining(root) < 150 * len(document['runs']) + 60:
        raise ValueError('insufficient remaining total budget; no new trials submitted')
    args = [operator, 'cell', 'resume', session_dir, '--start'] if journal.exists() else [
        operator, 'cell', 'run', '--cell', cell, '--start', '--payload', payload,
        '--plan', plan_file, '--out', session_dir] + [x for setting in SETTINGS for x in ['--pg-setting', setting]]
    log = out / 'operator.log'
    with log.open('a') as output:
        process = subprocess.Popen(list(map(str, args)), stdout=output, stderr=subprocess.STDOUT)
        last_progress, previous, next_audit = time.monotonic(), None, 0
        try:
            while process.poll() is None:
                if remaining(root) < 45:
                    raise TimeoutError('total experiment budget expired')
                now = time.monotonic()
                if now >= next_audit:
                    current = audit(operator, root, journal, descriptor)
                    signature = (current['verified'], current['active_run'], current['phase'], current['instance_states'])
                    if signature != previous:
                        last_progress, previous = now, signature
                    if current['active_run'] and any(x != 'RUNNING' for x in current['instance_states']):
                        raise RuntimeError('an instance stopped during active remote execution')
                    if now - last_progress > 300:
                        raise TimeoutError('remote phase and verified-trial count made no progress for five minutes')
                    next_audit = now + 30
                time.sleep(1)
        finally:
            if process.poll() is None:
                stop(process)
            status = subprocess.run([operator, 'cell', 'status', '--cell', cell, '--json'], capture_output=True, text=True, timeout=30, check=True)
            observed = json.loads(status.stdout)
            lease = observed['lease']
            if lease and journal.exists() and lease['leaseId'] == read(journal)['leaseId']:
                subprocess.run([operator, 'cell', 'release', '--cell', cell, '--lease-id', lease['leaseId']], check=True, timeout=30)
                status = subprocess.run([operator, 'cell', 'status', '--cell', cell, '--json'], capture_output=True, text=True, timeout=30, check=True)
                observed = json.loads(status.stdout)
            write(out / 'lease-release.json', observed)
            if observed['lease'] and journal.exists() and observed['lease']['leaseId'] == read(journal)['leaseId']:
                raise ValueError('owned lease was not released')
    rows = verified(journal) if journal.exists() else []
    write(out / 'verified.json', rows)
    if process.returncode or len(rows) != len(document['runs']):
        raise ValueError('session incomplete or failed; retained all samples and journal')
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--operator', required=True)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--cell', default='alpha')
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(exist_ok=True)
    if not (root / 'budget.json').exists():
        write(root / 'budget.json', {'started_epoch': time.time(), 'budget_seconds': 3600})
    payload = read(args.payload)
    if payload['harness']['dirty']:
        raise ValueError('requires a clean immutable payload')
    inputs = {'payloadSha256': digest(args.payload), 'policySha256': digest(POLICY), 'cell': args.cell,
              'cases': CASES, 'pairs': 5, 'phases': [10, 61, 10], 'settings': SETTINGS,
              'controllerSha256': digest(__file__)}
    inputs = json.loads(json.dumps(inputs))
    if (root / 'inputs.json').exists():
        if read(root / 'inputs.json') != inputs:
            raise ValueError('owned experiment inputs changed')
    else:
        write(root / 'inputs.json', inputs)
    status = subprocess.run([args.operator, 'cell', 'status', '--cell', args.cell, '--json'], capture_output=True, text=True, timeout=30, check=True)
    descriptor = json.loads(status.stdout)['descriptor']
    template_file = root / 'template.json'
    if not template_file.exists():
        cohort_file = root / 'operator-cohort.json'
        write(cohort_file, payload['cohortIdentity'])
        env = dict(os.environ, KENSHOU_COHORT_IDENTITY=str(cohort_file))
        code = command([args.operator, 'plan', '--all', '--select', 'kiroku/append/benchmark/subscription-hardening',
                        '--placement', 'cell', '--seed', '7', '--dim', 'pg.version=18',
                        '--dim', 'pg.durability=durable', '--out', template_file], root / 'prepare.log', environment=env)
        if code:
            raise ValueError('planning failed')
    template = read(template_file)
    # One verified trial proves the entire lifecycle before expanding coverage.
    proof_file = root / 'proof/plan.json'
    proof = read(proof_file) if proof_file.exists() else plan(template, CASES[0], 1, calibration=True, proof=True)
    execute(args.operator, root, args.payload, args.cell, 'proof', proof, descriptor)
    release = subprocess.run([args.operator, 'cell', 'status', '--cell', args.cell, '--json'], capture_output=True, text=True, timeout=30, check=True)
    if json.loads(release.stdout)['lease'] is not None:
        raise ValueError('proof lease was not released')
    write(root / 'proof-lease-release.json', json.loads(release.stdout))
    # A second identical control gives a small calibration, not equivalence proof.
    calibration_file = root / 'calibration/plan.json'
    calibration = read(calibration_file) if calibration_file.exists() else plan(template, CASES[0], 1, calibration=True, proof=True)
    execute(args.operator, root, args.payload, args.cell, 'calibration', calibration, descriptor)
    for case in CASES:
        path = root / case[0] / 'plan.json'
        document = read(path) if path.exists() else plan(template, case, 5)
        rows = execute(args.operator, root, args.payload, args.cell, case[0], document, descriptor)
        for row in rows:
            if command([args.operator, 'summarize', row['path'], '--verify'], root / 'verification.log', timeout=min(120, remaining(root))):
                raise ValueError('raw measurement recomputation failed')
        baseline = sorted((x for x in rows if x['comparison']['arm'] == 'baseline'), key=lambda x: x['comparison']['trial'])
        candidate = sorted((x for x in rows if x['comparison']['arm'] == 'candidate'), key=lambda x: x['comparison']['trial'])
        comparison_file = root / case[0] / 'comparison.json'
        code = command([args.operator, 'compare', '--policy', POLICY, '--vary', 'knob:mp13.index-layout', '--out', comparison_file]
                       + [item for row in baseline for item in ['--baseline', row['path']]]
                       + [item for row in candidate for item in ['--candidate', row['path']]], root / 'comparison.log', timeout=min(120, remaining(root)))
        if code not in [0, 2, 3] or not comparison_file.exists():
            raise ValueError('paired comparison failed')
        result = read(comparison_file)
        print(json.dumps({'case': case[0], 'verdict': result['verdict'], 'pairs': result['pairCount']}), flush=True)
        if result['verdict'] == 'regression':
            raise ValueError('confirmed write regression; no further cases submitted')
    write(root / 'completion.json', {'status': 'functional-complete', 'performance': 'see individual comparisons', 'remaining_seconds': remaining(root)})


if __name__ == '__main__':
    main()
