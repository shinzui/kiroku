#!/usr/bin/env python3
"""Repair proof and fixed five-pair cases, retaining the original experiment deadline."""
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku')
SPEC = importlib.util.spec_from_file_location('controller', ROOT / 'bench/ep54-cell/run.py')
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
C.OPERATOR = '/nix/store/298a0vi9z4snf83z83zgi3fjg126v1fw-kenshou-ep54-cell-0.1.0.0/bin/ep54-operator'
C.RESULTS = C.RESULTS / 'v2'
C.RESULTS.mkdir(exist_ok=True)


def plan(mode, label):
    target = C.RESULTS / f'{label}.plan.json'
    C.command([C.OPERATOR, 'plan', '--all', '--select', 'kiroku/append/benchmark/category-namespace',
               '--placement', 'cell', '--seed', '7', '--dim', 'pg.durability=durable', '--dim', 'pg.version=18',
               '--set', f'ep54.mode={mode}', '--out', target], f'plan-{label}')
    document = json.loads(target.read_text())
    target.with_suffix('.generated.json').write_text(json.dumps(document, indent=2) + '\n')
    for entry in document['runs']:
        entry['spec']['phases'] = dict(warmUpSeconds=10, steadySeconds=20, drainSeconds=30)
    document['ep54MeasurementOverride'] = dict(reason='Fit both fixed five-pair cases within the approved cumulative 90-minute budget; statistical criteria unchanged', warmup=10, steady=20, observed_full_trial_seconds=116)
    target.write_text(json.dumps(document, indent=2) + '\n')
    return target


def pair(label, document, pairs):
    C.command(C.cell('pair', '--cell', 'alpha', '--start', '--baseline', C.RESULTS / 'released-payload.json',
                      '--candidate', C.RESULTS / 'head-payload.json', '--plan', document,
                      '--policy', 'bench/mp12-cell/policy.json', '--pairs', str(pairs), '--max-replacements', '0',
                      '--pg-setting', 'shared_buffers=128MB', '--pg-setting', 'fsync=on',
                      '--pg-setting', 'synchronous_commit=on', '--pg-setting', 'full_page_writes=on',
                      '--out', C.RESULTS / label), f'pair-{label}', minimum=pairs * 220, accepted=(0, 1, 3), monitor=True)
    C.status(f'{label}-released-status')
    comparison = json.loads((C.RESULTS / label / 'comparison.json').read_text())
    if comparison['verdict'] == 'regression':
        raise RuntimeError('consistent adverse comparison; stop and diagnose before adding coverage')
    return comparison


def verify_measurement_proof():
    journal = json.loads((C.RESULTS / 'measurement-proof/session.json').read_text())
    planned = json.loads((C.RESULTS / 'measurement-proof.plan.json').read_text())
    if len(journal['slices']) != len(planned['runs']) or any(row['state'] != 'verified' or row['cellOutcome'] != 'completed' or row['entryExitCode'] != 0 for row in journal['slices']):
        raise RuntimeError('measurement proof has invalid or unfinished slices')
    summaries = []
    for row in journal['slices']:
        for identifier in row['runIds']:
            result = C.RESULTS / row['cellRun'] / 'tree/output' / identifier / 'run-result.json'
            run = json.loads(result.read_text())
            summary = run['summaries']['measurements']['measurements']
            if run['exitCode'] or summary['grade'] != 'benchmark':
                raise RuntimeError('measurement proof lacks benchmark grade')
            probe = run['summaries']['measurements']['namespace-comparison']
            if not probe['namespace']['exact_ordered_delivery'] or not probe['observer']['ordered_exact_delivery']:
                raise RuntimeError('active namespace or observer oracle did not pass')
            if summary['ops']['append']['count'] != probe['measured_appends']:
                raise RuntimeError('recorder and independent append counts disagree')
            summaries.append(dict(run=run['runId'], grade=summary['grade'], arm=probe['arm']))
    C.save('measurement-proof-completed.json', summaries)


try:
    C.status('verified-proof-before-expansion')
    verify_measurement_proof()
    if C.remaining() < 20 * 110 + 180:
        raise RuntimeError('the fixed 20-trial queue no longer fits the remaining budget')
    for case in ['disabled', 'active']:
        pair(case, plan(case, case), 5)
finally:
    C.cleanup()
