# Milestone 5 — Links & Categories

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this milestone, callers can do three things they could not do before. First, they can link existing events into new streams — the fundamental building block for projection-built streams. A projection that processes `$all` events can group them into custom streams (e.g., link all `OrderCreated` and `OrderShipped` events for customer "alice" into a `customer-alice` stream) without duplicating event data. Second, they can read events by category. Using the Message-DB naming convention where stream names follow the pattern `category-id` (e.g., `order-123`, `order-456`), callers can read all events across every stream in a category (e.g., all events from any `order-*` stream) in global position order. Third, they can write to multiple streams atomically in a single transaction — for example, appending events to two streams with per-stream version checks, where either both succeed or neither does.

These three capabilities complete Phase 1b of the kiroku-store implementation plan. Together with the append/read/public-API work from Milestones 2–4, they form the core feature set that projections and subscriptions (Phase 2) will build upon.

**Observable outcomes:**

- `cabal build all` compiles with the new `Kiroku.Store.Link` module and updated `Kiroku.Store.Read`.
- `cabal test all` passes all existing tests plus new tests for linking, category reads, and multi-stream transactions.
- `cabal bench all` includes a category read benchmark at scale (1M events across 100 categories).
- The `Store` effect GADT has new operations: `LinkToStream`, `ReadCategoryForward`, and `AppendMultiStream`.


## Progress

- [x] M5.1: Add `linkToStream` SQL and hasql statement (2026-03-23)
- [x] M5.2: Add `readCategory` SQL and hasql statement (2026-03-23)
- [x] M5.3: Extend the `Store` effect GADT with `LinkToStream`, `ReadCategoryForward`, and `AppendMultiStream` (2026-03-23)
- [x] M5.4: Create `Kiroku.Store.Link` module with `linkToStream` public API (2026-03-23)
- [x] M5.5: Add `readCategory` to `Kiroku.Store.Read` (2026-03-23)
- [x] M5.6: Implement multi-stream transaction support (2026-03-23)
- [x] M5.7: Update `Kiroku.Store` public API re-exports (2026-03-23)
- [x] M5.8: Tests — link events, category reads, multi-stream atomicity (2026-03-23)
- [x] M5.9: Benchmark — category read performance at scale (2026-03-23)
- [x] M5.10: Document results and update plan (2026-03-23)


## Surprises & Discoveries

- **Multi-stream transaction rollback requires `Tx.condemn`.** The append CTEs use `ON CONFLICT DO NOTHING` (for `NoStream`) which silently returns zero rows rather than raising a PG error. Without `Tx.condemn`, hasql-transaction commits the transaction even when one append returned `Nothing`, leaving the successful appends persisted. Fix: check results inside the `Transaction` monad and call `Tx.condemn` before returning if any result is `Nothing`.

- **Category read overhead is negligible.** At 100K events across 100 categories, category read (1.05ms/100-event page) is within 2% of `$all` read (1.03ms/100-event page). The `ix_streams_category` index + `ix_stream_events_all_by_origin` partial index make the category filter effectively free.


## Decision Log

- Decision: Use the existing `category` generated column in the `streams` table for category reads, rather than `LIKE` prefix matching on `stream_name`.
  Rationale: The schema already has `category TEXT GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED` and an index `ix_streams_category ON streams (category)`. Using the generated column with an equality check (`WHERE s.category = $1`) is more efficient and index-friendly than `WHERE s.stream_name LIKE $1 || '-%'`. The DESIGN.md originally showed the `LIKE` approach, but the actual schema.sql evolved to use a generated column — follow the schema.
  Date: 2026-03-23

- Decision: Category read queries `$all` (stream_id = 0) filtered by original stream's category, not individual streams.
  Rationale: Reading from `$all` with a category filter returns events in global position order, which is what subscriptions and projections need. The index `ix_stream_events_all_by_origin ON stream_events (original_stream_id, stream_version) WHERE stream_id = 0` supports this pattern. The query plan: look up stream_ids matching the category, then index-scan `$all` entries for those stream_ids, merge-ordered by global position.
  Date: 2026-03-23

