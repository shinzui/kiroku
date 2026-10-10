import datetime,json,os,pathlib,signal,subprocess,time
folder=pathlib.Path(__file__).resolve().parent
root=folder.parents[3]
packages=list(json.loads((root/'kiroku-store/bench/results/ep6-release/proposal/versions.json').read_text()))
commands=[('package-build',['cabal','build','all'],root,1200)]
commands += [(p+'-check',['cabal','check'],root/p,120) for p in packages]
commands += [('sdist',['cabal','sdist']+packages,root,180),('haddock',['cabal','haddock']+packages+['--haddock-for-hackage','--haddock-hyperlink-source','--haddock-quickjump'],root,1200)]
journal={'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':'starting','stages':[]}
def save():
 (folder/'package-journal.json').write_text(json.dumps(journal,indent=2)+'\n')
for name,command,cwd,limit in commands:
 stage={'name':name,'command':command,'cwd':str(cwd.relative_to(root)),'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 journal['phase']=name;journal['stages'].append(stage);save();print('START '+name,flush=True)
 with (folder/(name+'.log')).open('w') as log:
  p=subprocess.Popen(command,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  try:code=p.wait(timeout=limit)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   code=124
 stage['exit_code']=code;stage['finished_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();save();print('END '+name+' exit='+str(code),flush=True)
 if code:
  journal['phase']='failed';save();raise SystemExit(code)
journal['phase']='complete';save()
