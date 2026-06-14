---
id: 64
slug: harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates
title: "Harden benchmark regression detection with structural checks and controlled A/B workload gates"
kind: exec-plan
created_at: 2026-06-14T21:19:12Z
---

# Harden benchmark regression detection with structural checks and controlled A/B workload gates

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku currently has a benchmark regression workflow, but EP-5 showed that it is not
strong enough to distinguish a real performance regression from measurement noise in
small microbenchmarks. A single `tasty-bench` run compared to
`kiroku-store/bench/results/baseline.csv` can fail on singleton append cells even when
controlled same-database SQL A/B timing says the schema change is effectively neutral.
That makes the gate hard to trust: it can block good work for noisy reasons, and it can
also train contributors to refresh baselines instead of proving what changed.

After this plan, Kiroku has a two-tier performance regression system. The first tier is
deterministic structural coverage: tests and EXPLAIN checks assert that critical query
paths use the intended indexes, that append emits exactly one notification, and that
cheap paths avoid unnecessary pool or transaction work. The second tier is a controlled
workload benchmark harness: old and new variants run in the same process, against the
same freshly seeded database shape, with warm-up, repeated rounds, environment metadata,
and a pass/fail policy based on workload-level deltas rather than tiny one-off timing
cells. Existing singleton `tasty-bench` cells remain useful telemetry, but they no
longer carry the full responsibility of deciding whether a performance-sensitive change
is safe.

A contributor can see the new system working by running:

```bash
just perf-structure
just perf-workload-gate
just bench-regression
```

The first command should pass or fail deterministically based on query plans and
invariants. The second should print a JSON and human summary showing workload medians,
ratios, and metadata for the current checkout. The third remains as a smoke signal and
historical continuity check, with documentation explaining that noisy microbenchmark
warnings require investigation rather than immediate baseline refresh.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: audit the current benchmark and structural coverage surface; record which
      paths are already deterministic tests, which are timing-only, and which are
      unguarded.
- [ ] M2: add a deterministic structural performance test module for index access,
      notification count, and cheap no-op paths; wire it into `kiroku-store-test` or
      the migrations test suite.
- [ ] M3: add a controlled workload benchmark executable that runs same-process A/B
      workload comparisons with warm-up, repeated rounds, summary statistics, and
      environment metadata.
- [ ] M4: add Justfile recipes and documentation that separate structural gates,
      controlled workload gates, and noisy telemetry.
- [ ] M5: update EP-7 and future performance-plan guidance to depend on the controlled
      A/B gate instead of `just bench-regression` alone.
- [ ] Final: run the structural gate, workload gate, `just build`, `just test`, and
      existing `just bench-regression`; record exact results and write Outcomes &
      Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Split regression detection into structural tests, controlled workload
  A/B gates, and telemetry-only microbenchmarks.
  Rationale: EP-5 showed that singleton append microbenchmarks can move enough to trip
  the historical 10% `tasty-bench` baseline gate while same-database A/B timings show
  no meaningful writer-latency regression. Structural checks catch query-shape mistakes
  without clocks, controlled workload A/B catches user-visible performance changes, and
  microbenchmarks remain useful for investigation.
  Date: 2026-06-14

- Decision: Keep the existing `just bench-regression` workflow, but demote it from the
  only performance gate to a smoke signal.
  Rationale: The checked-in `baseline.csv` and `docs/BENCH-REGRESSION.md` are already
  part of the repository's history and still provide continuity. Removing them would
  lose signal. The problem is treating one historical-baseline comparison as decisive
  for very small operations.
  Date: 2026-06-14

- Decision: Prefer benchmark SQL and query text written with the Haskell
  `MultilineStrings` extension when adding multiple embedded queries to a Haskell
  harness.
  Rationale: `kiroku-store/bench/Main.hs` and `kiroku-store/bench/Explain.hs` already
  use `{-# LANGUAGE MultilineStrings #-}` for large SQL strings. Keeping new benchmark
  queries in multiline literals makes A/B SQL easier to review and avoids fragile
  concatenation.
  Date: 2026-06-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a PostgreSQL-backed event store written in Haskell. The package most affected
by this plan is `kiroku-store`. Its public API lives under
`kiroku-store/src/Kiroku/Store/`, its tests live under `kiroku-store/test/`, and its
benchmark executable lives at `kiroku-store/bench/Main.hs`.

The current benchmark workflow has three main entry points in `Justfile`:

