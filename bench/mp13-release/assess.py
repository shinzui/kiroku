#!/usr/bin/env python3
"""Verify sealed inspection evidence and invoke Kenshou's unchanged metric policy."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('controller', Path(__file__).with_name('run-cell.py'))
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)


def read(path): return json.loads(Path(path).read_text())
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write(path, data): Path(path).write_text(json.dumps(data, indent=2) + '\n')


def verify_manifest(folder, expected):
    if digest(folder/'manifest.json') != expected: raise ValueError('manifest identity differs')
    manifest=read(folder/'manifest.json')
    for artifact in manifest['artifacts']:
        path=folder/artifact['path']
        if path.stat().st_size != artifact['bytes'] or digest(path) != artifact['sha256'].removeprefix('sha256:'):
            raise ValueError('corrupt artifact: '+str(path))
    return len(manifest['artifacts'])


def observations(folder):
    fingerprints={}
    host={}
    for role in ('driver','postgres','monitoring'):
        data=read(folder/f'cell/observations/{role}.json')
        fingerprints[role]={key:data[key] for key in ('machine','image','agentVersion','systemClosure')}
        rows=data['samples']
        rates=[]
        for a,b in zip(rows,rows[1:]):
            total=b['cpuTotalTicks']-a['cpuTotalTicks']
            if total<=0: raise ValueError('nonmonotonic host CPU counter')
            busy=1-(b['cpuIdleTicks']-a['cpuIdleTicks'])/total
            steal=(b['cpuStealTicks']-a['cpuStealTicks'])/total
            rates.append((busy,steal))
        host[role]=dict(peak_busy=max(x[0] for x in rates),peak_steal=max(x[1] for x in rates),samples=len(rows))
    return fingerprints,host


def sql_delta(data):
    keys=('calls','rows','shared_blks_hit','shared_blks_read','wal_bytes')
    def aggregate(rows):
        result={}
        for row in rows:
            target=result.setdefault(row['query'],{key:0 for key in keys})
            for key in keys: target[key]+=float(row[key])
        return result
    before,after=aggregate(data['sql_before']),aggregate(data['sql_after'])
    return [dict(query=query,**{key:values[key]-before.get(query,{}).get(key,0) for key in keys})
            for query,values in sorted(after.items())]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--comparator',required=True)
    parser.add_argument('--policy',type=Path,default=Path('bench/mp12-cell/policy.json'))
    args=parser.parse_args()
    root=args.root
    journal=read(root/'cell/journal.json')
    out=root/'assessment';out.mkdir(exist_ok=True)
    records=[];inputs={};common_fingerprint=None;artifact_count=0
    for row in journal['trials']:
        if row['status']!='verified':continue
        folder=root/'cell'/row['label']/'fetched'
        artifact_count+=verify_manifest(folder,row['manifest_sha256'])
        data=controller.validation.validate(folder/'output/trial.json',row['arm'],row['mode'])
        if digest(folder/'output/trial.json')!=row['trial_sha256']:raise ValueError('trial changed')
        checkpoint=controller.validate_checkpoints(folder/'output')
        fingerprint,host=observations(folder)
        if common_fingerprint is None:common_fingerprint=fingerprint
        if fingerprint!=common_fingerprint:raise ValueError('host image/agent/runtime changed')
        if read(folder/'cell/health.json')['passed'] is not True:raise ValueError('cell health failed')
        if read(folder/'cell/result.json')['entryExitCode']!=0:raise ValueError('workload failed')
        submission=read(folder/'submission/submission.json')
        fixed={key:submission[key] for key in ('payload','reset','limits','env')}
        if inputs and fixed!=inputs:raise ValueError('trial settings changed')
        inputs=fixed
        def lsn(value):
            hi,lo=value.split('/');return (int(hi,16)<<32)+int(lo,16)
        record=dict(label=row['label'],arm=row['arm'],mode=row['mode'],run_id=row['run_id'],
            started=row['started'],finished=row['finished'],measured_appends=data['measured_appends'],
            total_appends=data['total_appends'],seconds=data['seconds'],throughput=data['throughput'],
            p50_us=data['p50_us'],p95_us=data['p95_us'],p99_us=data['p99_us'],
            wal_bytes_per_append=(lsn(data['wal_lsn_after'])-lsn(data['wal_lsn_before']))/data['measured_appends'],
            checkpoint=checkpoint,host=host,
            tail_lag_p99_us=data['observer']['lag_p99_us'] if data['observer'] else None)
        records.append(record)
        write(out/(row['label']+'-sql.json'),sql_delta(data))
    write(out/'verified-trials.json',records)
    mapping={'op.append.throughput':'throughput','op.append.latency.p50':'p50_us','op.append.latency.p95':'p95_us','op.append.latency.p99':'p99_us'}
    cases={}
    for mode in ('disabled','active'):
        matching={r['label']:r for r in records if r['mode']==mode and r['label']!='proof'}
        if len(matching)!=10:
            cases[mode]=dict(status='incomplete',verified_trials=len(matching));continue
        pairs={name:[] for name in mapping}
        ordered=[]
        for index in range(5):
            control=matching[f'{mode}-{index}-control'];candidate=matching[f'{mode}-{index}-candidate']
            first,second=(control,candidate) if index%2==0 else (candidate,control)
            if first['finished']>second['started']:raise ValueError('trials overlap or interleaving changed')
            if ordered and ordered[-1]['finished']>first['started']:raise ValueError('pair order changed')
            ordered.extend([first,second])
            for metric,key in mapping.items():pairs[metric].append([control[key],candidate[key]])
        write(out/(mode+'-pairs.json'),pairs)
        result_path=out/(mode+'-comparison.json')
        subprocess.run([args.comparator,str(args.policy),str(out/(mode+'-pairs.json')),str(result_path)],check=True)
        comparison=read(result_path)
        statuses=[metric['status'] for metric in comparison['metrics'].values()]
        verdict='regression' if 'regression' in statuses else ('pass' if all(s=='pass' for s in statuses) else 'inconclusive')
        cases[mode]=dict(status=verdict,verified_trials=10,pairs=5,metrics=comparison['metrics'])
    complete=journal['status']=='complete' and len(records)==21
    write(out/'summary.json',dict(complete=complete,verified_artifacts=artifact_count,verified_trials=len(records),
        cases=cases,fingerprint=common_fingerprint,policy_sha256=digest(args.policy),
        lease_released=journal.get('lease_release_exit')==0,all_stopped=journal.get('all_stopped'),
        scope='Unmodified Kenshou metric policy applied to independently verified opaque-probe evidence. Not a native Kenshou run-directory grade certificate.'))
    print(json.dumps({mode:case['status'] for mode,case in cases.items()}))


if __name__=='__main__': main()
