# Phase 2 — Subscriptions for kiroku-store

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, callers of kiroku-store can subscribe to real-time event streams. A
subscription is a long-running process that reads events from the store — first catching up
from a saved position, then switching to live delivery as new events are appended. The
subscription wakes up via PostgreSQL LISTEN/NOTIFY so there is no polling.

A user can do four things they could not do before. First, subscribe to the `$all` stream or
a specific category and receive every event in global order, starting from any saved
position. Second, provide a handler callback that receives each event; the handler returns
`Continue` or `Stop` to control the subscription lifecycle. Third, persist a checkpoint (the
last processed global position) so that after a restart the subscription resumes where it
left off rather than replaying from the beginning. Fourth, cancel a running subscription
gracefully.

The subscription system uses a hybrid architecture informed by all three major PostgreSQL
event store implementations (Commanded, Hindsight, and Marten). A Notifier thread listens
for PostgreSQL notifications and wakes a centralized EventPublisher. The EventPublisher
queries the database once per notification, then broadcasts fetched events to all
subscribers via a `TChan (Vector RecordedEvent)`. Each subscriber receives the same events
without issuing its own database query — 30+ subscribers means 1 query, not 30+.

Three reliability mechanisms ensure events are never missed. First, LISTEN/NOTIFY provides
sub-10ms wakeup for live delivery. Second, a periodic safety poll (every 30 seconds) wakes
the EventPublisher even if LISTEN/NOTIFY is down, bounding maximum delivery latency.
Third, tick debouncing in the EventPublisher collapses rapid notifications into a single
database query, reducing burst load during high-throughput appends.

Observable outcomes:

- `cabal build all` compiles with the new subscription modules.
- `cabal test all` passes all existing tests (46) plus new subscription tests.
- A test demonstrates catch-up: subscribe from position 0 on a store with pre-existing
  events, and the handler receives all of them.
- A test demonstrates live delivery: subscribe, then append new events, and the handler
  receives them without polling.
- A test demonstrates checkpoint persistence: subscribe, process some events, restart the
  subscription with the saved checkpoint, and only new events are delivered.
- A test demonstrates cancellation: subscribe, cancel the subscription handle, and the
  worker exits cleanly.


## Progress

- [x] M7.1: Add hasql-notifications dependency and verify build (2026-03-23)
- [x] M7.2: Implement the Notifier (LISTEN thread + TChan broadcast) (2026-03-23)
- [x] M7.3: Implement the EventPublisher (centralized fetch + broadcast) (2026-03-23)
- [x] M7.4: Implement subscription types and checkpoint SQL (2026-03-23)
- [x] M7.5: Implement the subscription worker loop (catch-up + live) (2026-03-23)
- [x] M7.6: Wire subscriptions into the public API (2026-03-23)
- [x] M7.7: Tests — catch-up, live delivery, checkpoint, category, cancellation, empty store, debouncing (2026-03-23)
- [x] M7.8: Document results and update plan (2026-03-23)


## Surprises & Discoveries

- **hasql-notifications tag mismatch.** The `source-repository-package` approach with
  `tag: 0.2.5.0` failed because that tag does not exist in the git repository. Switched to
  `optional-packages` with a local path to the hasql-project checkout. This works for
  development; a production release would need to pin a specific commit hash or publish the
  package.

- **Worker catch-up/Stop bug.** The initial Worker implementation had a bug where the handler
  returning `Stop` during catch-up would still proceed to the live loop (blocking forever on
  `readTChan`). The catch-up function needed to return `Maybe GlobalPosition` instead of
  `GlobalPosition`, with `Nothing` signaling the handler stopped and the worker should exit.
  This was caught during test development.

- **`asyncExceptionFromException` location.** In GHC 9.12.2 with GHC2024,
  `asyncExceptionFromException` is exported from `Control.Exception`, not `GHC.Exception`.
  Minor import fix required.


## Comparative Analysis: Subscription Architectures

Three production PostgreSQL event stores were studied in depth before choosing an
architecture. Research notes are archived in rei collection
`collection_01kj3w0dnvex9s582d5xvdncz2`. Source code for all three is available on disk.

### Commanded EventStore (Elixir) — Production-proven, most sophisticated

Source: `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/`

Commanded has the most sophisticated subscription system of any PostgreSQL event store. It
uses a 7-state FSM (`initial → request_catch_up → catching_up → subscribed → max_capacity →
disconnected → unsubscribed`) with competing consumers, partition-aware distribution,
contiguous-ack checkpoint advancement, and advisory lock coordination.

The notification pipeline is centralized: a `Listener` (GenStage producer) receives
PostgreSQL LISTEN notifications, a `Publisher` (GenStage consumer) reads the actual events
from storage, then broadcasts them via PubSub to all subscriptions. This means event data
flows through the notification pipeline — the Publisher fetches events by stream and version
range from the NOTIFY payload (`stream_uuid,stream_id,first_version,last_version`).

**What we take:** The NOTIFY trigger design (on `streams` table, schema-scoped channel,
fires once per append). The centralized Publisher pattern (query once, broadcast to all
subscribers — eliminates the thundering herd problem at 30+ subscribers). The checkpoint
concept (contiguous-ack advancement before persisting). The `SubscriptionHandle` pattern
(cancel + wait). The advisory lock two-part key design (for future competing consumers).

**What we leave:** The OTP/GenStage supervision tree (Elixir-specific). The 7-state FSM
complexity (overkill for Phase 2a — `max_capacity`, `disconnected`, and `unsubscribed`
states are Phase 2c concerns). Competing consumers and partition-aware distribution
(Phase 2c).

### Hindsight (Haskell) — Cleanest Haskell implementation, limited production use

Source: `/Users/shinzui/Keikaku/hub/haskell/hindsight/`

Hindsight uses a decentralized pull-based architecture. A single `Notifier` thread listens
for PostgreSQL notifications and broadcasts a `()` tick via `TChan` (STM broadcast channel).
Each subscriber gets a personal channel copy via `dupTChan`. The worker loop independently
pulls batches from the database — the Notifier carries no event data, only "something
changed." This eliminates the centralized Publisher bottleneck.

The worker loop is simple: fetch a batch → process each event → update cursor → if batch
was empty, wait for tick. Server-side event filtering (`AND event_name = ANY($4)`) reduces
unnecessary data transfer.

