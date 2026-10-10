# EP6 authorized follow-up: valid evidence, acceptance inconclusive

Release remains deferred; EP6 remains In Progress. The one-hour follow-up closed
with **13 valid benchmark trials**, three real-adapter pairs, two successful-hook
fan-out pairs, one unmatched fan-out baseline, one calibration and one diagnostic
trial. There are **zero replacements**. All four cell VMs are TERMINATED, with no
lease or quarantine. No production library code or release metadata changed.

The fixed clock is 2026-10-10 03:31–04:31 UTC. Remote work stopped at the declared
04:28 cleanup cutoff. Cleanup finished at 04:28:32 UTC (57.54 minutes from the
start); fetch and independent collection also finished before the one-hour limit.
The preflight payload-label refusal occurred before any trial and is retained,
including its shutdown timeout and subsequent proof that all VMs stopped. The
original closed experiment in `../ep6-release/` is unchanged.

The invalid checkpoint assumption was diagnosed locally and verified remotely.
AllStreams live batches come from the publisher, whose maximum size is 1000;
the subscription fetch limit of 1 does not control those batches. Both source
arms save once per delivered batch. Six actual-adapter probes each delivered
1000 events and drained durable progress. Table updates exactly matched observed
batch counts, including after longer flush checks across ten distinct backends.
The generic statistics probe did not reproduce lag. The corrected remote
calibration delivered 40,203 events in 40,176 batches and checkpoint saves.
Every accepted remote run has exact delivery, batch/update/SQL-call agreement,
durable drain, on/on/on PostgreSQL durability, a verified reset, benchmark grade,
a completed cell outcome and independently verified artifact sizes/SHA-256.

The final fan-out candidate's scenario reported `passed`, but its cell sealed
`cancelled` after the cutoff with `lease-lost` and `health-unavailable`. Its sealed
manifest and all artifacts were fetched and verified. It is excluded from trial
acceptance and matched effects; no favorable result replaces an interrupted run.

| Workload | Complete pairs | Throughput change (95% interval) | p99 change (95% interval) |
| --- | ---: | --- | --- |
| Real Shibuya adapter | 3 | +3.91% (-0.27% to +8.27%) | +3.52% (-33.37% to +60.84%) |
| Two live subscribers, successful identity hook | 2 | +3.23% (-18.30% to +30.44%) | -6.59% (-31.64% to +27.66%) |

Intervals use Student t on paired log ratios (df = pairs - 1), as declared;
they do not replace the original Kenshou policy. The real-adapter report remains
`inconclusive`, with fewer than the required five pairs and wide intervals. The
fan-out queue did not finish, so it has no completed operator comparison report;
its two-pair descriptive estimate is also inconclusive. Throughput improved in
every accepted pair. Adapter p99 improved in two pairs and worsened in one;
a separate control fan-out trial also had a tail spike. There is no confirmed
candidate-specific slowdown, but these data cannot establish zero regression or
rule out a concerning tail-latency change. The 10% descriptive uncertainty target
was not met for p99; no gate was weakened or extra experiment queued.

Additional retained effects: adapter p50 -3.81%, p95 -4.54%, WAL/op +0.01%,
allocation/op +0.39%; successful-hook fan-out p50 -2.21%, p95 -7.12%, WAL/op
+0.97%, allocation/op +3.04%. Full pair-level effects, intervals and per-save
checkpoint SQL execution/WAL are in `summary.json`.

The single chronological diagnostic comparison against the preceding disabled
head observed throughput +1.32%, p99 +3.36%, allocation/op +1.99%, WAL/op +0.65%.
This is descriptive only and has no uncertainty estimate; it does not isolate a
causal diagnostic cost or grant default-path acceptance.

The two historical telemetry timeouts passed a focused repeat using the unchanged
CPU-time baseline, default relative deviation and existing timeout in 96.00
seconds: NoStream append 125 µs ± 7.0 µs (32% below baseline), exhausted-category
17.9 µs ± 872 ns (reported same). The initial parser refusal is retained. The
original full 2/30 failure remains in `../ep6-release/perf-telemetry.log`; the
focused repeat does not replace it. Tasty-bench defaults to CPU-time adaptation
but its hard timeout uses wall time, making I/O timeout susceptibility plausible,
not proving the original cause. Dependency source discovery used
mori://Bodigrim/tasty-bench and mori://hasql/hasql.

Control production source: `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0`.
Candidate production source: `5805117edf6bdb988d02d73e19fbb221ef2bf767`.
Clean disabled-arm harness: `f7273083f1d719ac701500c898152c04dadd5170`.
The diagnostic wrapper uses the identical head cohort identity and a distinct
bundle. Operator: mori://shinzui/keiro-runtime-kenshou; infrastructure owner:
mori://shinzui/load-testing-infra. `scope.json`, `journal.json`, controllers,
plans, payload descriptors, logs and all immutable sealed artifacts are retained.

All five implementation children remain Complete. The existing 554-example
PostgreSQL 18.6 integrated correctness result and unchanged-source structural/
controlled checks remain valid. Performance acceptance, release metadata approval,
new-version archives/publication, clean-consumer proof and downstream adoption
remain outstanding. No tag, push, Hackage upload or downstream edit occurred.
