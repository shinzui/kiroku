# Kiroku (記録) — Implementation Blueprint

> PostgreSQL event store implemented in Haskell.
> Synthesized from analysis of Marten, Message-DB, Commanded EventStore, Hindsight, and others.

## Core Design Choice: Strategy E (Atomic Row-Level Counter)

Every PostgreSQL event store must solve the tension between **concurrent write throughput** and **gap-free global ordering** for the `$all` stream. Kiroku uses **Strategy E** — an atomic `UPDATE ... RETURNING` on a dedicated `$all` row that claims contiguous global positions within the same transaction that inserts events.

**Why Strategy E over the alternatives:**

| Property | Strategy E (Kiroku) | Strategy D (Hindsight) | Strategy B (Serialized) | Strategy A (Marten) |
|---|---|---|---|---|
| Global positions | Contiguous (1,2,3…) | Non-contiguous (xid8 gaps) | Contiguous | Contiguous (after HWM) |
| Read-your-own-writes | Immediate | Delayed (MVCC barrier) | Immediate | Delayed (polling) |
| MVCC vulnerability | None | `pg_snapshot_xmin` stalls | None | None |
| Write throughput ceiling | ~50K events/s (batched) | No global ceiling | ~5K events/s | High |
| Operational complexity | Low | Medium (pg_stat_activity scoping) | Low | High (gap detection) |
| SQL complexity | Standard integers | xid8 casting | Standard | lead() window functions |

**Throughput ceiling is acceptable.** At 0.2ms per lock cycle on the `$all` row, the ceiling is ~5K batches/s. With 10 events per batch, that's ~50K events/s — 4.3 billion events/day. If this ceiling is ever reached, Strategy D (Hindsight's MVCC approach with `pg_stat_activity` scoping) is the escape hatch.

## What We Take From Each Implementation

| Source | Adopt | Skip |
|---|---|---|
| **Commanded** (Elixir) | CTE-based atomic append, `$all` as stream_id=0 in streams table, link table design (stream_events), NOTIFY trigger on streams table (not events), trigger-based immutability with gated hard deletes, subscription FSM concepts, three connection types | OTP/GenStage specifics |
| **Hindsight** (Haskell) | hasql patterns, per-stream advisory locks, LISTEN/NOTIFY subscription architecture, TChan broadcast, dual sync/async projections, `waitForEvent` API, multi-stream transactions, server-side event filtering | xid8-based ordering, SERIALIZABLE isolation |
| **Message-DB** | Stream naming convention (`category-id`), function-based API minimalism | Missing $all stream, no subscription mechanism |
| **Marten** (.NET) | Projection type taxonomy (inline/async/live), error handling in projections (skip/dead-letter), enrichment concepts | Gap detection, polling subscriptions, code generation |

---

## Schema

### Tables

```sql
-- Streams (including $all as stream_id = 0)
CREATE TABLE streams (
    stream_id    BIGSERIAL    PRIMARY KEY,
    stream_uuid  TEXT         NOT NULL,
    stream_version BIGINT     NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT ix_streams_stream_uuid UNIQUE (stream_uuid)
);

-- Seed the $all stream
INSERT INTO streams (stream_id, stream_uuid, stream_version)
VALUES (0, '$all', 0);

-- Reset sequence past the reserved stream_id=0
SELECT setval('streams_stream_id_seq', (SELECT MAX(stream_id) FROM streams));

-- Events (flat table — stream membership tracked in stream_events)
CREATE TABLE events (
    event_id       UUID         PRIMARY KEY DEFAULT uuidv7(),  -- PostgreSQL 18+
    event_type     TEXT         NOT NULL,
    causation_id   UUID,
    correlation_id UUID,
    data           JSONB        NOT NULL,
    metadata       JSONB,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Stream-event junction (each event gets 2+ rows: source stream + $all + any links)
CREATE TABLE stream_events (
    event_id                UUID   NOT NULL REFERENCES events(event_id),
    stream_id               BIGINT NOT NULL REFERENCES streams(stream_id),
    stream_version          BIGINT NOT NULL,
    original_stream_id      BIGINT NOT NULL,
    original_stream_version BIGINT NOT NULL,
    PRIMARY KEY (event_id, stream_id)
);
```

