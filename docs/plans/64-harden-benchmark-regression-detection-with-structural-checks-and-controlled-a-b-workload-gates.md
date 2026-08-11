---
id: 64
slug: harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates
title: "Harden benchmark regression detection with structural checks and controlled A/B workload gates"
kind: exec-plan
created_at: 2026-06-14T21:19:12Z
intention: intention_01kzrxb4p6evrt9tacc5sfmcvv
---

# Harden benchmark regression detection with structural checks and controlled A/B workload gates

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku's checked-in `tasty-bench` baseline is useful historical telemetry, but it is
not a trustworthy promotion gate by itself. It compares today's run with timings
captured on an earlier machine state, and `tasty-bench` deliberately treats a current
benchmark with no matching baseline row as an un-compared success. The current tree
makes both limitations concrete: `kiroku-store/bench/Main.hs --list-tests` lists 31
benchmark leaves, while `kiroku-store/bench/results/baseline.csv` contains 25 rows.
The six uncovered leaves are the old `pipelined-multi-append` experiment.

That experiment is also stale in a more important way. ExecPlan 62 promoted pipeline
mode into the production `appendMultiStream` path on 2026-06-14. Consequently,
`runCurrentMultiAppend` and `runPipelinedMultiAppend` now both execute the pipelined
shape. Their labels still say “current” and “pipelined”, but they no longer compare an
old control with a candidate. Leaving them in place gives the appearance of an A/B
check without preserving the contrast that made the original experiment meaningful.

After this plan, contributors have three deliberately different signals. Structural
checks fail deterministically when protected query plans, notification cardinality, or
no-database-work invariants change. A focused same-process A/B workload gate compares
the production pipelined multi-stream append path with an explicit sequential
transaction control on identically seeded databases and fails on their relative ratio.
The historical CSV comparison remains available as telemetry and as an opt-in strict
smoke check, but it is not the evidence that promotes or rejects a performance change.

A contributor can see the completed system working from the repository root:

```bash
just perf-structure
just perf-workload-gate
just perf-telemetry
just perf-check
```

`perf-structure` reports only deterministic invariants. `perf-workload-gate` prints
same-process control/candidate ratios and exits nonzero if the production path loses
its pre-registered advantage. `perf-telemetry` reports differences from
`baseline.csv` without converting a noisy percentage into a failing gate. `perf-check`
runs the two authoritative gates: structure and controlled A/B.


## Progress

- [x] 2026-08-11: Re-audit the plan against the current benchmark, test, migration,
      documentation, ADR, and dependency surfaces. Confirmed 31 current benchmark
      leaves versus 25 baseline rows, the stale pipeline-vs-pipeline experiment, the
      completed EP-7 implementation, and the current `tasty-bench`/Hasql APIs.
- [x] 2026-08-11T17:26:12Z: Consolidate existing notification and no-op coverage under a focused
      `performance structure` test group and add JSON EXPLAIN assertions for the three
      protected index/query shapes. The focused run passed 8 examples in 1.4737
      seconds, and the migration suite passed all 10 examples in 2.9136 seconds.
- [x] 2026-08-11T17:34:09Z: Add a dedicated controlled workload benchmark that compares the old
      sequential multi-stream transaction shape with the current production pipeline
      at four and eight streams using `bcompareWithin`; retire the six stale A/B leaves
      from the historical suite. Three unchanged wall-time runs passed with ratios of
      0.86x-0.88x, and the historical suite now matches all 25 baseline names exactly.
- [x] 2026-08-11T17:37:14Z: Add an exact baseline-coverage preflight, make benchmark code alignment
      deterministic, and separate non-failing historical telemetry from the existing
      opt-in strict CSV regression command. The real 25-name comparison passed, and
      controlled baseline-only and current-only mismatches both failed with unified
      diffs naming the unmatched leaf.
- [x] 2026-08-11T17:40:47Z: Add the final Justfile entry points and update the performance methodology,
      benchmark workflow, and three-tier regression-gate documentation.
      `just --list` exposes all five new interfaces; `just perf-structure` passed
      8 examples, `just perf-workload-gate` passed the registered ratios, and
      `just perf-check` invoked the two authoritative tiers in order.
- [x] 2026-08-11T17:55:13Z: Run build, full tests, exact baseline coverage, both
      authoritative gates, historical telemetry, and the opt-in strict historical
      check. `just build` succeeded, `just test` passed all seven test suites,
      structural coverage passed 8 examples, the final aggregate controlled ratios
      were 0.88x and 0.87x, and both historical modes passed all 25 cells. Distilled the
      three-tier policy into ADR-5 and passed strict OKF and repository ADR validation.


## Surprises & Discoveries

- 2026-08-11: The current benchmark tree and baseline are structurally out of sync.
  Running the built benchmark with `--list-tests` produced 31 `All.*` leaves, while
  parsing `kiroku-store/bench/results/baseline.csv` produced 25 data rows. The exact six
  missing names are the leaves under `All.pipelined-multi-append`.