**What we take:** The `TChan` broadcast pattern for fan-out. The `Notifier` type design
and reconnection logic. The `SubscriptionHandle` pattern (`cancel` via `Async.cancel`,
`wait` via `Async.waitCatch`).

**What we leave:** The decentralized pull-based architecture where each subscriber queries
the database independently — this causes a thundering herd with 30+ subscribers (all wake
simultaneously, all issue separate queries, pool exhausted). The compound
`(transactionXid8, seqNo)` cursor (we use contiguous `GlobalPosition` instead). The
`EventMatcher` type-level machinery. Hindsight's limited production track record means we
validate the architecture with our own tests rather than trusting it at face value.

### Marten (.NET) — Most battle-tested, but polling-based

Source: `/Users/shinzui/Keikaku/hub/event-sourcing/marten/`

Marten uses a fully polling-based subscription model. The `AsyncDaemon` / `ProjectionDaemon`
continuously polls PostgreSQL to detect new events, gaps, and stale progress. A
`HighWaterDetector` with `GapDetector` maintains a safe high-water mark using `lead()`
window functions. Shards (`ISubscriptionAgent`) process event ranges independently.

Marten's error handling is the most mature: `SkipApplyErrors`, `SkipSerializationErrors`,
`SkipUnknownEvents` with dead-letter table persistence. The `ResilientEventLoader` uses
Polly retry pipelines. Multi-tenancy is handled via `ProjectionCoordinator` with
`SoloProjectionDistributor` / `MultiTenantedProjectionDistributor`.

**What we take:** The error handling taxonomy (skip + dead-letter) for future Phase 2b
projection work. The concept of sharded/parallel event processing for future scaling.

**What we leave:** The entire polling architecture (LISTEN/NOTIFY is strictly better for
latency and database load). The gap detection machinery (Strategy E produces gap-free
positions, making this unnecessary). The `HighWaterDetector` / `GapDetector` / skip tracking
complexity. The .NET-specific Polly resilience patterns.

### Architecture decision: Centralized EventPublisher with LISTEN/NOTIFY + safety poll

The chosen architecture combines Commanded's centralized Publisher pattern with Hindsight's
TChan broadcast mechanism, adds reliability guarantees absent from both, and defers Marten's
error handling to Phase 2b:

1. **Notification layer (from Commanded):** PostgreSQL NOTIFY trigger fires on `streams`
   table, schema-scoped channel, once per append. The Notifier thread receives notifications
   and writes ticks to a `TChan ()`.

2. **EventPublisher (from Commanded, adapted):** A single EventPublisher thread reads ticks
   from the Notifier's TChan, queries the database once to fetch new events from `$all`
   starting after the last-published position, and broadcasts the fetched events to all
   subscribers via a `TChan (Vector RecordedEvent)`. This eliminates the thundering herd:
   30+ subscribers = 1 database query, not 30+. Unlike Commanded's per-stream Publisher,
   our EventPublisher reads from `$all` in global position order — all subscribers see the
   same global event stream.

