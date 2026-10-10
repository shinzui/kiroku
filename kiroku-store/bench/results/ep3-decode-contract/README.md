# EP3 focused decode-contract evidence

Implementation source: `eb58104`; pre-change EP3 base: `7e9c7a2`.
PostgreSQL 18.6 on PATH, GHC 9.12.4, Cabal 3.16.1.0, aarch64 macOS,
Cabal O1. Source and test changes are committed together. `summary.json`
records counts and SHA-256 checksums for every retained transcript.

M1's temporary characterization confirmed that a persistently throwing hook
retried the same publisher position while the subscribed worker appeared live
and delivered nothing. `pre-change-regression.log` retains that observation
(1 example passing the characterization). Permanent tests replace it with the
typed data-failure contract; thrown programming exceptions retain their prior
behavior. This log is a correctness characterization, not a timing benchmark.

Final correctness: 360 store tests including 21 publisher callback resilience
cases; 22 metrics, 38 adapter, 24 migration, 22 CLI, 17 OpenTelemetry tests.
All 483 pass. `tests-verified.log` contains the six-suite workspace pass before
two final store recovery/cleanup tests were added; `final-affected-tests.log`
contains the final 360-store/22-metrics pass, including JSON/Prometheus assertions.
The other four suites' production inputs remained unchanged. `build-verified.log`
records the final all-component build. No PostgreSQL-version matrix ran.

The contracts exercised include bounded default retries without dead letters or
checkpoint advancement past the failure, healthy sibling live continuation,
shared successful-hook decoding, category/group live and catch-up handling,
explicit dispositions, typed reads without partial vectors, cancellation,
replay after repairing the hook, and persistent effect-environment sharing.
The metrics WebSocket emits its existing error frame and releases its publisher
queue on a typed live decode failure. A no-hook test retains a vector containing
unevaluated events; source inspection confirms direct read passthrough and no
per-event subscription wrappers.

`perf-check.log` passes 20 structural checks and all 16 existing controlled
workload cases (115.37 seconds for the workload gate). These compare existing
SQL controls and do not compare EP3 or the full cohort against its predecessor.
The category-append control was noisy (45.9 ± 48 ms), so its favorable ratio is
not evidence of cumulative performance neutrality. Successful-hook outcome
allocation and real adapter costs remain EP6 concerns. No new remote experiment,
new harness, calibration queue or per-child statistical-equivalence study ran.
The retained EP1/EP2 uncertainty and original comparison policy remain unchanged.

Strict ADR validation passes 12 concepts, and capability validation passes 21.
The hook API, subscription config and exhaustive enum matches are source-breaking;
publication/version selection remains EP6 work. ADR-12 records the durable contract.

Commands, from the repository root:

```bash
cabal build all
cabal test all --test-show-details=direct
cabal test kiroku-store:kiroku-store-test kiroku-metrics:kiroku-metrics-test --test-show-details=direct
just perf-check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
nix fmt
```