- 2026-08-11: The missing six leaves no longer form a valid A/B experiment.
  `runCurrentMultiAppend` calls the public `appendMultiStream`, whose implementation in
  `kiroku-store/src/Kiroku/Store/Effect.hs` has used `Session.pipeline` since commit
  `b005e99`. `runPipelinedMultiAppend` separately issues the same `BEGIN` + pre-lock +
  pipelined appends + commit shape. Both arms therefore measure pipeline mode.

- 2026-08-11: `tasty-bench` 0.5.1 already supplies the portable relative gate that the
  old plan proposed rebuilding. `bcompareWithin` divides a candidate benchmark's mean
  by a uniquely selected control and fails when the ratio falls outside a declared
  interval. Its baseline reporter separately returns no comparison for a missing CSV
  row, which leaves that benchmark acceptable. The source was located through
  `mori://Bodigrim/tasty-bench/packages/tasty-bench`.

- 2026-08-11: Much of the proposed deterministic coverage already exists.
  `kiroku-store/test/Test/NotifyGuard.hs` asserts exact notification payload count and
  excludes lifecycle updates; `Test.StreamNameLookup` asserts an empty name lookup uses
  zero pool checkouts; the append tests reject empty batches before state changes. The
  missing structural checks are query-plan assertions and an explicit zero-checkout
  assertion for empty append operations.

- 2026-08-11: Hasql 1.10.3.7 exposes `Hasql.Statement.toSql`, so EXPLAIN tests can wrap
  the actual production statement text instead of copying SQL into the test suite.
  `Hasql.Decoders.jsonBytes Right`, already used by
  `kiroku-store/bench/Explain.hs`, can preserve PostgreSQL's JSON plan for Aeson parsing.
  The source was located through `mori://hasql/hasql/packages/hasql`.

- 2026-08-11: `kiroku-store/bench/Main.hs` performs the 100,000-event category seed and
  the legacy 6,400-append B9 measurement before `defaultMain` sees `--list-tests` or a
  pattern filter. The baseline-coverage preflight can tolerate that cost, but the
  authoritative A/B gate should live in its own small executable so its signal is not
  preceded by unrelated setup and load.

- 2026-08-11: A single realistic fixture of 200 category streams, 100 events per
  stream, and 20,000 dead letters was sufficient for PostgreSQL to choose all three
  protected indexes naturally. The focused run selected
  `ix_stream_events_all_by_origin`, `ix_dead_letters_subscription_position` without a
  `Sort`, and `ix_dead_letters_event_id` without setting `enable_seqscan=off`.

- 2026-08-11: The refreshed plan's assertion that current benchmark names contain no
  commas was wrong. The leaf `All.category.$all forward (100-event page, baseline)`
  is CSV-quoted in `baseline.csv`; a naive first-column split truncated it to
  `"All.category.$all forward (100-event page` even though both sides had 25 rows.
  Exact coverage therefore requires normalizing that one label before the shell
  helper can safely enforce the documented comma-free contract.

- 2026-08-11: The controlled wall-time gate passed three unchanged runs. The
  four-stream production/control ratios were 0.88x, 0.86x, and 0.88x; the
  eight-stream ratios were 0.86x, 0.87x, and 0.86x. This keeps the observed
  advantage below the pre-registered 0.90 ceiling while showing less margin than
  ExecPlan 62's earlier approximately 0.78 measurements.

- 2026-08-11: Exact baseline coverage is practical as a sorted multiset comparison,
  not merely a count. The completed helper reported `baseline coverage OK: 25
  historical benchmarks match exactly`; adding one baseline-only row and removing one
  real baseline row each produced the expected unified diff and nonzero exit.

- 2026-08-11: A deliberately impossible 0.10 ratio ceiling made both controlled
  candidates fail at 0.87x and made Cabal exit nonzero. Restoring the registered 0.90
  ceiling byte-for-byte returned the gate to green, demonstrating that the relative
  comparison is an effective gate rather than report-only output.

- 2026-08-11: The final non-failing historical telemetry run and the opt-in strict 10%
  run both passed all 25 cells. In the strict run the retained
  `reliability-audit.appendMultiStream 3 existing streams` cell measured 248 microseconds,
  34% below its historical baseline, consistent with the separately controlled
  workload gate rather than contradicting it.


## Decision Log

- Decision: Keep three separate responsibilities: deterministic structural checks,
  controlled same-process A/B workload checks, and historical timing telemetry.
  Rationale: Structural checks catch query-shape and no-work regressions without a
  clock. A/B ratios remove most host-to-host drift when a real control exists.
  Historical timings preserve continuity but cannot reliably decide a small change by
  themselves.
  Date: 2026-06-14; reaffirmed 2026-08-11.

