#!/usr/bin/env python3
"""Check IDs, matched varying inputs, interleaving and the persistent deadline."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('controller', Path(__file__).with_name('run.py'))
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
template = {'runs': [{'spec': {'knobs': {}, 'scenario': 'kiroku/append/benchmark/subscription-hardening'}}]}
for case in controller.CASES:
    plan = controller.plan(template, case, 5)
    assert uuid.UUID(plan['planId']).version == 7
    assert len(plan['runs']) == 10
    assert [row['spec']['comparison']['arm'] for row in plan['runs'][:4]] == ['baseline', 'candidate', 'candidate', 'baseline']
    for pair in range(5):
        first, second = [copy.deepcopy(row['spec']) for row in plan['runs'][2 * pair:2 * pair + 2]]
        assert first['seed'] == second['seed'] == 7 + pair
        assert {first['comparison']['arm'], second['comparison']['arm']} == {'baseline', 'candidate'}
        assert first['knobs']['mp13.index-layout'] != second['knobs']['mp13.index-layout']
        for value in [first, second]:
            assert uuid.UUID(value.pop('runId')).version == 7
            value.pop('comparison')
            value['knobs'].pop('mp13.index-layout')
        assert first == second
with tempfile.TemporaryDirectory(prefix='mp13-deadline-', dir='/tmp') as owned:
    root = Path(owned)
    controller.write(root / 'budget.json', {'started_epoch': 0, 'budget_seconds': 3600})
    assert controller.remaining(root) == 0
    assert controller.remaining(root) == 0
print('UUIDv7, matched pairs, AB/BA order and expired deadline checks passed')

valid = {'outcome': 'passed', 'summaries': {'measurements': {'measurements': {'grade': 'benchmark', 'gradeReasons': []}}}}
controller.validate_evidence_grade(valid)
invalid = copy.deepcopy(valid)
invalid['outcome'] = 'inconclusive'
invalid['summaries']['measurements']['measurements'].update(grade='exploratory', gradeReasons=['health:insufficient-samples'])
try:
    controller.validate_evidence_grade(invalid)
except ValueError as error:
    assert 'insufficient-samples' in str(error)
else:
    raise AssertionError('exploratory browse evidence must stop queue expansion')
print('early evidence-grade rejection check passed')

observer = copy.deepcopy(valid)
section = observer['summaries']['measurements']
section['measurements']['ops'] = {'append': {'count': 2000}}
section['write-probe'] = {'workload': {'mode': 'category'}}
section['browse-diagnostics'] = {
    'schema': 'mp13.browse-diagnostics/v1',
    'samples': [{'phase': 'steady', 'page': shape, 'started_ns': i * 1_000_000_000,
                 'duration_ns': 1000, 'rows': 0 if shape == 'absent' else 11}
                for i in range(61) for shape in ['first', 'late', 'absent']]}
controller.validate_browser_diagnostics(observer)
for change in ['missing', 'primary', 'short', 'absent', 'accelerated']:
    broken = copy.deepcopy(observer)
    section = broken['summaries']['measurements']
    if change == 'missing':
        section.pop('browse-diagnostics')
    elif change == 'primary':
        section['measurements']['ops']['browse'] = {'count': 183}
    elif change == 'short':
        section['browse-diagnostics']['samples'] = section['browse-diagnostics']['samples'][:9]
    elif change == 'absent':
        section['browse-diagnostics']['samples'][2]['rows'] = 1
    else:
        for row in section['browse-diagnostics']['samples']:
            row['started_ns'] //= 10
    try:
        controller.validate_browser_diagnostics(broken)
    except ValueError:
        pass
    else:
        raise AssertionError(f'bad observer evidence accepted: {change}')
comparison = {'verdict': 'inconclusive', 'pairCount': 5, 'policy': {'confidenceLevel': 0.95},
              'metrics': {'op.append.throughput': {'ratio': {'estimate': 1.0, 'low': 0.98, 'high': 1.02}},
                          'op.append.latency.p99': {'ratio': {'estimate': 1.01, 'low': 0.99, 'high': 1.03}}}}
estimates = controller.cost_estimates(comparison)
assert abs(estimates['metrics']['op.append.throughput']['upperSlowdownBoundPercent'] - 1.9607843137254943) < 1e-9
assert abs(estimates['metrics']['op.append.latency.p99']['upperSlowdownBoundPercent'] - 3) < 1e-9
assert comparison['verdict'] == 'inconclusive'
print('separate sparse diagnostics, realistic observer schedule and cost-bound conversion checks passed')
