import hashlib,json,math,pathlib,statistics,subprocess,time
repo=pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku')
old=repo/'kiroku-store/bench/results/ep6-diagnosis';new=repo/'kiroku-store/bench/results/ep6-tail-repeat'
operator='/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou/dist-newstyle/build/aarch64-osx/ghc-9.12.4/kenshou-cli-0.1.0.0/x/kenshou/build/kenshou/kenshou'
sets={'diagnosis':json.loads((old/'summary.json').read_text()),'tail-repeat':json.loads((new/'summary.json').read_text())}
roots={'diagnosis':old,'tail-repeat':new};pairs={};rows=[];seen=set();input_verification=[]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
for experiment,summary in sets.items():
 root=roots[experiment]
 for name,digest in summary['evidence_sha256'].items():assert sha(root/name)==digest,(experiment,name)
 for row in summary['rows']:
  if not row['valid'] or row['case'] not in ['real-adapter','live-hook-fanout']:continue
  assert row['cell_run'] not in seen;seen.add(row['cell_run'])
  base=root/'runs'/row['cell_run'];assert sha(base/'cell-manifest.json')==row['manifest_sha256']
  manifest=json.loads((base/'cell-manifest.json').read_text())
  for artifact in manifest['artifacts']:
   item=base/'tree'/artifact['path'];assert item.stat().st_size==artifact['bytes'] and sha(item)==artifact['sha256']
  run=base/'tree/output'/row['run_id'];assert sha(run/'run-result.json')==row['result_sha256']
  result=json.loads((run/'run-result.json').read_text());spec=json.loads((run/'run-spec.json').read_text());reset=json.loads((base/'tree/cell/reset-evidence.json').read_text())
  assert result['outcome']=='passed' and reset['verified']
  row=dict(row,experiment=experiment,run_directory=str(run),seed=spec['seed'])
  rows.append(row);membership=row['comparison'];pairs.setdefault((row['case'],experiment,membership['trial']),{})[membership['arm']]=row
full={case:[]for case in ['real-adapter','live-hook-fanout']}
for key,members in pairs.items():
 if set(members)=={'baseline','candidate'}:
  assert members['baseline']['seed']==members['candidate']['seed']
  full[key[0]].append(members)
full={k:sorted(v,key=lambda p:p['baseline']['timings']['startedAt'])for k,v in full.items()}
keys=['op.append.throughput','op.append.latency.p50','op.append.latency.p95','op.append.latency.p99','pg.wal-bytes-per-op','rts.alloc-bytes-per-op']
tcritical={2:12.706204736,3:4.302652730,4:3.182446305,5:2.776445105,6:2.570581836,7:2.446911851,8:2.364624252}
effects={};comparisons={};pair_records={}
for case,group in full.items():
 effects[case]={};pair_records[case]=[{arm:{k:p[arm][k]for k in ['experiment','cell_run','run_id','seed','run_directory','result_sha256','manifest_sha256']}for arm in ['baseline','candidate']}for p in group]
 for metric in keys:
  ratios=[p['candidate']['metrics'][metric]/p['baseline']['metrics'][metric]for p in group];logs=list(map(math.log,ratios));center=statistics.mean(logs)if logs else None;n=len(logs);half=tcritical[n]*statistics.stdev(logs)/math.sqrt(n)if n in tcritical else None
  effects[case][metric]={'pairs':n,'paired_percent_changes':[100*(r-1)for r in ratios],'geometric_mean_percent_change':100*(math.exp(center)-1)if logs else None,'descriptive_95_percent_interval':{'low':100*(math.exp(center-half)-1),'high':100*(math.exp(center+half)-1)}if half is not None else None}
 if group:
  report=new/(case+'-combined-comparison.json');command=[operator,'compare']
  for p in group:command+=['--baseline',p['baseline']['run_directory'],'--candidate',p['candidate']['run_directory']]
  command+=['--policy',str(repo/'bench/mp12-cell/policy.json'),'--vary','cohort','--out',str(report),'--json']
  response=subprocess.run(command,capture_output=True,text=True,timeout=60)
  (new/(case+'-combined-command.json')).write_text(json.dumps({'command':command,'returncode':response.returncode,'stderr':response.stderr},indent=2)+'\n')
  (new/(case+'-combined.log')).write_text(response.stdout+response.stderr)
  comparisons[case]=json.loads(report.read_text())if report.exists()else {'verdict':'comparison-refused','returncode':response.returncode,'stderr':response.stderr}
combined={'schema':'kiroku.ep6-combined-evidence/v1','input_summaries':{name:{'path':str(roots[name].relative_to(repo)/'summary.json'),'sha256':sha(roots[name]/'summary.json')}for name in sets},'verified_valid_trials':len(rows),'complete_pairs':{k:len(v)for k,v in full.items()},'pairs':pair_records,'effects':effects,'operator_verdicts':{k:{key:v.get(key)for key in ['verdict','pairCount','reasons','exitCode']}for k,v in comparisons.items()},'interval_method':'descriptive 95% Student t on paired log ratios, df=n-1; original Kenshou policy and operator comparisons retained separately','replacements':0,'verified_at_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
(new/'combined-summary.json').write_text(json.dumps(combined,indent=2)+'\n');print(json.dumps({k:combined[k]for k in ['complete_pairs','effects','operator_verdicts']},indent=2))