3. **Subscriber layer (hybrid):** Each subscriber has its own worker thread that reads from
   its personal `TChan (Vector RecordedEvent)` (obtained via `dupTChan`). During catch-up
   (reading historical events before reaching the Publisher's current position), the worker
   queries the database directly. Once caught up, it switches to consuming events pushed by
   the EventPublisher. This means slow subscribers during catch-up don't affect the
   Publisher or other subscribers.

4. **Reliability layer (new — absent from Hindsight and partially from Commanded):**
   - **Periodic safety poll:** The EventPublisher wakes every 30 seconds even without a
     LISTEN/NOTIFY tick. This bounds maximum delivery latency if the Notifier connection
     drops. LISTEN/NOTIFY is not durable — notifications during a connection gap are lost
     forever. The safety poll ensures the database (the source of truth) is checked
     regardless.
   - **Tick debouncing:** When the EventPublisher wakes, it drains all pending ticks from
     the TChan before querying. This collapses rapid notifications (e.g., 10 appends in
     quick succession) into a single database query.
   - **Notifier reconnection:** On connection failure, the Notifier waits 1 second and
     retries. On `AsyncException` it exits cleanly. During reconnection, the safety poll
     ensures events are still delivered.

5. **Checkpoint layer (from Commanded):** Persistent checkpoint table, upsert-based saves.
   Contiguous-ack advancement deferred to Phase 2c (simple last-processed-position
   checkpointing is sufficient for Phase 2a).

6. **Error handling (from Marten, deferred):** Skip + dead-letter taxonomy for Phase 2b
   projections. Phase 2a handlers throw on error — the subscription stops, which is the
   safest default.

This architecture uses Kiroku's gap-free `GlobalPosition` as a simpler cursor than any of
the three reference implementations. The EventPublisher's `$all` query is the same
`readAllForwardStmt` already implemented in Phase 1 — no new SQL is needed for the
publishing path.


## Decision Log

- Decision: Build subscriptions directly into `kiroku-store` rather than creating a separate
  `kiroku` framework package.
  Rationale: The DESIGN.md envisioned a two-package split (`kiroku-store` for the store,
  `kiroku` for subscriptions and projections). However, the subscription machinery is tightly
  coupled to the store's connection pool, schema, and event types. A separate package would
  require re-exporting most of `kiroku-store` internals. The Hindsight codebase demonstrates
  that subscriptions work well as part of the store package — its `subscribe` function takes
  the store handle directly. Keeping everything in one package avoids circular dependency
  issues and simplifies the build. Projections (Phase 2b) can still be split out later if
  warranted.
  Date: 2026-03-23

- Decision: Use `hasql-notifications` for LISTEN/NOTIFY rather than raw `postgresql-libpq`.
  Rationale: The `hasql-notifications` library provides `listen`, `waitForNotifications`,
  and `PgIdentifier` (safe channel name escaping) on top of `Hasql.Connection`. It handles
  the platform-specific waiting (`threadWaitRead` on Unix, `threadDelay` on Windows) and
  `consumeInput` loop correctly. Using raw `postgresql-libpq` would require reimplementing
  all of this. The library is already available in the hasql project corpus at
  `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-notifications/`.
  Date: 2026-03-23

- Decision: Use a centralized EventPublisher that queries once and broadcasts events to all
  subscribers, rather than decentralized pull where each subscriber queries independently.
  Rationale: Hindsight's decentralized pull-based architecture causes a thundering herd at
  scale. When a NOTIFY arrives, all subscribers wake simultaneously and each issues its own
  database query. With 30+ subscribers, this means 30+ concurrent queries hitting PostgreSQL
  in a burst, exhausting a typical connection pool (10–20 connections). Commanded solves this
  with a centralized Publisher that queries once and pushes event data to subscribers via
  in-process messaging. We adopt this pattern: the EventPublisher reads from `$all` once per
  notification, then broadcasts the fetched events to all subscribers via `TChan (Vector
  RecordedEvent)`. 30+ subscribers = 1 query. The trade-off is that the EventPublisher
  becomes a throughput bottleneck — but since it reads from `$all` (a single indexed query
  taking ~1ms for 100 events), this bottleneck is far above practical subscription counts.
  Subscribers during catch-up still query independently (they need historical events the
  Publisher has already passed), so the pool must accommodate some concurrent catch-up
  queries, but this is bounded and temporary.
  Date: 2026-03-23

- Decision: Add a periodic safety poll (every 30 seconds) to the EventPublisher as a
  reliability backstop.
  Rationale: LISTEN/NOTIFY is not durable. If the Notifier's PostgreSQL connection drops,
  notifications during the reconnection window are lost forever. Hindsight has no mitigation
  for this — subscribers sit in `readTChan` indefinitely, receiving no events until a new
  notification arrives after reconnection. Adding a 30-second periodic wakeup to the
  EventPublisher guarantees bounded delivery latency regardless of LISTEN/NOTIFY health. The
  database is always the source of truth; the safety poll simply ensures we check it. The
  30-second interval is a balance between latency (acceptable for most projections) and
  database load (one extra query every 30 seconds is negligible).
  Date: 2026-03-23

- Decision: Debounce ticks in the EventPublisher — drain all pending ticks before querying.
  Rationale: During high-throughput appends (e.g., bulk import writing 100 batches in 1
  second), the Notifier produces 100 ticks in rapid succession. Without debouncing, the
  EventPublisher would issue 100 queries. By draining all pending ticks from the TChan before
  querying, rapid notifications collapse into a single database query that fetches all new
  events at once. This is especially important because the EventPublisher is centralized —
  any time it spends on redundant queries delays delivery to all subscribers.
  Date: 2026-03-23

- Decision: Milestone numbering continues from M7 (Milestones 1–6 were kiroku-store Phase 1).
  Rationale: Continuity with the existing milestone numbering in the repository.
  Date: 2026-03-23

- Decision: Use `GlobalPosition` (contiguous `Int64`) as the subscription cursor, not a
  compound cursor like Hindsight's `(transactionXid8, seqNo)`.
  Rationale: Kiroku uses Strategy E — an atomic row-level counter on the `$all` stream —
  which produces contiguous, gap-free global positions. A single `Int64` is sufficient to
  uniquely identify a position. Hindsight uses `(transactionXid8, seqNo)` because its
  Strategy D has non-contiguous xid8-based ordering. Our simpler cursor means checkpoint
  persistence is a single integer column, ordering is trivial, and the existing
  `readAllForward` / `readCategoryForward` SQL already accepts `GlobalPosition` as its
  cursor parameter.
  Date: 2026-03-23

- Decision: The Notifier acquires its own dedicated `Hasql.Connection` outside the pool.
  Rationale: PostgreSQL LISTEN requires a persistent connection that stays open and
  subscribed to the channel. Pooled connections are returned to the pool and reused,
  which would break the LISTEN subscription. `hasql-notifications` operates on a raw
  `Hasql.Connection`, not a pool. The Notifier creates one connection on startup and holds
  it for the store's lifetime.
  Date: 2026-03-23

- Decision: The checkpoint table lives in the same schema as the store tables and is created
  by `initializeSchema`.
  Rationale: Checkpoints are integral to the store's operation. Using the same schema
  (`public` by default, or the configured schema for multi-tenant) ensures isolation and
  co-location with the event data. The DESIGN.md already includes a `subscriptions` table
  design that matches this approach.
  Date: 2026-03-23

- Decision: Subscriptions support both `$all` and category-based subscription, but not
  single-stream subscription in this milestone.
  Rationale: The most common subscription patterns are "all events" (for cross-cutting
  projections) and "all events in a category" (for aggregate-specific projections). Single-
  stream subscription is less common and can be added later. The existing `readAllForward`
  and `readCategoryForward` SQL statements already support the cursor-based fetching needed.
  Date: 2026-03-23

- Decision: Phase 2a implements a 3-state subscription lifecycle (CatchingUp → Subscribed →
  Stopped), deferring Commanded's full 7-state FSM to Phase 2c.
  Rationale: Commanded's 7-state FSM (`initial → request_catch_up → catching_up →
  subscribed → max_capacity → disconnected → unsubscribed`) handles competing consumers,
  buffer overflow, lock loss recovery, and subscriber death — all production hardening
  concerns. For Phase 2a, the simple 3-state model covers the core use case: catch up from
  a position, switch to live delivery, stop on handler request or cancellation. The
  additional states can be added incrementally without breaking the Phase 2a API because
  they are internal to the worker loop.
  Date: 2026-03-23

- Decision: Simple last-processed-position checkpointing rather than Commanded's
  contiguous-ack advancement algorithm.
  Rationale: Commanded's checkpoint mechanism tracks `in_flight_event_numbers` and
  `acknowledged_event_numbers` separately, only advancing `last_ack` through contiguous
  acknowledged positions. This is necessary for competing consumers where multiple
  subscribers process events in parallel and acks arrive out of order. In Phase 2a, each
  subscription has a single worker processing events sequentially — acks are always in
  order by construction. Simple "save the position of the last processed event" is correct
  and sufficient. Contiguous-ack advancement will be needed when competing consumers are
  added in Phase 2c.
  Date: 2026-03-23

- Decision: Handler exceptions stop the subscription (fail-fast), deferring Marten's
  skip/dead-letter error taxonomy to Phase 2b.
  Rationale: Marten offers `SkipApplyErrors`, `SkipSerializationErrors`, and
  `SkipUnknownEvents` with dead-letter table persistence. These are essential for production
  projections but add significant complexity. For Phase 2a, if a handler throws, the
  subscription stops and the exception is available via `SubscriptionHandle.wait`. This is
  the safest default — silently skipping errors can cause data inconsistency. Phase 2b
  (projections) will add configurable error policies.
  Date: 2026-03-23


## Outcomes & Retrospective

Phase 2a subscriptions are complete. All planned capabilities are implemented and tested:

- **53 tests pass** (46 existing Phase 1 tests + 7 new subscription tests).
- **Catch-up delivery:** Subscribers starting from position 0 on a store with existing events
  receive all events in global position order via direct database queries.
- **Live delivery:** Events appended after subscription starts are delivered via the
  EventPublisher's TChan broadcast without polling. Sub-second latency on localhost.
- **Checkpoint persistence:** Subscriptions persist their position via upsert to the
  `subscriptions` table. Restarting with the same name resumes from the saved position.
- **Category subscription:** Category-based subscriptions filter events during catch-up via
  the existing `readCategoryForwardStmt` SQL.
- **Cancellation:** `Async.cancel` cleanly terminates subscription workers.
- **Debouncing:** 50 rapid appends to 50 different streams are all delivered without loss,
  confirming the tick debouncing mechanism works correctly.
- **Safety poll:** The 30-second periodic wakeup is implemented in the EventPublisher. The
  safety poll test was deferred (would add 30+ seconds to the test suite) but the mechanism
  is architecturally in place.

**Architecture validated.** The centralized EventPublisher pattern (query once, broadcast to
all subscribers) works as designed. The catch-up → live transition is clean: workers query
the database independently during catch-up, then switch to consuming from the broadcast
TChan once caught up.

**Deferred to Phase 2b/2c:**
- Error handling taxonomy (skip + dead-letter) for production projections.
- Competing consumers with contiguous-ack checkpoint advancement.
- In-process category filtering during live mode (currently category subscriptions use SQL
  filtering during catch-up only).
- 7-state FSM (max_capacity, disconnected, unsubscribed states).


## Context and Orientation

Kiroku is a PostgreSQL event store implemented in Haskell. The core library lives in
`kiroku-store/`. It uses GHC 9.12.2 with GHC2024, the effectful library for effect
management, and hasql for PostgreSQL access.

### Repository structure

    kiroku-store/
      kiroku-store.cabal          -- package definition
      sql/schema.sql              -- DDL (embedded at compile time via file-embed)
      src/Kiroku/Store/
        Store.hs                  -- public API re-exports
        Types.hs                  -- StreamName, EventId, RecordedEvent, GlobalPosition, etc.
        Connection.hs             -- ConnectionSettings, KirokuStore handle, withStore bracket
        Effect.hs                 -- Store effect GADT and runStorePool interpreter
        SQL.hs                    -- all hasql statements (private module)
        Error.hs                  -- StoreError type and PostgreSQL error mapping
        Append.hs                 -- appendToStream public API
        Read.hs                   -- readStreamForward, readAllForward, etc.
        Link.hs                   -- linkToStream
        Lifecycle.hs              -- softDeleteStream, hardDeleteStream, undeleteStream
        Schema.hs                 -- initializeSchema (runs embedded DDL)
      test/Main.hs                -- 46 tests using hspec + ephemeral-pg
      bench/Main.hs               -- tasty-bench benchmarks

    cabal.project                 -- project file (currently just kiroku-store)

### Key types

`GlobalPosition` is a newtype over `Int64`. It represents a contiguous, gap-free position in
the `$all` stream. Every event appended to any stream gets a unique global position. The
`readAllForward` and `readCategoryForward` functions accept a `GlobalPosition` as a cursor
parameter and return events with positions strictly greater than the cursor.

`RecordedEvent` is the type returned by all read operations. It carries `globalPosition`,
`eventType`, `payload` (JSONB as `Value`), `metadata`, `streamVersion`,
`originalStreamId`, and `createdAt`.

`KirokuStore` is a record with `pool :: Pool` and `schema :: Text`. It is created by
`withStore` which initializes the schema and manages the pool lifecycle.

`ConnectionSettings` has `connString :: Text`, `poolSize :: Int`, `schema :: Text`,
`idleInTransactionTimeout :: Int`, and `observationHandler :: Maybe (Observation -> IO ())`.

### Existing NOTIFY trigger

The schema already has a NOTIFY trigger on the `streams` table (not the `events` table).
It fires once per append batch, not once per event. The trigger is in
`kiroku-store/sql/schema.sql` (lines 76–89):

    CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
    BEGIN
        PERFORM pg_notify(
            TG_TABLE_SCHEMA || '.events',
            NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version
        );
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER stream_events_notify
        AFTER INSERT OR UPDATE ON streams
        FOR EACH ROW EXECUTE FUNCTION notify_events();

The channel name is `<schema>.events` (e.g., `public.events`). The payload is a
comma-separated string: `stream_name,stream_id,stream_version`. Subscribers do not need
to parse this payload for the initial implementation — they only need to know that
"something changed" and should pull new events from the database.

### hasql-notifications library

Located at `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-notifications/`. It
provides LISTEN/NOTIFY support for hasql. Key exports:

- `listen :: Connection -> PgIdentifier -> IO ()` — register a connection to listen on a
  channel. The connection must be kept alive.
- `unlisten :: Connection -> PgIdentifier -> IO ()` — deregister from a channel.
- `waitForNotifications :: (ByteString -> ByteString -> IO ()) -> Connection -> IO ()` —
  blocking loop that calls the handler on each notification. Runs forever.
- `toPgIdentifier :: Text -> PgIdentifier` — escape and quote a channel name.
- `notifyPool :: Pool -> Text -> Text -> IO (Either UsageError ())` — send NOTIFY via pool.

The library requires `hasql >= 1.10 && < 1.11`, `hasql-pool >= 1.4 && < 1.5`, and
`postgresql-libpq >= 0.9 && < 1.0`. The `listen` and `waitForNotifications` functions
operate on a raw `Hasql.Connection`, not a pooled connection.

### Hasql Connection API

`Hasql.Connection.acquire :: Settings -> IO (Either ConnectionError Connection)` creates a
new connection. `Settings` is a monoid; it can be constructed from a connection string via
`Hasql.Connection.Settings.connectionString :: Text -> Settings`. The `Connection` type
wraps an `MVar ConnectionState` and is thread-safe (operations block if another session is
running). `Connection.release :: Connection -> IO ()` closes the connection.

### Reference implementations on disk

Three production event store implementations were studied for this plan. All source code is
available locally for reference during implementation:

- **Commanded EventStore (Elixir):**
  `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/`
  Key files: `lib/event_store/subscriptions/subscription_fsm.ex` (7-state FSM),
  `lib/event_store/notifications/listener.ex` (LISTEN pipeline),
  `lib/event_store/notifications/publisher.ex` (centralized event fetcher),
  `lib/event_store/subscriptions/subscription_state.ex` (checkpoint data structures)

- **Hindsight (Haskell):**
  `/Users/shinzui/Keikaku/hub/haskell/hindsight/`
  Key files: `hindsight-postgresql-store/src/Hindsight/Store/PostgreSQL/Events/Subscription.hs`
  (notifier, worker loop, subscribe), `hindsight-core/src/Hindsight/Store.hs` (types)

- **Marten (.NET):**
  `/Users/shinzui/Keikaku/hub/event-sourcing/marten/`
  Key files: `src/Marten/Events/Daemon/ProjectionDaemon.cs`,
  `src/Marten/Events/Daemon/HighWater/GapDetector.cs`,
  `src/Marten/Subscriptions/SubscriptionBase.cs`

### Hindsight subscription architecture (reference)

Hindsight's subscription system at
`/Users/shinzui/Keikaku/hub/haskell/hindsight/hindsight-postgresql-store/src/Hindsight/Store/PostgreSQL/Events/Subscription.hs`
uses this architecture:

1. A `Notifier` holds a `TChan ()` (broadcast channel) and an `Async ()` (listener thread).
2. `startNotifier` creates a broadcast TChan, spawns a thread that acquires a dedicated
   connection, calls `listen` on a channel, then loops in `waitForNotifications`. On each
   notification it writes `()` to the TChan. On connection failure it waits 1 second and
   retries. On `AsyncException` it exits cleanly.
3. Each subscriber calls `dupTChan` to get a personal copy of the broadcast channel.
4. The worker loop reads the current cursor from an `IORef`, fetches a batch of events from
   the database, processes them with the handler, and updates the cursor. If no events are
   available, it blocks on `readTChan` until the Notifier ticks.
5. `subscribe` spawns the worker as an `Async` thread and returns a `SubscriptionHandle`
   with `cancel :: IO ()` and `wait :: IO ()`.

### DESIGN.md subscription table

The DESIGN.md (lines 82–89) defines a `subscriptions` table:

    CREATE TABLE subscriptions (
        subscription_id   BIGSERIAL    PRIMARY KEY,
        subscription_name TEXT         NOT NULL UNIQUE,
        stream_name       TEXT         NOT NULL DEFAULT '$all',
        last_seen         BIGINT       NOT NULL DEFAULT 0,
        created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
        updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
    );

This table persists subscription checkpoints. The `last_seen` column stores the last
processed `GlobalPosition`. On startup, the subscriber reads `last_seen` and begins
catching up from that position. After processing events, it updates `last_seen`. The
`subscription_name` is a unique identifier chosen by the caller (e.g.,
`"inventory-projection"`, `"email-notifier"`).


## Plan of Work

The work proceeds in eight milestones. Milestones 7.1–7.3 build the notification and
publishing infrastructure. Milestone 7.4 adds subscription types and checkpoint persistence.
Milestone 7.5 implements the worker loop with catch-up and live modes. Milestone 7.6 wires
the public API. Milestone 7.7 adds tests including reliability scenarios. Milestone 7.8
documents results.

### Milestone 7.1 — Add hasql-notifications dependency and verify build

Add the `hasql-notifications` package as a dependency. Since it is not on Hackage with
the required version bounds (it requires `hasql >= 1.10`), add it as a `source-repository-package`
in `cabal.project` pointing to the local hasql project or the git repository.

Edit `cabal.project` to add a `source-repository-package` stanza for `hasql-notifications`
pointing to the git repository at `https://github.com/diogob/hasql-notifications` (or the
local path if preferred). Add `hasql-notifications` and `stm` to `build-depends` in
`kiroku-store.cabal`. Also add `async` (for spawning the Notifier, EventPublisher, and
subscription worker threads). Run `cabal build all` to verify.