**kiroku** (framework) adds:

```sql
-- Subscription checkpoints (managed by kiroku framework, not kiroku-store)
CREATE TABLE subscriptions (
    subscription_id   BIGSERIAL    PRIMARY KEY,
    subscription_name TEXT         NOT NULL UNIQUE,
    stream_uuid       TEXT         NOT NULL DEFAULT '$all',
    last_seen         BIGINT       NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
```

### Indexes

```sql
-- Primary read path: fetch events from a stream in order
CREATE INDEX ix_stream_events_stream_version
    ON stream_events (stream_id, stream_version);

-- Event type filtering (for server-side subscription filtering)
CREATE INDEX ix_events_event_type
    ON events (event_type);

-- Correlation tracing
CREATE INDEX ix_events_correlation_id
    ON events (correlation_id) WHERE correlation_id IS NOT NULL;

-- Causation tracing
CREATE INDEX ix_events_causation_id
    ON events (causation_id) WHERE causation_id IS NOT NULL;
```

### Triggers

```sql
-- NOTIFY on stream changes (fires once per append, not per event)
CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '.events',
        NEW.stream_uuid || ',' || NEW.stream_id || ',' || NEW.stream_version
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER stream_events_notify
    AFTER INSERT OR UPDATE ON streams
    FOR EACH ROW EXECUTE FUNCTION notify_events();

-- Immutability: prevent event mutation
CREATE OR REPLACE FUNCTION prevent_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutable table: % cannot be updated', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER no_update_events
    BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

CREATE TRIGGER no_update_stream_events
    BEFORE UPDATE ON stream_events
    FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

-- Gated hard deletes (for maintenance/GDPR only)
CREATE OR REPLACE FUNCTION protect_deletion() RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('kiroku.enable_hard_deletes', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Hard deletes require: SET LOCAL kiroku.enable_hard_deletes = ''on''';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER no_delete_events
    BEFORE DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

CREATE TRIGGER no_delete_stream_events
    BEFORE DELETE ON stream_events
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

CREATE TRIGGER no_delete_streams
    BEFORE DELETE ON streams
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();
```

---

## Core Operations

### Append Events

The entire append is a single CTE — one SQL round-trip. Uses parallel `unnest` to handle variable-length event batches without dynamic SQL.

**With expected version check (optimistic concurrency):**

```sql
WITH
  new_events AS (
    SELECT *
    FROM unnest(
        $1::uuid[],         -- event_ids (caller-supplied or pre-generated UUIDv7s)
        $2::text[],         -- event_types
        $3::uuid[],         -- causation_ids
        $4::uuid[],         -- correlation_ids
        $5::jsonb[],        -- data
        $6::jsonb[],        -- metadata
        $7::timestamptz[]   -- created_at
    ) WITH ORDINALITY AS t(
        event_id, event_type, causation_id, correlation_id,
        data, metadata, created_at, idx
    )
  ),

  -- Step 1: Update source stream version (optimistic concurrency)
  stream_update AS (
    UPDATE streams
    SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_uuid = $8
      AND stream_version = $9    -- expected_version
    RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
  ),

  -- Step 2: Insert event payloads (only if version check passed — no orphans)
  inserted_events AS (
    INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
    SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
    FROM new_events
    WHERE EXISTS (SELECT 1 FROM stream_update)
    ORDER BY idx
  ),

  -- Step 3: Link events to source stream
  source_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN stream_update su
  ),

  -- Step 4: Atomically claim global positions (only if source stream was updated)
  all_update AS (
    UPDATE streams
    SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_id = 0
      AND EXISTS (SELECT 1 FROM stream_update)
    RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
  ),

  -- Step 5: Link events to $all
  all_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN all_update au
    CROSS JOIN stream_update su
  )

-- Return result (empty = version conflict)
SELECT
    su.stream_id,
    su.initial_version + (SELECT count(*) FROM new_events) AS stream_version,
    au.initial_global_version + (SELECT count(*) FROM new_events) AS global_position
FROM stream_update su
CROSS JOIN all_update au;
```

