# MP13 matched index comparison

This payload reuses the MP12 workload and Kenshou executor. Both arms use the
same current Kiroku source and executable. Only `mp13.index-layout` varies:
`category-only` preserves the current schema; `category-name` replaces the
category index with `(category, stream_name)` inside an empty isolated run DB.
The workload refuses populated stores. No production migration is installed.

`bench/mp12-cell/src/IndexResearch.hs` supplies the optional research path;
`unchanged` is the default and preserves the ordinary MP12 fixture/workload.
The extended scenario is revision 4. The separate flake/cohort here pins the
current runtime packages, rather than using the historical MP12 control.
The recorded source revision predates only benchmark/documentation changes;
verify package directories against it before publication.

Fixtures contain 20,000 deterministic valid UUIDv7 TypeID names in each of
`probe` and `noise`, plus four writer streams. Fresh warmup and measurement
names are deterministic and disjoint. Empty catalog streams are metadata-only
fixtures, seeded before measurement. Four appenders share a ten-connection pool,
512-character JSON body and `-N4 -T -A32m`. Index definitions, sizes, stream
insert/update/HOT/new-page counters, append-statement execution/WAL snapshots,
full latency samples and exact delivery/durable drain checks are retained.
Stream statistics are flushed across the pool before the measurement boundary
and after drain. Snapshot queries are outside the append measurement window.

The selected two cases are:

| Case | Appends | Observer load |
| --- | --- | --- |
| `fresh` | New TypeID streams, one event per append | None |
| `existing-category-browse` | Reuse four streams, one event per append | One category subscriber; one browse cycle/sec, each with first/late/absent pages |

Both use unpaced capacity with the existing bounded subscriber backpressure.
The second case measures combined shared work; it does not separate browse
savings from bare write overhead. No group/adapter/version/pool matrix is added.
General prefix and plan 54 namespace access remain unresolved.

## Protocol and runtime bound

Before remote execution, freeze the payload, controller, source/cohort and policy
hashes in the owned output directory. `run.py` uses the existing MP12 zero-regression
policy unchanged: five pairs, 95% intervals, 10,000 bootstrap iterations, maximum
relative interval width 6%, full benchmark-grade samples and zero allowed slowdown.
This is a focused index comparison, not the old optional MP12 precision matrix.
Wide intervals remain inconclusive; no automatic repeats or favorable replacements.

Start with one category-only proof run, verify sealed result hashes, input/output
invariants and lease release, then one identical calibration run. This small
calibration describes observed control variability; it does not certify statistical
measurement resolution. Continue with five AB/BA pairs per case, fresh first.
Each trial declares 10s warmup / 61s measurement / 10s drain; the existing durable
waits are bounded at 30s and a trial has a 180s executor timeout. Drains may finish
earlier than their declared allowance. Twenty-two trials have 29.7 minutes of
phase allowances. Allow about 11 minutes for reset/setup (30s/trial), 10 minutes
for build/publication and 5 minutes for first submission/recomputation/cleanup:
about 56 minutes total, conditional on actual preparation overhead. One persisted
60-minute wall-clock deadline covers all stages, including build and recovery.
The controller requires 150s/trial plus cleanup reserve before each new queue.
If measured overhead or remaining time cannot fit, it stops without shrinking
pair count or relaxing acceptance. Do not reset `budget.json` to resume.

The controller requires Python 3.14 or later for UUIDv7 plan/run IDs. It journals
immutable plans and operator sessions. Every 30 seconds
it checks the current remote run phase, actual driver/database power state and
verified slice count. It stops on five minutes without phase/count progress,
active stopped instances, health/hash/invariant failures, deadline exhaustion or
a confirmed write regression. It interrupts only its owned operator and releases
its owned lease on exit. Reuse the saved session for recovery; never overwrite
or silently replace failed trials. Inspect `remote-progress.jsonl`, individual
session journals, `verified.json`, comparisons and lease-release records for status.
Functional completion is separate from comparison acceptance.

## Build and run

Use the operator from `mori://shinzui/keiro-runtime-kenshou` at
`7a451b5f5f4b51986e872879a3bfe10f5943af6b` or later. Its project-relative guide
is `docs/guides/running-on-gcp.md` (artifact-level URI pending).

```bash
nix build ./bench/mp13-index#packages.x86_64-linux.kenshou-head --no-link
kenshou cell payload publish --cohort head --root ./bench/mp13-index \
  --out /tmp/mp13-index.payload.json
python3 bench/mp13-index/run.py --operator kenshou \
  --payload /tmp/mp13-index.payload.json --root /tmp/mp13-index-experiment
```

Create `budget.json` when starting build/preparation with `started_epoch` (UTC Unix
seconds) and `budget_seconds: 3600`; otherwise the controller creates it at its
own entry point. Do not omit earlier build/publication time from the experiment.
Publish only from a clean committed checkout. Validate that the cohort source
matches production packages and that `pg_stat_statements` exists in the cell's
cloned database before queue expansion.

The operator's `cell pair` shortcut varies payloads only. This controller submits
an explicit same-payload paired plan and recomputes the comparison with
`--vary knob:mp13.index-layout`. Every other compatibility input must match.
The single-trial lifecycle proof runs before any larger queue. All completed
slices are sealed/hash-verified, then summaries are recomputed from retained raw
samples before comparison. A partial session preserves every completed sample
and remains incomplete until the journal and results establish otherwise.

## 2026-10-10 execution checkpoint

The first controller plan was rejected because it generated UUIDv4 IDs; no
benchmark work ran. IDs now use UUIDv7 and the identifier/matched-plan tests
pass. The rejected plan/logs and source-hash recovery record are retained.
Publication first failed because `zstd` was absent; the established pinned
Nix shell supplied it. Both recoveries preserved the original deadline.

The corrected proof and second category-only control are sealed/hash-verified
and durably complete, and owned lease release is verified. The proof measured
41,830 fresh stream inserts and 41,830 stream updates, of which 41,280 were HOT.
These are control instrumentation checks, not replacement cost. Proof/calibration
journals took 151.7s / 132.2s, exposing reset/submission overhead beyond the
initial 30s/trial allowance. Before second-case submission, coverage was
explicitly revised to five fresh pairs and three active-observer diagnostic
pairs. The unchanged policy still requires five pairs for acceptance. The
second comparison therefore remains inconclusive for acceptance; no slowdown
allowance, phase change, favorable replacement or new budget is introduced.
`protocol-revision-coverage.json` supersedes the original target pair count
for that case and binds its unsubmitted plan hash. The paired queue completed.
Fresh acceptance is inconclusive; observer evidence
is exploratory because the low-rate browser did not meet the per-operation
sample minimum. The controller now checks grade during progress audits before
allowing continued queue execution. No measured payload or policy was changed.
All 18 samples, failed setup/grade checks and diagnostic recomputation are
retained in [the completed report](evidence/2026-10-10/README.md). The owned
lease is released and all four cell instances are stopped. No production
promotion is accepted.
