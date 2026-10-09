import hashlib, json, pathlib, statistics, subprocess, time
root=pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku')
control_root=pathlib.Path('/tmp/kiroku-mp12-control-e6ea664')
out=root/'kiroku-store/bench/results/ep2-target-binding/local-mixed.json'
if out.exists(): raise SystemExit('refusing to overwrite evidence')
out.parent.mkdir(parents=True,exist_ok=True)
roots={'control':control_root,'candidate':root}
binaries={arm:pathlib.Path(subprocess.check_output(['cabal','list-bin','shibuya-kiroku-adapter:kiroku-mp12-write-probe'],cwd=repo,text=True).strip()) for arm,repo in roots.items()}
subprocess.run(['git','diff','--exit-code','--','kiroku-store/src','kiroku-store-migrations/migrations','shibuya-kiroku-adapter/src'],cwd=control_root,check=True,stdout=subprocess.DEVNULL)
workload=['15','group','1','1','1','False','100']
evidence={'classification':'exploratory local diagnostic; no statistical acceptance claim','complete_matrix':False,'workload':workload,'pairs':3,'source':{arm:subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip() for arm,repo in roots.items()},'binary_sha256':{arm:hashlib.sha256(path.read_bytes()).hexdigest() for arm,path in binaries.items()},'trials':[],'status':'running'}
deadline=time.monotonic()+300

def save():
 tmp=out.with_suffix('.tmp');tmp.write_text(json.dumps(evidence,indent=2)+'\n');tmp.replace(out)
save()
try:
 for pair in range(3):
  for arm in (['control','candidate'] if pair%2==0 else ['candidate','control']):
   print(f'pair {pair+1}/3: {arm}',flush=True)
   result=subprocess.run([str(binaries[arm]),*workload],capture_output=True,text=True,timeout=min(60,deadline-time.monotonic()))
   trial={'pair':pair+1,'arm':arm,'returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr}
   evidence['trials'].append(trial);save()
   if result.returncode: raise RuntimeError('trial failed; raw output retained')
   rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
   if len(rows)!=1:raise RuntimeError('expected one result')
   row=rows[0];trial['result']=row;save()
   if row['durability']!='on,on,on' or not row['durable_drained'] or row['delivered']!=row['events'] or row['checkpoint_updates']!=row['events']:raise RuntimeError('durability/delivery/checkpoint work mismatch')
 for field in ['append_p50_ms','append_p95_ms','append_p99_ms','wal_bytes','allocated_bytes']:
  ratios=[]
  for pair in range(1,4):
   arms={t['arm']:t['result'] for t in evidence['trials'] if t['pair']==pair}
   ratios.append(arms['candidate'][field]/arms['control'][field])
  evidence.setdefault('point_comparisons',{})[field]={'pair_ratios':ratios,'geometric_mean_ratio':statistics.geometric_mean(ratios)}
 evidence['status']='complete diagnostic; statistical acceptance remains inconclusive';save()
 print(json.dumps(evidence['point_comparisons'],indent=2),flush=True)
except BaseException as error:
 evidence['status']='failed';evidence['error']=str(error);save();raise
