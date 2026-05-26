# Production Tuning Guide for kiroku-store

This document is the operator's companion to `docs/PRODUCTION-DEPLOYMENT.md`.
That document covers privilege separation, hard-delete authorization,
schema migration, connection-string handling, at-rest encryption,
multi-tenancy patterns, and the PostgreSQL 18 minimum. This document
covers *tuning*: picking the values that determine the package's
runtime behaviour under your workload.

The audience is the operator wiring `kiroku-store` into a real
service. Everything below is opinion plus evidence; no function in
the package enforces these recommendations.

Read alongside the in-source Haddocks for `Kiroku.Store.Connection`,
`Kiroku.Store.Subscription.Types`, and `Kiroku.Store.Observability`.


## Connection pool sizing

`ConnectionSettings.poolSize` (default `10`) controls the number of
concurrent `hasql-pool` connections the application can hold against
PostgreSQL. The pool is shared between application reads/writes and
the store's internal `EventPublisher` (`Kiroku.Store.Subscription.EventPublisher`),
which issues one read per notification or 30-second safety poll.

Pool sizing is bounded above by two distinct ceilings:

1. **Per-`$all` row contention.** Every append touches the seed
   `$all` row in the `streams` table to advance the global
   counter — the SQL baseline at PostgreSQL 18 (Apple Silicon,
   unix socket, `docs/BENCH-GATE3.md` benchmark B9) measured
   1,262 ops/s with 64 concurrent writers and pool size 10, and
   ~5,400 TPS at 4 connections (the SQL baseline at 64
   connections-without-a-pool reached 3,015 TPS, which scales the
   per-connection contention ratio). Past ~32 active writers the
   `$all` row's exclusive update is the bottleneck, not the pool;
   adding more pool connections increases lock waiting rather than
   throughput.
2. **PostgreSQL connection limits.** `max_connections` defaults to
   100 in stock PostgreSQL. A pool size of 50 leaves 50 for
   psql / monitoring / migrations / replication; if multiple
   `kiroku-store` instances share the database, divide by
   instance count.

Recommendations:

- Start at the default `10` for a single-process service with
  fewer than 32 concurrent writers. Throughput is `$all`-bound at
  this point; raising the pool wastes connections.
- For services with many concurrent readers (projection workers
  reading streams in parallel) raise to `max(10, expected_concurrent_readers + 4)`.
  Each subscription's worker thread holds a connection only
  during catch-up batches and during category-live re-queries; in
  steady state subscription workers spend most of their time
  blocked on STM, not the pool.
- For multi-process deployments, divide PostgreSQL's
  `max_connections` budget by instance count, then leave 30% for
  non-application use.

The pool's connection-lifecycle events are surfaced through
`ConnectionSettings.observationHandler`. Wire it to your metrics
pipeline and alert when `Acquired` events back up — sustained
acquisition latency above 100 ms means the pool is undersized for
the load.

The focused reliability-and-scale audit refreshed the `kiroku-store`
benchmark baseline in May 2026. On the local PostgreSQL 18 benchmark
host, the added gates measured roughly 1.6 ms for 10 hot
`invoice-payment` appends, 0.39 ms for one `appendMultiStream` touching
three existing streams, and 4 ms for a category subscription catching up
100 events. Treat these as regression guards for this repository rather
than portable service-level objectives; production thresholds should
come from your hardware and payload sizes.


## Statement timeout

`ConnectionSettings.statementTimeout` (default `Nothing`) sets
PostgreSQL's session-level `statement_timeout` GUC at every pooled
connection's `initSession`. Bounds the wall-clock runtime of any
single statement; protects pool slots from being held indefinitely
by a pathological query.

Failure mode the timeout protects against: a query that for any
reason (a network partition that keeps TCP alive but stalls the
server, an index-disabled scan triggered by a planner regression,
an accidental cartesian join in a future ad-hoc statement) sits
on a pool connection forever. Without a timeout the pool slot is
unrecoverable until the connection is forcibly closed.

Recommendations:

- Set to `Just 30` (30 seconds) as a starting point. Long enough
  to absorb GC pauses and transient slow disks; short enough to
  free the pool slot under genuine pathology.
- Tune based on observed `pg_stat_statements`: pick a value above
  the p99 of your slowest legitimate query plus 3-5x headroom.
- Coordinate with `idleInTransactionTimeout` (default `30` s):
  the two together cap the maximum wall-clock time a pool slot
  can be unavailable. A pool of size 10 with both at 30 s caps
  slot loss at 30 s under either failure mode.

The package surfaces `statement_timeout` failures as
`StoreError.UnexpectedServerError "57014"` (the SQLSTATE for
"query canceled"). Callers wanting retry logic should pattern match
on that constructor.


## Idle-in-transaction timeout