- Decision: Preserve `just bench-regression` as the existing strict 10% historical
  command, add `just perf-telemetry` as the non-failing baseline comparison, and make
  `just perf-check` depend only on the structural and A/B gates.
  Rationale: Silently changing the established command's exit semantics would surprise
  existing users. Excluding it from the authoritative aggregate gate removes its noisy
  veto while retaining an explicit strict diagnostic when a contributor wants it.
  Date: 2026-08-11.

- Decision: Use `Test.Tasty.Bench.bcompareWithin` in a dedicated Cabal benchmark rather
  than implement a custom statistics and JSON-reporting framework.
  Rationale: The resolved dependency already implements same-process relative
  performance tests and integrates their pass/fail result with the existing benchmark
  runner. A separate executable avoids the historical suite's unconditional 100K-event
  seed and legacy B9 load. CSV remains available from `tasty-bench` when a durable
  machine-readable result is needed; a bespoke JSON schema would add code without
  improving the promotion decision.
  Date: 2026-08-11.

- Decision: Reconstruct the pre-pipeline sequential transaction only as a benchmark
  control and compare the production `appendMultiStream` API against it at four and
  eight streams. Require a candidate/control ratio no greater than 0.90 in both cells.
  Rationale: EP-7 measured approximately 0.78 at both sizes across three runs (about 22%
  faster). A 0.90 upper bound requires a still-material 10% advantage while leaving
  substantial headroom for ordinary measurement variance. The sequential path is not
  reintroduced into production or exposed as public behavior.
  Date: 2026-08-11.

- Decision: Retire the six `pipelined-multi-append` leaves from
  `kiroku-store/bench/Main.hs` once the new controlled gate exists.
  Rationale: Their labels are now false, they have no baseline rows, and the new
  executable restores the original contrast with an explicit control. The historical
  `reliability-audit.appendMultiStream 3 existing streams` cell remains as telemetry for
  the public API.
  Date: 2026-08-11.

- Decision: Build EXPLAIN statements from `Hasql.Statement.toSql` and inspect parsed
  JSON plan nodes rather than asserting substrings in copied SQL or timing EXPLAIN
  ANALYZE.
  Rationale: This couples the check to the statement production actually executes,
  avoids destructive execution for DELETE shapes, and lets tests assert semantic plan
  facts such as index names and the absence of a `Sort` node.
  Date: 2026-08-11.

- Decision: Reuse and regroup existing notification and empty-lookup tests instead of
  duplicating them in a new performance module.
  Rationale: Those tests already express the required deterministic behavior. The new
  work should add only the missing empty-append checkout assertion and query-plan
  coverage, then give `just perf-structure` one stable Hspec group to select.
  Date: 2026-08-11.

- Decision: Do not revise completed ExecPlan 62 as part of this work.
  Rationale: It is execution history and its implementation is already on `master`.
  This plan consumes its measured control/candidate evidence and corrects the durable
  benchmark surface that remained afterward.
  Date: 2026-08-11.

- Decision: Add `-fproc-alignment=64` to the historical and controlled benchmark
  stanzas.
  Rationale: The resolved `tasty-bench` documentation specifically recommends aligned
  procedure entry points for baseline comparison to avoid intermittent cache-line
  placement skew. Both benchmark signals should compile under the same alignment rule.
  Date: 2026-08-11.

- Decision: Seed the structural EXPLAIN examples once per focused group with 200
  category streams, 100 events per stream, and one dead-letter row per event.
  Rationale: The 20,000-row shape is large enough to make the intended access paths
  cost-effective on PostgreSQL's real planner while keeping the complete focused gate
  below two seconds on the implementation host. Sharing the freshly cloned database
  avoids repeating the seed for each read-only EXPLAIN example.
  Date: 2026-08-11.

- Decision: Pin the controlled database workload group to `tasty-bench`'s
  `WallTime` mode instead of accepting its default `CpuTime` mode.
  Rationale: The control and candidate spend most of their elapsed time waiting
  for PostgreSQL, which runs outside the benchmark process. `CpuTime` would omit
  most server and socket wait time and could compare only client-side overhead;
  `WallTime` measures the end-to-end database operation the gate is intended to
  protect. Both arms remain in the same process and server, so shared host noise
  still affects the ratio symmetrically.
  Date: 2026-08-11.

- Decision: Rename the historical leaf `$all forward (100-event page, baseline)` to
  `$all forward (100-event page baseline)` and update only that row's name in
  `baseline.csv`, retaining its mean and deviation values byte-for-byte.
  Rationale: The coverage helper is intentionally a small shell script rather than a
  CSV parser and must reject commas in names. Removing the sole existing comma makes
  that contract true without refreshing or otherwise altering historical timing data.
  Date: 2026-08-11.