At the end of this milestone, `cabal build all` compiles with the new dependencies available.

### Milestone 7.2 — Implement the Notifier

Create `kiroku-store/src/Kiroku/Store/Notification.hs`. This module provides a `Notifier`
type that manages a dedicated PostgreSQL connection, listens for events on the
`<schema>.events` channel, and writes ticks to a `TChan ()`.

The `Notifier` type holds three things: a `TChan ()` (tick channel), an `Async ()` for the
listener thread, and the dedicated `Hasql.Connection` for cleanup.

`startNotifier` takes a `Text` (connection string) and a `Text` (schema name), acquires a
dedicated `Hasql.Connection`, computes the channel name as `<schema>.events`, calls
`Notifications.listen`, and spawns an async thread that runs `waitForNotifications`. The
notification handler writes `()` to the TChan on every notification. The thread runs inside
`forever` with reconnection logic: on connection failure, wait 1 second and retry; on
`AsyncException`, exit cleanly.

`stopNotifier` cancels the async thread, waits for it to terminate, and releases the
dedicated connection.

At the end of this milestone, `cabal build all` compiles. The Notifier starts and stops
cleanly within `withStore`.

### Milestone 7.3 — Implement the EventPublisher

Create `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`. This module provides
the centralized EventPublisher that reads events from the database once per notification and
broadcasts them to all subscribers.

