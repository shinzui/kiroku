"""Synthetic checks of schedule integrity, drift cancellation and gate direction."""
import csv
import tempfile
import unittest
from pathlib import Path
import paired


class PairedTests(unittest.TestCase):
    def samples(self, destination, legacy_ratio=1, aa_ratio=1):
        stamp = 1
        with destination.open('w') as handle:
            writer = csv.writer(handle)
            writer.writerow('round,case,order,slot,arm,calls,start_ns,end_ns,duration_ns'.split(','))
            for round_id, case, order in paired.schedule(9701):
                for slot, arm in enumerate(order):
                    calls = 1200 if case == 'positive-20pct' and arm == 'B' else 1000
                    # Strong linear temporal drift, shared by both arms, cancels in ABBA.
                    base = 10000000 + round_id * 100000 + slot * 10000
                    scale = legacy_ratio if case.startswith('legacy') else aa_ratio
                    duration = round(base * (1.2 if case == 'positive-20pct' and arm == 'B' else scale if arm == 'B' else 1))
                    writer.writerow([round_id,case,order,slot,arm,calls,stamp,stamp+duration,duration])
                    stamp += duration + 100

    def analyze(self, **kwargs):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'samples.csv'
            self.samples(path, **kwargs)
            return paired.analyze(path, 9701)

    def test_identical_code_with_drift_passes_and_positive_control_detected(self):
        result = self.analyze()
        self.assertEqual(result['status'], 'passed')
        for case in result['cases']:
            self.assertAlmostEqual(case['ratio'], 1.2 if case['case']=='positive-20pct' else 1)

    def test_seventeen_percent_regression_fails(self):
        self.assertEqual(self.analyze(legacy_ratio=1.17)['status'], 'regression')

    def test_biased_identical_code_control_blocks_acceptance(self):
        result = self.analyze(aa_ratio=1.08)
        self.assertEqual(result['status'], 'inconclusive')
        self.assertFalse(result['controls_passed'])

    def test_missing_sample_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'samples.csv'
            self.samples(path)
            path.write_text('\n'.join(path.read_text().splitlines()[:-1])+'\n')
            with self.assertRaisesRegex(ValueError, 'incomplete rows'):
                paired.analyze(path, 9701)

    def test_interval_preserves_variation_and_comparison_direction(self):
        pairs = [(1, value) for value in (1, 2, 3, 4)]
        low, high = paired.interval(pairs, 1, 9701)
        # The exact four-draw distribution has mean 2.5 and wide tails.
        self.assertLess(low, 1.5)
        self.assertGreater(high, 3.5)
        inverse_low, inverse_high = paired.interval([(b, a) for a, b in pairs], 1, 9701)
        self.assertAlmostEqual(inverse_low, 1 / high)
        self.assertAlmostEqual(inverse_high, 1 / low)

    def test_schedule_is_balanced_reproducible_and_seeded(self):
        first=paired.schedule(9701)
        self.assertEqual(first, paired.schedule(9701))
        self.assertNotEqual(first, paired.schedule(9702))
        for case in paired.CASES:
            self.assertEqual(sum(c==case and order=='ABBA' for _,c,order in first),20)
            self.assertEqual(sum(c==case and order=='BAAB' for _,c,order in first),20)


if __name__ == '__main__':
    unittest.main()