```bash
just bench
just bench-baseline
just bench-regression
```

`just bench` runs `cabal bench all`. `just bench-baseline` runs the
`kiroku-store:kiroku-store-bench` benchmark and overwrites
`kiroku-store/bench/results/baseline.csv` using `tasty-bench` CSV output.
`just bench-regression` runs the same benchmark against that CSV and fails if any named
cell is more than 10% slower. This is documented in `docs/BENCH-REGRESSION.md`.

The existing benchmark executable, `kiroku-store/bench/Main.hs`, uses
`Test.Tasty.Bench.defaultMain` and `whnfIO` cells. It starts an ephemeral PostgreSQL
cluster, applies migrations through `Kiroku.Test.Postgres.migrateTestDatabase`, opens a
`KirokuStore`, seeds benchmark data, prints a legacy B9 pool-saturation measurement,
and then runs named benchmark groups such as `append`, `raw-append-shape`, `read`,
`category`, `concurrent`, and `reliability-audit`. The file already enables
`MultilineStrings`, and its raw SQL snippets are large multiline literals.

The repository also has PostgreSQL-oriented benchmark and profiling tools:
`kiroku-store/bench/sql/run_benchmarks.sh` drives `pgbench` scripts under
`kiroku-store/bench/sql/`, and `kiroku-store/bench/Explain.hs` runs
`EXPLAIN (ANALYZE, BUFFERS, TIMING)` for focused append-path profiling. These should
be reused where possible. `EXPLAIN` is PostgreSQL's query-plan inspection command; it
can show whether a query uses an index scan, a sequential scan, a sort, and how many
buffers were touched. For deterministic regression checks, prefer plan-shape assertions
that do not depend on wall-clock timings.

Terms used in this plan:

**Structural check** means a test that verifies the database or API does the expected
kind of work without measuring elapsed time. Examples are "the dead-letter read query
uses `ix_dead_letters_subscription_position`" and "append emits exactly one PostgreSQL
notification".

**Workload benchmark** means a benchmark that runs enough real operations that the
signal is larger than scheduler noise. Examples are "10,000 appends across many
streams" or "read 100,000 category events in pages", not "one singleton append".

**A/B benchmark** means a benchmark that runs two comparable variants in the same
process and environment. Variant A is the baseline shape, variant B is the candidate
shape. Running both back-to-back against the same seeded database is more reliable than
comparing today's checkout to a CSV captured weeks earlier on a different machine load.

**Telemetry benchmark** means a benchmark that is still collected and printed, but does
not hard-fail the gate by itself. Singleton append microbenchmarks belong here unless
they regress by a very large amount repeatedly or a workload benchmark confirms the
same direction.

The immediate motivation comes from EP-5, completed in
`docs/plans/60-schema-and-trigger-hygiene-notify-guard-dead-letter-fk-policy-and-index-fixes.md`.
That plan initially expected a guarded NOTIFY trigger to improve append writer latency.
Controlled SQL A/B later corrected the interpretation: duplicate notifications and
downstream wakeups were reduced, but writer latency was effectively neutral. The
historical `just bench-regression` gate still produced noisy singleton/raw append
failures. This plan turns that lesson into infrastructure.


## Plan of Work

Milestone 1 is an audit milestone. Read `kiroku-store/bench/Main.hs`,
`kiroku-store/bench/Explain.hs`, `kiroku-store/bench/sql/run_benchmarks.sh`,
`docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/PERF-METHODOLOGY.md`,
and the EP-5 benchmark notes in
`docs/plans/60-schema-and-trigger-hygiene-notify-guard-dead-letter-fk-policy-and-index-fixes.md`.
Create `docs/perf-regression-gate-inventory.md`. This document should classify each
important performance-sensitive behavior into one of three categories: structural gate,
controlled workload gate, or telemetry. At the end of M1, no production code changes are
required. Acceptance is a committed inventory that explains which checks will move out
of timing-only coverage and why.

Milestone 2 adds deterministic structural checks. Add a test module such as
`kiroku-store/test/Test/PerformanceStructure.hs`, then import it from
`kiroku-store/test/Main.hs`. The module should use the existing ephemeral PostgreSQL test
helpers from `kiroku-store/test/Test/Helpers.hs` and
`Kiroku.Test.Postgres.migrateTestDatabase`. It should include focused tests for the
highest-value invariants:

