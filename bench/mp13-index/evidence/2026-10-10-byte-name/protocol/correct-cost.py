import json,pathlib,hashlib,time,math
r=pathlib.Path('/tmp/mp13-byte-name-experiment-20261010-2355')
for case in ['fresh','existing-category-browse']:
 p=r/case/'comparison.json'
 if not p.exists():continue
 c=json.loads(p.read_text());metrics={}
 for name,row in c['metrics'].items():
  t=name.endswith('throughput');a=row['ratio']
  ratio={'estimate':1/a['estimate'],'low':1/a['high'],'high':1/a['low']} if t else a
  actual=math.exp(sum(math.log(x['candidate']/x['baseline']) for x in row['pairs'])/len(row['pairs']))
  assert math.isclose(actual,ratio['estimate'],rel_tol=1e-10)
  lo=(ratio['low']-1)*100;hi=(ratio['high']-1)*100
  metrics[name]={'candidateChangePercent':(ratio['estimate']-1)*100,'confidenceIntervalPercent':[lo,hi],'upperSlowdownBoundPercent':max(0,-lo if t else hi),'candidateOverBaselineRatio':ratio,'comparisonAdverseRatio':a,'relativeIntervalWidth':a['high']/a['low']-1,'precisionTargetMet':a['high']/a['low']<=1+c['policy']['maxCiRelativeWidth']}
 result={'purpose':'cost estimation, separate from unchanged zero-slowdown policy','ratioSemantics':'Kenshou normalizes adverse ratios: baseline/candidate for throughput, candidate/baseline for latency; actual candidate changes invert throughput ratios.','confidenceLevel':c['policy']['confidenceLevel'],'pairs':c['pairCount'],'policyVerdict':c['verdict'],'comparisonSha256':hashlib.sha256(p.read_bytes()).hexdigest(),'metrics':metrics}
 (r/case/'cost-estimates-corrected.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({'case':case,'metrics':metrics}))
note={'epoch':time.time(),'reason':'Reporting helper changed before trials incorrectly assumed every comparison ratio was candidate/baseline; source verification confirms adverse ratio normalization. Preserve original derived reports and produce corrected sidecars from unchanged paired comparison/raw data. Workload, policy, controller inputs, trial identities, and acceptance verdict are unchanged.','source':'mori://shinzui/keiro-runtime-kenshou; kenshou-measure/src/Kenshou/Measure/Compare.hs compareMetricPairs (artifact-level URI pending)','reported_implementation':'/tmp/mp13-correct-cost.py'}
(r/'reporting-correction.json').write_text(json.dumps(note,indent=2)+'\n')
