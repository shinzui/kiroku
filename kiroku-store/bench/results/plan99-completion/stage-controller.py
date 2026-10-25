import pathlib, subprocess, sys
root=pathlib.Path.cwd()
for label in ['focused-batched-2','focused-batched-3']:
 csv=root/'kiroku-store/bench/results/plan99-completion'/f'{label}.csv'
 cmd=['python3','kiroku-store/bench/results/plan99-completion/controller.py',label,'nix','develop','--no-write-lock-file','-c','cabal','bench','kiroku-store:kiroku-store-bench-workload-gate',f'--benchmark-options=--stdev 5 -p /append-40/ --csv {csv}']
 result=subprocess.run(cmd)
 if result.returncode: sys.exit(result.returncode)
for label,recipe in [('full-batched-1','perf-workload-gate'),('full-batched-2','perf-workload-gate'),('full-batched-3','perf-check')]:
 result=subprocess.run(['python3','kiroku-store/bench/results/plan99-completion/controller.py',label,'nix','develop','--no-write-lock-file','-c','just',recipe])
 if result.returncode: sys.exit(result.returncode)
