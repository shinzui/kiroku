# Category/name replacement: matched write experiment, 2026-10-10

The replacement is a default-opclass B-tree on `(category, stream_name)` in
place of `ix_streams_category(category)`. Both arms use one immutable executable
and the current Kiroku runtime source. The layout changes only inside empty,
isolated run databases. No production migration or browse API is installed.

## Scope and frozen protocol

PostgreSQL 18.3, durable settings (`fsync`, synchronous commit and full-page writes
on), 128 MiB shared buffers, four writers, ten pooled connections, one event with a 512-character
JSON body per append, RTS `-N4 -T -A32m`, and 20,000 empty TypeID catalog streams
in each of two categories. Phases are 10s warmup / 61s measurement / 10s drain
allowance, with bounded durable waits. Runs use unpaced capacity and the existing
bounded subscription backpressure. The source/cohort, payload, policy and controller
hashes are retained in `protocol/`.

The fresh case has five adjacent interleaved AB/BA pairs, without observers.
The existing-stream case reuses four streams with one category subscriber and
one browse cycle/sec (first, late and absent category pages, LIMIT 11). It measures
combined shared work, not a separate bare-existing-write cost.

One persisted 60-minute deadline includes Linux build, publication, setup,
calibration, recovery, measurements, recomputation and cleanup. The two baseline
controls took 151.7s and 132.2s including reset/submission overhead, beyond the
initial allowance. Before submitting the second case, its queue was explicitly
reduced to three diagnostic pairs. `protocol/protocol-revision-coverage.json`
binds that plan and explains the revision. The unchanged policy requires five
pairs, 95% intervals, 10,000 bootstrap iterations, a maximum 6% relative interval
width and zero allowed slowdown. The second case cannot pass acceptance with
three pairs. Controls describe variability and prove lifecycle/instrumentation;
they do not certify measurement resolution. Failed or interrupted samples are
never silently replaced.

The first plan used UUIDv4 and was rejected before benchmark execution; retained
logs show the failure and recovery to UUIDv7. Publication initially lacked `zstd`
and succeeded through the pinned shell. Both recoveries kept the original clock.

## Fresh-stream results

All ten trials are sealed/hash-verified, benchmark-grade and durably drained.
The original policy verdict is **inconclusive** for every append metric.
Changes below are candidate relative to baseline; negative throughput means less
capacity, and positive latency means slower appends. Intervals are the retained
Kenshou paired bootstrap/Student-t envelope, not intervals over individual events.

| Metric | Estimate | 95% interval | Policy |
| --- | ---: | ---: | --- |
| Append throughput | -0.677% | -2.687% to +1.374% | Inconclusive |
| Append p50 | +0.657% | -1.311% to +2.664% | Inconclusive |
| Append p95 | +0.828% | -1.976% to +3.712% | Inconclusive |
| Append p99 | +1.718% | -1.703% to +5.258% | Inconclusive |

This is a small observed throughput effect with unresolved sign. It establishes
neither zero cost nor an accepted regression allowance.

Across the five trials per arm, global WAL/event was 2,136.25 bytes baseline and
2,188.18 bytes candidate: **+2.43%**, a descriptive aggregate without a policy
confidence interval. Stream HOT fractions were 98.703% / 98.698%. The baseline
created 212,755 measured streams; the candidate created 211,302. Each fresh append
also updates `$all`, so the index is not outside the event-creation write path.

At setup, with 40,001 streams, the incrementally populated category index was
286,720 bytes and the replacement 3,874,816 bytes (13.51x); all stream indexes
together were 4,538,368 / 8,126,464 bytes (+79.06%). This differs from the earlier
compact index-layout experiment (9.28x / +53.7%) because this workload creates
the index before inserting its fixture. Neither footprint ratio is a write-cost
percentage.

## Subscription and browsing results

All six trials completed and sealed, with artifact hashes, stream counters,
exact delivery and durable drain checked. They are **exploratory**, not
benchmark-grade: the 1 Hz browser recorded 185–186 steady samples per trial,
below Kenshou's 1,000-sample minimum for each operation. The controller rejected
the grade after the queue; the original exception and all samples are retained.
That check should have run after the first observer slice. The controller now
checks grades during its progress audit, with a regression test for this failure.
The correction changes no measured payload, inputs, artifacts or policy.

