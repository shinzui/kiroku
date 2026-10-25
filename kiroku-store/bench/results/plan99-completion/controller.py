import csv, datetime, hashlib, json, math, os, pathlib, shutil, signal, subprocess, sys, time
end = datetime.datetime.fromisoformat('2026-10-25T17:26:53+00:00').timestamp()
label, *cmd = sys.argv[1:]
root = pathlib.Path('kiroku-store/bench/results/plan99-completion')
log = root / (label + '.log')
if log.exists():
    sys.exit('Refusing to overwrite retained run ' + label)
start = time.time()
if start >= end:
    sys.exit('Plan 99 completion budget expired')
inputs = ['kiroku-store/bench/RegressionGate.hs', 'kiroku-store/bench/check-gate-spread.sh', 'kiroku-store/src/Kiroku/Store/Effect.hs', 'Justfile']
record = dict(label=label, command=cmd, started_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), load=os.getloadavg(), inputs={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in inputs})
with log.open('w') as output:
    process = subprocess.Popen(cmd, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        rc = process.wait(timeout=min(600, end-start))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
        rc = 124
if 'just' in cmd and ('perf-workload-gate' in cmd or 'perf-check' in cmd):
    csv = pathlib.Path('kiroku-store/bench/results/workload-gate.csv')
    if csv.exists(): shutil.copyfile(csv, root / (label + '.csv'))
record['command_exit_code'] = rc
if label.startswith('focused-') and rc == 0:
    try:
        with (root / (label + '.csv')).open() as source:
            rows = list(csv.DictReader(source))
        assert len(rows) == 3
        for row in rows:
            if '.warm-' not in row['Name']:
                mean, spread = float(row['Mean (ps)']), float(row['2*Stdev (ps)'])
                assert math.isfinite(mean) and mean > 0 and math.isfinite(spread) and 0 <= spread <= .2 * mean, row['Name']
        record['focused_spread_valid'] = True
    except (OSError, ValueError, AssertionError) as error:
        record['validation_error'] = str(error)
        rc = 1
record.update(exit_code=rc, elapsed_seconds=round(time.time()-start, 2), finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
with (root/'journal.jsonl').open('a') as journal:
    journal.write(json.dumps(record)+'\n')
print(log.read_text()[-9000:])
print(json.dumps(record))
sys.exit(rc)
