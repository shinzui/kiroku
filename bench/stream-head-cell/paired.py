"""Fixed schedules and paired block-bootstrap analysis for the EP-97 gate."""
import csv
import json
import math
import random
from collections import defaultdict
from pathlib import Path

CASES = ('legacy-100', 'legacy-100000', 'aa-100', 'aa-100000', 'positive-20pct')
ROUNDS = 40
CALLS = 1000
RESAMPLES = 20000


def schedule(seed, rounds=ROUNDS):
    if rounds <= 0 or rounds % 2:
        raise ValueError('an even positive round count is required')
    rng = random.Random(seed)
    orders = {}
    for case in CASES:
        orders[case] = ['ABBA', 'BAAB'] * (rounds // 2)
        rng.shuffle(orders[case])
    result = []
    for round_id in range(rounds):
        cases = list(CASES)
        rng.shuffle(cases)
        result.extend((round_id, case, orders[case][round_id]) for case in cases)
    return result


def quantile(values, p):
    position = (len(values) - 1) * p
    low = math.floor(position)
    high = math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def ratio(pairs):
    return sum(b for a, b in pairs) / sum(a for a, b in pairs)


def interval(pairs, block_length, seed):
    # Resample adjacent rounds together to retain short-range time dependence.
    # Circular blocks avoid giving the observations at the ends lower weight.
    count = len(pairs)
    if count % block_length:
        raise ValueError('block length must divide the round count')
    blocks = [(
        sum(pairs[(start + k) % count][0] for k in range(block_length)),
        sum(pairs[(start + k) % count][1] for k in range(block_length)),
    ) for start in range(count)]
    rng = random.Random(seed)
    estimates = []
    for _ in range(RESAMPLES):
        chosen = [blocks[rng.randrange(count)] for _ in range(count // block_length)]
        estimates.append(ratio(chosen))
    estimates.sort()
    return [quantile(estimates, .005), quantile(estimates, .995)]


def analyze(path, seed, rounds=ROUNDS, calls=CALLS, proof=False):
    with Path(path).open() as handle:
        rows = list(csv.DictReader(handle))
    expected = [(r, c, order, slot, arm)
                for r, c, order in schedule(seed, rounds)
                for slot, arm in enumerate(order)]
    if len(rows) != len(expected):
        raise ValueError(f'incomplete rows: {len(rows)} versus {len(expected)}')
    grouped = defaultdict(lambda: defaultdict(list))
    end_previous = 0
    for row, identity in zip(rows, expected):
        r, case, order, slot, arm = identity
        actual = (int(row['round']), row['case'], row['order'], int(row['slot']), row['arm'])
        if actual != identity:
            raise ValueError('sample order differs from predeclared schedule')
        count = calls * 6 // 5 if case == 'positive-20pct' and arm == 'B' else calls
        start, end, duration = (int(row[k]) for k in ('start_ns', 'end_ns', 'duration_ns'))
        if int(row['calls']) != count or start < end_previous or end - start != duration or duration <= 0:
            raise ValueError('invalid count, monotonic timestamp or duration')
        end_previous = end
        grouped[case][r].append((arm, duration, order))
    if proof:
        return dict(schema='ep97.paired-analysis/v1', status='proof-valid', rows=len(rows), seed=seed)
    if rounds != ROUNDS or calls != CALLS:
        raise ValueError('release evidence requires the fixed protocol')
    results = []
    for index, case in enumerate(CASES):
        pairs, by_order = [], defaultdict(list)
        for r in range(rounds):
            values = grouped[case][r]
            pair = tuple(sum(d for arm, d, _ in values if arm == label) for label in 'AB')
            pairs.append(pair)
            by_order[values[0][2]].append(pair)
        point = ratio(pairs)
        intervals = [interval(pairs, length, seed + index) for length in (5, 10)]
        low = min(ci[0] for ci in intervals)
        high = max(ci[1] for ci in intervals)
        relative_half_width = (high - low) / (2 * point)
        order_ratios = {order: ratio(items) for order, items in by_order.items()}
        half_ratios = [ratio(pairs[:rounds // 2]), ratio(pairs[rounds // 2:])]
        stable_order = .95 <= order_ratios['ABBA'] / order_ratios['BAAB'] <= 1.05
        stable_halves = .95 <= half_ratios[0] / half_ratios[1] <= 1.05
        precise = relative_half_width <= .03
        if case.startswith('legacy'):
            within_limit = high <= 1.10
        elif case.startswith('aa'):
            within_limit = low >= .95 and high <= 1.05
        else:
            within_limit = low > 1.10 and high < 1.30
        results.append(dict(case=case, ratio=point, ci99=[low, high],
                            block_intervals=dict(zip(('5', '10'), intervals)),
                            relative_half_width=relative_half_width,
                            order_ratios=order_ratios, half_ratios=half_ratios,
                            stable_order=stable_order, stable_halves=stable_halves,
                            precise=precise, within_limit=within_limit,
                            passed=precise and stable_order and stable_halves and within_limit,
                            mean_a_us=sum(a for a, b in pairs)/(rounds*2*calls*1000),
                            mean_b_us=sum(b for a, b in pairs)/(rounds*2*calls*1000)))
    controls = all(x['passed'] for x in results if not x['case'].startswith('legacy'))
    accepted = controls and all(x['passed'] for x in results)
    clear_regression = controls and any(x['ci99'][0] > 1.10 for x in results if x['case'].startswith('legacy'))
    return dict(schema='ep97.paired-analysis/v1', seed=seed, rounds=rounds, calls=calls,
                rows=len(rows), resamples=RESAMPLES, block_lengths=[5,10], confidence=.99,
                status='passed' if accepted else ('regression' if clear_regression else 'inconclusive'),
                controls_passed=controls, cases=results)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('samples', type=Path)
    parser.add_argument('--seed', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = analyze(args.samples, args.seed)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    raise SystemExit(0 if result['status'] == 'passed' else 3)
