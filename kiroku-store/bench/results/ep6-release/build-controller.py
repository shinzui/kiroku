import json,os,pathlib,signal,subprocess,time
root=pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku')
folder=pathlib.Path('/tmp/mp12-ep6-release');journal=folder/'journal.json';state=json.loads(journal.read_text())
start=time.time();limit=min(state['deadline_epoch']-120,start+state['build_limit_seconds'])
with (folder/'build.log').open('w') as log:
 p=subprocess.Popen(['nix','build','./bench/mp12-cell#packages.x86_64-linux.kenshou-released','./bench/mp12-cell#packages.x86_64-linux.kenshou-head','./bench/mp12-cell#packages.x86_64-linux.kenshou-head-stall','--no-link','--json'],cwd=root,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 state['build_pid']=p.pid;state['build_started_epoch']=start;journal.write_text(json.dumps(state,indent=2)+'\n')
 try:
  while p.poll() is None:
   if time.time()>=limit:raise TimeoutError('bounded build deadline reached; no remote trials started')
   state['build_log_bytes']=(folder/'build.log').stat().st_size;state['updated_epoch']=time.time();journal.write_text(json.dumps(state,indent=2)+'\n');time.sleep(2)
  state['build_returncode']=p.returncode;state['phase']='built' if p.returncode==0 else 'build-failed';state['build_seconds']=time.time()-start;journal.write_text(json.dumps(state,indent=2)+'\n')
  print(json.dumps({k:state[k] for k in ['phase','build_returncode','build_seconds']}),flush=True)
  raise SystemExit(p.returncode)
 except BaseException as error:
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  if not isinstance(error,SystemExit):
   state['phase']='build-stopped';state['error']=str(error);journal.write_text(json.dumps(state,indent=2)+'\n')
  raise