- Decision: Distill the completed three-tier policy into ADR-5 rather than leave it
  only in contributor workflow documentation.
  Rationale: Which evidence may promote or veto a performance change is a durable
  project-level architecture decision. The ADR records the authoritative aggregate,
  the role of exact historical coverage, and the requirement to pre-register controlled
  workloads and thresholds.
  Date: 2026-08-11.


## Outcomes & Retrospective

The repository now has two authoritative performance gates. `just perf-structure`
passed all 8 examples in the final focused run, including zero pooled checkouts for
empty appends, exact notification behavior, and natural PostgreSQL selection of
`ix_stream_events_all_by_origin`, `ix_dead_letters_subscription_position` without a
`Sort`, and `ix_dead_letters_event_id`. The final `just perf-check` run passed the
controlled workload in 12.74 seconds: the production four-stream path measured 550
microseconds against a 623-microsecond sequential control (0.88x), and the eight-stream
path measured 1.01 milliseconds against a 1.16-millisecond control (0.87x). The
aggregate runs those two gates and no historical timing veto.

Historical evidence is complete rather than silently partial. The dedicated preflight
reported exactly 25 current names and 25 matching baseline rows; controlled tests proved
that either a baseline-only or current-only name makes it fail. `just perf-telemetry`
then passed all 25 cells in 155.49 seconds without a timing failure threshold, while
the retained `just bench-regression` strict 10% smoke check independently passed all 25
cells in 215.30 seconds. No baseline timing was refreshed: only the comma-bearing label
was normalized, with its stored mean and deviation retained byte-for-byte.

Repository-wide validation also passed: `just build` completed for the workspace,
`just test` passed all seven test suites, the migration suite passed all 10 examples,
and both strict OKF profile validation and `just adr-validate` accepted all 5 ADRs.
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) now records the durable
policy that structural checks and controlled same-process ratios decide promotion,
while exact-coverage historical comparisons supply telemetry and an opt-in diagnostic.

The main lesson is that benchmark coverage and benchmark validity are separate
problems. Exact name matching repaired the first, but retiring the stale
pipeline-versus-pipeline leaves and rebuilding an explicit sequential control repaired
the second. The remaining operational cost is deliberate: PostgreSQL planner fixtures
and the benchmark-only control must evolve when supported query plans or production
transaction topology legitimately change.


## Context and Orientation

Kiroku is a PostgreSQL-backed event store written in Haskell. The public store package
is `kiroku-store`; its implementation lives in `kiroku-store/src/Kiroku/Store/`, its
Hspec suite lives in `kiroku-store/test/`, and its benchmark sources live in
`kiroku-store/bench/`. Database migrations are no longer owned by `kiroku-store`; the
current native migration component is `kiroku-store-migrations`, with SQL under
`kiroku-store-migrations/migrations/` and an embedded history under
`kiroku-store-migrations/src/Kiroku/Store/Migrations/History/`.

The current historical benchmark target is the Cabal benchmark
`kiroku-store:kiroku-store-bench`, whose `main-is` is
`kiroku-store/bench/Main.hs`. It boots cached ephemeral PostgreSQL, calls
`Kiroku.Test.Postgres.migrateTestDatabase`, opens a `KirokuStore`, seeds a 100K-event
category fixture, runs the legacy B9 pool-saturation measurement once, and then passes
its benchmark tree to `Test.Tasty.Bench.defaultMain`. Its 31 leaves are grouped under
`append`, `raw-append-shape`, `pipelined-multi-append`, `read`, `category`,
`concurrent`, `reliability-audit`, and `subscription-checkpoint-inventory`.

`Justfile` currently exposes `bench`, `bench-baseline`, `bench-regression`,
`bench-regression-threshold`, and `bench-regression-pattern`. `bench-baseline` writes
`kiroku-store/bench/results/baseline.csv`. `bench-regression` compares the current run
against that file and asks `tasty-bench` to fail any compared leaf more than 10% slower.
The baseline has 25 rows: every current leaf except the six under
`pipelined-multi-append`.

The current production multi-stream path lives in the `AppendMultiStream` branch of
`Kiroku.Store.Effect.runStorePool`. It enriches and prepares events, then calls
`runAppendMultiStreamPipeline`. The first protocol phase sends `BEGIN`, the
deterministic stream pre-lock, and all append statements through `Session.pipeline`;
the second phase commits or rolls back after the client inspects results. One transient
serialization or deadlock error is retried. ExecPlan 62 measured the old sequential
transaction against this pipeline at four and eight streams and then promoted the
pipeline into production. See
[`docs/plans/62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md`](62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md)
and the 2026-06-14 rows in
[`docs/perf-experiment-log.md`](../perf-experiment-log.md).

The test suite runs under one shared cached PostgreSQL server through
`Kiroku.Test.Postgres.withSharedMigratedPostgres`. Each call to
`withMigratedTestDatabase` clones a newly migrated template database, so tests and the
new A/B gate can obtain isolated databases with identical starting schema. Store test
fixtures in `kiroku-store/test/Test/Helpers.hs` wrap those databases with
`withTestStore` or `withTestStoreSettings`.

