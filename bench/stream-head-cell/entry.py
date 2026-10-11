#!/usr/bin/env python3
"""Run unchanged timing actions against cell-reset PostgreSQL databases."""
import json, os, pathlib, subprocess, sys, time
head, gate, paired, analysis_file, work_file, out_path = sys.argv[1:]
work = json.loads(pathlib.Path(work_file).read_text())
kind = work['kind']
if kind not in ('proof', 'head', 'gate', 'paired-proof', 'paired-1', 'paired-2'):
    raise ValueError('unknown work kind')
environment = json.loads(pathlib.Path(os.environ['CELL_ENV_FILE']).read_text())
if environment['postgres']['major'] != 18:
    raise ValueError('PostgreSQL 18 required')
out = pathlib.Path(out_path)
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, EP97_DATABASE_URL=environment['postgres']['connectionString'])
if kind.startswith('paired'):
    import runpy
    analysis = runpy.run_path(analysis_file, run_name='paired_module')
    proof = kind == 'paired-proof'
    rounds, calls = (4, 100) if proof else (40, 1000)
    seed = work['seed']
    schedule = analysis['schedule'](seed, rounds)
    (out/'schedule.csv').write_text(''.join(','.join(map(str, row))+'\n' for row in schedule))
    command = [paired, str(out/'schedule.csv'), str(out/'samples.csv'), str(calls)]
else:
    command = [gate if kind == 'gate' else head, '--time-mode', 'wall', '--stdev', '5', '--csv', str(out/'timings.csv')]
    if kind != 'gate':
        command += ['--timeout', '60s' if kind == 'head' else '10s']
    if kind == 'proof':
        command += ['--pattern', '$(NF-1) == "100" && $NF == "production-with-head"']
start = time.time()
with (out/'benchmark.log').open('w') as log:
    result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=work['seconds'])
exit_code = result.returncode
if kind.startswith('paired') and exit_code == 0:
    estimates = analysis['analyze'](out/'samples.csv', seed, rounds, calls, proof)
    (out/'analysis.json').write_text(json.dumps(estimates, indent=2)+'\n')
    if estimates['status'] not in ('passed', 'proof-valid'):
        exit_code = 3
(out/'summary.json').write_text(json.dumps(dict(kind=kind, exit_code=exit_code, elapsed_seconds=time.time()-start, command=command), indent=2)+'\n')
sys.exit(exit_code)