**Key detail:** All data-modifying CTEs are gated on `stream_update` via `EXISTS (SELECT 1 FROM stream_update)`. If the expected version doesn't match, `stream_update` returns 0 rows, and every subsequent step (event insert, `$all` update, link inserts) is skipped. The final SELECT returns 0 rows — signaling a version conflict. No orphaned events are created.

**Event ID pre-generation:** The CTE requires `$1::uuid[]` — every element must be a concrete UUID. Since `DEFAULT` cannot be used inside `unnest` arrays, the Haskell store layer pre-generates UUIDv7s client-side for any `EventData` with `eventId = Nothing` before building the parameter arrays. The `DEFAULT uuidv7()` on the column is a fallback for direct SQL use.

**Variants needed:**

| Variant | Source Stream Step | Use Case |
|---|---|---|
| `append_expected_version` | UPDATE ... WHERE stream_version = $expected | Standard optimistic concurrency |
| `append_stream_exists` | UPDATE ... WHERE stream_uuid = $uuid (no version check, fail if 0 rows) | Append to existing stream, any version |
| `append_any_version` | UPDATE ... (no version check) / INSERT on miss | Append-only logging streams, create-or-append |
| `append_no_stream` | INSERT ... ON CONFLICT DO NOTHING | Creating a new stream (fail if exists) |
| `link_events` | (no event insert, link existing event_ids) | Projections building custom streams |

### Read Events

**From a specific stream:**

```sql
SELECT e.event_id, e.event_type, e.causation_id, e.correlation_id,
       e.data, e.metadata, e.created_at,
       se.stream_version, se.original_stream_id, se.original_stream_version
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = $1
  AND se.stream_version > $2      -- start_version (cursor)
ORDER BY se.stream_version ASC
LIMIT $3;                          -- batch_size
```

**From $all (global stream):**

```sql
-- Same query with stream_id = 0
SELECT e.event_id, e.event_type, e.causation_id, e.correlation_id,
       e.data, e.metadata, e.created_at,
       se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = 0
  AND se.stream_version > $1
ORDER BY se.stream_version ASC
LIMIT $2;
```

**By category** (using Message-DB naming convention: `category-id`):

```sql
SELECT e.event_id, e.event_type, e.causation_id, e.correlation_id,
       e.data, e.metadata, e.created_at,
       se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
JOIN streams s ON s.stream_id = se.original_stream_id
WHERE se.stream_id = 0
  AND se.stream_version > $1
  AND s.stream_uuid LIKE $2 || '-%'     -- category prefix
ORDER BY se.stream_version ASC
LIMIT $3;
```

### Stream Metadata

**Get stream info (version, existence check):**

```sql
SELECT stream_id, stream_uuid, stream_version, created_at, deleted_at
FROM streams
WHERE stream_uuid = $1;
```

Useful for pre-append version checks, aggregate loading (to know current version before reading events), and existence checks. Returns empty if stream doesn't exist.

### Subscribe (LISTEN/NOTIFY)

The notification channel is schema-scoped: `<schema>.events` (e.g., `public.events`).

**Subscriber workflow:**

1. Catch up: read all events from `last_seen` to current head
2. LISTEN on `<schema>.events`
3. On NOTIFY: fetch new events from `last_seen`, process, advance checkpoint
4. Periodically re-poll as safety net (notifications are not durable across disconnects)

---

## Haskell Architecture

### Core Types