The first test checks the NOTIFY contract. Reuse the approach in
`kiroku-store/test/Test/NotifyGuard.hs`: listen on the Kiroku notification channel,
append to an application stream, perform lifecycle operations that update stream rows,
and assert that exactly one append notification is received for the append and none for
the lifecycle updates.

The second group checks query plans. Use `Hasql.Session` and `EXPLAIN (FORMAT JSON)` or
`EXPLAIN (FORMAT TEXT)` to assert stable structural facts. Seed enough rows to make the
planner prefer the intended index, run the relevant query, and assert that the plan text
contains the expected index name and does not contain an unexpected `Seq Scan` for the
target table. Cover at least the dead-letter read path using
`ix_dead_letters_subscription_position`, the dead-letter FK/delete support using
`ix_dead_letters_event_id`, and the category exhausted-read path that should not scan
the rest of `$all`.

The third group checks cheap no-op paths that should be independent of timing. Existing
tests already cover some of this behavior, such as empty append batches and empty stream
name lookup. If a pool-checkout observation hook already exists, add or extend tests so
empty append and empty lookup assert zero pool checkout. If no hook exists for a given
path, record that in Surprises & Discoveries and limit M2 to the observable checks that
can be made without intrusive instrumentation.

Milestone 3 adds the controlled workload benchmark harness. Prefer a new executable
module under `kiroku-store/bench/`, for example
`kiroku-store/bench/RegressionGate.hs`, and a new Cabal benchmark stanza named
`kiroku-store-regression-gate`. This keeps the existing `kiroku-store-bench` names stable
for `baseline.csv`. The harness should start ephemeral PostgreSQL, apply migrations,
seed deterministic data, warm up the workload, run repeated rounds, and emit two files
under `kiroku-store/bench/results/`: a JSON result file and a short text summary.

The first version of the controlled workload gate does not need to compare two source
branches. It should compare stable in-tree workload variants that protect known risks:
for example API append workload versus raw SQL append workload, category read workload
versus `$all` read baseline shape, and subscription catch-up workload with notification
wakeups counted. For future performance experiments, add an interface that allows a
benchmark-only candidate variant to be plugged into the same harness. This can be as
simple as a Haskell data type:

```haskell
data WorkloadVariant = Baseline | Candidate
```

and a runner shape:

```haskell
runWorkload :: Workload -> WorkloadVariant -> IO WorkloadResult
```

Do not overfit the exact type names. The requirement is that one executable can run
both sides with the same seed, warm-up, and reporting path.

The harness should record metadata in every JSON result: git SHA if available,
benchmark executable name, GHC version, PostgreSQL server version, operating system,
timestamp, seed size, warm-up count, measured round count, and any threshold used for
failure. Use standard Haskell libraries already present where possible. If a new
dependency is genuinely needed for statistics, inspect dependency source and docs with
`mori` before using its API.

Milestone 4 wires commands and documentation. Add Justfile recipes:

```bash
just perf-structure
just perf-workload-gate
just perf-telemetry
```

`perf-structure` should run the deterministic structural tests only. `perf-workload-gate`
should run the new controlled workload benchmark and fail only on workload-level
thresholds. `perf-telemetry` should run the existing `just bench-regression` workflow or
a non-failing equivalent, depending on what is easiest to express with `tasty-bench`.
Update `docs/BENCH-REGRESSION.md` so it no longer implies the CSV baseline is the only
source of truth. Add a new document, `docs/PERF-REGRESSION-GATES.md`, that explains the
three tiers and gives examples of when to use each.

Milestone 5 updates future-plan guidance. Edit
`docs/plans/62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md`
so EP-7 explicitly depends on `just perf-workload-gate` or the new controlled A/B
harness for promotion decisions. It may still run `just bench-regression`, but it must
not promote or reject pipelining/raw-payload changes based on the historical CSV gate
alone. If any master plan registry mentions EP-7 benchmark dependencies, update that
wording to point at this new plan or the new docs.


## Concrete Steps

All commands run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Start by confirming the repository identity and benchmark surface:

```bash
mori show --full
rg -n "bench-regression|bench-baseline|kiroku-store-bench" Justfile docs kiroku-store/kiroku-store.cabal
rg -n "defaultMain|bgroup|MultilineStrings|EXPLAIN" kiroku-store/bench kiroku-store/test
```