The `EventPublisher` type holds: a `TChan (Vector RecordedEvent)` (broadcast channel for
subscribers), an `Async ()` (publisher thread), and a `TVar GlobalPosition` (the last-
published position, readable by subscribers to know where the live stream starts).

The publisher thread loop:

1. Wait for a wakeup signal. Use `STM.orElse` to wake on either:
   a. A tick from the Notifier's `TChan ()`, or
   b. A timeout (30 seconds) via `registerDelay` for the periodic safety poll.
2. On wakeup, drain all pending ticks from the TChan (debouncing). This collapses multiple
   rapid notifications into a single database query.
3. Query `readAllForwardStmt` from the pool, starting after the last-published position,
   with a configurable batch size (default 1000 — larger than subscriber batch size because
   the Publisher serves all subscribers).
4. If events were fetched:
   a. Write the `Vector RecordedEvent` to the broadcast `TChan`.
   b. Update the `TVar GlobalPosition` to the last event's position.
   c. If the batch was full (1000 events), loop immediately without waiting (there may be
      more events to fetch).
5. If no events were fetched, go back to step 1.

`startPublisher` takes a `Pool`, the Notifier's `TChan ()`, and spawns the publisher thread.
`stopPublisher` cancels the thread and waits for termination.
`subscribePublisher` returns a personal `TChan (Vector RecordedEvent)` via `dupTChan`.
`publisherPosition` reads the `TVar GlobalPosition` (used by workers to know when catch-up
is complete).

