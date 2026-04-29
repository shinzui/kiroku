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

- [x] Milestone 1: Failure-mode and observability gap inventory (2026-04-29)
  - [x] Catalog every failure mode the package can encounter (DB-side, network-side, application-side)
  - [x] For each, record what currently surfaces to the caller (error, exception, silent retry, log) and what *should* surface
  - [x] Inventory every existing observability hook and identify gaps
  - [x] Identify every tunable and document its current default and acceptable range
- [ ] Milestone 2: Land hardening changes
  - [ ] Introduce `KirokuEvent` sum type and `eventHandler` field on `ConnectionSettings`
  - [ ] Wire emit sites for must-fix findings F1–F5 (Notifier reconnect, publisher pool error, worker checkpoint/fetch/save errors)
  - [ ] Add `statementTimeout` field on `ConnectionSettings` and wire into `initSession` (F8)
  - [ ] Replace Notifier's fixed 1-second reconnect delay with capped exponential backoff (F7)
  - [ ] Promote `Notifier.acquireOrFail` startup error from `IOException` to a structured `NotifierStartError` (F6)
  - [ ] Add subscription-lifecycle events (started, caught-up, stopped, failed) (F14)
  - [ ] Add hard-delete observation event (F13, cross-plan with EP-4.F6)
  - [ ] Add failure-injection regression test: listener-disconnect-and-recover emits expected events
  - [ ] Write `docs/PRODUCTION-TUNING.md` (F16)
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

### Milestone 1 audit (2026-04-29) — 18 findings

The audit reads `Connection.hs`, `Schema.hs`, `Notification.hs`,
`Subscription/EventPublisher.hs`, `Subscription/Worker.hs`,
`Subscription/Effect.hs`, `Subscription.hs`, `Subscription/Stream.hs`,
`Effect.hs`, `Error.hs`, and `Lifecycle.hs`. It also reads
`docs/PRODUCTION-DEPLOYMENT.md` (produced by EP-4) to avoid duplicating
what is already documented and to identify the gaps that document
explicitly leaves to EP-5.