- Decision: The link CTE does NOT insert into `$all`. Linked events are already in `$all` from their original append.
  Rationale: The `stream_events` junction table design means an event can appear in multiple streams. When an event is originally appended, it gets rows in `stream_events` for (1) the source stream and (2) `$all`. Linking adds a row for (3) the target stream. The event's global position in `$all` does not change — it was assigned at append time. Adding another `$all` row would double-count the event in `$all` reads.
  Date: 2026-03-23

- Decision: Multi-stream transactions use `hasql-transaction` with `ReadCommitted` isolation and `Write` mode.
  Rationale: The existing append CTEs use row-level locks on the `streams` table for concurrency control. `ReadCommitted` is sufficient because the CTE's `UPDATE ... WHERE stream_version = $expected` provides optimistic concurrency within each stream. `Serializable` would add unnecessary overhead and retry complexity. The `hasql-transaction` library provides automatic retry on serialization conflicts (40001/40P01), but with `ReadCommitted` these should not occur for our use case.
  Date: 2026-03-23

- Decision: Expose `RunTransaction` in the Store effect GADT rather than a standalone `withTransaction` function.
  Rationale: Keeping all store operations within the `Store` effect maintains the mockability guarantee. A standalone `withTransaction` that directly uses the pool would bypass the effect system. The `RunTransaction` constructor takes a callback `(Pool -> IO a)` that the interpreter executes within a transaction session. This keeps the effect GADT as the single point of dispatch while still allowing arbitrary transaction composition.
  Date: 2026-03-23

- Decision: Use `[EventId]` (not `[UUID]`) in the effect GADT and public API for `linkToStream`.
  Rationale: The `EventId` newtype (`newtype EventId = EventId UUID`) already exists in `Types.hs` and provides a meaningful domain name. Exposing raw `UUID` in effect signatures leaks implementation details and makes the API less self-documenting. The hasql `Statement` in `SQL.hs` still operates on `Vector UUID` internally — the interpreter in `Effect.hs` unwraps `EventId` to `UUID` at the boundary.
  Date: 2026-03-23

- Decision: `linkToStream` creates the target stream if it does not exist (upsert semantics).
  Rationale: Projection-built streams are created on-the-fly as events are linked into them. Requiring the caller to create the stream first would add unnecessary ceremony. The link CTE uses `INSERT INTO streams ... ON CONFLICT DO UPDATE` (same pattern as `appendAnyVersion`) to atomically create-or-update the target stream's version. This matches Commanded's link table design where linked streams are managed automatically.
  Date: 2026-03-23


## Outcomes & Retrospective

All 10 milestones complete. The store now supports:

1. **`linkToStream`** — link existing events into projection-built streams without duplicating event data or $all entries. Upsert semantics (target stream created automatically).
2. **`readCategory`** — read events by category prefix (Message-DB convention) in global position order. Uses the `category` generated column + index.
3. **`appendMultiStream`** — atomically append to multiple streams in a single hasql-transaction. Rollback on any version conflict via `Tx.condemn`.

**Test results:** 32 tests pass (20 existing + 12 new: 5 link, 4 category read, 3 multi-stream).

**Benchmark results (100K events, 100 categories):**
- B10 category forward (100-event page): **1.05 ms** (target < 3ms) — PASS
- $all forward baseline (100-event page): **1.03 ms**
- Category filter overhead: ~2% — negligible

**Decision validated:** Using the `category` generated column with equality check is the right approach. The index path `ix_streams_category` → `ix_stream_events_all_by_origin` delivers near-zero overhead for category filtering.


## Context and Orientation

Kiroku is a PostgreSQL event store implemented in Haskell. The core library lives in `kiroku-store/`. The project uses GHC 9.12.2 with the GHC2024 language edition and the effectful effect system for all store operations.

