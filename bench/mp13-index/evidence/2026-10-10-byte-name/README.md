# Selected byte-name index: final-layout cost comparison

The selected index makes the production browse statements fast and bounded, but
it has measurable catalog storage and WAL cost. Write point estimates are adverse;
the 95% intervals span both directions. Neither workload proves zero slowdown,
and most intervals miss the frozen 6% relative-width precision target.
No performance allowance was changed and no additional trials were queued.

## Scope and verified execution

One clean immutable payload, PostgreSQL 18.6 with durable writes, four appenders,
a 40,000-stream deterministic UUIDv7 TypeID catalog, and five alternating AB/BA
pairs per workload. Each trial has 10 seconds warmup, 61 seconds measurement,
and up to 10 seconds drain. The original control retains its three stream indexes;
the candidate adds only `ix_streams_browse_name` on
`stream_name COLLATE "C" WHERE stream_id <> 0`. All twenty measured arm inventories
were checked. Both arms use the same production `listStreamsSession` statements.

Runtime source: `9717120a0411ac05d8aa6febe9e76e7a3a107d15`.
Published harness: `63ed721a35798c2478eea78f0e0327c7bd2982db`, clean,
scenario revision 6. The six runtime package paths are unchanged between those
commits. The shared operator is from `mori://shinzui/keiro-runtime-kenshou`.
Earlier replacement-layout results are retained separately and are not pooled.

All 21 trials verified: one lifecycle proof, ten fresh trials, and ten observer
trials. Sealed manifests and every artifact hash passed; raw metrics were
recomputed. Every measured trial is benchmark-grade. Counters and durable drain
passed; every observer trial passed exact category delivery and steady browse
coverage. The controller exited successfully. Its original deadline began before
Linux build. The user explicitly extended the same start-time budget from 60 to
75 minutes; both budget records and authorization are retained. Cleanup was
verified at 59.32 minutes: no lease, and all four cell instances `TERMINATED`.

Setup recoveries are retained: initial cell-status TLS timeout, a Linux harness
import conflict, and missing operator `zstd`. No measured trial was retried or
replaced. The owner cleanup script is in `mori://shinzui/load-testing-infra`,
`scripts/cell/stop.sh` (artifact-level URI pending).

## Write estimates

Actual candidate percentage change, with 95% intervals:

| Workload | Throughput | Append p99 |
| --- | --- | --- |
| Every append creates a TypeID stream | -2.980% [-6.128%, +0.274%] | +3.700% [-3.814%, +11.802%] |
| Existing streams, category subscriber, and browsing | -1.722% [-4.631%, +1.276%] | +0.308% [-3.556%, +4.327%] |

Both unchanged zero-slowdown policy verdicts are **inconclusive**. No metric
confirmed a regression under the frozen gate. All fresh metrics miss its 6%
relative interval-width target; only observer p95 meets that precision target.
Do not describe these results as accepted performance or proof of neutrality.
Independent pair variability limits precision despite tens of thousands of
append samples per trial. See `summary.json` for p50/p95, all pairs, and exact
interval widths. These are index-layout/SQL observer measurements; cumulative
HTTP, tail and inventory acceptance remains plan 96's work.

Descriptive physical counters, without confidence claims:

| Counter | Original | Selected |
| --- | ---: | ---: |
| Fresh WAL bytes/event | 2,131.89 | 2,252.73 (+5.668%) |
| Fresh HOT updates | 98.698% | 98.694% |
| Observer WAL bytes/event | 1,995.08 | 1,998.80 (+0.187%) |
| Observer HOT updates | 99.474% | 99.507% |
| Initial stream-index bytes | 4,538,368 | 7,872,512 (+73.466%) |

The additional index is 3,334,144 bytes (3.180 MiB) on the fixed 40,000-stream
fixture. It indexes catalog rows, not events or stream-event rows. New streams
and eligible non-HOT catalog updates still incur maintenance; unchanged HOT
eligibility is not a claim that event appends are free of end-to-end cost.

## Browse diagnostics

Steady-window median SQL latency across all five observer pairs:

| Page | Original | Selected |
| --- | ---: | ---: |
| Exact-category first | 15.020 ms | 0.647 ms |
| Exact-category late | 4.968 ms | 0.471 ms |
| Absent literal global prefix | 16.414 ms | 0.380 ms |

There are 305 original and 310 selected samples per shape at one browse cycle
per second. These sparse samples describe read behavior; they are excluded from
the primary append grade and are not a separately accepted latency benchmark.
Production generic/custom EXPLAIN and Unicode correctness evidence is retained
with the implementation's store tests.

## Reporting correction and retained evidence

Kenshou normalizes adverse ratios: throughput is baseline/candidate, while
latency is candidate/baseline. The pre-submission reporting edit mistakenly
assumed all ratios used candidate/baseline. Raw data, paired comparisons, policy,
and verdicts were unaffected. The original derived `cost-estimates.json` files
and controller logs are preserved for audit; **use `cost-estimates-corrected.json`
and `summary.json`** for actual candidate changes. The throughput interval is
inverted with its endpoints reversed. The fixed controller was checked against
both real comparisons and tests with a known 100-to-98 throughput example.

`protocol/` retains setup/recovery logs, source identities, the frozen protocol,
budget extension, remote phase/power audits, lease and cleanup proof, correction
source, and final reporting checks. Case directories retain plans, journals,
comparisons, original and corrected derived reports, and compressed verified
records. `sealed-metadata.tar.gz` retains manifests, run specifications and
results. Journals and verified records retain immutable GCS raw-result prefixes;
all fetched artifacts were hash-verified and raw recomputation passed.
`sha256.json` covers the retained machine-readable evidence and logs.

Recommendation: retain the one shared index implementation for the required
category/prefix browsing, and treat its write cost as real. Reserve release
promotion for the cumulative original-control gate and an explicit cost review;
do not claim a second independent allowance for plan 54 or silently accept the
unresolved fresh-stream tail bound.
