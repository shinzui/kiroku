# Plan 54: verified Kenshou comparison

Both original-control comparisons completed five valid interleaved pairs. Every
comparison trial has benchmark grade, passes its correctness checks, retains full
raw samples, and has no health warnings. The statistical zero-slowdown gate remains
inconclusive. After reviewing both comparisons and the interval limits, the user
explicitly chose “Accept practical performance; close Plan 54.” This new
cohort-specific practical acceptance closes M3; it does not relabel the statistical
verdicts, borrow the earlier cohort's acceptance or grant future slowdown allowance.
The exact decision is retained in `acceptance.json`.

| Case | Metric | Candidate change | 95% interval | Native status |
| --- | --- | ---: | --- | --- |
| disabled | throughput | -0.39% | -5.29% to +4.76% | inconclusive |
| disabled | latency.p50 | -0.44% | -5.24% to +4.61% | inconclusive |
| disabled | latency.p95 | +0.07% | -5.40% to +5.84% | inconclusive |
| disabled | latency.p99 | +1.53% | -5.59% to +9.18% | inconclusive |
| active | throughput | +0.80% | -3.57% to +5.38% | inconclusive |
| active | latency.p50 | +0.78% | -3.33% to +5.06% | inconclusive |
| active | latency.p95 | +0.77% | -5.91% to +7.93% | inconclusive |
| active | latency.p99 | +1.94% | -5.57% to +10.05% | inconclusive |

Positive throughput change is faster; positive latency change is slower. All
intervals and statuses above come directly from Kenshou. The policy requires five
pairs, 95% confidence, a maximum 6% relative interval width and a zero-slowdown
limit. No trial was discarded or replaced to improve the result.

## Scope and validity

The control is `364ffa82136fcfc83d39ead1234abffaf500844b`, the original
pre-inspection source. Candidate runtime is `94c2839f4b9a51bff2bfead57b8e587389a7875f`.
The measured Haskell/Cabal/Nix sources match harness commit `ad4e527`; the runtime
implementation is unchanged by subsequent benchmark/report edits. This is the
cumulative comparison required by ADR-15, including the inspection changes.

The matched toolchain uses GHC 9.12.4 and PostgreSQL 18.3 on alpha's separate
n2-standard-8 driver and database VMs, durable settings and 128 MB shared buffers.
Each trial receives a verified cold reset. Both arms run four closed-loop writers,
a 512-character body, mixed fresh/existing stream names, and one percent namespace
names. The active case adds a common exact-category worker, independent WebSocket
observer, REST polling and the candidate's namespace worker. The disabled case
omits those active readers. Both arms retain the same producer and observer code.

Comparison windows are 10 seconds warmup and 20 seconds measurement. The 30-second
candidate proof showed full trial times around 116 seconds including reset,
collection and verification, so the windows were shortened before the comparison
queue to fit both cases within the approved cumulative 90-minute budget. Pair
count, confidence, interval-width requirement and slowdown limit were unchanged.
The measured precision is insufficient to pass that policy.

All 20 comparison trials are verified. Recorder and independent append counts agree in every trial. All five active candidate runs have exact ordered namespace delivery, and all ten active observer runs have exact delivery. Candidate namespace matches: 1,580; per-trial logical scanned prefix: 29,787–31,764; per-trial p99 namespace lag: 8.24–9.52 ms.

SQL statement deltas, buffers, rows and subscription-save counts are retained in
`summary.json`. Subscription-save counts aggregate the category and namespace
workers because pg_stat_statements groups parameterized statements. Logical scan
prefix is safe durable progress, rather than a physical tuple-visit counter.
Namespace startup timing measures empty catch-up before the producers start;
historical replay throughput was not measured. Each group member still scans
global history independently. The separately retained correctness and 96 query-plan
cases establish bounded metadata/payload work and selective/coalesced wake/save
invariants; they are not a performance certificate.

## Recovery and retained evidence

The first wrapper's completed sample was rejected for a missing load-series window;
its next sample was cancelled when the queue stopped. Both remain retained,
including the fetched, verified cancellation manifest. Commit `ad4e527` supplies
complete load markers. Three active candidate proof trials then passed with
benchmark grade, exact namespace/observer delivery and matching append counts;
they are excluded from paired estimates. A one-pair proof request was rejected
before acquiring a lease because Kenshou requires at least three pairs; the
subsequent ordinary run-plan proof produced its default three candidate trials.
The original experiment deadline was extended by 30 minutes only after the user
explicitly chose a 90-minute total. All setup failures and recovery time remain
inside that same deadline.

Kenshou at `2129bb917da811ef1e90198d91db873cc8d05b7b` already supports the deployed
optional broker field. A narrow local operator registers this namespace scenario
and uses Kenshou's standard submission, reset, measurement, collection,
verification, lease and comparison paths. Both payload arms use the same
strict-mutable-base 1.1.0.0 compatibility pin, within Effectful 2.6.1.0's published
bound. FRIC-10 records this accepted assembly workaround; no dependency or
infrastructure checkout was changed.

All four owned VMs are stopped and the lease is absent. Total experiment time, including preparation and cleanup: 86.6 minutes of the user-approved 90-minute ceiling.

`evidence.tar.gz` retains the fetched trees, manifests, raw samples, run specs,
comparisons, journals, source identities, controllers, setup failures and cleanup
receipts. `evidence.sha256` verifies the archive. `summary.json` provides the
reviewable metric and workload index. The original implementation/correctness
and Yujin OS Login evidence remains in `../ep54-namespace/`.

The checked archive preserves the collected evidence before the acceptance decision.
The subsequent decision is stored separately in `acceptance.json`.
