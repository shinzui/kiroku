"""Wait at most ten minutes for the public index, then build the exact consumer."""
import json,pathlib,subprocess,time
out=pathlib.Path(__file__).resolve().parent
stage=pathlib.Path(json.loads((out/'consumer-stage.json').read_text())['path'])
deadline=time.monotonic()+600
with (out/'index-propagation.log').open('w') as log:
 while True:
  subprocess.run(['cabal','update'],cwd=stage,stdout=log,stderr=log,check=True,timeout=90)
  versions=subprocess.check_output(['cabal','list','--simple-output','shibuya-kiroku-adapter'],cwd=stage,text=True,timeout=30)
  if 'shibuya-kiroku-adapter 0.6.0.1' in versions:break
  log.write('Waiting for published adapter version in signed index.\n');log.flush()
  if time.monotonic()+30>deadline:raise TimeoutError('Hackage index propagation')
  time.sleep(30)
with (out/'published-consumer-build-propagated.log').open('w') as log:
 subprocess.run(['cabal','build','all','-j2'],cwd=stage,stdout=log,stderr=log,check=True,timeout=900)
print('Published consumer build passed.',flush=True)
