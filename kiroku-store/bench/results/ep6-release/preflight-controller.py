import hashlib,json,os,pathlib,signal,subprocess,time
folder=pathlib.Path('/tmp/mp12-ep6-release');journal=folder/'journal.json'
operator='/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou/dist-newstyle/build/aarch64-osx/ghc-9.12.4/kenshou-cli-0.1.0.0/x/kenshou/build/kenshou/kenshou'
owner=pathlib.Path('/Users/shinzui/Keikaku/bokuno/load-testing-infra')
repo=pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku')
state=json.loads(journal.read_text());limit=state['deadline_epoch']-state['cleanup_reserve_seconds'];p=None;failure=None
settings=['shared_buffers=128MB','fsync=on','synchronous_commit=on','full_page_writes=on','wal_level=replica','checkpoint_timeout=30min','max_wal_size=16GB']
pgargs=[arg for setting in settings for arg in ['--pg-setting',setting]]
state['remote_started_epoch']=time.time();state['jobs']=[];state['phase']='remote'
def save():journal.write_text(json.dumps(state,indent=2)+'\n')
def bounded(command,timeout=20,env=None):return subprocess.run(command,capture_output=True,text=True,timeout=timeout,env=env)
def verify(session_path):
 s=json.loads(session_path.read_text());count=0
 for entry in s['slices']:
  if entry['state']!='verified':raise RuntimeError('incomplete or rejected slice '+entry['cellRun'])
  tree=pathlib.Path(entry['fetchedPath']);manifest=tree/'manifest.json'
  if hashlib.sha256(manifest.read_bytes()).hexdigest()!=entry['manifestSha256']:raise RuntimeError('manifest hash mismatch')
  for artifact in json.loads(manifest.read_text())['artifacts']:
   item=tree/artifact['path']
   if item.stat().st_size!=artifact['bytes'] or hashlib.sha256(item.read_bytes()).hexdigest()!=artifact['sha256']:raise RuntimeError('artifact mismatch '+artifact['path'])
  for run in entry['runIds']:
   result=json.loads((tree/'output'/run/'run-result.json').read_text());m=result['summaries']['measurements'];w=m['write-probe']
   if result['outcome']!='passed' or m['measurements']['grade']!='benchmark' or not w['durable_drained']:raise RuntimeError('failed durable benchmark '+run)
   expected=w.get('expected_delivered',w['events'])
   if w['delivered']!=expected or w['checkpoint_updates']!=expected or w['durability']!='on,on,on':raise RuntimeError('incorrect delivered/checkpoint work '+run)
  reset=json.loads((tree/'cell/reset-evidence.json').read_text())
  if not reset['verified']:raise RuntimeError('reset not verified')
  count+=1
 return count