A structural check verifies the kind of work performed without comparing elapsed
time. In this plan that means an exact notification count, zero observed pool checkouts
for a no-op, or a PostgreSQL JSON query plan containing an intended index. A controlled
A/B workload has a control and candidate compiled into one executable, run on the same
server against identically seeded databases. Historical telemetry compares an absolute
timing with an older CSV row and reports the change without deciding promotion.

The protected production query shapes are in `kiroku-store/src/Kiroku/Store/SQL.hs`.
`readCategoryForwardStmt` uses a LATERAL subquery over the partial index
`ix_stream_events_all_by_origin` so a high cursor does not scan the remaining `$all`
suffix. `readDeadLettersStmt` orders by global position and dead-letter id so
`ix_dead_letters_subscription_position` can satisfy both filtering and ordering without
a separate sort. `deleteDeadLettersForOrphanedEventsStmt` probes dead letters by event id
and depends on `ix_dead_letters_event_id`. The indexes are installed by
`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`,
`0004-dead-letters-event-id-index.sql`, and
`0005-index-hygiene-and-streams-fillfactor.sql`.

Existing deterministic tests already cover part of the target. `Test.NotifyGuard`
asserts one append notification per append and no lifecycle-update notification.
`Test.StreamNameLookup` uses Hasql pool observations to prove empty batch lookup takes
zero pool checkouts. The empty append group in `kiroku-store/test/Main.hs` proves empty
single- and multi-stream requests do not change durable state, but it does not yet
count pool checkouts.

Three local ADRs matter. [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md)
records a same-machine A/B decision and the standing 10% read-regression concern; it is
evidence for using a real control, not authority for applying one historical CSV
threshold to every leaf. [ADR-3](../adr/0003-dedicated-kiroku-schema.md) makes
`ConnectionSettings.schema` and the per-connection `search_path` authoritative, so
EXPLAIN tests should run through the store pool or explicitly preserve that path.
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) explains the current
checkpoint contract whose 100-row and 10,000-row inventory cells now appear in the
historical suite. No current ADR governs performance-regression gate architecture; the
implementation must perform the required final ADR distillation instead of inventing an
ADR during this planning refresh.

Dependency APIs used by this design were verified from Mori-located source. The
resolved `tasty-bench` is 0.5.1 and provides `bcompareWithin`; the package API is
`mori://Bodigrim/tasty-bench/packages/tasty-bench`. The resolved Hasql is 1.10.3.7 and
provides `Hasql.Statement.toSql` and `Hasql.Decoders.jsonBytes`; its package API is
`mori://hasql/hasql/packages/hasql`. Ephemeral PostgreSQL lifecycle and cached startup
come from `mori://shinzui/ephemeral-pg/packages/ephemeral-pg`, while Kiroku should
normally consume them through `kiroku-test-support`'s existing migrated-template
helpers.


## Plan of Work

Milestone 1 creates one deterministic structural gate without rewriting existing
coverage. Add `kiroku-store/test/Test/PerformanceStructure.hs` and register it in
`kiroku-store/kiroku-store.cabal` and `kiroku-store/test/Main.hs`. Give the top-level
group the exact name `performance structure`. Move the existing empty-lookup
zero-checkout spec behind an exported sub-spec from `Test.StreamNameLookup`, and nest
`Test.NotifyGuard.spec` under this top-level group rather than running a duplicate.
Add an empty `appendToStream` and empty `appendMultiStream` observation test that records
`InUseConnectionStatus` events and requires a delta of zero.

The same module adds three query-plan examples. Seed representative category, event,
and dead-letter rows, run PostgreSQL `ANALYZE` so estimates are realistic, and build
`EXPLAIN (FORMAT JSON, COSTS OFF)` SQL by prefixing the text returned by
`Hasql.Statement.toSql` for the production statement under test. Substitute only
hard-coded test literals for positional parameters; no user input enters this helper.
Decode the one JSON result with `D.jsonBytes Right`, parse it with Aeson, recursively
collect `Node Type`, `Relation Name`, and `Index Name` from `Plan` and nested `Plans`,
and assert semantic facts. The category plan must name
`ix_stream_events_all_by_origin`; the dead-letter read must name
`ix_dead_letters_subscription_position` and contain no `Sort`; the orphan dead-letter
delete/probe must name `ix_dead_letters_event_id`. Do not set `enable_seqscan=off`: the
test proves the representative shape is actually selected, not merely available.

Milestone 1 is complete when a focused Hspec run selects all notification, no-op, and
plan-shape examples under one group and passes, and when temporarily changing an
expected index name makes the focused command fail with a plan dump useful for
diagnosis.