Expected shape: `mori show --full` identifies the project as `shinzui/kiroku` with
packages including `kiroku-store`; the `rg` commands show the current Justfile recipes,
the `kiroku-store-bench` Cabal stanza, `Test.Tasty.Bench.defaultMain`, and existing
multiline SQL in `kiroku-store/bench/Main.hs` and `kiroku-store/bench/Explain.hs`.

For M1, create the inventory document and commit it:

```bash
git status --short
just build
```

Expected: `git status --short` is either clean or only shows unrelated user changes that
must not be touched; `just build` exits successfully. Write
`docs/perf-regression-gate-inventory.md` with the classification described above, then
commit:

```bash
git add docs/perf-regression-gate-inventory.md docs/plans/64-harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates.md
git commit -m "docs(perf): classify regression gate responsibilities" \
  -m "ExecPlan: docs/plans/64-harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates.md"
```

For M2, add the structural test module and run it directly:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "performance structure"'
```

Expected output should include a named hspec group such as:

```text
performance structure
  notification contract emits only application append payloads [✔]
  dead-letter reads use the subscription position index [✔]
  dead-letter event-id cleanup uses the event-id index [✔]
  exhausted category reads avoid scanning unrelated $all rows [✔]
```

Then run the full store tests:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```

For M3, add the new benchmark executable and Cabal stanza. Build it before running it:

```bash
cabal build kiroku-store:kiroku-store-regression-gate
cabal bench kiroku-store:kiroku-store-regression-gate
```

Expected output should include a metadata block and a workload summary. The exact numbers
will vary, but the shape should be stable:

```text
Kiroku performance regression gate
metadata: ghc=..., postgres=..., git=...
workload append.multi-stream.10000: PASS median_ratio=...
workload read.category.high-cursor: PASS median_ratio=...
results: kiroku-store/bench/results/regression-gate-YYYYMMDD-HHMMSS.json
```

If a workload fails, do not refresh a baseline. Investigate, record the failure in
Surprises & Discoveries, and either fix the regression or adjust the workload only with
a Decision Log entry explaining why the old threshold was invalid.

For M4, add the Justfile recipes and docs. Verify recipe listing and each new command:

```bash
just --list
just perf-structure
just perf-workload-gate
just perf-telemetry
```

For M5, update EP-7 guidance and run a consistency check:

```bash
rg -n "bench-regression|perf-workload-gate|controlled A/B|baseline.csv" docs/plans/62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md docs/BENCH-REGRESSION.md docs/PERF-REGRESSION-GATES.md
```

At final validation, run:

```bash
just build
just test
just perf-structure
just perf-workload-gate
just bench-regression
```

Record all final results in this plan's Surprises & Discoveries or Outcomes &
Retrospective before the final commit.


## Validation and Acceptance

This plan is accepted when a future contributor has a reliable way to catch performance
regressions without relying solely on historical singleton timing cells.

M1 acceptance: `docs/perf-regression-gate-inventory.md` exists and classifies every
existing `kiroku-store/bench/Main.hs` benchmark group as structural gate, workload gate,
or telemetry. The document must explicitly mention the EP-5 lesson that append writer
latency did not improve measurably even though notification duplication was fixed.

M2 acceptance: `just perf-structure` exists and passes. It must fail if a contributor
removes an index or changes a query shape so a protected path degrades to an unexpected
sequential scan. It must include at least one notification-count invariant and at least
two plan-shape/index invariants.

M3 acceptance: `just perf-workload-gate` exists and runs a controlled workload benchmark
that emits both machine-readable JSON and human-readable summary output. The output must
include metadata and repeated-run statistics. It must not overwrite
`kiroku-store/bench/results/baseline.csv`.

M4 acceptance: `docs/BENCH-REGRESSION.md` clearly states that `just bench-regression` is
a smoke signal and telemetry source. `docs/PERF-REGRESSION-GATES.md` explains which
command to use for structural regressions, workload regressions, and historical
microbenchmark telemetry.

M5 acceptance: `docs/plans/62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md`
no longer treats one `just bench-regression` run as sufficient evidence to promote or
reject EP-7 prototypes. It names the controlled A/B workload gate as the deciding
performance evidence.

Final acceptance: these commands all pass from the repository root:

```bash
just build
just test
just perf-structure
just perf-workload-gate
```

`just bench-regression` should also be run. If it warns or fails on telemetry-only
microbenchmarks while the structural and workload gates pass, document the exact warning
and do not treat that alone as a failed plan. If it fails on a workload-like benchmark
that overlaps the new controlled gate, investigate until the discrepancy is understood.