### Key modules and their roles

`kiroku-store/src/Kiroku/Store/SQL.hs` contains all SQL statements as hasql `Statement` values. Each statement has a SQL text template, a hasql encoder (for parameters), and a hasql decoder (for results). The module exports `AppendParams` (a record of the 7 parallel arrays + stream name used by all append CTEs), four append statement functions, five read statement functions, and shared decoders (`recordedEventRow`, `streamInfoRow`). New SQL statements for link and category read will be added here.

`kiroku-store/src/Kiroku/Store/Effect.hs` defines the `Store` effect as a GADT with six constructors (`AppendToStream`, `ReadStreamForward`, `ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`, `GetStream`). The `runStorePool` interpreter pattern-matches on each constructor and executes the corresponding hasql statement against the pool. Internal helpers `prepareEvents` and `buildAppendParams` live here. New GADT constructors for link, category read, and transaction will be added.

`kiroku-store/src/Kiroku/Store/Append.hs` is a thin module that exposes `appendToStream` by calling `send (AppendToStream ...)`. The `Kiroku.Store.Link` module will follow this same pattern.

`kiroku-store/src/Kiroku/Store/Read.hs` exposes five read functions, each calling `send` on the corresponding GADT constructor. `readCategory` will be added here.

`kiroku-store/src/Kiroku/Store/Connection.hs` defines `KirokuStore` (a record with `pool :: Pool` and `schema :: Text`), `ConnectionSettings`, and `withStore` (which auto-initializes the schema).

`kiroku-store/src/Kiroku/Store/Types.hs` defines all domain types: `StreamName`, `StreamId`, `EventId`, `EventType`, `StreamVersion`, `GlobalPosition`, `ExpectedVersion`, `EventData`, `RecordedEvent`, `StreamInfo`, `AppendResult`.

`kiroku-store/src/Kiroku/Store/Error.hs` defines `StoreError` with five constructors and maps hasql `UsageError` to domain errors.

`kiroku-store/src/Kiroku/Store.hs` is the public API module that re-exports all user-facing modules.

`kiroku-store/sql/schema.sql` is the embedded DDL. Relevant schema details for this milestone:

The `streams` table has a generated column: `category TEXT GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED`. This extracts the category prefix from stream names following the `category-id` convention. An index `ix_streams_category ON streams (category)` supports efficient category lookups.

The `stream_events` junction table has a composite primary key `(event_id, stream_id)`. Each event gets at least two rows: one for its source stream and one for `$all` (stream_id = 0). Linking adds additional rows with different stream_ids. The `original_stream_id` and `original_stream_version` columns on every row record where the event was originally appended — these do not change when an event is linked into a new stream.

The index `ix_stream_events_all_by_origin ON stream_events (original_stream_id, stream_version) WHERE stream_id = 0` supports category reads by enabling the planner to look up stream_ids matching a category, then efficiently scan `$all` entries originating from those streams.

`kiroku-store/kiroku-store.cabal` already lists `hasql-transaction >= 1.1` in library build-depends.

`kiroku-store/test/Main.hs` uses hspec with an `around withTestStore` pattern. The `withTestStore` helper uses `ephemeral-pg` to create a fresh PostgreSQL database and `withStore` to initialize it. Tests use `runStoreIO store $ ...` to run effectful operations. There are currently 20 tests.

`kiroku-store/bench/Main.hs` uses `tasty-bench` with `ephemeral-pg`. Benchmarks run inside a `withStore` bracket. A counter provides unique stream names.

### hasql-transaction API

The `hasql-transaction` library (already a dependency) provides:

- `Hasql.Transaction.Transaction` — a monad for composing multiple SQL statements in a transaction. Key functions: `statement :: a -> Statement a b -> Transaction b` (execute a parameterized statement), `sql :: ByteString -> Transaction ()` (execute raw SQL), `condemn :: Transaction ()` (force rollback).
- `Hasql.Transaction.Sessions.transaction :: IsolationLevel -> Mode -> Transaction a -> Session a` — wraps a `Transaction` into a hasql `Session` with automatic retry on serialization conflicts.
- `IsolationLevel`: `ReadCommitted`, `RepeatableRead`, `Serializable`.
- `Mode`: `Read`, `Write`.