Milestone 2 restores a real controlled A/B gate. Add
`kiroku-store/bench/RegressionGate.hs` and a Cabal benchmark named
`kiroku-store-bench-workload-gate`. The executable obtains two fresh databases from one
shared migrated PostgreSQL server: one for the sequential control and one for the
production candidate. Seed matching four-stream and eight-stream sets in each database
and warm both arms before measurement.

Implement the control only inside the benchmark. It must reproduce the pre-`b005e99`
transaction topology: prepare events, pre-lock stream names through
`SQL.lockStreamsForMultiStmt`, issue each append with `appendDispatchTx` inside
`TxSessions.transaction ReadCommitted Write`, and commit after all results. The
candidate must call the public `appendMultiStream` through `runStoreIO`; it must not call
`runAppendMultiStreamPipeline` or another internal shortcut, because the gate protects
the production dispatch path. Use unique or `AnyVersion` appends so repeated benchmark
iterations remain valid, force all results, and fail immediately on a store or pool
error. Apply Tasty's `localOption WallTime` to the complete controlled group so the
measurement includes PostgreSQL server and socket wait time.

Declare the sequential cell before its dependent candidate. Wrap the production cells
with `bcompareWithin 0 0.90`, selecting the unique matching sequential control at the
same stream count. The console should show candidate ratios, and a ratio above 0.90
must make the benchmark executable exit nonzero. Keep the prior contention pair only
if it remains useful as non-gating telemetry; scheduler-sensitive contention must not
become a required ratio in the first version.

Once the new gate passes, remove the six stale `pipelined-multi-append` leaves and their
now-misleading helpers from `kiroku-store/bench/Main.hs`. Do not remove
`reliability-audit.appendMultiStream 3 existing streams`; it remains historical public
API telemetry. The historical suite should then list exactly the 25 names already
present in `baseline.csv`, so this milestone requires no baseline timing refresh.

Milestone 3 makes historical coverage explicit. Add an executable shell helper at
`kiroku-store/bench/check-baseline-coverage.sh`. It should locate the built
`kiroku-store-bench` binary with `cabal list-bin`, run `--list-tests`, select only lines
beginning with `All.`, parse the baseline header and name column, sort both name sets,
and fail with a unified diff when either side has an unmatched name. Benchmark names
currently contain no commas; document that constraint in the helper and fail loudly if
a future name contains one instead of parsing it incorrectly. Use a private directory
from `mktemp -d` and clean only that exact directory in a trap.

Add `just bench-baseline-check`; have that recipe build
`kiroku-store:kiroku-store-bench` before invoking the helper. Run the preflight before
`bench-regression`, `bench-regression-threshold`, `bench-regression-pattern`, and the
new `perf-telemetry` recipe. `perf-telemetry` runs the same benchmark with `--baseline`
but without `--fail-if-slower`, so real benchmark execution errors still fail while
timing differences remain reports. Preserve the current strict commands and
thresholds. Add `-fproc-alignment=64` to both the historical benchmark stanza and the
new workload-gate stanza; do not change the library or test compiler options.

Milestone 4 wires and documents the public workflow. Add `perf-structure`,
`perf-workload-gate`, `perf-telemetry`, and `perf-check` recipes to `Justfile`.
`perf-check` should invoke only the first two. Update `docs/BENCH-REGRESSION.md` to
describe exact baseline coverage, the non-failing telemetry command, and the retained
strict historical command. Update `docs/PERF-METHODOLOGY.md` so future optimization
plans use controlled pairs for promotion and the historical suite to detect unrelated
movement. Add `docs/PERF-REGRESSION-GATES.md` as the short contributor-facing map of
the three tiers, their commands, failure meaning, and baseline-update policy. Link the
new guide from both existing documents instead of duplicating their detailed content.

At finalization, update Progress after every stopping point, capture unexpected planner
or benchmark behavior in Surprises & Discoveries, and record any threshold or workload
change in the Decision Log before changing code. Review all three living sections and
Outcomes & Retrospective for durable architectural context. If the final three-tier
policy is judged project-level architecture, create or update the appropriate ADR
under the profiled `docs/adr/` bundle and run `just adr-validate`; otherwise record why
the existing contributor docs are sufficient.


## Concrete Steps

All commands run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Confirm the refreshed starting point without modifying benchmark data:

```bash
git status --short
mori show --full
cabal build kiroku-store:kiroku-store-bench
BENCH_BIN=$(cabal list-bin kiroku-store:kiroku-store-bench)
"$BENCH_BIN" --list-tests | rg '^All\.' | wc -l
sed '1d' kiroku-store/bench/results/baseline.csv | wc -l
```

Expected before implementation: the two counts are 31 and 25. `git status` may show
unrelated user changes; do not stage or edit them.

For Milestone 1, add and select the structural group:

```bash
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "performance structure"'
cabal test kiroku-store-migrations:kiroku-store-migrations-test \
  --test-show-details=direct
```

