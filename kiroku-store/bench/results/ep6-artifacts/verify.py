import datetime,json,os,pathlib,signal,subprocess,time
root=pathlib.Path(__file__).resolve().parents[4]
folder=pathlib.Path(__file__).resolve().parent
started=time.time()
commands=[('format',['nix','fmt'],120),('build',['cabal','build','all'],1200),('pg18-tests',['cabal','test','all','--test-show-details=direct'],1200)]
journal={'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':'starting','stages':[]}
def save():
 (folder/'journal.json').write_text(json.dumps(journal,indent=2)+'\n')
for name,command,limit in commands:
 stage={'name':name,'command':command,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 journal['phase']=name;journal['stages'].append(stage);save()
 print('START '+name,flush=True)
 with (folder/(name+'.log')).open('w') as log:
  p=subprocess.Popen(command,cwd=root,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  try:code=p.wait(timeout=limit)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   code=124
 stage['exit_code']=code;stage['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
 print('END '+name+' exit='+str(code),flush=True)
 if code:
  journal['phase']='failed';save();raise SystemExit(code)
journal['phase']='complete';journal['elapsed_seconds']=time.time()-started;save()
