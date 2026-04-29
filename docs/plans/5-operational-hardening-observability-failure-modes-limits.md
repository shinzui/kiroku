---
id: 5
slug: operational-hardening-observability-failure-modes-limits
title: "Operational hardening: observability, failure modes, limits"
kind: exec-plan
created_at: 2026-04-29T14:06:28Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/1-production-readiness-review-of-kiroku-store.md"
---

# Operational hardening: observability, failure modes, limits

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`kiroku-store` is a long-lived in-process component: it holds a connection pool, a dedicated LISTEN connection, an event-publisher thread, and one worker thread per active subscription. When something goes wrong in production — the database is briefly unreachable, a slow subscriber backs up the publisher, the pool is saturated, a hard-delete contends with concurrent reads — operators need actionable signals to triage and respond. The current observability surface is one optional `observationHandler :: Maybe (Observation -> m ())` callback (`Connection.hs:38-39`) wired only to `hasql-pool` connection-lifecycle events. There is no structured logging path, no subscriber-lag metric, no publisher-queue-depth metric, no append-latency histogram, no failure-injection harness, and no documented operational tuning guide.

After this plan, the package has a written audit of every failure mode (database disconnection, NOTIFY drop, slow subscriber, pool exhaustion, hard-delete-vs-concurrent-write, schema-init failure on startup, etc.); a published list of operational signals callers can subscribe to (event types and the data they carry); a failure-injection harness for the test suite (so that every documented failure mode has at least one test exercising it); and a documented "Production Tuning" guide that names every tunable (pool size, idle timeout, batch sizes, safety-poll intervals, queue capacities) with operational guidance on each.

A reader can verify the change by reading the new audit and tuning documents, running `cabal test kiroku-store` (the failure-injection tests), and writing a small consumer program against the new observation surface to confirm signals fire as expected.


## Progress

- [ ] Milestone 1: Failure-mode and observability gap inventory
  - [ ] Catalog every failure mode the package can encounter (DB-side, network-side, application-side)
  - [ ] For each, record what currently surfaces to the caller (error, exception, silent retry, log) and what *should* surface
  - [ ] Inventory every existing observability hook and identify gaps
  - [ ] Identify every tunable and document its current default and acceptable range
- [ ] Milestone 2: Land hardening changes
  - [ ] Extend the observation/event surface (callbacks or an event-emitter type) to cover identified gaps
  - [ ] Add a failure-injection harness in the test suite (or coordinate with EP-6)
  - [ ] Write the Production Tuning guide
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

(None yet. The findings document produced in Milestone 1 will be reflected here.)

Initial leads identified during MasterPlan research:

- The Notifier silently swallows connection failures and reconnects after 1 second (`Notification.hs:67-79`). No signal to the caller. Severity: must-fix.
- The EventPublisher silently swallows pool errors during `fetchAndBroadcast` (`EventPublisher.hs:107-110`); the 30-second safety poll is the only recovery path. No signal. Severity: must-fix.
- No metric for: append latency, append throughput, read latency, subscription catch-up lag, subscription live-mode lag, publisher batch size, NOTIFY rate, pool acquisition wait time. The `observationHandler` covers only pool connection lifecycle. Severity: should-fix; many are easy.
- The `idleInTransactionTimeout` is configurable (default 30s), but `statement_timeout` is not. A long-running query can hold a pool connection indefinitely. Severity: should-fix; consider adding a `statementTimeout` field on `ConnectionSettings`.
- Pool saturation behaviour is documented in `docs/BENCH-GATE3.md` (B9): 64 writers × 100 appends, pool size 10, throughput 1262 ops/s, ~0.79ms avg latency. Document this as a known limit. Operational guidance: set pool size relative to writer concurrency.
- The `EventPublisher` polls every 30s as a safety net. Latency under a fully-broken NOTIFY scenario is up to 30s. Document.
- No log emission anywhere. Every error is either thrown or returned in a Left. Severity: a callback-based or `co-log`-style logging hook should be considered.


