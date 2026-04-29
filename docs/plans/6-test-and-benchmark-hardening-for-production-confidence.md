---
id: 6
slug: test-and-benchmark-hardening-for-production-confidence
title: "Test and benchmark hardening for production confidence"
kind: exec-plan
created_at: 2026-04-29T14:06:33Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/1-production-readiness-review-of-kiroku-store.md"
---

# Test and benchmark hardening for production confidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`kiroku-store` already has a substantial test suite (`kiroku-store/test/Main.hs` is 887 lines, hspec-based, exercises every public function and every subscription scenario via `ephemeral-pg`). It also has a benchmark suite (`kiroku-store/bench/Main.hs`, `kiroku-store/bench/ShibuyaOverhead.hs`, results captured in `kiroku-store/bench/results/`) showing the system meets the Gate 3 performance targets. The gap between this suite and a production-grade test surface is in three areas: (1) *concurrency* — there are no deterministic concurrent-access tests; the existing subscription tests use `threadDelay` for synchronization, which is fragile; (2) *property-based coverage* — the suite asserts specific scenarios but does not assert system-wide invariants (e.g. "no orphan rows after any sequence of appends and failures"; "global positions are gap-free across any interleaving"); (3) *failure-injection* — every test runs against a healthy ephemeral database. There are no tests for connection drops, slow networks, pool exhaustion, etc.

After this plan, the package has: (1) a property-based test module that codifies the invariants identified by EP-1 (CTE correctness), EP-2 (API contracts), EP-3 (subscription delivery semantics), and EP-4 (multi-tenancy); (2) a deterministic-concurrency test harness that replaces `threadDelay`-based synchronization with STM barriers; (3) a failure-injection harness aligned with EP-5; (4) a stress-benchmark suite covering scenarios beyond Gate 3 (sustained multi-stream concurrent appends, slow-handler subscription, large-payload appends); (5) a baseline-regression check so future changes are measured against a frozen reference.

A reader can verify the change by running `cabal test kiroku-store` (the existing tests plus the new property and deterministic tests), `cabal bench kiroku-store:kiroku-store-bench` (existing + new stress benchmarks), and reading the new test-strategy section in the package README.


## Progress

- [x] Milestone 1: Test and benchmark gap inventory (2026-04-29; 24 findings F1–F24: 11 must-fix, 9 should-fix, 4 deferred-with-rationale)
  - [x] Catalogue the existing test suite by function-under-test and scenario-tested
  - [x] Catalogue the existing benchmark suite by what it measures
  - [x] List invariants from EP-1 through EP-5 that should be property-tested
  - [x] List concurrency scenarios that should be deterministic-tested
  - [x] List failure-injection scenarios needed (cross-plan with EP-5)
  - [x] List stress-benchmark gaps
- [ ] Milestone 2: Land tests and benchmarks
  - [ ] Add property-based tests using `hedgehog` or `QuickCheck`
  - [ ] Replace `threadDelay`-based subscription synchronization with STM barriers
  - [ ] Add failure-injection scenarios coordinated with EP-5
  - [ ] Add stress benchmarks for scenarios beyond Gate 3
  - [ ] Establish a baseline-regression workflow
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

### M1 — Gap inventory (2026-04-29)

The audit confirms the initial leads and adds five more findings. Total: 24 findings
(F1–F24, EP-6 numbering — distinct from EP-1 through EP-5). 11 must-fix,
9 should-fix, 4 deferred-with-rationale.

#### Existing Coverage Map

