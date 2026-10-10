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
