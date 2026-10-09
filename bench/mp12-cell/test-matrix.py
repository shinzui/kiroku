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
    def test_checkpoint_change_coverage(self):
        configurations = matrix.SPEC['configurations']
        self.assertEqual(len(configurations), 5)
        self.assertEqual({c['mode'] for c in configurations},
                         {'none', 'category', 'group-all', 'group-category', 'adapter'})
        groups = [c for c in configurations if c['mode'].startswith('group-')]
        self.assertEqual({c['checkpointBatch'] for c in groups}, {1, 100})
        self.assertEqual({c['width'] for c in configurations}, {1, 4})
        self.assertEqual({c['fresh'] for c in configurations}, {False, True})
        self.assertEqual({c['appendBatch'] for c in configurations}, {1, 100})
        self.assertEqual(matrix.SPEC['calibrationProfiles'], ['capacity', 'below'])
        self.assertIn(matrix.SPEC['calibrationConfiguration'], {c['id'] for c in groups})
        self.assertEqual(matrix.SPEC['profiles'], ['capacity', 'below', 'near'])

    def test_fixed_load_case_inherits_predeclared_calibration_effort(self):
        anchor = {'configuration': {'id': matrix.SPEC['calibrationConfiguration']}, 'belowOffered': 100}
        case = {'configuration': {'id': 'other'}, 'nearOffered': 50}
        frozen = {'cases': [anchor, case]}
        with patch.object(matrix, 'checked_calibration', return_value={'seconds':610, 'pairs':20}), patch.object(matrix, 'digest', return_value='frozen'):
            seconds, pairs = matrix.candidate_design(Path('/unused'), frozen, case, 'near')
            self.assertEqual((seconds, pairs), (610,20))
            case['nearOffered'] = 1
            self.assertEqual(matrix.candidate_design(Path('/unused'), frozen, case, 'near'), (6100,20))

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

    def test_interrupted_pilot_resumes_same_session_and_refuses_changed_plan(self):
        for changed in [False, True]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                config = matrix.SPEC['configurations'][0]
                payload = {'harness': {'dirty': False}, 'cohort': 'released',
                           'cohortIdentity': {'components': [{'packages': [{
                               'name': 'kiroku-store', 'source': {
                                   'rev': 'e6ea66433c5320097b6afd3c4ca56cd18ba86bd0'}}]}]}}
                matrix.write(root / 'control.json', payload)
                matrix.write(root / 'inputs.json', {'matrixSha256': matrix.digest(HERE / 'matrix.json'),
                             'control': payload, 'productionSha256': 'source'})
                base = root / config['id']
                matrix.write(base.with_suffix('.plan.json'), {'saved': True})
                session = base / 'session'
                session.mkdir(parents=True)
                matrix.write(session / 'session.json', {'cell': 'alpha', 'payloads': {'default': payload},
                             'planSha256': 'changed' if changed else matrix.digest(base.with_suffix('.plan.json'))})
                args = argparse.Namespace(root=root, control=root / 'control.json', operator='operator', cell='alpha')
                trials = [{'writeProbe': {'calls': 6100, 'elapsed': 61}}] * 3
                spec = dict(matrix.SPEC, configurations=[config])
                with patch.object(matrix, 'SPEC', spec), patch.object(matrix, 'production_fingerprint', return_value='source'), patch.object(matrix, 'planned') as plan, patch.object(matrix, 'collect', return_value=trials), patch.object(matrix.subprocess, 'run') as execute:
                    execute.return_value.returncode = 0
                    if changed:
                        with self.assertRaisesRegex(ValueError, 'saved pilot session differs'):
                            matrix.pilot(args)
                        execute.assert_not_called()
                    else:
                        matrix.pilot(args)
                        self.assertEqual(execute.call_args.args[0], ['operator', 'cell', 'resume', '--session', str(session)])
                        self.assertTrue((root / 'frozen-loads.json').exists())
                    plan.assert_not_called()


if __name__ == '__main__':
    unittest.main()
