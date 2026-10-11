#!/usr/bin/env python3
"""Collect checkpoint evidence around the unchanged frozen workload binary."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

entry, work, output = sys.argv[1:]
out = Path(output)
out.mkdir(parents=True, exist_ok=True)
environment = json.loads(Path(os.environ['CELL_ENV_FILE']).read_text())
connection = environment['postgres']['connectionString']
stop = threading.Event()
errors = []
samples = []

def sample():
    result = subprocess.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-d', connection,
        '-c', 'SELECT public.mp13_checkpoint_snapshot()'], capture_output=True,
        text=True, check=True, timeout=5)
    row = dict(unix_ns=time.time_ns(), monotonic_ns=time.monotonic_ns(),
               postgres=json.loads(result.stdout))
    samples.append(row)
    with (out / 'checkpoints.jsonl').open('a') as stream:
        stream.write(json.dumps(row) + '\n')

def poll():
    while not stop.wait(1):
        try: sample()
        except Exception as error:
            errors.append(str(error))
            return

sample()
started = time.time_ns()
worker = threading.Thread(target=poll)
worker.start()
try:
    result = subprocess.run([entry, work, output], timeout=135)
finally:
    finished = time.time_ns()
    stop.set()
    worker.join(timeout=6)
    sample()
    (out / 'checkpoint-window.json').write_text(json.dumps(dict(
        started_unix_ns=started, finished_unix_ns=finished,
        errors=errors, samples=len(samples), covers='entire entry including fixture and warmup')) + '\n')
if errors: raise RuntimeError(errors)
result.check_returncode()
