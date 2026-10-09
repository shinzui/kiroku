#!/usr/bin/env python3
"""Fail closed unless every frozen ADR-11 matrix cell has accepted evidence."""
import argparse
import importlib.util
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('matrix', HERE / 'run-matrix.py')
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


def verify(root):
    frozen = matrix.read(root / 'frozen-loads.json')
    if frozen['matrixSha256'] != matrix.digest(HERE / 'matrix.json'):
        raise ValueError('matrix specification differs from the measured matrix')
    if frozen['productionSha256'] != matrix.production_fingerprint():
        raise ValueError('production source differs from the measured candidate')
    expected = matrix.SPEC['configurations']
    if [case['configuration'] for case in frozen['cases']] != expected:
        raise ValueError('missing, reordered or substituted workload configurations')
    count = 0
    for case in frozen['cases']:
        config = case['configuration']
        for profile in matrix.SPEC['profiles']:
            name = config['id'] + '-' + profile
            for stage, calibrate in [('calibration', True), ('comparison', False)]:
                directory = root / stage / name
                accepted = matrix.read(directory / 'accepted.json')
                seconds = accepted['seconds']
                tag = matrix.trial_tag(seconds, accepted['pairs'])
                output = directory / tag
                recalculated = matrix.resolution(output / 'comparison.json', calibrate, profile)
                if recalculated['status'] != 'pass' or recalculated != accepted['resolution']:
                    raise ValueError(f'{stage}/{name}: unresolved or altered comparison')
                if accepted['configuration'] != config or accepted['profile'] != profile:
                    raise ValueError('accepted result names the wrong configuration')
                offered = 0 if profile == 'capacity' else case[profile + 'Offered']
                if accepted['offered'] != offered or seconds < 60:
                    raise ValueError('offered load or steady window differs from the contract')
                if not calibrate:
                    calibrated = matrix.checked_calibration(root, name, profile, matrix.digest(root / 'frozen-loads.json'))
                    if seconds != calibrated['seconds'] or accepted['pairs'] != calibrated['pairs']:
                        raise ValueError('candidate window or pair count differs from calibration')
                if offered and seconds * offered < matrix.SPEC['minimumFixedLoadCalls']:
                    raise ValueError('too few fixed-load arrivals for tail measurement')
                if accepted['frozenLoadsSha256'] != matrix.digest(root / 'frozen-loads.json'):
                    raise ValueError('offered loads were changed after calibration')
                if accepted['planSha256'] != matrix.digest(directory / f'{tag}.plan.json'):
                    raise ValueError('submitted plan was changed')
                # Re-read raw operator-verified trees and sealed hashes, rather
                # than trusting a hand-edited acceptance flag or copied report.
                trials = [trial for session in sorted(output.glob('round-*/session.json'))
                          for trial in matrix.collect(session)]
                if trials != accepted['trials']:
                    raise ValueError('raw evidence differs from accepted report')
                if accepted['pairs'] < matrix.SPEC['minimumPairs'] or len(trials) < 2 * accepted['pairs'] or accepted['comparison']['pairCount'] != accepted['pairs']:
                    raise ValueError('fewer than five paired trials')
                payloads = accepted['payloads']
                if payloads['baseline'] != frozen['control']:
                    raise ValueError('original control payload was replaced')
                if payloads['candidate']['harness'] != frozen['control']['harness'] or payloads['candidate']['harness']['dirty']:
                    raise ValueError('harnesses differ or the source was dirty')
                if calibrate and payloads['candidate'] != frozen['control']:
                    raise ValueError('calibration did not compare the original control to itself')
                if not calibrate and payloads['candidate']['cohort'] != 'head':
                    raise ValueError('candidate comparison did not use the candidate implementation')
                for trial in trials:
                    arm = trial['comparison']['arm']
                    payload = payloads[arm]
                    if trial['fingerprint']['cell']['payload']['bundleSha256'] != payload['cell']['bundle']['sha256']:
                        raise ValueError('trial used a different compiled payload')
                    if trial['cohort'] != payload['cohortIdentity']:
                        raise ValueError('runtime cohort differs from its compiled identity')
                    probe = trial['writeProbe']
                    workload = probe['workload']
                    actual = (workload['mode'], workload['width'], workload['fresh'],
                              workload['append_batch'], workload['checkpoint_batch'])
                    wanted = (config['mode'], config['width'], config['fresh'],
                              config['appendBatch'], config['checkpointBatch'])
                    if actual != wanted or workload['offered'] != offered or workload['seconds'] != seconds:
                        raise ValueError('compiled workload differs from the frozen plan')
                    fixtures = [f'probe-{writer}-{slot}' + (f'-{2 * iteration + phase}' if config['fresh'] else '')
                                for phase in [0, 1] for writer in range(4)
                                for slot in range(config['width']) for iteration in [0, 1]]
                    if probe['fixture_preview'] != fixtures:
                        raise ValueError('fresh-stream fixtures differ from the deterministic specification')
                    if trial['fingerprint']['postgres']['serverVersionNum'] // 10000 != 18:
                        raise ValueError('matrix requires PostgreSQL 18')
                    consuming = config['mode'] not in ('none', 'idle')
                    if probe['delivered'] != (probe['events'] if consuming else 0):
                        raise ValueError('subscriber delivered a different amount of work')
                    if not consuming and probe['checkpoint_updates'] != 0:
                        raise ValueError('inactive subscriptions saved checkpoints')
                    if offered and probe['calls'] != offered * seconds:
                        raise ValueError('a fixed-load arrival was dropped')
            count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.root)
    except (ValueError, KeyError, OSError) as error:
        print(f'ADR-11 matrix is unfinished: {error}', file=sys.stderr)
        return 2
    print(f'ADR-11 matrix: all {count} PostgreSQL 18 cells pass calibration, raw evidence and zero-regression checks')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
