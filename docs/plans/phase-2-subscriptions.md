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

The subscription system uses a decentralized pull-based architecture informed by all three
major PostgreSQL event store implementations (Commanded, Hindsight, and Marten). A single
Notifier thread listens for PostgreSQL notifications and broadcasts a "tick" to all active
subscribers via STM. Each subscriber runs its own worker loop, pulling batches from the
database whenever it receives a tick or has unprocessed events remaining. This design
provides inherent backpressure — a slow subscriber simply pulls less frequently without
affecting other subscribers.

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

- [ ] M7.1: Add hasql-notifications dependency and verify build
- [ ] M7.2: Implement the Notifier (LISTEN thread + TChan broadcast)
- [ ] M7.3: Implement subscription types and checkpoint SQL
- [ ] M7.4: Implement the subscription worker loop
- [ ] M7.5: Wire subscriptions into the public API
- [ ] M7.6: Tests — catch-up, live delivery, checkpoint, cancellation
- [ ] M7.7: Document results and update plan


## Surprises & Discoveries

(None yet.)


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
fires once per append). The checkpoint concept (contiguous-ack advancement before
persisting). The `SubscriptionHandle` pattern (cancel + wait). The advisory lock two-part
key design (for future competing consumers).

**What we leave:** The centralized Publisher that fetches events in the notification
pipeline (creates a bottleneck — all subscribers share one Publisher's fetch throughput).
The 7-state FSM complexity (overkill for Phase 2a — `max_capacity`, `disconnected`, and
`unsubscribed` states are Phase 2c concerns). The OTP/GenStage supervision tree (Elixir-
specific). Competing consumers and partition-aware distribution (Phase 2c).

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

**What we take:** The decentralized pull-based architecture (each subscriber pulls
independently). The `TChan ()` broadcast pattern (no event data in the notification
channel). The worker loop structure (fetch → process → wait). The `Notifier` type design
and reconnection logic. The `SubscriptionHandle` pattern (`cancel` via `Async.cancel`,
`wait` via `Async.waitCatch`).

**What we leave:** The compound `(transactionXid8, seqNo)` cursor (we use contiguous
`GlobalPosition` instead). The `EventMatcher` type-level machinery (complex, and our
handlers are simpler — they receive `RecordedEvent` and decide what to do). Hindsight's
limited production track record means we validate the architecture with our own tests rather
than trusting it at face value.

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

### Architecture decision: Decentralized pull-based with LISTEN/NOTIFY

The chosen architecture combines Hindsight's decentralized pull-based worker model with
Commanded's NOTIFY trigger design and Marten's error handling philosophy:

1. **Notification layer (from Commanded):** PostgreSQL NOTIFY trigger fires on `streams`
   table, schema-scoped channel, once per append.

2. **Broadcast layer (from Hindsight):** Single Notifier thread, `TChan ()` broadcast, each
   subscriber gets a personal channel via `dupTChan`. No event data flows through the
   notification channel.

3. **Worker layer (from Hindsight):** Each subscriber has its own worker thread that
   independently pulls batches from the database. Inherent backpressure — slow subscribers
   don't affect fast ones.

4. **Checkpoint layer (from Commanded):** Persistent checkpoint table, upsert-based saves.
   Contiguous-ack advancement deferred to Phase 2c (simple last-processed-position
   checkpointing is sufficient for Phase 2a).

5. **Error handling (from Marten, deferred):** Skip + dead-letter taxonomy for Phase 2b
   projections. Phase 2a handlers throw on error — the subscription stops, which is the
   safest default.

This avoids the centralized Publisher bottleneck (Commanded), eliminates polling overhead
(Marten), and leverages the proven `TChan` broadcast pattern (Hindsight) — while using
Kiroku's gap-free `GlobalPosition` as a simpler cursor than any of the three reference
implementations.


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

- Decision: Use a decentralized pull-based architecture (each subscriber pulls independently)
  rather than a centralized Publisher that fetches and distributes events.
  Rationale: Commanded's architecture routes all event data through a centralized Publisher
  (GenStage consumer) that fetches events from storage and broadcasts via PubSub. This
  creates a throughput bottleneck — all subscribers share one Publisher's fetch capacity. If
  one subscriber is slow, backpressure propagates to the Publisher, delaying all subscribers.
  Hindsight's approach gives each subscriber its own worker thread that independently pulls
  from the database. The Notifier merely broadcasts a `()` tick — no event data flows through
  the notification channel. This provides inherent backpressure per-subscriber, eliminates the
  Publisher as a single point of failure, and simplifies the code. Marten's polling approach
  was also rejected — LISTEN/NOTIFY provides sub-10ms notification latency vs. polling's
  inherent delay and database load. The trade-off is that each subscriber independently
  queries the database, which means N subscribers issue N queries per tick. For typical
  workloads (< 20 concurrent subscribers) this is acceptable; the database is the source of
  truth regardless.
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

(To be filled during and after implementation.)


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

The work proceeds in seven milestones. Milestones 7.1–7.2 set up the notification
infrastructure. Milestone 7.3 adds checkpoint persistence. Milestone 7.4 implements the
core subscription worker loop. Milestone 7.5 wires the public API. Milestone 7.6 adds
tests. Milestone 7.7 documents results.

### Milestone 7.1 — Add hasql-notifications dependency and verify build

Add the `hasql-notifications` package as a dependency. Since it is not on Hackage with
the required version bounds (it requires `hasql >= 1.10`), add it as a `source-repository-package`
in `cabal.project` pointing to the local hasql project or the git repository.

Edit `cabal.project` to add a `source-repository-package` stanza for `hasql-notifications`
pointing to the git repository at `https://github.com/diogob/hasql-notifications` (or the
local path if preferred). Add `hasql-notifications` and `stm` to `build-depends` in
`kiroku-store.cabal`. Also add `async` (for spawning the Notifier and subscription worker
threads). Run `cabal build all` to verify.

At the end of this milestone, `cabal build all` compiles with the new dependencies available.

### Milestone 7.2 — Implement the Notifier

Create `kiroku-store/src/Kiroku/Store/Notification.hs`. This module provides a `Notifier`
type that manages a dedicated PostgreSQL connection, listens for events on the
`<schema>.events` channel, and broadcasts ticks to all subscribers via a `TChan ()`.

The `Notifier` type holds three things: a broadcast `TChan ()`, an `Async ()` for the
listener thread, and the dedicated `Hasql.Connection` for cleanup.

`startNotifier` takes a `Text` (connection string) and a `Text` (schema name), acquires a
dedicated `Hasql.Connection`, computes the channel name as `<schema>.events`, calls
`Notifications.listen`, and spawns an async thread that runs `waitForNotifications`. The
notification handler writes `()` to the broadcast TChan on every notification. The
thread runs inside `forever` with reconnection logic: on connection failure, wait 1 second
and retry; on `AsyncException`, exit cleanly.

`stopNotifier` cancels the async thread, waits for it to terminate, and releases the
dedicated connection.

`subscribeNotifier` returns a personal `TChan ()` via `dupTChan`.

Update `KirokuStore` in `Connection.hs` to include a `notifier :: Notifier` field. Update
`withStore` to start the Notifier on acquire and stop it on release.

At the end of this milestone, `cabal build all` compiles. The Notifier starts and stops
cleanly within `withStore`.

### Milestone 7.3 — Implement subscription types and checkpoint SQL

Create `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` with the subscription types:

- `SubscriptionName` — a newtype over `Text`, the unique name for a subscription.
- `SubscriptionTarget` — which stream to subscribe to: `AllStreams` or
  `Category CategoryName`.
- `SubscriptionResult` — what the handler returns: `Continue` or `Stop`.
- `EventHandler` — the handler type: `RecordedEvent -> IO SubscriptionResult`.
- `SubscriptionConfig` — configuration record: `subscriptionName`, `target`, `handler`,
  `batchSize` (default 100), `startFrom` (a `GlobalPosition`, default 0).
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

### Milestone 7.4 — Implement the subscription worker loop

Create `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. This module contains the
worker loop that each subscription runs in its own thread.

The worker loop follows Hindsight's pattern:

1. Read the checkpoint from the database. If no checkpoint exists and `startFrom` is
   provided, use that position; otherwise start from 0.
2. Enter the main loop:
   a. Fetch a batch of events from the database starting after the current cursor. Use
      `readAllForward` for `AllStreams` or `readCategoryForward` for `Category`.
   b. If the batch is non-empty, process each event by calling the handler. If any handler
      call returns `Stop`, exit the loop. Update the cursor to the last event's global
      position. Persist the checkpoint.
   c. If the batch is empty, wait for a tick from the Notifier's TChan. On tick, loop back
      to fetch again.
3. On exit (whether from `Stop` or cancellation), persist the final checkpoint.

The worker uses `Pool.use` from the store's pool to execute reads and checkpoint saves. It
does not need its own dedicated connection — reads and checkpoint writes are short-lived
sessions that return the connection to the pool immediately.

The fetch step uses the Store effect's existing `readAllForwardStmt` and
`readCategoryForwardStmt` SQL statements directly (via `Pool.use` + `Session.statement`),
bypassing the effectful layer. This is intentional — the subscription worker runs in `IO`,
not in an `Eff` monad, because it is a long-lived concurrent thread that manages its own
lifecycle.

At the end of this milestone, `cabal build all` compiles.

### Milestone 7.5 — Wire subscriptions into the public API

Create `kiroku-store/src/Kiroku/Store/Subscription.hs` as the public API module. It
re-exports the types from `Subscription.Types` and provides a single function:

    subscribe :: KirokuStore -> SubscriptionConfig -> IO SubscriptionHandle

This function:

1. Gets a personal TChan from the Notifier via `subscribeNotifier`.
2. Spawns the worker loop as an `Async` thread.
3. Returns a `SubscriptionHandle` wrapping the async thread — `cancel` calls
   `Async.cancel`, `wait` calls `Async.waitCatch`.

Update `kiroku-store/src/Kiroku/Store.hs` to re-export the `Subscription` module.

Update `kiroku-store.cabal` to add all new modules to `exposed-modules`:
`Kiroku.Store.Notification`, `Kiroku.Store.Subscription`,
`Kiroku.Store.Subscription.Types`, `Kiroku.Store.Subscription.Worker`.

At the end of this milestone, `cabal build all` compiles and the full subscription API is
available.

### Milestone 7.6 — Tests

Add subscription tests to `kiroku-store/test/Main.hs`. The test helpers need a small
update: `withTestStore` currently creates a `KirokuStore` which now includes a `Notifier`.
The `Notifier` needs a real PostgreSQL connection, which `ephemeral-pg` provides.

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

At the end of this milestone, `cabal test all` passes with all existing tests plus the
new subscription tests.

### Milestone 7.7 — Document results and update plan

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

Create `kiroku-store/src/Kiroku/Store/Notification.hs`. Update `Connection.hs` to add
`Notifier` to `KirokuStore` and update `withStore`.

    cabal build all

**Step 4: Create subscription types and checkpoint SQL.**

Create `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. Update
`kiroku-store/sql/schema.sql` with `subscriptions` table. Add checkpoint hasql statements
to `SQL.hs`.

    cabal build all

**Step 5: Create subscription worker.**

Create `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`.

    cabal build all

**Step 6: Create subscription public API.**

Create `kiroku-store/src/Kiroku/Store/Subscription.hs`. Update `Store.hs` re-exports.
Update `kiroku-store.cabal` exposed-modules.

    cabal build all

**Step 7: Add tests.**

Update `kiroku-store/test/Main.hs`.

    cabal test all

Expected: all existing 46 tests pass plus new subscription tests.

**Step 8: Update plan with results.**


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
- The Notifier thread starts and stops within the `withStore` bracket without resource
  leaks.

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

If the Notifier connection drops, the reconnection logic waits 1 second and retries. During
the reconnection window, subscribers simply wait on the TChan — they miss no events because
the next tick will trigger a catch-up pull from the database. LISTEN/NOTIFY is not durable
(notifications are lost if no connection is listening), but the pull-based architecture
makes this safe: the database is the source of truth, not the notification channel.


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
        { broadcastChan :: !(TChan ())
        , listenerThread :: !(Async ())
        , listenerConn :: !Connection
        }

    startNotifier :: Text -> Text -> IO Notifier
    -- ^ connString -> schema -> IO Notifier

    stopNotifier :: Notifier -> IO ()
    -- ^ Cancel thread, wait for exit, release connection

    subscribeNotifier :: Notifier -> IO (TChan ())
    -- ^ Get a personal TChan via dupTChan

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

    runWorker :: Pool -> TChan () -> SubscriptionConfig -> IO ()
    -- ^ Main worker loop. Runs until handler returns Stop or thread is cancelled.

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
        }

`withStore` updated to call `startNotifier` / `stopNotifier` in the bracket.

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