To run a transaction against a pool: `Pool.use pool (transaction ReadCommitted Write myTxn)`.


## Plan of Work

The work proceeds in four phases: SQL layer (M5.1–M5.2), effect layer (M5.3–M5.7), tests (M5.8), and benchmarks (M5.9–M5.10).

### Milestone 5.1 — Link SQL statement

Add the `linkToStream` SQL statement and hasql `Statement` to `kiroku-store/src/Kiroku/Store/SQL.hs`.

The link operation takes a list of existing event IDs, a target stream name, and links those events into the target stream. It does NOT insert into the `events` table (events already exist) and does NOT insert into `$all` (events are already there from their original append). It only:

1. Upserts the target stream (create if missing, bump version by the number of linked events).
2. Inserts rows into `stream_events` for the target stream, with sequential `stream_version` values starting from the stream's previous version + 1.

The `original_stream_id` and `original_stream_version` for each linked event must be looked up from the event's existing `stream_events` row (any row for that event_id where stream_id is not 0 — i.e., not the `$all` row). We use a subquery on `stream_events` for this.

The SQL CTE structure:

    WITH
      event_list AS (
        SELECT event_id, idx
        FROM unnest($1::uuid[]) WITH ORDINALITY AS t(event_id, idx)
      ),
      stream_upsert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($2, (SELECT count(*) FROM event_list))
        ON CONFLICT (stream_name)
        DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM event_list)
        RETURNING stream_id, stream_version - (SELECT count(*) FROM event_list) AS initial_version
      ),
      link_inserts AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT el.event_id, su.stream_id, su.initial_version + el.idx,
               orig.original_stream_id, orig.original_stream_version
        FROM event_list el
        CROSS JOIN stream_upsert su
        JOIN LATERAL (
          SELECT se.original_stream_id, se.original_stream_version
          FROM stream_events se
          WHERE se.event_id = el.event_id AND se.stream_id <> 0
          LIMIT 1
        ) orig ON true
      )
    SELECT su.stream_id, su.initial_version + (SELECT count(*) FROM event_list)
    FROM stream_upsert su

Parameters: `$1::uuid[]` (event IDs to link), `$2::text` (target stream name).
Returns: `(stream_id, stream_version)` of the target stream after linking.

A new `LinkResult` type will hold the return values, or we can reuse a subset of `AppendResult`. Since there is no global position change, a dedicated `LinkResult` with just `streamId` and `streamVersion` is cleaner.

Add to `Kiroku.Store.Types`: `data LinkResult = LinkResult { streamId :: !StreamId, streamVersion :: !StreamVersion }`.

The hasql statement internally unwraps `EventId` to `UUID` for the encoder. Add to `Kiroku.Store.SQL`: `linkToStreamStmt :: Statement (Vector UUID, Text) LinkResult` (the encoder operates on raw UUIDs; the `Effect.hs` interpreter unwraps `[EventId]` to `Vector UUID` before calling the statement).

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 5.2 — Category read SQL statement

Add the `readCategoryForward` SQL statement to `kiroku-store/src/Kiroku/Store/SQL.hs`.

The query reads events from `$all` (stream_id = 0) where the originating stream belongs to a given category, ordered by global position (ascending). It uses the `category` generated column on the `streams` table.

    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    JOIN streams s ON s.stream_id = se.original_stream_id
    WHERE se.stream_id = 0
      AND se.stream_version > $1
      AND s.category = $2
    ORDER BY se.stream_version ASC
    LIMIT $3

Parameters: `$1::bigint` (start global position), `$2::text` (category name), `$3::int4` (limit).
Returns: `Vector RecordedEvent` (reuses the existing `recordedEventRow` decoder).

