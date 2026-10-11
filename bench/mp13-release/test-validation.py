#!/usr/bin/env python3
"""Fault checks for the acceptance validator, including historical under-validation."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def fixture():
    paths = ['/streams?category=catalog&prefix=catalog-00009&limit=10', '/categories?limit=10', '/subscriptions/probe/dead-letters?limit=10', '/subscription-checkpoints']
    return dict(schema='mp13.inspection-trial/v2', arm='candidate', mode='active',
                database=dict(version='18.6', fsync='on', synchronous_commit='on', full_page_writes='on'),
                seconds=10.01, measurement_seconds=10, measured_appends=5000, total_appends=6000,
                durable_events=6001, raw_latency_us=[100.] * 5000, p50_us=100., p95_us=100., p99_us=100.,
                throughput=5000/10.01, wal_lsn_before='0/100', wal_lsn_after='0/200',
                observer=dict(ordered_exact_delivery=True, tail_events=6000, last_position=6001,
                              source_streams_seen=5000, verified_names=6000,
                              poll_responses=[(p, 200) for _ in range(10) for p in paths],
                              raw_lag_us=[200.] * 6000, lag_p99_us=200.))


class Validation(unittest.TestCase):
    def check(self, data):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'trial.json';path.write_text(json.dumps(data))
            return runner.validate(path, 'candidate', 'active')

    def test_valid(self):
        self.check(fixture())

    def test_rejects_faults(self):
        mutations = [
            lambda d: d.pop('schema'),
            lambda d: d['observer'].update(ordered_exact_delivery=False),
            lambda d: d['observer'].update(last_position=6000),
            lambda d: d['observer'].update(tail_events=6001),
            lambda d: d['observer'].update(verified_names=5999),
            lambda d: d['observer'].update(source_streams_seen=100),
            lambda d: d['observer'].update(poll_responses=[('/categories?limit=10', 200)]*40),
            lambda d: d['database'].update(fsync='off'),
            lambda d: d.update(durable_events=6000),
            lambda d: d.update(wal_lsn_after='0/100'),
            lambda d: d['raw_latency_us'].__setitem__(0, float('nan')),
            lambda d: d.update(seconds=9.9),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                data=copy.deepcopy(fixture());mutate(data)
                with self.assertRaises(ValueError): self.check(data)


if __name__ == '__main__': unittest.main()
