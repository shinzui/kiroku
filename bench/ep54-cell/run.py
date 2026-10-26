#!/usr/bin/env python3
"""Bounded Plan 54 Kenshou experiment. Never reset the recorded deadline."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / 'kiroku-store/bench/results/ep54-kenshou'
INFRA = '/Users/shinzui/Keikaku/bokuno/load-testing-infra'
DEADLINE = json.loads((RESULTS / 'budget.json').read_text())['deadline_epoch']
ENV = dict(os.environ, CLOUDSDK_CORE_PROJECT='tan-nb-exp', LTI_GCP_PROJECT='tan-nb-exp',
           CLOUDSDK_COMPUTE_ZONE='us-west1-a', KENSHOU_LTI_DIR=INFRA,
           KENSHOU_CELL_CAPABILITIES_DIR=str(RESULTS / 'capabilities'),
           KENSHOU_COHORT_IDENTITY=str(RESULTS / 'head-identity.json'))
OPERATOR = None


def save(name, value):
    (RESULTS / name).write_text(json.dumps(value, indent=2) + '\n')


def journal(event, **fields):
    with (RESULTS / 'controller.jsonl').open('a') as out:
        out.write(json.dumps(dict(at=time.time(), event=event, **fields)) + '\n')


def remaining():
    return DEADLINE - time.time()


def observe():
    """Actual cell phase, VM power, and verified slices; no PID-as-progress."""
    snapshot = {}
    for session in RESULTS.rglob('session.json'):
        try:
            document = json.loads(session.read_text())
            snapshot[str(session.relative_to(RESULTS))] = [
                (row.get('cellRun'), row.get('state'), row.get('cellOutcome'))
                for row in document.get('slices', [])]
        except (ValueError, OSError):
            pass
    active = [row[0] for rows in snapshot.values() for row in rows if row[1] in ['submitted', 'sealed', 'fetched']]
    commands = [
        ['gcloud', 'storage', 'cat', f'gs://tan-nb-exp-cells-control/cells/alpha/submissions/{active[-1] if active else "none"}/status.json', '--project=tan-nb-exp'],
        ['gcloud', 'compute', 'instances', 'list', '--project=tan-nb-exp', '--filter=name~^cell-alpha-', '--format=json(name,status)']]
    for key, args in zip(['remote', 'power'], commands):
        result = subprocess.run(args, env=ENV, capture_output=True, text=True, timeout=20)
        try:
            value = json.loads(result.stdout)
            if key == 'remote':
                value = {field: value.get(field) for field in ['runId', 'cellRunId', 'phase', 'outcome']}
            snapshot[key] = value
        except ValueError:
            snapshot[key] = dict(exit_code=result.returncode, error=result.stderr[-500:])
    journal('observation', snapshot=snapshot)
    return json.dumps(snapshot, sort_keys=True)


def command(args, label, minimum=1, accepted=(0,), monitor=False):
    if remaining() < minimum + 180:
        raise RuntimeError(f'{label}: insufficient remaining budget ({remaining():.0f}s) including cleanup')
    journal('started', label=label, args=list(map(str, args)))
    print(label, flush=True)
    log = RESULTS / (label + '.log')
    if log.exists():
        raise RuntimeError(f'{label}: log exists; inspect and resume the owned journal')
    with log.open('x') as output:
        child = subprocess.Popen(list(map(str, args)), cwd=ROOT, env=ENV, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        last = None
        changed = time.monotonic()
        next_observation = 0
        try:
            while child.poll() is None:
                if remaining() < 180:
                    raise RuntimeError('cleanup reserve reached')
                if monitor and time.monotonic() >= next_observation:
                    state = observe()
                    if state != last:
                        changed, last = time.monotonic(), state
                    if time.monotonic() - changed > 240:
                        raise RuntimeError('remote phase, power, and verified count stalled for 240s')
                    next_observation = time.monotonic() + 30
                time.sleep(1)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGINT)
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    child.wait(timeout=10)
    journal('finished', label=label, exit_code=child.returncode)
    if child.returncode not in accepted:
        raise RuntimeError(f'{label}: exit {child.returncode}; inspect {log}')
    return log.read_text()


def cell(*args):
    return [OPERATOR, 'cell', *args]


def status(label):
    value = json.loads(command(cell('status', '--cell', 'alpha', '--json'), label))
    if value['lease'] is not None:
        raise RuntimeError(f'{label}: lease remains held')
    return value


def cleanup():
    if not (RESULTS / 'owned-cell.json').exists():
        journal('cleanup-no-owned-cell')
        return
    inspected = subprocess.run(cell('status', '--cell', 'alpha', '--json'), env=ENV,
                               capture_output=True, text=True, timeout=25)
    if inspected.returncode:
        journal('cleanup-status-unavailable', error=inspected.stderr)
        return
    current = json.loads(inspected.stdout)
    save('cleanup-status-before.json', current)
    owned = set()
    for path in RESULTS.rglob('session.json'):
        try:
            owned.add(json.loads(path.read_text())['leaseId'])
        except (OSError, ValueError, KeyError):
            pass
    setup = RESULTS / 'setup-lease.json'
    if setup.exists():
        owned.add(json.loads(setup.read_text())['leaseId'])
    if current['lease']:
        identifier = current['lease']['leaseId']
        if identifier not in owned:
            journal('cleanup-refused-other-lease', lease=identifier)
            return
        released = subprocess.run(cell('release', '--cell', 'alpha', '--lease-id', identifier), env=ENV,
                                  capture_output=True, text=True, timeout=25)
        if released.returncode:
            journal('cleanup-release-failed', error=released.stderr)
            return
    extension_log = RESULTS / 'setup-extension.log'
    if extension_log.exists() and 'existed=false' in extension_log.read_text():
        acquired = subprocess.run(cell('lease', '--cell', 'alpha', '--purpose', 'Plan 54 extension cleanup',
                                       '--ttl', '120', '--json'), env=ENV, capture_output=True, text=True, timeout=25)
        if acquired.returncode == 0:
            identifier = json.loads(acquired.stdout)['leaseId']
            try:
                removed = subprocess.run(cell('debug', '--cell', 'alpha', 'ssh', 'postgres', '--', 'sudo', '-n', '-u', 'postgres',
                                             'psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-d', 'template1', '-c',
                                             'DROP EXTENSION IF EXISTS pg_stat_statements'), env=ENV, capture_output=True, text=True, timeout=45)
                save('cleanup-extension.json', dict(exit_code=removed.returncode, stdout=removed.stdout, stderr=removed.stderr))
            finally:
                subprocess.run(cell('release', '--cell', 'alpha', '--lease-id', identifier), env=ENV, timeout=25)
    result = subprocess.run(['gcloud', 'compute', 'instances', 'stop',
                             'cell-alpha-postgres', 'cell-alpha-driver-0',
                             'cell-alpha-monitoring', 'cell-alpha-broker',
                             '--project=tan-nb-exp', '--zone=us-west1-a', '--quiet'],
                            env=ENV, capture_output=True, text=True, timeout=150)
    save('cleanup-power-command.json', dict(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr))
    inspected = subprocess.run(cell('status', '--cell', 'alpha', '--json'), env=ENV, capture_output=True, text=True, timeout=25)
    if inspected.returncode == 0:
        save('cleanup-status-after.json', json.loads(inspected.stdout))
    power = subprocess.run(['gcloud', 'compute', 'instances', 'list', '--project=tan-nb-exp', '--filter=name~^cell-alpha-',
                            '--format=json(name,status)'], env=ENV, capture_output=True, text=True, timeout=25)
    if power.returncode == 0:
        save('cleanup-power-after.json', json.loads(power.stdout))
    journal('cleanup-finished')


def main():
    global OPERATOR
    parser = argparse.ArgumentParser()
    parser.add_argument('--operator', required=True)
    parser.add_argument('--stage', choices=['prepare', 'measure', 'all'], required=True)
    args = parser.parse_args()
    OPERATOR = args.operator
    try:
        if args.stage in ['prepare', 'all']:
            status('initial-status')
            for cohort in ['head', 'released']:
                if (RESULTS / f'{cohort}-payload.json').exists():
                    command(cell('payload', 'show', RESULTS / f'{cohort}-payload.json'), f'verify-published-{cohort}')
                    continue
                command(cell('payload', 'publish', '--cohort', cohort, '--root', str(ROOT / 'bench/ep54-cell'),
                             '--out', RESULTS / f'{cohort}-payload.json', '--allow-dirty'),
                        f'publish-{cohort}', minimum=300)
            power = subprocess.run(['gcloud', 'compute', 'instances', 'list', '--project=tan-nb-exp', '--filter=name~^cell-alpha-', '--format=json(name,status)'], env=ENV, capture_output=True, text=True, check=True, timeout=20)
            machines = json.loads(power.stdout)
            if len(machines) != 4 or any(row['status'] != 'TERMINATED' for row in machines):
                raise RuntimeError('expected all four alpha instances stopped before taking ownership')
            save('owned-cell.json', dict(cell='alpha', initial_power=machines))
            lease = json.loads(command(cell('lease', '--cell', 'alpha', '--purpose', 'Plan 54 Kenshou setup',
                                            '--ttl', '300', '--start', '--json'), 'setup-acquire', minimum=180).splitlines()[-1])
            save('setup-lease.json', lease)
            save('owned-cell.json', dict(cell='alpha', started_from='all stopped and no lease'))
            command(cell('debug', '--cell', 'alpha', 'ssh', 'postgres', '--', 'sudo', '-n', '-u', 'postgres',
                         'psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-d', 'template1', '-c',
                         "SELECT 'existed=' || EXISTS(SELECT FROM pg_extension WHERE extname='pg_stat_statements'); CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public"), 'setup-extension', minimum=120)
            command(cell('release', '--cell', 'alpha', '--lease-id', lease['leaseId']), 'setup-release')
            command(cell('probe', '--cell', 'alpha', '--payload', RESULTS / 'head-payload.json'),
                    'proof', minimum=180, monitor=True)
            status('proof-released-status')
            save('proof-completed.json', dict(verified=True, lease_released=True))
        if args.stage in ['measure', 'all']:
            if not (RESULTS / 'proof-completed.json').exists():
                raise RuntimeError('verify submission and lease-release proof before expansion')
            if remaining() < 20 * 80 + 180:
                raise RuntimeError('20 paired trials do not fit remaining budget with reset allowance')
            for mode in ['disabled', 'active']:
                command([OPERATOR, 'plan', '--all', '--select', 'kiroku/append/benchmark/category-namespace',
                         '--placement', 'cell', '--seed', '7', '--dim', 'pg.durability=durable',
                         '--dim', 'pg.version=18', '--set', f'ep54.mode={mode}', '--out', RESULTS / f'{mode}.plan.json'], f'plan-{mode}')
                command(cell('pair', '--cell', 'alpha', '--start', '--baseline', RESULTS / 'released-payload.json',
                             '--candidate', RESULTS / 'head-payload.json', '--plan', RESULTS / f'{mode}.plan.json',
                             '--policy', 'bench/mp12-cell/policy.json', '--pairs', '5', '--max-replacements', '0',
                             '--pg-setting', 'shared_buffers=128MB', '--pg-setting', 'fsync=on',
                             '--pg-setting', 'synchronous_commit=on', '--pg-setting', 'full_page_writes=on',
                             '--out', RESULTS / mode), f'pair-{mode}', minimum=800, accepted=(0, 1, 3), monitor=True)
                status(f'{mode}-released-status')
                comparison = json.loads((RESULTS / mode / 'comparison.json').read_text())
                if str(comparison.get('verdict', '')).lower() == 'regression':
                    raise RuntimeError('consistent adverse comparison; stop before adding cases')
    finally:
        cleanup()


if __name__ == '__main__':
    main()
