# Plan 99 — adverse gate result, 2026-10-25

The first converged append comparison failed the unchanged 1.05 ceiling:
**1.058478x**, or **+5.85%** in this run. Timing experiments stopped at that
point under Plan 99's explicit adverse-result condition. No three-run acceptance
or full `perf-check` pass is claimed.

All spreads below are tasty-bench's **doubled standard deviation**, not confidence
intervals. A single run with roughly 8% spreads does not establish a reproducible
5.85% regression or a universal migration cost.

| Run | Setup | Control mean ±2σ | Candidate mean ±2σ | Ratio | Evidence quality |
| --- | --- | --- | --- | --- | --- |
| `baseline` | Original harness | 53.332 ±54.058 ms | 28.614 ±13.063 ms | 0.536532x | Both arms invalid; vacuous pass |
| `warm-focused-1` | Disposable first cell | 32.329 ±10.132 ms | 31.438 ±8.257 ms | 0.972451x | Both arms exceed 20% spread |
| `quiescent-focused-1` | Warm cell, checkpoint and vacuum/analyze | 3.336 ±0.087 ms | 52.031 ±33.143 ms | 15.596814x | Candidate invalid; rejected |
| `populated-focused-1` | Twenty setup iterations per append store, checkpoint and vacuum/analyze, separate warm store | 3.327034 ±0.277265 ms | 3.521592 ±0.265205 ms | **1.058478x** | Spreads 8.33% / 7.53%; ratio fails |

Each timed iteration still performs 20 fresh-stream and 20 hot-stream appends.
The final setup primes all three append stores equally with 400 fresh streams
and 800 events before analyzing. It leaves the frozen pre-0012 statement,
production statement and numeric gates unchanged. The disposable cell uses its
own sixth database, preserving both comparison arms and the pipeline fixture.
This setup removed the large position effect in the first trial; the prescribed
three-run confirmation remains unperformed because of the adverse stop.

`journal.jsonl` retains exact commands, start/finish times, initial load averages,
exit statuses and elapsed times, including the initial relative-CSV-path failure.
`environment.json` records compiler, benchmark dependencies and hardware. The
user explicitly authorized continuing on the active host; the final comparison
started at load 3.41 / 4.69 / 4.46. This was a local experiment with a 60-minute
ceiling starting at 13:35:27 UTC; timing stopped at 13:46:22 UTC, after about
11 minutes including the build and rejected attempts.

`diagnostic.jsonl` contains 45 one-second PostgreSQL samples during the warm-only
attempt: zero completed checkpoints, zero active vacuums in 44 samples and one
vacuum in one sample. The active work included appends and publisher head queries.
`head-plan.log` shows indexed head queries on grown stores and a sequential scan
on the still-small candidate. This supports investigating startup statistics and
plan selection; it does not prove a root cause. No production publisher behavior
was disabled for measurement.

Deterministic validation: 41 structural examples passed (`structure.log`);
seven parser/recipe tests passed, including corruption of every comparison arm
and preservation of a nonzero benchmark exit status. Strict ADR and friction
bundle validation passed. Whole-manifest Dhall type-checking reproduces a pre-existing
`versionConstraint` mismatch in the dependency helpers, before this bundle addition;
that unrelated migration remains outside Plan 99. The full timed recipe and three consecutive focused
runs remain outstanding; no favorable retry replaces the failed sample.
