#!/usr/bin/env python3
"""Fault checks for deadline admission and recovery; no cloud calls."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("controller", Path(__file__).with_name("run-cell.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.handler = signal.getsignal(signal.SIGTERM)
        (self.root / "budget.json").write_text(json.dumps(dict(started_epoch=time.time(), budget_seconds=3600)))
        (self.root / "payload.json").write_text("{}")
        self.args = SimpleNamespace(out=self.root / "run", budget=self.root / "budget.json",
            payload=self.root / "payload.json", cellctl="must-not-execute", infra=self.root,
            proof=False, gate=True, case="both", seconds_per_trial=100, resume=False)

    def tearDown(self):
        signal.signal(signal.SIGTERM, self.handler)
        self.tmp.cleanup()

    def test_expired_budget_never_acquires(self):
        (self.root / "budget.json").write_text(json.dumps(dict(started_epoch=time.time()-3601, budget_seconds=3600)))
        controller = module.Controller(self.args)
        with patch.object(controller, "acquire") as acquire:
            with self.assertRaises(TimeoutError): controller.run()
            acquire.assert_not_called()
        self.assertEqual(module.read(controller.journal_path)["status"], "stopped")

    def test_setup_resume_preserves_deadline_and_archives_failure(self):
        controller = module.Controller(self.args)
        original = controller.deadline
        controller.journal.update(status="stopped", lease_release_exit=0, error="fixture")
        controller.save()
        self.args.resume = True
        resumed = module.Controller(self.args)
        self.assertEqual(resumed.deadline, original)
        self.assertEqual(module.read(self.args.out / "setup-attempt-0/journal.json")["error"], "fixture")

    def test_submitted_trial_cannot_be_retried(self):
        controller = module.Controller(self.args)
        controller.journal.update(status="stopped", lease_release_exit=0, trials=[dict(status="failed")])
        controller.save()
        self.args.resume = True
        with self.assertRaisesRegex(RuntimeError, "existing run"):
            module.Controller(self.args)

    def test_timeout_kills_descendants_holding_pipes(self):
        controller = module.Controller(self.args)
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            controller.command([sys.executable, "-c", "import os,time; os.fork(); print('started',flush=True); time.sleep(60)"], "timeout", timeout=.15)
        self.assertLess(time.monotonic() - started, 3)
        self.assertIn("started", (self.args.out / "timeout.stdout").read_text())

    def test_sequence_holds_one_lease_for_proof_and_twenty_trials(self):
        self.args.gate=False
        self.args.sequence=True
        controller=module.Controller(self.args)
        with patch.object(controller,'acquire') as acquire, patch.object(controller,'trial') as trial, patch.object(controller,'cleanup') as cleanup:
            controller.run()
        acquire.assert_called_once()
        cleanup.assert_called_once()
        self.assertEqual(trial.call_count,21)
        self.assertEqual(trial.call_args_list[0].args,('candidate','active','proof'))
        self.assertEqual(trial.call_args_list[1].args,('control','disabled','disabled-0-control'))

    def test_exited_wrapper_does_not_wait_for_descendant_output_eof(self):
        controller=module.Controller(self.args)
        code="import os,time\npid=os.fork()\nif pid: print(pid,flush=True)\nelse: time.sleep(30)\n"
        try:
            result=controller.command([sys.executable,'-c',code],'inherited-output',timeout=1)
            self.assertEqual(result.returncode,0)
            self.assertGreater(int(result.stdout.strip()),0)
        finally:
            output=self.args.out/'inherited-output.stdout'
            if output.exists() and output.read_text().strip():
                try:os.kill(int(output.read_text().strip()),signal.SIGKILL)
                except ProcessLookupError:pass

    def test_failed_proof_never_expands_queue(self):
        self.args.gate=False
        self.args.sequence=True
        controller=module.Controller(self.args)
        with patch.object(controller,'acquire'), patch.object(controller,'trial',side_effect=ValueError('proof failure')) as trial, patch.object(controller,'cleanup') as cleanup:
            with self.assertRaisesRegex(ValueError,'proof failure'): controller.run()
        trial.assert_called_once()
        cleanup.assert_called_once()

    def test_checkpoint_envelope_rejects_activity(self):
        folder=self.root/'checkpoints';folder.mkdir()
        postgres=dict(num_timed=0,num_requested=1,num_done=1,buffers_written=100,
            stats_reset='frozen',checkpoint=dict(checkpoint_lsn='0/100'),activity=[dict(wait_event='CheckpointerMain')])
        rows=[dict(unix_ns=n*10**9,monotonic_ns=n*10**9,postgres=postgres.copy()) for n in range(31)]
        module.write(folder/'checkpoint-window.json',dict(errors=[],samples=31,started_unix_ns=1,finished_unix_ns=29*10**9))
        def save(): (folder/'checkpoints.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
        save()
        self.assertEqual(module.validate_checkpoints(folder)['overlap_fraction'],0)
        rows[15]['postgres']['num_done']=2
        save()
        with self.assertRaisesRegex(ValueError,'checkpoint activity'):module.validate_checkpoints(folder)


if __name__ == "__main__": unittest.main()
