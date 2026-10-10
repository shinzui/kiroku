import datetime,hashlib,json,pathlib,subprocess
folder=pathlib.Path(__file__).resolve().parent
root=folder.parents[3]
records=json.loads((root/'kiroku-store/bench/results/ep6-artifacts/archives.json').read_text())
journal={'release_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':'starting','actions':[]}
def save():
 (folder/'journal.json').write_text(json.dumps(journal,indent=2)+'\n')
for record in records:
 package=record['package'];version=record['version'];tag=f'{package}-v{version}'
 for kind in ['source','docs']:
  path=root/record[kind]['path'];assert hashlib.sha256(path.read_bytes()).hexdigest()==record[kind]['sha256']
 commands=[('source-upload',['cabal','upload','--publish',str(root/record['source']['path'])]),('docs-upload',['cabal','upload','--publish','--documentation',str(root/record['docs']['path'])]),('github-release',['gh','release','create',tag,'--repo','shinzui/kiroku','--verify-tag','--title',f'{package} v{version}','--notes-file',str(root/'kiroku-store/bench/results/ep6-artifacts/release-notes'/f'{package}.md')])]
 for action,command in commands:
  entry={'package':package,'version':version,'action':action,'command':command,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
  journal['actions'].append(entry);journal['phase']=f'{package}:{action}';save();print('START '+journal['phase'],flush=True)
  with (folder/f'{package}-{action}.log').open('w') as log:
   try:r=subprocess.run(command,cwd=root,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,timeout=180)
   except subprocess.TimeoutExpired:
    entry['exit_code']=124;journal['phase']='failed';save();raise
  entry['exit_code']=r.returncode;entry['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();save();print('END '+package+':'+action+' exit='+str(r.returncode),flush=True)
  if r.returncode:
   journal['phase']='failed';save();raise SystemExit(r.returncode)
journal['phase']='complete';save()