`kiroku-store/test/Main.hs` is 1521 lines — larger than the 887 the plan baseline
recorded because EP-1 through EP-5 each landed regression tests (66 → 79 cases).
The suite covers every public function in `Kiroku.Store`:

  * `appendToStream` — 11 scenarios across the four `ExpectedVersion` constructors,
    batch append, global position contiguity, duplicate event id rejection.
  * `readStreamForward` / `readStreamBackward` — 4 scenarios (read-your-own-writes,
    pagination, empty stream, `getStream` integration).
  * `readAllForward` / `readAllBackward` — 3 scenarios.
  * `readCategory` — 4 scenarios (filtering, pagination, empty, link inclusion).
  * `linkToStream` — 7 scenarios including F3 (silent version gap), F5 (link to
    soft-deleted target).
  * `appendMultiStream` — 4 scenarios including F4 ordering preservation. Multi-stream
    *concurrency* is explicitly punted to EP-6 (the F4 test comment states this).
  * `softDeleteStream` / `undeleteStream` / `hardDeleteStream` — 16 scenarios
    including F1 (orphan removal), F6 (TRUNCATE protection on three tables).
  * `subscribe` / `withSubscription` — 12 scenarios covering catch-up, live mode,
    checkpoint persistence, F18 (Category live filter), F25 (bracket), cancellation,
    empty store, debouncing, F6 (overflow policy), Eff API.
  * `Notifier` reconnection — 1 scenario (F1 listener-conn release post-reconnect).
  * `KirokuEvent` observation — 3 scenarios (F1 reconnect events, F14 lifecycle,
    F13 hard-delete audit).
  * Pure helpers — 5 scenarios for `extractStreamNameFromDetail`.

Functions with zero direct tests: none in the public API. Every constructor of
`StoreError` is exercised by at least one test except `PoolAcquisitionTimeout`,
`ConnectionLost`, `UnexpectedServerError` — these were added by EP-2 F19/F20
without dedicated reproducers. **F1 (must-fix)**: add a failure-injection test
that pins the pool, drains it, and observes `PoolAcquisitionTimeout`.

#### Invariant List (F2–F8 — property targets)

  * **F2 (must-fix).** *Global position contiguity.* For any sequence of `appendToStream`,
    `appendMultiStream`, and `linkToStream` calls, the global positions assigned form
    a contiguous prefix of `[1..N]`. Source: EP-1 F2 (soft-delete TOCTOU) and F3
    (linkToStream silent version gap) — both fixed; this property guards against
    regressions.
  * **F3 (must-fix).** *No orphan events after lifecycle ops.* For any sequence of
    appends followed by a `hardDeleteStream`, the `events` table contains exactly
    one row per surviving `stream_events` row (no orphans, no missing payloads).
    Source: EP-1 F1.
  * **F4 (must-fix).** *Soft-delete write barrier.* After `softDeleteStream`, no
    `appendToStream` of any `ExpectedVersion` succeeds until `undeleteStream`.
    Source: EP-1 F2; the existing scenario tests cover three constructors but a
    property test verifies arbitrary sequences cannot bypass it.
  * **F5 (must-fix).** *Idempotent caller-supplied event ids.* For any sequence of
    appends, every event id is unique → all succeed; any id is duplicated → exactly
    the duplicate fails with `DuplicateEvent`. Source: EP-1 audit.
  * **F6 (should-fix).** *Lifecycle round-trip.* `softDelete; undelete` returns a
    stream to a state functionally equivalent to its pre-delete state (reads return
    the same events, version unchanged, appends succeed at the same expected
    version). Source: EP-1 audit.
  * **F7 (should-fix).** *`readStreamForward` order.* For any append sequence,
    `readStreamForward s 0 N` returns events in `streamVersion`-ascending order.
    Source: EP-1.
  * **F8 (deferred).** *Link round-trip.* For any link, the linked event's
    `originalStreamId` and `originalVersion` match the source's `streamId`,
    `streamVersion`. Source: EP-1. Deferred — this is a structural invariant of
    the schema's foreign keys, already exercised by every link scenario test;
    a property test would not add coverage.

#### Concurrency Scenarios (F9–F13)

Existing scenario tests are single-threaded. The deterministic concurrency harness
must add:

  * **F9 (must-fix).** *Two concurrent appends to different streams.* Both succeed,
    global positions interleave but stay contiguous, both finish without deadlock.
  * **F10 (must-fix).** *Two concurrent `appendToStream` calls to the same stream
    with `ExactVersion 0`.* Exactly one returns success at `streamVersion 1`; the
    other returns `WrongExpectedVersion`. No deadlock.
  * **F11 (must-fix).** *Two concurrent `appendMultiStream` calls touching the same
    streams in opposite order.* EP-1 F4 landed a sorted `SELECT … FOR UPDATE`
    pre-pass to prevent deadlock; this test verifies it. Both calls eventually
    succeed (in serialized order) without `40P01` deadlock detection firing.
  * **F12 (should-fix).** *Subscription concurrent with hot writes.* A live
    subscription receives all events appended during its run, in `globalPosition`
    order, with no duplicates within a single worker run.
  * **F13 (should-fix).** *Multiple subscriptions to `$all`.* Two named subscriptions
    each receive every event independently; they do not interfere via the
    publisher's broadcast.