```haskell
-- Stream identification
newtype StreamUuid = StreamUuid Text
newtype StreamId = StreamId Int64

-- Event identification
newtype EventId = EventId UUID
newtype EventType = EventType Text

-- Positions
newtype StreamVersion = StreamVersion Int64
newtype GlobalPosition = GlobalPosition Int64

-- Version expectations for appends
data ExpectedVersion
    = NoStream                      -- Stream must not exist yet
    | StreamExists                  -- Must exist, any version
    | ExactVersion StreamVersion    -- Must match exactly
    | AnyVersion                    -- Create or append, don't care

-- What the caller provides
data EventData = EventData
    { eventId       :: Maybe EventId  -- Nothing = pre-generated UUIDv7 by store; Just = caller-supplied (for idempotent retries)
    , eventType     :: EventType
    , eventData     :: Value          -- JSONB payload
    , eventMetadata :: Maybe Value   -- JSONB metadata
    , causationId   :: Maybe UUID
    , correlationId :: Maybe UUID
    }

-- Stream metadata (from getStream)
data StreamInfo = StreamInfo
    { streamInfoId      :: StreamId
    , streamInfoUuid    :: StreamUuid
    , streamInfoVersion :: StreamVersion
    , streamInfoCreatedAt :: UTCTime
    , streamInfoDeletedAt :: Maybe UTCTime
    }

-- What comes back from a read
data RecordedEvent = RecordedEvent
    { recordedEventId             :: EventId
    , recordedEventType           :: EventType
    , recordedStreamVersion       :: StreamVersion       -- version in the stream being read
    , recordedGlobalPosition      :: GlobalPosition
    , recordedOriginalStreamId    :: StreamId             -- stream the event was originally appended to
    , recordedOriginalVersion     :: StreamVersion        -- version in the original stream
    , recordedData                :: Value
    , recordedMetadata            :: Maybe Value
    , recordedCausationId         :: Maybe UUID
    , recordedCorrelationId       :: Maybe UUID
    , recordedCreatedAt           :: UTCTime
    }

-- Append result
data AppendResult = AppendResult
    { appendStreamId       :: StreamId
    , appendStreamVersion  :: StreamVersion
    , appendGlobalPosition :: GlobalPosition
    }

-- Errors
data AppendError
    = WrongExpectedVersion StreamUuid ExpectedVersion StreamVersion
    | StreamNotFound StreamUuid
    | StreamAlreadyExists StreamUuid
    | DuplicateEvent EventId
```

### Module Structure

```
kiroku-store/                           -- Package 1: high-performance event store
  src/
    Kiroku/
      Store.hs                        -- Public API, re-exports, KirokuStore handle
      Store/
        Types.hs                      -- Core domain types
        Append.hs                     -- appendToStream and variants
        Read.hs                       -- readStream, readAll, readCategory, getStream
        Link.hs                       -- linkToStream (for projection-built streams)
        Schema.hs                     -- DDL, migrations, initialization
        Connection.hs                 -- hasql-pool, connection config, health checks
        SQL.hs                        -- All SQL statements (hasql)
        Error.hs                      -- Error types, PG error mapping

kiroku/                                 -- Package 2: framework (depends on kiroku-store)
  src/
    Kiroku.hs                         -- Public API, re-exports
    Kiroku/
      Notification.hs                 -- LISTEN/NOTIFY via libpq
      Subscription.hs                 -- Subscription manager
      Subscription/
        State.hs                      -- Subscription FSM states
        Checkpoint.hs                 -- Progress tracking, persistence
        Worker.hs                     -- Pull-based subscription workers
      Projection.hs                   -- Projection framework
      Projection/
        Sync.hs                       -- In-transaction projections
        Async.hs                      -- Background projection workers
```

### Connection Architecture

Split across two packages, following Commanded's three-connection-type pattern:

**kiroku-store** — minimal, focused handle:

```haskell
data KirokuStore = KirokuStore
    { storePool      :: Pool          -- hasql-pool: read/write operations
    , storeSchema    :: Text          -- schema name (multi-tenant)
    }
```

1. **Read/write pool** (`hasql-pool`): Parameterized pool size (default 10). All append, read, link, checkpoint operations go through here.

**kiroku** (framework) adds additional connections:

```haskell
data Kiroku = Kiroku
    { kirokuStore    :: KirokuStore   -- underlying store
    , listenConn     :: Connection    -- raw libpq: LISTEN/NOTIFY
    , lockConns      :: TVar (Map SubscriptionId Connection)
                                      -- dedicated hasql: advisory locks
    , notifier       :: Notifier      -- broadcasts NOTIFY to subscribers
    }
```