`ConnectionSettings.idleInTransactionTimeout` (default `30`
seconds) sets PostgreSQL's session-level
`idle_in_transaction_session_timeout` GUC. Bounds how long a pooled
connection can sit inside an open transaction without progress.

The default of 30 s is well-suited to typical workloads:
`hasql-transaction` opens transactions only inside `Pool.use` and
the transaction completes within the function call. Raising the
default makes sense only when the application uses `Pool.use`
directly to coordinate multi-step transactions across
non-database work — an unusual pattern.


## Subscription batch size

`SubscriptionConfig.batchSize` (default `100`) controls how many
events the subscription worker fetches per database round-trip
during catch-up.

Tradeoffs:

- **Higher batch size** reduces per-event overhead. At 1000
  events per fetch the per-event overhead is ~1 µs; at 10 events
  per fetch it is ~100 µs. For a pure-Haskell handler this is
  noticeable.
- **Lower batch size** improves the worker's responsiveness to
  `Stop` and to cancellation. The worker checks the `Stop`
  condition once per event, but only checks for cancellation
  between batches. A batch size of 1000 means up to 1000 events
  worth of latency before cancellation takes effect.
- **Memory**: each batch is held in memory in a `Vector
  RecordedEvent`. At 1 KB per event (typical for compact JSON
  payloads) a batch of 100 is 100 KB, of 1000 is 1 MB. Workers
  process batches sequentially so the in-memory cost is per-worker
  not aggregate.

Recommendations:

- Stay at `100` for catch-up against a large historical backlog
  on a low-CPU handler. Catch-up dominates startup time on a
  fresh subscription against a 10M-event stream; raising to
  `1000` cuts catch-up time roughly tenfold for handlers that are
  not CPU-bound.
- Lower to `50` or `25` if cancellation latency matters
  (operator-initiated subscription drains during deploys, for
  example).


## Subscription queue capacity and overflow policy

`SubscriptionConfig.queueCapacity` (default `16` batches) is the
size of the bounded `TBQueue` the publisher writes to per
subscriber. Effective event capacity is
`queueCapacity * publisherBatchSize` — at the publisher's default
1000 events per batch, the default queue holds ~16,000 events.

`SubscriptionConfig.overflowPolicy` (default `DropSubscription`)
controls publisher behaviour when a subscriber's queue is full:

- **`DropSubscription`** — the publisher marks the subscription
  overflowed; the worker observes the status TVar and surfaces
  `SubscriptionOverflowed` through `Async.waitCatch`. The slow
  subscriber is terminated, other subscribers are unaffected.
  *No events are lost from the subscriber's perspective:* on the
  next subscription with the same name, catch-up reads from the
  saved checkpoint and the dropped events are re-delivered.
- **`DropOldest`** — the publisher discards the oldest queued
  batch and enqueues the new one. The subscription continues to
  run but loses events. Choose this only for telemetry-style
  subscriptions where missing events is acceptable.

Recommendations:

- Default `DropSubscription` is correct for projection workers,
  audit consumers, and any other at-least-once consumer.
- Choose `DropOldest` only when liveness matters more than
  correctness (live dashboards, derived counters where the latest
  value is what counts).
- Size `queueCapacity` for the maximum handler stall you need to
  absorb. At a handler latency of 100 ms per event, a queue of 16
  batches × 1000 events = 27 minutes of buffered work. Reduce
  for real-time consumers; raise for consumers that occasionally
  block (e.g., a handler that calls a downstream service with
  retry-with-backoff).
- Couple sizing with the
  `KirokuEventSubscriptionStopped _ _ StopOverflowed` event:
  alert on it. An overflow event in production is a signal to
  investigate the slow handler, not a transient blip to ignore.


## Safety poll cadence

The `EventPublisher`'s `safetyPollMicros = 30_000_000` (30 s)
constant is *not* exposed on `ConnectionSettings` and intentionally
not configurable. It bounds the worst-case latency between an
appended event and its delivery to subscribers when notifications
are missed (a dropped NOTIFY, a notify trigger that raised, a
listener still in mid-reconnect when an append happened). The
notifier's reconnect backoff is also capped at 30 s for the same
reason — the safety poll is the universal upper bound on broadcast
latency.

