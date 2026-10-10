import hashlib,json,pathlib,time
root=pathlib.Path('/tmp/mp12-ep6-diagnosis');cache=root/'observed-results.json';rows=json.loads(cache.read_text()) if cache.exists() else [];seen={(r['case'],r['cell_run'],r['run_id']) for r in rows}
for name in ['calibration','real-adapter','diagnostic','live-hook-fanout']:
 out=root/('remote-'+name);paths=[out/'session.json'] if name in ['calibration','diagnostic'] else list(out.glob('round-*/session.json'))
 for path in paths:
  if not path.exists():continue
  session=json.loads(path.read_text())
  for entry in session['slices']:
   if entry['state']!='verified':continue
   tree=pathlib.Path(entry['fetchedPath']);manifest=tree/'manifest.json'
   if all((name,entry['cellRun'],run) in seen for run in entry['runIds']):continue
   assert hashlib.sha256(manifest.read_bytes()).hexdigest()==entry['manifestSha256']
   for artifact in json.loads(manifest.read_text())['artifacts']:
    item=tree/artifact['path'];assert item.stat().st_size==artifact['bytes'];assert hashlib.sha256(item.read_bytes()).hexdigest()==artifact['sha256']
   reset=json.loads((tree/'cell/reset-evidence.json').read_text());assert reset['verified']
   for run in entry['runIds']:
    if (name,entry['cellRun'],run) in seen:continue
    d=json.loads((tree/'output'/run/'run-result.json').read_text());assert d['outcome']=='passed',d.get('reason')
    m=d['summaries']['measurements'];w=m['write-probe'];assert m['measurements']['grade']=='benchmark'
    before={r['queryid']:r['calls'] for r in w['checkpoint_sql_before']};calls=sum(r['calls']-before.get(r['queryid'],0) for r in w['checkpoint_sql_after'])
    assert w['delivered']==w['expected_delivered'];assert w['checkpoint_updates']==w['delivery_batches']==calls;assert w['durable_drained'] and w['durability']=='on,on,on'
    metrics={k:v['value'] for k,v in m['measurements']['metrics'].items()}
    rows.append({'case':name,'run_id':run,'cell_run':entry['cellRun'],'comparison':d.get('comparison'),'events':w['events'],'delivery_batches':w['delivery_batches'],'checkpoint_calls':calls,'metrics':metrics,'manifest_sha256':entry['manifestSha256']});seen.add((name,entry['cellRun'],run))
cache.write_text(json.dumps(rows,indent=2)+'\n')
j=json.loads((root/'journal.json').read_text());print(json.dumps({'phase':j['phase'],'current_run':j.get('current_run'),'remote_phase':j.get('remote_status',{}).get('phase') if j.get('remote_status',{}).get('runId')==j.get('current_run') else 'awaiting current-run status','remaining_minutes':round((j['deadline_epoch']-time.time())/60,1),'independently_verified_trials':len(rows),'trials':[{'case':r['case'],'comparison':r['comparison'],'events':r['events'],'batches':r['delivery_batches'],'eps':round(r['metrics']['op.append.throughput'],2),'p99_ms':round(r['metrics']['op.append.latency.p99']/1_000_000,3)} for r in rows]},indent=2))