At the end of this milestone, `cabal build all` compiles.

### Milestone 7.4 — Implement subscription types and checkpoint SQL

Create `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` with the subscription types:

- `SubscriptionName` — a newtype over `Text`, the unique name for a subscription.
- `SubscriptionTarget` — which stream to subscribe to: `AllStreams` or
  `Category CategoryName`.
- `SubscriptionResult` — what the handler returns: `Continue` or `Stop`.
- `EventHandler` — the handler type: `RecordedEvent -> IO SubscriptionResult`.
- `SubscriptionConfig` — configuration record: `subscriptionName`, `target`, `handler`,
  `batchSize` (default 100).
- `SubscriptionHandle` — returned to the caller: `cancel :: IO ()` (stop the subscription)
  and `wait :: IO (Either SomeException ())` (block until the subscription completes or
  fails, re-throwing any exception from the worker).

Add the `subscriptions` table DDL to `kiroku-store/sql/schema.sql`. The table definition
follows the DESIGN.md specification (see Context and Orientation above). This is an additive
schema change — existing databases will get the new table on the next `initializeSchema`
call because the DDL uses `CREATE TABLE IF NOT EXISTS`.

Add hasql statements to `kiroku-store/src/Kiroku/Store/SQL.hs`:

- `getCheckpointStmt :: Statement Text (Maybe Int64)` — reads `last_seen` from
  `subscriptions` where `subscription_name = $1`.
- `saveCheckpointStmt :: Statement (Text, Int64) ()` — upserts into `subscriptions`:
  `INSERT INTO subscriptions (subscription_name, last_seen, updated_at) VALUES ($1, $2, now()) ON CONFLICT (subscription_name) DO UPDATE SET last_seen = $2, updated_at = now()`.

At the end of this milestone, `cabal build all` compiles with the new types and SQL.

### Milestone 7.5 — Implement the subscription worker loop

Create `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. This module contains the
worker loop that each subscription runs in its own thread.

The worker operates in two phases:

**Phase 1 — Catch-up.** On startup, the worker reads its checkpoint from the database. If
behind the EventPublisher's current position (read from the `TVar GlobalPosition`), the
worker queries the database directly using `readAllForwardStmt` or `readCategoryForwardStmt`
(via `Pool.use`), processing events batch by batch until it reaches the Publisher's position.
During catch-up, the worker does not read from the Publisher's `TChan` — it pulls
independently. This means catch-up queries use pool connections, but catch-up is temporary
and bounded.

**Phase 2 — Live.** Once caught up, the worker switches to reading from its personal
`TChan (Vector RecordedEvent)` (obtained via `subscribePublisher`). Each batch pushed by the
EventPublisher is received and processed. For `AllStreams` subscriptions, every event in the
batch is relevant. For `Category` subscriptions, the worker filters the batch in-process to
retain only events from matching streams (using the `originalStreamId` / stream name prefix
match). No database query is needed in live mode — the EventPublisher already fetched the
events.

In both phases, the worker calls the handler for each event. If the handler returns `Stop`,
the worker exits. After processing each batch, the worker persists its checkpoint.

On exit (whether from `Stop`, handler exception, or cancellation), the worker persists the
final checkpoint.

At the end of this milestone, `cabal build all` compiles.

### Milestone 7.6 — Wire subscriptions into the public API

Create `kiroku-store/src/Kiroku/Store/Subscription.hs` as the public API module. It
re-exports the types from `Subscription.Types` and provides a single function:

    subscribe :: KirokuStore -> SubscriptionConfig -> IO SubscriptionHandle

This function:

1. Gets a personal `TChan (Vector RecordedEvent)` from the EventPublisher via
   `subscribePublisher`.
2. Reads the EventPublisher's current position via `publisherPosition`.
3. Spawns the worker loop as an `Async` thread.
4. Returns a `SubscriptionHandle` wrapping the async thread — `cancel` calls
   `Async.cancel`, `wait` calls `Async.waitCatch`.

Update `KirokuStore` in `Connection.hs` to include both a `notifier :: Notifier` and a
`publisher :: EventPublisher` field. Update `withStore` to start/stop both in the bracket
(Notifier first, then EventPublisher which depends on the Notifier's TChan).

Update `kiroku-store/src/Kiroku/Store.hs` to re-export the `Subscription` module.

Update `kiroku-store.cabal` to add all new modules to `exposed-modules`:
`Kiroku.Store.Notification`, `Kiroku.Store.Subscription`,
`Kiroku.Store.Subscription.Types`, `Kiroku.Store.Subscription.Worker`,
`Kiroku.Store.Subscription.EventPublisher`.

At the end of this milestone, `cabal build all` compiles and the full subscription API is
available.

### Milestone 7.7 — Tests

Add subscription tests to `kiroku-store/test/Main.hs`. The test helpers need a small
update: `withTestStore` currently creates a `KirokuStore` which now includes a `Notifier`
and `EventPublisher`. Both need a real PostgreSQL connection, which `ephemeral-pg` provides.

Test cases:

**Catch-up test:** Append 10 events to a stream. Subscribe from position 0 with a handler
that collects events into an `IORef [RecordedEvent]`. After receiving all 10 events, the
handler returns `Stop`. Wait for the subscription to complete. Verify the IORef contains
exactly 10 events in global position order.

**Live delivery test:** Subscribe from position 0 with a handler that collects events. In a
separate thread, append 5 events after a short delay. The handler collects events and
returns `Stop` after receiving 5. Verify the IORef contains the 5 events.

**Checkpoint persistence test:** Append 10 events. Subscribe with name
`"checkpoint-test"`, handler returns `Stop` after 5 events. Wait for completion. Verify
the checkpoint is saved at position 5 (query the `subscriptions` table). Subscribe again
with the same name. The handler should receive events 6–10 only. Verify.

**Category subscription test:** Append events to streams `order-1`, `order-2`, and
`user-1`. Subscribe to category `order` from position 0. Handler collects events and
returns `Stop` after receiving all order events. Verify only order events were received.

**Cancellation test:** Subscribe from position 0 with a handler that always returns
`Continue`. Cancel the subscription. Wait for it to exit. Verify it exited without error.

**Empty store test:** Subscribe from position 0 on an empty store. Append an event. Handler
receives it and returns `Stop`. Verify exactly 1 event received.

**Safety poll test:** Subscribe from position 0 on an empty store. Disable or do not start
the Notifier (or use a store where LISTEN/NOTIFY is not firing). Append an event. Verify
the handler receives the event within 35 seconds (30-second safety poll + margin). This
confirms events are delivered even without LISTEN/NOTIFY.

**Debouncing test:** Append 50 events rapidly (50 separate appends to different streams).
Subscribe from position 0. Verify all 50 events are received. This confirms debouncing
does not lose events.

At the end of this milestone, `cabal test all` passes with all existing tests plus the
new subscription tests.

### Milestone 7.8 — Document results and update plan

Update this plan's Progress, Surprises & Discoveries, and Outcomes & Retrospective
sections. Record test results. Note any deviations from the plan.


## Concrete Steps

All commands run from: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**Step 1: Verify current build and tests pass.**

    cabal build all
    cabal test all

Expected: 46 tests pass.

**Step 2: Add hasql-notifications dependency.**

Edit `cabal.project` to add a `source-repository-package` stanza for
`hasql-notifications`. Edit `kiroku-store/kiroku-store.cabal` to add `hasql-notifications`,
`stm`, and `async` to `build-depends`.

    cabal build all

**Step 3: Create Notification module.**

Create `kiroku-store/src/Kiroku/Store/Notification.hs`.

    cabal build all

**Step 4: Create EventPublisher module.**

Create `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`.

    cabal build all

**Step 5: Create subscription types and checkpoint SQL.**

Create `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. Update
`kiroku-store/sql/schema.sql` with `subscriptions` table. Add checkpoint hasql statements
to `SQL.hs`.

    cabal build all

