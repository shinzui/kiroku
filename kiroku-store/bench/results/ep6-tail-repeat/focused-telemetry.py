import json,pathlib,subprocess,time,signal,os
root=pathlib.Path('/tmp/mp12-ep6-tail-repeat');binary='/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/dist-newstyle/build/aarch64-osx/ghc-9.12.4/kiroku-store-0.9.0.1/b/kiroku-store-bench/build/kiroku-store-bench/kiroku-store-bench'
command=[binary,'--baseline','kiroku-store/bench/results/baseline.csv','--pattern','/AnyVersion (new stream)/'];record={'command':command,'started_epoch':time.time(),'wrapper_timeout_seconds':150,'test_timeout_seconds':100,'purpose':'Single unchanged-method diagnostic of the newly timed-out full-suite case; not a replacement or performance-acceptance trial'}
with (root/'focused-anyversion.log').open('w')as log:
 p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 try:record['returncode']=p.wait(timeout=150)
 except subprocess.TimeoutExpired:
  record['error']='wrapper deadline';os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  record['returncode']=124
record['finished_epoch']=time.time();record['seconds']=record['finished_epoch']-record['started_epoch'];(root/'focused-anyversion-command.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