Findings are numbered F1–F18 (EP-5 numbering — distinct from EP-1's,
EP-2's, EP-3's, and EP-4's F-numbers). Severity values: must-fix
(silent failures with no operator signal that can hide data loss,
silent re-processing, or unbounded wait), should-fix (improves
operability with bounded blast radius if not landed), deferred-with-rationale
(would require non-trivial work and ships safely without).

#### Group A — Notifier silent failures (must-fix)

* **F1 (must-fix). Notifier reconnect emits no signal.**
  `Notification.hs:90-122` `listenerLoop` catches every
  non-`AsyncCancelled` exception, releases the dead connection, sleeps
  one second, and reconnects via `bracketOnError`. None of the four
  observable transitions (listener-down, reconnect-attempt-started,
  reconnect-succeeded, reconnect-failed-and-will-retry) reaches the
  caller. An operator with the database briefly unreachable for
  fifteen minutes sees no signal at all; subscriptions appear to
  freeze and then silently resume when the database comes back. The
  store's `observationHandler` does not cover the dedicated listener
  connection — that connection is owned by `Notification.hs`
  directly via `Hasql.Connection`, not by `hasql-pool`. *Cross-plan
  origin:* this is the same gap surfaced as EP-3.F3, routed to EP-5
  for the unified observation surface.

#### Group B — EventPublisher silent failures (must-fix)

* **F2 (must-fix). `EventPublisher.fetchAndBroadcast` swallows pool errors silently.**
  `Subscription/EventPublisher.hs:165-171` pattern-matches `Left _err`
  and returns `()`, leaving the publisher to wait for the next tick
  or the 30-second safety poll. Pool exhaustion (every connection
  busy with application work) and statement-level errors (e.g., a
  malformed payload that the SQL CTE rejects on the read path) both
  fall into this branch. The publisher will sit idle until the next
  notification or the 30-second timeout, at which point it tries
  again. Subscribers see the resulting latency spike but no
  structured cause. *Cross-plan origin:* same as EP-3.F7 and EP-3.F12.

#### Group C — Worker silent failures (must-fix)

* **F3 (must-fix). `Worker.loadCheckpoint` returns `GlobalPosition 0` on any DB error.**
  `Subscription/Worker.hs:62-68` maps `Left _err` to
  `pure (GlobalPosition 0)`, which causes the worker to start
  catch-up from the global beginning rather than the saved
  checkpoint. At-least-once handlers are idempotent so the
  correctness blast radius is bounded, but the operational blast
  radius is large: a transient pool error at subscription startup
  silently re-processes the entire history. *Cross-plan origin:*
  same as EP-3.F13.

* **F4 (must-fix). `Worker.fetchBatch` returns an empty vector on any DB error.**
  `Subscription/Worker.hs:151-168` (both `AllStreams` and `Category`
  arms) maps `Left _err` to `pure V.empty`. The catch-up loop at
  lines 79-93 treats an empty vector as "no more events" and returns
  `Just cursor`, which signals catch-up complete and triggers the
  switch to live mode. A persistent error (e.g. a permission
  revocation) can therefore make catch-up appear to finish prematurely
  while the cursor sits at a stale position. The category live loop at
  lines 142-149 has the same shape: an empty vector loops back without
  observable failure.

* **F5 (must-fix). `Worker.saveCheckpoint` swallows DB errors silently.**
  `Subscription/Worker.hs:197-199` discards the result of
  `Pool.use` with `() <$ ...`. A transient error during checkpoint
  save means the next subscription with the same name re-processes
  events the handler has already seen — again, idempotent handlers
  mask the correctness issue, but the operator has no way to detect
  the situation.

#### Group D — Hardening of existing failure paths (should-fix)

* **F6 (should-fix). `Notifier.acquireOrFail` raises raw `IOException`.**
  `Notification.hs:124-129` calls `fail ("Notifier: failed to acquire connection: " <> show err)`.
  `fail` in `IO` raises an `IOException` whose message embeds the
  underlying hasql `ConnectionError`. The shape is asymmetric to
  `Schema.SchemaInitError`'s structured exception. Production
  callers wrapping `withStore` in a structured retry policy see
  schema-init failures as a typed exception they can match on but
  notifier-startup failures as a generic `IOException`. Add a
  dedicated `NotifierStartError UsageError` constructor (or reuse
  the existing `Hasql.Pool.UsageError` shape, but Notifier uses raw
  `Hasql.Connection`, so the underlying error is
  `Hasql.Connection.ConnectionError`).

* **F7 (should-fix). Notifier reconnect uses a fixed 1-second delay.**
  `Notification.hs:111` `threadDelay 1_000_000`. Under a sustained
  outage (for example, the database has been migrated to a new
  endpoint and the connection string is now wrong) the listener
  hot-loops a reconnect every second, producing connection-failure
  log spam in PostgreSQL and consuming local resources. Replace with
  capped exponential backoff: 1 s → 2 s → 4 s → 8 s → 16 s capped at
  30 s. The 30-second cap aligns with the publisher's safety-poll
  cadence so the maximum latency between database recovery and
  subscription wakeup remains bounded by 30 s.

* **F8 (should-fix). No `statement_timeout` setting.**
  `Connection.hs:140-143` sets `idle_in_transaction_session_timeout`
  via `initSession` but does not set `statement_timeout`. A
  pathological query (an accidental `LIMIT` -less read on a multi-million-row
  stream, an index-disabled query, a network partition that keeps
  the TCP connection up but stalls the server) can hold a pool
  connection indefinitely. Add `statementTimeout :: Maybe Int`
  (seconds) to `ConnectionSettings`; wire into `initSession` when set.
  A reasonable default for callers to consider is 30 s — long enough
  to absorb GC pauses and transient slow disks, short enough to free
  the pool slot under genuine pathology. Default `Nothing` (current
  behaviour) for backward compatibility.

* **F9 (deferred-with-rationale). hasql-pool acquisition timeout is not exposed.**
  `Hasql.Pool.Config.acquisitionTimeout` exists; `defaultConnectionSettings`
  does not surface it. The pool's default is finite (10 s in current
  hasql-pool), so the failure mode is at least bounded — `Pool.use`
  returns `AcquisitionTimeoutUsageError`, which `mapUsageError` maps
  to `PoolAcquisitionTimeout`. The current behaviour is correct but
  not tunable. Defer with rationale: tuning the pool acquisition
  timeout requires a careful interplay with `statementTimeout` and
  the application's own retry policy. Adding the field is cheap; the
  guidance is what is hard. EP-5 documents the existing 10 s default
  in the Production Tuning guide and leaves the field for a future
  audit when concrete tuning need emerges.