try:
 for name in ['real-adapter','diagnostic','live-hook-fanout']:
  if time.time()>=limit:raise TimeoutError('whole experiment deadline leaves only cleanup reserve; no next job')
  out=folder/('remote-'+name)
  if name=='diagnostic':
   source=json.loads((folder/'remote-real-adapter/pair-plan.json').read_text());last=source['runs'][-1]
   if last['trial']['arm']!='candidate':raise RuntimeError('diagnostic must follow final disabled head trial')
   source['runs']=[last];source['runs'][0]['spec']['comparison']['arm']='diagnostic';source['runs'][0]['trial']['arm']='diagnostic';source['runs'][0]['spec']['labels']={'ep6.diagnostics':'enabled'}
   plan=folder/'diagnostic.plan.json';plan.write_text(json.dumps(source,indent=2)+'\n')
   cmd=[operator,'cell','run','--cell','alpha','--start','--payload','diagnostic='+str(folder/'diagnostic.payload.json'),'--plan',str(plan),'--out',str(out)]+pgargs
  else:
   cmd=[operator,'cell','pair','--cell','alpha','--start','--baseline',str(folder/'control.payload.json'),'--candidate',str(folder/'head.payload.json'),'--plan',str(folder/(name+'.plan.json')),'--pairs','3','--ordering','abba','--max-replacements','0','--policy',str(repo/'bench/mp12-cell/policy.json'),'--out',str(out)]+pgargs
  record={'name':name,'command':cmd,'started_epoch':time.time()};state['jobs'].append(record);state['phase']=name;save()
  last_snapshot=0;signature=None;last_progress=time.time()
  with (folder/(name+'.remote.log')).open('w') as log:
   p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);state['remote_pid']=p.pid;save()
   while p.poll() is None:
    now=time.time()
    if now>=limit:raise TimeoutError('whole experiment remote deadline reached; no replacement')
    paths=list(out.glob('round-*/session.json')) if name!='diagnostic' else [out/'session.json']
    paths=[path for path in paths if path.exists()]
    if paths:
     session=json.loads(sorted(paths)[-1].read_text());slices=session['slices'];verified=sum(x.get('state')=='verified' for x in slices);pending=[x for x in slices if x.get('state') not in ['verified','rejected']];current=pending[0]['cellRun'] if pending else None
     record['verified_trials']=verified;state['owned_lease']=session['leaseId'];state['current_run']=current
     if current and now-last_snapshot>=30:
      response=bounded(['gcloud','storage','cat',f'gs://tan-nb-exp-cells-control/cells/alpha/submissions/{current}/status.json','--project=tan-nb-exp'])
      if response.returncode==0:state['remote_status']=json.loads(response.stdout);state['remote_phase']=state['remote_status'].get('phase')
      else:state['status_lookup_error']=response.stderr[-500:]
    if now-last_snapshot>=30:
     response=bounded(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~cell-alpha','--format=json(name,status)'])
     if response.returncode==0:state['instance_power']=json.loads(response.stdout)
     last_snapshot=now
    changed=(state.get('current_run'),state.get('remote_phase'),record.get('verified_trials'))
    if changed!=signature:signature=changed;last_progress=now
    if now-last_progress>240:raise TimeoutError('no current phase or verified-trial progress for 240 seconds')
    state['updated_epoch']=time.time();save();time.sleep(2)
   record['returncode']=p.returncode;record['seconds']=time.time()-record['started_epoch'];save()
  session_path=out/'session.json' if name=='diagnostic' else out/'round-0/session.json'
  record['independently_verified_trials']=verify(session_path)
  if name!='diagnostic':
   comparison=out/'comparison.json'
   if not comparison.exists():raise RuntimeError('pair command did not produce comparison report')
   record['comparison']=json.loads(comparison.read_text())
  elif p.returncode!=0:raise RuntimeError('diagnostic command failed')
  save()
except BaseException as error:
 failure=str(error);state['remote_error']=failure;save()
 if p is not None and p.poll() is None:
  os.killpg(p.pid,signal.SIGINT)
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
finally:
 state['phase']='cleanup';save();cleanup=[];leases=set()
 for path in folder.glob('remote-*/**/session.json'):
  try:
   session=json.loads(path.read_text())
   if session['cell']=='alpha':leases.add(session['leaseId'])
  except Exception as error:cleanup.append({'action':'read-session','error':str(error)})
 for lease in leases:
  try:
   result=bounded([operator,'cell','release','--cell','alpha','--lease-id',lease],30);cleanup.append({'action':'release-owned-lease','lease':lease,'returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
  except Exception as error:cleanup.append({'action':'release-owned-lease','error':str(error)})
 env=os.environ.copy();env['CLOUDSDK_CORE_PROJECT']='tan-nb-exp';env['LTI_GCP_PROJECT']='tan-nb-exp'
 try:
  result=bounded(['bash',str(owner/'scripts/cell/stop.sh'),'alpha'],110,env);cleanup.append({'action':'stop-cell','returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
  result=bounded(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~cell-alpha','--format=json(name,status)'],15)
  if result.returncode==0:state['final_instance_power']=json.loads(result.stdout)
 except Exception as error:cleanup.append({'action':'stop-cell','error':str(error)})
 state['cleanup']=cleanup;state['phase']='stopped' if failure else 'completed';state['finished_epoch']=time.time();save();print(json.dumps({'phase':state['phase'],'error':failure,'finished_epoch':state['finished_epoch'],'jobs':[{k:j.get(k) for k in ['name','returncode','verified_trials','independently_verified_trials','seconds']} for j in state['jobs']],'cleanup':cleanup,'final_instance_power':state.get('final_instance_power')}),flush=True)
raise SystemExit(1 if failure else 0)