## Idempotence and Recovery

Most steps are additive and safe to repeat. Structural tests create temporary ephemeral
PostgreSQL databases through the existing test helpers. The controlled workload gate
should also use ephemeral PostgreSQL by default. It must write timestamped result files
under `kiroku-store/bench/results/` instead of overwriting `baseline.csv`.

Do not edit or refresh `kiroku-store/bench/results/baseline.csv` as part of this plan
unless a later explicit decision says the historical tasty-bench baseline itself is being
updated. If it changes accidentally, inspect it before restoring anything:

```bash
git diff -- kiroku-store/bench/results/baseline.csv
```

If the diff is accidental and not a user edit, restore only that file:

```bash
git restore kiroku-store/bench/results/baseline.csv
```

If a benchmark run leaves timestamped result files that are only scratch artifacts, either
record them in the plan and commit the useful one, or remove only those generated files
after checking `git status --short`. Do not remove unrelated files.

If a structural EXPLAIN test is flaky because PostgreSQL chooses a sequential scan on a
tiny table, do not weaken the assertion immediately. First seed enough rows and run
`ANALYZE` in the test setup so the planner has realistic statistics. If the plan remains
unstable, record the evidence and decide whether that path is unsuitable for structural
assertion.

If the controlled workload gate is noisy, increase operation counts, warm-up rounds, or
measured rounds before changing thresholds. The goal is to make the signal bigger than
the noise, not to tune thresholds until a bad benchmark passes.


## Interfaces and Dependencies

Use the existing repository tooling first.

`Test.Tasty.Bench` is already used by `kiroku-store/bench/Main.hs`. Keep it for the
historical `kiroku-store-bench` suite and for telemetry. The new controlled workload
gate may use plain Haskell timing with `Data.Time.Clock.getCurrentTime` if that makes
warm-up, repeated rounds, and JSON reporting easier than fitting the shape into
`tasty-bench`.

`EphemeralPg` and `Kiroku.Test.Postgres.migrateTestDatabase` are already used to boot
temporary PostgreSQL databases and apply embedded migrations. The new workload gate
should use the same approach unless there is a documented reason to use an operator's
existing local database.

`Hasql.Session`, `Hasql.Statement`, `Hasql.Encoders`, and `Hasql.Decoders` are already
used in benchmark and test code. Use them for EXPLAIN checks and raw workload queries.
When adding several embedded SQL queries in Haskell, enable and use:

```haskell
{-# LANGUAGE MultilineStrings #-}
```

Then write queries as multiline string literals:

```haskell
explainDeadLettersReadSQL :: Text
explainDeadLettersReadSQL =
    """
    EXPLAIN (FORMAT TEXT)
    SELECT dead_letter_id, event_id, global_position
    FROM kiroku.dead_letters
    WHERE subscription_name = $1
      AND consumer_group_member = $2
    ORDER BY global_position DESC, dead_letter_id DESC
    LIMIT $3
    """
```

This matches the current benchmark style and is easier to review than string
concatenation.

The new Cabal benchmark stanza should live in `kiroku-store/kiroku-store.cabal` near the
existing benchmark stanzas. A likely shape is:

```cabal
benchmark kiroku-store-regression-gate
  type: exitcode-stdio-1.0
  hs-source-dirs: bench
  main-is: RegressionGate.hs
  build-depends:
      base
    , aeson
    , bytestring
    , containers
    , ephemeral-pg
    , hasql
    , hasql-pool
    , kiroku-store
    , kiroku-test-support
    , text
    , time
  ghc-options: -threaded -rtsopts
```

Adjust the exact dependency list to compile; do not add new third-party dependencies
until inspecting them with `mori registry search`, `mori registry show --full`, and
local source/docs.

The new structural test module should be exposed through the existing test tree. A
reasonable interface is:

```haskell
module Test.PerformanceStructure (spec) where

spec :: Spec
```

and `kiroku-store/test/Main.hs` should include it in the top-level hspec tree under a
group named `performance structure`.

The new documentation interfaces are:

`docs/perf-regression-gate-inventory.md` — one-time inventory produced in M1.

`docs/PERF-REGRESSION-GATES.md` — durable operator/contributor guide for which
performance command to run and how to interpret results.

`docs/BENCH-REGRESSION.md` — revised historical baseline documentation.

`docs/plans/62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md`
— updated future EP-7 guidance so performance promotion relies on controlled A/B
evidence.