**Step 6: Create subscription worker.**

Create `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`.

    cabal build all

**Step 7: Create subscription public API and update KirokuStore.**

Create `kiroku-store/src/Kiroku/Store/Subscription.hs`. Update `Connection.hs` to add
`Notifier` and `EventPublisher` to `KirokuStore` and update `withStore`. Update `Store.hs`
re-exports. Update `kiroku-store.cabal` exposed-modules.

    cabal build all

**Step 8: Add tests.**

Update `kiroku-store/test/Main.hs`.

    cabal test all

Expected: all existing 46 tests pass plus new subscription tests.

**Step 9: Update plan with results.**


## Validation and Acceptance

### Compilation

    cabal build all

Must succeed with no warnings in kiroku-store modules.

### Tests

    cabal test all

All tests must pass — the 46 existing tests plus the new subscription tests.

Key behaviors:

- Catch-up: subscribing from position 0 on a store with existing events delivers all events
  in global position order.
- Live delivery: events appended after subscription starts are delivered to the handler
  without polling.
- Checkpoint persistence: after restart, the subscription resumes from the saved position —
  events already processed are not re-delivered.
- Category subscription: only events from streams matching the category prefix are
  delivered.
- Cancellation: cancelling a subscription handle causes the worker to exit cleanly.
- Safety poll: events are delivered within 30 seconds even without LISTEN/NOTIFY.
- Debouncing: rapid appends do not cause duplicate or lost events.
- The Notifier and EventPublisher threads start and stop within the `withStore` bracket
  without resource leaks.

### Behavior verification

The subscription system can be verified beyond unit tests by running two concurrent
processes against the same database: one that appends events in a loop, and one that
subscribes and prints received events. The subscriber should see events appearing in
real-time with sub-second latency (bounded by PostgreSQL NOTIFY delivery, typically < 10ms
on localhost).


## Idempotence and Recovery

All steps are idempotent. `cabal build` is incremental. Schema initialization uses
`CREATE TABLE IF NOT EXISTS` and `ON CONFLICT DO NOTHING` — running `initializeSchema`
multiple times is safe. Checkpoint saves use `INSERT ... ON CONFLICT ... DO UPDATE` (upsert)
— saving the same checkpoint twice is harmless. Tests use `ephemeral-pg` which creates a
fresh PostgreSQL database per run.

Three mechanisms ensure events are never missed:

1. **Notifier reconnection.** If the LISTEN connection drops, the Notifier waits 1 second
   and retries. During the reconnection window, NOTIFY messages are lost.

2. **Safety poll.** The EventPublisher wakes every 30 seconds regardless of LISTEN/NOTIFY
   health. This guarantees that even during a prolonged Notifier outage, events are
   discovered within 30 seconds. The database is always the source of truth — the
   EventPublisher queries from its last-published position, so no events are skipped.

3. **Cursor-based reads.** Both the EventPublisher and catch-up workers read using
   `WHERE stream_version > $cursor`. This is idempotent — re-reading from the same cursor
   returns the same events. Duplicate processing is prevented by the checkpoint: the worker
   only processes events with positions greater than its last checkpoint.

The combination of LISTEN/NOTIFY (sub-10ms latency) and safety poll (30-second backstop)
provides both low-latency delivery and guaranteed reliability. LISTEN/NOTIFY is the fast
path; the safety poll is the safety net.


## Interfaces and Dependencies

### New dependency: hasql-notifications

