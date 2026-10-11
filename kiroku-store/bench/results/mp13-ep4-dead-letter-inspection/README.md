# EP-4 dead-letter inspection verification

Local completion on 2026-10-11, based on parent `b8f1f43`; implementation and
this evidence are committed together on local master. No remote performance
experiment, production migration, version/bound edit or publication occurred.

`cabal build all` passes (pre-existing warnings retained). `cabal test all -j1`
passes CLI 22, metrics 77, otel 17, store 446, migrations 24 and adapter 45
examples: 631 total. The ten-step metrics example passes. `nix build
.#kiroku-metrics` passes. Packages disable Nix tests; Cabal verifies the test-only
atomic callback collector repair. Nix formatting and strict ADR, capability and
improvement-request checks pass. IR-9 remains in_progress until release.

`prepared-plans.json.gz` retains all sixteen actual production EXPLAIN ANALYZE
BUFFERS cases: four statement shapes, generic/custom prepared plans, and three
historical members with 1,000 then 20,000 rows each. A six-row fetch examines at
most six member rows; all-member pages report 21.01 rows with PostgreSQL's
loop-average rounding, under the unchanged 24-row bound. Merge input is at most
18 candidates; shared buffers reach at most 27 under the 128-buffer ceiling.
Both existing name/member-leading indexes can enumerate members; lateral pages
use ix_dead_letters_subscription_position. No new index is added.

All task logs are retained compressed with deterministic gzip headers. Earlier
logs include record-selector/build errors, bad Hspec argument quoting, a fixture
column error, and an overly specific enumeration index-name assertion. The SQL
work budgets were never relaxed. `tests-all.log.gz` preserves the initial 446-case
run's missing backpressure resumed event; `tests-all-2.log.gz` preserves the full
pass after changing the shared multi-threaded callback collector from non-atomic
to atomic IORef updates. Production FSM code and every assertion are unchanged.
The initial partial-staging treefmt rejection is recorded in plan 89; no commit
was created by it. Modules are staged with their Cabal registrations in the final
commit. `example.log.gz` and the HTTP focused log contain real wire transcripts.

This is correctness and bounded-read-work evidence. Cumulative append-under-
inspection performance acceptance and publication remain with plan 96; the browse
index's previously retained inconclusive results are unchanged. ADR-9, ADR-8 and
ADR-15 cover the durable decisions; no additional ADR is needed.

Verify retained artifacts with `shasum -a 256 -c artifacts.sha256` in this directory.
