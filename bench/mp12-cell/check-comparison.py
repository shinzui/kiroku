#!/usr/bin/env python3
"""Check ADR-11 resolution independently of Kenshou's slowdown policy.

The 1%/3% limits constrain confidence interval precision, never an accepted
slowdown. Control/control additionally requires an interval containing equality.
This checks one cell only; it cannot establish full-matrix acceptance.
"""
import argparse
import json
import math
from pathlib import Path

RESOLUTION = {
    'op.append.throughput': .01,
    'op.append.latency.p50': .01,
    'op.append.latency.p95': .03,
    'op.append.latency.p99': .03,
}


def check(comparison, calibrate, required_metrics=None):
    problems = list(comparison['reasons'])
    algorithm = comparison.get('algorithm', {})
    if (algorithm.get('name') != 'paired-bootstrap-t-envelope' or algorithm.get('version') != 1
            or algorithm.get('confidenceLevel', 0) < .95 or algorithm.get('iterations', 0) < 10000):
        problems.append('missing or weakened paired uncertainty algorithm')
    if comparison['pairCount'] < 5:
        problems.append('fewer than five valid pairs')
    if comparison['design'] not in ('abba', 'baab'):
        problems.append('trials are not alternating')
    rows = {}
    required = RESOLUTION if required_metrics is None else {name: RESOLUTION[name] for name in required_metrics}
    for name, resolution in required.items():
        metric = comparison['metrics'].get(name)
        if metric is None:
            problems.append(f'{name}: missing metric')
            continue
        ratio = metric['ratio']
        low, high = ratio['low'], ratio['high']
        if not (math.isfinite(low) and math.isfinite(high) and 0 < low <= high):
            problems.append(f'{name}: invalid interval')
            continue
        half_width = math.sqrt(high / low) - 1
        rows[name] = {'ratio': ratio, 'relativeHalfWidth': half_width,
                      'resolutionLimit': resolution, 'status': metric['status']}
        if half_width > resolution:
            problems.append(f'{name}: insufficient measurement precision')
        if calibrate:
            if not low <= 1 <= high:
                problems.append(f'{name}: control/control interval excludes equality')
        elif metric['relativeLimit'] != 0 or metric['absoluteFloor'] != 0:
            problems.append(f'{name}: a slowdown allowance was introduced')
        elif metric['status'] == 'regression' or low > 1:
            problems.append(f'{name}: confirmed adverse change')
        elif high > 1 + resolution:
            problems.append(f'{name}: possible adverse change exceeds bounded measurement uncertainty')
    if not calibrate and comparison['verdict'] not in ('pass', 'inconclusive'):
        problems.append(f'Kenshou verdict: {comparison["verdict"]}')
    regression = not calibrate and (comparison['verdict'] == 'regression' or
                  any(row['status'] == 'regression' or row['ratio']['low'] > 1 for row in rows.values()))
    status = 'regression' if regression else 'inconclusive' if problems else 'pass'
    return {'schema': 'kiroku.mp12.cell-resolution/v1', 'complete_matrix': False,
            'calibration': calibrate, 'status': status,
            'metrics': rows, 'problems': problems}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('comparison', type=Path)
    parser.add_argument('--calibrate', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = check(json.loads(args.comparison.read_text()), args.calibrate)
    result['comparison'] = str(args.comparison)
    with args.out.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['status'] == 'pass' else 2)


if __name__ == '__main__':
    main()
