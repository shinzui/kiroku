"""Verify retained final runs without rerunning benchmarks or changing raw evidence."""
import csv
import json
import math
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
journal = [json.loads(line) for line in (ROOT / 'journal.jsonl').read_text().splitlines()]
records = {r['label']: r for r in journal}
summaries = []
for index in range(1, 4):
    label = f'full-batched-{index}'
    record = records[label]
    assert record['exit_code'] == record['command_exit_code'] == 0, label
    rows = list(csv.DictReader((ROOT / (label + '.csv')).open()))
    assert len(rows) == 17, label
    cells = {r['Name']: r for r in rows}
    assert len(cells) == 17, label
    for row in rows:
        mean, spread = float(row['Mean (ps)']), float(row['2*Stdev (ps)'])
        assert math.isfinite(mean) and mean > 0 and math.isfinite(spread) and spread >= 0
        if '.warm-' not in row['Name']:
            assert spread <= .2 * mean, (label, row['Name'])
    ratios = {}
    def ratio(name, control, candidate, floor, ceiling):
        value = float(cells[candidate]['Mean (ps)']) / float(cells[control]['Mean (ps)'])
        assert floor <= value <= ceiling, (label, name, value)
        ratios[name] = value
    prefix = 'All.append-accepted-category.'
    ratio('accepted_append', prefix + 'accepted-control-append-40x32', prefix + 'candidate-append-40x32', .5, 1.05)
    for size in (4, 8):
        prefix = 'All.append-multi-stream.'
        ratio(f'pipeline_{size}', prefix + f'sequential-control-{size}', prefix + f'production-pipeline-{size}', .5, .9)
    for case, ceiling in [('exhausted-category', 1.05), ('page-200-streams-from-0', 1.05), ('page-20000-streams-from-0', 1.05), ('plain-caught-up-20000-streams', .2), ('group-caught-up-20000-streams', .2)]:
        prefix = 'All.category-read.'
        ratio(case, prefix + 'control-' + case, prefix + 'candidate-' + case, 0, ceiling)
    summaries.append({'label': label, 'ratios': ratios, 'max_doubled_spread_percent': max(100 * float(r['2*Stdev (ps)']) / float(r['Mean (ps)']) for r in rows if '.warm-' not in r['Name']), 'elapsed_seconds': record['elapsed_seconds'], 'inputs': record['inputs']})
assert all(r['inputs'] == summaries[0]['inputs'] for r in summaries), 'Final full runs must have identical inputs'
assert records['full-batched-3']['command'][-1] == 'perf-check'
(ROOT / 'full-summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
print(json.dumps(summaries, indent=2))
