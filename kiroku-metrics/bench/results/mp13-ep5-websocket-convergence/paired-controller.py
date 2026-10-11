import hashlib, json, subprocess, time
from pathlib import Path
pub=Path('kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs')
candidate=pub.read_bytes()
control=subprocess.check_output(['git','show','c725aac:'+str(pub)])
started=time.monotonic()
deadline=started+720
journal=Path('/tmp/mp13-ep5-paired-journal.json')
def record(phase, **kw):
    journal.write_text(json.dumps(dict(phase=phase, elapsed_seconds=time.monotonic()-started, budget_seconds=720, candidate_sha256=hashlib.sha256(candidate).hexdigest(), control_sha256=hashlib.sha256(control).hexdigest(), **kw),indent=2)+'\n')
def run(case):
    record(case)
    with open('/tmp/mp13-ep5-paired-'+case+'.log','w') as log:
        result=subprocess.run(['cabal','bench','kiroku-store:kiroku-shibuya-overhead'],stdout=log,stderr=subprocess.STDOUT,timeout=max(1,deadline-time.monotonic()))
    if result.returncode: raise RuntimeError(f'{case} exited {result.returncode}')
    record(case+'_complete',exit_code=result.returncode)
try:
    pub.write_bytes(control)
    run('control')
finally:
    pub.write_bytes(candidate)
    record('candidate_restored')
try:
    run('candidate')
    record('complete',exit_code=0)
finally:
    assert pub.read_bytes()==candidate
