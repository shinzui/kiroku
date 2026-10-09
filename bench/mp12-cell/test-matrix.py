"""Tests for coverage, source/evidence refusal and stage ordering."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


matrix = load('matrix', 'run-matrix.py')
gate = load('gate', 'check-matrix.py')


class MatrixContract(unittest.TestCase):
    def test_representative_coverage(self):
        configurations = matrix.SPEC['configurations']
        self.assertEqual({(c['width'], c['fresh'], c['appendBatch']) for c in configurations},
                         {(width, fresh, batch) for width in [1, 4] for fresh in [False, True] for batch in [1, 100]})
        for mode in ['none', 'idle', 'all', 'category', 'group-all', 'group-category', 'adapter']:
            rows = [c for c in configurations if c['mode'] == mode]
            self.assertEqual({c['width'] for c in rows}, {1, 4})
            self.assertEqual({c['fresh'] for c in rows}, {False, True})
            self.assertEqual({c['appendBatch'] for c in rows}, {1, 100})
            self.assertEqual({c['checkpointBatch'] for c in rows}, {1, 100})
        self.assertEqual(matrix.SPEC['profiles'], ['capacity', 'below', 'near'])

    def test_capacity_and_latency_have_distinct_primary_metrics(self):
        self.assertEqual(matrix.required_metrics('capacity'), ['op.append.throughput'])
        self.assertEqual(set(matrix.required_metrics('below')),
                         {'op.append.latency.p50', 'op.append.latency.p95', 'op.append.latency.p99'})

    def test_missing_evidence_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(FileNotFoundError):
                gate.verify(Path(temp))

    def test_source_change_invalidates_prior_measurements(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            matrix.write(root / 'frozen-loads.json', {'matrixSha256': matrix.digest(HERE / 'matrix.json'),
                         'productionSha256': 'old'})
            with patch.object(gate.matrix, 'production_fingerprint', return_value='new'):
                with self.assertRaisesRegex(ValueError, 'production source differs'):
                    gate.verify(root)

    def test_candidate_cannot_start_before_the_whole_calibration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = {'harness': {'dirty': False, 'revision': 'clean'}, 'cohortIdentity': {'compiled': 'control'}}
            matrix.write(root / 'control.json', payload)
            matrix.write(root / 'candidate.json', payload)
            matrix.write(root / 'operator-cohort.json', payload['cohortIdentity'])
            matrix.write(root / 'frozen-loads.json', {'matrixSha256': matrix.digest(HERE / 'matrix.json'),
                         'productionSha256': 'source', 'control': payload,
                         'cases': [{'configuration': c} for c in matrix.SPEC['configurations']]})
            args = argparse.Namespace(root=root, control=root / 'control.json', candidate=root / 'candidate.json')
            with patch.object(matrix, 'production_fingerprint', return_value='source'), patch.object(matrix, 'command') as execute:
                with self.assertRaises(FileNotFoundError):
                    matrix.pairs(args, False)
                execute.assert_not_called()

    def test_operator_uses_the_compiled_cohort_in_any_working_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            cohort = Path(temp) / 'operator-cohort.json'
            matrix.write(cohort, {'compiled': 'control'})
            with patch.object(matrix.subprocess, 'run') as execute:
                execute.return_value.returncode = 0
                matrix.command(['operator', 'plan'], cohort_file=cohort)
                self.assertEqual(execute.call_args.kwargs['env']['KENSHOU_COHORT_IDENTITY'], str(cohort.resolve()))

    def test_corrupted_sealed_sample_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tree = root / 'tree'
            tree.mkdir()
            (tree / 'sample.raw').write_bytes(b'original')
            manifest = {'artifacts': [{'path': 'sample.raw', 'bytes': 8,
                                      'sha256': hashlib.sha256(b'original').hexdigest()}]}
            matrix.write(tree / 'manifest.json', manifest)
            matrix.write(root / 'session.json', {'slices': [{'state': 'verified', 'cellOutcome': 'completed',
                         'fetchedPath': str(tree), 'cellRun': 'run', 'manifestSha256': matrix.digest(tree / 'manifest.json')}]})
            (tree / 'sample.raw').write_bytes(b'mutated!')
            with self.assertRaisesRegex(ValueError, 'corrupt artifact'):
                matrix.collect(root / 'session.json')


if __name__ == '__main__':
    unittest.main()