#### Failure-Injection Scenarios (F14–F18)

Coordinated with EP-5's findings (already landed for emit-side observability).

  * **F14 (must-fix).** *Listener kill + recovery via NOTIFY.* Already present at
    `test/Main.hs:1233` (existing F1 reconnect test) — verify reconnect; **add**
    an event appended *during the down window* is still delivered via the safety
    poll. Closes the EP-5 F1 cross-plan.
  * **F15 (must-fix).** *Pool exhaustion.* Hold all pool connections in long-running
    transactions; the next `appendToStream` returns `PoolAcquisitionTimeout`
    (the EP-2 F19 constructor). Closes EP-2 F19's reproducer gap (cross-plan).
  * **F16 (should-fix).** *Slow handler triggers `OverflowPolicy`.* The existing
    F6 overflow test exercises `DropSubscription`. The plan's stated scope is
    one policy; we already have it. Folded into F12 above as "the at-least-once
    contract under load".
  * **F17 (should-fix).** *Hard-delete event audit fail-safe.* Already present at
    `test/Main.hs:1357` (F13 EP-5). No additional test required from EP-6 —
    confirmation only.
  * **F18 (deferred).** *Database paused mid-append.* Producing a deterministic
    pause via `ephemeral-pg` is awkward (would require SIGSTOP on the postmaster
    and risks leaving zombie clusters across CI runs). The pool exhaustion test
    (F15) covers the same `Pool.use` failure path. Deferred.

#### Stress Benchmark Gaps (F19–F22)

  * **F19 (should-fix).** *Multi-writer concurrent stress.* Promote the existing
    B9 wall-clock measurement (`bench/Main.hs:77-103`) to a structured tasty-bench
    benchmark with N = {8, 32, 64} writers, recording p50/p95/p99 from in-process
    timing samples.
  * **F20 (should-fix).** *Subscription catch-up time.* Append 100K events, then
    measure time to catch up from position 0. The current bench suite has no
    subscription benchmark.
  * **F21 (deferred).** *10KB and 100KB JSONB payload performance.* Useful but
    out-of-scope for the production-readiness verdict — `kiroku` does not impose
    a payload-size limit and the SCALING-ANALYSIS doc already notes that large
    payloads degrade throughput proportionally. Deferred.
  * **F22 (deferred).** *Sustained-throughput soak test (1M events, steady-state
    memory).* Worth doing but takes >30 minutes per run — it does not fit in
    `cabal bench`'s expected runtime envelope. Tracked as a future Justfile
    target; deferred.

#### Baseline Regression (F23–F24)

  * **F23 (must-fix).** *Establish baseline-regression workflow.* The current
    `kiroku-store/bench/results/` has 11 timestamped files (sql_bench_*,
    haskell_bench_m3, shibuya_adapter_overhead) but no canonical baseline. Pick
    the latest Haskell M3 run (`haskell_bench_m3_20260322.txt`) as the baseline
    for `bench/Main.hs` outputs; capture an inline baseline CSV at
    `kiroku-store/bench/results/baseline.csv` and add a `just bench-regression`
    target that runs `cabal bench`, parses tasty-bench's CSV mode, and
    compares against baseline at a 5% threshold (configurable).
  * **F24 (must-fix).** *Document baseline update protocol.* Add a section to
    `docs/PRODUCTION-TUNING.md` (or a new `docs/BENCH-REGRESSION.md`) explaining
    when to update the baseline and require a Decision Log entry. Without this,
    every flaky CI bench run will tempt a contributor to silently update the
    baseline.

#### threadDelay Inventory

Subscription tests at `test/Main.hs` use `threadDelay` for synchronization at
the following lines:

  * 726, 799, 916, 1106 — `threadDelay 200_000` waiting for EventPublisher to
    process appended events before subscribing. **Replace** with
    `atomically (publisherPosition pub >>= check . (>= GlobalPosition n))`.
  * 782, 958, 983, 1017, 1162, 1186, 1332 — `threadDelay 100_000` waiting for
    the subscription worker to enter live mode. **Replace** with an
    `eventHandler`-driven `MVar` barrier that opens on
    `KirokuEventSubscriptionCaughtUp` for the named subscription.

