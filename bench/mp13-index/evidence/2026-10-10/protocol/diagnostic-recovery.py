from pathlib import Path
import importlib.util,json,subprocess,hashlib,time
root=Path('/tmp/mp13-index-experiment-20261010');src=Path('bench/mp13-index/run.py')
spec=importlib.util.spec_from_file_location('original_controller',src);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
# Reuse every original hash/counter check. Only collect rejected grade separately;
# never modify artifacts or promote these records to benchmark-grade verification.
text=src.read_text().replace("if result['outcome'] != 'passed' or measure['grade'] != 'benchmark' or measure['gradeReasons']:","if result['outcome'] not in ['passed', 'inconclusive']:")
namespace={'__file__':str(src.resolve()),'__name__':'diagnostic_recovery'};exec(compile(text,str(src),'exec'),namespace)
case=root/'existing-category-browse';rows=namespace['verified'](case/'session/session.json')
for row in rows:
 row['evidenceClassification']='artifact-hash-and-workload-invariant-verified; exploratory; not acceptance-grade'
 if row['writeProbe']['delivered']!=row['writeProbe']['expected_delivered']:raise ValueError('delivery mismatch')
(case/'diagnostic-records.json').write_text(json.dumps(rows,indent=2)+'\n')
operator='/tmp/mp13-kenshou-operator/bin/kenshou'
with (root/'diagnostic-recomputation.log').open('w') as log:
 for row in rows:
  code=subprocess.run([operator,'summarize',row['path'],'--verify'],stdout=log,stderr=subprocess.STDOUT,timeout=30).returncode
  if code not in [0,3]:raise ValueError(f'raw verification exit {code}')
 baseline=sorted([x for x in rows if x['comparison']['arm']=='baseline'],key=lambda x:x['comparison']['trial']);candidate=sorted([x for x in rows if x['comparison']['arm']=='candidate'],key=lambda x:x['comparison']['trial'])
 args=[operator,'compare','--policy',str(m.POLICY),'--vary','knob:mp13.index-layout','--out',str(case/'comparison.json')]+[s for row in baseline for s in ['--baseline',row['path']]]+[s for row in candidate for s in ['--candidate',row['path']]]
 code=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=60).returncode
 if code not in [0,2,3]:raise ValueError('diagnostic comparison failed')
(root/'diagnostic-recovery.json').write_text(json.dumps({'at':time.time(),'sourceControllerSha256':hashlib.sha256(src.read_bytes()).hexdigest(),'recoveryScriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'classification':'exploratory only; original policy unchanged','records':len(rows),'noReruns':True,'originalArtifactsUnmodified':True},indent=2)+'\n')
print(json.dumps(json.loads((case/'comparison.json').read_text())['reasons']))
