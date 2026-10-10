# EP6 authorized follow-up

This directory retains the separate follow-up authorized after deferring release.
The fixed whole-work budget is 2026-10-10 03:31–04:31 UTC, including all setup,
diagnosis, builds, remote trials, fetch/verification and cleanup. The closed
experiment in `../ep6-release/` remains unchanged.

Six actual-adapter probes delivered 1000 events each and drained durable progress.
Checkpoint table updates equalled observed delivery batches exactly, before and
after longer statistics flushes. The live publisher limit is 1000, independent
of the subscription fetch limit of 1. Both source arms checkpoint each delivered
batch. The harness therefore requires exact checkpoint-update/delivery-batch
agreement and retains exact event delivery, durability and durable drain gates.
The generic statistics probe alone did not reproduce any lag.

The focused CPU-time telemetry repeat passed both previously timed-out cases in
96.00 seconds using the existing baseline, default relative deviation and hard
timeout. NoStream append: 125 µs ± 7.0 µs, 32% below historical baseline.
Exhausted-category: 17.9 µs ± 872 ns, reported same. An initial command failed
argument parsing after fixture setup and is retained. Neither repeat replaces
the original 2/30 failed full telemetry run. The upstream default CPU-time
adaptation and wall-time hard timeout can explain I/O timeout susceptibility;
they do not prove the original timeout cause. Source discovery used
mori://Bodigrim/tasty-bench and mori://hasql/hasql.

Remote cumulative evidence is pending. No release metadata has changed.
