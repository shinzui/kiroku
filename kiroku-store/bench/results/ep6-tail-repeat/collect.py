import hashlib,json,math,pathlib,shutil,statistics
root=pathlib.Path('/tmp/mp12-ep6-tail-repeat');dest=pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/bench/results/ep6-tail-repeat')
j=json.loads((root/'journal.json').read_text());assert j['phase'] in ['completed','stopped'],'controller still active';dest.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def retain(p,name):
 target=dest/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
rows=[];planned=[];errors=[]
for name in ['real-adapter','live-hook-fanout']:
 out=root/('remote-'+name);paths=list(out.glob('round-*/session.json')) if name not in ['calibration','diagnostic'] else [out/'session.json']
 for path in paths:
  if not path.exists():continue
  session=json.loads(path.read_text());retain(path,pathlib.Path(name)/path.relative_to(out))
  for s in session['slices']:
   planned.append({'case':name,'run_ids':s['runIds'],'cell_run':s['cellRun'],'state':s['state'],'cell_outcome':s.get('cellOutcome'),'entry_exit_code':s.get('entryExitCode')})
   if not s.get('fetchedPath'):continue
   tree=pathlib.Path(s['fetchedPath']);manifest=json.loads((tree/'manifest.json').read_text());assert sha(tree/'manifest.json')==s['manifestSha256']
   for a in manifest['artifacts']:
    item=tree/a['path'];assert item.stat().st_size==a['bytes'];assert sha(item)==a['sha256'],a['path']
   for artifact in manifest['artifacts']:
    retain(tree/artifact['path'],pathlib.Path('runs')/s['cellRun']/'tree'/artifact['path'])
   for run in s['runIds']:
    rp=tree/'output'/run;d=json.loads((rp/'run-result.json').read_text());m=d.get('summaries',{}).get('measurements',{});w=m.get('write-probe');metrics=m.get('measurements',{}).get('metrics',{})
    if not w:
     errors.append({'case':name,'cell_run':s['cellRun'],'outcome':d['outcome'],'reason':d.get('reason','no completed write-probe summary')})
    else:
     before={r['queryid']:r for r in w['checkpoint_sql_before']};calls=ms=wal=0
     for r in w['checkpoint_sql_after']:
      b=before.get(r['queryid'],{});calls+=r['calls']-b.get('calls',0);ms+=r['exec_ms']-b.get('exec_ms',0);wal+=r['wal_bytes']-b.get('wal_bytes',0)
     expected=w.get('expected_delivered',w['events']);valid=w['delivered']==expected and w['checkpoint_updates']==calls==w['delivery_batches'] and w['durable_drained'] and w['durability']=='on,on,on' and d['outcome']=='passed' and m['measurements']['grade']=='benchmark'
     reset=json.loads((tree/'cell/reset-evidence.json').read_text());valid=valid and reset['verified'] and s.get('cellOutcome')=='completed' and s.get('entryExitCode')==0
     row={'case':name,'valid':valid,'cell_run':s['cellRun'],'run_id':run,'comparison':d.get('comparison'),'grade':m['measurements']['grade'],'cohort':d['cohort'],'manifest_sha256':s['manifestSha256'],'result_sha256':sha(rp/'run-result.json'),'results_uri':json.loads((tree.parent/'cell-run.json').read_text())['resultsBaseUri'],'metrics':{k:v['value'] for k,v in metrics.items()},'events':w['events'],'expected_delivered':expected,'delivered':w['delivered'],'checkpoint_calls':calls,'delivery_batches':w['delivery_batches'],'checkpoint_updates':w['checkpoint_updates'],'checkpoint_statement_us':ms*1000/calls if calls else None,'checkpoint_statement_wal_bytes_per_call':wal/calls if calls else None,'checkpoint_hot_updates':w['checkpoint_hot_updates'],'durable_drained':w['durable_drained'],'workload':w['workload'],'timings':d['timings'],'server':w['server'],'peak_durable_pending':m['backlog']['peakDurablePending'],'peak_handler_pending':m['backlog']['peakHandlerPending']};rows.append(row)
    for p,label in [(tree/'manifest.json','cell-manifest.json'),(tree.parent/'cell-run.json','cell-run.json'),(tree/'cell/reset-evidence.json','reset-evidence.json'),(tree/'cell/health.json','health.json'),(rp/'run-result.json','run-result.json'),(rp/'run-spec.json','run-spec.json'),(rp/'manifest.json','run-manifest.json')]:
     if p.exists():retain(p,pathlib.Path('runs')/s['cellRun']/label)
  for p in [out/'pair-plan.json',out/'comparison.json',out/'policy.json',path.parent/'comparison.json',path.parent/'policy.json']:
   if p.exists():retain(p,pathlib.Path(name)/p.relative_to(out))
