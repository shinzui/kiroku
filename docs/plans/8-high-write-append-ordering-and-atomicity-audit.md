---
id: 8
slug: high-write-append-ordering-and-atomicity-audit
title: "High-write append ordering and atomicity audit"
kind: exec-plan
created_at: 2026-05-06T20:42:40Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/2-focused-event-store-reliability-and-scale-audit.md"
---

# High-write append ordering and atomicity audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan proves that writes to `kiroku-store` preserve the event-store ordering contract under high concurrency. After it is complete, a maintainer can run focused stress tests and see that every successful append path produces gap-free per-stream versions, gap-free `$all` global positions, no duplicate positions, and no partial commits when a transaction fails.

The outcome is not just "more tests." The outcome is a written reliability verdict for the append layer plus any code fixes needed to make that verdict true. The most important human-visible behavior is that readers and subscribers can trust event order even when many writers append at once.


## Progress

- [x] 2026-05-06: Audited the append schema, CTEs, interpreter, and current tests for ordering assumptions.
- [x] 2026-05-06: Added high-write stress tests covering single-stream, cross-stream batch, large batch, overlapping `appendMultiStream`, and duplicate-event rollback paths.
- [x] 2026-05-06: Classified findings as no must-fix append correctness issues found; permanent regression coverage was the necessary change.
- [x] 2026-05-06: Landed regression tests; no append SQL or interpreter code changes were required.
- [x] 2026-05-06: Recorded the final append-ordering verdict and test evidence.


## Surprises & Discoveries

- Discovery: The append CTEs already serialize each successful append by taking the source stream row lock before updating the `$all` row, and `appendMultiStream` pre-locks existing source streams in deterministic `stream_id` order before running the per-stream CTEs.
  Evidence: `cabal test kiroku-store --test-options='--match "kiroku-store concurrency"'` passed 8 concurrency examples, including 24 concurrent `AnyVersion` writers to one stream, 12 concurrent 10-event batch writers to distinct streams, a 10+100 event batch sequence, 9 overlapping `appendMultiStream` transactions across 3 streams, and a duplicate-event rollback case.
  Date: 2026-05-06

- Discovery: The duplicate event-id failure path rolls back the whole `appendMultiStream` transaction, including source stream version bumps, `$all` advancement, and payload insertion for later operations in the transaction.
  Evidence: The new test `duplicate event failure leaves touched streams and $all unchanged` checks `events` row count, `$all` positions, and both touched source streams after a duplicate-id abort.
  Date: 2026-05-06


## Decision Log

- Decision: Start with a focused audit and permanent regression tests, not a benchmark-only exercise.
  Rationale: Throughput numbers can look good while ordering is wrong. Reliability requires invariant checks on the resulting rows and API reads.
  Date: 2026-05-06

- Decision: Keep the EP-1 change to regression tests only.
  Rationale: The audit and stress tests did not expose a must-fix append ordering or atomicity defect in `kiroku-store/src/Kiroku/Store/SQL.hs` or `kiroku-store/src/Kiroku/Store/Effect.hs`. Changing append SQL without a failing correctness case would add risk without improving the reliability verdict.
  Date: 2026-05-06


## Outcomes & Retrospective

EP-1 completed on 2026-05-06. `kiroku-store/test/Test/Concurrency.hs` now contains permanent high-write coverage for the append-ordering contract: many concurrent `AnyVersion` writers to one stream, many concurrent `NoStream` batch writers to distinct streams, 10-event and 100-event batch position checks, overlapping `appendMultiStream` transactions, and duplicate event-id rollback.

Final verdict: no must-fix append SQL or interpreter correctness issue was found. Successful append paths preserved contiguous per-stream versions and contiguous `$all` global positions in the audited scenarios. Failed duplicate-event writes did not leave extra `events` rows, source stream version gaps, or `$all` advancement. This verdict is bounded to append ordering and atomicity; subscription delivery remains owned by EP-3 and large-store performance remains owned by EP-4.

Validation evidence:

    cabal test kiroku-store --test-options='--match "kiroku-store concurrency"'
    8 examples, 0 failures

    cabal test kiroku-store
    91 examples, 0 failures


## Context and Orientation

`kiroku-store` is a PostgreSQL event store. A stream is a named sequence of events, represented by a row in `streams`. The reserved `$all` stream is the row with `stream_id = 0`; its `stream_version` is the global event position. The table `events` stores immutable payloads. The table `stream_events` links each event to its source stream and to `$all`, carrying `stream_version`, `original_stream_id`, and `original_stream_version`.

The schema lives in `kiroku-store/sql/schema.sql`. The critical indexes are `ix_stream_events_stream_version ON stream_events (stream_id, stream_version)` and `ix_stream_events_all_by_origin ON stream_events (original_stream_id, stream_version) WHERE stream_id = 0`. The append SQL templates live in `kiroku-store/src/Kiroku/Store/SQL.hs`: `appendExpectedVersionSQL`, `appendStreamExistsSQL`, `appendNoStreamSQL`, and `appendAnyVersionSQL`. They all follow the same structure: build `new_events`, create or update the source stream, insert payload rows, insert source stream links, update `$all`, and insert `$all` links. The public operations are exposed through `kiroku-store/src/Kiroku/Store/Append.hs` and interpreted in `kiroku-store/src/Kiroku/Store/Effect.hs`.

