"""Guard against stopping another lease and observing a queued future slice."""
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ep54_run', Path(__file__).with_name('run.py'))
RUN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUN)


class OwnershipTests(unittest.TestCase):
    def test_other_lease_prevents_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            (results / 'owned-cell.json').write_text('{}')
            current = dict(lease=dict(leaseId='another-owner'))
            response = types.SimpleNamespace(returncode=0, stdout=json.dumps(current), stderr='')
            with patch.object(RUN, 'RESULTS', results), patch.object(RUN.subprocess, 'run', return_value=response) as command:
                RUN.cleanup()
            self.assertEqual(command.call_count, 1)
            self.assertIn('cleanup-refused-other-lease', (results / 'controller.jsonl').read_text())

    def test_watch_submitted_slice_before_future_planned_slice(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            (results / 'session.json').write_text(json.dumps(dict(slices=[
                dict(cellRun='current', state='submitted'),
                dict(cellRun='future', state='planned')])))
            responses = [types.SimpleNamespace(returncode=0, stdout='{"runId":"current","phase":"running"}', stderr=''),
                         types.SimpleNamespace(returncode=0, stdout='[]', stderr='')]
            with patch.object(RUN, 'RESULTS', results), patch.object(RUN.subprocess, 'run', side_effect=responses) as command:
                observation = json.loads(RUN.observe())
            self.assertIn('/submissions/current/status.json', command.call_args_list[0].args[0][3])
            self.assertEqual(observation['remote']['phase'], 'running')


if __name__ == '__main__':
    unittest.main()
