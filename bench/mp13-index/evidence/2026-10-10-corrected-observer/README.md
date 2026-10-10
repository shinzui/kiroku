# Corrected category/name observer comparison, 2026-10-10

This follow-up measures the default-opclass `(category, stream_name)` replacement
for `ix_streams_category(category)` with active category browsing and one category
subscriber. Both arms run one immutable executable; layout is the only varied
compatibility input. No production migration or browse API is installed.

## Correction and protocol

The earlier observer run registered the sparse browser as a primary operation.
Kenshou requires 1,000 steady samples per registered operation, so 1 Hz browsing
made that evidence exploratory. Scenario revision 5 retains every raw browser
timing in a separate `browse-diagnostics` summary and registers only appends in
the primary recorder. The queries, 1 Hz cycle, first/late/absent pages, LIMIT 11,
subscriber load, append sampling/health requirements and durability are unchanged.
Sparse browser timings remain descriptive diagnostics, not an independently
accepted latency benchmark. Earlier artifacts are immutable and are not pooled
with this revision.

PostgreSQL 18.3, durable settings, 128 MiB shared buffers, four writers, ten pooled
connections, one event with a 512-character JSON body per append and RTS
`-N4 -T -A32m`. The fixture has 20,000 empty deterministic UUIDv7 TypeID streams
in each of two categories and four existing writer streams. Writers reuse those
four streams with unpaced capacity and bounded subscriber backpressure. This
case measures combined shared work, not bare existing-write overhead or isolated
subscription query latency. The valid fresh-write comparison is retained in
[the original experiment](../2026-10-10/README.md).

One corrected baseline observer proof precedes five adjacent AB/BA pairs.
Each trial declares 10s warmup, 61s measurement and a 10s drain allowance, with
bounded durable waits and a 180s executor timeout. Eleven trials allow about
27.5 minutes including observed reset overhead; build/publication, verification
and cleanup bring the estimate to 35–40 minutes. One new persisted 60-minute
budget includes all those stages. The earlier budget is not reset. Prior controls
are retained; the new proof establishes corrected grade and lifecycle, not
statistical resolution. No smaller pair count, favorable replacement or extra
precision repeats are allowed. Invalid grade/hash/workload/schedule, stopped
active instances, five minutes without remote phase/count progress, deadline
or confirmed regression stops further work.

The original zero-slowdown policy is unchanged: five pairs, benchmark grade,
95% paired bootstrap/Student-t intervals, 10,000 bootstrap iterations, maximum
6% relative interval width and zero checkpoint asymmetry. Cost estimates and
upper slowdown bounds are reported separately from that policy's verdict.
Targets are useful 95% bounds near ±3% throughput and ±5–6% tail latency;
wider bounds remain unresolved. No new accepted regression allowance is chosen.

## Verified results

The corrected proof passed benchmark grade with 47,734 append samples and only
`append` in the primary operation set. Separate steady browse counts were 62
first, 62 late and 61 absent pages. Sealed hashes, schedule/page coverage, stream
counters, exact delivery, durable drain, raw-summary recomputation and lease
release passed. All ten comparison trials are also benchmark-grade; all five
pairs are retained. Sealed hashes and raw-summary recomputation passed for
every trial. There were no retries, replacements or additional trials.

The clean published harness is `229f6e598889ecb97abeca0c1d304a55004bd315`.
The operator is `mori://shinzui/keiro-runtime-kenshou` at
`7a451b5f5f4b51986e872879a3bfe10f5943af6b`. Production package source remains
`1c6905f61dfd32e3e6838739a2ddfae8cb187def`, verified against current package
code before publication. General literal-prefix and plan 54 namespace/global
ordering design remain open; this benchmark does not settle those access paths.


The figures below are paired candidate changes with 95% intervals. Throughput
is capacity under the combined workload; latency is append latency. These are
valid cost estimates, distinct from the unchanged zero-slowdown verdict.

| Append metric | Candidate change | 95% interval | Upper slowdown bound |
| --- | ---: | ---: | ---: |
| Throughput | -0.466% | -1.821% to +0.908% | 1.821% loss |
| p50 latency | +0.462% | -1.260% to +2.215% | 2.215% increase |
| p95 latency | -0.147% | -1.225% to +0.944% | 0.944% increase |
| p99 latency | -0.013% | -2.192% to +2.214% | 2.214% increase |

All intervals include zero. The zero-slowdown policy is **inconclusive** because
these valid intervals allow both improvement and a small regression; the trials
are not invalid or exploratory. The predeclared useful precision target was met.
A positive accepted cost allowance would be a separate decision. This experiment
does not select one or demonstrate exact zero cost.

Sparse browse timings are descriptive, pooled across each arm's five trials.
They are neither paired confidence intervals nor a standalone latency gate.

| Browse page | Samples baseline / candidate | Median baseline | Median candidate | p95 baseline | p95 candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| First | 310 / 310 | 4.411 ms | 0.270 ms | 5.033 ms | 0.409 ms |
| Late | 310 / 310 | 0.369 ms | 0.389 ms | 0.542 ms | 0.569 ms |
| Absent | 305 / 310 | 7.987 ms | 0.231 ms | 9.466 ms | 0.356 ms |

The late-page result prevents a blanket claim that every browse query improves.
The absent category page is an unfiltered empty result, not a literal-prefix test.
Exact category delivery and durable drain passed in every trial. Each event caused
two stream updates and no stream insertion. HOT fractions were 99.4854% versus
99.4814%. Global WAL/event was 1,988.85 versus 2,007.92 bytes (+0.959%); append
statement WAL/call was 1,664.27 versus 1,677.99 bytes (+0.824%). WAL changes are
descriptive and have no paired confidence bounds here. Initial stream-index
footprint was 4,538,368 versus 8,126,464 bytes (+79.06%), with the replacement
index itself 286,720 versus 3,874,816 bytes. The existing category event index
used by subscriptions is unchanged. Combined workload bounds do not isolate
subscription latency or extrapolate to arbitrary catalog/cache sizes.

The separate valid fresh-write experiment found throughput -0.677% (95% interval
-2.687% to +1.374%), p99 +1.718% (interval -1.703% to +5.258%) and descriptive
WAL/event +2.43%. It is not repeated or pooled with this corrected observer case.

These results support keeping the replacement candidate in the shared access
review: first/absent category pages become much cheaper, with append cost now
bounded for this fixture. They do not justify installing a category-only solution
and then paying for an independent prefix structure. Resolve the literal-prefix
and plan 54 namespace/global-ordering design first, then judge the final shared
layout against an explicit cost allowance and its affected paths.

## Cleanup and retained evidence

The owned lease was released and all four cell instances were verified TERMINATED.
The single budget includes build, publication, proof, five pairs, raw verification
and cleanup; exact elapsed time and deadline checks are in
[experiment-completion.json](protocol/experiment-completion.json).

[summary.json](summary.json) contains counter, layout and diagnostic aggregates.
[Cost estimates](existing-category-browse/cost-estimates.json) and
[comparison.json](existing-category-browse/comparison.json) preserve the exact
bounds and policy verdict. Losslessly compressed verified records and
`sealed-metadata.tar.gz` retain specs, manifests and results. Original append
samples remain in each verified record's sealed `rawPrefix`; the successful
`--verify` logs are retained. [sha256.json](sha256.json) covers retained evidence
bytes; this editorial README is outside that manifest. ADR distillation selects
no new architecture: ADR-15 already governs the shared-work review.