`appendMultiStream` in `Effect.hs` wraps multiple append CTEs in a `hasql-transaction` transaction and first calls `lockStreamsForMultiStmt`, which pre-locks existing streams in deterministic `stream_id` order to avoid row-lock deadlocks. Current concurrency coverage is in `kiroku-store/test/Test/Concurrency.hs`. It covers two concurrent appends to different streams, two concurrent `ExactVersion` appends to one stream, and opposite-order `appendMultiStream` calls. Property tests in `kiroku-store/test/Test/Properties.hs` cover small generated operation sequences, including global-position uniqueness, soft-delete barriers, and duplicate caller-supplied event ids.

Prior work matters. `docs/masterplans/1-production-readiness-review-of-kiroku-store.md` records fixes for soft-delete TOCTOU races, link gaps, multi-stream pre-locking, and hard-delete trigger protection. This plan must verify the current state after those fixes rather than rediscover them from scratch.


## Plan of Work

Milestone 1 is the append-ordering audit. Read `schema.sql`, `SQL.hs`, `Effect.hs`, `Test.Concurrency`, and `Test.Properties`. For each append path, write down the invariant it must preserve: source stream versions are contiguous for successful events, `$all` positions are contiguous for surviving events, `AppendResult.globalPosition` is the last event in the batch, failed writes do not leave payload rows or stream version gaps, and concurrent writers either serialize correctly or fail with the documented `StoreError`. Record findings in this plan's Surprises & Discoveries section.

Milestone 2 adds a high-write invariant checker. Prefer a helper in `kiroku-store/test/Test/Concurrency.hs` or `kiroku-store/test/Test/Helpers.hs` that reads raw or API-visible rows and verifies ordering after a stress run. Cover at least these scenarios: many writers appending to one stream with `AnyVersion`; many writers appending to different streams; batched appends with batch sizes 10 and 100; concurrent `appendMultiStream` calls with overlapping stream sets; and injected failures such as duplicate event ids or stale `ExactVersion` expectations mixed into a concurrent run. A failing transaction must not advance stream versions or `$all`.

Milestone 3 lands fixes for must-fix findings. If the audit finds a correctness issue in a CTE, edit only the relevant SQL template in `kiroku-store/src/Kiroku/Store/SQL.hs` and add a regression test that fails before the fix. If the issue is interpreter-level transaction handling, edit `kiroku-store/src/Kiroku/Store/Effect.hs`. Keep API changes out of this plan unless they are required to preserve ordering.

Milestone 4 records the verdict. Update this plan with the test command outputs, the number of writers/events used in stress tests, and any performance notes that should feed EP-4 at `docs/plans/10-large-store-read-path-and-index-performance-audit.md`.


## Concrete Steps

From the repository root, establish the baseline:

    cabal test kiroku-store

Expected result: the `kiroku-store-test` suite passes. If it fails before edits, record the failure in Surprises & Discoveries and decide whether it blocks the audit.

Read the current append implementation:

    sed -n '1,260p' kiroku-store/src/Kiroku/Store/Effect.hs
    sed -n '1,760p' kiroku-store/src/Kiroku/Store/SQL.hs
    sed -n '1,220p' kiroku-store/test/Test/Concurrency.hs
    sed -n '1,260p' kiroku-store/test/Test/Properties.hs

Add focused stress coverage in `kiroku-store/test/Test/Concurrency.hs` and any shared helper in `kiroku-store/test/Test/Helpers.hs`. Keep generated data bounded so the suite remains practical; the goal is deterministic invariant failure, not long soak time. If a larger soak is valuable but too slow for the default test suite, add it to `kiroku-store/bench/Main.hs` or document it for EP-4 instead.

Run the focused and full validations:

    cabal test kiroku-store --test-options='--match "kiroku-store concurrency"'
    cabal test kiroku-store

If a code fix changes append latency-sensitive code, also run:

    just bench-regression-pattern append


## Validation and Acceptance

Acceptance requires a passing test suite and a written finding verdict in this plan. The tests must demonstrate that after concurrent successful writes, `readAllForward (GlobalPosition 0)` returns a strictly ascending sequence of `GlobalPosition` values with no duplicates, and each tested source stream returns strictly ascending `StreamVersion` values starting at 1. For failed writes, the tests must show no extra `events` rows, no `$all` position advancement, and no source stream version gaps.

For `appendMultiStream`, acceptance requires both no deadlock and all-or-nothing results: every stream in a successful multi-stream transaction advances by the expected number of events, and a failed operation leaves every touched stream at its previous version.


## Idempotence and Recovery

The tests use `ephemeral-pg` through `Test.Helpers.withTestStore`, so rerunning them creates fresh temporary databases and is safe. If a stress test is flaky because of timing, convert it to use `MVar`, `STM`, or deterministic barriers before accepting it. Do not accept `threadDelay` as the primary synchronization method for ordering tests.

If a benchmark baseline changes while working on this plan, do not update `kiroku-store/bench/results/baseline.csv` here unless the performance change is a deliberate accepted tradeoff. Coordinate that update through EP-4.


## Interfaces and Dependencies

Use the existing public API from `Kiroku.Store`: `appendToStream`, `appendMultiStream`, `readStreamForward`, `readAllForward`, `runStoreIO`, `StreamName`, `ExpectedVersion`, `StreamVersion`, and `GlobalPosition`. Use `Control.Concurrent.Async` for concurrent writers and existing `Test.Helpers.withTestStore` for the database fixture.

Do not add new library dependencies unless there is no practical way to express the stress scenario with the existing test stack (`hspec`, `hedgehog`, `async`, `stm`, `vector`, and `hasql-pool`). Any new dependency must be added to `kiroku-store/kiroku-store.cabal` and justified in the Decision Log.
