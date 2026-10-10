import hashlib,json,pathlib,signal,os,time
root=pathlib.Path('/tmp/mp12-ep6-tail-repeat');j=json.loads((root/'journal.json').read_text());cache=root/'verified-progress.json';previous=json.loads(cache.read_text())if cache.exists()else {'rows':[]};seen={(r['case'],r['cell_run'],r['run_id'])for r in previous['rows']}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
try:
 for case in ['real-adapter','live-hook-fanout']:
  for path in (root/('remote-'+case)).glob('round-*/session.json'):
   session=json.loads(path.read_text())
   for entry in session['slices']:
    if entry['state']!='verified':continue
    if all((case,entry['cellRun'],run) in seen for run in entry['runIds']):continue
    assert entry.get('cellOutcome')=='completed' and entry.get('entryExitCode')==0,(entry['cellRun'],'cell did not complete')
    tree=pathlib.Path(entry['fetchedPath']);manifest=tree/'manifest.json';assert sha(manifest)==entry['manifestSha256']
    for artifact in json.loads(manifest.read_text())['artifacts']:
     item=tree/artifact['path'];assert item.stat().st_size==artifact['bytes']and sha(item)==artifact['sha256'],artifact['path']
    assert json.loads((tree/'cell/reset-evidence.json').read_text())['verified']
    for run in entry['runIds']:
     if (case,entry['cellRun'],run)in seen:continue
     result=json.loads((tree/'output'/run/'run-result.json').read_text());assert result['outcome']=='passed'
     m=result['summaries']['measurements'];w=m['write-probe'];assert m['measurements']['grade']=='benchmark';before={r['queryid']:r['calls']for r in w['checkpoint_sql_before']};calls=sum(r['calls']-before.get(r['queryid'],0)for r in w['checkpoint_sql_after'])
     assert w['delivered']==w.get('expected_delivered',w['events'])and calls==w['checkpoint_updates']==w['delivery_batches']and w['durable_drained']and w['durability']=='on,on,on'
     previous['rows'].append({'case':case,'cell_run':entry['cellRun'],'run_id':run,'comparison':result['comparison'],'throughput':m['measurements']['metrics']['op.append.throughput']['value'],'p99_ns':m['measurements']['metrics']['op.append.latency.p99']['value'],'events':w['events'],'delivered':w['delivered'],'batch_count':w['delivery_batches'],'checkpoint_calls':calls,'verified_epoch':time.time()})
except Exception as error:
 previous['verification_failure']=repr(error);cache.write_text(json.dumps(previous,indent=2)+'\n')
 if j['phase']not in ['completed','stopped','cleanup']:os.kill(int(pathlib.Path(root/'controller.pid').read_text()),signal.SIGINT)
 raise
previous['updated_epoch']=time.time();cache.write_text(json.dumps(previous,indent=2)+'\n')
status=j.get('remote_status');current=status if status and status.get('runId')==j.get('current_run')else None
pairs={}
for row in previous['rows']:pairs.setdefault((row['case'],row['comparison']['trial']),{})[row['comparison']['arm']]=row
print(json.dumps({'utc':time.strftime('%H:%M:%S',time.gmtime()),'phase':j['phase'],'current_run':j.get('current_run'),'remote_status':current,'power':j.get('instance_power'),'verified_new_trials':len(previous['rows']),'pairs':[{'case':k[0],'trial':k[1],'throughput_percent':100*(p['candidate']['throughput']/p['baseline']['throughput']-1),'p99_percent':100*(p['candidate']['p99_ns']/p['baseline']['p99_ns']-1)}for k,p in pairs.items()if set(p)=={'baseline','candidate'}],'error':j.get('remote_error'),'remaining_minutes':round((j['deadline_epoch']-time.time())/60,1)},indent=2))