Raw summaries were independently recomputed with `summarize --verify`; then all
three original pairs were compared with the unchanged policy, solely to retain
diagnostic numbers. The verdict is **inconclusive**, with reasons: fewer than
five pairs, evidence grade below benchmark, and a soft health observation.
No trial was rerun or replaced. `diagnostic-records.json.gz` explicitly retains
the rejected grade and distinguishes hash/invariant checks from acceptance.

| Diagnostic append metric | Estimate | 95% interval |
| --- | ---: | ---: |
| Throughput | +2.326% | -0.900% to +5.656% |
| p50 | -1.724% | -6.229% to +2.997% |
| p95 | -1.602% | -7.752% to +4.958% |
| p99 | +0.168% | -5.383% to +6.045% |

Pooled first/late/absent browse p50 fell 92.31%, p95 93.88% and mean 90.13%
(geometric mean of the three paired ratios). These are descriptive low-sample
estimates without an acceptance interval. Global WAL/event was 1,997.29 /
2,002.84 bytes (+0.28%); stream HOT fractions were 99.499% / 99.463%, with zero
measured stream inserts. The combined case does not isolate subscription query
latency, bare write overhead or browse savings.

## Interpretation and retained evidence

Existing category subscriptions read the separate unchanged `stream_events`
category/global-version access path. This replacement does not remove that
index; shared write, WAL, cache and pool effects can still affect subscriptions.
The combined observer case checks those effects with active browsing, rather
than asserting a direct subscription query rewrite.

Fixtures use valid deterministic UUIDv7 TypeID names. Fresh warmup and steady
sequences are disjoint and interleave across writers/phases; committed names are
not strictly monotonic. The result is evidence for this concrete workload, not
for every perfectly ordered insertion stream or arbitrary production inventory.
General literal-prefix and plan 54 namespace/global-event-order access remain
unresolved. ADR-15 still requires reviewing both features' physical design and
cumulative writer cost against the original control.

The operator source is `mori://shinzui/keiro-runtime-kenshou` at
`7a451b5f5f4b51986e872879a3bfe10f5943af6b`. Production source is
`1c6905f61dfd32e3e6838739a2ddfae8cb187def`; the published clean harness is
`06c70b39549e046c6ee8d341e9f3221a340459e0`, with the controller identifier
correction bound separately by the recovery record.

## Completion and files

All 18 planned trials (two controls, ten fresh, six observer) completed and
sealed. Fresh acceptance remains inconclusive; observer acceptance is also
inconclusive and its evidence grade exploratory. No production promotion is
claimed. The owned lease was released, and the idle cell was stopped through
`mori://shinzui/load-testing-infra`, project-relative `scripts/cell/stop.sh`
(artifact-level URI pending). Final power states and elapsed time are in
`protocol/experiment-completion.json`. The first stop command was refused by
project preflight; a process-local explicit project selected the correct cell.

`summary.json` contains derived percentages and counters; each comparison keeps
the policy, interval algorithm, paired inputs and reasons. Control/fresh records
are losslessly retained as `verified.json.gz`; observer records are named
`diagnostic-records.json.gz`. WAL/event is total measured WAL divided by measured
events; HOT fraction is summed HOT updates divided by summed stream updates.
Throughput changes invert Kenshou's adverse baseline/candidate ratio; latency
changes use candidate/baseline. `sealed-metadata.tar.gz` preserves original
outer/inner manifests, run specifications and results. Full raw latency samples
remain in sealed GCS prefixes recorded in each row's `rawPrefix`, with artifact
sizes/hashes in the manifests. `sha256.json` verifies retained artifact bytes.
Protocol files include setup failures, immutable plans, journals, progress,
lease receipts and the explicit exploratory recovery. ADR distillation found
no new selected architecture; ADR-15 already governs the unresolved design and
cumulative cost review.
