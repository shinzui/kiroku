#!/usr/bin/env python3
"""Bounded, retained local inspection diagnostic (never a release acceptance gate)."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import time


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(path, arm, mode):
    data = json.loads(path.read_text())
    if data['arm'] != arm or data['mode'] != mode or data['tail_errors']:
        raise ValueError('invalid trial identity or tail errors')
    raw = data['raw_latency_us']
    if len(raw) != data['measured_appends'] or len(raw) < 1000 or any(x <= 0 for x in raw):
        raise ValueError('invalid raw append samples')
    ordered = sorted(raw)
    for key, fraction in [('p50_us', .50), ('p95_us', .95), ('p99_us', .99)]:
        if ordered[math.floor(fraction * (len(raw)-1))] != data[key]:
            raise ValueError('percentile does not reproduce')
    if not math.isclose(len(raw)/data['seconds'], data['throughput']):
        raise ValueError('throughput does not reproduce')
    if mode == 'active':
        if data['tail_events'] != data['total_appends'] or len(data['poll_responses']) < 24:
            raise ValueError('missing tail delivery or polls')
        if arm == 'candidate' and data['resolved_names'] <= 4096:
            raise ValueError('distinct-name workload did not fill the cache')
    elif data['tail_events'] or data['poll_responses']:
        raise ValueError('disabled observers performed work')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--deadline', type=float, required=True, help='Original experiment UTC Unix deadline, including setup')
    parser.add_argument('--proof', action='store_true')
    parser.add_argument('--case', choices=['disabled', 'active', 'both'], default='both')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    journal = {'started': time.time(), 'deadline': args.deadline, 'binaries': {arm: {'path': str(getattr(args, arm)), 'sha256': digest(getattr(args, arm))} for arm in ('control','candidate')}, 'trials': [], 'status': 'running', 'acceptance': 'inconclusive: local diagnostic, no controlled-host calibration'}
    write(args.out/'journal.json', journal)
    modes = ('disabled', 'active') if args.case == 'both' else (args.case,)
    schedule = [('candidate', 'active', 'proof')] if args.proof else [(arm, mode, f'{mode}-{pair}-{arm}') for mode in modes for pair in range(3) for arm in (('control','candidate') if pair % 2 == 0 else ('candidate','control'))]
    try:
        for arm, mode, name in schedule:
            if args.deadline - time.time() < 90:
                raise TimeoutError('original experiment deadline has insufficient trial time')
            path = args.out/(name+'.json')
            trial = {'arm': arm, 'mode': mode, 'name': name, 'started': time.time(), 'status': 'running'}
            journal['trials'].append(trial)
            write(args.out/'journal.json', journal)
            with (args.out/(name+'.log')).open('w') as log:
                subprocess.run([str(getattr(args,arm)), arm, mode, str(path)], stdout=log, stderr=subprocess.STDOUT, timeout=min(90,args.deadline-time.time()), check=True)
            validate(path, arm, mode)
            trial.update(status='verified', completed=time.time(), sha256=digest(path))
            write(args.out/'journal.json', journal)
            print(name + ': verified', flush=True)
        if not args.proof:
            summary = {}
            for mode in modes:
                pairs = [(validate(args.out/f'{mode}-{pair}-control.json','control',mode), validate(args.out/f'{mode}-{pair}-candidate.json','candidate',mode)) for pair in range(3)]
                metrics = {}
                for key in ('throughput','p50_us','p95_us','p99_us'):
                    ratios = [math.log(b[key]/a[key]) for a,b in pairs]
                    mean = statistics.mean(ratios)
                    # Student t with two degrees of freedom, descriptive only.
                    half = 4.302652729 * statistics.stdev(ratios)/math.sqrt(3)
                    metrics[key] = {'candidate_change_percent': 100*math.expm1(mean), 'descriptive_95_interval_percent': [100*math.expm1(mean-half),100*math.expm1(mean+half)], 'pair_ratios': [math.exp(x) for x in ratios]}
                summary[mode] = metrics
            write(args.out/'summary.json', summary)
        journal['status'] = 'complete'
    except BaseException as error:
        journal.update(status='stopped', error=str(error))
        if journal['trials'] and journal['trials'][-1]['status'] == 'running':
            journal['trials'][-1].update(status='failed', error=str(error))
        raise
    finally:
        journal['finished'] = time.time()
        write(args.out/'journal.json', journal)


if __name__ == '__main__':
    main()
