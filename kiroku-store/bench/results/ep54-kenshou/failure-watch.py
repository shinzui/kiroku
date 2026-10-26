"""Stop this experiment's controller on the first verified invalid trial."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

PID = 71698
ROOT = Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/bench/results/ep54-kenshou/v2')
while True:
    identity = subprocess.run(['ps', '-p', str(PID), '-o', 'command='], capture_output=True, text=True)
    if identity.returncode or 'python3 kiroku-store/bench/results/ep54-kenshou/v4-controller.py' not in identity.stdout:
        break
    failures = []
    for case in ['disabled', 'active']:
        for path in (ROOT / case).rglob('session.json'):
            try:
                document = json.loads(path.read_text())
            except (ValueError, OSError):
                continue
            for row in document['slices']:
                if row['state'] == 'verified' and (row['cellOutcome'] != 'completed' or row['entryExitCode'] != 0):
                    failures.append(dict(session=str(path.relative_to(ROOT)), cellRun=row['cellRun'], outcome=row['cellOutcome'], exitCode=row['entryExitCode']))
    if failures:
        (ROOT / 'failure-watch-stop.json').write_text(json.dumps(dict(at=time.time(), failures=failures), indent=2) + '\n')
        os.kill(PID, signal.SIGINT)
        break
    time.sleep(5)
