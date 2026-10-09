import hashlib,json,math,pathlib,shutil,time,statistics
root=pathlib.Path('/tmp/mp12-ep2-quick-linux')
dest=pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/bench/results/ep2-quick-linux')
j=json.loads((root/'journal.json').read_text())
assert j['phase'] in ('completed','stopped'), 'controller still active'
dest.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def retain(p,name):
 target=dest/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
session=json.loads((root/'pair/round-0/session.json').read_text())
rows=[]
for s in session['slices']:
 if not s.get('fetchedPath'):continue
 tree=pathlib.Path(s['fetchedPath']);manifest=json.loads((tree/'manifest.json').read_text())
 assert sha(tree/'manifest.json')==s['manifestSha256']
 for a in manifest['artifacts']:
  p=tree/a['path'];assert p.stat().st_size==a['bytes'];assert sha(p)==a['sha256'],a['path']
 run=s['runIds'][0];rp=tree/'output'/run;d=json.loads((rp/'run-result.json').read_text())
 m=d['summaries']['measurements'];w=m['write-probe'];metrics=m['measurements']['metrics']
 before={r['queryid']:r for r in w['checkpoint_sql_before']};calls=ms=wal=0
 for r in w['checkpoint_sql_after']:
  b=before.get(r['queryid'],{});calls+=r['calls']-b.get('calls',0);ms+=r['exec_ms']-b.get('exec_ms',0);wal+=r['wal_bytes']-b.get('wal_bytes',0)
 assert w['events']==w['delivered']==w['checkpoint_updates']==calls
 assert w['durable_drained'] and w['durability']=='on,on,on'
 assert d['outcome']=='passed' and m['measurements']['grade']=='benchmark'
 reset=json.loads((tree/'cell/reset-evidence.json').read_text());assert reset['verified']
 row={'cell_run':s['cellRun'],'run_id':run,'comparison':d['comparison'],'grade':m['measurements']['grade'],
      'cohort':d['cohort'],'manifest_sha256':s['manifestSha256'],'result_sha256':sha(rp/'run-result.json'),
      'results_uri':json.loads((tree.parent/'cell-run.json').read_text())['resultsBaseUri'],
      'metrics':{k:v['value'] for k,v in metrics.items()},'events':w['events'],'checkpoint_calls':calls,
      'checkpoint_statement_us':ms*1000/calls,'checkpoint_statement_wal_bytes_per_call':wal/calls,
      'checkpoint_hot_updates':w['checkpoint_hot_updates'],'durable_drained':w['durable_drained'],
      'workload':w['workload'],'timings':d['timings'],'server':w['server'],
      'peak_durable_pending':m['backlog']['peakDurablePending'],'peak_handler_pending':m['backlog']['peakHandlerPending']}
 rows.append(row)
 for p,name in [(tree/'manifest.json','cell-manifest.json'),(tree.parent/'cell-run.json','cell-run.json'),
                (tree/'cell/reset-evidence.json','reset-evidence.json'),(tree/'cell/health.json','health.json'),
                (rp/'run-result.json','run-result.json'),(rp/'run-spec.json','run-spec.json'),(rp/'manifest.json','run-manifest.json')]:
  retain(p,pathlib.Path('runs')/s['cellRun']/name)
files=['journal.json','scope.json','plan.json','head.payload.json','preflight-refusal-journal.json',
       'remote-preflight-refusal.log','remote-valid.log','build.log','stop-reason.json','remote-driver-initial.py']
for name in files:
 if (root/name).exists():retain(root/name,name)
retain(pathlib.Path('/tmp/kiroku-mp12-v5-released.payload.json'),'control.payload.json')
for name in ['mp12-ep2-quick-build.py','mp12-ep2-quick-stage.py','mp12-ep2-quick-remote.py','mp12-ep2-quick-collect.py']:
 retain(pathlib.Path('/tmp')/name,pathlib.Path('controller')/name)
retain(root/'pair/round-0/session.json','session.json')
retain(root/'pair/pair-plan.json','pair-plan.json')
retain(pathlib.Path('/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/bench/mp12-cell/policy.json'),'policy.json')
for name in ['comparison.json','policy.json']:
 if (root/'pair'/name).exists():retain(root/'pair'/name,name)
 if (root/'pair/round-0'/name).exists():retain(root/'pair/round-0'/name,'round-0-'+name)
pairs={}
for row in rows:pairs.setdefault(row['comparison']['trial'],{})[row['comparison']['arm']]=row
effects={}
for key in ['op.append.throughput','op.append.latency.p50','op.append.latency.p95','op.append.latency.p99','pg.wal-bytes-per-op','rts.alloc-bytes-per-op']:
 ratios=[p['candidate']['metrics'][key]/p['baseline']['metrics'][key] for p in pairs.values() if len(p)==2]
 logs=list(map(math.log,ratios));center=statistics.mean(logs) if logs else None
 tcritical={2:12.706204736,3:4.302652730}.get(len(logs))
 half=tcritical*statistics.stdev(logs)/math.sqrt(len(logs)) if tcritical else None
 effects[key]={'paired_percent_changes':[100*(r-1) for r in ratios],
               'geometric_mean_percent_change':100*(math.exp(center)-1) if ratios else None,
               'descriptive_95_percent_interval':{'low':100*(math.exp(center-half)-1),'high':100*(math.exp(center+half)-1)} if half is not None else None}
summary={'schema':'kiroku.ep2-quick-linux/v1','operator':'mori://shinzui/keiro-runtime-kenshou',
         'infrastructure':'mori://shinzui/load-testing-infra','whole_experiment_started_epoch':j['deadline_epoch']-3600,
         'controller_finished_epoch':j['finished_epoch'],'whole_experiment_seconds':j['finished_epoch']-(j['deadline_epoch']-3600),
         'verified_trials':len(rows),'replacements':0,'rows':rows,'effects':effects,
         'complete_pairs':sum(len(p)==2 for p in pairs.values()),'performance_acceptance':'inconclusive',
         'uncertainty_target_met':False,'checkpoint_only_tradeoff':'accepted by the user; event-append regression gate retained',
         'planned_trials':[{'run_id':s['runIds'][0],'cell_run':s['cellRun'],'state':s['state']} for s in session['slices']],
         'interval_method':'descriptive Student t interval on paired log ratios; df=pairs-1; not the unchanged Kenshou policy acceptance report',
         'evidence_sha256':{str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name not in ['summary.json','README.md']}}
(dest/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'whole_experiment_minutes':summary['whole_experiment_seconds']/60,'verified_trials':len(rows),'effects':effects},indent=2))