## Decision Log

- Decision: Treat observability as a callback-based extension API (consistent with the existing `observationHandler` pattern) rather than depending on a logging framework. Callers wire `co-log`, `katip`, `prometheus-client`, etc., on top.
  Rationale: Library-level logging frameworks lock callers into a logging stack. Callbacks are minimal-commitment and easy to thread.
  Date: 2026-04-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The reader is assumed to have only the working tree and this file.

`kiroku-store` is a Haskell PostgreSQL event-store library. Long-lived components include:

- A `Hasql.Pool.Pool` (default size 10) for application reads/writes. Lifecycle events (acquire/release/connect/disconnect) are surfaced via the optional `observationHandler` callback in `ConnectionSettings`.
- A dedicated `Hasql.Connection.Connection` for LISTEN/NOTIFY (`Notification.hs`). On any exception (other than `AsyncCancelled`), the listener thread waits 1 second and reconnects.
- An `EventPublisher` thread (`Subscription/EventPublisher.hs`) that wakes on a NOTIFY tick or a 30-second safety poll, fetches new events from the database, and broadcasts to subscribers.
- One `Worker` thread per active subscription (`Subscription/Worker.hs`).
- An optional `observationHandler :: Observation -> m ()` callback wired to `hasql-pool`'s observation API (`Hasql.Pool.Observation`). The `Observation` type is re-exported from `Kiroku.Store.Subscription.EventPublisher` (actually from `hasql-pool` via `Kiroku.Store`'s re-exports at lines 26-32 of `Store.hs`). Observation events from `hasql-pool` include connection-establishment, connection-readiness-for-use, and connection-termination, with reasons.

Existing tunables, all on `ConnectionSettings`:

- `connString :: Text` — required.
- `poolSize :: Int` — default 10.
- `schema :: Text` — default `"public"`. (See EP-4 for the actual contract.)
- `idleInTransactionTimeout :: Int` — default 30s. Set via `SET idle_in_transaction_session_timeout` in `initSession`.
- `observationHandler :: Maybe (Observation -> m ())` — default `Nothing`.

Other internal tunables (not exposed on the public API):

- `Subscription/EventPublisher.publisherBatchSize = 1000` — number of events fetched per round.
- `Subscription/EventPublisher.safetyPollMicros = 30_000_000` — the 30-second safety poll.
- `Subscription/Worker` — `batchSize` is on `SubscriptionConfig` (default not provided; tests use 100). Catch-up uses this; live mode reads single broadcast vectors.

Existing benchmarks reside under `kiroku-store/bench/` and produce results in `kiroku-store/bench/results/`. Notable: `B9` in `docs/BENCH-GATE3.md` is the pool-saturation benchmark, showing 64 writers × 100 appends → 1262 ops/s with pool size 10.

Failure paths visible in the source:

- `Pool.use pool` returns `Either UsageError a`; `UsageError` is `SessionUsageError`, `ConnectionUsageError`, or `AcquisitionTimeoutUsageError`. Currently mapped to `StoreError.ConnectionError !Text` (a single bag — see EP-2 for refinement).
- `runStorePool` handles `Left _err` by either throwing `StoreError` or returning a default (e.g. soft-deleted-stream check returns `pure V.empty` on error). The publisher's pool error is silently dropped.
- `Notification.acquireOrFail` calls `fail` on initial-acquire failure, which propagates as `IOException` from `withStore`.
- `Pool.acquire` does not appear to fail (it returns `IO Pool` synchronously).


## Plan of Work

### Milestone 1 — Failure-mode and observability gap inventory

Goal: produce a structured catalog of every failure mode and every observability gap, classified by severity and named by data the operator wants.

What will exist at the end:

- A "Failure Mode Catalog" section in this plan's Surprises & Discoveries, listing every failure mode with: trigger condition, current behaviour, current observability, recommended observability, severity.
- A "Tunable Inventory" section listing every tunable (public and internal) with: current default, acceptable range, recommended setting for typical production deployments.
- A "Recommended Observation Surface" section enumerating every event the package should emit, the data each event carries, and the recommended consumer-side handling.