2. **LISTEN connection** (raw `libpq`): Single persistent connection. hasql doesn't natively support LISTEN/NOTIFY, so use `postgresql-libpq` directly. This connection stays open for the framework's lifetime.
3. **Lock connections** (dedicated `hasql` connections): One per active subscription. Advisory locks are session-scoped — releasing the connection releases the lock. Monitored for death (PostgreSQL auto-releases locks on connection drop).

### LISTEN/NOTIFY Architecture

Following Hindsight's pattern with STM broadcast:

```haskell
data Notifier = Notifier
    { notifyChan  :: TChan Notification   -- broadcast channel
    , notifyThread :: Async ()            -- listener thread
    }

data Notification = Notification
    { notifStreamUuid :: StreamUuid
    , notifStreamId   :: StreamId
    , notifVersion    :: StreamVersion
    }

-- Each subscriber gets a duplicate TChan (STM broadcast)
subscribe :: Notifier -> IO (TChan Notification)
subscribe n = atomically $ dupTChan (notifyChan n)
```

### PostgreSQL Error Mapping

Following Commanded's pattern:

| PostgreSQL Error | Constraint | Kiroku Error |
|---|---|---|
| `unique_violation` (23505) | `events_pkey` | `DuplicateEvent` |
| `unique_violation` (23505) | `ix_streams_stream_uuid` | `StreamAlreadyExists` (retryable) |
| `unique_violation` (23505) | other | `WrongExpectedVersion` |
| `foreign_key_violation` (23503) | — | `StreamNotFound` |

### Key Dependencies

**kiroku-store:**

| Package | Purpose |
|---|---|
| `hasql` + `hasql-pool` + `hasql-transaction` | PostgreSQL client, pooling, transactions |
| `hasql-th` | Compile-time SQL type checking (quasi-quotes) |
| `uuid` | UUID generation and types (client-side UUIDv7 pre-generation) |
| `aeson` | JSONB event data and metadata encoding |
| `vector` | Efficient array parameters for batch appends |

**kiroku** (framework, additional deps):

| Package | Purpose |
|---|---|
| `postgresql-libpq` | Raw LISTEN/NOTIFY support |
| `stm` | TChan for notification broadcast |
| `async` | Concurrent subscription workers |

---

## Subscription State Machine

Adapted from Commanded's 7-state FSM. Simplified for initial implementation, with states added incrementally.

```
                    ┌──────────────┐
                    │   Initial    │  Load/create subscription record
                    └──────┬───────┘  Acquire advisory lock
                           │
                    ┌──────▼───────┐
              ┌────►│  CatchingUp  │  Read forward from last_seen
              │     └──────┬───────┘  Batch processing
              │            │ caught up
              │     ┌──────▼───────┐
              │     │  Subscribed  │  Live: process NOTIFY events
              │     └──┬───────┬───┘  Continuity check on each notification
              │        │       │
    gap       │        │       │ queue full
  detected    │        │  ┌────▼───────┐
              │        │  │ MaxCapacity │  Only process acks until queue drains
              │        │  └────────────┘
              │        │
              │   ┌────▼───────────┐
              └───┤  Disconnected  │  Lock lost → reset → retry
                  └────┬───────────┘
                       │
                  ┌────▼───────────┐
                  │  Unsubscribed  │  Terminal: all subscribers removed
                  └────────────────┘
```

**Phase 2a implements:** Initial → CatchingUp → Subscribed (3 states).
**Phase 2c adds:** MaxCapacity, Disconnected, Unsubscribed.

### Checkpoint Algorithm

From Commanded: contiguous-ack advancement.

- Track `in_flight` (ordered list of positions sent) and `acknowledged` (set of acked positions)
- On ack: add to `acknowledged`, walk `in_flight` from front, advance `last_seen` through contiguous acknowledged positions
- Persist: threshold-based (every N acks) or timer-based (every M ms)
- On shutdown: always persist final checkpoint

---

