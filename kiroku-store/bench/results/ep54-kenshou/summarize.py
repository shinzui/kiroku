"""Summarize verified Kenshou evidence without changing fetched artifacts."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / 'v2'


def percentile(values, fraction):
    return sorted(values)[min(len(values) - 1, int(fraction * (len(values) - 1)))] if values else None


def statement_delta(before, after):
    prior = {row['query']: row for row in before}
    result = []
    for row in after:
        query = row['query']
        if not any(fragment in query for fragment in ['WITH scanned AS MATERIALIZED', 'INSERT INTO subscriptions (', 'SELECT stream_version FROM stream_events WHERE stream_id =']):
            continue
        old = prior.get(query, {})
        result.append(dict(query=query, **{field: row[field] - old.get(field, 0) for field in ['calls', 'rows', 'shared_blks_hit', 'shared_blks_read', 'wal_bytes']}))
    return result


def summarize():
    trials = []
    for case in ['disabled', 'active']:
        base = RESULTS / case
        journal_path = base / 'round-0/session.json'
        if not journal_path.exists():
            continue
        journal = json.loads(journal_path.read_text())
        for row in journal['slices']:
            if row['state'] != 'verified':
                continue
            for identifier in row['runIds']:
                directory = base / row['cellRun'] / 'tree/output' / identifier
                run = json.loads((directory / 'run-result.json').read_text())
                measurements = run['summaries']['measurements']
                measured = measurements.get('measurements', {})
                probe = measurements.get('namespace-comparison', {})
                namespace = probe.get('namespace') or {}
                observer = probe.get('observer') or {}
                reset = json.loads((base / row['cellRun'] / 'tree/cell/reset-evidence.json').read_text())
                trials.append(dict(case=case, run_id=identifier, cell_run=row['cellRun'],
                    comparison=run['comparison'], outcome=run['outcome'], exit_code=run['exitCode'],
                    grade=measured.get('grade'), grade_reasons=measured.get('gradeReasons'),
                    metrics={key: value for key, value in measured.get('metrics', {}).items() if key.startswith('op.append.')},
                    arm=probe.get('arm'), total_appends=probe.get('total_appends'), measured_appends=probe.get('measured_appends'),
                    recorder_count=measured.get('ops', {}).get('append', {}).get('count'),
                    warmup_seconds=probe.get('warmup_seconds'), measurement_seconds=probe.get('measurement_seconds'),
                    observer_exact=observer.get('ordered_exact_delivery'), observer_events=observer.get('tail_events'),
                    distinct_source_streams=observer.get('source_streams_seen'), observer_p99_lag_us=observer.get('lag_p99_us'),
                    namespace_exact=namespace.get('exact_ordered_delivery'), namespace_matched=namespace.get('matched'),
                    namespace_catchup_us=namespace.get('catchup_us'),
                    namespace_logical_scanned_prefix=namespace.get('checkpoint'),
                    namespace_lag_p99_us=percentile(namespace.get('raw_lag_us', []), .99),
                    statement_deltas=statement_delta(probe.get('sql_before', []), probe.get('sql_after', [])),
                    reset_verified=reset['verified'], cache_policy=reset['cachePolicy'],
                    relative_result_path=str(directory.relative_to(ROOT))))
    comparisons = {}
    for case in ['disabled', 'active']:
        path = RESULTS / case / 'comparison.json'
        if path.exists():
            comparisons[case] = json.loads(path.read_text())
    summary = dict(schema='kiroku.ep54.kenshou-summary/v1', trials=trials, comparisons=comparisons,
                   limitations=['Namespace catch-up timing measures empty startup before producers begin, rather than historical replay throughput.',
                                'Scanned prefix is the safe logical checkpoint position; it is not a count of physical PostgreSQL tuple visits.',
                                'The three candidate proof trials are retained separately and excluded from paired comparison estimates.'])
    (ROOT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('verified trials', len(trials), 'by case', {case: sum(row['case'] == case for row in trials) for case in ['disabled', 'active']})
    for case, comparison in comparisons.items():
        print(case, comparison['verdict'], comparison['pairCount'], comparison['reasons'])
        for name, metric in comparison['metrics'].items():
            print(name, metric['ratio'], metric['status'])


if __name__ == '__main__':
    summarize()
