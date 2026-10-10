import json,os,pathlib,signal,subprocess,sys,time
folder=pathlib.Path('/tmp/mp12-ep6-release');journal=folder/'diagnostic-publication-journal.json'
phase=sys.argv[1]; cap=int(sys.argv[2]);cmd=sys.argv[3:];state=json.loads(journal.read_text());start=time.time();limit=min(state['deadline_epoch']-state['cleanup_reserve_seconds'],start+cap)
logfile=folder/(phase+'.log')
def save():journal.write_text(json.dumps(state,indent=2)+'\n')
state['phase']=phase;state.setdefault('stages',{})[phase]={'started_epoch':start,'cap_seconds':cap,'command':cmd};save()
with logfile.open('w') as log:
 p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);state['active_pid']=p.pid;save()
 try:
  while p.poll() is None:
   if time.time()>=limit:raise TimeoutError(phase+' deadline reached')
   state['log_bytes']=logfile.stat().st_size;state['updated_epoch']=time.time();save();time.sleep(2)
  rc=p.returncode;state['stages'][phase].update(returncode=rc,seconds=time.time()-start);state['phase']=phase+'-finished';state.pop('active_pid',None);save();print(json.dumps(state['stages'][phase]),flush=True);raise SystemExit(rc)
 except BaseException as error:
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  if not isinstance(error,SystemExit):state['phase']=phase+'-stopped';state['error']=str(error);save()
  raise
