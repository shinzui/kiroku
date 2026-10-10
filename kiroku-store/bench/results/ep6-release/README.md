# EP6 release readiness and retained stopped experiment

EP6 remains In Progress. No release metadata has changed and nothing has been
published. The exact six-package metadata proposal is in
[proposal/README.md](proposal/README.md) and [release-metadata.patch](proposal/release-metadata.patch).
Version confirmation is pending under the repository release skill; publication
requires a second explicit approval and passing acceptance gates.

The integrated full build and all six PostgreSQL 18.6 suites pass, totaling 554
examples. Six current-version packaging checks, strict ADR validation (14
concepts), configured capability validation (21 concepts), and native Nix formatting and
pre-commit checks pass. An additional strict capability audit reports 18 existing
concepts without profile-recommended review provenance; the repository capability
recipe passes with profile/log enforcement. No review metadata was invented. Existing structural/controlled evidence at the unchanged
production source `5805117` is reused from `../ep5-unique-violation/`: 20 structural
checks and 16 controlled cases pass in 117.74 seconds. Fresh/upgrade migration
fixtures are included in the 24 migration examples. New-version source/Haddock
archives and the publication/clean-consumer/downstream gates remain outstanding.

`just perf-telemetry` failed two of 30 historical cases in 443.01 seconds: the
new-stream NoStream append and exhausted-category read each reached the existing
100-second timeout. The full adverse output is retained in `perf-telemetry.log`.
No retry or favorable subset replaces this failed gate.

The focused original-control experiment was declared before remote submission in
`scope.json`. It planned three ABBA pairs for two independent live all-stream
subscribers with a successful identity hook, three pairs for the real Shibuya
adapter with diagnostics disabled, and one descriptive diagnostic-enabled adapter
trial immediately after the final disabled head trial. PostgreSQL 18 durability,
GHC 9.12.4, four writers, pool 10, batch sizes 1, width 1, 30-second warmup,
61-second steady window and at most 30-second drain were fixed. The original
`policy.json` was retained: the short queue could remain inconclusive rather than
relaxing its five-pair minimum or regression limits.

Control production source is `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0`; candidate
production source is `5805117edf6bdb988d02d73e19fbb221ef2bf767`. Disabled arms share
clean harness source `b8ec42d661bb25025adb48d0c80f4a2ccd326365`. The diagnostic
wrapper's isolated clean source is `3849a10ab31c14b9c6bd499d94fdd33e1ad5eb45`;
its verified candidate cohort identity is identical to the disabled payload's,
with a distinct wrapper bundle. This diagnostic payload was never executed.

The original whole-experiment clock began at 2026-10-10 02:46:38 UTC, with a fixed
03:46:38 deadline and 180-second cleanup reserve. Formatting, payload-root and
integer-plan-estimate preparation failures are retained; each occurred before a
performance trial and did not restart the clock. Previous verified EP2 recovery
checks were reused. The operator is mori://shinzui/keiro-runtime-kenshou; cell
ownership belongs to mori://shinzui/load-testing-infra.

The first baseline adapter run sealed with entry exit code 4 and scenario outcome
`errored`: `checkpoint frequency differs from the declared batch policy`. The
next candidate was submitted before that failure was inspected. It was
interrupted immediately, sealed as `cancelled` with reason `lease-lost`, and was
fetched separately after cleanup. Both sealed manifests and every retained
artifact's size and SHA-256 were independently verified. The failed baseline
reset was verified. There are **zero valid benchmark trials, zero matched pairs,
zero replacements, and no active remote execution**. The remaining four adapter
trials, diagnostic trial and six fan-out trials were not submitted. No speed or
uncertainty estimate can be computed.

The failed baseline observed 44,545 steady deliveries. Sampled subscription
update counters showed 22,571 near the steady boundary and 67,098 at done, while
load totals were 22,586 after warmup and 67,131 after steady work. This is consistent
with counter lag, which PostgreSQL documents for cumulative statistics:
https://www.postgresql.org/docs/18/monitoring-stats.html. The exact failed invariant
locals were not retained by the executing harness, so this is a hypothesis,
not a proved root cause or evidence that the invariant passed.

All failed raw histograms, samples, host/SQL series, reset/health evidence and
logs remain under `runs/<cell-run>/tree/`; cancelled-run artifacts are retained in
the same shape. `summary.json` records artifact hashes and explicit uncertainty.
`executed-controller.py` preserves the controller that ran; the updated
`remote-controller.py` stops immediately when a verified slice has a failed entry
code and reports the scenario reason before looking for a successful summary.
The harness now stores `checkpoint-validation` before its unchanged assertion,
including delivery counts, table-counter boundaries and SQL snapshots. These
post-stop diagnostic corrections build successfully for released/head/head-stall
payloads in 88.20 seconds and were not retried remotely.

Cleanup completed 25.14 minutes after the original start. The operator released
the owned lease; a subsequent release confirmed it was already absent. All four
alpha VMs were verified TERMINATED and cell status showed no lease or quarantine.
Read-only cancelled-artifact recovery and local diagnostic-build validation stayed
within the same deadline. The gate remains **inconclusive** and historical
telemetry remains **failed**; no publication approval is requested on this evidence.