## Implementation Phases

The project is split into two packages: **kiroku-store** (high-performance PostgreSQL event store) and **kiroku** (framework for projections, subscriptions, and higher-level APIs). Both are designed upfront, but kiroku-store ships first as a standalone, usable library.

### Phase 1 — kiroku-store

A focused, high-performance event store library. Append events, read them back, link streams, manage lifecycle. No subscription or projection machinery.

#### 1a — Foundation

**Goal:** Core append/read with optimistic concurrency.

- [ ] Project scaffolding (cabal, nix)
- [ ] `Kiroku.Store.Types` — core domain types
- [ ] `Kiroku.Store.Schema` — DDL execution, `$all` seed, schema initialization (schema-parameterized)
- [ ] `Kiroku.Store.Connection` — hasql-pool, connection config
- [ ] `Kiroku.Store.SQL` — hasql statements for append (all 3 variants) and read
- [ ] `Kiroku.Store.Append` — `appendToStream`, `appendToStreamAnyVersion`, `appendToStreamNoStream`
- [ ] `Kiroku.Store.Read` — `readStreamForward`, `readAllForward`, `readStreamBackward`, `readAllBackward`, `getStream`
- [ ] `Kiroku.Store.Error` — error types, PostgreSQL error code mapping
- [ ] `Kiroku.Store` — `KirokuStore` handle, `withStore` bracket, public API re-exports
- [ ] Tests: append with version check, version conflict, read-your-own-writes, concurrent appends to different streams

