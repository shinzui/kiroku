#!/usr/bin/env python3
"""Fault checks for deadline admission and recovery; no cloud calls."""
import importlib.util
import json
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


if __name__ == "__main__": unittest.main()
