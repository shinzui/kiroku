#!/usr/bin/env python3
"""Collect the predeclared ADR-11 matrix using the Kenshou cell operator.

The stages are deliberately separate: pilots freeze offered loads, two A/A
method calibrations finish before A/B starts, and an inconclusive A/B stops the gate.
No timing allowance is introduced. Output directories are never overwritten.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
SPEC = json.loads((HERE / 'matrix.json').read_text())
REPO = HERE.parent.parent
SETTINGS = ['shared_buffers=128MB', 'fsync=on', 'synchronous_commit=on',
            'full_page_writes=on', 'wal_level=replica']


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    with Path(path).open('x') as output:
        json.dump(value, output, indent=2)
        output.write('\n')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def production_fingerprint():
    packages = ['kiroku-store', 'kiroku-store-migrations', 'shibuya-kiroku-adapter',
                'kiroku-cli', 'kiroku-metrics', 'kiroku-otel', 'kiroku-test-support']
    files = subprocess.check_output(['git', 'ls-files', '-z', '--'] + packages,
                                    cwd=REPO).decode().split('\0')
    files = sorted(path for path in files if path and
                   ('/src/' in path or '/migrations/' in path or path.endswith('.cabal')))
    files += ['flake.lock', 'flake.nix', 'nix/haskell-overlay.nix', 'cabal.project']
    records = {path: digest(REPO / path) for path in files}
    return hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()


def command(args, log=None, cohort_file=None):
    print(' '.join(map(str, args)), flush=True)
    environment = os.environ.copy()
    if cohort_file is not None:
        environment['KENSHOU_COHORT_IDENTITY'] = str(cohort_file.resolve())
    if log is None:
        return subprocess.run(list(map(str, args)), check=True, env=environment).returncode
    with log.open('x') as output:
        return subprocess.run(list(map(str, args)), stdout=output,
                              stderr=subprocess.STDOUT, env=environment).returncode


def collect(session_file):
    """Only use operator-verified trees; bind every artifact to its sealed hash."""
    session = read(session_file)
    rows = []
    for trial in session['slices']:
        if trial['state'] != 'verified' or trial['cellOutcome'] != 'completed':
            raise ValueError('session contains an unverified or failed trial')
        tree = Path(trial['fetchedPath'])
        portable = Path(session_file).parent.parent / trial['cellRun'] / 'tree'
        if portable.exists():
            tree = portable
        manifest = read(tree / 'manifest.json')
        if digest(tree / 'manifest.json') != trial['manifestSha256'].removeprefix('sha256:'):
            raise ValueError('sealed manifest digest differs from operator journal')
        for item in manifest['artifacts']:
            path = tree / item['path']
            if not path.is_relative_to(tree) or '..' in Path(item['path']).parts:
                raise ValueError('invalid artifact path')
            if path.stat().st_size != item['bytes'] or digest(path) != item['sha256'].removeprefix('sha256:'):
                raise ValueError(f'corrupt artifact: {path}')
        for path in tree.glob('output/*/run-result.json'):
            result = read(path)
            measurements = result['summaries']['measurements']
            summary = measurements['measurements']
            if result['outcome'] != 'passed' or summary['grade'] != 'benchmark' or summary['gradeReasons']:
                raise ValueError('trial is not benchmark-grade')
            probe = measurements['write-probe']
            if probe['durability'] != 'on,on,on' or not probe['durable_drained']:
                raise ValueError('trial lacks durable progress')
            rows.append({'runId': result['runId'], 'comparison': result['comparison'], 'cohort': result['cohort'],
                         'fingerprint': result['fingerprint'], 'writeProbe': probe,
                         'backlog': measurements['backlog'], 'startup': measurements.get('startup'), 'measurements': summary,
                         'manifestSha256': digest(tree / 'manifest.json'),
                         'manifest': manifest, 'resultSha256': digest(path),
                         'rawPrefix': f"gs://{session['resultsBucket']}/runs/{manifest['runId']}/"})
    if not rows:
        raise ValueError('session has no benchmark results')
    return rows


def planned(operator, configuration, path, offered, seconds, cohort_file):
    args = [operator, 'plan', '--all', '--select',
            'kiroku/append/benchmark/subscription-hardening', '--placement', 'cell',
            '--seed', '7', '--dim', 'pg.durability=durable', '--dim', 'pg.version=18']
    for key, value in [('mode', configuration['mode']), ('width', configuration['width']),
                       ('fresh', str(configuration['fresh']).lower()),
                       ('append-batch', configuration['appendBatch']),
                       ('checkpoint-batch', configuration['checkpointBatch']), ('offered', offered)]:
        args += ['--set', f'mp12.{key}={value}']
    command(args + ['--out', path], cohort_file=cohort_file)
    plan = read(path)
    for run in plan['runs']:
        run['spec']['phases'] = {'warmUpSeconds': 60, 'steadySeconds': seconds, 'drainSeconds': 30}
        run['spec']['timeoutSeconds'] = seconds + 300
        run['estimateMinutes'] = math.ceil((seconds + 120) / 60)
    # This file has not been submitted; recording explicit phase overrides is
    # part of constructing its immutable workload specification.
    path.write_text(json.dumps(plan, indent=2) + '\n')
    return plan


def cell_args(operator, cell):
    args = [operator, 'cell']
    return args, ['--cell', cell, '--start'] + [part for setting in SETTINGS for part in ['--pg-setting', setting]]


def pilot(args):
    payload = read(args.control)
    original = 'e6ea66433c5320097b6afd3c4ca56cd18ba86bd0'
    store = [p for c in payload['cohortIdentity']['components'] for p in c['packages']
             if p['name'] == 'kiroku-store']
    if payload['harness']['dirty'] or payload['cohort'] != 'released' or len(store) != 1 or store[0]['source']['rev'] != original:
        raise ValueError('pilot requires the clean original pre-cohort control')
    inputs = {'matrixSha256': digest(HERE / 'matrix.json'), 'control': payload,
              'productionSha256': production_fingerprint()}
    if args.root.exists():
        if read(args.root / 'inputs.json') != inputs:
            raise ValueError('pilot inputs differ from the existing output')
    else:
        args.root.mkdir(parents=True)
        write(args.root / 'inputs.json', inputs)
    if (args.root / 'frozen-loads.json').exists():
        raise ValueError('offered loads are already frozen')
    cohort_file = args.root / 'operator-cohort.json'
    if cohort_file.exists():
        if read(cohort_file) != payload['cohortIdentity']:
            raise ValueError('operator cohort differs from the compiled control')
    else:
        write(cohort_file, payload['cohortIdentity'])
    rows = []
    for config in SPEC['configurations']:
        base = args.root / config['id']
        accepted = base.with_suffix('.pilot.json')
        if accepted.exists():
            rows.append(read(accepted))
            continue
        plan = base.with_suffix('.plan.json')
        prefix, common = cell_args(args.operator, args.cell)
        output = base / 'session'
        journal_path = output / 'session.json'
        if journal_path.exists():
            journal = read(journal_path)
            if (journal['planSha256'].removeprefix('sha256:') != digest(plan)
                    or journal['payloads'] != {'default': payload}
                    or journal['cell'] != args.cell):
                raise ValueError('saved pilot session differs from its frozen inputs')
            # Resume the same submitted trials; never replace an interrupted
            # pilot with a fresh sample or overwrite its original operator log.
            with base.with_suffix('.log').open('a') as log:
                code = subprocess.run([str(args.operator), 'cell', 'resume',
                                       '--session', str(output)], stdout=log,
                                      stderr=subprocess.STDOUT).returncode
        else:
            if plan.exists():
                raise ValueError('pilot plan exists without a session; inspect its log')
            planned(args.operator, config, plan, 0, 61, cohort_file)
            code = command(prefix + ['run'] + common + ['--payload', args.control, '--plan', plan,
                           '--granularity', 'run', '--cache-policy', 'cold', '--out', output],
                           base.with_suffix('.log'), cohort_file=cohort_file)
        if code:
            raise ValueError(f'capacity pilot failed: {config["id"]}; inspect its log')
        trials = collect(output / 'session.json')
        rates = [r['writeProbe']['calls'] / r['writeProbe']['elapsed'] for r in trials]
        if len(rates) < 3 or min(rates) < 5:
            raise ValueError('pilot needs three capacity trials and >=5 calls/s')
        row = {'configuration': config, 'trials': trials,
               'controlCallsPerSecond': rates,
               'belowOffered': math.floor(min(rates) * SPEC['belowCapacityFraction']),
               'nearOffered': math.floor(min(rates) * SPEC['nearCapacityFraction'])}
        write(accepted, row)
        rows.append(row)
    write(args.root / 'frozen-loads.json', {'schema': 'kiroku.mp12.frozen-loads/v1',
          'matrixSha256': digest(HERE / 'matrix.json'), 'control': payload,
          'productionSha256': production_fingerprint(), 'cases': rows})


def required_metrics(profile):
    return (['op.append.throughput'] if profile == 'capacity' else
            ['op.append.latency.p50', 'op.append.latency.p95', 'op.append.latency.p99'])


def trial_tag(seconds, pairs):
    return f'window-{seconds}-pairs-{pairs}'


def initial_duration(case, profile):
    offered = 0 if profile == 'capacity' else case[profile + 'Offered']
    return 61 if not offered else max(61, math.ceil(SPEC['minimumFixedLoadCalls'] / offered))


def calibration_anchor(frozen, profile):
    case = next(case for case in frozen['cases']
                if case['configuration']['id'] == SPEC['calibrationConfiguration'])
    calibrated_profile = 'capacity' if profile == 'capacity' else 'below'
    return case, calibrated_profile


def candidate_design(root, frozen, case, profile):
    anchor, calibrated_profile = calibration_anchor(frozen, profile)
    name = anchor['configuration']['id'] + '-' + calibrated_profile
    accepted = checked_calibration(root, name, calibrated_profile, digest(root / 'frozen-loads.json'))
    # Reuse the demonstrated steady window, rather than multiplying an
    # already-long low-rate case and collecting unnecessary extra arrivals.
    return max(initial_duration(case, profile), accepted['seconds']), accepted['pairs']


def resolution(path, calibrate, profile):
    spec = importlib.util.spec_from_file_location('resolution', HERE / 'check-comparison.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.check(read(path), calibrate, required_metrics(profile))


def checked_calibration(root, name, profile, frozen_digest):
    directory = root / 'calibration' / name
    accepted = read(directory / 'accepted.json')
    output = directory / trial_tag(accepted['seconds'], accepted['pairs'])
    recalculated = resolution(output / 'comparison.json', True, profile)
    if accepted['frozenLoadsSha256'] != frozen_digest or recalculated['status'] != 'pass' or recalculated != accepted['resolution']:
        raise ValueError(f'{name}: missing matching passed calibration')
    trials = [trial for session in sorted(output.glob('round-*/session.json'))
              for trial in collect(session)]
    if (trials != accepted['trials'] or accepted['pairs'] < SPEC['minimumPairs']
            or len(trials) < 2 * accepted['pairs'] or read(output / 'comparison.json')['pairCount'] != accepted['pairs']):
        raise ValueError(f'{name}: calibration raw evidence differs from its report')
    return accepted


def pairs(args, calibrate):
    frozen = read(args.root / 'frozen-loads.json')
    if frozen['matrixSha256'] != digest(HERE / 'matrix.json'):
        raise ValueError('matrix changed after offered loads were frozen')
    if frozen['productionSha256'] != production_fingerprint():
        raise ValueError('production source changed after the measurement inputs were frozen')
    if frozen['control'] != read(args.control):
        raise ValueError('control payload differs from capacity pilot')
    cohort_file = args.root / 'operator-cohort.json'
    if read(cohort_file) != frozen['control']['cohortIdentity']:
        raise ValueError('operator cohort differs from the compiled control')
    if not calibrate and not args.candidate:
        raise ValueError('compare requires --candidate')
    stage = 'calibration' if calibrate else 'comparison'
    target = args.control if calibrate else args.candidate
    candidate = read(target)
    if candidate['harness']['dirty'] or candidate['harness'] != frozen['control']['harness']:
        raise ValueError('both arms must use the same clean harness revision')
    if not calibrate:
        # Calibrate the measurement method on frequent checkpoint writes.
        # Every A/B cell still has to meet its own uncertainty limits.
        for profile in SPEC['calibrationProfiles']:
            name = SPEC['calibrationConfiguration'] + '-' + profile
            checked_calibration(args.root, name, profile, digest(args.root / 'frozen-loads.json'))
    for case in frozen['cases']:
        config = case['configuration']
        if calibrate and config['id'] != SPEC['calibrationConfiguration']:
            continue
        for profile in SPEC['profiles']:
            if calibrate and profile not in SPEC['calibrationProfiles']:
                continue
            name = config['id'] + '-' + profile
            offered = 0 if profile == 'capacity' else case[profile + 'Offered']
            duration = initial_duration(case, profile)
            directory = args.root / stage / name
            if directory.exists():
                if (directory / 'accepted.json').exists():
                    accepted = read(directory / 'accepted.json')
                    if accepted['frozenLoadsSha256'] != digest(args.root / 'frozen-loads.json') or accepted['resolution']['status'] != 'pass':
                        raise ValueError('existing accepted evidence differs from frozen inputs')
                    continue
                raise ValueError(f'output exists: {directory}; inspect/resume the owned operator session')
            directory.mkdir(parents=True)
            policy = read(HERE / 'policy.json')
            policy['metrics'] = [metric for metric in policy['metrics'] if metric['match'] in required_metrics(profile)]
            policy_file = directory / 'policy.json'
            write(policy_file, policy)
            limits = SPEC['calibrationWindows'] if calibrate else [{'durationMultiplier': 1, 'pairs': 5}]
            if not calibrate:
                duration, limits[0]['pairs'] = candidate_design(args.root, frozen, case, profile)
            for window in limits:
                seconds = duration * window['durationMultiplier']
                pairs_count = window['pairs']
                tag = trial_tag(seconds, pairs_count)
                plan = directory / f'{tag}.plan.json'
                planned(args.operator, config, plan, offered, seconds, cohort_file)
                prefix, common = cell_args(args.operator, args.cell)
                output = directory / tag
                code = command(prefix + ['pair'] + common + ['--baseline', args.control,
                       '--candidate', target, '--plan', plan, '--pairs', pairs_count,
                       '--max-replacements', '2', '--policy', policy_file, '--out', output],
                       directory / f'{tag}.log', cohort_file=cohort_file)
                if code not in (0, 3):
                    raise ValueError(f'cell pair failed ({code}); inspect {output}')
                verdict = resolution(output / 'comparison.json', calibrate, profile)
                sessions = sorted(output.glob('round-*/session.json'))
                trials = [trial for session in sessions for trial in collect(session)]
                evidence = {'schema': 'kiroku.mp12.matrix-cell/v1', 'name': name,
                            'configuration': config, 'profile': profile, 'offered': offered,
                            'seconds': seconds, 'pairs': pairs_count, 'resolution': verdict, 'trials': trials,
                            'comparison': read(output / 'comparison.json'),
                            'payloads': {'baseline': frozen['control'], 'candidate': candidate},
                            'planSha256': digest(plan), 'frozenLoadsSha256': digest(args.root / 'frozen-loads.json')}
                write(directory / f'{tag}.evidence.json', evidence)
                if verdict['status'] == 'pass':
                    write(directory / 'accepted.json', evidence)
                    break
                if not calibrate:
                    raise ValueError(f'{name}: {verdict["status"]}; acceptance remains open')
            else:
                raise ValueError(f'{name}: calibration remains inconclusive after all declared windows')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['pilot', 'calibrate', 'compare'])
    parser.add_argument('--operator', required=True)
    parser.add_argument('--cell', default='alpha')
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.stage == 'pilot':
            pilot(args)
        else:
            pairs(args, args.stage == 'calibrate')
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'MP-12 gate unfinished: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
