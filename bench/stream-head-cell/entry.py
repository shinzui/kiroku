#!/usr/bin/env python3
"""Run unchanged timing actions against cell-reset PostgreSQL databases."""
import json, os, pathlib, subprocess, sys, time
head, gate, work_file, out_path = sys.argv[1:]
work = json.loads(pathlib.Path(work_file).read_text())
kind = work['kind']
if kind not in ('proof', 'head', 'gate'):
    raise ValueError('unknown work kind')
environment = json.loads(pathlib.Path(os.environ['CELL_ENV_FILE']).read_text())
if environment['postgres']['major'] != 18:
    raise ValueError('PostgreSQL 18 required')
out = pathlib.Path(out_path)
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, EP97_DATABASE_URL=environment['postgres']['connectionString'])
command = [gate if kind == 'gate' else head, '--time-mode', 'wall', '--stdev', '5', '--csv', str(out/'timings.csv')]
if kind != 'gate':
    command += ['--timeout', '60s' if kind == 'head' else '10s']
if kind == 'proof':
    command += ['--pattern', '$(NF-1) == "100" && $NF == "production-with-head"']
start = time.time()
with (out/'benchmark.log').open('w') as log:
    result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=work['seconds'])
(out/'summary.json').write_text(json.dumps(dict(kind=kind, exit_code=result.returncode, elapsed_seconds=time.time()-start, command=command), indent=2)+'\n')
sys.exit(result.returncode)
