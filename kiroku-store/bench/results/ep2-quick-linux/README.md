# EP2 quick Linux verification, 2026-10-09

The bounded experiment, including preparation and cleanup, took **25 minutes
30 seconds**. Five trials are verified, benchmark-grade and durably drained.
There are two complete alternating pairs and one unmatched control. The sixth
trial was stopped during reset: its minimum 91-second warmup/measurement could
not fit the remaining queue budget. It produced no timing sample. No replacement
trial, second workload, calibration or database-version matrix was run.

This supplies reliable recorded timings for the selected workload, but does
**not** establish performance equivalence or meet the intended approximately
10% uncertainty target. The paired intervals are wide. The unchanged Kenshou
policy requires five pairs; no strict acceptance report was produced because
the queue was interrupted. EP2's checkpoint-only cost was accepted by the user;
event-append acceptance remains unresolved. No package is released.

## Inputs and scope

- Operator: `mori://shinzui/keiro-runtime-kenshou`, existing native CLI at
  revision `7a451b5f5f4b51986e872879a3bfe10f5943af6b`.
- Infrastructure: `mori://shinzui/load-testing-infra`, cell alpha, PostgreSQL
  18.3, Linux x86_64. Durable settings: fsync, synchronous_commit and
  full_page_writes on, wal_level replica, shared_buffers 128MB.
- Control Kiroku source: `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0`.
  Candidate: `7bd37df3de809c04b323146a8c5a3d6bc1325023`, whose production
  source equals the optimized EP2 implementation at `6612523`. Harness source
  `f7ddbe18fdfa8d76a90242f1959ee51fd14c85e5`; clean source proof before publish.
  Both cohorts use GHC 9.12.4 and the same frozen harness. This is cumulative
  EP1+EP2 versus the original control, not an isolated EP2 comparison.
- One category group, four appenders and four members, existing streams,
  width 1, 512-character JSON payload, pool 10, capacity load, append batch 1,
  checkpoint batch 1, RTS `-N4 -T -A32m`.
- Three pairs planned in ABBA order; 30 seconds warmup, 61 seconds steady,
  30 seconds maximum drain, no replacements. Five trials completed, in
  control/candidate/candidate/control/control order.
- Build limit 600 seconds; publication limit 180 seconds; queue limit 900
  seconds including resets/fetches; one-hour whole-experiment deadline with
  cleanup reserved. Linux build took 224.38 seconds and publication 64.13
  seconds. The remote queue ran 841.34 seconds before interruption, followed
  by cleanup. Remaining time was not filled with extra work.

## Results

Reported changes are geometric means of the two matched candidate/control
ratios. Mean absolute values are arithmetic trial means of those same pairs.
The unmatched fifth control is retained but does not enter the paired estimate.

| Metric | Control mean | Candidate mean | Paired change | Descriptive 95% interval |
|---|---:|---:|---:|---:|
| Append throughput | 593.98 events/s | 593.28 events/s | -0.14% | -26.88% to +36.38% |
| Append p50 | 6.623 ms | 6.570 ms | -0.82% | -35.27% to +51.95% |
| Append p95 | 8.120 ms | 8.298 ms | +2.17% | -19.71% to +30.02% |
| Append p99 | 8.651 ms | 8.901 ms | +2.87% | -16.06% to +26.06% |
| WAL per append | 1936.85 bytes | 1938.25 bytes | +0.074% | -7.95% to +8.80% |
| Allocation per append | 188054.61 bytes | 196040.75 bytes | +4.24% | -12.02% to +23.51% |

Throughput changes by pair are -2.56% and +2.34%; p99 changes are +4.53%
and +1.24%. There is no consistent throughput slowdown in these two pairs.
Both tail estimates and allocation rise; these observations and their
uncertainty remain retained, without a claim of no regression. The interval
method is Student t on paired log ratios, one degree of freedom, explicitly
descriptive rather than a substitute for Kenshou's unchanged acceptance policy.

PostgreSQL checkpoint statement execution averages **36.31 to 62.10 µs per
save**, an additional 25.78 µs. It excludes the client round trip and measures
the cumulative cohort's checkpoint SQL, not event-append latency. Checkpoint
statement WAL rises from approximately 155.92 to 164.04 bytes/save. The earlier
isolated local EP2 client-save comparison remains in
[`../ep2-target-binding/README.md`](../ep2-target-binding/README.md).

Across all five verified trials, 181434 events were appended and delivered,
with exactly 181434 checkpoint statement calls and durable updates. Every
artifact's size and SHA-256 was rechecked against its sealed cell manifest.
All four cell instances are TERMINATED; the owned lease was already absent
when the controller repeated release, and the lease-aware stop script succeeded.
The initial invalid two-pair invocation was rejected before VM startup or
measurement; its transcript is retained separately rather than hidden.

## Retained evidence

`summary.json` records each trial, source identities, inputs, paired effects,
descriptive uncertainty, immutable GCS artifact locations and file checksums.
`runs/` retains original result/spec/manifest, reset and health evidence for all
five trials. The full sealed series and raw samples remain at their GCS locations;
they were verified locally without copying every raw series into git.
`session.json`, `journal.json`, `stop-reason.json`, payload descriptors, plans,
unchanged `policy.json`, logs and `controller/` preserve submission, interruption
and cleanup. The sixth submitted run remains identified in the session.
