#!/usr/bin/env python3
"""Bounded cellctl controller. A failed/interrupted measured trial is never retried."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import shlex
import subprocess
import time
import uuid

spec = importlib.util.spec_from_file_location('local_validation', Path(__file__).with_name('run.py'))
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


def read(path): return json.loads(Path(path).read_text())
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write(path, data):
    path = Path(path); temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, indent=2) + '\n'); temp.replace(path)


class Controller:
    def __init__(self, args):
        self.args = args
        self.root = args.out
        self.root.mkdir(parents=True, exist_ok=True)
        budget = read(args.budget)
        self.deadline = budget['started_epoch'] + budget['budget_seconds']
        self.ctl = [args.cellctl, '--control-bucket', 'tan-nb-exp-cells-control']
        self.holder = None
        self.lease = None
        self.template = None
        self.journal_path = self.root/'journal.json'
        if self.journal_path.exists():
            self.journal = read(self.journal_path)
            if self.journal['payload_sha256'] != digest(args.payload): raise ValueError('payload changed')
            if args.resume and not self.journal['trials'] and self.journal.get('lease_release_exit')==0:
                archive=self.root/('setup-attempt-'+str(len(self.journal.get('recoveries',[]))))
                archive.mkdir(exist_ok=False)
                for path in self.root.iterdir():
                    if path.is_file():shutil.copy2(path,archive/path.name)
                self.journal.setdefault('recoveries',[]).append(dict(at=time.time(),previous_journal=str(archive/'journal.json'),reason='resume before any trial submission'))
                for key in ('lease_id','lease_release_exit','stop_exit','all_stopped','finished','error'):
                    self.journal.pop(key,None)
                self.journal['status']='preparing';self.save()
                return
            if self.journal['status'] != 'complete':
                raise RuntimeError('unfinished journal retained; fetch/verify its existing run before any new submission')
            raise RuntimeError('completed journal is immutable; do not replace measured trials')
        self.journal = dict(started=time.time(), deadline=self.deadline, payload_sha256=digest(args.payload), trials=[], status='preparing')
        self.save()

    def save(self): write(self.journal_path, self.journal)
    def remaining(self): return self.deadline - time.time()
    def command(self, args, name, timeout=120, allow_failure=False):
        if self.remaining() <= 0: raise TimeoutError('whole-experiment deadline')
        command=list(map(str,args))
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        try:
            stdout,stderr=process.communicate(timeout=min(timeout,max(1,self.remaining())))
        except BaseException:
            # SSH wrappers can leave descendants holding pipes after their parent
            # exits. Bound the entire process group, including those descendants.
            os.killpg(process.pid,signal.SIGKILL)
            stdout,stderr=process.communicate(timeout=5)
            (self.root/(name+'.stdout')).write_text(stdout)
            (self.root/(name+'.stderr')).write_text(stderr)
            raise
        result=subprocess.CompletedProcess(command,process.returncode,stdout,stderr)
        (self.root/(name+'.stdout')).write_text(result.stdout)
        (self.root/(name+'.stderr')).write_text(result.stderr)
        if result.returncode and not allow_failure: raise RuntimeError(f'{name} failed ({result.returncode})')
        return result

    def acquire(self):
        self.lease = str(uuid.uuid7())
        result=self.command(self.ctl+['lease','acquire','--cell','alpha','--lease-id',self.lease,'--owner','kiroku-mp13','--purpose','inspection validation','--ttl-seconds','120'],'lease-acquire')
        if json.loads(result.stdout)['outcome'] != 'acquired': raise RuntimeError('lease not acquired')
        self.journal['lease_id']=self.lease;self.save()
        self.holder_log=(self.root/'lease-holder.log').open('a')
        self.holder=subprocess.Popen(self.ctl+['lease','hold','--cell','alpha','--lease-id',self.lease],stdout=self.holder_log,stderr=subprocess.STDOUT)
        self.command(['bash',str(self.args.infra/'scripts/cell/start.sh'),'alpha'],'start',180)
        if not self.args.gate:
            # GCE RUNNING precedes sshd readiness after a cold cell start.
            self.journal['phase']='waiting-for-ssh-readiness';self.save()
            time.sleep(30)
            name = 'mp13_' + self.lease.replace('-', '')
            self.admin_sql('postgres', 'CREATE DATABASE ' + name + ' TEMPLATE template0', 'template-create')
            self.template = name
            self.journal['template'] = name; self.save()
            self.admin_sql(name, 'CREATE EXTENSION pg_stat_statements WITH SCHEMA public', 'template-extension')
            self.admin_sql('postgres', 'ALTER DATABASE ' + name + ' IS_TEMPLATE true', 'template-enable')

    def admin_sql(self, database, sql, name):
        command = shlex.join(['sudo','-u','postgres','psql','-X','-v','ON_ERROR_STOP=1','-d',database,'-c',sql])
        return self.command(['bash',str(self.args.infra/'scripts/iap-ssh.sh'),'ssh','cell-alpha-postgres','--',command],name,90)

    def trial(self, arm, mode, label):
        if self.remaining() < 240: raise TimeoutError('insufficient time for trial plus cleanup')
        folder=self.root/label;folder.mkdir(exist_ok=False)
        work=dict(arm=arm,mode=mode,warmup_seconds=10,measurement_seconds=30)
        write(folder/'work.json',work)
        run_id=str(uuid.uuid7())
        submission=dict(schema='cell.submission/v1',runId=run_id,leaseId=self.lease,payload=read(self.args.payload),
          work=dict(sha256=digest(folder/'work.json'),bytes=(folder/'work.json').stat().st_size,mediaType='application/json'),env={},
          reset=dict(cachePolicy='warm',postgres=dict(major=18,databases=[dict(name='benchmark',owner='benchmark',template=self.template or 'template0')],
             settings=dict(shared_buffers='128MB',fsync='on',synchronous_commit='on',full_page_writes='on',wal_level='replica'))),
          limits=dict(wallClockSeconds=480 if mode=='gate' else 180,memoryMaxBytes=8*1024**3,outputMaxBytes=256*1024**2),
          requires=dict(protocol='cell.protocol/v1',minAgentVersion='0.1.0'),collect=dict(traces=False),labels=dict(arm=arm,mode=mode,purpose='mp13-inspection'))
        write(folder/'submission.json',submission)
        row=dict(label=label,arm=arm,mode=mode,run_id=run_id,started=time.time(),status='submitting')
        self.journal['trials'].append(row);self.save()
        self.command(self.ctl+['submit','--cell','alpha','--submission',folder/'submission.json','--work',folder/'work.json'],label+'-submit')
        previous=None;progress=time.time()
        while True:
            if self.holder.poll() is not None: raise RuntimeError('lease holder exited')
            if self.remaining() < 180: raise TimeoutError('cleanup reserve reached')
            result=self.command(['gcloud','storage','cat',f'gs://tan-nb-exp-cells-control/cells/alpha/submissions/{run_id}/status.json','--project=tan-nb-exp'],label+'-status',45,True)
            status=json.loads(result.stdout) if result.returncode==0 else {}
            rejected=self.command(['gcloud','storage','cat',f'gs://tan-nb-exp-cells-control/cells/alpha/submissions/{run_id}/rejected.json','--project=tan-nb-exp'],label+'-rejected',45,True) if not status else None
            if rejected and rejected.returncode==0: raise RuntimeError('submission rejected: '+rejected.stdout)
            phase=status.get('phase','awaiting-status')
            if phase!=previous: previous=phase;progress=time.time()
            states=self.command(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~^cell-alpha-','--format=json(name,status)'],label+'-power',45)
            machines=json.loads(states.stdout)
            if phase not in ('awaiting-status','sealed') and any(x['status']!='RUNNING' for x in machines): raise RuntimeError('instance stopped during active trial')
            audit=dict(at=time.time(),run_id=run_id,phase=phase,power=machines,verified=sum(t['status']=='verified' for t in self.journal['trials']))
            with (self.root/'progress.jsonl').open('a') as out:out.write(json.dumps(audit)+'\n')
            row['phase']=phase;self.save()
            print(label,phase,'verified',audit['verified'],flush=True)
            if phase=='sealed': break
            if time.time()-progress>(480 if mode=='gate' else 240): raise TimeoutError('remote phase exceeded its progress deadline')
            time.sleep(15)
        self.command(self.ctl+['fetch','--results-bucket','tan-nb-exp-cells-results',run_id,folder/'fetched'],label+'-fetch',120)
        self.command(self.ctl+['verify',folder/'fetched'],label+'-verify',120)
        result=read(folder/'fetched/cell/result.json')
        if result['outcome']!='completed' or result['entryExitCode']!=0: raise RuntimeError('remote execution failed; sealed evidence retained')
        if read(folder/'fetched/cell/health.json').get('passed') is not True:
            raise ValueError('cell health gates failed')
        manifest=folder/'fetched/manifest.json'
        expected=status.get('manifestSha256')
        if expected and expected.removeprefix('sha256:')!=digest(manifest):raise ValueError('status/manifest hash mismatch')
        if mode=='gate':
            if read(folder/'fetched/output/gate.json')['exit_code']!=0:raise ValueError('workload gate failed')
        else:
            data=validation.validate(folder/'fetched/output/trial.json',arm,mode)
            if data['sql_before'] is None or data['sql_after'] is None:raise ValueError('SQL diagnostics unavailable')
            if data['warmup_seconds']!=work['warmup_seconds'] or data['measurement_seconds']!=work['measurement_seconds']:
                raise ValueError('measurement phases differ from submitted work')
            row['trial_sha256']=digest(folder/'fetched/output/trial.json')
        row.update(status='verified',finished=time.time(),manifest_sha256=digest(manifest))
        self.save()

    def cleanup(self):
        # Cleanup has its own short reserve, never a fresh experiment budget.
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        if self.lease and 'lease_id' in self.journal:
            if self.template:
                try:
                    self.admin_sql('postgres','ALTER DATABASE '+self.template+' IS_TEMPLATE false','template-disable')
                    self.admin_sql('postgres','DROP DATABASE '+self.template,'template-drop')
                    self.journal['template_removed']=True
                except Exception as error:
                    self.journal['template_cleanup_error']=str(error)
            if self.holder:
                self.holder.terminate()
                try:self.holder.wait(timeout=10)
                except subprocess.TimeoutExpired:self.holder.kill();self.holder.wait()
                self.holder_log.close()
            release=subprocess.run(self.ctl+['lease','release','--cell','alpha','--lease-id',self.lease],capture_output=True,text=True,timeout=45)
            (self.root/'lease-release.log').write_text(release.stdout+release.stderr)
            self.journal['lease_release_exit']=release.returncode
            self.save()
            if release.returncode==0:
                stop=subprocess.run(['bash',str(self.args.infra/'scripts/cell/stop.sh'),'alpha'],capture_output=True,text=True,timeout=90)
                (self.root/'stop.log').write_text(stop.stdout+stop.stderr)
                self.journal['stop_exit']=stop.returncode
                states=subprocess.run(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~^cell-alpha-','--format=json(name,status)'],capture_output=True,text=True,timeout=45)
                (self.root/'power-after.json').write_text(states.stdout)
                machines=json.loads(states.stdout) if states.returncode==0 else []
                self.journal['all_stopped']=len(machines)==4 and all(x['status']=='TERMINATED' for x in machines)
        self.journal['finished']=time.time();self.save()

    def run(self):
        try:
            modes=('disabled','active') if self.args.case=='both' else (self.args.case,)
            estimate=600 if self.args.gate else (420 if self.args.proof else len(modes)*10*self.args.seconds_per_trial+180)
            if self.remaining()<estimate:raise TimeoutError(f'queue needs {estimate:.0f}s, only {self.remaining():.0f}s remain; no lease acquired')
            if not self.args.proof and not self.args.gate:
                if self.args.proof_journal is None: raise ValueError('verified lifecycle proof required before queue expansion')
                proof=read(self.args.proof_journal)
                if not (proof['status']=='complete' and proof['payload_sha256']==digest(self.args.payload)
                        and proof.get('lease_release_exit')==0 and proof.get('all_stopped') is True
                        and proof.get('template_removed') is True
                        and len(proof['trials'])==1 and proof['trials'][0]['status']=='verified'):
                    raise ValueError('lifecycle proof or cleanup incomplete')
            self.acquire();self.journal['status']='running';self.save()
            schedule=[('candidate','gate','gate')] if self.args.gate else ([('candidate','active','proof')] if self.args.proof else [(arm,mode,f'{mode}-{pair}-{arm}') for mode in modes for pair in range(5) for arm in (('control','candidate') if pair%2==0 else ('candidate','control'))])
            # Admit the whole predeclared queue before submitting measured trials.
            if self.remaining()<estimate:raise TimeoutError(f'queue needs {estimate:.0f}s, only {self.remaining():.0f}s remain; no measurements submitted')
            for arm,mode,label in schedule:self.trial(arm,mode,label)
            self.journal['status']='complete'
        except BaseException as error:
            if self.journal['trials'] and self.journal['trials'][-1]['status']!='verified':
                self.journal['trials'][-1].update(status='failed',error=str(error))
            self.journal.update(status='stopped',error=str(error));self.save();raise
        finally:self.cleanup()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cellctl',required=True);p.add_argument('--infra',type=Path,required=True)
    p.add_argument('--payload',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--budget',type=Path,required=True)
    mode=p.add_mutually_exclusive_group();mode.add_argument('--proof',action='store_true');mode.add_argument('--gate',action='store_true')
    p.add_argument('--seconds-per-trial',type=float,default=100)
    p.add_argument('--case',choices=['disabled','active','both'],default='both')
    p.add_argument('--proof-journal',type=Path)
    p.add_argument('--resume',action='store_true',help='Resume a setup failure with no submitted trials; preserve the original journal and budget')
    def interrupt(signum, frame): raise KeyboardInterrupt(f'signal {signum}')
    signal.signal(signal.SIGTERM, interrupt)
    Controller(p.parse_args()).run()


if __name__=='__main__':main()