**Batch limit:** 1,000 events per CTE (7 array params × 1,000 = 7,000, under PostgreSQL's 65,535 parameter limit). Larger appends chunked within a single transaction.

#### 1b — Links & Categories

**Goal:** Stream linking and category reads.

- [ ] `Kiroku.Store.Link` — link existing events to new streams (for projection-built streams)
- [ ] `Kiroku.Store.Read` — `readCategory` (Message-DB naming convention: `category-id`)
- [ ] Multi-stream transactions (write to N streams atomically, per-stream version checks)
- [ ] Tests: link events, category reads, multi-stream atomicity

#### 1c — Lifecycle & Deletes

**Goal:** Stream lifecycle management.

- [ ] Soft delete (`UPDATE streams SET deleted_at = now()`)
- [ ] Gated hard delete (cascading CTE, requires session variable)
- [ ] Connection health checks
- [ ] `idle_in_transaction_session_timeout` on all connections
- [ ] Metrics / observability hooks
- [ ] Tests: soft delete hides stream, hard delete cascades, health checks

### Phase 2 — kiroku (framework)

Builds on kiroku-store. Adds subscriptions, projections, and higher-level APIs. Depends on kiroku-store as a library.

#### 2a — Subscriptions

**Goal:** Real-time event delivery via LISTEN/NOTIFY.

- [ ] `Kiroku.Notification` — libpq LISTEN connection, `Notifier` with TChan broadcast
- [ ] `Kiroku.Subscription.State` — FSM (Initial, CatchingUp, Subscribed)
- [ ] `Kiroku.Subscription.Checkpoint` — contiguous-ack checkpoint persistence
- [ ] `Kiroku.Subscription.Worker` — pull-based worker loop with NOTIFY wakeup
- [ ] `Kiroku.Subscription` — subscription manager, advisory lock acquisition
- [ ] Server-side event type filtering (indexed `AND event_type = ANY($4)`)
- [ ] Tests: catch-up from position 0, live delivery, checkpoint persistence, reconnection

#### 2b — Projections

**Goal:** Sync and async projections, waitForEvent.

- [ ] `Kiroku.Projection.Sync` — handlers run within the append transaction (must be fast)
- [ ] `Kiroku.Projection.Async` — independent workers with own cursors, ReadCommitted isolation
- [ ] `waitForEvent` API — block until a projection catches up to a given position (per-projection NOTIFY channel)
- [ ] Projection progress tracking table
- [ ] Projection error handling (skip + dead letter table)
- [ ] Tests: sync projection atomicity, async catch-up, waitForEvent, poison event handling

#### 2c — Production Features

**Goal:** Competing consumers, advanced subscription states, hardening.

- [ ] Subscription FSM: add MaxCapacity, Disconnected, Unsubscribed states
- [ ] Competing consumers with partition-aware distribution (`partition_by` function)
- [ ] Advisory lock lifecycle: two-part lock key, lock-loss detection, re-acquisition
- [ ] Subscriber death recovery: re-queue in-flight events
- [ ] Snapshotting for long-lived aggregates
- [ ] Schema migration framework (versioned migrations)

---

## Design Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Global ordering strategy | Strategy E (atomic row-level counter) | Gap-free, contiguous positions, immediate read-your-own-writes, no MVCC vulnerability, standard SQL. ~50K events/s ceiling is sufficient. |
| Event payload format | `JSONB` | Queryable in-database for debugging and ad-hoc analysis, human-readable in psql, works with PostgreSQL tooling. Binary escape hatch (`raw_data BYTEA` column) can be added later as a non-breaking migration if needed. |
| Metadata format | `JSONB` | Flexible, queryable. Causation/correlation IDs are columns for indexed access. |
| Stream naming | Message-DB convention (`category-id`) | Enables category reads via prefix match. No separate category column needed. |
| PostgreSQL client | `hasql` + `hasql-pool` + `hasql-th` | Type-safe, performant, compile-time SQL checking. Best PostgreSQL library in Haskell. |
| LISTEN/NOTIFY | Raw `libpq` | hasql lacks native LISTEN/NOTIFY. Dedicated persistent connection. |
| Notification trigger | On `streams` table (not `events`) | Fires once per append regardless of batch size. Payload includes version range. |
| Immutability | Triggers (not rules) | Enables gated hard deletes via session variable. |
| Transaction isolation | READ COMMITTED | The CTE handles concurrency via row-level locks. No need for SERIALIZABLE. |
| Write concurrency | Row-level lock on source stream + $all row | Source stream UPDATE serializes same-stream writes (inherent to optimistic concurrency). $all row serializes global position assignment. Cross-stream writes contend only on $all. |
| Same-stream concurrency | Row lock only (no advisory locks) | The CTE's `UPDATE streams WHERE stream_uuid` row lock is sufficient for correctness. Advisory locks would reduce wasted retries under contention but add complexity. Cross-stream contention is low in practice. Revisit if high retry rates observed on hot streams. |
| Multi-tenant isolation | Schema-per-tenant from Phase 1 | Parameterize all SQL with schema prefix and scope NOTIFY channels per schema. Avoids costly retrofit. Full tenant lifecycle (create/drop/migrate) deferred to later phases. |
| Backward reads | Include in Phase 1 | Trivial (`ORDER BY stream_version DESC`). Needed for "latest N events" and snapshot-based aggregate loading. |
| Event ID generation | UUIDv7 via PostgreSQL 18+ `uuidv7()` | Time-ordered UUIDs for better B-tree locality and sequential insert performance. Requires PostgreSQL 18+. |
| Idempotency | Server default with caller override | `DEFAULT uuidv7()` generates IDs automatically. Callers may supply their own UUID for idempotent retries — the `events_pkey` constraint rejects duplicates with a `DuplicateEvent` error. UUIDv7 is timestamp+random so retries must reuse the original UUID. |
| Package split | `kiroku-store` + `kiroku` | Store is a standalone, high-performance library (append/read/link/delete). Framework adds subscriptions, projections, and higher-level APIs on top. Clean dependency boundary — store has no subscription/projection concerns. |
| Version conflict orphans | Gate event INSERT on `stream_update` | All CTE steps gated via `EXISTS (SELECT 1 FROM stream_update)`. No orphaned events on version conflict. Negligible performance impact — row lock on `streams` is already held through transaction commit. |

---

## Open Questions

1. **Projection error handling (Phase 2b).** Marten's `SkipApplyErrors` / `SkipSerializationErrors` / `SkipUnknownEvents` with dead letter table. Basic skip + dead letter in 2b; full taxonomy in 2c?
