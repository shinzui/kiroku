#!/usr/bin/env python3
"""One bounded, resumable sealed stage; never replace an interrupted trial."""
import argparse, csv, datetime, hashlib, json, os, pathlib, signal, subprocess, time, uuid

ENV = dict(os.environ, CLOUDSDK_CORE_PROJECT="tan-nb-exp")

def read(path): return json.loads(pathlib.Path(path).read_text())
def digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def write(path, value):
    path=pathlib.Path(path); temporary=path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value,indent=2)+'\n'); temporary.replace(path)

class Run:
    def __init__(self,a):
        self.a=a; self.root=a.out; self.root.mkdir(parents=True,exist_ok=True)
        self.deadline=datetime.datetime.fromisoformat(a.started.read_text().strip().replace('Z','+00:00')).timestamp()+3600
        self.ctl=[str(a.cellctl),'--control-bucket','tan-nb-exp-cells-control']
        self.path=self.root/'journal.json'; self.holder=None; self.owned=False
        if self.path.exists():
            self.j=read(self.path)
            if self.j['payload_sha256']!=digest(a.payload) or self.j['kind']!=a.kind: raise ValueError('immutable inputs changed')
        else:
            self.j=dict(kind=a.kind,payload_sha256=digest(a.payload),deadline=self.deadline,run_id=str(uuid.uuid7()),lease_id=str(uuid.uuid7()),status='new',verified_trials=0)
            self.save()
    def save(self): write(self.path,self.j)
    def command(self,args,label,timeout=60,allow_failure=False,cleanup=False):
        remaining=self.deadline-time.time()
        if remaining<=90 and not cleanup: raise TimeoutError('cleanup reserve reached')
        try:
            result=subprocess.run(list(map(str,args)),capture_output=True,text=True,env=ENV,timeout=timeout if cleanup else min(timeout,remaining-60))
        except subprocess.TimeoutExpired as error:
            for suffix,value in [('stdout',error.stdout),('stderr',error.stderr)]:
                (self.root/(label+'.'+suffix)).write_text(value.decode() if isinstance(value,bytes) else (value or ''))
            raise
        (self.root/(label+'.stdout')).write_text(result.stdout);(self.root/(label+'.stderr')).write_text(result.stderr)
        with (self.root/'commands.jsonl').open('a') as history:
            history.write(json.dumps(dict(at=time.time(),label=label,args=list(map(str,args)),exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr))+'\n')
        if result.returncode and not allow_failure: raise RuntimeError(label+': '+result.stderr[-1500:])
        return result
    def lease(self):
        result=self.command(self.ctl+['lease','show','--cell','alpha'],'lease-show',allow_failure=True)
        if result.returncode and 'has no active lease' in result.stderr:return None
        if result.returncode:raise RuntimeError('lease lookup failed: '+result.stderr)
        return json.loads(result.stdout)['lease']
    def acquire(self):
        held=self.lease()
        wait_until=min(time.time()+self.a.wait_seconds,self.deadline-300)
        while held and held['leaseId']!=self.j['lease_id']:
            if time.time()>=wait_until:raise RuntimeError('cell is leased by another owner; bounded wait finished')
            print('waiting for other-owner lease',held['owner'],held.get('heartbeatAt'),flush=True)
            time.sleep(min(30,wait_until-time.time()))
            held=self.lease()
        if not held:
            result=self.command(self.ctl+['lease','acquire','--cell','alpha','--lease-id',self.j['lease_id'],'--owner','kiroku-ep97','--purpose','stream head cost','--ttl-seconds','120'],'lease-acquire')
            if json.loads(result.stdout)['outcome']!='acquired':raise RuntimeError('lease refused')
        self.owned=True
        self.j.update(owned_lease_released=False,acquired_epoch=time.time());self.save()
        self.holder_log=(self.root/'lease-holder.log').open('a')
        self.holder=subprocess.Popen(self.ctl+['lease','hold','--cell','alpha','--lease-id',self.j['lease_id']],stdout=self.holder_log,stderr=subprocess.STDOUT,env=ENV)
        transition_until=time.time()+150
        while True:
            states=json.loads(self.command(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~^cell-alpha-','--format=json(name,status)'],'power-before-start',45).stdout)
            if len(states)==4 and all(x['status'] in ('RUNNING','TERMINATED') for x in states):break
            if time.time()>=transition_until:raise TimeoutError('cell power transition stalled')
            time.sleep(10)
        self.command(['bash',self.a.infra/'scripts/cell/start.sh','alpha'],'start',180)
    def status(self):
        uri=f"gs://tan-nb-exp-cells-control/cells/alpha/submissions/{self.j['run_id']}"
        r=self.command(['gcloud','storage','cat',uri+'/status.json','--project=tan-nb-exp'],'status',45,True)
        if r.returncode==0:return json.loads(r.stdout)
        rejection=self.command(['gcloud','storage','cat',uri+'/rejected.json','--project=tan-nb-exp'],'rejected',45,True)
        if rejection.returncode==0:raise RuntimeError('submission rejected: '+rejection.stdout)
        return {}
    def submit(self):
        seconds={'proof':120,'head':480,'gate':720}[self.a.kind]
        if self.deadline-time.time()<seconds+180:raise TimeoutError('insufficient remaining budget for stage and cleanup')
        write(self.root/'work.json',dict(kind=self.a.kind,seconds=seconds))
        work=self.root/'work.json'
        submission=dict(schema='cell.submission/v1',runId=self.j['run_id'],leaseId=self.j['lease_id'],payload=read(self.a.payload),work=dict(sha256=digest(work),bytes=work.stat().st_size,mediaType='application/json'),env={},reset=dict(cachePolicy='warm',postgres=dict(major=18,databases=[dict(name=n,owner='benchmark',template='template0') for n in ['benchmark','ep97_1','ep97_2','ep97_3','ep97_4']],settings=dict(shared_buffers='128MB',fsync='on',synchronous_commit='on',full_page_writes='on',wal_level='replica'))),limits=dict(wallClockSeconds=seconds+60,memoryMaxBytes=8*1024**3,outputMaxBytes=256*1024**2),requires=dict(protocol='cell.protocol/v1',minAgentVersion='0.1.0'),collect=dict(traces=False),labels=dict(purpose='ep97-stream-head',kind=self.a.kind))
        write(self.root/'submission.json',submission)
        self.j.update(status='submitting',submitted_epoch=time.time()); self.save()
        self.command(self.ctl+['submit','--cell','alpha','--submission',self.root/'submission.json','--work',work],'submit',120)
        self.j['status']='submitted';self.save()
    def collect(self,status):
        fetched=self.root/'fetched'
        if not (fetched/'manifest.json').exists():
            self.command(self.ctl+['fetch','--results-bucket','tan-nb-exp-cells-results',self.j['run_id'],fetched],'fetch',120)
        self.command(self.ctl+['verify',fetched],'verify',120)
        if status.get('manifestSha256') and status['manifestSha256'].removeprefix('sha256:')!=digest(fetched/'manifest.json'):raise ValueError('status/manifest digest mismatch')
        result=read(fetched/'cell/result.json')
        summary=read(fetched/'output/summary.json')
        rows=list(csv.DictReader((fetched/'output/timings.csv').open()))
        expected={'proof':1,'head':6,'gate':16}[self.a.kind]
        if len(rows)!=expected:raise ValueError(f'expected {expected} timing cells, found {len(rows)}')
        for row in rows:
            mean=float(row['Mean (ps)']); spread=float(row['2*Stdev (ps)'])
            if mean<=0:raise ValueError('invalid timing mean')
            row['relative_stdev']=spread/(2*mean)
        write(self.root/'estimates.json',rows)
        self.j.update(status='verified',verified_trials=1,result=result,summary=summary,precision_met=all(r['relative_stdev']<=.05 for r in rows),manifest_sha256=digest(fetched/'manifest.json'))
        self.save()
        return 0 if result['entryExitCode']==0 and self.j['precision_met'] else 3
    def cleanup(self):
        if not self.owned:return
        if self.holder:
            self.holder.terminate()
            try:self.holder.wait(timeout=10)
            except subprocess.TimeoutExpired:self.holder.kill();self.holder.wait()
            self.holder_log.close()
        result=self.command(self.ctl+['lease','release','--cell','alpha','--lease-id',self.j['lease_id']],'lease-release',45,True,True)
        observed=self.command(self.ctl+['lease','show','--cell','alpha'],'lease-after',45,True,True)
        held=json.loads(observed.stdout)['lease'] if observed.returncode==0 else (None if 'has no active lease' in observed.stderr else {'leaseId':self.j['lease_id']})
        self.j['owned_lease_released']=result.returncode==0 and (held is None or held['leaseId']!=self.j['lease_id'])
        self.save()
        if held is None and not self.a.keep_running:
            try:
                stop=self.command(['bash',self.a.infra/'scripts/cell/stop.sh','alpha'],'stop',120,True,True)
                self.j['stop_exit']=stop.returncode
            except subprocess.TimeoutExpired:
                self.j['stop_timeout']=True
        self.j['finished_epoch']=time.time();self.save()
        if not self.j['owned_lease_released']:raise RuntimeError('owned lease release not verified')
    def run(self):
        try:
            # Resume the existing run before considering submission. No trial replacement.
            status=self.status() if self.j['status']!='new' else {}
            if status.get('phase')=='sealed':
                held=self.lease()
                self.owned=held is not None and held['leaseId']==self.j['lease_id']
                return self.collect(status)
            self.acquire()
            if self.j['status'] in ('new','submitting'):self.submit()
            previous=None;changed=time.time()
            while True:
                if self.holder.poll() is not None:raise RuntimeError('lease holder exited')
                status=self.status(); phase=status.get('phase','awaiting-status')
                states=json.loads(self.command(['gcloud','compute','instances','list','--project=tan-nb-exp','--filter=name~^cell-alpha-','--format=json(name,status)'],'power',45).stdout)
                if len(states)!=4 or any(s['status']!='RUNNING' for s in states):raise RuntimeError('cell power state is not four running instances')
                marker=(phase,status.get('logChunks'))
                if marker!=previous:previous=marker;changed=time.time()
                audit=dict(at=time.time(),run_id=self.j['run_id'],phase=phase,power=states,verified_trials=self.j['verified_trials'])
                with (self.root/'progress.jsonl').open('a') as out:out.write(json.dumps(audit)+'\n')
                self.j['phase']=phase;self.save();print(json.dumps(audit),flush=True)
                if phase=='sealed':return self.collect(status)
                maximum=read(self.root/'work.json')['seconds']+90 if phase=='running' else 240
                if time.time()-changed>maximum:raise TimeoutError('remote phase has stalled')
                time.sleep(10)
        except BaseException as error:
            self.j['error']=str(error);self.save();raise
        finally:self.cleanup()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('cellctl','infra','payload','out','started'):p.add_argument('--'+name,type=pathlib.Path,required=True)
    p.add_argument('--kind',choices=['proof','head','gate'],required=True)
    p.add_argument('--wait-seconds',type=int,default=0)
    p.add_argument('--keep-running',action='store_true')
    a=p.parse_args()
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    raise SystemExit(Run(a).run())
if __name__=='__main__':main()