effects={};complete={};keys=['op.append.throughput','op.append.latency.p50','op.append.latency.p95','op.append.latency.p99','pg.wal-bytes-per-op','rts.alloc-bytes-per-op']
for name in ['real-adapter','live-hook-fanout']:
 pairs={}
 for row in rows:
  if row['case']==name and row['valid']:pairs.setdefault(row['comparison']['trial'],{})[row['comparison']['arm']]=row
 full=[p for p in pairs.values() if 'baseline' in p and 'candidate' in p];complete[name]=len(full);effects[name]={}
 for key in keys:
  ratios=[p['candidate']['metrics'][key]/p['baseline']['metrics'][key] for p in full];logs=list(map(math.log,ratios));center=statistics.mean(logs) if logs else None;tcritical={2:12.706204736,3:4.302652730}.get(len(logs));half=tcritical*statistics.stdev(logs)/math.sqrt(len(logs)) if tcritical else None
  effects[name][key]={'paired_percent_changes':[100*(r-1) for r in ratios],'geometric_mean_percent_change':100*(math.exp(center)-1) if ratios else None,'descriptive_95_percent_interval':{'low':100*(math.exp(center-half)-1),'high':100*(math.exp(center+half)-1)} if half is not None else None}
diag=[r for r in rows if r['case']=='diagnostic' and r['valid']];heads=[r for r in rows if r['case']=='real-adapter' and r['valid'] and r['comparison']['arm']=='candidate'];diagnostic=None
if diag and heads:
 enabled=diag[-1];disabled=heads[-1];diagnostic={'enabled_cell_run':enabled['cell_run'],'disabled_cell_run':disabled['cell_run'],'single_chronological_percent_changes':{k:100*(enabled['metrics'][k]/disabled['metrics'][k]-1) for k in keys},'acceptance':'descriptive only; one trial has no uncertainty estimate'}
for p in root.iterdir():
 if p.is_file() and p.suffix in ['.json','.jsonl','.log','.py','.hs']:retain(p,p.name)
for p in (root/'preflight-label-refusal').rglob('*'):
 if p.is_file():retain(p,pathlib.Path('preflight-label-refusal')/p.relative_to(root/'preflight-label-refusal'))
for p in []:
 if p.is_file():retain(p,pathlib.Path('diagnostic-publisher')/p.name)
retain(pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/bench/mp12-cell/policy.json'),'policy.json')
interrupted=[]
for index in (root/'interrupted-candidate-fetch').glob('*/cell-run.json'):
 tree=index.parent/'tree';manifest=json.loads((tree/'manifest.json').read_text());retain(index,pathlib.Path('runs')/index.parent.name/'cell-run.json');retain(tree/'manifest.json',pathlib.Path('runs')/index.parent.name/'cell-manifest.json')
 for artifact in manifest['artifacts']:
  item=tree/artifact['path'];assert item.stat().st_size==artifact['bytes'];assert sha(item)==artifact['sha256'];retain(item,pathlib.Path('runs')/index.parent.name/'tree'/artifact['path'])
 interrupted.append({'cell_run':index.parent.name,'status':json.loads((root/'interrupted-candidate-status.json').read_text()),'manifest_sha256':sha(tree/'manifest.json'),'artifacts_verified':len(manifest['artifacts'])})
summary={'schema':'kiroku.ep6-tail-repeat/v1','operator':'mori://shinzui/keiro-runtime-kenshou','infrastructure':'mori://shinzui/load-testing-infra','whole_experiment_started_epoch':j['started_epoch'],'whole_experiment_deadline_epoch':j['deadline_epoch'],'controller_finished_epoch':j['finished_epoch'],'whole_experiment_seconds':j['finished_epoch']-j['started_epoch'],'final_cell_status':j.get('final_cell_status'),'within_one_hour':j['finished_epoch']<=j['deadline_epoch'],'verified_trials':sum(r['valid'] for r in rows),'replacements':0,'rows':rows,'errors':errors,'effects':effects,'complete_pairs':complete,'diagnostic_cost':diagnostic,'performance_acceptance':'inconclusive','planned_trials':planned,'stop_reason':j.get('remote_error','completed declared queue'),'controller_error':j.get('remote_error'),'interrupted_trials':interrupted,'declared_trials':12,'verified_sealed_results':len(errors)+len(rows)+len(interrupted),'interval_method':'descriptive Student t interval on paired log ratios; df=pairs-1; not the unchanged Kenshou policy acceptance report','final_instance_power':j.get('final_instance_power'),'evidence_sha256':{str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name not in ['summary.json','README.md']}}
(dest/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({k:summary[k] for k in ['verified_trials','complete_pairs','whole_experiment_seconds','within_one_hour','effects','diagnostic_cost','stop_reason']},indent=2))
