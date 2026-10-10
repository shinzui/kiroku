import datetime,json,os,pathlib,subprocess
folder=pathlib.Path(__file__).resolve().parent
consumer=pathlib.Path('/tmp/mp12-ep6-published-consumer')
journal={'consumer_directory':str(consumer),'scope':'Only exact published Hackage versions; explicit Hackage URLs during index propagation, no local source packages or package environment','stages':[]}
env=os.environ.copy();env['GHC_ENVIRONMENT']='-'
for name,command,timeout in [('index-update',['cabal','update'],180),('clean-build',['cabal','build','all'],1200),('run',['cabal','run','release-consumer'],120)]:
 entry={'name':name,'command':command,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()};journal['stages'].append(entry)
 (folder/'consumer-journal.json').write_text(json.dumps(journal,indent=2)+'\n');print('START '+name,flush=True)
 with (folder/f'consumer-{name}.log').open('w') as log:
  r=subprocess.run(command,cwd=consumer,env=env,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,timeout=timeout)
 entry['exit_code']=r.returncode;entry['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();(folder/'consumer-journal.json').write_text(json.dumps(journal,indent=2)+'\n');print('END '+name+' exit='+str(r.returncode),flush=True)
 if r.returncode:raise SystemExit(r.returncode)
plan=json.loads((consumer/'dist-newstyle/cache/plan.json').read_text());expected=json.loads((folder.parents[3]/'kiroku-store/bench/results/ep6-release/proposal/versions.json').read_text())
selected=[x for x in plan['install-plan'] if x.get('pkg-name') in expected and x.get('component-name')=='lib']
assert len(selected)==6,selected
for x in selected:
 assert x['pkg-version']==expected[x['pkg-name']][1]
 assert x['pkg-src']['type'] in ['repo-tar','remote-tar'],x
 if x['pkg-src']['type']=='remote-tar': assert x['pkg-src']['uri'].startswith('https://hackage.haskell.org/package/'),x
(folder/'consumer-resolved-packages.json').write_text(json.dumps(selected,indent=2)+'\n')
print('Six exact versions verified as published Hackage tarballs.',flush=True)
