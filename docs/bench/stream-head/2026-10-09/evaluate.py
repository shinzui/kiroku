import json, pathlib, re, subprocess, tempfile, statistics, os

repo = pathlib.Path(__file__).resolve().parents[4]
out = pathlib.Path(tempfile.mkdtemp(prefix='kiroku-pr1-'))
data = out / 'pgdata'
sock = out / 'socket'
sock.mkdir()
def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kwargs)
def sql(q):
    return run(['psql','-X','-qAt','-v','ON_ERROR_STOP=1','-h',str(sock),'-d','postgres'], input='SET search_path TO kiroku, pg_catalog;\n'+q).stdout.strip()
def seed(cat, count, per, offset):
    return f"""
WITH ns AS (
 INSERT INTO streams(stream_name,stream_version)
 SELECT '{cat}-'||n,{per} FROM generate_series(1,{count}) n RETURNING stream_id,category
), f AS MATERIALIZED (
 SELECT uuidv7() event_id, s.stream_id,s.category,v::bigint version,
 {offset}+row_number() OVER(ORDER BY v,s.stream_id) gp
 FROM ns s CROSS JOIN generate_series(1,{per}) v
), e AS (
 INSERT INTO events(event_id,event_type,data)
 SELECT event_id,'PR1Fixture','{{}}'::jsonb FROM f RETURNING event_id
), home AS (
 INSERT INTO stream_events(event_id,stream_id,stream_version,original_stream_id,original_stream_version)
 SELECT f.event_id,f.stream_id,f.version,f.stream_id,f.version FROM f JOIN e USING(event_id) RETURNING event_id
)
INSERT INTO stream_events(event_id,stream_id,stream_version,original_stream_id,original_stream_version,category)
SELECT f.event_id,0,f.gp,f.stream_id,f.version,f.category FROM f JOIN e USING(event_id);
"""

src = (repo/'kiroku-store/src/Kiroku/Store/SQL.hs').read_text()
baseline = re.search(r'getStreamSQL =\s*"""(.*?)"""',src,re.S).group(1).strip()
probe = '(SELECT se.stream_version FROM stream_events se WHERE se.stream_id=0 AND se.original_stream_id=s.stream_id ORDER BY se.stream_version DESC LIMIT 1)'
combined = 'SELECT s.stream_id,s.stream_name,s.stream_version,s.created_at,s.deleted_at,s.truncate_before,'+probe+' AS head_global_position FROM streams s WHERE s.stream_name=$1'
sibling = 'SELECT s.stream_version,'+probe+' AS head_global_position FROM streams s WHERE s.stream_name=$1'
queries = {'getStream':baseline,'getStreamWithHead':combined,'versionAndHead':sibling}
try:
    run(['initdb','-D',str(data),'-A','trust','--no-locale','-E','UTF8'])
    run(['pg_ctl','-D',str(data),'-l',str(out/'postgres.log'),'-o',f"-k {sock} -c listen_addresses=''",'-w','start'])
    print('Evidence directory:',out,flush=True)
    print('Server:',sql('SELECT version();'),flush=True)
    migrations=repo/'kiroku-store-migrations/migrations'
    for name in (migrations/'manifest').read_text().splitlines():
        sql('BEGIN;\n'+(migrations/name).read_text()+'\nCOMMIT;')
    sql(seed('bench',1000,100,0)+seed('long',1,100000,100000)+"UPDATE streams SET stream_version=200000 WHERE stream_id=0; INSERT INTO streams(stream_name) VALUES('empty-1'); ANALYZE streams; ANALYZE stream_events;")
    (out/'queries.json').write_text(json.dumps(queries,indent=2))
    for state in ['before-vacuum','after-vacuum']:
        if state=='after-vacuum': sql('VACUUM (ANALYZE) stream_events;')
        for name in ['bench-1','long-1','empty-1','missing-1']:
            q=combined.replace('$1',"'"+name+"'")
            result=sql(q+';')
            plan=json.loads(sql('EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) '+q+';'))[0]
            (out/f'{state}-{name}.json').write_text(json.dumps(plan,indent=2))
            def walk(p):
                yield p
                for sub in p.get('Plans',[]):yield from walk(sub)
            nodes=list(walk(plan['Plan']))
            print(json.dumps({'state':state,'stream':name,'result':result,'buffers':plan['Plan'].get('Shared Hit Blocks',0)+plan['Plan'].get('Shared Read Blocks',0),'nodes':[{k:n[k] for k in ['Node Type','Index Name','Scan Direction','Actual Rows','Actual Loops','Heap Fetches'] if k in n} for n in nodes]}),flush=True)
    records=[]
    for stream in ['bench-1','long-1']:
        for trial in range(3):
            order=list(queries) if trial%2==0 else list(reversed(queries))
            for name in order:
                script=out/f'{name}-{stream}.sql'
                script.write_text(queries[name].replace('$1',"'"+stream+"'")+';\n')
                env=dict(os.environ,PGOPTIONS='-c search_path=kiroku,pg_catalog')
                result=run(['pgbench','-n','-h',str(sock),'-d','postgres','-c','1','-j','1','-M','prepared','-T','2','-f',str(script)],env=env)
                (out/f'bench-{stream}-{trial}-{name}.txt').write_text(result.stdout+result.stderr)
                latency=float(re.search(r'latency average = ([\d.]+)',result.stdout).group(1))
                records.append({'stream':stream,'trial':trial,'query':name,'latency_ms':latency})
        means={name:statistics.median([r['latency_ms'] for r in records if r['stream']==stream and r['query']==name]) for name in queries}
        print(json.dumps({'stream':stream,'median_ms':means,'combined_ratio':means['getStreamWithHead']/means['getStream']}),flush=True)
    (out/'timings.json').write_text(json.dumps(records,indent=2))
finally:
    if (data/'postmaster.pid').exists():run(['pg_ctl','-D',str(data),'-m','fast','-w','stop'])