A new `CategoryName` newtype will be added to `Kiroku.Store.Types` for type safety.

Add to `Kiroku.Store.SQL`: `readCategoryForwardStmt :: Statement (Int64, Text, Int32) (Vector RecordedEvent)`, the SQL text, and a `readCategoryEncoder`.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 5.3 — Extend the Store effect GADT

Add three new constructors to the `Store` GADT in `kiroku-store/src/Kiroku/Store/Effect.hs`:

    LinkToStream :: StreamName -> [EventId] -> Store m LinkResult
    ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    RunTransaction :: (forall n. Eff (Store : n) a -> Eff (Store : n) a) -> Store m a

Wait — `RunTransaction` needs more careful thought. The issue is that `hasql-transaction` works at the `Session` level, not the `Eff` level. We cannot simply nest `Eff` computations inside a `Hasql.Transaction.Transaction`. The approach needs to be: the interpreter detects `RunTransaction` and executes the contained operations within a single `Pool.use` call wrapped in a `hasql-transaction`.

A simpler approach: instead of a general `RunTransaction`, provide `LinkToStream` as a single atomic operation (which it already is — it's a single CTE). Multi-stream transactions can be handled by a dedicated `AppendMultiStream` constructor that takes a list of `(StreamName, ExpectedVersion, [EventData])` triples and executes them in a single `hasql-transaction`.

Revised GADT additions:

    LinkToStream :: StreamName -> [EventId] -> Store m LinkResult
    ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    AppendMultiStream :: [(StreamName, ExpectedVersion, [EventData])] -> Store m [AppendResult]

The `AppendMultiStream` interpreter will:
1. Prepare all events (generate UUIDs) for all streams.
2. Open a `hasql-transaction` with `ReadCommitted Write`.
3. Execute each append CTE as a `statement` within the transaction.
4. Collect results. If any append fails (version conflict, etc.), the transaction rolls back.

Add the interpreter cases for all three in `runStorePool`.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 5.4 — Create `Kiroku.Store.Link` module

Create `kiroku-store/src/Kiroku/Store/Link.hs` following the pattern of `Kiroku.Store.Append`:

    module Kiroku.Store.Link (linkToStream) where

    linkToStream ::
        (HasCallStack, Store :> es) =>
        StreamName ->
        [EventId] ->
        Eff es LinkResult
    linkToStream targetStream eventIds = send (LinkToStream targetStream eventIds)

Add `Kiroku.Store.Link` to `exposed-modules` in `kiroku-store.cabal`.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 5.5 — Add `readCategory` to `Kiroku.Store.Read`

Add `readCategory` to `kiroku-store/src/Kiroku/Store/Read.hs`:

    readCategory ::
        (HasCallStack, Store :> es) =>
        CategoryName ->
        GlobalPosition ->
        Int32 ->
        Eff es (Vector RecordedEvent)
    readCategory cat startPos limit = send (ReadCategoryForward cat startPos limit)

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 5.6 — Implement multi-stream transaction support

Add `appendMultiStream` to `kiroku-store/src/Kiroku/Store/Append.hs`:

    appendMultiStream ::
        (HasCallStack, Store :> es) =>
        [(StreamName, ExpectedVersion, [EventData])] ->
        Eff es [AppendResult]
    appendMultiStream ops = send (AppendMultiStream ops)

The interpreter in `Effect.hs` for `AppendMultiStream` will:

1. Call `prepareEvents` for each stream's event list.
2. Call `buildAppendParams` for each.
3. Use `Pool.use pool $ Transaction.Sessions.transaction ReadCommitted Write $ do` to compose:
   - For each `(params, expected)`: `Transaction.statement params stmt` where `stmt` is the appropriate append variant.
4. Collect the `Maybe AppendResult` from each, checking for `Nothing` (version conflict) and throwing the appropriate `StoreError`.

This requires importing `Hasql.Transaction` and `Hasql.Transaction.Sessions` in `Effect.hs`.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 5.7 — Update public API re-exports

Update `kiroku-store/src/Kiroku/Store.hs` to add:

    import Kiroku.Store.Link

And add `module Kiroku.Store.Link` to the export list.

Ensure `CategoryName`, `LinkResult`, and `appendMultiStream` are accessible through the public API (they should be via the existing re-exports of `Types`, `Append`, and `Read`).

At the end of this milestone, `cabal build all` compiles.

### Milestone 5.8 — Tests

Add tests to `kiroku-store/test/Main.hs` covering:

**Link tests:**
- Link a single event to a new stream; read the target stream and verify the event appears with correct `original_stream_id` and `original_stream_version`.
- Link multiple events to a new stream; verify they appear in the order linked with sequential `stream_version` values.
- Link events to an existing stream; verify the stream version is bumped correctly.
- Read the linked stream forward; confirm the events are readable.
- Verify the linked events still appear in `$all` with their original global positions (no duplication).
- Verify linking the same event to the same stream twice fails (primary key constraint on `(event_id, stream_id)`).

**Category read tests:**
- Create streams `order-1`, `order-2`, `user-1` with events in each. Read category `order` — should return events from `order-1` and `order-2` in global position order, not events from `user-1`.
- Category read with pagination (start position > 0, limit).
- Category read for a nonexistent category returns empty.
- Category read includes linked events that originate from streams in the category.

**Multi-stream transaction tests:**
- Append to two streams atomically; both succeed.
- Append to two streams where the second has a version conflict; both roll back (the first stream's version should not have changed).
- Append to three streams with different `ExpectedVersion` variants in one transaction.

At the end of this milestone, `cabal test all` passes.

### Milestone 5.9 — Benchmark: category read at scale

Add a benchmark group `"category"` to `kiroku-store/bench/Main.hs`.

Setup: pre-populate 100 categories, each with 100 streams, each stream with 100 events = 1M events total (1,000,000 events across 10,000 streams in 100 categories). This is a substantial setup step that should run before the benchmark loop.

Note: 1M events may take significant time to insert. Consider reducing to a more practical scale if setup exceeds 60 seconds — e.g., 10 categories × 10 streams × 100 events = 10K events, or 100 categories × 10 streams × 100 events = 100K events. Adjust during implementation based on observed setup time.

Benchmarks:
- B10: Category read forward (100-event page) from a category with 10,000 events (100 streams × 100 events).
- Compare against `$all` read of the same page size to measure the category filter overhead.

Target: category read < 3ms per 100-event page (from IMPLEMENTATION.md performance targets).

At the end of this milestone, `cabal bench all` runs and reports category read performance.

### Milestone 5.10 — Document results

Update this plan's Progress, Surprises & Discoveries, and Outcomes & Retrospective sections. Record benchmark results inline.


## Concrete Steps

All commands run from: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**Step 1: Verify current build.**

    cabal build all

Expected: succeeds.

**Step 2: Add `LinkResult` and `CategoryName` types.**

Edit `kiroku-store/src/Kiroku/Store/Types.hs`.

    cabal build lib:kiroku-store

**Step 3: Add link and category SQL statements.**

Edit `kiroku-store/src/Kiroku/Store/SQL.hs`.

    cabal build lib:kiroku-store

**Step 4: Extend Store GADT and interpreter.**

Edit `kiroku-store/src/Kiroku/Store/Effect.hs`.

    cabal build lib:kiroku-store

**Step 5: Create Link module and update Read module.**

Create `kiroku-store/src/Kiroku/Store/Link.hs`. Edit `kiroku-store/src/Kiroku/Store/Read.hs`. Edit `kiroku-store/kiroku-store.cabal`. Edit `kiroku-store/src/Kiroku/Store.hs`.

    cabal build all

**Step 6: Add multi-stream append.**

Edit `kiroku-store/src/Kiroku/Store/Append.hs`. Edit `kiroku-store/src/Kiroku/Store/Effect.hs`.

    cabal build lib:kiroku-store

**Step 7: Add tests.**

Edit `kiroku-store/test/Main.hs`.

    cabal test all

Expected: all tests pass (20 existing + new link/category/multi-stream tests).

**Step 8: Add category benchmarks.**

Edit `kiroku-store/bench/Main.hs`.

    cabal bench all

Record category read latency. Target: < 3ms per 100-event page.


## Validation and Acceptance

### Compilation

    cabal build all

Must succeed with no warnings in kiroku-store modules.

### Tests

    cabal test all

All tests must pass — the 20 existing tests plus the new link, category, and multi-stream transaction tests.

Key behaviors:

- Linking events: events appear in the target stream with correct sequential versions, and with the correct `original_stream_id` and `original_stream_version` from their original append. The same events remain in `$all` at their original global positions.
- Category reads: only events from streams matching the category prefix are returned, in global position order. Pagination works.
- Multi-stream transactions: all appends succeed or all roll back. A version conflict on any stream causes the entire transaction to fail without side effects.

### Benchmarks

    cabal bench all

**B10 (category read):** < 3ms per 100-event page from a category containing 10K+ events. This is the performance target from IMPLEMENTATION.md.


## Idempotence and Recovery

All steps are idempotent. `cabal build` is incremental. Tests use `ephemeral-pg` which creates a fresh database per run. Schema initialization is idempotent (`IF NOT EXISTS`). The link CTE will fail on duplicate `(event_id, stream_id)` pairs — this is correct behavior (you cannot link the same event to the same stream twice), not an error to recover from. If any step fails, fix the issue and re-run the same command.


## Interfaces and Dependencies

### New Type: `CategoryName`

In `kiroku-store/src/Kiroku/Store/Types.hs`:

    newtype CategoryName = CategoryName Text
        deriving stock (Eq, Ord, Show, Generic)

Represents the category prefix of a stream name (the part before the first `-`). For example, stream `order-123` has category `order`.

### New Type: `LinkResult`

In `kiroku-store/src/Kiroku/Store/Types.hs`:

    data LinkResult = LinkResult
        { streamId :: !StreamId
        , streamVersion :: !StreamVersion
        }
        deriving stock (Eq, Show, Generic)

### New Module: `Kiroku.Store.Link`

In `kiroku-store/src/Kiroku/Store/Link.hs`:

    linkToStream :: (HasCallStack, Store :> es) => StreamName -> [EventId] -> Eff es LinkResult

Links existing events (identified by `EventId`) into a target stream. Creates the stream if it does not exist. Returns the target stream's ID and new version.

### Updated Module: `Kiroku.Store.Read`

New function:

    readCategory :: (HasCallStack, Store :> es) => CategoryName -> GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)

Reads events from streams matching the given category, in global position order.

### Updated Module: `Kiroku.Store.Append`

New function:

    appendMultiStream :: (HasCallStack, Store :> es) => [(StreamName, ExpectedVersion, [EventData])] -> Eff es [AppendResult]

Atomically appends events to multiple streams in a single transaction. If any append fails (version conflict, etc.), the entire transaction rolls back.

### Updated Module: `Kiroku.Store.Effect`

Three new GADT constructors:

    LinkToStream :: StreamName -> [EventId] -> Store m LinkResult
    ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    AppendMultiStream :: [(StreamName, ExpectedVersion, [EventData])] -> Store m [AppendResult]

### Updated Module: `Kiroku.Store.SQL`

New statements:

    linkToStreamStmt :: Statement (Vector UUID, Text) LinkResult
    readCategoryForwardStmt :: Statement (Int64, Text, Int32) (Vector RecordedEvent)

### Updated Module: `Kiroku.Store`

Add `module Kiroku.Store.Link` to re-exports.

### Dependencies

No new dependencies. `hasql-transaction` is already in library `build-depends`.