The remaining `threadDelay` usages (1165, 1192 — Async.race timeouts;
1412 — `waitWithTimeout`; 1473, 1485 — listener-pid polling intervals) are
not synchronization points and stay.


## Decision Log

- Decision: Use `hedgehog` for property-based tests (generators are first-class, shrinking is automatic, integration with hspec via `hspec-hedgehog` is idiomatic). Add the dependency in Milestone 2.
  Rationale: `QuickCheck` would also work; `hedgehog`'s explicit generator type and integrated shrinking are a better fit for the operation-sequence properties this suite needs.
  Date: 2026-04-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The reader is assumed to have only the working tree and this file.

`kiroku-store` is a Haskell PostgreSQL event store. Its existing test infrastructure:

- `kiroku-store/test/Main.hs` (887 lines) — hspec-based; uses `ephemeral-pg` to spin up a temporary PostgreSQL 18 instance per test (via `withTestStore`). Tests cover every public function: append (all four variants), read (forward/backward/all/category), link, multi-stream tx, soft-delete/undelete/hard-delete, subscriptions (catch-up, live, checkpoint persistence, category filtering, cancellation, empty store, debouncing, effectful API), observation handler.
- Test dependencies in `kiroku-store.cabal` `test-suite kiroku-store-test`: `aeson`, `async`, `effectful-core`, `ephemeral-pg`, `generic-lens`, `hasql`, `hasql-pool`, `hspec`, `kiroku-store`, `lens`, `stm`, `text`, `uuid`, `vector`.
- `kiroku-store/bench/Main.hs` (184 lines) — tasty-bench-based; covers append (single, batch-10, batch-100, sequential), read (stream forward, $all forward), category, plus an embedded pool-saturation wall-clock measurement (B9). The B9 measurement is *not* a tasty-bench benchmark — it runs in `main` and prints to stdout.
- `kiroku-store/bench/ShibuyaOverhead.hs` (289 lines) — measures the overhead of routing through the shibuya adapter.
- `kiroku-store/bench/sql/` — a SQL-level benchmark suite from the original Track 1 implementation phase. Contains numbered `bench_*.sql` files runnable via `run_benchmarks.sh`.
- `kiroku-store/bench/results/` — timestamped output files from previous runs, including SQL-level (`sql_bench_*.txt`), Haskell M3 (`haskell_bench_m3_20260322.txt`), and adapter overhead (`shibuya_adapter_overhead_20260324.txt`).
- `kiroku-store/bench/Kiroku/Bench/` — empty subdir (placeholder).
- `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, `docs/BENCH-SQL-BASELINE.md` — narrative reports on each benchmarking gate.

Existing test patterns to preserve:

- `withTestStore :: (KirokuStore -> IO ()) -> IO ()` is the per-test bracket.
- `makeEvent :: Text -> Value -> EventData` is the event-construction helper.
- `waitWithTimeout :: Int -> SubscriptionHandle -> IO (Either String (Either SomeException ()))` is the subscription timeout helper.

Synchronization patterns currently in use that this plan replaces:

- `threadDelay 100_000` (100ms) — used to wait for a subscription to enter live mode before appending events.
- `threadDelay 200_000` (200ms) — used to wait for the EventPublisher to process events before subscribing.

These are heuristic. A better approach uses STM barriers: e.g. an `MVar ()` set inside a handler invocation to confirm the subscription is live, or a `TVar Int` counter that the handler increments to coordinate with the test thread.

Cross-plan dependencies of this plan:

- EP-1 produces CTE-correctness invariants; this plan turns them into properties.
- EP-2 produces API-contract changes (multi-stream attribution, refined `StoreError`, `withSubscription`); this plan adds tests for each.
- EP-3 produces subscription-system fixes (Category live filter, backpressure, at-least-once contract); this plan adds property and deterministic tests for each.
- EP-4 produces multi-tenancy guidance; this plan adds tests if EP-4 chose option (A) wire-through.
- EP-5 produces failure-injection harness requirements; this plan implements them.


## Plan of Work

### Milestone 1 — Gap inventory

Goal: produce a structured inventory of (a) what existing tests cover, (b) what invariants are missing, (c) what concurrency scenarios need deterministic synchronization, (d) what failure-injection scenarios are needed (cross-plan EP-5), (e) what stress benchmarks are needed.

What will exist at the end:

- An "Existing Coverage Map" section in this plan's Surprises & Discoveries, mapping each public function to the existing tests that cover it and the gaps.
- An "Invariant List" section, derived from EP-1 through EP-5, naming each invariant the property suite should assert.
- A "Concurrency Scenarios" section listing every scenario that should be deterministic-tested.
- A "Failure-Injection Scenarios" section coordinated with EP-5.
- A "Benchmark Gaps" section listing scenarios beyond Gate 3.

Verification: every public function in `Kiroku.Store` has a coverage entry; every invariant from upstream plans has an entry.

### Milestone 2 — Land tests and benchmarks

Goal: implement the inventory's recommendations.

Specific items expected:

- Add `hedgehog` and `hspec-hedgehog` to `kiroku-store.cabal`'s test-suite dependencies.
- Create a new test module structure. Currently everything is in `kiroku-store/test/Main.hs`. Split into:
  - `Main.hs` — the hspec entry point.
  - `Test/Append.hs` — append-specific tests (preserves existing scenarios; adds property tests).
  - `Test/Read.hs` — read tests.
  - `Test/Link.hs` — link tests.
  - `Test/Lifecycle.hs` — soft/hard/undelete tests.
  - `Test/Subscription.hs` — subscription tests with deterministic synchronization.
  - `Test/Properties.hs` — `hedgehog` properties for cross-cutting invariants.
  - `Test/Concurrency.hs` — multi-stream and concurrent-access scenarios.
  - `Test/FailureInjection.hs` — listener-disconnect, pool-exhaustion, slow-handler.
  - `Test/Helpers.hs` — `withTestStore`, `makeEvent`, `waitWithTimeout`, plus new helpers (`waitForSubscriptionLive`, `STM` barriers).
- Replace every `threadDelay` in subscription tests with an STM barrier.
- Add property tests:
  - "After any sequence of N appends and M lifecycle events, the events table has no orphans" (one event row per `stream_events` row in `$all`).
  - "Global positions are contiguous from 1 to count(*) on `$all`".
  - "After an `appendToStream` followed by `readStreamForward` from version 0, the read returns the appended events in order".
  - "Idempotent retry of an exact-version append with the same caller-supplied event ids returns `DuplicateEvent`, not `WrongExpectedVersion`".
  - "After `softDeleteStream`, no `appendToStream`, `readStreamForward`, or `readStreamBackward` against the stream succeeds (until `undeleteStream`)".
- Add concurrency tests:
  - Two concurrent `appendToStream` calls to different streams both succeed; the global positions are interleaved but contiguous.
  - Two concurrent `appendToStream` calls to the same stream with `ExactVersion 0` — exactly one wins; the other returns `WrongExpectedVersion`.
  - Two concurrent `appendMultiStream` calls touching streams in opposite order — outcome documented (deadlock, retry, or fix-landed).
- Add failure-injection tests (coordinated with EP-5):
  - A test that deliberately closes the listener's connection (e.g. via a separate admin connection issuing `pg_terminate_backend`) and asserts the Notifier reconnects within the documented window.
  - A test that drains the pool by holding all connections in long-running queries and asserts `appendToStream` returns the appropriate error.
  - A test with a deliberately slow handler that asserts the chosen subscriber-overflow policy (cross-plan with EP-3).
- Add stress benchmarks:
  - Sustained throughput at 32 concurrent writers across 1024 unique streams for 30 seconds; record p50/p95/p99 latency.
  - Subscription replay: subscribe to `$all` after appending 100K events; measure catch-up time.
  - Large-payload append: 10KB JSONB payloads, 100 events per batch.
- Establish a baseline-regression workflow: a script (or Justfile target) that runs `cabal bench` and compares against a checked-in baseline file (`kiroku-store/bench/results/baseline.csv`); flags regressions over a configurable threshold (default 5%).

What will exist at the end: green test suite with property tests, deterministic concurrency tests, and failure-injection tests. A new structured bench suite. A documented baseline-regression workflow. Updated `kiroku-store.cabal` with new test dependencies. Updated test files split per the structure above. The MasterPlan's Exec-Plan Registry status updated.


## Concrete Steps

### Milestone 1 commands

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    cabal build kiroku-store
    cabal test kiroku-store
    cabal bench kiroku-store:kiroku-store-bench

Read these files in full:

- `kiroku-store/test/Main.hs` (887 lines)
- `kiroku-store/bench/Main.hs` (184 lines)
- `kiroku-store/bench/ShibuyaOverhead.hs` (289 lines)
- `kiroku-store/kiroku-store.cabal`
- `docs/BENCH-GATE3.md`
- `docs/BENCH-HASKELL-APPEND.md`
- `docs/BENCH-SQL-BASELINE.md`

Survey existing test scenarios. For each public function (using `cabal repl kiroku-store` and `:browse Kiroku.Store`), list the tests in `Main.hs` that cover it. Identify gaps.

### Audit Checklist

Existing test coverage:
- For every public function, list the tests in `Main.hs` that cover it. Identify any function with zero tests and surface as a gap.
- For every documented behavior in Haddocks (post-EP-2), list the tests that demonstrate it.
- For every error constructor, list the tests that exercise the path that produces it.

Concurrency scenarios needing deterministic tests:
- Two concurrent appends to different streams → both succeed, contiguous global positions.
- Two concurrent appends to the same stream with `ExactVersion 0` → one wins.
- Two concurrent `appendMultiStream` calls with overlapping streams in opposite orders → outcome documented.
- Subscription concurrent with hot writes → no events lost, no events duplicated within a single subscription instance (subject to at-least-once contract).
- Multiple subscriptions to `$all` → each receives the same events.
- Subscription cancel during `processEvents` → handler may have processed up to N-1 events; checkpoint reflects last batch boundary.

Property invariants:
- `length stream_events = 2 * count_of_appended_events + count_of_linked_events` after any sequence (every event has at least 2 stream_events rows: source + $all; linked events add one row each).
- `count(*) FROM stream_events WHERE stream_id = 0` equals the global position cursor.
- For every event in `events`, every row in `stream_events` referencing it has `original_stream_id` and `original_stream_version` consistent.
- After `hardDeleteStream`, no rows in `events` remain that have no `stream_events` rows pointing at them (orphan-protection).
- Lifecycle: `softDelete; undelete` returns to identical state; `softDelete; softDelete` returns `(Just, Nothing)`; `softDelete; hardDelete` removes the stream.
- For any sequence of `appendToStream` calls with caller-supplied event ids, each id is unique → all succeed; any id is duplicated → exactly the duplicate fails with `DuplicateEvent`.

Failure-injection scenarios:
- Listener connection killed via admin `pg_terminate_backend` → reconnect within X seconds; events appended during the down window are delivered via safety poll.
- Pool exhausted → 11th concurrent caller (with pool size 10) gets `PoolAcquisitionTimeout` (cross-plan EP-2).
- Slow handler overflows subscriber queue → policy fires (cross-plan EP-3).
- Database paused mid-append → `Pool.use` returns `Left ConnectionUsageError`; consumer gets `ConnectionError` or refined variant.
- Schema initialization on a database where `uuidv7()` is unavailable → fails with a clear error.

Stress benchmark gaps:
- Multi-writer concurrent stress: 32 writers × 1000 appends to unique streams; measure throughput and latency distribution.
- Subscription catch-up time at 100K, 1M, 10M events.
- Large-payload performance: 10KB and 100KB JSONB payloads.
- Sustained-throughput soak test (no leak): 1M events in a loop; measure steady-state memory.

Baseline regression:
- Decide which benchmark numbers are the canonical baseline. Probable: B8 from `docs/BENCH-GATE3.md`.
- Write the baseline values into `kiroku-store/bench/results/baseline.csv` or similar.
- Add a CI-friendly script that compares current output against baseline.

### Milestone 2 commands

For each batch of new tests:

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    # 1. Add the new module(s)
    $EDITOR kiroku-store/test/Test/Properties.hs
    $EDITOR kiroku-store/kiroku-store.cabal       # add hedgehog dep, list new modules
    cabal build kiroku-store-test
    cabal test kiroku-store
    # 2. Commit (one focused commit per test family)
    git commit -m "test: <one-line summary>

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/6-test-and-benchmark-hardening-for-production-confidence.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"

For the test-module split, do it in one commit (or a small sequence of commits, each leaving the test suite green).

For the baseline-regression workflow:

    $EDITOR Justfile          # add `just bench-regression` target
    $EDITOR kiroku-store/bench/results/baseline.csv
    git commit -m "bench: establish baseline-regression workflow

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/6-test-and-benchmark-hardening-for-production-confidence.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"


## Validation and Acceptance

Milestone 1 is complete when the inventory sections (Existing Coverage Map, Invariant List, Concurrency Scenarios, Failure-Injection Scenarios, Benchmark Gaps) are filled in.

Milestone 2 is complete when:

- `cabal build kiroku-store-test` succeeds with the new module structure and dependencies.
- `cabal test kiroku-store` passes including all new property and deterministic tests.
- `cabal bench kiroku-store:kiroku-store-bench` runs all stress benchmarks and produces a current-run output file.
- The baseline-regression workflow exists and can be invoked (e.g. `just bench-regression`) and reports pass/fail vs. the checked-in baseline.
- The MasterPlan's Exec-Plan Registry status for EP-6 is "Complete".

Acceptance behaviours that a human can verify:

- Run `cabal test kiroku-store` and observe property tests reporting (e.g.) "Property: no orphan events after 100 random operations" with explicit shrunk counterexamples on failure.
- Run `cabal test kiroku-store` and observe subscription tests no longer mention `threadDelay` in the source — synchronization is via named STM barriers.
- Run `cabal bench kiroku-store:kiroku-store-bench` and observe the new stress benchmarks produce numerical output.
- Run `just bench-regression` (or equivalent) and observe a green/red verdict against the baseline.


## Idempotence and Recovery

The work is additive. Each commit must keep the test suite green. The test-module split should be a single commit (or a small atomic sequence) that does not leave half the tests in the old file and half in the new file.

If a property test surfaces a real bug, surface it as a cross-plan finding to the responsible plan (EP-1, EP-2, EP-3, etc.) rather than landing the fix here. This plan's Decision Log records the surfacing.

If a benchmark regresses against the baseline, do not commit; investigate. The root cause must be either a real regression (fix or revert) or a justified change (update the baseline with rationale).


## Interfaces and Dependencies

Files this plan modifies:

- `kiroku-store/kiroku-store.cabal` — add `hedgehog`, `hspec-hedgehog` to test-suite dependencies. List new test modules.
- `kiroku-store/test/Main.hs` — restructured into a thin entry point; existing tests moved into per-concern modules.
- `kiroku-store/test/Test/*.hs` — new module structure.
- `kiroku-store/bench/Main.hs` — extended with stress benchmarks; possibly restructured to surface B9 as a tasty-bench benchmark.
- `kiroku-store/bench/results/baseline.csv` — new file.
- `Justfile` — new `bench-regression` target.

Files this plan does *not* modify:

- Any source under `kiroku-store/src/` — owned by the upstream plans (EP-1 through EP-5).

External dependencies. Adds `hedgehog` and `hspec-hedgehog` to test-only dependencies. No new runtime dependencies.

Cross-plan integration:

- EP-1 owns CTE invariants; EP-6 turns them into properties.
- EP-2 owns API contracts; EP-6 adds tests as those land.
- EP-3 owns subscription contracts; EP-6 adds deterministic tests for the at-least-once semantics and the bounded-backpressure policy.
- EP-4 owns multi-tenancy; if EP-4 lands option (A), EP-6 adds multi-tenancy tests.
- EP-5 owns failure-injection requirements; EP-6 implements them.

Module-level interface contracts:

- `kiroku-store/test/Test/Helpers.hs` — owned by this plan; provides `withTestStore`, `makeEvent`, `waitWithTimeout`, plus new STM-barrier helpers.
- `kiroku-store/bench/results/baseline.csv` — owned by this plan; updates require Decision Log justification.
