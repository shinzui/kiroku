# Single-event append feasibility probes — 2026-10-25

The user asked whether single-event append could be made faster while keeping
the category-read benefit. Two focused probes found **no dependable small win**.
Production SQL, schema, publisher behavior and performance bounds are unchanged.
The optional benchmark variants remain as evidence against repeating blind
rewrites, not as promoted optimizations.

The investigation began at 14:27:10 UTC with one 60-minute wall-clock ceiling,
including inspection, profiling, builds and repeats. It reused the active-host
authorization, existing profiles, the experiment ledger and the fixed-work
diagnostic. Each invocation runs 12 alternating pairs of 32 workload iterations
per arm after the existing warm-up; each iteration is 20 fresh-stream plus 20
hot-stream single-event appends. Both arms retain migration 0012's category
index and CHECK. All six measured invocations verified equal iteration counts
and the expected final stream/event/junction/version counts.

## Combining the junction inserts

Production appends insert the event's home-stream row and `$all` row using two
separate data-modifying CTEs. The `paired-combined-links` prototype uses one
INSERT with UNION ALL, retaining the exact bind parameters, row values, category
index, CHECK and foreign keys. It keeps one database round trip. Its source
statement is derived from `Statement.toSql SQL.appendAnyVersion`; the frozen
pre-0012 control is untouched.

The existing ledger has already rejected scalar singleton statements, replacing
the event-count subqueries with a parameter, and a two-round-trip append path.
This probe tested a different, bounded question: whether eliminating one INSERT
executor could save a few microseconds without changing contracts. No new
promotion threshold was selected after seeing results.

`explain-combined-links` profiled the actual production/prototype SQL with
`EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING ON, FORMAT JSON)`. The warm hot-stream
production sample had a 7 µs `source_links` node and 15 µs `all_links` node;
whole-statement execution was 148 µs. Both foreign-key triggers still ran twice,
and the stream notification still ran once. These single instrumented samples
suggested only modest headroom and were not latency estimates. The prototype
passed the structural execution/count checks; its hot sample was 156 µs.
`profile-summary.json` and `explain-combined-links.log.gz` retain the profile.

| Run | Candidate/control | Descriptive interval | First-control / first-candidate |
| --- | --- | --- | --- |
| `combined-links` | 0.9639x (3.6% lower) | 0.9076–1.0238x | 0.9388 / 0.9897x |
| `combined-links-2` | 0.9971x (0.3% lower) | 0.9827–1.0116x | 1.0071 / 0.9871x |
| `combined-links-3` | 0.9951x (0.5% lower) | 0.9619–1.0294x | 1.0183 / 0.9724x |

The apparent initial improvement depended on large early control batches. The
unchanged repeats were essentially flat, with different results by arm order.
The rewrite has no demonstrated benefit that warrants a production path.

## Publisher work with no subscribers

The current publisher queries the authoritative `$all` tail on notification even
when its subscriber registry is empty. `paired-no-publisher` stops **only the
candidate's publisher worker** in this subscriber-free fixture; both arms retain
the production append SQL, notifier, database indexes, constraints and durability
settings. This measures a diagnostic upper bound on removing that background
work, not an implementation suitable for production.

| Run | Candidate/control | Descriptive interval | First-control / first-candidate |
| --- | --- | --- | --- |
| `no-publisher` | 0.9364x (6.4% lower) | 0.9114–0.9622x | 0.9373 / 0.9356x |
| `no-publisher-2` | 0.9689x (3.1% lower) | 0.9077–1.0342x | 0.9977 / 0.9409x |
| `no-publisher-3` | 0.9945x (0.6% lower) | 0.9725–1.0170x | 1.0000 / 0.9890x |

The second run retains a large candidate spike; the third has little difference.
There may be background-work headroom, but these results do not establish a
repeatable latency gain. A genuine optimization could investigate coalescing or
deferring idle bookkeeping while preserving subscription startup and catch-up.
Simply disabling the worker would violate the existing idle cursor advancement
behavior tested in `kiroku-store/test/Test/PublisherIdleAdvance.hs` and is not a
valid shipping fix.

## Interpretation and reproduction

All intervals use mean log-ratio ± t(11) × standard error, exponentiated; they
are descriptive summaries of consecutive pairs, not calibrated population
confidence limits. No samples were clipped, no favorable retry replaced a
sample, and no results were pooled or used to relax the original gate. The
three repeats per variant satisfy the existing discipline of observing an
unchanged noisy candidate before changing its workload or threshold.

The practical finding is that there is no proven small SQL tweak here that
recovers the measured category-write cost. Keeping the category index remains
compatible with future focused optimization. For callers that unnecessarily
wrap an isolated append in an explicit transaction, the existing `appendToStream`
API already avoids extra BEGIN/COMMIT round trips; callers needing an atomic
projection write must retain their transaction.

Run one variant from the repository root:

```bash
nix develop --no-write-lock-file -c env KIROKU_GATE_DIAGNOSE=paired-combined-links \
  cabal bench kiroku-store:kiroku-store-bench-workload-gate
```

Use `paired-no-publisher` for the upper-bound probe and
`explain-combined-links` for instrumented plans. Zero exit status means the
diagnostic and count checks completed, not a performance pass. Unset the
variable for the unchanged authoritative gate.

`journal.jsonl` records the exact commands, loads, times and exit codes. The
paired logs/CSVs retain every sample. Recompute summaries with:

```bash
python3 kiroku-store/bench/results/plan99-append-probe/summarize.py \
  combined-links combined-links-2 combined-links-3 \
  no-publisher no-publisher-2 no-publisher-3
```