Expected focused output has one `performance structure` group containing the existing
NOTIFY guard, empty lookup and append checkout assertions, and three named query-plan
examples. A useful success shape is:

```text
performance structure
  NOTIFY trigger guard ...
  no-op paths use no pooled connection ...
  category high-cursor reads use ix_stream_events_all_by_origin ...
  dead-letter reads use ix_dead_letters_subscription_position without Sort ...
  orphan dead-letter cleanup uses ix_dead_letters_event_id ...
```

For Milestone 2, build and run the dedicated gate directly before adding its Justfile
wrapper:

```bash
cabal build kiroku-store:kiroku-store-bench-workload-gate
cabal bench kiroku-store:kiroku-store-bench-workload-gate \
  --benchmark-options='--stdev 5'
```

The exact timings vary, but both candidate leaves must be marked `OK`, print ratios at
or below `0.90x`, and the summary must report all tests passed. The command must exit
nonzero if either `bcompareWithin` upper bound is temporarily reduced below the
observed ratio.

After moving the stale cells out of `Main.hs`, confirm historical coverage before
capturing or comparing timings:

```bash
just bench-baseline-check
```

Expected: the helper reports that all 25 listed historical benchmarks have exactly one
baseline row. It must fail if a temporary extra line is added to either name set.

For Milestone 3 and Milestone 4, exercise each public command separately:

```bash
just --list
just perf-structure
just perf-workload-gate
just perf-telemetry
just perf-check
```

`perf-telemetry` may report slower or faster historical leaves but exits zero unless
the suite itself errors or baseline coverage is incomplete. `perf-check` exits zero
only when structure and both controlled ratios pass.

Check documentation and stale-name cleanup:

```bash
rg -n 'perf-structure|perf-workload-gate|perf-telemetry|perf-check|bench-baseline-check' \
  Justfile docs/BENCH-REGRESSION.md docs/PERF-METHODOLOGY.md \
  docs/PERF-REGRESSION-GATES.md
rg -n 'pipelined-multi-append|runPipelinedMultiAppend|runCurrentMultiAppend' \
  kiroku-store/bench/Main.hs
```

Expected: the first search finds each new interface in the implementation and docs;
the second search returns no matches in the historical benchmark.

Run final validation:

```bash
just build
just test
just bench-baseline-check
just perf-structure
just perf-workload-gate
just perf-telemetry
just bench-regression
```

The build, tests, coverage preflight, structural gate, workload gate, and telemetry
command must pass. Run the strict historical command and record its exact result. A
timing-only failure there is not by itself a failed plan, but an overlapping slowdown
in `reliability-audit.appendMultiStream 3 existing streams` must be investigated
against the controlled gate before completion.

Every implementation commit must use a Conventional Commit subject and end with this
trailer:

```text
ExecPlan: docs/plans/64-harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates.md
```


## Validation and Acceptance

The plan is accepted when a contributor can distinguish a structural regression, a
same-process workload regression, and historical timing movement by running the four
documented commands without interpreting one signal as another.

Milestone 1 is accepted when `just perf-structure` runs the existing notification and
empty-lookup invariants, the new empty-append zero-checkout assertion, and all three
production-SQL JSON EXPLAIN assertions. Removing or making unusable one of the protected
indexes must fail a named test with the actual parsed plan shown in the diagnostic.

Milestone 2 is accepted when the dedicated workload executable compares isolated but
identically seeded control and candidate databases in one process. The production
four-stream and eight-stream candidates must each measure no more than 0.90 times their
sequential controls. The old six pipeline experiment leaves must no longer appear in
the historical suite.

Milestone 3 is accepted when the historical suite and baseline have exactly the same
25 names and the coverage helper fails in both mismatch directions. The historical and
controlled benchmark stanzas both compile with `-fproc-alignment=64`.

Milestone 4 is accepted when `docs/PERF-REGRESSION-GATES.md` tells a novice which
command to run and what a failure means; `docs/BENCH-REGRESSION.md` distinguishes
non-failing telemetry from the retained strict command; and
`docs/PERF-METHODOLOGY.md` requires controlled evidence for promotion decisions.

Final acceptance requires successful `just build`, `just test`,
`just bench-baseline-check`, `just perf-structure`, `just perf-workload-gate`, and
`just perf-telemetry`. The strict `just bench-regression` result must be recorded and
explained, but a timing-only failure is not authoritative when structure and the
controlled gate pass.


## Idempotence and Recovery

All new database work uses cached ephemeral PostgreSQL and freshly cloned migrated
databases. Re-running structural or workload gates creates no durable database state.
The two A/B arms use separate databases, so repeated measurements cannot let control
rows change the candidate's initial table shape.

The baseline-coverage helper creates only a private temporary directory with
`mktemp -d`. Its trap must remove the resolved temporary directory, never a broad path
or an unresolved environment variable. The helper reads `baseline.csv`; it does not
rewrite it.

