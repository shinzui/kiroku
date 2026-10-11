#!/usr/bin/env python3
"""Opaque cell entry; database reset and lease lifecycle belong to the cell agent."""
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    control, candidate, gate, work, output = sys.argv[1:]
    out = Path(output)
    out.mkdir(parents=True, exist_ok=True)
    # Keep diagnostics in the manifest even on agents that omit entry logs.
    log = (out / 'entry.log').open('w')
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)
    spec = json.loads(Path(work).read_text())
    if spec['arm'] not in ('control', 'candidate') or spec['mode'] not in ('active', 'disabled', 'gate'):
        raise ValueError('invalid workload')
    environment = json.loads(Path(os.environ['CELL_ENV_FILE']).read_text())
    if environment['postgres']['major'] != 18:
        raise ValueError('requires PG18')
    env = dict(os.environ, MP13_DATABASE_URL=environment['postgres']['connectionString'],
               MP13_SQL_STATS_REQUIRED='1',
               MP13_WARMUP_SECONDS=str(spec['warmup_seconds']),
               MP13_MEASUREMENT_SECONDS=str(spec['measurement_seconds']))
    if spec['mode'] == 'gate':
        with (out / 'workload-gate.log').open('w') as log:
            result = subprocess.run([gate, '--stdev', '5'], env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=420)
        (out / 'gate.json').write_text(json.dumps(dict(exit_code=result.returncode)) + '\n')
        result.check_returncode()
        return
    executable = candidate if spec['arm'] == 'candidate' else control
    subprocess.run([executable, 'self-test'], env=env, check=True, timeout=10)
    subprocess.run([executable, spec['arm'], spec['mode'], str(out / 'trial.json')],
                   env=env, check=True, timeout=spec['warmup_seconds'] + spec['measurement_seconds'] + 90)


if __name__ == '__main__':
    main()