Verification: every component (`Connection.hs`, `Schema.hs`, `Notification.hs`, `Subscription/*`, `Effect.hs`) is represented in the catalog by at least one failure mode (or a "no failure modes identified" entry).

### Milestone 2 — Land hardening changes

Goal: extend the observation surface to cover the gaps identified, add a failure-injection harness, and publish the Production Tuning guide.

Specific items expected (subject to confirmation in Milestone 1):

- Extend `ConnectionSettings` with: `statementTimeout :: Maybe Int` (seconds; default `Nothing`); per-tunable internal-publisher / safety-poll fields if the audit recommends them. Coordinate with EP-2.
- Extend the observation handler or add a separate callback (e.g. `eventHandler :: Maybe (KirokuEvent -> m ())`) for: notifier-reconnect events, publisher-pool-error events, subscriber-overflow events (cross-plan with EP-3), append-error events (above the bagged `StoreError`). Decide between extending `Observation` (re-export from hasql-pool) and introducing a `KirokuEvent` sum type. Recommend the latter.
- Add a failure-injection harness. The minimum viable harness:
  - A test scenario that drops the LISTEN connection mid-subscription and asserts the subscription recovers.
  - A test scenario that exhausts the pool and asserts a clear error type is returned (cross-plan with EP-2's `PoolAcquisitionTimeout`).
  - A test scenario that runs a slow handler and asserts the chosen subscriber-overflow policy fires (cross-plan with EP-3's bounded backpressure decision).
- Write a `docs/PRODUCTION-TUNING.md` (or extend an existing operational doc) covering: pool size guidance (relative to writer concurrency and the documented 5K-batch/s ceiling); statement_timeout guidance; subscription batch size guidance; what to monitor and what to alert on; how to interpret each `Observation` and `KirokuEvent`.

What will exist at the end: green build with new failure-injection tests; a Production Tuning guide; a `KirokuEvent` callback (or the chosen alternative) that consumers can wire to their preferred logging or metrics stack.


## Concrete Steps

### Milestone 1 commands

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    cabal build kiroku-store
    cabal test kiroku-store
    # Inventory tunables — search for every constant or magic number in the codebase:
    grep -rn 'safetyPollMicros\|publisherBatchSize\|poolSize\|idleInTransactionTimeout\|threadDelay\|registerDelay\|batchSize' kiroku-store/src/

Files to read in full:

- `kiroku-store/src/Kiroku/Store/Connection.hs` (103 lines)
- `kiroku-store/src/Kiroku/Store/Schema.hs` (39 lines)
- `kiroku-store/src/Kiroku/Store/Notification.hs` (88 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` (140 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (167 lines)
- `kiroku-store/src/Kiroku/Store/Effect.hs` (293 lines)
- `kiroku-store/src/Kiroku/Store/Error.hs` (126 lines)
- `kiroku-store/test/Main.hs` (887 lines) — for the `observationHandler` test at lines 836-851 (the only existing test for observability)
- `docs/BENCH-GATE3.md` — for the existing pool-saturation analysis

### Audit Checklist

Failure modes:
- Database unreachable at startup: `Pool.acquire` does not fail (it's lazy); `initializeSchema` will fail when the first connection attempt happens. Document the resulting exception and the consumer's handling.
- Database becomes unreachable mid-operation: `Pool.use` returns `Left ConnectionUsageError`. The `usePool` helper maps this to `StoreError.ConnectionError`. Confirm.
- Pool acquisition timeout: `Pool.use` returns `Left AcquisitionTimeoutUsageError`. Mapped to `ConnectionError "Connection pool acquisition timeout"`. Cross-plan with EP-2 for the dedicated constructor.
- LISTEN connection dies: 1-second sleep then reconnect (`Notification.hs:73-79`). NO signal. Add a callback.
- Schema-initialization failure (e.g. missing extension `pgcrypto`/uuidv7 not available): `initializeSchema` throws `SchemaInitError UsageError`. Confirm; document.
- `notify_events` trigger fails (e.g. malformed payload): the trigger raises an exception and the source append CTE is rolled back. Verify.
- Hard-delete contended with concurrent append: trace the locks. Confirm one waits or one fails.
- Long-running query: no `statement_timeout`; pool connection blocked indefinitely. Recommend adding `statementTimeout`.
- Slow subscriber: per-subscriber `dupTChan` grows unbounded. Cross-plan with EP-3.
- Catch-up phase, very large gap: the worker queries in batches of `batchSize` until it reaches `pubPosVar`. Quantify time-to-catch-up at typical event rates; document.
- Handler exception: worker thread dies; `wait` returns `Left e`. Document.
- Schema concurrent-startup race: two processes call `initializeSchema` simultaneously. The DDL is `CREATE ... IF NOT EXISTS` and `CREATE OR REPLACE ...`. The `INSERT INTO streams ...` and `setval` are conditional/idempotent. Verify there is no race.
- Disk-full / quota / replication-lag (replica reads): out of scope for this audit, but document at the boundary.

Tunables:
- Each of `poolSize`, `idleInTransactionTimeout`, `publisherBatchSize`, `safetyPollMicros`, `SubscriptionConfig.batchSize` — record default, justification, range, recommended production values.
- Identify tunables that should be public but aren't (`safetyPollMicros`, `publisherBatchSize`).
- For each public tunable, write a Haddock paragraph.

Existing observability:
- `observationHandler :: Maybe (Observation -> m ())` — covers what? Read `Hasql.Pool.Observation` documentation (or `mori registry docs hasql:hasql-pool` if available). The events are connection lifecycle: acquire, ready-for-use, terminate.
- The test at `Main.hs:836-851` confirms the handler fires during normal operations. Confirm it does not fire on failures the operator cares about (e.g. statement-level errors).
- No subscription-level observability. Add.
- No statement-level observability (per-query latency, error rate). Decide whether to add.

Observation surface design:
- Decide between extending `hasql-pool`'s `Observation` (limited; not extensible) and introducing a `KirokuEvent` sum type. Recommend the latter:

        data KirokuEvent
            = KirokuEventNotifierReconnecting !SomeException
            | KirokuEventNotifierReconnected
            | KirokuEventPublisherPoolError !UsageError
            | KirokuEventPublisherSafetyPollFired
            | KirokuEventSubscriberOverflow !SubscriptionName !Int
            | KirokuEventSubscriptionStarted !SubscriptionName !GlobalPosition
            | KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition
            | KirokuEventSubscriptionStopped !SubscriptionName !GlobalPosition
            | KirokuEventSubscriptionFailed !SubscriptionName !SomeException
            | KirokuEventHardDeleteIssued !StreamName

  This is a starter list; the audit refines it. The existing `observationHandler` continues to cover pool events.

Production tuning:
- Pool size: at the documented 5K batches/s `$all` ceiling, pool size > 32 buys diminishing returns. Recommend size = max(2, expected_concurrent_writers).
- `idleInTransactionTimeout`: keep default 30s for application reads/writes; raise if long-lived transactions are expected.
- `statementTimeout`: recommend setting it to ~10x median append latency, so pathological queries fail fast.
- Subscription batch size: 100 is the test default. Higher reduces per-event overhead; lower improves handler responsiveness to `Stop`.

### Milestone 2 commands

For each landed change:

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    # 1. Add the observability hook or test
    $EDITOR kiroku-store/src/Kiroku/Store/Connection.hs   # KirokuEvent type, eventHandler field
    $EDITOR kiroku-store/src/Kiroku/Store/Notification.hs  # emit reconnect events
    $EDITOR kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs  # emit pool-error events
    # 2. Add a failure-injection test
    $EDITOR kiroku-store/test/Main.hs
    cabal test kiroku-store
    # 3. Commit
    git commit -m "feat(observability): <one-line summary>

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/5-operational-hardening-observability-failure-modes-limits.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"

For the Production Tuning guide:

    $EDITOR docs/PRODUCTION-TUNING.md
    git add docs/PRODUCTION-TUNING.md
    git commit -m "docs: add production tuning guide

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/5-operational-hardening-observability-failure-modes-limits.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"


## Validation and Acceptance

Milestone 1 is complete when:

- The Failure Mode Catalog covers every component listed in the Audit Checklist with severity classification.
- The Tunable Inventory enumerates every public and internal tunable.
- The Recommended Observation Surface lists every event the audit thinks should be emitted.

Milestone 2 is complete when:

- A `KirokuEvent` (or chosen alternative) sum type exists and is wired to the relevant emit sites.
- The failure-injection test scenarios pass: (a) listener-disconnect-and-recover, (b) pool-exhaustion, (c) slow-handler.
- `docs/PRODUCTION-TUNING.md` exists with pool-size, statement_timeout, batch-size, monitoring, and alerting guidance.
- `cabal test kiroku-store` passes with the new tests.
- The MasterPlan's Exec-Plan Registry status for EP-5 is "Complete".

Acceptance behaviours that a human can verify:

- Wire the new `KirokuEvent` callback to `print` in a small test program; kill the database server's connection mid-subscription; observe a `KirokuEventNotifierReconnecting` event followed by a `KirokuEventNotifierReconnected` (or equivalent) event when connectivity is restored. Before the change, no signal fires.
- Run a producer that exceeds the documented pool ceiling; observe pool-acquisition errors are surfaced as the dedicated constructor (cross-plan with EP-2) and that the failure-injection test asserts this.
- Read `docs/PRODUCTION-TUNING.md` and confirm it answers: "What pool size do I set?", "What is `statement_timeout` and should I set it?", "What metrics should I scrape?", "What alerts should I configure?"


## Idempotence and Recovery

The audit milestone is read-only. The fix milestone produces commits — each must keep the test suite green.

If a hardening change requires a breaking API change (e.g. adding a new field to `ConnectionSettings`), coordinate with EP-2 before landing. If it requires a new SQL statement (unlikely), coordinate with EP-1.

If the Production Tuning guide depends on benchmark numbers that this audit does not reproduce, run the relevant benchmarks via `cabal bench kiroku-store:kiroku-store-bench` and capture the output as evidence in Surprises & Discoveries.


## Interfaces and Dependencies

Files this plan modifies:

- `kiroku-store/src/Kiroku/Store/Connection.hs` — add `KirokuEvent`, add `eventHandler` field on `ConnectionSettings` (or extend `observationHandler`), possibly add `statementTimeout`. Coordinate with EP-2 (public types).
- `kiroku-store/src/Kiroku/Store/Notification.hs` — emit reconnect events.
- `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` — emit pool-error and queue-depth events. Coordinate with EP-3.
- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — emit subscription lifecycle events. Coordinate with EP-3.
- `kiroku-store/test/Main.hs` — failure-injection scenarios. Coordinate with EP-6.
- `docs/PRODUCTION-TUNING.md` — new file.
- `kiroku-store/bench/Main.hs` — possibly extended with new pool-saturation scenarios. Coordinate with EP-6.

Files this plan does not modify:

- `kiroku-store/sql/schema.sql` — owned by EP-1.
- `kiroku-store/src/Kiroku/Store/SQL.hs` — owned by EP-1.
- `kiroku-store/src/Kiroku/Store/Error.hs` — owned by EP-2.

External dependencies. None new (the failure-injection harness can use `network`-level tricks like closing the listener connection's underlying socket, or we can simulate via `Async.cancel` of the listener thread).

Module-level interface contracts:

- `Kiroku.Store.Connection.ConnectionSettings` — owned by EP-2 in shape; this plan adds fields with EP-2's coordination.
- A new `Kiroku.Store.Observability` module (if introduced) is owned by this plan.