#### Group E — Internal tunables (deferred-with-rationale)

* **F10 (deferred-with-rationale). `publisherBatchSize` and `safetyPollMicros` are not public.**
  `Subscription/EventPublisher.hs:88-93` hard-codes `publisherBatchSize = 1000`
  and `safetyPollMicros = 30_000_000` (30 s). The first determines the
  fan-out batch from publisher to subscriber queues; the second is the
  fallback wakeup if NOTIFY is dropped or the trigger fails. Neither
  is exposed on `ConnectionSettings`. Promoting them to the public API
  expands the surface for callers that mostly should not need to
  touch these — the defaults are well-supported by the EP-1 and
  EP-3 audit work. Defer with rationale: revisit if a benchmark or
  field report demonstrates the defaults are wrong for a real
  workload, at which point the right path is to tune the default
  rather than expose the knob.

* **F11 (no-issue, document only). `queueCapacity` default of 16 batches.**
  `Subscription/Types.hs:91-97` defaults to 16 batches per
  subscriber. At the publisher's batch size of 1000 events, that is
  ~16,000 events of headroom per subscriber. For a slow handler at
  100 ms per event, a full queue represents ~27 minutes of buffered
  work — useful for absorbing a transient handler stall, plenty of
  rope to hang oneself with. The Haddock documents the math; the
  Production Tuning guide should restate it with a recommended
  formula.

#### Group F — New emit sites that would benefit from observation

* **F13 (should-fix, cross-plan from EP-4.F6). Hard-delete emits no observable signal.**
  `Effect.hs:175-187` runs the hard-delete transaction with no
  side-channel. Operators relying on an audit log have no in-band
  record of what was hard-deleted and when. EP-4 documented this in
  `docs/PRODUCTION-DEPLOYMENT.md` with the recommendation that
  callers record an application-level event before calling
  `hardDeleteStream`. EP-5 should also surface a
  `KirokuEventHardDeleted streamName streamId` event through the new
  observation channel so operators with a structured log can
  reconstruct hard-deletes without an application-level event being
  necessary. The application-level event remains the right approach
  for compliance-grade audit; the observation event is a fail-safe.

* **F14 (should-fix). No subscription-lifecycle events.**
  Subscription start, catch-up completion, normal stop (handler
  returned `Stop`), failed-stop (worker died), and overflow are all
  invisible to the operator. A subscription that has been stuck in
  catch-up for an hour is indistinguishable from a healthy one.
  Emit:
  * `KirokuEventSubscriptionStarted name fromPosition`
  * `KirokuEventSubscriptionCaughtUp name atPosition` — fired once
    when catch-up completes.
  * `KirokuEventSubscriptionStopped name atPosition reason` —
    `reason` covers `HandlerStop`, `Cancelled`, `Overflowed`, `WorkerCrashed`.

* **F15 (deferred-with-rationale). No schema-init lifecycle events.**
  `Schema.hs:58-63` returns `()` on success and throws `SchemaInitError`
  on failure. Startup tracing (a healthcheck that asserts schema is
  ready) is doable from the caller side: catch `SchemaInitError`,
  succeed on `Right`. Adding observation events at schema-init
  would be of marginal value — the success path is one event, the
  failure path is already structured. Defer.

