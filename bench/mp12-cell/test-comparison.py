"""Regression tests for fail-closed acceptance of externally measured evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('check-comparison.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def evidence():
    return {'reasons': [], 'pairCount': 5, 'design': 'abba', 'verdict': 'pass',
            'algorithm': {'name': 'paired-bootstrap-t-envelope', 'version': 1,
                          'confidenceLevel': .95, 'iterations': 10000},
            'metrics': {name: {'ratio': {'low': .998, 'estimate': 1, 'high': 1.002},
                               'status': 'pass', 'relativeLimit': 0, 'absoluteFloor': 0}
                        for name in gate.RESOLUTION}}


class ComparisonAcceptance(unittest.TestCase):
    def test_weaker_or_missing_uncertainty_is_not_accepted(self):
        for field, value in [('confidenceLevel', .9), ('iterations', 1000), ('name', 'unpaired')]:
            data = evidence()
            data['algorithm'][field] = value
            self.assertEqual(gate.check(data, True)['status'], 'inconclusive')

    def test_narrow_unbiased_calibration(self):
        self.assertEqual(gate.check(evidence(), True)['status'], 'pass')

    def test_wide_intervals_do_not_establish_equivalence(self):
        data = evidence()
        data['metrics']['op.append.latency.p50']['ratio'] = {'low': .98, 'estimate': 1, 'high': 1.02}
        self.assertEqual(gate.check(data, True)['status'], 'inconclusive')

    def test_systematic_control_arm_bias_requires_investigation(self):
        data = evidence()
        data['metrics']['op.append.latency.p99']['ratio'] = {'low': 1.001, 'estimate': 1.002, 'high': 1.003}
        self.assertEqual(gate.check(data, True)['status'], 'inconclusive')

    def test_missing_tail_metric_or_health_failure_refuses_calibration(self):
        for failure in ('missing', 'health'):
            data = copy.deepcopy(evidence())
            if failure == 'missing':
                del data['metrics']['op.append.latency.p95']
            else:
                data['reasons'] = ['an input run has a hard health observation']
            self.assertEqual(gate.check(data, True)['status'], 'inconclusive')

    def test_precision_limits_cannot_become_slowdown_allowances(self):
        data = evidence()
        data['metrics']['op.append.latency.p50']['relativeLimit'] = .01
        self.assertEqual(gate.check(data, False)['status'], 'inconclusive')

    def test_unchanged_candidate_does_not_need_to_prove_a_speedup(self):
        data = evidence()
        data['verdict'] = 'inconclusive'
        for metric in data['metrics'].values():
            metric['status'] = 'inconclusive'
        self.assertEqual(gate.check(data, False)['status'], 'pass')
        data = evidence()
        for metric in data['metrics'].values():
            metric['ratio'] = {'low': .995, 'estimate': .997, 'high': .999}
        self.assertEqual(gate.check(data, False)['status'], 'pass')

    def test_narrow_confirmed_slowdown_below_precision_limit_still_blocks(self):
        data = evidence()
        data['metrics']['op.append.latency.p50']['ratio'] = {'low':1.001,'estimate':1.002,'high':1.003}
        self.assertEqual(gate.check(data, False)['status'], 'regression')

    def test_nonsignificance_without_bounded_uncertainty_is_not_enough(self):
        data = evidence()
        data['metrics']['op.append.latency.p50']['ratio'] = {'low':.999,'estimate':1.006,'high':1.013}
        self.assertEqual(gate.check(data, False)['status'], 'inconclusive')

    def test_confirmed_regression_is_preserved(self):
        data = evidence()
        data['verdict'] = 'regression'
        data['metrics']['op.append.latency.p95']['status'] = 'regression'
        self.assertEqual(gate.check(data, False)['status'], 'regression')


if __name__ == '__main__':
    unittest.main()