Do not run `just bench-baseline` merely to make a historical timing failure disappear.
This plan deliberately removes six stale unbaselined cells so the remaining 25 current
names match the existing 25 rows without changing their measurements. If
`baseline.csv` changes accidentally, inspect it first:

```bash
git diff -- kiroku-store/bench/results/baseline.csv
```

Restore it only when the diff is known to be generated by this work and not a user
edit. Never restore or delete unrelated working-tree changes.

If an EXPLAIN test chooses a sequential scan, first verify the fixture row counts,
`ANALYZE` call, parameter substitution, and actual JSON plan. Increase realistic seed
cardinality when the planner has insufficient evidence. Do not force index selection
with `enable_seqscan=off`, and do not weaken the assertion without recording the
observed plan and rationale in this plan.

If an A/B cell is noisy, run it on a quiet host and inspect the reported standard
deviation. Repeat the unchanged gate three times before diagnosing a real regression.
Increase work per iteration or tighten `--stdev` before changing the 0.90 threshold.
Any threshold or workload change requires a Decision Log entry made before accepting
the new result.


## Interfaces and Dependencies

The structural test module has the conventional test interface:

```haskell
module Test.PerformanceStructure (spec) where

spec :: Spec
```

`kiroku-store/test/Main.hs` should expose one stable selector:

```haskell
describe "performance structure" $ do
    PerformanceStructure.spec
    NotifyGuard.spec
    StreamNameLookup.noOpSpec
```

Adjust the exact split if Hspec fixture nesting requires it, but do not duplicate the
existing notification or lookup examples and keep the full path selectable by
`--match "performance structure"`.

The EXPLAIN helper consumes actual statement text:

```haskell
Hasql.Statement.toSql :: Statement params result -> Text
```

It wraps that text with `EXPLAIN (FORMAT JSON, COSTS OFF)`, substitutes fixed test
literals for parameters, decodes the returned PostgreSQL `json` value with
`D.jsonBytes Right`, and parses it with the already declared `aeson` test dependency.
No new library dependency or production API is needed.

The workload benchmark is a new Cabal stanza near the current benchmark stanzas:

```cabal
benchmark kiroku-store-bench-workload-gate
  import:         common
  type:           exitcode-stdio-1.0
  main-is:        RegressionGate.hs
  hs-source-dirs: bench
  ghc-options:    -threaded -rtsopts "-with-rtsopts=-N -A32m" -fproc-alignment=64
```

Its dependencies should be limited to `base`, `aeson`, `generic-lens`, `hasql-pool`,
`hasql-transaction`, `kiroku-store`, `kiroku-test-support`, `lens`, `tasty`,
`tasty-bench`, `text`, `time`, and `vector`, trimming any unused entries after
compilation. The direct `tasty` dependency supplies `localOption`; `tasty-bench`
supplies `WallTime`, estimation, and the relative gate. Do not add a statistics
package.

The essential gate shape is:

```haskell
bgroup
    "append-multi-stream"
    [ bench "sequential control (4 streams)" $ whnfIO control4
    , bcompareWithin 0 0.90 "sequential control (4 streams)" $
        bench "production pipeline (4 streams)" $ whnfIO candidate4
    , bench "sequential control (8 streams)" $ whnfIO control8
    , bcompareWithin 0 0.90 "sequential control (8 streams)" $
        bench "production pipeline (8 streams)" $ whnfIO candidate8
    ]
```

Use unambiguous control patterns; if name growth makes the short strings ambiguous,
construct exact paths with `locateBenchmark` and Tasty's pattern printer after locating
that dependency through Mori.

`kiroku-store/bench/check-baseline-coverage.sh` is the only new script. It compares the
historical executable's `All.*` list with the first CSV column after the header and
prints a diff. It must reject commas in names unless it is upgraded to a real CSV
parser.

The public command contract is:

```text
just perf-structure        deterministic Hspec and query-plan invariants
just perf-workload-gate    authoritative same-process relative performance gate
just perf-telemetry        non-failing historical timing comparison
just perf-check            perf-structure followed by perf-workload-gate
just bench-regression      retained opt-in strict 10% historical comparison
```

No cross-repository code change is required. Cross-repository dependency references in
durable documentation must use the Mori URIs recorded in Context and Orientation, not
local absolute corpus paths.


## Revision Note

2026-08-11: Rebased the June plan on the current code before implementation. The
revision accounts for completed ExecPlan 62, the native migration package, new
checkpoint inventory benchmarks, existing notification/no-op tests, the 31-leaf versus
25-row baseline mismatch, and the stale pipeline-vs-pipeline cells. It replaces the
proposed custom JSON statistics harness and obsolete EP-7 update milestone with a
focused `tasty-bench` `bcompareWithin` gate, exact baseline coverage, and current
repository commands and paths.
