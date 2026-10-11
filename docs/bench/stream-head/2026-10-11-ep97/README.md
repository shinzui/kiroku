# Plan 97 implementation evidence

This directory retains the local PostgreSQL 18.6 / GHC 9.12.4 experiment for
[Plan 97](../../../plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md).
Baseline production source: `109d58f57dbd5757ad55792474d046a37cc2e87d`.
Frozen fixtures and full metadata interpreter: `25b0b8e`.
The candidate adds only the opt-in originated-head read. No migrations or legacy
statement, decoder, handler or StreamInfo changes are included.

The experiment started at the UTC timestamp in `started.txt`, with one 60-minute
budget covering baseline, compilation, setup, recovery, candidate and aggregate
gates. `stages.jsonl` records command durations and remaining budget. No remote
execution or new configuration matrix was used.

The fixture has 1,000 interleaved 100-event streams, one 100,000-event stream and
an empty stream: 200,000 events and 400,000 junctions. All arms share one migrated
database. Setup, ANALYZE and VACUUM run outside measurement. Each cell warms 100
calls, then measures batches of 100 public-runner calls. All six metadata fields
are forced by equality to the validated fixture metadata; heads are also checked.

The two legacy gates compare production metadata with the frozen effect handler,
pool error mapping, statement, decoder and runner. Their maximum ratio is 1.10.
Metadata-plus-head cells are diagnostic additional functionality. All timing uses
wall time, 5% relative standard deviation and 60 seconds per cell. Tasty's printed
and CSV uncertainty is **twice** standard deviation; divide it by twice the mean
to check the 5% target.

Baseline: 448 existing tests and 13 frozen statement/column checks passed.
Metadata ratios were 0.987 and 0.988; all four cells met the precision target.
`baseline-cost.log` is the failed pre-measurement attempt: Cabal changed directory,
so a relative CSV path did not exist. `baseline-cost-2.log` and `baseline.csv` are
the successful absolute-path retry (14.69 seconds measurement).

`functional.log` preserves a compile failure from an ambiguous Async `wait` name;
`functional-2.log` has 26 passing focused cases after qualification. `query-plans.json`
extracts its complete literal and warmed prepared EXPLAIN JSON. Both populated
sizes use seven execution shared buffers, empty six, missing two. Missing streams
execute the origin probe zero times. Natural prepared plans used generic parameters
after six executions. No planner settings were forced.

Candidate and aggregate results are recorded below when completed.

The user reported a very busy host before candidate timing. No automatic timing
retries will be run under this contention. Failed or noisy ratios will be retained
as inconclusive performance acceptance, with thresholds unchanged.