#### Group G — Documentation gaps (should-fix)

* **F16 (should-fix). No production tuning guide.**
  `docs/PRODUCTION-DEPLOYMENT.md` (produced by EP-4) covers
  privilege separation, hard-delete authorization, schema migration,
  connection-string handling, at-rest encryption, multi-tenant
  pattern, observability framing, and the PostgreSQL 18 minimum.
  It does not cover *tuning*: pool size selection relative to writer
  concurrency, recommended `statement_timeout` and
  `idle_in_transaction_session_timeout`, subscription
  `batchSize`/`queueCapacity` choice, what metrics to alert on, what
  the 30-second safety poll's worst-case latency is, the trade-offs
  of `DropSubscription` vs `DropOldest`. Write
  `docs/PRODUCTION-TUNING.md` as a sibling to PRODUCTION-DEPLOYMENT,
  link both from `kiroku-store`'s README (when it exists) and from
  the `withStore` Haddock.

#### Group H — Cross-plan / no-issue / deferred

* **F12 (deferred-with-rationale). Publisher uses the application pool.**
  `Connection.hs:154` wires the publisher to the same pool the
  application's appends and reads use. Application-side pool
  exhaustion therefore stalls publisher reads (F2). A dedicated
  publisher connection (or a small dedicated pool of size 1-2)
  would isolate the two. The change is non-trivial — it adds
  another lifecycle owner inside `KirokuStore` and another tunable.
  Defer; recommend the operator either size the application pool
  generously (so the publisher's single concurrent read fits) or
  monitor pool acquisition latency via `observationHandler` and
  raise pool size when it climbs.

* **F17 (deferred-with-rationale). Per-statement latency observability.**
  Append/read/lifecycle latencies are not surfaced. Adding them
  requires a wrapper around every `Pool.use` site or an in-process
  metrics library dependency. Both are a significantly larger
  change than the rest of M2. Defer; recommend external
  instrumentation: callers wire `prometheus-client` or `ekg-core`
  into the new `eventHandler` callback for the events EP-5 does
  emit, and use PostgreSQL's own `pg_stat_statements` for
  per-statement latency profiling.

* **F18 (cross-plan from EP-3.F30, EP-6 owns). `threadDelay` in subscription tests.**
  `test/Main.hs` subscription tests at lines 716-990 use
  `threadDelay`-based synchronisation. EP-3 added new regression
  tests with deterministic STM/`MVar` barriers but did not refactor
  the older ones. EP-5's failure-injection harness adds new tests
  with deterministic barriers (no `threadDelay`); EP-6 still owns
  the suite-wide restructure.

### Tunable Inventory

#### Public, on `ConnectionSettings` (`Connection.hs:29-78`)

| Field | Default | Range / Notes |
|---|---|---|
| `connString` | required | Passed verbatim to libpq. |
| `poolSize` | 10 | B9 in `docs/BENCH-GATE3.md` shows pool sizes above ~32 hit `$all`-row contention as the dominant ceiling, not pool slots. Recommend `max(2, expected_concurrent_writers)` for write-heavy workloads, default for read-mixed. |
| `schema` | `"public"` | LISTEN channel only; not a table prefix. EP-4 documented in detail. |
| `idleInTransactionTimeout` | 30 s | Tunes `idle_in_transaction_session_timeout`. Raise if long-lived transactions are expected from the application; default suits typical workloads. |
| `observationHandler` | `Nothing` | hasql-pool's connection-lifecycle events (acquire, ready-for-use, terminate). |

Missing public tunables (added in M2):

| Field | Default | Range / Notes |
|---|---|---|
| `statementTimeout` | `Nothing` | When `Just s`, sets `statement_timeout = 's'` in `initSession`. Recommend 30 s as a starting point for typical workloads. |
| `eventHandler` | `Nothing` | New `KirokuEvent`-based observation channel for events that hasql-pool's `Observation` does not cover (notifier reconnects, publisher pool errors, worker checkpoint errors, subscription lifecycle, hard-delete). |

#### Public, on `SubscriptionConfig` (`Subscription/Types.hs:85-104`)

| Field | Default | Range / Notes |
|---|---|---|
| `batchSize` | 100 | Catch-up batch size. Larger reduces per-event overhead; smaller improves handler responsiveness to `Stop`. |
| `queueCapacity` | 16 (batches) | Per-subscriber queue, in batches. Effective event capacity is `queueCapacity * publisherBatchSize` (default ~16,000 events). |
| `overflowPolicy` | `DropSubscription` | `DropSubscription` is correctness-preserving; `DropOldest` trades correctness for liveness. |

#### Internal (not exposed)

| Constant | File | Value | Notes |
|---|---|---|---|
| `publisherBatchSize` | `EventPublisher.hs:88-89` | 1000 | Publisher fan-out batch size. |
| `safetyPollMicros` | `EventPublisher.hs:92-93` | 30 s | Fallback wakeup if NOTIFY is missed. |
| Notifier reconnect delay | `Notification.hs:111` | 1 s (fixed) | M2 replaces with exponential backoff capped at 30 s (F7). |
| Notifier `application_name` | `Notification.hs:138` | `"kiroku-listener"` | Used for `pg_stat_activity` visibility. |

### Recommended Observation Surface (`KirokuEvent`)

Introduce a `Kiroku.Store.Observability` module owning a `KirokuEvent`
sum type and a re-export to `Kiroku.Store`. The `Observation` re-export
from hasql-pool stays unchanged for pool-lifecycle events. The new
type covers events the package emits itself:

    data KirokuEvent
        = -- | Notifier listener thread caught a non-async exception
          -- and is about to attempt reconnection. The 'SomeException'
          -- carries the underlying cause for diagnostics. The 'Int' is
          -- the consecutive failure count starting at 1 — used to drive
          -- the exponential backoff and useful as a metric.
          KirokuEventNotifierReconnecting !SomeException !Int
        | -- | Notifier successfully re-established the LISTEN
          -- connection after one or more reconnect attempts. Pairs
          -- with the most recent 'KirokuEventNotifierReconnecting'.
          KirokuEventNotifierReconnected
        | -- | EventPublisher's read query failed; the publisher will
          -- retry on the next tick or safety poll. The 'UsageError'
          -- carries the underlying cause.
          KirokuEventPublisherPoolError !UsageError
        | -- | A subscription's worker thread encountered a DB error
          -- in 'loadCheckpoint', 'fetchBatch', or 'saveCheckpoint'.
          -- The phase identifies which.
          KirokuEventSubscriptionDbError !SubscriptionName !SubscriptionDbPhase !UsageError
        | -- | A subscription's worker has just started; events will
          -- begin from the recorded position (0 if no checkpoint).
          KirokuEventSubscriptionStarted !SubscriptionName !GlobalPosition
        | -- | A subscription has reached the publisher's
          -- 'lastPublished' position and is switching to live mode.
          KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition
        | -- | A subscription has stopped. The reason discriminates
          -- normal completion (handler returned 'Stop') from cancellation,
          -- overflow, and worker-thread crashes.
          KirokuEventSubscriptionStopped !SubscriptionName !GlobalPosition !SubscriptionStopReason
        | -- | A hard-delete was issued. Operators relying on a fail-safe
          -- audit log can capture this. Compliance-grade audit should
          -- still record an application-level event before issuing the
          -- delete (per 'docs/PRODUCTION-DEPLOYMENT.md').
          KirokuEventHardDeleteIssued !StreamName !StreamId

    data SubscriptionDbPhase = LoadCheckpoint | FetchBatch | SaveCheckpoint

    data SubscriptionStopReason
        = StopHandlerRequested
        | StopCancelled
        | StopOverflowed
        | StopWorkerCrashed !SomeException

The `eventHandler :: Maybe (KirokuEvent -> m ())` field is added to
`ConnectionSettingsM`. The current `observationHandler` field is
preserved for hasql-pool events.

This list is the audit's recommended starter set. Subsequent
production experience may add or refine constructors; the design is
sum-typed precisely so additions surface as `-Wincomplete-patterns`
warnings rather than as silent regressions in caller code.


## Decision Log

- Decision: Treat observability as a callback-based extension API (consistent with the existing `observationHandler` pattern) rather than depending on a logging framework. Callers wire `co-log`, `katip`, `prometheus-client`, etc., on top.
  Rationale: Library-level logging frameworks lock callers into a logging stack. Callbacks are minimal-commitment and easy to thread.
  Date: 2026-04-29

- Decision: Introduce a new `KirokuEvent` sum type in a new `Kiroku.Store.Observability` module rather than extending hasql-pool's `Observation`. Add a separate `eventHandler :: Maybe (KirokuEvent -> m ())` field on `ConnectionSettings`; do not replace or rename the existing `observationHandler`.
  Rationale: hasql-pool's `Observation` is owned upstream; extending it would require a fork. A package-owned sum type lets EP-5 add new constructors as production experience reveals new gaps without an upstream coordination cost. Pattern-match incompleteness on consumer sites surfaces as a compiler warning, never as silent misclassification. Keeping both handlers separates "who owns the lifecycle" (hasql-pool for connections, kiroku-store for everything else); merging them into one would force callers to switch on a constructor for "is this mine to handle?" on every event.
  Date: 2026-04-29

- Decision: M2 lands the must-fix observability findings (F1 Notifier reconnect, F2 publisher pool error, F3/F4/F5 worker DB errors), the should-fix tightening of existing failure paths (F6 structured `NotifierStartError`, F7 exponential backoff, F8 `statementTimeout`, F13 hard-delete event, F14 subscription lifecycle events), and the documentation gap (F16 production tuning guide). It defers F9, F10, F12, F15, F17 with rationale recorded in Surprises & Discoveries. F11 is documentation-only and folds into F16.
  Rationale: The must-fix items address the silent-failure operator-blindness gaps that motivated this audit. The should-fix items round out the observation surface to a coherent shape (so callers wiring it once cover the lifecycle, not a partial slice). The deferred items are either non-trivial work that can ship safely without (F12 publisher pool isolation), or tuning surface that is easier to leave latent until a concrete need surfaces (F9, F10), or out-of-scope tasks owned by other plans (F18 owned by EP-6).
  Date: 2026-04-29

- Decision: Notifier reconnect backoff is capped exponential: `min(30s, 2^(attempt-1))` for `attempt = 1, 2, …`. After a successful reconnect the counter resets to 1.
  Rationale: 30 s aligns with the publisher's safety-poll cadence — under sustained outage the worst-case latency between database recovery and subscription wakeup is bounded by the safety poll regardless of the reconnect delay, so capping the backoff at the safety-poll cadence avoids unnecessary additional latency. The exponential schedule (1, 2, 4, 8, 16, 30, 30, …) reduces hot-loop log spam after a few seconds of outage. Reset on success ensures a transient blip does not penalise the next blip.
  Date: 2026-04-29

- Decision: The new `eventHandler` callback is invoked synchronously from the emit site (Notifier loop, publisher loop, worker loop, hard-delete interpreter). Slow callbacks therefore stall those loops. The Haddock contract states this and recommends asynchronous fan-out (e.g., write to a TQueue, drain in a separate thread) for callbacks that may block.
  Rationale: A library-side async wrapper would impose policy (queue size, overflow behaviour) on every caller. The hasql-pool `observationHandler` follows the same synchronous-emit convention; staying consistent is the smaller surprise. Callers needing async fan-out can wire it in 5 lines.
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