The 30 s cadence is correct for typical workloads. If a deployment
has hard latency requirements below 30 s under all failure modes,
the right answer is not to lower the safety poll (which would
amplify the publisher's read load against the database) but to
investigate why notifications are unreliable in the first place
(usually a `LISTEN` channel name mismatch — see
`docs/PRODUCTION-DEPLOYMENT.md` "Multi-tenant deployments").


## What to monitor and alert on

Wire `ConnectionSettings.observationHandler` and
`ConnectionSettings.eventHandler` to your structured logger and/or
metrics pipeline. The `observationHandler` covers `hasql-pool`'s
connection lifecycle (acquire, ready-for-use, terminate, with
reasons); the `eventHandler` covers `Kiroku.Store.Observability.KirokuEvent`,
which is everything the package emits itself.

Structured-log everything; metric-aggregate the items in this
table:

| Signal | Source | Why to alert |
|---|---|---|
| Connection acquisition latency p99 | `Observation` (hasql-pool) | > 100 ms sustained → pool is undersized for offered load. |
| Connection-terminated rate | `Observation` (hasql-pool) | spike → backend is killing connections (statement_timeout, idle_in_transaction_session_timeout, network) — investigate. |
| `KirokuEventNotifierReconnecting` rate | `eventHandler` | > 1/min sustained → listener cannot stay connected; check LISTEN channel name vs trigger schema. |
| `KirokuEventNotifierReconnecting` consecutive count | `eventHandler` | The `Int` field. Above 5 means exponential backoff has reached 16 s; sustained outage. Page operator. |
| `KirokuEventPublisherPoolError` rate | `eventHandler` | > 0 sustained → publisher cannot read; subscriptions are running on the 30 s safety poll only. Investigate pool exhaustion or server errors. |
| `KirokuEventSubscriptionDbError` rate per phase | `eventHandler` | Any rate sustained → investigate database health. `LoadCheckpoint` errors mean startup re-processing from 0; `FetchBatch` means the worker is retrying the same cursor and not making progress until the fetch succeeds; `SaveCheckpoint` means restart will re-process. |
| `KirokuEventSubscriptionStopped` with `StopOverflowed` | `eventHandler` | Any → subscriber is too slow for `DropSubscription`; investigate handler latency or raise `queueCapacity`. |
| `KirokuEventSubscriptionStopped` with `StopWorkerCrashed` | `eventHandler` | Any → uncaught exception in handler. Log the wrapped `SomeException` and triage. |
| Catch-up duration | derived: time between `KirokuEventSubscriptionStarted` and `KirokuEventSubscriptionCaughtUp` | Used to size `batchSize`; an outlier (> historical p99) on subscription startup against a known-static stream is a sign of database slowness. |
| `KirokuEventHardDeleteIssued` rate | `eventHandler` | Anomaly detection. A sudden spike of hard-deletes from a service that does not normally issue them is a runtime smell. Compliance audit should still record application-level events *before* the delete (per `docs/PRODUCTION-DEPLOYMENT.md`); this signal is fail-safe. |

Wire the `eventHandler` callback fast or asynchronously. The
callback runs synchronously on the emit-site thread (notifier
loop, publisher loop, worker loop, store interpreter); a slow
callback stalls those loops. For callbacks that may block, fan
out:

    let asyncHandler queue = \evt -> atomically (writeTBQueue queue evt)
    -- ... drain queue in a separate thread, push to your metrics pipeline ...

A bounded `TBQueue` of 1024 entries is plenty; events emit at
human-investigation cadence, not per-event-throughput cadence.


## What *not* to monitor

`kiroku-store` does not emit per-statement latency or per-operation
metrics. Adding them would couple the package to a metrics library
or impose a wrapper on every `Pool.use` site. Use PostgreSQL's
own `pg_stat_statements` for per-statement profiling, and the
existing `observationHandler` for connection-pool behaviour. If
application-side per-call latency matters, instrument the call site
in your application — `runStoreIO` returns `Either StoreError a`
and is the natural point to record duration.

`kiroku-store` does not emit a heartbeat or liveness signal. The
absence of `KirokuEventSubscriptionDbError` is not a positive
signal that subscriptions are healthy. Couple your monitoring with
an application-level synthetic write or a periodic
`getStream` ping if you need active liveness.


## Pre-production checklist

Before pointing real services at a `kiroku-store` instance:

1. Confirm `poolSize` is set, with rationale, against your
   expected concurrent-writer count.
2. Set `statementTimeout` to a non-`Nothing` value with rationale.
3. Wire `observationHandler` and `eventHandler` to structured
   logging. Verify a test event flows end-to-end.
4. Configure alerts for the signals in the "What to monitor" table.
5. For each subscription, document the `overflowPolicy` choice and
   the `queueCapacity` rationale. `DropSubscription` should be the
   default; `DropOldest` requires a written justification.
6. Validate `LISTEN` channel name agreement under whatever
   `search_path` your tenant configuration uses (per
   `docs/PRODUCTION-DEPLOYMENT.md` "Multi-tenant deployments");
   subscription latency silently degrades to 30 s without it.
7. If hard-delete is enabled, confirm
   `KirokuEventHardDeleteIssued` is wired to your audit pipeline,
   *and* confirm application-level audit events are recorded
   before each `hardDeleteStream` call (per
   `docs/PRODUCTION-DEPLOYMENT.md`).