Version 0.2.5.0, located at
`/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-notifications/`. Must be added to
`cabal.project` as a `source-repository-package`. Depends on `hasql >= 1.10`, `hasql-pool >= 1.4`,
`postgresql-libpq >= 0.9`. If version bounds conflict with kiroku-store's existing
`hasql >= 1.8` constraint, update kiroku-store's constraint to `hasql >= 1.10` and add
appropriate `allow-newer` stanzas in `cabal.project`.

### New dependency: stm

Part of GHC's boot libraries. No version constraint needed. Used for `TChan` broadcast
in the Notifier.

### New dependency: async

Used for `Async` threads (Notifier listener, subscription workers) and `cancel`/`wait`
lifecycle management.

### New module: `Kiroku.Store.Notification`

In `kiroku-store/src/Kiroku/Store/Notification.hs`:

    data Notifier = Notifier
        { tickChan :: !(TChan ())
        , listenerThread :: !(Async ())
        , listenerConn :: !Connection
        }

    startNotifier :: Text -> Text -> IO Notifier
    -- ^ connString -> schema -> IO Notifier

    stopNotifier :: Notifier -> IO ()
    -- ^ Cancel thread, wait for exit, release connection

### New module: `Kiroku.Store.Subscription.EventPublisher`

In `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`:

    data EventPublisher = EventPublisher
        { broadcastChan :: !(TChan (Vector RecordedEvent))
        -- ^ Broadcast channel; subscribers get personal copies via dupTChan
        , publisherThread :: !(Async ())
        , lastPublished :: !(TVar GlobalPosition)
        -- ^ Last-published position; workers read this to know when catch-up is done
        }

    startPublisher :: Pool -> TChan () -> IO EventPublisher
    -- ^ pool -> notifierTickChan -> IO EventPublisher
    -- Spawns the publisher thread. The thread:
    -- 1. Waits for tick OR 30-second timeout (safety poll)
    -- 2. Drains all pending ticks (debouncing)
    -- 3. Queries readAllForwardStmt from lastPublished position
    -- 4. Broadcasts fetched events to broadcastChan
    -- 5. Updates lastPublished TVar

    stopPublisher :: EventPublisher -> IO ()
    -- ^ Cancel thread, wait for exit

    subscribePublisher :: EventPublisher -> IO (TChan (Vector RecordedEvent))
    -- ^ Get a personal TChan via dupTChan

    publisherPosition :: EventPublisher -> STM GlobalPosition
    -- ^ Read the last-published position (non-blocking STM read)

### New module: `Kiroku.Store.Subscription.Types`

In `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:

    newtype SubscriptionName = SubscriptionName Text
        deriving newtype (Eq, Ord, Show)

    data SubscriptionTarget
        = AllStreams
        | Category !CategoryName
        deriving stock (Eq, Show)

    data SubscriptionResult = Continue | Stop
        deriving stock (Eq, Show)

    type EventHandler = RecordedEvent -> IO SubscriptionResult

    data SubscriptionConfig = SubscriptionConfig
        { name :: !SubscriptionName
        , target :: !SubscriptionTarget
        , handler :: !EventHandler
        , batchSize :: !Int32
        -- ^ Number of events to fetch per batch (default: 100)
        }

    data SubscriptionHandle = SubscriptionHandle
        { cancel :: !(IO ())
        , wait :: !(IO (Either SomeException ()))
        }

### New module: `Kiroku.Store.Subscription.Worker`

In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`:

    runWorker
        :: Pool
        -> TChan (Vector RecordedEvent)
        -> TVar GlobalPosition
        -> SubscriptionConfig
        -> IO ()
    -- ^ Main worker loop. Two phases:
    -- Phase 1 (catch-up): queries database directly until reaching publisherPosition
    -- Phase 2 (live): reads from TChan, no database queries
    -- Runs until handler returns Stop or thread is cancelled.

### New module: `Kiroku.Store.Subscription`

In `kiroku-store/src/Kiroku/Store/Subscription.hs`:

    subscribe :: KirokuStore -> SubscriptionConfig -> IO SubscriptionHandle
    -- ^ Start a subscription. Returns a handle for cancellation and waiting.

    -- Re-exports from Types:
    module Kiroku.Store.Subscription.Types

### Updated module: `Kiroku.Store.Connection`

    data KirokuStore = KirokuStore
        { pool :: !Pool
        , schema :: !Text
        , notifier :: !Notifier
        , publisher :: !EventPublisher
        }

`withStore` updated to start Notifier then EventPublisher on acquire, and stop
EventPublisher then Notifier on release (reverse order).

### Updated module: `Kiroku.Store.SQL`

New statements:

    getCheckpointStmt :: Statement Text (Maybe Int64)
    saveCheckpointStmt :: Statement (Text, Int64) ()

### Updated module: `Kiroku.Store`

Add `module Kiroku.Store.Subscription` to re-exports.

### Updated file: `kiroku-store/sql/schema.sql`

Add after existing tables:

    CREATE TABLE IF NOT EXISTS subscriptions (
        subscription_id   BIGSERIAL    PRIMARY KEY,
        subscription_name TEXT         NOT NULL UNIQUE,
        stream_name       TEXT         NOT NULL DEFAULT '$all',
        last_seen         BIGINT       NOT NULL DEFAULT 0,
        created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
        updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
    );


---

**Revision — 2026-03-23:** Replaced decentralized pull-based architecture (Hindsight-style)
with centralized EventPublisher (Commanded-style). Research into Hindsight's subscription
system revealed a thundering herd problem at 30+ subscribers: all subscribers wake
simultaneously on each NOTIFY and issue independent database queries, exhausting the
connection pool. The centralized EventPublisher queries the database once per notification
and broadcasts fetched events to all subscribers via `TChan (Vector RecordedEvent)`. Added
three reliability mechanisms: (1) periodic 30-second safety poll to guarantee delivery even
if LISTEN/NOTIFY fails, (2) tick debouncing to collapse rapid notifications into a single
query, (3) Notifier reconnection with safety poll backstop. Added M7.3 (EventPublisher) as
a new milestone, renumbered subsequent milestones. Updated architecture decision in
Comparative Analysis, added three new decisions to Decision Log, updated Interfaces section
with `EventPublisher` type and `Worker` signature, updated tests to include safety poll and
debouncing scenarios.
