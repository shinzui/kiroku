import json,os,pathlib,signal,subprocess,time
folder=pathlib.Path('/tmp/mp12-ep2-quick-linux');journal=folder/'journal.json'
operator='/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou/dist-newstyle/build/aarch64-osx/ghc-9.12.4/kenshou-cli-0.1.0.0/x/kenshou/build/kenshou/kenshou'
owner=pathlib.Path('/Users/shinzui/Keikaku/bokuno/load-testing-infra')
state=json.loads(journal.read_text());start=time.time();limit=min(state['deadline_epoch']-120,start+900)
cmd=[operator,'cell','pair','--cell','alpha','--start','--baseline','/tmp/kiroku-mp12-v5-released.payload.json','--candidate',str(folder/'head.payload.json'),'--plan',str(folder/'plan.json'),'--pairs','2','--ordering','abba','--max-replacements','0','--policy','/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/bench/mp12-cell/policy.json','--pg-setting','shared_buffers=128MB','--pg-setting','fsync=on','--pg-setting','synchronous_commit=on','--pg-setting','full_page_writes=on','--pg-setting','wal_level=replica','--out',str(folder/'pair')]
state['phase']='remote';state['remote_started_epoch']=start;state['remote_command']=cmd
last_snapshot=0;signature=None;last_progress=start;failure=None;code=None;p=None

def save():journal.write_text(json.dumps(state,indent=2)+'\n')
def bounded(command,timeout=15,env=None):return subprocess.run(command,capture_output=True,text=True,timeout=timeout,env=env)
def stop_process():
 if p is not None and p.poll() is None:
  os.killpg(p.pid,signal.SIGINT)
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
save()
try:
 with (folder/'remote.log').open('w') as log:
  p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);state['remote_pid']=p.pid;save()
  while p.poll() is None:
   now=time.time()
   if now>=limit:raise TimeoutError('remote queue exceeded its 900-second ceiling; no retries')
   paths=list((folder/'pair').glob('round-*/session.json'))
   if paths:
    j=json.loads(sorted(paths)[-1].read_text());slices=j['slices'];verified=sum(s.get('state')=='verified' for s in slices)
    pending=[s for s in slices if s.get('state') not in ['verified','rejected']];current=pending[0]['cellRun'] if pending else None
    state['verified_trials']=verified;state['owned_lease']=j['leaseId'];state['current_run']=current
    if current and now-last_snapshot>=30:
     response=bounded(['gcloud','storage','cat',f'gs://tan-nb-exp-cells-control/cells/alpha/submissions/{current}/status.json','--project=tan-nb-exp'])
     if response.returncode==0:
      status=json.loads(response.stdout);state['remote_status']=status;state['remote_phase']=status.get('phase')
     else:state['status_lookup_error']=response.stderr[-500:]
   if now-last_snapshot>=30:
    power=bounded(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~cell-alpha','--format=json(name,status)'])
    if power.returncode==0:state['instance_power']=json.loads(power.stdout)
    last_snapshot=now
   changed=(state.get('current_run'),state.get('remote_phase'),state.get('verified_trials'))
   if changed!=signature:signature=changed;last_progress=now
   if now-last_progress>240:raise TimeoutError('no remote phase or verified-trial progress for 240 seconds')
   state['updated_epoch']=time.time();save();time.sleep(2)
  code=p.returncode;state['remote_returncode']=code;state['remote_seconds']=time.time()-start;save()
except BaseException as error:
 failure=str(error);state['remote_error']=failure;save();stop_process()
finally:
 state['phase']='cleanup';save();cleanup=[]
 for path in (folder/'pair').glob('round-*/session.json'):
  try:
   j=json.loads(path.read_text())
   if j['cell']=='alpha':
    result=bounded([operator,'cell','release','--cell','alpha','--lease-id',j['leaseId']],30);cleanup.append({'action':'release-owned-lease','returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
  except Exception as error:cleanup.append({'action':'release-owned-lease','error':str(error)})
 env=os.environ.copy();env['CLOUDSDK_CORE_PROJECT']='tan-nb-exp';env['LTI_GCP_PROJECT']='tan-nb-exp'
 try:
  result=bounded(['bash',str(owner/'scripts/cell/stop.sh'),'alpha'],120,env);cleanup.append({'action':'stop-cell','returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
  power=bounded(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~cell-alpha','--format=json(name,status)'],15)
  if power.returncode==0:state['final_instance_power']=json.loads(power.stdout)
 except Exception as error:cleanup.append({'action':'stop-cell','error':str(error)})
 state['cleanup']=cleanup;state['phase']='completed' if not failure and code in [0,1,3] else 'stopped';state['finished_epoch']=time.time();state['total_remote_and_cleanup_seconds']=time.time()-start;save()
 print(json.dumps({'phase':state['phase'],'returncode':code,'verified_trials':state.get('verified_trials'),'remote_seconds':state.get('remote_seconds'),'cleanup':cleanup,'final_instance_power':state.get('final_instance_power')}),flush=True)
raise SystemExit(0 if not failure and code in [0,1,3] else 1)
