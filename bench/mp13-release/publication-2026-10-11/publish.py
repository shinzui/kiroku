"""Publish the authorized, committed cohort; retain a resumable per-package journal."""
from pathlib import Path
import hashlib,json,subprocess,tarfile,time
root=Path(__file__).resolve().parent
versions=json.loads((root/'authorization.json').read_text())['versions']
order=['kiroku-store','kiroku-store-migrations','kiroku-otel','kiroku-cli','kiroku-metrics','shibuya-kiroku-adapter']
commit=(root/'release-commit.txt').read_text().strip()
state_path=root/'publication.json';state=json.loads(state_path.read_text()) if state_path.exists() else {'commit':commit,'packages':{}}
assert state['commit']==commit
hash_file=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
# Hackage injects this presentation-only rule into served Haddock HTML.
css=b'<style type="text/css">#synopsis details:not([open]) > ul { visibility: hidden; }</style>'
def verify_html(path,expected_bytes):
 data=path.read_bytes()
 assert data.count(css)<=1
 assert data.replace(css,b'')==expected_bytes,'published documentation body differs: '+str(path)
 return {'served_sha256':hash_file(path),'local_sha256':hashlib.sha256(expected_bytes).hexdigest(),'hackage_css_injection_removed':css in data}
def save():state_path.write_text(json.dumps(state,indent=2)+'\n')
def command(args,name):
 with (root/(name+'.log')).open('a') as log:
  subprocess.run(args,stdout=log,stderr=log,check=True,timeout=180)
def download(url,path):
 subprocess.run(['curl','-fsSL','--retry','2','--max-time','30',url,'-o',str(path)],check=True,timeout=100)
for package in order:
 version=versions[package][1];ident=package+'-'+version;tag=package+'-v'+version
 assert subprocess.check_output(['git','rev-parse',tag+'^{}'],text=True).strip()==commit
 source=root/'sdist'/(ident+'.tar.gz');docs=root/'docs'/(ident+'-docs.tar.gz')
 expected=json.loads((root/'source-archives.json').read_text())[source.name]['sha256'];assert hash_file(source)==expected
 assert hash_file(docs)==json.loads((root/'documentation-archives.json').read_text())[docs.name]['sha256']
 item=state['packages'].setdefault(package,{'version':version,'tag':tag,'hackage':'https://hackage.haskell.org/package/'+ident});save()
 if not item.get('source_uploaded'):
  command(['cabal','upload','--publish',str(source)],package+'-upload-source');item['source_uploaded']=True;save()
 remote=root/(ident+'-remote.tar.gz');download(item['hackage']+'/'+ident+'.tar.gz',remote)
 assert hash_file(remote)==expected,'published source bytes differ: '+package
 item['source_verified_sha256']=expected;save()
 if not item.get('documentation_uploaded'):
  command(['cabal','upload','--publish','--documentation',str(docs)],package+'-upload-docs');item['documentation_uploaded']=True;save()
 index=root/(ident+'-remote-index.html');download(item['hackage']+'/docs/doc-index.html',index)
 with tarfile.open(docs) as archive:
  index_member=next(m for m in archive.getmembers() if m.name==ident+'-docs/doc-index.html')
  expected_index=archive.extractfile(index_member).read()
  module={'kiroku-store':'Kiroku-Store','kiroku-store-migrations':'Kiroku-Store-Migrations','kiroku-metrics':'Kiroku-Metrics','kiroku-cli':'Kiroku-Cli','kiroku-otel':'Kiroku-Otel-Subscription','shibuya-kiroku-adapter':'Shibuya-Adapter-Kiroku'}[package]+'.html'
  expected_module=archive.extractfile(ident+'-docs/'+module).read()
 item['documentation_index']=verify_html(index,expected_index)
 module_path=root/(ident+'-remote-module.html');download(item['hackage']+'/docs/'+module,module_path)
 item['documentation_module']=verify_html(module_path,expected_module);save()
 if not item.get('github_release'):
  command(['gh','release','create',tag,'--verify-tag','--title',package+' v'+version,'--notes-file',str(root/'release-notes'/(package+'.md'))],package+'-github-release')
  item['github_release']=json.loads(subprocess.check_output(['gh','release','view',tag,'--json','url'],text=True))['url'];save()
 item['verified_at']=time.time();save();print(package,version,'published and verified',flush=True)
state['complete']=True;state['finished']=time.time();save()
